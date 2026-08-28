# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Generate regmap.json for the CEDARtools.TraceEncoder KV260 dashboard.

Compiles the full-profile RDL (rdl/ct_cs_cpuif.rdl, no CT_PROFILE_NO_*
defines = Vollausstattung) with systemrdl-compiler and walks the elaborated
tree into a flat JSON register list. The SoC CTRL region registers
(mbv_soc_top.sv, not RDL-described) are appended by hand here so the
dashboard has ONE machine-readable source for everything it shows.

Output: examples/dashboard/regmap.json
Regenerate after every RDL change: py gen_regmap.py   (from examples/dashboard/)
"""
import json
import sys
from pathlib import Path

from systemrdl import RDLCompiler, RDLCompileError
from systemrdl.node import RegNode, MemNode

# REPO is the repository root: examples/dashboard/gen_regmap.py -> examples
# -> repo root (two levels up). In this repository the RDL source lives at
# the repo-root rdl/ directly -- unlike the predecessor repository, which vendored a CTTE
# fork under third_party/CTTE/rdl/, this repository's rdl/ IS the source.
REPO = Path(__file__).resolve().parents[2]
RDL = REPO / "rdl" / "ct_cs_cpuif.rdl"
OUT = Path(__file__).resolve().parent / "regmap.json"

# KV260 aperture (trio_soc_top.sv seg_of decode; Trio seit 2026-07-24, Gate C4)
REGIONS = {
    "ctrl":  {"base": 0xA0000000, "size": 0x10000,  "name": "SoC CTRL (trio_soc_top)"},
    "enc":   {"base": 0xA0010000, "size": 0x10000,  "name": "CTTE Encoder 0 CSRs (MBV)"},
    "enc1":  {"base": 0xA0020000, "size": 0x10000,  "name": "CTTE Encoder 1 CSRs (TGC5B)"},
    "enc2":  {"base": 0xA0030000, "size": 0x10000,  "name": "CTTE Encoder 2 CSRs (CVA6)"},
    "ram1":  {"base": 0xA0080000, "size": 0x10000,  "name": "TGC5B Program/Data RAM (64 KiB)"},
    "ram":   {"base": 0xA0100000, "size": 0x20000,  "name": "MBV Program/Data RAM (128 KiB)"},
    "trace": {"base": 0xA0200000, "size": 0x100000, "name": "ATB Trace Ring (gemergt, URAM)"},
    "axis":  {"base": 0xA0300000, "size": 0x100000, "name": "AXIS Capture BRAM"},
}


def access_rule(d):
    """One English sentence per field: what a write/read REALLY does.

    Written after the question "are the accesses the dashboard offers really
    read/write?" turned out to have no good answer.
    `sw = rw` is only half the truth -- the RDL carries
    four further properties that decide whether a write arrives at all, and
    the dashboard used to show none of them:
      swwel        write is silently dropped while trTeControl.Enable=1
                   (ct_cs_cpuif.sv:1239; cpuif_wr_err is tied to 0, so the
                   bus cycle ends with OKAY either way)
      onwrite=woclr  write-1-clears -- a read-modify-write of the whole word
                   wipes the bit (that is the overflow evidence)
      singlepulse  self-clearing strobe: reads back 0, never holds the value
      swacc        the READ has a side effect (moves a pointer)
    Text, not code, because the consumer is the operator: the badge in the
    UI is derived from the same machine-readable flags right next to it.
    """
    parts = []
    if d.get("pulse"):
        parts.append("write-1 pulse: self-clearing, always reads back 0")
    elif d.get("w1c"):
        parts.append("write-1-to-clear: a read-modify-write of the whole "
                     "register clears this bit unintentionally")
    if d.get("gated"):
        parts.append("writable only while trTeControl.Enable=0 -- a write "
                     "while enabled is discarded WITHOUT an error response")
    if d.get("swacc"):
        parts.append("reading has a side effect (see the register description)")
    if not parts:
        parts.append("read-only" if d["sw"] == "r" else "freely writable")
    return "; ".join(parts)


def field_json(f):
    d = {
        "name": f.inst_name,
        "lsb": f.lsb,
        "msb": f.msb,
        "sw": f.get_property("sw").name,
        "hw": f.get_property("hw").name,
        "reset": None,
        "desc": (f.get_property("desc") or "").strip(),
    }
    rst = f.get_property("reset")
    if isinstance(rst, int):
        d["reset"] = rst
    enc = f.get_property("encode")
    if enc is not None:
        d["enum"] = {
            str(int(m.value)): {"name": m.name, "desc": (m.rdl_desc or "").strip()}
            for m in enc
        }
    swwel = f.get_property("swwel")
    if swwel not in (None, False, True):
        d["gated"] = "trTeControl.Enable=0"
    ow = f.get_property("onwrite")
    if ow is not None:
        d["onwrite"] = ow.name
        if ow.name == "woclr":
            d["w1c"] = True
    if f.get_property("singlepulse"):
        d["pulse"] = True
    if f.get_property("swacc"):
        d["swacc"] = True
    d["access_rule"] = access_rule(d)
    return d


def reg_json(r, region, group=None):
    fields = [field_json(f) for f in r.fields()]
    return {
        "region": region,
        "offset": r.absolute_address,
        "path": r.get_path(array_suffix="[{index:d}]"),
        "name": r.get_property("name") or r.inst_name,
        "desc": (r.get_property("desc") or "").strip(),
        "fields": fields,
        # Register-level marker: ANY field with a read side effect makes the
        # whole register unsafe for the panel poller -- a block read across
        # it moves the pointer just as a targeted read does. The poller and
        # the cluster builder key on THIS flag, never on a register name
        # (the name-based filter caught TipFifoHistData and missed
        # trWpReadHigh -- FINDINGS_u3 §2.2).
        **({"read_side_effect": True} if any(f.get("swacc") for f in fields) else {}),
        **({"group": group} if group else {}),
    }


def main():
    rdlc = RDLCompiler()
    try:
        rdlc.compile_file(str(RDL))
        root = rdlc.elaborate(top_def_name="ct_cs_cpuif")
    except RDLCompileError as e:
        sys.exit(f"RDL compile failed: {e}")

    top = root.top
    regs = []
    mems = []

    for node in top.descendants(unroll=True):
        if isinstance(node, MemNode):
            entry_regs = []
            for vr in node.children(unroll=False):
                if isinstance(vr, RegNode):
                    entry_regs.append({
                        "entry_offset": vr.raw_address_offset,
                        "name": vr.get_property("name") or vr.inst_name,
                        "inst": vr.inst_name,
                        "desc": (vr.get_property("desc") or "").strip(),
                        "fields": [field_json(f) for f in vr.fields()],
                    })
            mems.append({
                "region": "enc",
                "offset": node.absolute_address,
                "path": node.get_path(),
                "name": node.get_property("name") or node.inst_name,
                "desc": (node.get_property("desc") or "").strip(),
                "entries": node.get_property("mementries"),
                "stride": node.get_property("memwidth") // 8,
                "entry_regs": entry_regs,
            })
        elif isinstance(node, RegNode):
            if not node.get_property("ispresent"):
                continue
            if isinstance(node.parent, MemNode):
                continue  # virtual regs are emitted inside their mem
            regs.append(reg_json(node, "enc"))

    # SoC CTRL region (hand-described; source: rtl/board_kv260/mbv_soc_top.sv)
    ctrl_regs = [
        {"region": "ctrl", "offset": 0x00, "path": "soc.CONTROL", "name": "SoC Control Register",
         "desc": "Board-level control (mbv_soc_top). Core is held in reset while core_run=0; "
                 "load RAM and configure the encoder first, then set core_run=1.",
         "fields": [
             {"name": "core_run", "lsb": 0, "msb": 0, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: release the MicroBlaze V core from reset (run). 0: hold core in reset."},
             {"name": "trace_clear", "lsb": 1, "msb": 1, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: clear the trace capture buffer and byte/beat counters."},
             {"name": "trace_flush", "lsb": 2, "msb": 2, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: assert ATB flush (afvalid) so the encoder drains buffered trace."},
             {"name": "irq_gen_en", "lsb": 3, "msb": 3, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: enable HW IRQ pulse generator (1-cycle pulse every 4096 clks ~ 55 us "
                      "@75 MHz) into the core's external interrupt (G6 hardening)."},
             {"name": "cva6_run", "lsb": 5, "msb": 5, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: release the CVA6 core (soc2) from reset. Independent of core_run: "
                      "set only AFTER the program was loaded into the reserved PS-DDR window "
                      "at 0x6400_0000 (devmem; examples/kv260/SPEC_board_memory_map.md)."},
             # U1 (2026-08-14): per-core release bits. Additive -- b0 keeps
             # meaning "all cores of this SoC", effective is b0 | b(8+i)
             # (tgc5b2_axis_soc_top.sv:182-183, duo_soc_top.sv:151-152,
             # trio_soc_top.sv:227-228,234; SPEC_axis_wp_memory_map.md §10).
             {"name": "core0_run", "lsb": 8, "msb": 8, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: release core 0 alone (tgc5b2: TGC5B-0, duo/trio: MicroBlaze V). "
                      "Effective run state is core_run | core0_run, so b0 still starts "
                      "everything. Reads 0 on single-core designs and on pre-U1 bitstreams.",
              "access_rule": "freely writable; the RAM window of THIS core is only "
                             "accessible while its effective run bit is 0 -- an access to "
                             "the RAM of a running core never gets ready and HANGS the AXI "
                             "transaction (SPEC §10 point 2)"},
             {"name": "core1_run", "lsb": 9, "msb": 9, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: release core 1 alone (tgc5b2: TGC5B-1, duo/trio: TGC5B). "
                      "Effective run state is core_run | core1_run. Reads 0 on single-core "
                      "designs and on pre-U1 bitstreams.",
              "access_rule": "freely writable; the RAM window of THIS core is only "
                             "accessible while its effective run bit is 0 (SPEC §10 point 2)"},
             {"name": "cva6_run2", "lsb": 10, "msb": 10, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "trio only: second release bit of the CVA6, OR-ed with the historic "
                      "b5 cva6_run (trio_soc_top.sv:234). Exists so all three cores have a "
                      "bit in the same b8..b10 field; b5 keeps working unchanged.",
              "access_rule": "freely writable; alias of b5 (effective cva6_run = b5 | b10)"},
         ]},
        {"region": "ctrl", "offset": 0x04, "path": "soc.STATUS", "name": "SoC Status Register",
         "desc": "Board-level status (read-only).",
         "fields": [
             {"name": "trace_wrapped", "lsb": 0, "msb": 0, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: the trace capture RING buffer has wrapped at least once -- the "
                      "oldest beats were overwritten (capture continues; nothing stalls). "
                      "Clear via CONTROL.trace_clear."},
             {"name": "axis_overflow", "lsb": 1, "msb": 1, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: AXIS capture BRAM overflowed."},
             # U1: STATUS mirrors the EFFECTIVE run state, so a host learns
             # with ONE read which core is actually running instead of
             # keeping shadow bookkeeping (tgc5b2_axis_soc_top.sv:584,
             # duo_soc_top.sv:546, trio_soc_top.sv:718).
             {"name": "core0_running", "lsb": 8, "msb": 8, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: core 0 is effectively released (CONTROL.core_run | "
                      "CONTROL.core0_run). Reads 0 on pre-U1 bitstreams."},
             {"name": "core1_running", "lsb": 9, "msb": 9, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: core 1 is effectively released (CONTROL.core_run | "
                      "CONTROL.core1_run). Reads 0 on pre-U1 bitstreams."},
             {"name": "cva6_running", "lsb": 10, "msb": 10, "sw": "r", "hw": "w", "reset": 0,
              "desc": "trio only: 1 = the CVA6 is effectively released "
                      "(CONTROL.cva6_run | CONTROL.cva6_run2)."},
         ]},
        {"region": "ctrl", "offset": 0x08, "path": "soc.TRACE_BEATS", "name": "Trace Beats Counter",
         "desc": "Total captured ATB beats since last trace_clear (monotonic, does NOT stop "
                 "at the ring capacity). Ring write position = TRACE_BEATS % (TRACE_BUFSZ/4).",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "r", "hw": "w", "reset": 0,
                     "desc": "ATB beats captured since last trace_clear (monotonic)."}]},
        {"region": "ctrl", "offset": 0x0C, "path": "soc.TRACE_BYTES", "name": "Trace Bytes Counter",
         "desc": "Total captured ATB bytes since last trace_clear (monotonic). "
                 "Poll delta = live trace bandwidth.",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "r", "hw": "w", "reset": 0,
                     "desc": "ATB bytes captured since last trace_clear (monotonic)."}]},
        {"region": "ctrl", "offset": 0x10, "path": "soc.AXIS_BEATS", "name": "AXIS Beats Counter",
         "desc": "Number of captured AXIS beats (read-only).",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "r", "hw": "w", "reset": 0,
                     "desc": "AXIS beats captured since last trace_clear."}]},
        {"region": "ctrl", "offset": 0x14, "path": "soc.TRACE_BUFSZ", "name": "Trace Ring Capacity",
         "desc": "Capacity of the ATB trace capture ring buffer in bytes (read-only; "
                 "1 MiB URAM in the G7 build). Reads 0 on pre-ring bitstreams.",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "r", "hw": "w", "reset": 0,
                     "desc": "Ring capacity in bytes (TRACE_DEPTH * 4)."}]},
        {"region": "ctrl", "offset": 0x18, "path": "soc.SINK_CTRL", "name": "Trace Sink Control",
         "desc": "Enables/config of the additional trace sinks (DDR4 + PIB). Both sinks "
                 "observe the funnel-merged ATB stream in parallel to the URAM ring and "
                 "never back-pressure the trace path (own FIFO + drop counters).",
         "fields": [
             {"name": "ddr_en", "lsb": 0, "msb": 0, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: DDR4 sink enabled (writes beats to PS DDR at DDR_BASE)."},
             {"name": "ddr_clear", "lsb": 1, "msb": 1, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "W1 pulse (only while ddr_en=0): reset DDR_WPTR/full/wrapped/err/"
                      "drops -- and SINK_STAT.ddr_cfg_rej, the refusal marker of the "
                      "U6 window interlock.",
              # ct_trace_sinks.sv:125 masks b1 out of the stored word
              # (SINK_WR_MASK = 0xFFFF_FFDD) and turns it into a one-cycle
              # pulse (:142-146) -- it never reads back as 1. The rule "only
              # while ddr_en=0" is a CONTRACT, not hardware: the pulse fires
              # regardless, only the button path refuses it (server.py
              # _ctl ddr_clear). FINDINGS_u3 §2.5 / row 21.
              "pulse": True,
              "access_rule": "write-1 pulse: self-clearing, always reads back 0; clear "
                             "only while ddr_en=0 -- the hardware does NOT enforce that, "
                             "a pulse during an active capture resets its counters"},
             {"name": "ddr_circ", "lsb": 2, "msb": 2, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "DDR capture mode: 0 = one shot (stop when full), 1 = circular "
                      "(wrap modulo DDR_SIZE, keeps the most recent bytes; write "
                      "offset = DDR_WPTR % DDR_SIZE). Switch only while cleared."},
             {"name": "uram_oneshot", "lsb": 3, "msb": 3, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "URAM trace buffer mode: 0 = circular ring (default, keeps the "
                      "most recent 1 MiB), 1 = one shot (capture stops when full, "
                      "keeps the FIRST 1 MiB; SINK_STAT.uram_stopped sets)."},
             {"name": "pib_en", "lsb": 4, "msb": 4, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: PIB parallel trace port enabled (pib_clk runs, beats serialized)."},
             {"name": "pib_clear", "lsb": 5, "msb": 5, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "W1 pulse (only while pib_en=0): reset PIB drop counter.",
              "pulse": True,
              "access_rule": "write-1 pulse: self-clearing, always reads back 0; the "
                             "hardware does NOT enforce the pib_en=0 rule "
                             "(ct_trace_sinks.sv:125,142-146)"},
             {"name": "pib_calib", "lsb": 6, "msb": 6, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "1: PIB emits the calibration pattern instead of trace "
                      "(reference trPibCalibrate); the trace input is not consumed."},
             {"name": "pib_div", "lsb": 8, "msb": 10, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "PIB port clock divider: pib_clk = clk / 2^(div+1); 0 is clamped "
                      "to 1 (max 18.75 MHz @75 MHz core -> 18.75 MB/s byte rate)."},
             {"name": "pib_pattern", "lsb": 12, "msb": 13, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "Calibration pattern (reference trPibCalibPattern): "
                      "0 = STANDARD (AA 55 00 FF), 1 = MOVING_ONE (walking 1), "
                      "2 = MOVING_ZERO (walking 0).",
              "enum": {0: {"name": "STANDARD"}, 1: {"name": "MOVING_ONE"},
                       2: {"name": "MOVING_ZERO"}}},
         ]},
        {"region": "ctrl", "offset": 0x34, "path": "soc.FUNNEL_CTRL", "name": "Trace Funnel Control",
         "desc": "Per-channel arbitration priority of the message-atomic trace funnel "
                 "(ct_L1_funnel, MAX_PRIO=3). Higher value wins on message boundaries; "
                 "equal values arbitrate round-robin. Live-writable (takes effect at "
                 "the next message boundary). The reference-PIB funnel CSRs "
                 "(trFunnelArbMode/Shed*) are not part of this build.",
         "fields": [
             {"name": "prio_ch0", "lsb": 0, "msb": 1, "sw": "rw", "hw": "r", "reset": 1,
              "desc": "Priority of channel 0 (Encoder 0, MBV)."},
             {"name": "prio_ch1", "lsb": 4, "msb": 5, "sw": "rw", "hw": "r", "reset": 1,
              "desc": "Priority of channel 1 (Encoder 1, TGC5B)."},
             {"name": "prio_ch2", "lsb": 8, "msb": 9, "sw": "rw", "hw": "r", "reset": 1,
              "desc": "Priority of channel 2 (Encoder 2, CVA6)."},
             # The register keeps a fourth bit that the card did not show
             # (trio_soc_top.sv:253,507,699). Its write mask is 0x0001_0333 --
             # every other bit reads back 0 no matter what was written, which
             # is exactly the class of write the readback check now reports.
             {"name": "te_tag_always", "lsb": 16, "msb": 16, "sw": "rw", "hw": "r", "reset": 0,
              "desc": "E-Trace mode: emit a source tag in front of EVERY packet instead of "
                      "only after a channel switch (funnel te_tag_always). No effect in "
                      "N-Trace mode.",
              "access_rule": "freely writable; the register write mask is 0x0001_0333 -- "
                             "bits outside it are dropped silently"},
         ]},
        # Address plan v4: the reset default of the ct_trace_sinks designs is
        # 0x5000_0000 + 256 MiB. It does NOT hold globally -- the tops with
        # their own sink wiring still sit at 0x6000_0000 + 64 MiB. The number
        # here is therefore a statement of origin, not a promise: the
        # dashboard computes everywhere from the register value it READ
        # (index.html ddr_fill/ddr_wptr), never from this constant.
        {"region": "ctrl", "offset": 0x1C, "path": "soc.DDR_BASE", "name": "DDR Sink Base Address",
         "desc": "Byte address of the linear DDR capture buffer in PS DDR (32-byte "
                 "aligned; low bits are masked). Reset 0x5000_0000 = start of the "
                 "reserved PL window 0x5000_0000..0x6FFF_FFFF (512 MiB, no-map via "
                 "ctrace_resmem.dtso; examples/kv260/SPEC_board_memory_map.md address plan v4) "
                 "for every ct_trace_sinks design (tgc5b2/duo/trio, package U6) and "
                 "for rocket2. The tops that still wire their own sink (rocket, "
                 "cva6_2, cva6_linux, cva6_linux64) reset to 0x6000_0000 -- read the "
                 "register, do not assume it. Keep inside the reserved window when "
                 "reconfiguring.",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "rw", "hw": "r",
                     "reset": 0x50000000,
                     "desc": "PS DDR byte address (32-byte aligned).",
                     # The rule is hardware now, no longer just text:
                     # ct_trace_sinks.sv:203-222 does NOT accept the write
                     # while ddr_en=1 and reports it in SINK_STAT b4. On the
                     # tops with their own sink wiring the older behaviour
                     # still applies (the write goes through).
                     # The hardware interlock only covers the ARMED sink --
                     # with ddr_en=0 it accepts any value (proven on the
                     # board: 0x8000_0000, readback identical). The dashboard
                     # therefore locks both window registers by POLICY:
                     # display instead of an input field, /api/write answers
                     # 403. `sw` stays "rw" -- that is the HARDWARE truth, and
                     # a register map that falsifies it would be the next
                     # piece of documentation drift.
                     "policy_ro": True,
                     "access_rule": "READ-ONLY BY POLICY in the dashboard (U9): the window "
                                    "is fixed by the bitstream reset and by the boot "
                                    "reserved-memory region -- /api/write answers 403 for "
                                    "this register, and the panel shows it without an input "
                                    "field. The HARDWARE is weaker: a write while the sink "
                                    "is armed is REFUSED (U6 interlock, SINK_STAT b4 "
                                    "ddr_cfg_rej), but at ddr_en=0 it is taken, and on the "
                                    "older tops with their own sink wiring it is taken even "
                                    "while the AXI write master is RUNNING"}]},
        {"region": "ctrl", "offset": 0x20, "path": "soc.DDR_SIZE", "name": "DDR Sink Buffer Size",
         "desc": "Capture buffer size in bytes (multiple of 4; configurable from the "
                 "DDR panel). Reset 0x1000_0000 (256 MiB, address plan v4: the trace "
                 "window 0x5000_0000..0x5FFF_FFFF, 64 MiB clear of the guest code "
                 "window at 0x6400_0000). The tops with their own sink wiring still "
                 "reset to 0x0400_0000 (64 MiB). One shot: when full, "
                 "SINK_STAT.ddr_full sets and further beats are dropped (counted). "
                 "Circular: write offset wraps modulo this size.",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "rw", "hw": "r",
                     "reset": 0x10000000,
                     "desc": "Buffer size in bytes; 0 disables writes.",
                     # The same policy as for DDR_BASE -- a size that reaches
                     # past the reservation is as dangerous as a wrong base
                     # (the master then writes beyond the reserved window).
                     "policy_ro": True,
                     "access_rule": "READ-ONLY BY POLICY in the dashboard (U9): a size that "
                                    "reaches past the reserved region is as dangerous as a "
                                    "wrong base -- /api/write answers 403 for this register "
                                    "and the panel shows it without an input field. The "
                                    "HARDWARE is weaker: a write while the sink is armed is "
                                    "REFUSED (U6 interlock, SINK_STAT b4 ddr_cfg_rej, it "
                                    "would let one burst escape the buffer), but at "
                                    "ddr_en=0 it is taken, and on the older tops with their "
                                    "own sink wiring it changes the wrap point of a RUNNING "
                                    "capture"}]},
        {"region": "ctrl", "offset": 0x24, "path": "soc.DDR_WPTR", "name": "DDR Sink Write Pointer",
         "desc": "TOTAL bytes written since last ddr_clear (monotonic, read-only). One "
                 "shot: host reads [DDR_BASE, DDR_BASE+min(WPTR,SIZE)). Circular: write "
                 "offset = WPTR % SIZE; chronological order = [off..SIZE) ++ [0..off) "
                 "once wrapped (same contract as the URAM ring).",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "r", "hw": "w", "reset": 0,
                     "desc": "Bytes written (completed AXI bursts only)."}]},
        {"region": "ctrl", "offset": 0x28, "path": "soc.SINK_STAT", "name": "Trace Sink Status",
         "desc": "Sink status flags (read-only; DDR bits cleared by ddr_clear).",
         "fields": [
             {"name": "ddr_full", "lsb": 0, "msb": 0, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: DDR buffer full in one-shot mode; further beats drop."},
             {"name": "ddr_axi_err", "lsb": 1, "msb": 1, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: an AXI write returned BRESP != OKAY (sticky)."},
             {"name": "ddr_wrapped", "lsb": 2, "msb": 2, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: circular DDR buffer wrapped at least once (oldest bytes "
                      "overwritten)."},
             {"name": "uram_stopped", "lsb": 3, "msb": 3, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: URAM one-shot capture stopped (buffer full, first 1 MiB kept)."},
             # This bit closed the class "the display keeps a state to
             # itself": without it the operator only sees that the value did
             # not arrive, and takes that for masking (WARL) rather than for
             # a refusal.
             {"name": "ddr_cfg_rej", "lsb": 4, "msb": 4, "sw": "r", "hw": "w", "reset": 0,
              "desc": "1: a DDR_BASE/DDR_SIZE write was REFUSED because the sink was "
                      "armed (ddr_en=1) -- sticky until ddr_clear (U6 window "
                      "interlock, ct_trace_sinks.sv). Reads 0 on the pre-U6 "
                      "bitstreams and on the tops that wire their own sink; there "
                      "the write is taken over while the master runs."},
         ]},
        {"region": "ctrl", "offset": 0x2C, "path": "soc.DDR_DROPS", "name": "DDR Sink Dropped Beats",
         "desc": "Beats dropped by the DDR sink (FIFO overflow or buffer full; "
                 "saturating; read-only).",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "r", "hw": "w", "reset": 0,
                     "desc": "Dropped beats since ddr_clear."}]},
        {"region": "ctrl", "offset": 0x30, "path": "soc.PIB_DROPS", "name": "PIB Dropped Beats",
         "desc": "Beats dropped by the PIB sink (FIFO overflow when the port rate is "
                 "below the trace rate; saturating; read-only).",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "r", "hw": "w", "reset": 0,
                     "desc": "Dropped beats since pib_clear."}]},
        {"region": "ctrl", "offset": 0x38, "path": "soc.DDR_BEATS", "name": "DDR Sink Beat Counter",
         "desc": "Beats offered to the DDR sink while ddr_en (accepted = BEATS - "
                 "DDR_DROPS; cleared by ddr_clear; read-only) -- the cheap proof that "
                 "beats reach the sink at all. NOTE: this counter sat at 0x30 in the "
                 "tgc5b2 C0B_DDR build; since the shared three-sink subsystem (T2, "
                 "ct_trace_sinks) it lives at 0x38 for ALL designs and 0x30 is "
                 "PIB_DROPS (docs/SPEC_axis_wp_memory_map.md §9).",
         "fields": [{"name": "Value", "lsb": 0, "msb": 31, "sw": "r", "hw": "w", "reset": 0,
                     "desc": "Beats offered to the DDR sink since ddr_clear."}]},
    ]

    # Encoder 1 (TGC5B): identical RDL register list, its own region. The
    # dashboard code picks the region by pipeline row; the register data are
    # NOT duplicated here (regs apply to enc; enc1 is read and written in the
    # UI through the region alias).

    # Every field carries an access_rule -- including the hand-written ones
    # above. The UI must be able to rely on that key; a field without a rule
    # would be back to the blanket "rw" this work set out to abolish.
    for r in ctrl_regs:
        for f in r["fields"]:
            f.setdefault("access_rule", access_rule(f))

    out = {
        "generated_from": str(RDL.relative_to(REPO)).replace("\\", "/"),
        "profile": "FULL (Vollausstattung, no CT_PROFILE_NO_* defines)",
        "regions": REGIONS,
        "regs": ctrl_regs + regs,
        "mems": mems,
    }
    OUT.write_text(json.dumps(out, indent=1), encoding="utf-8")
    n_fields = sum(len(r["fields"]) for r in out["regs"])
    print(f"regmap.json: {len(out['regs'])} regs / {n_fields} fields / {len(mems)} mems "
          f"-> {OUT} ({OUT.stat().st_size//1024} KiB)")


if __name__ == "__main__":
    main()
