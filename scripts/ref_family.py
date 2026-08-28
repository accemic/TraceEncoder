#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""REF_FINAL reference families: compute the key, archive, select.

The byte-neutrality gates ("a new feature does not change existing
streams") compare a fresh build against a PINNED md5 family, minted by
scripts/r2_final_mint.sh. Which family a gate may compare against is not
free choice: a family is minted from the full profile of its HEAD, so its
config message (TCODE 58) carries that profile's CAPS word. A build with a
LATER feature compiled out can never reproduce a family that already
contains that feature's CAPS bit -- not "usually not", but by
construction.

That is exactly what the P7 audit found (condition A-1): the P7 gate
pinned `bld/r2_final_manifest.txt`, a re-mint two minutes later put P7's
own CAPS bit 22 into it, and from then on the gate reported a permanent
DRIFT although nothing had drifted. The fix is mechanical selection
instead of "whatever was minted last":

  * the CAPS word is a pure function of the CT_EN_* switches
    (ct_pkg::ct_cfgmsg_caps), so it can be computed from ct_pkg.sv alone;
  * every minted family is archived under its own name in verification/ref_final/
    with its CAPS word recorded in verification/ref_final/families.tsv;
  * a gate asks for the family whose CAPS word equals the one ITS build
    will emit, and logs which file it got and why.

Modes
    caps    --pkg <ct_pkg.sv> | --rev <sha>
            print the key lines (CAPS_VALUE / CAPS_WIDTH / ...).
    select  --pkg <ct_pkg.sv> | --rev <sha>
            print FAMILY=<path> for the archived family matching that
            build; exit 3 when no or more than one family matches.
    archive <manifest> [--caps 0x...] [--reason "..."]
            copy a minted manifest into verification/ref_final/ and append its index
            line. APPEND-ONLY: an existing archive file is never
            overwritten and never edited.

The evaluator is deliberately strict: an expression in ct_cfgmsg_caps it
does not understand, a bit index out of order, or a switch it cannot
resolve is a hard error. Silently skipping one bit would produce a wrong
CAPS word, and a wrong CAPS word selects a wrong family -- the very class
of failure this file exists to close.
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ARCHIVE = REPO / "verification" / "ref_final"
INDEX = ARCHIVE / "families.tsv"
INDEX_HEADER = "# file\tcaps_value\tcaps_width\tminted\thead\tderivation\treason"


class RefFamilyError(Exception):
    """Anything that would make the computed CAPS word untrustworthy."""


# ------------------------------------------------------------------ CAPS ----
FUNC_RE = re.compile(r"function\s+automatic\s+logic\s*\[\s*(\d+)\s*:\s*0\s*\]\s*"
                     r"ct_cfgmsg_caps\s*\(([^)]*)\)\s*;(.*?)endfunction",
                     re.S)
SWITCH_RE = re.compile(r"^\s*localparam\s+bit\s+(CT_[A-Z0-9_]+)\s*=\s*([01])\s*;",
                       re.M)
# Integer build knobs (`localparam int unsigned CT_X = 32;`) and the DERIVED
# bit switches that compare against them (`localparam bit CT_Y = (CT_X == 64);`).
# X2a introduced the first CAPS bit of that shape: ADDR64 is CT_XLEN == 64,
# and giving it a second, independently writable `localparam bit` would be a
# second source of truth for the same fact -- exactly what this evaluator
# exists to prevent one level up.
INT_KNOB_RE = re.compile(r"^\s*localparam\s+int(?:\s+unsigned)?\s+"
                         r"(CT_[A-Z0-9_]+)\s*=\s*(\d+)\s*;", re.M)
DERIVED_RE = re.compile(r"^\s*localparam\s+bit\s+(CT_[A-Z0-9_]+)\s*=\s*"
                        r"\(\s*(CT_[A-Z0-9_]+)\s*==\s*(\d+)\s*\)\s*;", re.M)
ENTRY_RE = re.compile(r"^[ \t]*(?P<expr>[^,/\n]+?)\s*,?\s*//\s*(?P<bit>\d+)\s+(?P<name>\S+)",
                      re.M)
LITERAL_RE = re.compile(r"^(?:\d+'b)?([01])$")


def caps_from_pkg(text: str, sijump: int = 0) -> dict:
    """Evaluate ct_cfgmsg_caps() for the switch values in this ct_pkg.sv."""
    m = FUNC_RE.search(text)
    if not m:
        raise RefFamilyError("ct_cfgmsg_caps() not found in the package -- "
                             "the CAPS word cannot be computed")
    width = int(m.group(1)) + 1
    body = m.group(3)
    switches = {k: int(v) for k, v in SWITCH_RE.findall(text)}
    knobs = {k: int(v) for k, v in INT_KNOB_RE.findall(text)}
    for name, knob, want in DERIVED_RE.findall(text):
        if knob not in knobs:
            raise RefFamilyError(
                f"derived switch {name} compares against {knob}, which has no "
                f"`localparam int [unsigned] {knob} = <n>;` in the package -- "
                f"the CAPS word cannot be computed")
        switches[name] = int(knobs[knob] == int(want))

    entries = {}
    for e in ENTRY_RE.finditer(body):
        bit = int(e.group("bit"))
        if bit in entries:
            raise RefFamilyError(f"CAPS bit {bit} listed twice in ct_cfgmsg_caps()")
        entries[bit] = (e.group("expr").strip(), e.group("name"))
    missing = sorted(set(range(width)) - set(entries))
    if missing:
        raise RefFamilyError(f"ct_cfgmsg_caps() returns {width} bits but bit(s) "
                             f"{missing} carry no `// <bit> <NAME>` comment")
    extra = sorted(set(entries) - set(range(width)))
    if extra:
        raise RefFamilyError(f"ct_cfgmsg_caps() comments bit(s) {extra} outside "
                             f"the declared width {width}")

    value = 0
    owners_on, bits_on = [], []
    for bit in range(width):
        expr, name = entries[bit]
        val, owner = eval_term(expr, switches, sijump)
        if val:
            value |= 1 << bit
            bits_on.append(bit)
            owners_on.append(owner or name)
    return {
        "value": value,
        "width": width,
        "sijump": sijump,
        "bits_on": bits_on,
        "owners_on": owners_on,
    }


def eval_term(expr: str, switches: dict, sijump: int):
    """Value of one CAPS concatenation term + the switch that names it."""
    e = expr.strip().rstrip(",").strip()
    e = re.sub(r"^bit'\(\s*(.*?)\s*\)$", r"\1", e)   # bit'(A || B) -> A || B
    e = e.strip("() \t")
    parts = [p.strip() for p in e.split("||")]
    value = 0
    names = []
    for p in parts:
        if p == "sijump":
            value |= sijump
            names.append("sijump")
            continue
        lit = LITERAL_RE.match(p)
        if lit:
            # Reserved-bit placeholder (`1'b0`) or a permanent tie-off.
            value |= int(lit.group(1))
            names.append(f"const{lit.group(1)}")
            continue
        if not re.fullmatch(r"CT_[A-Z0-9_]+", p):
            raise RefFamilyError(f"cannot evaluate CAPS term {expr!r}: token "
                                 f"{p!r} is neither a CT_* switch nor `sijump`")
        if p not in switches:
            raise RefFamilyError(f"CAPS term {expr!r} names {p}, which has no "
                                 f"`localparam bit {p} = 0|1;` in the package")
        value |= switches[p]
        names.append(p)
    return value, "+".join(names)


def read_pkg(args) -> str:
    if args.rev:
        out = subprocess.run(["git", "-C", str(REPO), "show",
                              f"{args.rev}:rtl/pkg/ct_pkg.sv"],
                             capture_output=True, text=True)
        if out.returncode != 0:
            raise RefFamilyError(f"git show {args.rev}:rtl/pkg/ct_pkg.sv failed: "
                                 f"{out.stderr.strip()}")
        return out.stdout
    path = Path(args.pkg)
    if not path.is_file():
        raise RefFamilyError(f"package file not found: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


# --------------------------------------------------------------- archive ----
HDR_MINTED = re.compile(r"^#\s*REF_FINAL manifest\s*--\s*minted\s*"
                        r"(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})[:0-9]*,\s*HEAD\s*(\S+)",
                        re.M)
HDR_CAPS = re.compile(r"^#\s*caps-value\s*:\s*(0x[0-9a-fA-F]+)\s*"
                      r"\(width\s*(\d+)", re.M)
HDR_REASON = re.compile(r"^#\s*reason\s*:\s*(.*)$", re.M)


def read_index() -> list:
    if not INDEX.is_file():
        return []
    rows = []
    for line in INDEX.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        rows.append(line.split("\t"))
    return rows


def cmd_archive(args) -> int:
    src = Path(args.manifest)
    if not src.is_file():
        raise RefFamilyError(f"manifest not found: {src}")
    text = src.read_text(encoding="utf-8", errors="replace")

    m = HDR_MINTED.search(text)
    if not m:
        raise RefFamilyError(f"{src} has no `# REF_FINAL manifest -- minted "
                             f"<date>, HEAD <sha>` header line -- refusing to "
                             f"archive a family that cannot name itself")
    stamp = f"{m.group(1)}{m.group(2)}{m.group(3)}-{m.group(4)}{m.group(5)}"
    head = m.group(6)

    derivation = "header"
    if args.caps:
        caps_value, caps_width = int(args.caps, 16), int(args.width or 0)
        derivation = "explicit"
    else:
        c = HDR_CAPS.search(text)
        if c:
            caps_value, caps_width = int(c.group(1), 16), int(c.group(2))
        else:
            # Legacy family (minted before the header carried the word):
            # recompute it from the package at the recorded HEAD.
            info = caps_from_pkg(read_pkg(argparse.Namespace(rev=head, pkg=None)))
            caps_value, caps_width = info["value"], info["width"]
            derivation = f"recomputed-from-{head}"

    reason = args.reason
    if not reason:
        r = HDR_REASON.search(text)
        reason = r.group(1).strip() if r else "-"
    reason = " ".join(reason.split())[:160]

    name = f"REF_FINAL_caps{caps_width}_{stamp}_{head}.txt"
    dst = ARCHIVE / name
    ARCHIVE.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        print(f"[ref_family] archive already holds {name} -- append-only, "
              f"nothing written")
    else:
        shutil.copyfile(src, dst)
        print(f"[ref_family] archived {src} -> verification/ref_final/{name}")

    rows = read_index()
    if any(r[0] == name for r in rows):
        print(f"[ref_family] index already lists {name}")
        return 0
    line = "\t".join([name, f"0x{caps_value:x}", str(caps_width),
                      stamp, head, derivation, reason])
    fresh = not INDEX.is_file() or not INDEX.read_text(encoding="utf-8").strip()
    with INDEX.open("a", encoding="utf-8") as fh:
        if fresh:
            fh.write(INDEX_HEADER + "\n")
        fh.write(line + "\n")
    print(f"[ref_family] index += {name}  caps=0x{caps_value:x} (width {caps_width})")
    return 0


def cmd_select(args) -> int:
    info = caps_from_pkg(read_pkg(args), sijump=args.sijump)
    rows = read_index()
    if not rows:
        raise RefFamilyError(f"{INDEX} is empty -- no archived family to select "
                             f"from (run scripts/r2_final_mint.sh, or archive an "
                             f"existing manifest with `ref_family.py archive`)")
    hits = [r for r in rows if int(r[1], 16) == info["value"]]
    if not hits:
        known = ", ".join(f"{r[1]}({r[0]})" for r in rows)
        raise RefFamilyError(
            f"no archived REF_FINAL family carries CAPS 0x{info['value']:x} "
            f"(the word THIS build emits). Known: {known}. A gate must never "
            f"compare against a family with a different CAPS set -- that "
            f"comparison can only fail, and it fails for the wrong reason "
            f"(P7 audit A-1).")
    superseded = []
    if len(hits) > 1:
        # Same CAPS word, several mints. That is a LEGITIMATE state of the
        # append-only archive: a re-mint whose streams moved without a CAPS
        # bit (first case: the M0 merge 22ee86a3 -- C0b deepens the ACT
        # alignment pipes and P0-02 moves the sync-cadence reset, the word
        # stays 0x7fffbf). The current pin for a word is by definition its
        # NEWEST mint; the older siblings stay readable and selectable via
        # the gates' REF=<path> override (reproducing an older comparison).
        # The P7-A-1 protection is untouched -- a word MISMATCH still
        # refuses. Only an unresolvable tie (two mints with the same stamp)
        # stays a hard error.
        hits.sort(key=lambda r: r[3])
        if hits[-1][3] == hits[-2][3]:
            raise RefFamilyError(
                f"CAPS 0x{info['value']:x} matches {len(hits)} archived "
                f"families and the two newest carry the SAME mint stamp "
                f"({hits[-1][0]}, {hits[-2][0]}) -- unresolvable, pin one "
                f"explicitly (REF=<path>)")
        superseded = [r[0] for r in hits[:-1]]
    r = hits[-1]
    print(f"FAMILY={(ARCHIVE / r[0]).as_posix()}")
    print(f"FAMILY_FILE={r[0]}")
    print(f"FAMILY_CAPS={r[1]}")
    print(f"FAMILY_WIDTH={r[2]}")
    print(f"FAMILY_MINTED={r[3]}")
    print(f"FAMILY_HEAD={r[4]}")
    print(f"BUILD_CAPS=0x{info['value']:x}")
    print(f"BUILD_CAPS_WIDTH={info['width']}")
    if superseded:
        # Visible in every gate log that records the selection: which
        # same-word families were passed over, so an auditor can re-run the
        # comparison against them deliberately (REF=<path>) instead of
        # discovering them by surprise in the index.
        print(f"FAMILY_SUPERSEDES={','.join(superseded)}")
    return 0


def cmd_caps(args) -> int:
    info = caps_from_pkg(read_pkg(args), sijump=args.sijump)
    print(f"CAPS_VALUE=0x{info['value']:x}")
    print(f"CAPS_WIDTH={info['width']}")
    print(f"CAPS_SIJUMP={info['sijump']}")
    print(f"CAPS_BITS_ON={','.join(str(b) for b in info['bits_on'])}")
    print(f"CAPS_OWNERS_ON={','.join(info['owners_on'])}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add_source(p):
        p.add_argument("--pkg", default=str(REPO / "rtl" / "pkg" / "ct_pkg.sv"),
                       help="ct_pkg.sv to evaluate (default: this repo's)")
        p.add_argument("--rev", help="read ct_pkg.sv from this git revision instead")
        p.add_argument("--sijump", type=int, default=0,
                       help="value of the CT_SIJUMP instance parameter (default 0, "
                            "the value every in-tree encoder instance uses)")

    add_source(sub.add_parser("caps", help="print the CAPS key of a build"))
    add_source(sub.add_parser("select", help="pick the archived family for a build"))

    pa = sub.add_parser("archive", help="archive a minted manifest (append-only)")
    pa.add_argument("manifest")
    pa.add_argument("--caps", help="CAPS word (hex) if the header does not carry it")
    pa.add_argument("--width", help="CAPS width, with --caps")
    pa.add_argument("--reason", help="supersession reason for the index line")

    args = ap.parse_args()
    try:
        return {"caps": cmd_caps, "select": cmd_select,
                "archive": cmd_archive}[args.cmd](args)
    except RefFamilyError as exc:
        print(f"[ref_family] FAIL: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
