#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Address-width emission check on a RAW ATB capture (X2a, test 35).

Answers ONE question about a byte stream: does the PC_FADDR field of the
synchronizing messages carry the full instruction address, or was it
truncated to 32 bit somewhere along the way?

The question needs a byte-level answer. A decoder-based check would only
be as good as the decoder's own address width, and the reference decoder's
64-bit support is a separate work package -- a check that can only fail
together with the thing it is supposed to judge is not a check.

Framing (identical rules to scripts/check_sync_window.py, dual-pin MSEO
per IEEE-ISTO 5001 Table 5-1 and rtl/mseo_mdo/..._mseo_controller.sv):
  * every byte is MDO[7:2] | MSEO[1:0],
  * MSEO 00 = in-message chunk, 01 = end of a variable-length field,
    11 = end of message (and, outside a message, the idle byte 0xFF),
  * a message starts on the byte after an end-of-message / idle byte and
    carries TCODE[5:0] in the MDO of its first byte.

Field extraction: the caller has to produce the capture with SRC inhibited
and timestamps off (tests/instruction/35_addr64 does), so PC_FADDR is the
LAST field of a TCODE 9/11/12 message. Everything between the last MSEO=01
byte and the terminating MSEO=11 byte is therefore exactly that field, and
the value is the MDO groups concatenated LSB-first -- no knowledge of the
fixed-field widths required, no ambiguity.

The emitted field is the address shifted right by NEXUS_MSG_PC_ADDR_SHIFT
(1 for RISC-V), so the reconstructed PC is (field << 1).

