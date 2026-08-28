#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""N-Trace I-CNT field-width conformance check on a recorded ATB stream.

The N-Trace 1.0 program-trace messages carry their instruction count in a
VARIABLE field whose maximum is 8 bit (`NEXUS_MSG_I_CNT_WIDTH`), i.e. values
<= 255; the Accemic wide-ICNT compression (`trTeInstFeatures.InstEnWideIcnt`)
raises that to 16 bit.  Because the field is MSEO-variable-length, an over-cap
value is NOT a decode failure -- NexRv reads it, the PC stream stays lossless,
and every decode gate, PC comparison and byte-neutrality gate in this tree stays
green while the stream has left the standard.  This script is the channel that
sees it on the wire; `a_i12_*` in rtl/ct_L2_msg_gen.sv is the same check one
level up, inside the encoder.

Two carriers of an instruction count exist and both are checked:

  * the `ICNT` field of an ICNT-bearing message, and
  * `RDATA` of a ResourceFull whose `RCODE` is 0 (ICNT_OVERFLOW).  RCODE 1 and
    2 put a history pattern and a repeat count there and are NOT bound by the
    I-CNT width, hence the RCODE gate.

Input is the transcript of `NexRv -dump <atb.bin>`, whose field lines look like

    0x0D 000011_01: ICNT[10]=0x34 (52)
    0x80 100000_00: RCODE[4]=0x0 (0)
    0xFD 111111_01: RDATA[8]=0xfe (254)

The bracketed number is the number of WIRE bits the variable field occupies,
which is a multiple of the 6-bit MDO chunk and therefore regularly larger than
the cap -- it is the VALUE that is capped, never the wire width.  Mixing the
two up would report every second message as a violation.

  usage: check_icnt_cap.py --dump <file> [--cap 255] [--expect-over]
         check_icnt_cap.py --atb <file> [--nexrv <exe>] [--cap 255]

Exit 0 = conformant (or, with --expect-over, the demanded violation was found),
1 = verdict failed, 2 = usage/tooling problem.  --expect-over is for the RED
counter-proof leg of a gate: a check that has never been red proves nothing.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

FIELD = re.compile(r"(\w+)\[(\d+)\]=0x([0-9a-fA-F]+) \((\d+)\)")
MSG = re.compile(r"TCODE\[6\]=(\d+) \(MSG #(\d+)\) - (\S+)")


def scan(text, cap):
    """Return the list of over-cap instruction-count fields in a dump."""
    hits = []
    tcode, index, name = "?", "?", "?"
    rcode = None
    for line in text.splitlines():
        m = MSG.search(line)
        if m:
            tcode, index, name = m.groups()
            # RCODE belongs to the message it was read in, so it must not
            # leak across a message boundary into the next RDATA.
            rcode = None
            continue
        for field, width, _hexval, decimal in FIELD.findall(line):
            value = int(decimal)
            if field == "RCODE":
                rcode = value
                continue
            if field == "ICNT" and value > cap:
                hits.append((index, tcode, name, "ICNT", int(width), value))
            elif field == "RDATA" and rcode == 0 and value > cap:
                hits.append((index, tcode, name, "RDATA(RCODE=0)",
                             int(width), value))
    return hits


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--dump", help="transcript of NexRv -dump")
    src.add_argument("--atb", help="ATB binary; dumped with --nexrv")
    ap.add_argument("--nexrv", default=os.environ.get("NEXRV", ""),
                    help="NexRv executable (default: $NEXRV)")
    ap.add_argument("--cap", type=int, default=255,
                    help="I-CNT cap in force: 255 narrow, 65535 wide")
    ap.add_argument("--expect-over", action="store_true",
                    help="INVERT the verdict: demand at least one violation "
                         "(red counter-proof leg)")
    ap.add_argument("--label", default="",
                    help="prefix for the verdict line")
    args = ap.parse_args()

    if args.dump:
        try:
            with open(args.dump, "r", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            print(f"check_icnt_cap: cannot read {args.dump}: {exc}")
            return 2
    else:
        if not args.nexrv or not os.path.exists(args.nexrv):
            print("check_icnt_cap: no NexRv -- pass --nexrv or set $NEXRV")
            return 2
        if not os.path.exists(args.atb):
            print(f"check_icnt_cap: no ATB stream at {args.atb}")
            return 2
        if os.path.getsize(args.atb) == 0:
            print(f"check_icnt_cap: {args.atb} is EMPTY -- nothing was traced, "
                  "which is not a conformance verdict")
            return 2
        run = subprocess.run([args.nexrv, "-dump", args.atb],
                             capture_output=True, text=True)
        text = run.stdout

    if not MSG.search(text):
        print("check_icnt_cap: the dump carries no message at all -- refusing "
              "to call that conformant")
        return 2

    total = len(MSG.findall(text))
    hits = scan(text, args.cap)
    tag = f"{args.label}: " if args.label else ""

    for index, tcode, name, field, width, value in hits[:12]:
        print(f"  {tag}MSG #{index} TCODE {tcode} {name}: "
              f"{field}[{width} wire bits] = {value} > cap {args.cap}")
    if len(hits) > 12:
        print(f"  {tag}... {len(hits) - 12} further violation(s)")

    if args.expect_over:
        if hits:
            print(f"{tag}PASS (red leg): {len(hits)} over-cap field(s) in "
                  f"{total} message(s) -- the check can go red")
            return 0
        print(f"{tag}FAIL (red leg): {total} message(s), NOT ONE over-cap "
              f"field. The mutation did not take effect, so the green leg "
              f"proves nothing")
        return 1

    if hits:
        print(f"{tag}FAIL: {len(hits)} of the instruction-count fields in "
              f"{total} message(s) exceed the {args.cap} cap")
        return 1
    print(f"{tag}PASS: every instruction-count field in {total} message(s) "
          f"is within the {args.cap} cap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
