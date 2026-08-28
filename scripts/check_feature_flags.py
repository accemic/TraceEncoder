#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Feature-flag drift guard: RTL switches vs RDL vs CAPS map vs documentation.

Cross-checks four sources of truth against each other and FAILs (exit 1)
on any inconsistency, so the flag documentation cannot silently rot:

  A. rtl/pkg/ct_pkg.sv          -- the CT_EN_* build switches (0/1 literals)
                                   plus the broad set of all CT_* localparams.
  B. rdl/ct_cs_cpuif.rdl        -- register/field tree, per-field reset values
                                   and register offsets, evaluated for the
                                   FULL profile (empty `define set: `ifdef
                                   branches dropped, `ifndef branches taken).
                                   `->reset =` property overrides live inside
                                   profile `ifdef branches and are therefore
                                   ignored by construction.
  C. ct_pkg.sv ct_cfgmsg_caps() -- the CAPS bit map (bit -> name + the
                                   CT_EN_* switches in each bit expression),
                                   width cross-checked against
                                   NEXUS_MSG_CFG_CAPS_WIDTH (22 since P4:
                                   bit 18 QUOTA_SYNC, 19 DEVICE_ID,
                                   20 WATCHPOINT_MSG, 21 DF_ADDR_COMPRESS).
  D. The three documentation tables:
       - doc/trace-format.adoc      "Where CTTE sits" capability matrix
                                    (7 columns incl. Build switch /
                                    Runtime control / CAPS),
       - doc/integration.adoc       "#feature-flags" reference table,
       - doc/enhanced-features.adoc compression-suite table
                                    (Build switch / Enable columns).
  E. rtl/ct_L2_nexus_formatter.sv  -- the cfg_enab runtime-enable packing
                                   (ENAB = CFG_CAPS & {...}) behind the
                                   TCODE-58 config message.

Checks:
  * every CT_EN_* bit switch in ct_pkg.sv has exactly one row in the
    integration flag table, and no table row names an unknown switch;
  * every CT_EN_* switch that drives a CAPS bit (parsed from
    ct_cfgmsg_caps()) appears at least once in the Build-switch column
    of the trace-format capability matrix; CT_SIJUMP (CAPS bit 6,
    elaboration parameter) analogously;
  * every `CT_*` token quoted in the doc scopes exists in ct_pkg.sv
    (or is one of the ct_encoder elaboration parameters CT_SIJUMP /
    CT_DEVICE_ID);
  * every backticked RDL reference in the checked cells exists in the
    full-profile RDL -- dotted `reg.field` refs, and bare names that
    follow the register naming convention (`tr` + uppercase) or use
    array/memory syntax (`name[]`): registers, external memories
    (`watchpoints`) and `->ispresent = false` type anchors
    (`trActCapStCmd`) are separate parser categories, all valid as
    reference targets (a type anchor is not a live CSR);
  * every 0xOFF[hi:lo] annotation is checked against the RDL register
    offset / field bit range -- for ALL refs of a cell, not only the
    first;
  * the documented reset value equals the RDL reset;
  * the documented "Default full" column equals the ct_pkg.sv value;
  * CAPS: no gap and no collision over the full bit range, width ==
    NEXUS_MSG_CFG_CAPS_WIDTH, the
    per-row CAPS bit matches the switch named in the bit's expression,
    and the CAPS bit-name list in the trace-format config-message section
    matches the ct_cfgmsg_caps() comments;
  * ENAB packing (cfg_enab): concatenation order is MSB-first with no
    gap/duplicate over the CAPS width, each per-bit comment name matches
    the CAPS map, each bit's source matches the script's expectation
    table ENAB_EXPECT (runtime cs_proc field, or the `1'b1` "= CAPS"
    tie-off expected exactly for bits 17/12/11/10/6), and the
    expectation table itself is cross-checked against the RDL so it
    cannot go stale silently;
  * enhanced-features compression table: each Build-switch cell is a
    real CT_EN_* switch and each Enable cell resolves to an existing
    trTeInstFeatures field that matches the integration flag-table
    mapping for the same switch;
  * trace-format matrix structure: every group row spans all 7 columns
    (`7+s|`) and every data row has exactly 7 cells (a forgotten group
    row or cell breaks the table silently in AsciiDoc).

Known limits (doc-flag audit 2026-08-03 gap IDs; G1/G2/G4/G6/G9 closed
by the P1 fix round, the following remain open -- honest scope):
  * G3      -- bare FIELD names that continue a dotted ref
               (`InstSyncMax`, `SrcBits`, `Type`/`Prescale`/`Width`) are
               not resolved against the RDL; only full `reg.field` refs
               and register-convention bare names are validated.
  * G4-Rest -- dynamic RDL property overrides other than the modelled
               `->ispresent = false` (`->sw`, `->name`, `->reset` inside
               active branches) and mem-entry internals
               (memwidth/mementries vs the documented entry layout) are
               not modelled.
  * G5      -- slim/E-Trace-profile RDL views are not evaluated (only
               the full profile, empty define set); profile-dependent
               reset notes (e.g. the E-Trace-only Protocol reset 1) are
               prose, not machine-checked.
  * G7      -- CLOSED (P2 stage 6): range CAPS cells such as `10-14`
               are expanded; every bit must be mapped and each bit's
               driving switch named in the row's Build cell.
  * G8-Rest -- behavioural cell claims (WARL legalization, "register
               omitted when 0", "CSR reads 0 when off") are not verified
               against the CSR wrapper / generated regblock RTL.
  * G10     -- prose outside the three checked tables and the remaining
               doc/*.adoc files are out of scope. The reference manual is
               out of scope too, but no longer because it is "mirrored"
               under docs/rm/**: that mirror was retired on 2026-08-09
               (D1) after it had drifted from the doc repo in 18 of 24
               files. The RM lives in D:\\shared\\doc (repo `doc`,
               src/product_internal/ctrace/) and has its own pipeline.

Also unchecked by coordinator decision: LUT/FF cost cells (measurement
provenance, not machine-checkable); the featparity_gold/slimfull_gold
profile-default column (would require emulating
scripts/phase_d_matrix_v2.sh); CT_EN_COMPRESSION (a derived OR in
ct_pkg.sv, not an independent switch -- whitelisted wherever it is
mentioned).

Output: one `FAIL: <category>: <detail> (<file>:<line>)` line per finding,
exit 0/1. Stdlib only.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

CT_PKG = REPO / "rtl" / "pkg" / "ct_pkg.sv"
CT_ENCODER = REPO / "rtl" / "ct_encoder.sv"
VENDOR_PKG = REPO / "rtl" / "pkg" / "nexus_vendor_riscv_pkg.sv"
FORMATTER = REPO / "rtl" / "ct_L2_nexus_formatter.sv"
RDL = REPO / "rdl" / "ct_cs_cpuif.rdl"
DOC_TF = REPO / "doc" / "trace-format.adoc"
DOC_INT = REPO / "doc" / "integration.adoc"
DOC_ENH = REPO / "doc" / "enhanced-features.adoc"

# Derived OR in ct_pkg.sv (not a 0/1 literal, not an independent switch).
DERIVED_SWITCHES = {"CT_EN_COMPRESSION"}

# RDL profile `define tokens (CT_PROFILE_NO_*) are legitimate doc references
# too -- they live in the RDL profile mechanism, not in ct_pkg.sv, so the
# ct_pkg token check must not reject them. Validated against the switch ->
# define map in scripts/gen_rdl_profile.py (the SSOT of that mechanism), so a
# doc mention of a define that does not exist still fails. Found C0a: the
# [#filter-cost-drivers] block (commit 9197394206) names
# `CT_PROFILE_NO_FILTERS` and left this guard red at HEAD.
PROFILE_DEFINES = set(
    re.findall(r'"(CT_PROFILE_NO_\w+)"',
               (REPO / "scripts" / "gen_rdl_profile.py")
               .read_text(encoding="utf-8", errors="replace")))

# ---------------------------------------------------------------------------
# ENAB expectation table (cfg_enab in ct_L2_nexus_formatter.sv): per CAPS
# bit, the runtime-enable source the RTL must mask CFG_CAPS with. `1'b1`
# = "= CAPS" tie-off (feature has no runtime knob; ENAB mirrors CAPS).
# The table is itself cross-checked: coverage against the CAPS width and
# every cs_proc source against the RDL field list -- falsifying one entry
# (self-test) or changing the RTL packing turns the check red.
# ---------------------------------------------------------------------------
ENAB_EXPECT = {
    # ADDR64 (X2a): not a feature but the address width of the netlist
    # (CT_ADDR64 = CT_XLEN == 64). There is nothing to enable at runtime, so
    # ENAB mirrors CAPS.
    23: "1'b1",
    # DF_DROP (P7): the runtime policy bit itself IS the ENAB term -- with
    # DataDropEna = 0 the encoder never drops, so the feature is not in use
    # for this stream.
    22: "cs_proc.trTeDataDropEna",
    # DF_ADDR_COMPRESS (P3): like QUOTA_SYNC there is no separate enable
    # bit -- selecting a non-FULL compression mode IS the runtime use
    # (DADDR_FULL is the formatter-local shorthand for the DTR_ADDR_FULL
    # enum literal).
    21: "(cs_proc.trTeDataAddrCompress != DADDR_FULL)",
    # WATCHPOINT_MSG (P4): no separate enable bit either -- a non-zero slot
    # mask IS the runtime use (WEM = 0 masks every hit).
    20: "(|cs_proc.trWpWEM)",
    # DEVICE_ID (P4): the emission mode IS the runtime enable (DID_NONE
    # means the stream carries no Device ID message).
    19: "(cs_proc.trTeSendDeviceId != DID_NONE)",
    # QUOTA_SYNC has no separate enable bit: selecting one of the two
    # quota cadence modes IS the runtime use of the feature, so the ENAB
    # source is a mode-comparison expression (the only non-plain-signal
    # entry; QUOTA_MODE_* are formatter-local shorthands for the
    # ITR_SYNC_TRACE_MSG/_TRACE_BYTES enum literals).
    18: "(cs_proc.trTeInstSyncMode == QUOTA_MODE_MSG) || (cs_proc.trTeInstSyncMode == QUOTA_MODE_BYTES)",
    17: "1'b1",                                # DAQ          = CAPS tie-off
    16: "cs_proc.trTeDataTracing",             # DATA_TRACE
    15: "cs_proc.trTsEnable",                  # TIMESTAMP
    14: "cs_proc.trTeInstSeqSyncEnable",       # SEQ_SYNC
    13: "cs_proc.trTeInstTrigEnable",          # TRIG_SYNC
    12: "1'b1",                                # EVTI         = CAPS tie-off
    11: "1'b1",                                # POWER_EVENTS = CAPS tie-off
    10: "1'b1",                                # DEBUG_EVENTS = CAPS tie-off
    9:  "cs_proc.trTeInstEnRepeatInstr",       # REPEAT_INSTR
    8:  "cs_proc.trTeInstEnIbhs",              # IBHS
    7:  "cs_proc.trTeContext",                 # OWNERSHIP
    6:  "1'b1",                                # SIJUMP       = CAPS tie-off
    5:  "cs_proc.trTeInstEnBranchPrediction",  # BP
    4:  "cs_proc.trTeInstEnJumpTargetCache",   # JTC
    3:  "cs_proc.trTeInstEnRepeatBranch",      # RB
    2:  "cs_proc.trTeInstEnWideIcnt",          # WIDE_ICNT
    1:  "cs_proc.trTeInstEnRepeatedHistory",   # RH
    0:  "cs_proc.trTeInstEnImplicitReturn",    # IR
}
ENAB_TIEOFF = frozenset(b for b, e in ENAB_EXPECT.items() if e == "1'b1")

# CAPS bits that are NOT driven by a CT_EN_* switch, and the identifier that
# does drive them. Their bit expression in ct_cfgmsg_caps() carries no
# CT_EN_* token, so the flag-table coverage rule below cannot find a row for
# them; instead the named identifier has to be documented in the
# integration #feature-flags section. Without this table every such bit fell
# into one shared "CT_SIJUMP must be documented" branch -- which passes for
# the wrong reason as soon as there is a second one.
PARAM_CAPS = {
    6:  "CT_SIJUMP",   # elaboration parameter of ct_encoder
    23: "CT_XLEN",     # address-width build knob (CT_ADDR64 = CT_XLEN == 64)
}

failures = []


def fail(category: str, detail: str, where: str = "") -> None:
    failures.append(f"FAIL: {category}: {detail}" + (f" ({where})" if where else ""))


# ---------------------------------------------------------------------------
# A. ct_pkg.sv switches
# ---------------------------------------------------------------------------

def parse_ct_pkg(text: str):
    """Return (bit_switches: name->0/1, broad: set of all CT_* localparams)."""
    bit_switches = {}
    for m in re.finditer(r"^\s*localparam\s+bit\s+(CT_EN_\w+)\s*=\s*([01])\s*;",
                        text, re.M):
        bit_switches[m.group(1)] = int(m.group(2))
    broad = set(re.findall(
        r"^\s*localparam\s+(?:bit\s+|int\s+unsigned\s+|logic\s*\[[^\]]*\]\s*)?(CT_\w+)\s*=",
        text, re.M))
    return bit_switches, broad


# ---------------------------------------------------------------------------
# C. CAPS map from ct_cfgmsg_caps() (raw text -- the comments carry the bits)
# ---------------------------------------------------------------------------

def parse_caps(text: str):
    """Return {bit: (name, frozenset(CT_EN_* tokens in the expression))}."""
    m = re.search(r"function\s+automatic\s+logic\s*\[(\d+):0\]\s*ct_cfgmsg_caps"
                  r"(.*?)endfunction", text, re.S)
    if not m:
        fail("caps", "ct_cfgmsg_caps() not found in ct_pkg.sv", str(CT_PKG))
        return {}, 0
    width = int(m.group(1)) + 1
    caps = {}
    for line in m.group(2).splitlines():
        if "//" not in line:
            continue
        code, comment = line.split("//", 1)
        cm = re.match(r"\s*(\d+)\s+(\w+)", comment)
        if not cm:
            continue
        bit = int(cm.group(1))
        name = cm.group(2)
        tokens = frozenset(re.findall(r"CT_EN_\w+", code))
        if bit in caps:
            fail("caps", f"bit {bit} assigned twice in ct_cfgmsg_caps()", str(CT_PKG))
        caps[bit] = (name, tokens)
    return caps, width


# ---------------------------------------------------------------------------
# B. RDL parser (full profile: empty define set)
# ---------------------------------------------------------------------------

def rdl_clean(text: str) -> str:
    """Blank out strings, //-line and /* */-block comments (newlines kept)."""
    out = []
    i, n = 0, len(text)
    state = 0  # 0 normal, 1 string, 2 line comment, 3 block comment
    while i < n:
        c = text[i]
        if state == 0:
            if c == '"':
                state = 1
                out.append(" ")
            elif c == "/" and i + 1 < n and text[i + 1] == "/":
                state = 2
                out.append("  ")
                i += 1
            elif c == "/" and i + 1 < n and text[i + 1] == "*":
                state = 3
                out.append("  ")
                i += 1
            else:
                out.append(c)
        elif state == 1:
            if c == '"':
                state = 0
            out.append("\n" if c == "\n" else " ")
        elif state == 2:
            if c == "\n":
                state = 0
                out.append("\n")
            else:
                out.append(" ")
        else:  # block comment
            if c == "*" and i + 1 < n and text[i + 1] == "/":
                state = 0
                out.append("  ")
                i += 1
            else:
                out.append("\n" if c == "\n" else " ")
        i += 1
    return "".join(out)


def rdl_preprocess(text: str) -> str:
    """Evaluate `ifdef/`ifndef/`else/`endif with an EMPTY define set (full
    profile): `ifdef branches are dropped, `ifndef branches are taken.
    Inactive lines are blanked (line numbers preserved)."""
    out = []
    active = []  # per open conditional: is the current branch active
    taken = []   # per open conditional: has an active branch been emitted
    for line in text.split("\n"):
        s = line.strip()
        m = re.match(r"`(ifdef|ifndef|else|endif)\b", s)
        if m:
            d = m.group(1)
            if d == "ifdef":
                active.append(False)
                taken.append(False)
            elif d == "ifndef":
                active.append(True)
                taken.append(True)
            elif d == "else":
                if active:
                    active[-1] = not taken[-1]
                    taken[-1] = True
            elif d == "endif":
                if active:
                    active.pop()
                    taken.pop()
            out.append("")
            continue
        if s.startswith("`include"):
            out.append("")
            continue
        out.append(line if all(active) else "")
    return "\n".join(out)


class Scope:
    __slots__ = ("kind", "name", "children", "fields", "offset", "line")

    def __init__(self, kind, name=None, line=0):
        self.kind = kind
        self.name = name
        self.children = []
        self.fields = []  # (name, bits_raw, reset_raw, line)
        self.offset = None
        self.line = line


KINDS = {"addrmap", "regfile", "reg", "field", "mem", "enum"}


def parse_rdl(path: Path):
    """Parse the full-profile view of the RDL into
    (fields:  {dotted_path: (reset, bits, reg_offset, line)},
     regs:    {dotted_path: (offset, line)},
     anchors: {dotted_path: (offset, line)}  -- `->ispresent = false`
              type anchors: valid reference targets, NOT live CSRs,
     mems:    {name: (type_name, offset, line)} -- external memory
              instances such as `external act_st_mem_t watchpoints @..`)."""
    raw = path.read_text(encoding="utf-8")
    text = rdl_preprocess(rdl_clean(raw))
    nl = [m.start() for m in re.finditer("\n", text)]

    def line_of(pos):
        lo, hi = 0, len(nl)
        while lo < hi:
            mid = (lo + hi) // 2
            if nl[mid] < pos:
                lo = mid + 1
            else:
                hi = mid
        return lo + 1

    root = Scope("root")
    stack = [root]
    awaiting = None  # scope just closed, waiting for its name tail
    mem_instances = {}
    anchor_names = set()
    prev = 0
    for m in re.finditer(r"[{};]", text):
        seg = text[prev:m.start()]
        punct = m.group(0)
        pos = m.start()
        prev = m.end()
        if punct == "{":
            tokens = re.findall(r"[\w#().]+", seg)
            kind = tokens[0] if tokens and tokens[0] in KINDS else "anon"
            name = None
            if kind in ("mem", "enum") and len(tokens) > 1:
                name = tokens[1]
            sc = Scope(kind, name, line_of(pos))
            stack[-1].children.append(sc)
            stack.append(sc)
            awaiting = None
        elif punct == "}":
            if len(stack) > 1:
                awaiting = stack.pop()
            else:
                awaiting = None
        else:  # ';'
            seg = seg.strip()
            if awaiting is not None:
                sc = awaiting
                awaiting = None
                if sc.kind == "field":
                    fm = re.match(r"^(\w+)\s*\[([^\]]*)\]\s*(?:=\s*(.+))?$", seg)
                    if fm:
                        stack[-1].fields.append(
                            (fm.group(1), fm.group(2).strip(),
                             (fm.group(3) or "").strip(), line_of(pos)))
                elif sc.kind in ("reg", "regfile", "addrmap"):
                    rm = re.match(r"^(\w+)\s*(?:\[[^\]]*\])?\s*@\s*(0x[0-9A-Fa-f]+|\d+)", seg)
                    if rm:
                        sc.name = rm.group(1)
                        sc.offset = int(rm.group(2), 0)
                # enums / anon: no instance name needed
            else:
                # bare statements: named-type memory instantiations and
                # the ispresent=false type-anchor marker are modelled;
                # other dynamic property assignments are ignored.
                em = re.match(r"^external\s+(\w+)\s+(\w+)\s*(?:\[[^\]]*\])?"
                              r"\s*@\s*(0x[0-9A-Fa-f]+|\d+)", seg)
                if em:
                    mem_instances[em.group(2)] = (em.group(1),
                                                  int(em.group(3), 0),
                                                  line_of(pos))
                am_ = re.match(r"^(\w+)\s*->\s*ispresent\s*=\s*false\b", seg)
                if am_:
                    anchor_names.add(am_.group(1))

    fields, regs = {}, {}

    def walk(scope, prefix):
        for ch in scope.children:
            if ch.kind in ("reg", "regfile", "mem"):
                name = ch.name or ""
                path_ = f"{prefix}.{name}" if prefix and name else (name or prefix)
                if ch.kind in ("reg", "regfile") and name:
                    # regfile arrays (trTeFilter[], trTeComp[]) are valid
                    # addressable doc references, same as plain registers.
                    regs[path_] = (ch.offset, ch.line)
                for fname, bits, reset, fline in ch.fields:
                    fields[f"{path_}.{fname}"] = (reset, bits, ch.offset, fline)
                walk(ch, path_)
            elif ch.kind in ("addrmap", "root", "anon"):
                walk(ch, prefix)
            # enums: skip entirely

    walk(root, "")
    # `->ispresent = false` registers: move into the type-anchor category
    # (valid reference targets, hidden from the live CSR map).
    anchors = {}
    for key in [k for k in regs if k.split(".")[-1] in anchor_names]:
        anchors[key] = regs.pop(key)
    return fields, regs, anchors, mem_instances


def norm_reset(s):
    s = (s or "").strip()
    m = re.match(r"^(\d+)'([bdhBDH])([0-9a-fA-F_xz]+)$", s)
    if m:
        base = {"b": 2, "d": 10, "h": 16}[m.group(2).lower()]
        try:
            return int(m.group(3).replace("_", ""), base)
        except ValueError:
            return s
    if re.match(r"^0x[0-9a-fA-F]+$", s):
        return int(s, 16)
    if re.match(r"^\d+$", s):
        return int(s)
    return s  # parameterized reset (e.g. NUM_TRACE_FILTER)


# ---------------------------------------------------------------------------
# E. ENAB packing (cfg_enab in ct_L2_nexus_formatter.sv)
# ---------------------------------------------------------------------------

def parse_enab(text: str):
    """Parse the cfg_enab `CFG_CAPS & {...}` concatenation into a list of
    (bit, name, normalized_expr, has_caps_marker) in SOURCE order (MSB
    first); the per-line `// <bit> <NAME> [= CAPS]` comments carry the
    bit positions. Returns None if the packing is not found."""
    m = re.search(r"cfg_enab\s*=\s*!ct_pkg::CT_EN_CONFIG_MSG\s*\?\s*'0\s*:"
                  r"\s*CFG_CAPS\s*&\s*\{(.*?)\}\s*;", text, re.S)
    if not m:
        return None
    entries = []
    for line in m.group(1).splitlines():
        if "//" not in line:
            continue
        code, comment = line.split("//", 1)
        expr = code.strip().rstrip(",").strip()
        cm = re.match(r"\s*(\d+)\s+(\w+)(.*)$", comment)
        if not cm or not expr:
            continue
        entries.append((int(cm.group(1)), cm.group(2),
                        re.sub(r"\s+", "", expr),
                        bool(re.search(r"=\s*CAPS", cm.group(3)))))
    return entries


# ---------------------------------------------------------------------------
# D. documentation tables
# ---------------------------------------------------------------------------

BACKTICK_CT = re.compile(r"`(CT_[A-Z0-9_]+)`")
DOTTED_REF = re.compile(r"`([A-Za-z]\w*(?:\.\w+)+)`")
# Any backticked identifier, optionally with array/memory `[]` syntax --
# dotted refs AND bare register/memory names.
REF_RE = re.compile(r"`([A-Za-z][\w.]*?)(\[\])?`")
ANNOT = re.compile(r"0x([0-9A-Fa-f]+)(?:\[(\d+)(?::(\d+))?\])?")


def split_row(line):
    return [c.strip() for c in line.split("|")[1:]]


def parse_matrix(lines):
    """Locate the 7-column capability matrix in trace-format.adoc.
    Returns list of (line_no, cells) data rows; structural checks inline."""
    rows = []
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith("| Capability / message (TCODE)"):
            start = i
            break
    if start is None:
        fail("matrix", "capability-matrix header not found", f"{DOC_TF}:1")
        return rows
    header = split_row(lines[start])
    if len(header) != 7:
        fail("matrix", f"header has {len(header)} columns, expected 7",
             f"{DOC_TF}:{start + 1}")
    i = start + 1
    while i < len(lines):
        ln = lines[i].rstrip()
        if ln.startswith("|==="):
            break
        gm = re.match(r"^(\d+)\+s\|", ln)
        if gm:
            if gm.group(1) != "7":
                fail("matrix", f"group row spans {gm.group(1)} columns, expected 7+s",
                     f"{DOC_TF}:{i + 1}")
        elif ln.startswith("|"):
            cells = split_row(ln)
            if len(cells) != 7:
                fail("matrix", f"data row has {len(cells)} cells, expected 7",
                     f"{DOC_TF}:{i + 1}")
            else:
                rows.append((i + 1, cells))
        i += 1
    else:
        fail("matrix", "capability matrix is not closed with |===",
             f"{DOC_TF}:{start + 1}")
    return rows


def find_section(lines, anchor, fname):
    """Return (start, end) line index range of the section marked [#anchor]."""
    start = None
    for i, ln in enumerate(lines):
        if ln.strip() == f"[#{anchor}]":
            start = i
            break
    if start is None:
        fail("doc", f"section anchor [#{anchor}] not found", f"{fname}:1")
        return None
    end = len(lines)
    for i in range(start + 2, len(lines)):  # skip the == heading itself
        if re.match(r"^== ", lines[i]):
            end = i
            break
    return start, end


def parse_flag_table(lines, start, end):
    """Rows of the #feature-flags table: (line_no, cells)."""
    rows = []
    hdr = None
    for i in range(start, end):
        if lines[i].startswith("| Build switch"):
            hdr = i
            break
    if hdr is None:
        fail("flagtable", "flag-table header not found",
             f"{DOC_INT}:{start + 1}")
        return rows
    if len(split_row(lines[hdr])) != 7:
        fail("flagtable", "flag-table header must have 7 columns",
             f"{DOC_INT}:{hdr + 1}")
    for i in range(hdr + 1, end):
        ln = lines[i].rstrip()
        if ln.startswith("|==="):
            break
        if not ln.startswith("|"):
            continue
        cells = split_row(ln)
        if len(cells) != 7:
            fail("flagtable", f"row has {len(cells)} cells, expected 7",
                 f"{DOC_INT}:{i + 1}")
            continue
        rows.append((i + 1, cells))
    return rows


def parse_enh_table(lines):
    """Rows of the enhanced-features compression-suite table
    (Feature | Build switch | Enable | Effect): (line_no, cells)."""
    rows = []
    hdr = None
    for i, ln in enumerate(lines):
        if ln.startswith("| Feature | Build switch"):
            hdr = i
            break
    if hdr is None:
        fail("enhtable", "compression-suite table header not found",
             f"{DOC_ENH}:1")
        return rows
    for i in range(hdr + 1, len(lines)):
        ln = lines[i].rstrip()
        if ln.startswith("|==="):
            break
        if not ln.startswith("|"):
            continue
        cells = split_row(ln)
        if len(cells) != 4:
            fail("enhtable", f"row has {len(cells)} cells, expected 4",
                 f"{DOC_ENH}:{i + 1}")
            continue
        rows.append((i + 1, cells))
    return rows


def suffix_find(table, ref):
    """Suffix-match `ref` against a dotted-path dict; return payload or None."""
    for full in table:
        if full == ref or full.endswith("." + ref):
            return table[full]
    return None


def check_rdl_ref_cell(cell, rdl, where):
    """Validate EVERY backticked RDL reference of a cell:
      - dotted `reg.field` refs must exist in the full-profile RDL;
      - bare names are validated when they follow the register naming
        convention (`tr` + uppercase) or use array/memory `[]` syntax --
        registers, external memories and `->ispresent = false` type
        anchors are all valid reference targets (separate categories);
      - each ref's 0xOFF[hi:lo] annotation (the text between the ref and
        the next backtick) is checked against the RDL register offset /
        field bit range -- for ALL refs, not only the first.
    Other bare names (field-name continuations such as `InstSyncMax`,
    command mnemonics such as `CF_SYNC`) are skipped -- known limit G3.
    Returns the first resolved FIELD payload (for the reset check)."""
    fields, regs, anchors, mems = rdl
    if cell.startswith("—") or cell == "-":
        return None
    first_payload = None
    for m in REF_RE.finditer(cell):
        name, brackets = m.group(1), m.group(2)
        kind = payload = rdl_off = None
        if "." in name:
            for table, k in ((fields, "field"), (regs, "reg"),
                             (anchors, "anchor")):
                data = suffix_find(table, name)
                if data is not None:
                    kind = k
                    payload = data
                    rdl_off = data[2] if k == "field" else data[0]
                    break
            if kind is None:
                fail("rdl-ref", f"`{name}` does not exist in the "
                     f"full-profile RDL", where)
                continue
        elif name.startswith("CT_"):
            continue  # build-switch tokens are checked separately
        elif re.match(r"tr[A-Z]", name) or brackets:
            if name in mems:
                kind = "mem"
                rdl_off = mems[name][1]
            else:
                for table, k in ((regs, "reg"), (anchors, "anchor")):
                    data = suffix_find(table, name)
                    if data is not None:
                        kind = k
                        rdl_off = data[0]
                        break
            if kind is None:
                fail("rdl-ref", f"`{name}` is not a register/memory/type "
                     f"anchor in the full-profile RDL", where)
                continue
        else:
            continue  # known limit G3 (see module docstring)
        # annotation directly after THIS ref, up to the next backtick
        am = ANNOT.search(cell[m.end():].split("`")[0])
        if am:
            doc_off = int(am.group(1), 16)
            if rdl_off is not None and doc_off != rdl_off:
                fail("offset", f"`{name}` documented @0x{doc_off:03X}, "
                     f"RDL says @0x{rdl_off:03X}", where)
            if am.group(2) is not None and kind == "field":
                hi = int(am.group(2))
                lo = int(am.group(3)) if am.group(3) is not None else hi
                bm = re.match(r"^(\d+)\s*:\s*(\d+)$", payload[1])
                if bm and (hi, lo) != (int(bm.group(1)), int(bm.group(2))):
                    fail("bits", f"`{name}` documented [{hi}:{lo}], "
                         f"RDL says [{payload[1]}]", where)
        if kind == "field" and first_payload is None:
            first_payload = payload
    return first_payload


def main() -> int:
    pkg_text = CT_PKG.read_text(encoding="utf-8")
    bit_switches, broad = parse_ct_pkg(pkg_text)
    if not bit_switches:
        fail("ct_pkg", "no CT_EN_* bit switches found", str(CT_PKG))

    # CT_SIJUMP is an elaboration parameter of ct_encoder, not a ct_pkg
    # localparam -- verify it really exists before accepting doc mentions.
    # Integration attributes: ct_encoder PARAMETERS, not ct_pkg switches --
    # per-instance values (a multi-encoder SoC gives each encoder its own),
    # so the matrix may name them in a Build-switch cell.
    if CT_ENCODER.exists():
        enc_text = CT_ENCODER.read_text(encoding="utf-8")
        for attr in ("CT_SIJUMP", "CT_DEVICE_ID"):
            if re.search(rf"\b{attr}\b", enc_text):
                broad.add(attr)

    caps, caps_width = parse_caps(pkg_text)

    # CAPS width vs the vendor package constant
    vm = re.search(r"NEXUS_MSG_CFG_CAPS_WIDTH\s*=\s*(\d+)\s*;",
                   VENDOR_PKG.read_text(encoding="utf-8"))
    if not vm:
        fail("caps", "NEXUS_MSG_CFG_CAPS_WIDTH not found", str(VENDOR_PKG))
    else:
        if int(vm.group(1)) != caps_width:
            fail("caps", f"ct_cfgmsg_caps() width {caps_width} != "
                 f"NEXUS_MSG_CFG_CAPS_WIDTH {vm.group(1)}", str(VENDOR_PKG))
    missing_bits = [b for b in range(caps_width) if b not in caps]
    if missing_bits:
        fail("caps", f"bits without map entry: {missing_bits}", str(CT_PKG))
    extra_bits = [b for b in caps if b >= caps_width]
    if extra_bits:
        fail("caps", f"bits beyond width {caps_width}: {extra_bits}", str(CT_PKG))

    fields, regs, anchors, mems = parse_rdl(RDL)
    rdl = (fields, regs, anchors, mems)
    if not fields:
        fail("rdl", "no fields parsed from the RDL", str(RDL))

    # --- ENAB packing (cfg_enab) vs CAPS map vs expectation table -----------
    enab = parse_enab(FORMATTER.read_text(encoding="utf-8"))
    if enab is None:
        fail("enab", "cfg_enab CFG_CAPS & {...} concatenation not found",
             str(FORMATTER))
    else:
        bits_in_order = [b for b, _n, _e, _c in enab]
        if bits_in_order != sorted(bits_in_order, reverse=True):
            fail("enab", f"concatenation is not MSB-first descending: "
                 f"{bits_in_order}", str(FORMATTER))
        if set(bits_in_order) != set(range(caps_width)):
            fail("enab", f"bits covered {sorted(set(bits_in_order))} != "
                 f"0..{caps_width - 1}", str(FORMATTER))
        if set(ENAB_EXPECT) != set(range(caps_width)):
            fail("enab", f"ENAB_EXPECT covers {sorted(ENAB_EXPECT)} != "
                 f"0..{caps_width - 1} -- update the expectation table",
                 "scripts/check_feature_flags.py")
        for bit, name, expr, caps_marker in enab:
            if bit in caps and caps[bit][0] != name:
                fail("enab", f"bit {bit}: comment name '{name}' != CAPS map "
                     f"name '{caps[bit][0]}'", str(FORMATTER))
            exp = ENAB_EXPECT.get(bit)
            if exp is not None and expr != exp.replace(" ", ""):
                fail("enab", f"bit {bit} ({name}): source is '{expr}', "
                     f"expected '{exp}'", str(FORMATTER))
            if (expr == "1'b1") != (bit in ENAB_TIEOFF):
                fail("enab", f"bit {bit} ({name}): tie-off/runtime mismatch "
                     f"(1'b1 expected exactly for bits "
                     f"{sorted(ENAB_TIEOFF)})", str(FORMATTER))
            if caps_marker != (bit in ENAB_TIEOFF):
                fail("enab", f"bit {bit} ({name}): '= CAPS' comment marker "
                     f"{'missing' if bit in ENAB_TIEOFF else 'unexpected'}",
                     str(FORMATTER))
        # Guard the expectation table itself against going stale: every
        # runtime source must be a cs_proc.trTe*/trTs* signal whose field
        # name (prefix stripped) exists in the RDL.
        for bit in sorted(ENAB_EXPECT):
            exp = ENAB_EXPECT[bit]
            if exp == "1'b1":
                continue
            if exp == "1'b0":
                # Reserved placeholder bit (P4 reserve): constant 0 in CAPS
                # and ENAB alike -- no RDL field to cross-check yet.
                continue
            # A source is either a plain cs_proc signal or an expression
            # over cs_proc signals (QUOTA_SYNC's mode comparison): every
            # referenced field must exist in the RDL, and at least one
            # must be referenced (guards the table against going stale).
            # Prefixes: trTe/trTs (encoder + timestamp component) and trWp
            # (watchpoints component, P4 -- trWpMask.WEM).
            refs = re.findall(r"cs_proc\.tr(?:Te|Ts|Wp)(\w+)", exp)
            if not refs:
                fail("enab", f"expectation table bit {bit}: '{exp}' is "
                     f"neither 1'b1 nor an expression over "
                     f"cs_proc.trTe*/trTs* signals",
                     "scripts/check_feature_flags.py")
            for ref in refs:
                if suffix_find(fields, ref) is None:
                    fail("enab", f"expectation table bit {bit}: no RDL field "
                         f"named '{ref}' (stale table?)",
                         "scripts/check_feature_flags.py")

    tf_lines = DOC_TF.read_text(encoding="utf-8").split("\n")
    int_lines = DOC_INT.read_text(encoding="utf-8").split("\n")
    enh_lines = DOC_ENH.read_text(encoding="utf-8").split("\n")

    # --- trace-format matrix ------------------------------------------------
    matrix_rows = parse_matrix(tf_lines)
    matrix_build_tokens = set()
    for lno, cells in matrix_rows:
        where = f"{DOC_TF}:{lno}"
        build, runtime, caps_cell = cells[4], cells[5], cells[6]
        build_tokens = BACKTICK_CT.findall(build)
        matrix_build_tokens.update(build_tokens)
        for tok in build_tokens:
            if tok not in broad and tok not in DERIVED_SWITCHES \
                    and tok not in PROFILE_DEFINES:
                fail("token", f"`{tok}` not found in ct_pkg.sv/ct_encoder.sv "
                     f"or the gen_rdl_profile.py define map", where)
        check_rdl_ref_cell(runtime, rdl, where)
        rm_ = re.match(r"^(\d+)\s*[–-]\s*(\d+)$", caps_cell)
        if rm_:
            # Range cell (e.g. the sync-reasons row `10–14`): every bit must
            # be mapped, and each bit's driving switch named in the row.
            for bit in range(int(rm_.group(1)), int(rm_.group(2)) + 1):
                if bit not in caps:
                    fail("caps", f"row claims CAPS bits {caps_cell}, but bit "
                         f"{bit} is unmapped in ct_cfgmsg_caps()", where)
                elif caps[bit][1] and not (caps[bit][1] & set(build_tokens)):
                    fail("caps", f"row claims CAPS bit {bit} ({caps[bit][0]}), "
                         f"but none of its switches {sorted(caps[bit][1])} is "
                         f"named in the row's Build cell", where)
        cm = re.match(r"^(\d+)$", caps_cell)
        if cm:
            bit = int(cm.group(1))
            if bit not in caps:
                fail("caps", f"row claims CAPS bit {bit}, which is unmapped", where)
            else:
                expr = caps[bit][1]
                en_tokens = [t for t in build_tokens if t.startswith("CT_EN_")]
                if en_tokens:
                    if not any(t in expr for t in en_tokens):
                        fail("caps", f"row claims CAPS bit {bit} "
                             f"({caps[bit][0]}), but its expression uses "
                             f"{sorted(expr)}, not {en_tokens}", where)
                elif expr:
                    fail("caps", f"row claims CAPS bit {bit} without naming "
                         f"one of its switches {sorted(expr)}", where)

    # --- every CAPS-driving switch must appear in the matrix Build column ---
    for bit in sorted(caps):
        name, expr = caps[bit]
        for tok in sorted(expr):
            if tok not in matrix_build_tokens:
                fail("caps-matrix", f"CAPS bit {bit} ({name}): switch {tok} "
                     f"does not appear in any Build-switch cell of the "
                     f"capability matrix", str(DOC_TF))
    # The parameter/knob-driven bits (PARAM_CAPS) have an empty expression,
    # so the loop above cannot cover them -- name them explicitly.
    for bit, tok in sorted(PARAM_CAPS.items()):
        if bit not in caps:
            continue
        if tok in broad and tok not in matrix_build_tokens:
            fail("caps-matrix", f"CAPS bit {bit} ({caps[bit][0]}): {tok} does "
                 f"not appear in any Build-switch cell of the capability "
                 f"matrix", str(DOC_TF))

    # --- config-message CAPS bit-name list ----------------------------------
    for i, ln in enumerate(tf_lines):
        if ln.startswith("| `CAPS`"):
            doc_bits = dict((int(b), n) for b, n in
                            re.findall(r"(\d+)\s+([A-Z][A-Z0-9_]*)", ln))
            for bit, (name, _t) in caps.items():
                if doc_bits.get(bit) != name:
                    fail("caps", f"config-message CAPS list: bit {bit} is "
                         f"'{doc_bits.get(bit)}', ct_cfgmsg_caps() says '{name}'",
                         f"{DOC_TF}:{i + 1}")
            break

    # --- integration #feature-flags -----------------------------------------
    flag_first_ref = {}  # switch -> first dotted RDL ref of its Runtime cell
    sec = find_section(int_lines, "feature-flags", DOC_INT)
    if sec:
        s, e = sec
        section_text = "\n".join(int_lines[s:e])
        for tok in set(BACKTICK_CT.findall(section_text)):
            if tok not in broad and tok not in DERIVED_SWITCHES \
                    and tok not in PROFILE_DEFINES:
                fail("token", f"`{tok}` not found in ct_pkg.sv/ct_encoder.sv "
                     f"or the gen_rdl_profile.py define map",
                     f"{DOC_INT}:{s + 1}")

        rows = parse_flag_table(int_lines, s, e)
        seen = {}
        claimed = {}  # caps bit -> [(switch, line)]
        for lno, cells in rows:
            where = f"{DOC_INT}:{lno}"
            sm = re.match(r"^`(CT_\w+)`", cells[0])
            if not sm:
                fail("flagtable", "first cell must be a backticked CT_* switch", where)
                continue
            sw = sm.group(1)
            if sw in seen:
                fail("flagtable", f"duplicate row for {sw}", where)
            seen[sw] = lno
            if sw not in bit_switches:
                fail("flagtable", f"{sw} is not a CT_EN_* bit switch in ct_pkg.sv",
                     where)
                continue
            # Default-full column vs ct_pkg value
            fm = re.match(r"^([01])$", cells[4])
            if not fm:
                fail("flagtable", f"{sw}: Default-full cell must be 0 or 1", where)
            elif int(fm.group(1)) != bit_switches[sw]:
                fail("flagtable", f"{sw}: Default full documented {fm.group(1)}, "
                     f"ct_pkg.sv says {bit_switches[sw]}", where)
            # RDL reference + offset/bits + reset
            payload = check_rdl_ref_cell(cells[1], rdl, where)
            fr = DOTTED_REF.search(cells[1])
            if fr and not cells[1].startswith("—"):
                flag_first_ref[sw] = fr.group(1)
            rm = re.match(r"^(\d+)", cells[2])
            if rm and payload is not None:
                doc_reset = int(rm.group(1))
                rdl_reset = norm_reset(payload[0])
                if isinstance(rdl_reset, int) and doc_reset != rdl_reset:
                    fail("reset", f"{sw}: documented reset {doc_reset}, "
                         f"RDL says {rdl_reset}", where)
            elif rm and payload is None and not cells[1].startswith("—"):
                fail("reset", f"{sw}: reset given but no resolvable RDL field",
                     where)
            # CAPS column
            cm = re.match(r"^(\d+)", cells[3])
            if cm:
                bit = int(cm.group(1))
                claimed.setdefault(bit, []).append((sw, lno))
                if bit not in caps:
                    fail("caps", f"{sw} claims unmapped CAPS bit {bit}", where)
                elif sw not in caps[bit][1]:
                    fail("caps", f"{sw} claims CAPS bit {bit} ({caps[bit][0]}), "
                         f"but the bit expression uses {sorted(caps[bit][1])}",
                         where)
            else:
                # '--' rows: the switch must NOT drive any CAPS bit
                for bit, (name, expr) in caps.items():
                    if sw in expr:
                        fail("caps", f"{sw} drives CAPS bit {bit} ({name}) but "
                             f"documents '—'", where)

        # switch <-> row completeness (both directions)
        for sw in sorted(bit_switches):
            if sw in DERIVED_SWITCHES:
                continue
            if sw not in seen:
                fail("coverage", f"{sw} has no row in the integration flag table",
                     f"{DOC_INT}:{s + 1}")
        # CAPS coverage: every mapped bit is claimed by a row naming one of
        # its switches; parameter-driven bits (no CT_EN_* in the expression,
        # i.e. SIJUMP) must at least be mentioned in the section.
        for bit, (name, expr) in sorted(caps.items()):
            if expr:
                ok = any(sw in expr for sw, _l in claimed.get(bit, []))
                if not ok:
                    fail("coverage", f"CAPS bit {bit} ({name}) is not claimed by "
                         f"any flag-table row", f"{DOC_INT}:{s + 1}")
            else:
                tok = PARAM_CAPS.get(bit)
                if tok is None:
                    fail("coverage", f"CAPS bit {bit} ({name}) is driven by no "
                         f"CT_EN_* switch and has no entry in PARAM_CAPS -- "
                         f"name the identifier that drives it",
                         "scripts/check_feature_flags.py")
                elif tok not in section_text:
                    fail("coverage", f"CAPS bit {bit} ({name}) is driven by "
                         f"{tok}, which is not documented in the section",
                         f"{DOC_INT}:{s + 1}")

    # --- enhanced-features compression-suite table --------------------------
    enh_rows = parse_enh_table(enh_lines)
    for lno, cells in enh_rows:
        where = f"{DOC_ENH}:{lno}"
        bm_ = re.match(r"^`(CT_\w+)`$", cells[1].strip())
        if not bm_:
            fail("enhtable", "Build-switch cell must be exactly one "
                 "backticked CT_* switch", where)
            continue
        sw = bm_.group(1)
        if sw not in bit_switches or sw in DERIVED_SWITCHES:
            fail("enhtable", f"{sw} is not a CT_EN_* bit switch in ct_pkg.sv",
                 where)
            continue
        em_ = re.match(r"^`(\w+)`$", cells[2].strip())
        if not em_:
            fail("enhtable", "Enable cell must be exactly one backticked "
                 "field name", where)
            continue
        fieldname = em_.group(1)
        if suffix_find(fields, f"trTeInstFeatures.{fieldname}") is None:
            fail("enhtable", f"{sw}: enable field `{fieldname}` does not "
                 f"exist in trTeInstFeatures (full-profile RDL)", where)
        int_ref = flag_first_ref.get(sw)
        if int_ref and int_ref.split(".")[-1] != fieldname:
            fail("enhtable", f"{sw}: enable `{fieldname}` != integration "
                 f"flag-table field `{int_ref}`", where)

    # ---------------------------------------------------------------------
    if failures:
        for f_ in failures:
            print(f_)
        print(f"[check_feature_flags] {len(failures)} failure(s)")
        return 1
    print(f"[check_feature_flags] OK: {len(bit_switches)} CT_EN_* switches, "
          f"{len(fields)} RDL fields ({len(anchors)} type anchor(s), "
          f"{len(mems)} external memory(ies)), CAPS width {caps_width}, "
          f"ENAB {len(enab) if enab else 0} bits, {len(matrix_rows)} matrix + "
          f"{len(enh_rows)} compression-table rows checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
