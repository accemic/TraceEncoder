#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""check_memory_kind.py -- did the shared memory really become UltraRAM?

WHY THIS EXISTS
---------------
`(* ram_style = "ultra" *)` is a REQUEST. Vivado is free to ignore it, and
when it does, nothing fails: the design still builds, the simulation is
unaffected, and the memory quietly becomes block RAM.

That happened on this design. The first version of `ct_soc_shared_mem` gave
each port a separate read process and a separate write process, so Vivado saw

    [Synth 8-7217] RAM identified as Multi-port RAM (2 WRite and 2 Read)

and built a multi-port EMULATION -- the array replicated per read port. That
cannot be UltraRAM, so 256 KiB landed in ~64 block RAMs on a design already
at 73 % BRAM. The attribute was still in the source, still ignored, and the
only symptom was a utilization report nobody had been asked to read.

So the report is read here, by a script, as part of the build gate. A
verdict that depends on someone noticing a line among ten thousand is not a
verdict.

USAGE
    py check_memory_kind.py <utilization.rpt> [--min-uram N] [--max-bram N]

Exits non-zero and says what it expected if the numbers disagree.
"""

import argparse
import re
import sys


def parse_utilization(path):
    """Pull the design-wide BRAM tile and URAM counts out of a Vivado report."""
    bram = uram = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            # e.g. "| Block RAM Tile    | 105.5 |     0 |          0 |  144 | 73.26 |"
            m = re.match(r"\|\s*Block RAM Tile\s*\|\s*([0-9.]+)\s*\|", line)
            if m and bram is None:
                bram = float(m.group(1))
            m = re.match(r"\|\s*URAM\s*\|\s*([0-9.]+)\s*\|", line)
            if m and uram is None:
                uram = float(m.group(1))
    return bram, uram


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report")
    ap.add_argument("--min-uram", type=float, default=48.0,
                    help="expected URAM blocks: 32 for the trace ring + 16 for "
                         "a 256 KiB shared memory at 32-bit width")
    ap.add_argument("--max-bram", type=float, default=120.0,
                    help="BRAM tiles must NOT grow: the reference design sits "
                         "at 105.5 and the shared memory must cost none of them")
    args = ap.parse_args()

    bram, uram = parse_utilization(args.report)
    if bram is None or uram is None:
        print("MEMKIND_FAIL: could not find the BRAM/URAM rows in %s" % args.report)
        return 2

    print("BRAM tiles: %s   URAM blocks: %s" % (bram, uram))
    ok = True
    if uram < args.min_uram:
        print("MEMKIND_FAIL: URAM %s < %s -- the shared memory did NOT become "
              "UltraRAM. Look for 'Multi-port RAM' in the synthesis log: the "
              "template needs ONE process per port with ONE address, doing the "
              "write and the read together (ct_soc_shared_mem.sv @details 3)."
              % (uram, args.min_uram))
        ok = False
    if bram > args.max_bram:
        print("MEMKIND_FAIL: BRAM %s > %s -- something that should be UltraRAM "
              "landed in block RAM." % (bram, args.max_bram))
        ok = False

    if ok:
        print("MEMKIND_OK: shared memory is UltraRAM, BRAM budget untouched")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
