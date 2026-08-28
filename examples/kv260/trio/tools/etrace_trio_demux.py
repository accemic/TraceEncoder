#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""CTMX demultiplexer: ONE merged E-Trace container -> one `.te_inst_raw`
stream per source, byte-identical to a single-core capture.

Container (produced by `ct_L1_funnel` with EN_TE_RAW=1, see its header):

    Tag byte     1sssssss   bit 7 = 1, s = source/channel index (0..127)
    Packet       0mmlllll   bit 7 = 0, mm = msg_type, lllll = payload length
                 <payload>  exactly `lllll` bytes (any value, including bit 7 = 1)

The distinction is exact at a PACKET BOUNDARY (not heuristic): a header byte
always has bit 7 = 0, a tag byte always bit 7 = 1. Payload bytes are consumed
purely by length. The stream must therefore start at a packet boundary --
given for a one-shot capture from trace start; for a wrapped ring see
`--skip`/`--resync`.

Tags appear only on a source change (hardware default) or before every
packet (FUNNEL_CTRL b16 = TagAlways) -- the parser does not need to know
which convention is in effect.

Usage:
    py tools/etrace_trio_demux.py <container.bin> -o <prefix> [--sources 3]
        -> <prefix>.src0.te_inst_raw, <prefix>.src1.te_inst_raw, ...
Exit: 0 = demultiplexed cleanly, 1 = structural error (truncation, tag expected).

Migrated from an internal predecessor repository; referenced by trio_soc_top.sv's own
header comment as the host-side split tool for its E-Trace/CTMX dual-protocol
funnel output. Vendored into this example's own tools/ directory per this
migration's scope (a repository-wide tools/ tree does not exist yet).
"""
import argparse
import sys
from pathlib import Path

MSG_TYPES = {0: "TE_SUPPORT?", 1: "vendor/DAQ", 2: "TE_INST", 3: "TE_DATA?"}


def demux(data: bytes, start: int = 0):
    """-> (streams: dict[src] = bytearray, stats: dict, error: str|None)"""
    streams: dict[int, bytearray] = {}
    counts: dict[int, int] = {}
    mtypes: dict[int, dict[int, int]] = {}
    tags = 0
    src = None
    i = start
    n = len(data)
    while i < n:
        b = data[i]
        if b & 0x80:                      # source tag
            src = b & 0x7F
            tags += 1
            i += 1
            continue
        if src is None:
            return streams, {}, ("packet at offset %d without a preceding "
                                 "source tag (stream does not start at a "
                                 "packet boundary?)" % i)
        length = b & 0x1F
        mtype = (b >> 5) & 0x3
        if i + 1 + length > n:
            return streams, {}, ("packet at offset %d truncated (length %d, "
                                 "only %d bytes remaining)" % (i, length, n - i - 1))
        pkt = data[i:i + 1 + length]
        streams.setdefault(src, bytearray()).extend(pkt)
        counts[src] = counts.get(src, 0) + 1
        mtypes.setdefault(src, {})
        mtypes[src][mtype] = mtypes[src].get(mtype, 0) + 1
        i += 1 + length
    return streams, {"tags": tags, "packets": counts, "mtypes": mtypes,
                     "bytes": n - start}, None


def selftest() -> int:
    """Regression guard for exactly the cases that would break the parser:
    payload bytes with bit 7 set, zero-length packets, source changes,
    truncation, a missing start tag."""
    pkt = lambda mt, pl: bytes([(mt << 5) | len(pl)]) + bytes(pl)
    a, b = pkt(2, [0x80, 0xFF, 0x01]), pkt(2, [0x7F])
    c, z = pkt(1, [0x90, 0x80]), pkt(2, [])
    cont = bytes([0x80]) + a + b + bytes([0x82]) + c + bytes([0x80]) + z + a
    st, stats, err = demux(cont)
    assert err is None, err
    assert bytes(st[0]) == a + b + z + a, st[0].hex()
    assert bytes(st[2]) == c, st[2].hex()
    assert stats["tags"] == 3 and stats["packets"] == {0: 4, 2: 1}, stats
    assert demux(a)[2], "a packet without a start tag must be an error"
    assert demux(bytes([0x80]) + pkt(2, [1, 2, 3])[:-1])[2], "truncation must be an error"
    print("etrace_trio_demux: self-test OK (5 cases)")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    ap = argparse.ArgumentParser()
    ap.add_argument("container", help="merged container byte stream (CTMX)")
    ap.add_argument("-o", "--out-prefix", required=True)
    ap.add_argument("--sources", type=int, default=0,
                    help="expected source count; >0 = hard check that every "
                         "source delivered packets")
    ap.add_argument("--skip", type=int, default=0,
                    help="skip leading bytes (wrapped ring)")
    args = ap.parse_args()

    data = Path(args.container).read_bytes()
    streams, stats, err = demux(data, args.skip)
    if err:
        print("etrace_trio_demux: ERROR -- %s" % err, file=sys.stderr)
        return 1

    total_pkts = 0
    for src in sorted(streams):
        path = Path("%s.src%d.te_inst_raw" % (args.out_prefix, src))
        path.write_bytes(bytes(streams[src]))
        mt = ", ".join("%s=%d" % (MSG_TYPES.get(k, str(k)), v)
                       for k, v in sorted(stats["mtypes"][src].items()))
        total_pkts += stats["packets"][src]
        print("etrace_trio_demux: src%d -> %s (%d packets, %d bytes; %s)"
              % (src, path.name, stats["packets"][src], len(streams[src]), mt))
    print("etrace_trio_demux: %d container bytes, %d tags, %d packets, %d sources"
          % (stats["bytes"], stats["tags"], total_pkts, len(streams)))

    if args.sources:
        missing = [s for s in range(args.sources) if s not in streams]
        if missing:
            print("etrace_trio_demux: ERROR -- no packets for source(s) %s"
                  % missing, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
