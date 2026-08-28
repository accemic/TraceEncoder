#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Regression guard for insight.py and the scenario catalogue.

    py test_insight.py

Every test pins down exactly the failure mode that caused it:

  T1  Window alignment -- NexRv aborts with "Message must start from MSEO='00'"
      when a ring excerpt starts in the middle of a message.
  T2  Symbol lookup is half open [start, next_start): an address BEHIND the
      last symbol must not get its name.
  T3  Call depth only with an EXACT call marker. Two conditions, both from a
      measured defect: (a) with the C extension, pc+4 is not a valid step
      width; (b) without the call sites from the listing, every jump to an
      assembler label (`_try_lottery`) is wrongly taken for a call -- over one
      real boot the depth ran away to 2972 frames that way. In both cases
      depth MUST be None plus depth_note.
  T4  Coverage without a symbol table delivers NO share (share=None), because
      otherwise the UI would show a percentage without a reference quantity.
  T5  The CTRL register maps of the scenarios really are different -- exactly
      the reason scenarios.json exists. If this test falls over, a scenario
      has accidentally slipped onto another one's map.
  T6  bit/instruction is formed from MEASURED quantities (bytes*8/instr), not
      from a constant.
"""
import sys

import insight
from scenario import Catalog

FAILS = []


def check(name, cond, detail=""):
    print(("  OK   " if cond else "  FAIL ") + name + ("  " + detail if detail else ""))
    if not cond:
        FAILS.append(name)


# --- T1: window alignment on Nexus message boundaries ----------------------
print("T1 align_to_messages")
# Byte pattern: 2 bytes of the remainder of a message, then |END|, then a
# whole message with |END|, then a truncated remainder.
raw = bytes([0x04, 0x08, 0x03,        # tail of a foreign message + end
             0x10, 0x14, 0x03,        # whole message
             0x20, 0x24])             # truncated head
p, head, tail = insight.align_to_messages(raw)
check("cuts off head and tail", p == bytes([0x10, 0x14, 0x03]),
      "head=%d tail=%d payload=%s" % (head, tail, p.hex()))
check("empty result without a message end",
      insight.align_to_messages(bytes([0x04, 0x08, 0x10]))[0] == b"")
check("empty input is not an error", insight.align_to_messages(b"")[0] == b"")

# --- T2: symbol lookup -----------------------------------------------------
print("T2 SymbolTable")
st = insight.SymbolTable.from_text(
    "c0000000 T _start\n"
    "c0000100 t setup_vm\n"
    "c0000200 T start_kernel\n"
    "c0001000 D some_data\n",           # data symbol -> NOT in the table
    "unittest")
check("only executable symbols", st.count == 3, "count=%d" % st.count)
check("hit in the middle", st.lookup(0xC0000104)[0] == "setup_vm")
check("hit at the start", st.lookup(0xC0000200)[0] == "start_kernel")
check("offset is right", st.lookup(0xC0000108)[2] == 8)
check("before the first symbol -> None", st.lookup(0xBFFFFFF0)[0] is None)
check("far behind the last one -> None", st.lookup(0xC0009999)[0] is None)
check("is_entry only on the start",
      st.is_entry(0xC0000100) and not st.is_entry(0xC0000104))

# --- T3: call depth only with an exact call marker -------------------------
print("T3 PcStreamAnalysis + CallSites")
# _start runs, calls setup_vm by jal @0xC0000008, returns by ret @0xC0000104.
pcs = [0xC0000000, 0xC0000004, 0xC0000008,
       0xC0000100, 0xC0000104,          # call into setup_vm
       0xC000000C, 0xC0000010]          # return to 0xC0000008+4
sites = insight.CallSites.from_text("C c0000008\nR c0000104\n", "unittest")
check("sites read", sites.count == 2, str(sites.count))
a = insight.PcStreamAnalysis(pcs, st, fixed_width=True, sites=sites)
check("one call recognised", a.calls == 1, "calls=%d" % a.calls)
check("one return recognised", a.returns == 1, "returns=%d" % a.returns)
check("depth back to 0", a.depth == 0, "depth=%s" % a.depth)
check("instructions per function (keyed by START ADDRESS)",
      a.per_func == {0xC0000000: 5, 0xC0000100: 2}, str(a.per_func))
check("current function", a.current == "_start")
a2 = insight.PcStreamAnalysis(pcs, st, fixed_width=False, sites=sites)
check("without a fixed width, NO depth", a2.depth is None, "depth=%s" % a2.depth)
check("and the reason comes with it", "C extension" in (a2.depth_note or ""))
a3 = insight.PcStreamAnalysis(pcs, st, fixed_width=True)     # without sites
check("without sites, NO depth", a3.depth is None, "depth=%s" % a3.depth)
check("the reason names --sites", "--sites" in (a3.depth_note or ""))
check("without sites, no call count either", a3.calls == 0)
# The real defect case: a jump to an assembler label is NOT a call.
lbl = insight.SymbolTable.from_text(
    "64000000 T _fw_start\n6400002c t _try_lottery\n", "unittest")
jmp = [0x64000024, 0x6400002C, 0x64000030]     # j _try_lottery, NOT jal
aj = insight.PcStreamAnalysis(jmp, lbl, fixed_width=True,
                              sites=insight.CallSites.from_text("R 64009999\n"))
check("a jump to an assembler label does NOT count as a call",
      aj.calls == 0 and aj.depth == 0, "calls=%d depth=%s" % (aj.calls, aj.depth))
check("an empty stream is not an error",
      insight.PcStreamAnalysis([], st).n == 0)

# --- T4: coverage ----------------------------------------------------------
print("T4 InsightState / coverage")
ins = insight.InsightState()
ins.add_window(pcs, 64, 0.01)
cov = ins.coverage()
check("no share without a symbol table", cov["share"] is None, str(cov))
ins.symbols = st
ins.func_counts = {0xC0000000: 5, 0xC0000100: 2}
cov = ins.coverage()
check("with a table: 2 of 3 functions",
      cov["seen"] == 2 and cov["total"] == 3, str(cov))
check("the frame of reference comes with it", "windows" in cov.get("scope", ""))
check("the name is recovered from the address",
      ins.name_of(0xC0000100) == "setup_vm", ins.name_of(0xC0000100))

# --- T4b: the double-counting defect as actually measured ------------------
# One kernel symbol appears TWICE in the listing: physical and virtual. If the
# counters were keyed by NAME, the same instructions would count into both
# address regions -- observed in the field as identical 17,572 instructions in
# "kernel physical" AND "kernel virtual".
print("T4b double counting phys/virt")
dual = insight.SymbolTable.from_text(
    "64400000 T start_kernel\n64400100 T setup_vm\n"
    "c0000000 T start_kernel\nc0000100 T setup_vm\n", "unittest")
i2 = insight.InsightState()
i2.symbols = dual
i2.add_window([0x64400000, 0x64400004, 0x64400008], 32, 0.01)   # ONLY physical
keys = set(i2.func_counts)
check("only the physical copy counted", keys == {0x64400000}, str(keys))
check("the virtual copy stays at 0",
      i2.func_counts.get(0xC0000000, 0) == 0)
check("both copies are in the table nonetheless", dual.count == 4)

# --- T4c: symbol size across an address gap is capped ----------------------
print("T4c size cap")
gap = insight.SymbolTable.from_text(
    "64000000 T klein\n64000040 T handshake\nc0000000 T weit_weg\n", "unittest")
sz = {n: (s, c) for n, a, s, c in gap.sizes()}
check("a normal function is not capped", sz["klein"] == (0x40, False), str(sz["klein"]))
check("a symbol in front of the gap is capped",
      sz["handshake"][0] == insight.SymbolTable.MAX_FUNC_BYTES and sz["handshake"][1],
      str(sz["handshake"]))

# --- T5: scenario register maps are different ------------------------------
print("T5 scenario catalogue")
cat = Catalog()
cva6, trio, mbv = cat.by_id["cva6_linux"], cat.by_id["trio"], cat.by_id["mbv"]
check("cva6_linux: TRACE_BUFSZ at 0x10", cva6.co("trace_bufsz") == 0x10,
      "0x%02X" % cva6.co("trace_bufsz"))
check("trio: TRACE_BUFSZ at 0x14", trio.co("trace_bufsz") == 0x14,
      "0x%02X" % trio.co("trace_bufsz"))
check("the two maps are NOT equal",
      cva6.co("trace_bufsz") != trio.co("trace_bufsz"))
check("cva6_linux: CON_BYTES at 0x14", cva6.co("con_bytes") == 0x14)
check("trio has no CON_BYTES (None, not 0)", trio.co("con_bytes") is None)
# Until the D2 rework (bcb18d55093), mbv was the scenario WITHOUT DDR/PIB, and
# that is what stood here. Since mbv sits on ct_trace_sinks it has all three
# sinks -- the assertion was wrong from then on and coloured the stage red.
# The contrast this is about (the maps are NOT equal) remains: to this day
# cva6_linux has no PIB sink.
check("mbv has all three sinks (D2: ct_trace_sinks)",
      all(mbv.sinks.get(k) for k in ("uram", "ddr", "pib")),
      repr(mbv.sinks))
check("cva6_linux has NO PIB sink (the sink maps are not equal)",
      not cva6.sinks.get("pib"), repr(cva6.sinks))
check("cva6_linux has exactly one encoder",
      [r for r in ("enc", "enc1", "enc2") if r in cva6.regions] == ["enc"])
check("trio has three encoders",
      [r for r in ("enc", "enc1", "enc2") if r in trio.regions] ==
      ["enc", "enc1", "enc2"])
check("trio decodes multi-target", trio.decode["multi_target"] is True)
check("cva6_linux decodes single-target",
      cva6.decode["multi_target"] is False)
check("the con_clear bit only on the Linux CVA6",
      cva6.cbit("con_clear") == 4 and trio.cbit("con_clear") == 0)
check("regions resolved", cva6.regions["con"][0] == 0xA0300000,
      "0x%08X" % cva6.regions["con"][0])

# --- T6: bit/instruction from measured quantities --------------------------
print("T6 bit/instruction")
ins2 = insight.InsightState()
last = ins2.add_window([0xC0000000] * 2000, 2000, 0.5)   # 2000 B / 2000 instr
check("2000 bytes / 2000 instr == 8.0 bit", abs(last["bits_per_instr"] - 8.0) < 1e-9,
      str(last["bits_per_instr"]))
last = ins2.add_window([0xC0000000] * 4000, 2000, 0.5)   # 2000 B / 4000 instr
check("2000 bytes / 4000 instr == 4.0 bit", abs(last["bits_per_instr"] - 4.0) < 1e-9,
      str(last["bits_per_instr"]))
# The case actually observed in the browser test of 2026-07-28: 16,380 B
# yielded 9 instructions -> 14,560 bit/instr. Such a number must NOT appear.
small = ins2.add_window([0xC0000000] * 9, 16380, 0.05)
check("a tiny window delivers NO bit/instr number",
      small["bits_per_instr"] is None, str(small["bits_per_instr"]))
check("the reason stands there instead",
      "sync" in (small["bits_per_instr_note"] or ""), str(small["bits_per_instr_note"]))
check("the raw numbers stay visible",
      small["instr"] == 9 and small["bytes"] == 16380)
thr = ins2.decoder_throughput()
check("decoder throughput measured, not set",
      abs(thr["mb_per_s"] - (2000 + 2000 + 16380) / 1.05 / 1e6) < 1e-12, str(thr))
check("empty window -> bit/instr None",
      insight.InsightState().add_window([], 0, 0.1)["bits_per_instr"] is None)

# --- T7: no scenario shows another one's building blocks -------------------
# The defect as found in the field (2026-07-29): in the CVA6 scenario the CVA6
# block read "MicroBlaze V + SoC CTRL". The cause was not that one line but
# that block titles, descriptions and tooltip lines were hard-wired to
# POSITION ids (cpu0/cpu1/cpu2) -- row 0 was always the MBV. The test checks
# the class, not the single case.
import json
import pathlib
import re

HERE = pathlib.Path(__file__).parent
CORE_NAMES = ["MicroBlaze V", "MBV", "TGC5B", "CVA6", "cv32a60x", "cv32a6_ima"]

html = (HERE / "index.html").read_text(encoding="utf-8")
# Remove comments PROPERLY. Filtering line by line misses the CONTINUATION
# lines of block comments -- the first attempt at this test would almost have
# reported a false green because of that.
code = re.sub(r"/\*.*?\*/", " ", html, flags=re.S)
code = re.sub(r"(?m)//.*$", " ", code)
leaked = [n for n in CORE_NAMES if re.search(r"\b" + re.escape(n) + r"\b", code)]
check("no core names in the frontend code (only in the scenario)",
      not leaked, "found: " + ", ".join(leaked))

cat = json.loads((HERE / "scenarios.json").read_text(encoding="utf-8"))
by_id = {s["id"]: s for s in cat["scenarios"]}

# Every core carries its own description -- if it is missing, the UI falls
# back to a position default, and that was exactly the defect.
for sid, sc in by_id.items():
    for c in sc["cores"]:
        tag = "%s/core %d" % (sid, c["id"])
        check(tag + " has a panel title", bool(c.get("panel")))
        check(tag + " has a description", bool(c.get("desc")))
        check(tag + " has an ingress description", bool(c.get("ingress_desc")))

# A core text must not name a core that THIS scenario does not have. Short
# forms and configuration names belong to their respective core -- "MBV" is
# the MicroBlaze V, "cv32a60x" is a CVA6 configuration. Without that mapping
# the test fired on correct texts (its first version), which would have made
# it useless: a test that goes red on correct content gets switched off
# instead of read.
ALIAS = {"MBV": "MicroBlaze V", "cv32a60x": "CVA6", "cv32a6_ima": "CVA6"}
for sid, sc in by_id.items():
    own = {c["name"] for c in sc["cores"]}
    # Multi-core scenarios of the SAME core type name their instances
    # distinguishably ("TGC5B core 0", "Rocket hart 1") -- the core type in
    # front of the instance suffix then belongs to the scenario and is not
    # foreign to it (package H; without this rule the test fired on correct
    # texts of the tgc5b2_axis_wp scenario -- the same class of defect that
    # the ALIAS table above fixes for configuration names).
    for n in list(own):
        m = re.match(r"(.+?)\s+(?:core|hart)\s+\d+$", n)
        if m:
            own.add(m.group(1))
    for c in sc["cores"]:
        txt = " ".join([c.get("panel", ""), c.get("desc", ""),
                        c.get("ingress_panel", ""), c.get("ingress_desc", "")])
        foreign = [n for n in CORE_NAMES
                   if ALIAS.get(n, n) not in own
                   and re.search(r"\b" + re.escape(n) + r"\b", txt)]
        check("%s/%s names no core foreign to its scenario" % (sid, c["name"]),
              not foreign, "found: " + ", ".join(foreign))

# The start bit of every core must exist in the CTRL map of the scenario.
# The UI showed an irq_gen_en in the CVA6 scenario that does not exist there.
for sid, sc in by_id.items():
    bits = sc.get("control_bits", {})
    for c in sc["cores"]:
        rb = c.get("run_bit", "core_run")
        check("%s/%s: start bit %s is in control_bits" % (sid, c["name"], rb),
              rb in bits, "control_bits=" + ",".join(bits))

# The AXIS block only where the bitstream has it: feature and region must
# agree, otherwise the diagram shows a block without registers.
for sid, sc in by_id.items():
    has_feat = "axis" in sc.get("features", [])
    has_region = "axis" in sc.get("regions", {})
    check("%s: the axis feature agrees with the axis region" % sid,
          has_feat == has_region,
          "feature=%s region=%s" % (has_feat, has_region))

print()
if FAILS:
    print("FAIL: %d test(s) red: %s" % (len(FAILS), ", ".join(FAILS)))
    sys.exit(1)
print("PASS: all tests green")
