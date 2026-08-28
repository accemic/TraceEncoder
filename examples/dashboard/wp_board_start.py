#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""wp_board_start.py -- start the AXIS watchpoint demo program on the board.

Runs as root on the KV260, from the dashboard directory next to
`axis_wp_host/`. The sequence is g0_board.py `run` WITHOUT the FIFO
init/drain/stop steps:

    Safety checks (fpga_manager==operating, WPCTRL magic "AWP1")
    -> hold the cores + trace_clear
    -> prog.hex into BOTH RAMs (the RAM window is only reachable while
       core_run=0 -- the SoC muxes it)
    -> WALK_CTRL@0xE800 (1 = endless walk)
    -> the WP table of both encoders (ENCx+0x4100+8i, address then command)
    -> features read-modify-write (SrcBits=2, SrcID 0/1)
       + trTeControl := 0x0106_0067
    -> start the cores -- and LEAVE THEM RUNNING.

The FIFO windows (0xA041/42_0000) are DELIBERATELY not touched here: reading
RDFD is destructive, and the only FIFO reader is the drain thread of the
dashboard server (wp_view.py). No RDFR reset either -- the server drains
continuously and clears anything left over by itself; two processes on the
same RLR/RDFD sequence would both see garbled words.

Prerequisites: app `tgc5b2_axis_wp` loaded (PL at 75 MHz!), and /tmp/g0 with
prog.hex + wp_table.txt (the G0 runner puts both there with `-Phase gen` and
`-Phase deploy`). To stop: CONTROL := 0 (devmem 0xA0000000 32 0), or switch
or reload the dashboard scenario.
"""
import argparse
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
for _cand in (HERE, HERE.parent):
    if (_cand / "axis_wp_host" / "fifo_mm_s.py").is_file():
        sys.path.insert(0, str(_cand))
        break
from axis_wp_host.fifo_mm_s import DevMemBus   # noqa: E402

CTRL_BASE = 0xA0000000
ENC_BASE = [0xA0010000, 0xA0020000]
RAM_BASE = [0xA0100000, 0xA0080000]      # Index = Core: RAM0, RAM1
WPCTRL_BASE = 0xA0400000
MAGIC_EXP = 0x41575031                   # "AWP1"
WALK_OFF = 0xE800
WP_OFF = 0x4100
TE_CONTROL = 0x01060067


def log(s):
    print("H|" + s, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--walk", type=int, choices=(0, 1), default=1,
                    help="1 = endless walk (default), 0 = finite (64 phases)")
    ap.add_argument("--hex", default="/tmp/g0/prog.hex")
    ap.add_argument("--wp", default="/tmp/g0/wp_table.txt")
    a = ap.parse_args()

    st = open("/sys/class/fpga_manager/fpga0/state").read().strip()
    if st != "operating":
        log("FAIL fpga_manager state=%s (do NOT touch the aperture)" % st)
        return 7
    wp = DevMemBus(WPCTRL_BASE, 0x1000)
    magic = wp.r1(0x00)
    if magic != MAGIC_EXP:
        log("FAIL MAGIC 0x%08x != 0x%08x (wrong design in the slot?)"
            % (magic, MAGIC_EXP))
        return 7
    log("MAGIC OK, FIFO_WORDS=%d SHIM_RECS=%d" % (wp.r1(0x24), wp.r1(0x28)))

    ctrl = DevMemBus(CTRL_BASE, 0x1000)
    ctrl.write(0, 0)                     # Cores sicher gehalten
    ctrl.write(0, 2)                     # trace_clear
    ctrl.write(0, 0)
    log("CTRL cores held, trace_clear pulsed (status=0x%08x)" % ctrl.r1(4))

    words = [int(s, 16) for s in
             Path(a.hex).read_text(encoding="utf-8").split() if s.strip()]
    rams = [DevMemBus(RAM_BASE[c], 0x10000) for c in (0, 1)]
    for c in (0, 1):
        for i, w in enumerate(words):
            rams[c].write(4 * i, w)
        for idx in (0, len(words) // 2, len(words) - 1):
            if rams[c].r1(4 * idx) != words[idx]:
                log("FAIL RAM%d readback[%d]" % (c, idx))
                return 3
        rams[c].write(WALK_OFF, a.walk)
        if rams[c].r1(WALK_OFF) != a.walk:
            log("FAIL RAM%d WALK_CTRL rb" % c)
            return 3
        log("RAM%d: %d words + WALK_CTRL=%d (rb OK)" % (c, len(words), a.walk))

    table = []
    for line in Path(a.wp).read_text(encoding="utf-8").splitlines():
        p = line.split()
        if len(p) >= 3:
            table.append((int(p[0]), int(p[1], 16), int(p[2], 16)))
    encs = [DevMemBus(ENC_BASE[c], 0x5000) for c in (0, 1)]
    for c in (0, 1):
        for i, addr, cmd in table:
            encs[c].write(WP_OFF + 8 * i, addr)
            encs[c].write(WP_OFF + 8 * i + 4, cmd)
        rb = (encs[c].r1(WP_OFF), encs[c].r1(WP_OFF + 4))
        log("ENC%d WP table %d slots (slot0 rb 0x%08x/0x%08x)"
            % (c, len(table), rb[0], rb[1]))
        f = encs[c].r1(0x08)
        encs[c].write(0x08, (f & 0x0000FFFF) | (2 << 28) | (c << 16))
        encs[c].write(0x00, TE_CONTROL)
        log("ENC%d armed (feat rb 0x%08x, trTeControl rb 0x%08x)"
            % (c, encs[c].r1(0x08), encs[c].r1(0x00)))

    ctrl.write(0, 1)
    log("CORES started (walk=%s) -- the dashboard server drains the FIFOs"
        % ("endless" if a.walk else "finite"))
    time.sleep(0.2)
    log("WPCTRL after 200 ms: drop0=%d fill0=%d drop1=%d fill1=%d"
        % (wp.r1(0x04), wp.r1(0x08), wp.r1(0x10), wp.r1(0x14)))
    log("START_DONE")
    return 0


if __name__ == "__main__":
    if os.name != "posix":
        print("H|FAIL runs on the board only (needs /dev/mem)")
        sys.exit(2)
    sys.exit(main())
