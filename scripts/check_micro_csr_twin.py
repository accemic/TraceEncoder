#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Micro-CSR twin drift guard: the hand-written register block reads back
every field at the SAME bit width as the generated one.

`rtl/pkg/ct_cs_micro.sv` is a hand-written drop-in replacement for the
PeakRDL-generated `rtl/pkg/ct_cs_cpuif.sv`, selected by ct_pkg::CT_MICRO_CSR
in CONTROL-FLOW-ONLY slim profiles. Its module header promises
"byte-identical values" -- but nothing enforced that promise, and no build in
the repository sets CT_MICRO_CSR = 1, so the twin drifts in silence.

It did. P8 widened trTeSyncStatus.SyncReqSource from two to three bits (new
value SYNC_REQ_TE = 4), carried the generated block along and left the twin
at `s_cpuif_rd_data[1:0]`. In SystemVerilog that is a silent truncation: the
new source read back as 0 -- "since reset nobody has asked for a sync" --
and D-P8-2 had made exactly this read-back the ONLY software discovery the
feature has. Measured in xsim by the P8 closing audit (A-N1): driven 4,
read back 0.

Four mechanical checks, all against the generated block as the reference:

  1. WIDTH (target side). For every address the twin decodes, every readback
     slice must have EXACTLY the bounds of a generated field. A slice that
     overlaps a generated field with different bounds is drift -- narrower
     truncates, wider reports bits the register does not have, shifted is a
     decode bug. Fields the twin does not implement at all are fine (that is
     the whole point of the slim block); they simply have no overlapping
     slice.

  1b. WIDTH (source side). The target being wide enough proves nothing if
     the VALUE fed into it is narrow. Both of these pass check 1 and both
     read the new SyncReqSource value 4 back as 0 -- the A-N1 defect in two
     other spellings:

         s_cpuif_rd_data[2:0] = ...SyncReqSource.next[1:0];   // narrowed
         s_cpuif_rd_data[2:0] = 3'd0;                          // constant

     So: a part-select on the right-hand side must have the width of the
     left-hand side, and a literal right-hand side is only accepted where
     the GENERATED block assigns a literal to the same slice too (Format,
     the version nibbles, the timestamp width). The re-check that found
     this said it plainly: a guard that cannot see the narrowed source
     because the target looks wide enough is checking the wrong side.

  2. DECODE. Every address the GENERATED block decodes and the twin does not
     must be listed in WAIVED below with a reason -- and a reason that names
     an elaboration guard is only accepted while that $fatal really is in
     ct_cs_micro.sv. Reading a constant 0 for a register whose hardware is
     BUILT is the "lying discovery answer" P7 already had to guard against
     (trigger configuration block, ct_cs_micro.sv), and A-N1 is the same
     class one register deeper.

  2b. WAIVERS WITHOUT A GUARD. A waiver that names no build switch claims
     instead that the generated block reads a constant 0 at that address as
     well -- so there is nothing to mirror. That claim used to be accepted
     on faith. It is checkable, so it is checked: every readback assignment
     of the generated arm must be a zero literal.

Exit 0 = OK, 1 = drift (with the offending address/slice named).
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

GEN = "rtl/pkg/ct_cs_cpuif.sv"
MICRO = "rtl/pkg/ct_cs_micro.sv"

