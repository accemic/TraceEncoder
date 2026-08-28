#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""wp_board.py -- G1 board sequence (runs as root ON the KV260), C0b build.

Ported from the predecessor repository's g1_board.py unchanged in substance (register map,
sys.exit codes, and the two structured log lines wp_check.py's regexes
depend on -- `RUN_STATE drops0=...` and `SCRATCH core%d phase=...end-of-walk
marker` -- are byte-identical to the source; only docstrings/comments were
translated to English and the sibling-module names below follow this
example's renaming (g1_gen.py -> wp_gen.py stays host-side and is not
needed here; g1_check.py -> wp_check.py, also host-side)).

Differs from a hypothetical "direct WP window" variant the way the source
differed from its own D1 predecessor:
  * watchpoints are loaded INDIRECTLY via wp_load_indirect.py -- the direct
    window ENCx+0x4100 does not exist in this (C0b) bitstream (see
    docs/SPEC_axis_wp_memory_map.md Sec.7 in the encoder source repo);
  * trTsControl is RMW'd onto TR_TS_CORE before arming (W2 = fabric_time);
  * NO drain happens here: the FIFO windows belong EXCLUSIVELY to the F1
    reader (read_wp_stream.py --source fifo, single-master discipline) --
    this script never touches 0xA041/2_0000.

Subcommands: prep --walk {0,1} | start | stop | status
(each invocation does fresh mmaps -- state lives in the hardware, not in
this process).

HARD RULE: never touch the RAM windows while core_run=1 (SoC mux); every PL
access requires fpga_manager==operating + the MAGIC proof first.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fifo_mm_s import DevMemBus            # noqa: E402
import wp_load_indirect as wpi             # noqa: E402

CTRL_BASE = 0xA0000000
ENC_BASE = [0xA0010000, 0xA0020000]
RAM_BASE = [0xA0100000, 0xA0080000]      # index = core: RAM0, RAM1
WPCTRL_BASE = 0xA0400000
MAGIC_EXP = 0x41575031                   # "AWP1"
WALK_OFF = 0xE800
SCRATCH_OFF = 0xE000
OFF_TE_CONTROL = 0x000
OFF_FEATURES = 0x008
OFF_TS_CONTROL = 0x040
TE_CONTROL = 0x01060067
N_SLOTS = 1023


def log(s):
    print("G1|" + s, flush=True)


def fpga_state():
    with open("/sys/class/fpga_manager/fpga0/state") as f:
        return f.read().strip()


def wpctrl_dump(wp, tag):
    d0, f0, o0 = wp.r1(0x04), wp.r1(0x08), wp.r1(0x0C)
    d1, f1, o1 = wp.r1(0x10), wp.r1(0x14), wp.r1(0x18)
    log("%s shim0 drop=%d fill=%d ovf=%d | shim1 drop=%d fill=%d ovf=%d"
        % (tag, d0, f0, o0, d1, f1, o1))
    return (d0, f0, o0, d1, f1, o1)


def ftime(wp):
    lo = wp.r1(0x1C)                     # latches the 64-bit snapshot
    hi = wp.r1(0x20)
    return (hi << 32) | lo


def sanity():
    st = fpga_state()
    if st != "operating":
        log("FAIL fpga_manager state=%s (do not touch the aperture)" % st)
        sys.exit(7)
    wp = DevMemBus(WPCTRL_BASE, 0x1000)
    magic = wp.r1(0x00)
    if magic != MAGIC_EXP:
        log("FAIL MAGIC 0x%08x != 0x%08x" % (magic, MAGIC_EXP))
        sys.exit(7)
    return wp


