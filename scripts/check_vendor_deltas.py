#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""check_vendor_deltas.py -- the vendoring delta list must match reality.

`examples/kv260/third_party/CVA6_PIN.md` documents the local changes made to
the fetched CVA6 tree. Two mechanisms actually make those changes:

  * the patch series `examples/kv260/third_party/patches/cva6/*.patch`, and
  * `sed` steps inside `fetch.sh` for renames a context diff could not
    survive across upstream bumps.

On 2026-08-21 the list documented six deltas while `fetch.sh` performed
eight. That did not make the list incomplete -- it made it WRONG: anyone
comparing the patch series against a freshly fetched tree found changes with
no delta behind them, and had no way to tell an intended rename from
contamination. This guard is the regression guard for that defect class.

WHAT IT CHECKS, and deliberately nothing more:

  1. every patch file in the series is named in CVA6_PIN.md;
  2. every source file a patch touches (its `--- a/...` headers) is named
     there;
  3. every vendored file that `fetch.sh` rewrites with `sed`, or generates,
     is named there.

WHAT IT DOES NOT CHECK: whether the prose is accurate. A guard cannot read;
it can only insist that nothing changes the tree without being mentioned.
That is the check that would have caught the 2026-08-21 defect, and it is
the one worth having -- a cleverer guard that produces false positives gets
switched off, and then nothing is checked at all.

Exit 0 = every change has an entry, 1 = something is missing.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TP = ROOT / "examples" / "kv260" / "third_party"
PIN = TP / "CVA6_PIN.md"
PATCH_DIR = TP / "patches" / "cva6"
FETCH = TP / "fetch.sh"

# Files fetch.sh touches that are NOT vendored source: its own scratch names.
IGNORE_TARGETS = {"pulp_counter.sv.hdr"}


def fetch_targets(text: str) -> set[str]:
    """Vendored file names fetch.sh rewrites in place or generates."""
    names: set[str] = set()
    # `for f in a.sv b.sv; do ... sed -i ... "$dir/$f"` -- take the loop list
    # when a sed -i appears anywhere in the script (it does; if it ever does
    # not, the loop is not a delta either).
    if re.search(r"\bsed\s+-i\b", text):
        for m in re.finditer(r"for\s+f\s+in\s+([^\n;]+);", text):
            for tok in m.group(1).split():
                if tok.endswith((".sv", ".svh", ".v")):
                    names.add(tok)
    # `sed ... "$cc/counter.sv" > "$cc/pulp_counter.sv"` -- both sides count:
    # the source is read, the target is created.
    for m in re.finditer(r'\$\{?\w+\}?/([\w.]+\.sv)\b', text):
        names.add(m.group(1))
    return {n for n in names if n not in IGNORE_TARGETS}


def patch_targets(path: Path) -> set[str]:
    names = set()
    for ln in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ln.startswith("--- a/"):
            names.add(ln[6:].strip().split("/")[-1])
    return names


def main() -> int:
    for p in (PIN, FETCH, PATCH_DIR):
        if not p.exists():
            print(f"[check_vendor_deltas] ERROR: missing {p.relative_to(ROOT)}")
            return 1

    pin = PIN.read_text(encoding="utf-8")
    missing: list[str] = []

    patches = sorted(PATCH_DIR.glob("*.patch"))
    if not patches:
        print("[check_vendor_deltas] ERROR: no patches found -- has the series moved?")
        return 1

    for pf in patches:
        if pf.name not in pin and pf.stem.split("-", 1)[-1] not in pin:
            missing.append(f"patch file not mentioned in CVA6_PIN.md: {pf.name}")
        for target in patch_targets(pf):
            if target not in pin:
                missing.append(
                    f"{pf.name} patches {target}, which CVA6_PIN.md does not name")

    for target in sorted(fetch_targets(FETCH.read_text(encoding="utf-8"))):
        if target not in pin:
            missing.append(
                f"fetch.sh rewrites or generates {target}, "
                f"which CVA6_PIN.md does not name")

    if missing:
        print("[check_vendor_deltas] the delta list does not match what the "
              "fetch actually does:")
        for m in missing:
            print(f"  {m}")
        print("  Add an entry to examples/kv260/third_party/CVA6_PIN.md. A change "
              "to the vendored\n  tree that no delta names is indistinguishable "
              "from contamination.")
        return 1

    n_files = len({t for pf in patches for t in patch_targets(pf)})
    print(f"[check_vendor_deltas] OK: {len(patches)} patch(es) touching {n_files} "
          f"file(s) and every fetch.sh rewrite are named in CVA6_PIN.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
