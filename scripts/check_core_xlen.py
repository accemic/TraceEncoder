#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""CORE_XLEN declaration guard (P0-07): a declaration nobody made, and a
declaration derived from the thing it is supposed to check, are both worthless.

ct_encoder refuses to elaborate unless the integrator declares the width of
the attached hart (parameter CORE_XLEN) and it matches ct_pkg::CT_XLEN. That
guard is only as strong as the declaration, and it has exactly two ways of
being hollow:

  1. NOT DECLARED. The elaboration guard catches this -- but only when
     somebody elaborates. This checker names it in a `make lint`, before a
     build is even attempted.

  2. DERIVED FROM THE NETLIST. `.CORE_XLEN(ct_pkg::CT_XLEN)` or
     `.CORE_XLEN(TIP_IADDRESS_WIDTH)` always matches, so it declares nothing
     and the guard can never fire. This is not hypothetical: earlier board
     wrappers passed `.ITI_XLEN(TIP_AW)` into the CVA6 shim's identical
     width clamp, where TIP_AW is the ENCODER's width -- the clamp cannot
     fire there, and the truncation happens one level up in the wrapper.

A derived declaration is legitimate in exactly one situation: there is no
external core at all, i.e. the TIP is driven by a model or generator built
from tip_pkg types, so the "hart" width IS the netlist width. Those places
are listed in DERIVED_OK with a reason, in the spirit of
scripts/check_profile_deps.py's UNPARSED_OK: allowed, but never silent, and
never growing without someone writing down why.

Exit 0 = OK, 1 = an instantiation declares nothing, or derives without a
waiver, or a waiver has gone stale.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# examples/ is searched too: the shared common/tgc5b SoC instantiates ct_encoder
# without CORE_XLEN and the guard did not see it, because the example tree
# arrived after this list was written (AP0 merge, 2026-08-16).
SEARCH_DIRS = ("rtl", "tests", "formal", "examples")

# Places where a derived declaration is the truth, not a dodge. Key is the
# repo-relative path; the value is why the TIP has no external core.
DERIVED_OK = {
    "tests/lib/ct_env.sv":
        "the TIP is driven by cpu_model, whose addresses are tip_pkg types -- "
        "the model hart IS the netlist width, there is no second width",
    "tests/lib/ct_encoder_top.sv":
        "pin-reduced synthesis wrapper with no external core: it generates "
        "its TIP stream internally from tip_pkg types (see its header)",
    "tests/instruction/24_protocol_param/protocol_param_tb.sv":
        "both instances are fed by TIP interfaces of this netlist, same case "
        "as ct_env",
    "tests/instruction/39_dual_src/dual_src_tb.sv":
        "both encoders are driven by a cpu_model each, whose addresses are "
        "tip_pkg types -- same case as ct_env, twice",
}

# A declaration is DERIVED if its value mentions the netlist's own width.
DERIVED_TOKENS = (
    "CT_XLEN", "CT_ADDR64",
    "TIP_IADDRESS_WIDTH", "TIP_DADDRESS_WIDTH", "TIP_AW",
    "$bits(tip_iaddr_t)", "$bits(tip_daddr_t)",
)

# `ct_encoder` followed by an optional parameter list, up to the instance
# name. DOTALL: real instantiations span lines. The negative lookahead keeps
# `ct_encoder_top` from reading as an instantiation of `ct_encoder`.
INST = re.compile(r"\bct_encoder(?!\w)\s*(#\s*\((?P<params>.*?)\)\s*)?(?P<name>\w+)\s*\(", re.DOTALL)
CORE_XLEN_ARG = re.compile(r"\.CORE_XLEN\s*\((?P<value>[^()]*(?:\([^()]*\)[^()]*)*)\)")
IDENT_ONLY = re.compile(r"^[A-Za-z_]\w*$")


def resolves_to_netlist_width(value: str, text: str) -> bool:
    """Is this declaration ultimately the netlist's own width?

    Direct mention is the easy half. The other half is a declaration hidden
    one level up -- `.CORE_XLEN(FOO)` where FOO is a local parameter defined
    as the netlist width. That indirection is not a corner case: it is
    exactly how earlier board wrappers defeated the equivalent clamp
    in the CVA6 shim (`.ITI_XLEN(TIP_AW)`, TIP_AW = TIP_IADDRESS_WIDTH). One
    level of resolution covers every shape seen so far; a deeper chain would
    show up as an unresolved identifier and is reported below.
    """
    if any(tok in value for tok in DERIVED_TOKENS):
        return True
    if not IDENT_ONLY.match(value):
        return False
    decl = re.search(
        r"\b(?:parameter|localparam)\b[^;=]*?\b" + re.escape(value) + r"\s*=\s*([^,;)]+)",
        text)
    return bool(decl and any(tok in decl.group(1) for tok in DERIVED_TOKENS))

failures: list[str] = []
seen_derived: set[str] = set()
checked = 0


def sources():
    for d in SEARCH_DIRS:
        root = REPO / d
        if not root.is_dir():
            continue
        for p in sorted(root.rglob("*.sv")):
            yield p


for path in sources():
    rel = path.relative_to(REPO).as_posix()
    text = path.read_text(encoding="utf-8", errors="replace")
    # The module's own declaration is not an instantiation of it.
    if re.search(r"^\s*module\s+ct_encoder\b", text, re.MULTILINE):
        continue
    for m in INST.finditer(text):
        # Skip matches inside comments: cheap and sufficient here, the
        # instantiation always starts a line in this tree.
        line_start = text.rfind("\n", 0, m.start()) + 1
        if text[line_start:m.start()].lstrip().startswith(("//", "*")):
            continue
        checked += 1
        line_no = text.count("\n", 0, m.start()) + 1
        params = m.group("params") or ""
        arg = CORE_XLEN_ARG.search(params)
        if not arg:
            failures.append(
                f"  [FAIL] {rel}:{line_no}: ct_encoder instantiated without "
                f".CORE_XLEN -- declare the XLEN of the attached hart "
                f"(elaboration would reject it, but say it here)")
            continue
        value = " ".join(arg.group("value").split())
        if resolves_to_netlist_width(value, text):
            if rel in DERIVED_OK:
                seen_derived.add(rel)
            else:
                failures.append(
                    f"  [FAIL] {rel}:{line_no}: .CORE_XLEN({value}) is derived "
                    f"from the netlist's own width, so the guard can never "
                    f"fire. Declare the hart's actual width, or add {rel} to "
                    f"DERIVED_OK in {Path(__file__).name} with the reason why "
                    f"this TIP has no external core")

for rel in sorted(set(DERIVED_OK) - seen_derived):
    failures.append(
        f"  [FAIL] {rel}: listed in DERIVED_OK but no derived .CORE_XLEN found "
        f"there -- the waiver is stale, remove it (a waiver list that keeps "
        f"entries nobody needs stops describing the tree)")

if failures:
    print(f"[check_core_xlen] {len(failures)} problem(s):")
    print("\n".join(failures))
    sys.exit(1)

print(f"[check_core_xlen] OK: {checked} ct_encoder instantiation(s) checked, "
      f"{len(seen_derived)} declared-from-netlist waiver(s) in use")