def load_ram(ram, words, tag):
    for i, w in enumerate(words):
        ram.write(4 * i, w)
    for idx in (0, len(words) // 2, len(words) - 1):
        rb = ram.r1(4 * idx)
        if rb != words[idx]:
            log("FAIL %s readback[%d] 0x%08x != 0x%08x" % (tag, idx, rb,
                                                           words[idx]))
            sys.exit(3)
    log("%s loaded %d words (readback 0/mid/last OK)" % (tag, len(words)))


def ts_config(enc, tag):
    """trTsControl RMW (C1b ts_config): Active=1, Type=TR_TS_CORE(3),
    Enable(bit15)=0 -- no wire TSTAMP, the AXIS element follows Type;
    Width(29:24)=63 is preserved. MUST run before trTeControl.Enable
    (Type/Prescale are swwel-locked once armed)."""
    v = enc.r1(OFF_TS_CONTROL)
    nv = (v | 0x1) & ~0x8070 | (3 << 4)   # Active=1, Type=3, Enable=0
    enc.write(OFF_TS_CONTROL, nv)
    rb = enc.r1(OFF_TS_CONTROL)
    log("%s trTsControl 0x%08x -> 0x%08x (rb 0x%08x)" % (tag, v, nv, rb))
    if rb != nv:
        log("FAIL %s trTsControl readback (Type=TR_TS_CORE not set?)" % tag)
        sys.exit(5)


def enc_arm(enc, srcid, tag):
    f = enc.r1(OFF_FEATURES)
    nf = (f & 0x0000FFFF) | (2 << 28) | (srcid << 16)
    enc.write(OFF_FEATURES, nf)
    rb = enc.r1(OFF_FEATURES)
    enc.write(OFF_TE_CONTROL, TE_CONTROL)
    rc = enc.r1(OFF_TE_CONTROL)
    log("%s feat 0x%08x -> 0x%08x (rb 0x%08x), trTeControl rb 0x%08x"
        % (tag, f, nf, rb, rc))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prep")
    p.add_argument("--walk", type=int, choices=(0, 1), required=True)
    p.add_argument("--hex", default="/tmp/wp_board_run/prog.hex")
    p.add_argument("--wp", default="/tmp/wp_board_run/wp_table.txt")
    sub.add_parser("start")
    sub.add_parser("stop")
    sub.add_parser("status")
    a = ap.parse_args()

    wp = sanity()
    if a.cmd == "status":
        wpctrl_dump(wp, "STATUS")
        log("FTIME %d" % ftime(wp))
        return
    ctrl = DevMemBus(CTRL_BASE, 0x1000)

    if a.cmd == "start":
        ctrl.write(0, 1)
        log("CORES started (FTIME %d)" % ftime(wp))
        return

    if a.cmd == "stop":
        ctrl.write(0, 0)
        log("CORES stopped (FTIME %d)" % ftime(wp))
        final = wpctrl_dump(wp, "FINAL")
        rams = [DevMemBus(RAM_BASE[c], 0x10000) for c in (0, 1)]
        ph = [0, 0]
        for c in (0, 1):
            ph[c] = rams[c].r1(SCRATCH_OFF)
            s1 = rams[c].r1(SCRATCH_OFF + 4)
            s2 = rams[c].r1(SCRATCH_OFF + 8)
            log("SCRATCH core%d phase=%d acc=0x%08x end=0x%08x%s"
                % (c, ph[c], s1, s2,
                   " (end-of-walk marker)" if s2 == 0x0E0DDA7A else ""))
        log("RING status=0x%08x beats=%d bytes=%d"
            % (ctrl.r1(4), ctrl.r1(8), ctrl.r1(12)))
        log("RUN_STATE drops0=%d drops1=%d ovf0=%d ovf1=%d fill0=%d "
            "fill1=%d phase0=%d phase1=%d"
            % (final[0], final[3], final[2], final[5], final[1], final[4],
               ph[0], ph[1]))
        return

    # ---- prep ----
    log("MAGIC OK, FIFO_WORDS=%d SHIM_RECS=%d" % (wp.r1(0x24), wp.r1(0x28)))
    t0 = ftime(wp)
    time.sleep(0.01)
    t1 = ftime(wp)
    log("FTIME %d -> %d (delta %d in ~10 ms, expected ~750k @75 MHz)"
        % (t0, t1, t1 - t0))

    ctrl.write(0, 0)                     # cores held safe
    ctrl.write(0, 2)                     # trace_clear
    ctrl.write(0, 0)
    log("CTRL cores held, trace_clear pulsed (status=0x%08x)" % ctrl.r1(4))

    words = []
    with open(a.hex, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s:
                words.append(int(s, 16))
    rams = [DevMemBus(RAM_BASE[c], 0x10000) for c in (0, 1)]
    for c in (0, 1):
        load_ram(rams[c], words, "RAM%d" % c)
        rams[c].write(WALK_OFF, a.walk)
        rb = rams[c].r1(WALK_OFF)
        if rb != a.walk:
            log("FAIL RAM%d WALK_CTRL rb %d != %d" % (c, rb, a.walk))
            sys.exit(3)
    log("WALK_CTRL@0x%04X := %d (both RAMs, rb OK)" % (WALK_OFF, a.walk))

    table = []
    with open(a.wp, encoding="utf-8") as f:
        for line in f:
            p = line.split()
            if len(p) >= 3:
                i, addr, cmd = int(p[0]), int(p[1], 16), int(p[2], 16)
                # Drift guard: the file's cmd word must match the module rule.
                if cmd != wpi.cmd_word(addr, i):
                    log("FAIL wp_table slot %d: cmd 0x%08x != rule 0x%08x"
                        % (i, cmd, wpi.cmd_word(addr, i)))
                    sys.exit(4)
                table.append((addr, cmd))
    if len(table) != N_SLOTS:
        log("FAIL wp_table has %d slots != %d" % (len(table), N_SLOTS))
        sys.exit(4)

    encs = [DevMemBus(ENC_BASE[c], 0x5000) for c in (0, 1)]
    for c in (0, 1):
        tag = "ENC%d" % c
        prev = encs[c].r1(OFF_TE_CONTROL)
        encs[c].write(OFF_TE_CONTROL, 0)  # disarm: loading needs Enable=0
        log("%s disarm (trTeControl 0x%08x -> 0x%08x)"
            % (tag, prev, encs[c].r1(OFF_TE_CONTROL)))
        cap = wpi.read_cap(encs[c])
        log("%s trWpCap=%d" % (tag, cap))
        try:
            wpi.load_and_verify(encs[c], table, probe_slots=(0, 511, 1022),
                                log=lambda s, t=tag: log(t + " " + s))
        except wpi.WpLoadError as e:
            log("FAIL %s %s" % (tag, e))
            sys.exit(4)
        ts_config(encs[c], tag)
        enc_arm(encs[c], c, tag)
    wpctrl_dump(wp, "PRE-START")
    log("PREP_DONE walk=%d slots=%d" % (a.walk, len(table)))


if __name__ == "__main__":
    main()