# Addresses the generated block decodes and the hand-written twin deliberately
# does not. `guard` names a build switch whose $fatal in ct_cs_micro.sv keeps
# the omission honest; `None` means the generated block reads a constant 0
# there too, so there is nothing to mirror.
WAIVED = {
    0x00c: ("trTeInstFilters.Filters", "CT_EN_FILTERS", None),
    0x01c: ("trTeDataFilters.Filters", "CT_EN_DATA_TRACE", None),
    0x050: ("trTeTrigDbgControl.TrigDbgSetup", None,
            "the generated block reads a constant 0 here as well"),
    0x054: ("trTeTrigExtInControl.ExtInAction0", "CT_EN_TRIG_REGS", None),
    0x058: ("trTeTrigExtOutControl.ExtOutEvent0", None,
            "the generated block reads a constant 0 here as well"),
    0xe10: ("trTeTipFifoHistCtrl.RdIdx", "CT_EN_FIFO_HIST", None),
    0xe14: ("trTeTipFifoHistData.Lo/Hi", "CT_EN_FIFO_HIST", None),
    0x4008: ("trWpMask.WEM", "CT_EN_ACT",
             "CT_EN_WATCHPOINT_MSG requires CT_EN_ACT (pinned by "
             "check_profile_deps.py), and CT_EN_ACT is rejected here"),
    # Indirect watchpoint load/readback path (C0b): all six registers exist
    # for the act_st search tree only. Under CT_PROFILE_NO_ACT the writable
    # ones are `->sw = r;` constants and trWpCap.Entries resets to 0
    # (discovery-honest) -- reading 0 IS the truth in every profile the
    # twin is legal in, and the twin's own $fatal rejects CT_EN_ACT.
    0x400c: ("trWpIndex.Idx", "CT_EN_ACT", None),
    0x4010: ("trWpDataLow.Value", "CT_EN_ACT", None),
    0x4014: ("trWpDataHigh.Cmd/Sink/DirectData", "CT_EN_ACT", None),
    0x4018: ("trWpReadLow.Value", "CT_EN_ACT", None),
    0x401c: ("trWpReadHigh.Cmd/Sink/DirectData", "CT_EN_ACT", None),
    0x4020: ("trWpCap.Entries", "CT_EN_ACT", None),
}

# Fields the generated block reads back inside a register the twin DOES
# decode, and that the twin does not mirror. Those are not automatically a
# lie: the twin ties the same field to its reset constant in hwif_out (the
# gated feature groups -- compression enables, DF controls, Device ID), so
# reading 0 IS the truth there. The number is pinned so that a NEW field in
# an already-decoded register cannot slip in unnoticed: if it really is a
# constant in the twin as well, raise the number in the same commit that
# adds the field and say so.
#   0x000 SendConfig/SendDeviceId/Context/InstTrigEnable/InstSeqSyncEnable
#   0x004 trTeImpl reserved + ProtocolMinor · 0x008 the compression enables
#   0x010 trTeDataControl (data trace absent) · 0x?004 reserved nibbles
UNMIRRORED_EXPECTED = 25

# Slices the twin ties to a literal although the COMMITTED generated block
# reads them from storage. That is not a lie when the field is `sw = r` in
# every profile the twin is legal in -- the reference here is the full-profile
# generated block, and the twin only ever runs in a CF-slim one. The switch
# named must be rejected by the twin's own elaboration guard, so the literal
# can never be reached in a profile where the field really is writable.
#   (addr, hi, lo) -> (switch rejected at elaboration, why the literal is true)
LITERAL_OK = {
    (0x3010, 7, 0): ("CT_EN_ACT",
                     "trPerfCntControl.IFetchThreshold is `->sw = r;` under "
                     "CT_PROFILE_NO_ACT (rdl/ct_cs_cpuif.rdl, ACT/perfcnt "
                     "group), i.e. a read-only constant at its reset 4"),
    (0x3010, 15, 8): ("CT_EN_ACT",
                      "trPerfCntControl.DataWrThreshold, same override, same "
                      "reset 4"),
}

SLICE = re.compile(r"^\[\s*(\d+)\s*:\s*(\d+)\s*\]$")
BIT = re.compile(r"^\[\s*(\d+)\s*\]$")

