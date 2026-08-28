# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
Cross-validate the te_data (DF) and vendor-DAQ packets of a raw E-Trace
stream against testbench oracles.

Oracle formats (one record per line, written by the TB while driving):
  --df  : "<S|L> <addr-hex> <sz> <data-hex>"   sz = log2(bytes)
  --daq : "<idtag-hex> <data-hex>"             data = 192-bit element concat
                                               (element 0 in the LSBs)
Records must match in ORDER and COUNT. te_inst packets are parsed (and
thereby validated) but not compared here.

Usage: py etrace_data_check.py <stream.bin> [--df <f>] [--daq <f>]
"""

import argparse
import sys

import etrace_common


def read_df(path):
    out = []
    with open(path) as fd:
        for line in fd:
            f = line.split()
            if len(f) != 4:
                continue
            kind, addr, sz, data = f
            nbytes = 1 << int(sz)
            out.append((kind, int(addr, 16), nbytes,
                        int(data, 16) & ((1 << (8 * nbytes)) - 1)))
    return out


def read_daq(path):
    out = []
    with open(path) as fd:
        for line in fd:
            f = line.split()
            if len(f) != 2:
                continue
            out.append((int(f[0], 16), int(f[1], 16)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--df")
    ap.add_argument("--daq")
    args = ap.parse_args()

    import decoder_model as dm
    from common.raw_file import RawFile
    from common import utils

    utils.init_debug(False)
    dm.args = etrace_common.make_args()
    scf = etrace_common.make_scf()

    class NullElf:
        def get(self, a):
            raise SystemExit("data check does not walk the program image")

    dec = etrace_common.make_ext_decoder(dm)(scf, sys.stdout, NullElf(),
                                             expected=[])
    got_df, got_daq, n_ti = [], [], 0

    def handler(mt, ln, pkt):
        if mt == 3:
            d = etrace_common.parse_te_data(pkt)
            got_df.append((d["kind"], d["addr"], d["nbytes"], d["value"]))
            return None
        if mt == 1:
            d = etrace_common.parse_daq(pkt)
            got_daq.append((d["idtag"], d["data"]))
            return None
        return dec.create_te_inst(mt, ln, pkt)  # te_inst: parse to validate

    with open(args.stream, "rb") as fd:
        rf = RawFile(fd)
        while rf.has_data():
            if rf.process_packet(handler) is not None:
                n_ti += 1

    rc = 0
    for tag, gotten, path, rd in (("DF", got_df, args.df, read_df),
                                  ("DAQ", got_daq, args.daq, read_daq)):
        if not path:
            continue
        exp = rd(path)
        if gotten == exp:
            print("etrace_data_check: %s OK — %d records match"
                  % (tag, len(exp)))
            continue
        rc = 1
        print("etrace_data_check: %s MISMATCH — expected %d, got %d"
              % (tag, len(exp), len(gotten)))
        for i in range(max(len(exp), len(gotten))):
            e = exp[i] if i < len(exp) else None
            g = gotten[i] if i < len(gotten) else None
            if e != g:
                print("  [%d] exp=%s got=%s" % (i, e, g))
    print("etrace_data_check: %d te_inst / %d te_data / %d daq packets"
          % (n_ti, len(got_df), len(got_daq)))
    return rc


if __name__ == "__main__":
    sys.exit(main())
