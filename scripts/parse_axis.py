#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Parse the AXIS instrumentation capture of the TGC5B + CEDARtools.TraceEncoder KV260 app.
#
# Input (stdin): the AXIS BRAM dump as one hex word per line — 4 words per
# beat, exactly as `devmem` prints them when reading AXIS_BEATS * 4 words
# from 0xA030_0000 (see the README's watchpoint walkthrough):
#   word 0..2  tdata elem0..2 (32-bit each)
#   word 3     {tlast[20], tid[19:12], tkeep[11:0]}
# Output: one text line per DAQ beat (command name, elements, flags).
#
# The buffer holds AXIS_DEPTH = 256 beats (4 KiB); reads past that alias back to
# beat 0, so a dump longer than 1024 words is flagged instead of parsed as new
# beats.
#
# Usage: ssh <board> '...devmem dump...' | parse_axis.py [> beats.txt]

import signal
import sys

# Plain filter behaviour: `parse_axis.py | head` must not raise BrokenPipeError.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)

# ct_soc_axis_buf DEPTH (ct_soc_top AXIS_DEPTH), in beats of four 32-bit words.
AXIS_DEPTH = 256

# trActCapStCmd_e (rdl/ct_cs_cpuif.rdl); tid[5:0] carries the command.
CMD = {
    0:  "NONE",
    1:  "DAQ_PC_CURR",
    2:  "DAQ_PC_CURR_LAST",
    3:  "DAQ_DIRECT_DATA",
    4:  "DAQ_DATA",
    5:  "DAQ_DADDR",
    6:  "DAQ_DATA_DADDR",
    8:  "DAQ_IFETCH_TH",
    9:  "DAQ_DATA_RD_TH",
    10: "DAQ_DATA_WR",
    11: "DAQ_DATA_RD",
    12: "CF_SYNC",
    13: "TE",
}

words = [int(t, 16) for t in sys.stdin.read().split()
         if t.strip().lower().startswith("0x")]

if len(words) % 4:
    print("warning: %d words is not a whole number of 4-word beats — trailing "
          "partial record ignored" % len(words), file=sys.stderr)
if len(words) > 4 * AXIS_DEPTH:
    print("warning: %d words exceed the %d-beat buffer (%d words) — the extra "
          "records are aliased re-reads of beat 0 onwards"
          % (len(words), AXIS_DEPTH, 4 * AXIS_DEPTH), file=sys.stderr)

print("beat | cmd (tid[5:0])       | last | tkeep | elem0      elem1      elem2")
print("-----+----------------------+------+-------+---------------------------------")
for i in range(len(words) // 4):
    e0, e1, e2, meta = words[i*4:i*4+4]
    tkeep = meta & 0xFFF
    tid   = (meta >> 12) & 0xFF
    tlast = (meta >> 20) & 1
    cmd   = tid & 0x3F
    print("%4d | %2d %-18s |  %d   | 0x%03X | 0x%08X 0x%08X 0x%08X"
          % (i, cmd, CMD.get(cmd, "?"), tlast, tkeep, e0, e1, e2))