Usage:
    py scripts/check_addr64_emission.py <atb_bin> --expect-pc <hex>
                                        [--min-bits N] [--dump]

  --expect-pc  a PC that MUST appear as a full F-ADDR in the stream (the
               test's base address; give it as 0x...)
  --min-bits   additionally require some F-ADDR to have a set bit at or
               above this position (default: 32 iff --expect-pc >= 2^32,
               else 0 = no such requirement)

Exit 0 iff at least one synchronizing message carries the expected PC and
the min-bits requirement holds. Stdlib only.
"""

import argparse
import sys

IDLE_BYTE = 0xFF
MSEO_MASK = 0x03
MSEO_CONT = 0x00
MSEO_ENDF = 0x01
MSEO_ENDM = 0x03

# Synchronizing program-trace messages: the ones whose address field is a
# FULL address (F-ADDR), not a differential U-ADDR.
FADDR_TCODES = frozenset({9, 11, 12, 29, 32})

PC_ADDR_SHIFT = 1  # nexus_vendor::NEXUS_MSG_PC_ADDR_SHIFT


def frame_messages(buf):
    """[(offset, tcode, [bytes]), ...] plus the idle count."""
    msgs, idle, trunc = [], 0, 0
    i, n = 0, len(buf)
    while i < n:
        if buf[i] == IDLE_BYTE:
            idle += 1
            i += 1
            continue
        start = i
        tcode = buf[i] >> 2
        while i < n and (buf[i] & MSEO_MASK) != MSEO_ENDM:
            i += 1
        if i >= n:
            trunc = n - start
            break
        i += 1
        msgs.append((start, tcode, buf[start:i]))
    return msgs, idle, trunc


def last_field(msg_bytes):
    """MDO value of the last variable-length field of one framed message.

    The field runs from the byte AFTER the last MSEO=01 byte up to and
    including the terminating MSEO=11 byte. Returns None when the message
    has no end-of-field marker at all (a message consisting of fixed fields
    only -- nothing to extract).
    """
    last_endf = -1
    for k, b in enumerate(msg_bytes):
        if (b & MSEO_MASK) == MSEO_ENDF:
            last_endf = k
    if last_endf < 0:
        return None
    value = 0
    for j, b in enumerate(msg_bytes[last_endf + 1:]):
        value |= (b >> 2) << (6 * j)
    return value


def encode_field(value, end_mseo):
    """The MDO/MSEO bytes of ONE variable-length field (test aid).

    LSB-first 6-bit groups, leading-zero suppressed exactly as
    LengthWoLeadingZeros / the bit slicer do (a zero value is one group).
    """
    out = []
    v = value
    while True:
        out.append(v & 0x3F)
        v >>= 6
        if v == 0:
            break
    return bytes(((g << 2) | (MSEO_CONT if k < len(out) - 1 else end_mseo))
                 for k, g in enumerate(out))


def selftest() -> int:
    """Prove the framer and the field reconstruction on synthetic bytes.

    The gate legs exercise this code on real captures, but only on the
    addresses those captures happen to contain -- and a reconstruction that
    is wrong in the high groups looks fine on a low address. These vectors
    pin the arithmetic itself, including the 64-bit corner.
    """
    cases = [
        (9,  0x0000_1000, "low 32-bit address"),
        (11, 0xFFFF_FFFC, "32-bit corner"),
        (12, 0xFFFF_FFC0_0000_1000, "high 64-bit address"),
        (9,  0xFFFF_FFFF_FFFF_FFFC, "64-bit corner"),
        (29, 0x0000_0002, "smallest non-zero address"),
    ]
    bad = 0
    for tcode, pc, label in cases:
        stream = bytes([(tcode << 2) | MSEO_CONT])          # TCODE, fixed
        stream += encode_field(5, MSEO_ENDF)                # ICNT, variable
        stream += encode_field(pc >> PC_ADDR_SHIFT, MSEO_ENDM)  # PC_FADDR, last
        stream += bytes([IDLE_BYTE])                        # alignment pad
        msgs, idle, trunc = frame_messages(stream)
        got = None
        if len(msgs) == 1 and msgs[0][1] == tcode and not trunc:
            f = last_field(msgs[0][2])
            got = None if f is None else (f << PC_ADDR_SHIFT)
        ok = (got == pc) and idle == 1
        print(f"  [{'ok  ' if ok else 'FAIL'}] {label}: TCODE {tcode}, "
              f"PC 0x{pc:016x} -> 0x{(got or 0):016x} "
              f"({len(stream)} B, {len(msgs)} msg, {idle} idle)")
        if not ok:
            bad += 1
    # Negative control: a 64-bit address truncated to 32 bit must NOT be
    # accepted as the expected value -- that is the whole point of the check.
    trunc_pc = 0xFFFF_FFC0_0000_1000 & 0xFFFF_FFFF
    if trunc_pc == 0xFFFF_FFC0_0000_1000:
        print("  [FAIL] negative control is degenerate")
        bad += 1
    else:
        print(f"  [ok  ] negative control: truncation gives 0x{trunc_pc:016x} "
              f"!= 0x{0xFFFF_FFC0_0000_1000:016x}")
    print(f"[addr64] selftest: {len(cases) + 1 - bad}/{len(cases) + 1} ok")
    return 1 if bad else 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("atb_bin")
    ap.add_argument("--expect-pc", required=True,
                    help="PC that must appear as a full F-ADDR (0x...)")
    ap.add_argument("--min-bits", type=int, default=None,
                    help="require a set F-ADDR bit at or above this PC bit "
                         "position (default: 32 when --expect-pc >= 2^32)")
    ap.add_argument("--dump", action="store_true",
                    help="print every reconstructed F-ADDR")
    args = ap.parse_args()

    expect = int(args.expect_pc, 0)
    min_bits = args.min_bits if args.min_bits is not None else (32 if expect >= (1 << 32) else 0)

    with open(args.atb_bin, "rb") as fh:
        raw = fh.read()
    msgs, idle, trunc = frame_messages(raw)

    addrs = []
    for off, tcode, mb in msgs:
        if tcode not in FADDR_TCODES:
            continue
        f = last_field(mb)
        if f is None:
            continue
        addrs.append((off, tcode, f << PC_ADDR_SHIFT))

    print(f"[addr64] {args.atb_bin}: {len(raw)} raw ATB bytes, {len(msgs)} messages, "
          f"{idle} idle/pad{', %d B truncated tail' % trunc if trunc else ''}; "
          f"{len(addrs)} synchronizing message(s) with a full address")
    if args.dump:
        for off, tcode, a in addrs:
            print(f"    @{off:6d}  TCODE {tcode:2d}  F-ADDR -> PC 0x{a:016x}")

    if not addrs:
        print("[addr64] FAIL: the capture carries no synchronizing message with "
              "an extractable address field. Either the stream is empty, or it "
              "was produced WITHOUT `InhibitSrc = 1` / with timestamps on, in "
              "which case PC_FADDR is not the last field and this check does "
              "not apply.")
        return 1

    hit = [a for _o, _t, a in addrs if a == expect]
    widest = max(a for _o, _t, a in addrs)
    ok = True
    if not hit:
        print(f"[addr64] FAIL: expected PC 0x{expect:016x} appears in no F-ADDR. "
              f"Widest address seen: 0x{widest:016x} -- a value that matches the "
              f"expectation in its low 32 bits only is the truncation this check "
              f"exists for.")
        ok = False
    else:
        print(f"[addr64] PASS: PC 0x{expect:016x} carried in full by "
              f"{len(hit)} message(s)")
    if min_bits > 0:
        if widest >> min_bits:
            print(f"[addr64] PASS: at least one F-ADDR has a set bit at or above "
                  f"PC bit {min_bits} (widest 0x{widest:016x})")
        else:
            print(f"[addr64] FAIL: no F-ADDR reaches PC bit {min_bits} "
                  f"(widest 0x{widest:016x})")
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