# A right-hand side that is nothing but a literal: 3'h1, 32'h0, 4'd0, '0, 0.
LITERAL = re.compile(r"^(?:\d*'[sS]?[bodhBODH][0-9a-fA-FxzXZ_]+|'[01]|\d+)$")
# ... and the same, restricted to a value of zero.
LITERAL_ZERO = re.compile(r"^(?:\d*'[sS]?[bodhBODH]0[0_]*|'0|0)$")
# A trailing part-select / bit-select on the right-hand side.
RHS_SLICE = re.compile(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*$")
RHS_BIT = re.compile(r"\[\s*(\d+)\s*\]\s*$")

failures = []


def fail(where: str, msg: str) -> None:
    failures.append(f"  [FAIL] {where}: {msg}")


def read(rel: str) -> str:
    p = REPO / rel
    if not p.is_file():
        fail(rel, "file not found")
        return ""
    return p.read_text(encoding="utf-8", errors="replace")


def sv_int(lit: str) -> int:
    """`4'h6` / `3'd6` / `2'b10` / `'0` / `6` -> int. Only called on strings
    that already matched LITERAL."""
    lit = lit.strip().replace("_", "")
    m = re.match(r"^(\d*)'[sS]?([bodhBODH])([0-9a-fA-F]+)$", lit)
    if m:
        return int(m.group(3), {"b": 2, "o": 8, "d": 10, "h": 16}[m.group(2).lower()])
    if lit in ("'0", "'1"):
        return 0 if lit == "'0" else -1     # '1 = all ones, never compared here
    return int(lit)


def bounds(sl):
    """`[hi:lo]` / `[b]` / no index (whole word) -> (hi, lo) or None."""
    if sl is None:
        return (31, 0)
    m = SLICE.match(sl)
    if m:
        return (int(m.group(1)), int(m.group(2)))
    m = BIT.match(sl)
    if m:
        return (int(m.group(1)), int(m.group(1)))
    return None


def rhs_of(line: str, lhs: str):
    """The right-hand side of `<lhs>[...] = <rhs>;`, comment stripped."""
    m = re.match(r"\s*" + lhs + r"(\[[^\]]*\])?\s*=\s*(.+?);", line)
    if not m:
        return None, None
    return m.group(1), m.group(2).split("//")[0].strip()


def parse_generated(text):
    """addr -> {(hi, lo): rhs}. Array/loop arms (filters, comparators,
    external windows) are skipped: the slim twin has no such register."""
    out, cur = {}, None
    for line in text.splitlines():
        m = re.search(r"if\(rd_mux_addr == 15'h([0-9a-fA-F]+)\) begin", line)
        if m:
            cur = int(m.group(1), 16)
            out.setdefault(cur, {})
            continue
        if re.search(r"rd_mux_addr\b.*15'h[0-9a-fA-F]+\s*\+", line) or \
           re.search(r"rd_mux_addr\s*>=", line):
            cur = None
            continue
        if cur is None:
            continue
        sl, rhs = rhs_of(line, "readback_data_var")
        if rhs is not None:
            b = bounds(sl)
            if b:
                out[cur][b] = rhs
            continue
        if re.match(r"\s*end\b", line):
            cur = None
    return out


def parse_micro(text):
    """addr -> {(hi, lo): rhs} over the readback always_comb only."""
    try:
        start = text.index("s_cpuif_rd_data = '0;")
        end = text.index("assign s_cpuif_req_stall_wr")
    except ValueError:
        fail(MICRO, "readback always_comb block not found "
                    "(anchors `s_cpuif_rd_data = '0;` / "
                    "`assign s_cpuif_req_stall_wr`)")
        return {}
    out, cur = {}, None
    for line in text[start:end].splitlines():
        m = re.match(r"\s*15'h([0-9a-fA-F]+):\s*(.*)$", line)
        if m:
            cur = int(m.group(1), 16)
            out.setdefault(cur, {})
            line = m.group(2)
        elif re.match(r"\s*default\s*:", line):
            cur = None
        if cur is None:
            continue
        sl, rhs = rhs_of(line, "s_cpuif_rd_data")
        if rhs is not None:
            b = bounds(sl)
            if b:
                out[cur][b] = rhs
    return out


def main() -> int:
    gen_text, micro_text = read(GEN), read(MICRO)
    if not gen_text or not micro_text:
        for f_ in failures:
            print(f_)
        return 1

    # The profile guard: one `initial begin ... end` full of `$fatal`s. A
    # waiver may only lean on a switch that is really rejected in there.
    m = re.search(r"\n\tinitial begin\n(.*?)\n\tend\n", micro_text, re.S)
    guard_block = m.group(1) if m else ""
    if not guard_block:
        fail(MICRO, "profile guard `initial begin ... end` not found -- "
                    "every waiver below rests on its $fatal list")

    gen = parse_generated(gen_text)
    micro = parse_micro(micro_text)
    if not gen:
        fail(GEN, "no `if(rd_mux_addr == 15'h...)` readback arms found")
    if not micro:
        fail(MICRO, "no `15'h...:` readback arms found")

    # --- check 1 + 1b: target width, then source width -------------------
    slices, literals_ok = 0, 0
    for addr in sorted(micro):
        g = gen.get(addr)
        if g is None:
            fail(MICRO, f"0x{addr:03x} is decoded by the twin but not by the "
                        "generated block -- a register that no longer exists")
            continue
        for (hi, lo), rhs in sorted(micro[addr].items()):
            slices += 1
            overlap = sorted(a for a in g if not (a[1] > hi or a[0] < lo))
            if not overlap:
                fail(MICRO, f"0x{addr:03x}[{hi}:{lo}] covers bits no generated "
                            "field occupies")
                continue
            if overlap != [(hi, lo)]:
                shown = ", ".join(f"[{a}:{b}]" for a, b in overlap)
                fail(MICRO, f"0x{addr:03x}[{hi}:{lo}] vs generated {shown} -- "
                            "the twin reads the field back at the WRONG width "
                            "(a narrower slice truncates silently)")
                continue

            # 1b: the target is the right width -- is the SOURCE?
            want = hi - lo + 1
            m = RHS_SLICE.search(rhs)
            if m:
                got = int(m.group(1)) - int(m.group(2)) + 1
            else:
                got = 1 if RHS_BIT.search(rhs) else None
            if got is not None and got != want:
                fail(MICRO, f"0x{addr:03x}[{hi}:{lo}] is {want} bit(s) wide but "
                            f"is fed from a {got}-bit part-select "
                            f"(`{rhs}`) -- the upper bit(s) read back as 0 "
                            "however wide the target looks")
            elif LITERAL.match(rhs) and not LITERAL.match(g[(hi, lo)]):
                ok = LITERAL_OK.get((addr, hi, lo))
                if not ok:
                    fail(MICRO, f"0x{addr:03x}[{hi}:{lo}] is tied to the "
                                f"literal `{rhs}` while the generated block "
                                f"reads it from `{g[(hi, lo)]}` -- a constant "
                                "answer to a register that exists is the "
                                "lying discovery answer, not a slim "
                                "implementation. If the field is read-only in "
                                "every profile this twin is legal in, say so "
                                "in LITERAL_OK with the switch that makes it "
                                "so.")
                elif not re.search(r"\bct_pkg::" + ok[0] + r"\b", guard_block):
                    fail(MICRO, f"0x{addr:03x}[{hi}:{lo}] is allowed to be the "
                                f"literal `{rhs}` because {ok[0]} is rejected "
                                "at elaboration, but that $fatal is gone -- "
                                "the constant is now reachable in a profile "
                                "where the field is writable")
                else:
                    literals_ok += 1

    # --- check 3: fields inside a decoded arm the twin does not mirror ---
    unmirrored, breakdown = 0, []
    for addr in sorted(micro):
        g = gen.get(addr)
        if not g:
            continue
        miss = sorted(a for a in g if not any(
            not (a[1] > hi or a[0] < lo) for (hi, lo) in micro[addr]))
        if miss:
            unmirrored += len(miss)
            breakdown.append(f"0x{addr:03x}: " +
                             ", ".join(f"[{a}:{b}]" for a, b in miss))
    if unmirrored != UNMIRRORED_EXPECTED:
        fail(MICRO, f"{unmirrored} generated field(s) inside a decoded "
                    f"register are not mirrored by the twin, pinned at "
                    f"{UNMIRRORED_EXPECTED}. Breakdown: " + " | ".join(breakdown))

    # --- check 2: deliberately undecoded addresses -----------------------
    for addr in sorted(gen):
        if addr in micro:
            continue
        if addr not in WAIVED:
            fail(MICRO, f"0x{addr:03x} is decoded by the generated block but "
                        "not by the twin, and has no waiver -- the twin would "
                        "read a constant 0 for a register that exists")
            continue
        _, guard, note = WAIVED[addr]
        if guard:
            if not re.search(r"\bct_pkg::" + guard + r"\b", guard_block):
                fail(MICRO, f"0x{addr:03x} is waived because {guard} is "
                            "rejected at elaboration, but that $fatal is gone")
            continue
        # 2b: no guard means the waiver claims the generated block reads a
        # constant 0 here too. Check the claim instead of believing it.
        if not note:
            fail(MICRO, f"0x{addr:03x} is waived with neither an elaboration "
                        "guard nor a reason")
            continue
        nonzero = sorted(b for b, rhs in gen[addr].items()
                         if not LITERAL_ZERO.match(rhs))
        if nonzero:
            shown = ", ".join(f"[{a}:{b}]={gen[addr][(a, b)]}"
                              for a, b in nonzero)
            fail(MICRO, f"0x{addr:03x} is waived on the claim \"{note}\", but "
                        f"the generated block reads {shown} there -- the twin "
                        "would answer 0 for a register that has content")

    # --- check 4: RESET VALUES -------------------------------------------
    # The twin's storage block promises "resets == RDL reset values of the
    # slim regblock" and nothing checked it. A width-identical readback of a
    # field that comes out of reset with a DIFFERENT value is the same class
    # of silent lie as A-N1, one property further along: software that never
    # writes the field gets one behaviour from the generated block and another
    # from the twin. Found by P0-02, which changed trTeControl.InstSyncMax's
    # reset from 0 to 6 in the RDL -- the twin kept the 0 and no gate cared.
    gen_reset = {}
    for m_ in re.finditer(r"field_storage\.([\w.]+)\.value\s*<=\s*([^;]+);",
                          gen_text):
        rhs_ = m_.group(2).strip()
        if LITERAL.match(rhs_):
            gen_reset[m_.group(1)] = rhs_
    m_ = re.search(r"if \(rst\) begin\n(.*?)\n\t\tend\n", micro_text, re.S)
    twin_reset = {}
    if m_:
        for line in m_.group(1).splitlines():
            mm = re.match(r"\s*(\w+)\s*<=\s*([^;]+);", line)
            if mm and LITERAL.match(mm.group(2).strip()):
                twin_reset[mm.group(1)] = mm.group(2).strip()
    else:
        fail(MICRO, "storage reset block `if (rst) begin ... end` not found -- "
                    "reset values cannot be compared")

    resets_checked = 0
    for addr in sorted(micro):
        g = gen.get(addr)
        if not g:
            continue
        for (hi, lo), rhs in sorted(micro[addr].items()):
            if rhs not in twin_reset:
                continue                       # literal / expression / gated
            gm = re.match(r"^field_storage\.([\w.]+)\.value$", g.get((hi, lo), ""))
            if not gm or gm.group(1) not in gen_reset:
                continue
            want, got = gen_reset[gm.group(1)], twin_reset[rhs]
            if sv_int(want) != sv_int(got):
                fail(MICRO, f"0x{addr:03x}[{hi}:{lo}] `{rhs}` comes out of "
                            f"reset as {got} while the generated "
                            f"{gm.group(1)} resets to {want} -- software that "
                            "does not write the field sees two different "
                            "encoders")
            else:
                resets_checked += 1
            # The declaration initializer is the power-up value; it must not
            # disagree with the reset branch either.
            dm = re.search(r"^\s*logic\s*(?:\[[^\]]*\])?\s*" + rhs +
                           r"\s*=\s*([^;]+);", micro_text, re.M)
            if dm and LITERAL.match(dm.group(1).strip()) \
                    and sv_int(dm.group(1).strip()) != sv_int(got):
                fail(MICRO, f"`{rhs}` is declared with initial value "
                            f"{dm.group(1).strip()} but reset to {got}")

    if failures:
        for f_ in failures:
            print(f_)
        print(f"[check_micro_csr_twin] {len(failures)} failure(s)")
        return 1
    print(f"[check_micro_csr_twin] OK: {len(micro)} readback arm(s), "
          f"{slices} slice(s) width-identical to the generated block; "
          f"{len(WAIVED)} arm(s) deliberately not decoded "
          f"({sum(1 for _, g, _ in WAIVED.values() if g)} held by an "
          f"elaboration guard, {sum(1 for _, g, _ in WAIVED.values() if not g)} "
          f"because the generated block reads a checked constant 0 there); "
          f"{unmirrored} unmirrored field(s) as pinned; every source slice as "
          f"wide as its target, {literals_ok} literal(s) waived in LITERAL_OK; "
          f"{resets_checked} field(s) reset-identical to the generated block")
    return 0


if __name__ == "__main__":
    sys.exit(main())
