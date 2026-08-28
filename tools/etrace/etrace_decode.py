# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
E-Trace decode driver: raw te_inst byte stream (as dumped from the CTTE
ATB with CT_EN_ETRACE, or produced by the reference encoder model) + synthetic
objdump listing -> reconstructed PC sequence (one lowercase hex PC per line).

Uses the vendored reference decoder (third_party/riscv-trace-spec-ref)
unmodified; the argparse/module globals it expects are injected here.

Usage: py etrace_decode.py -i <stream.te_inst_raw> -l <listing.objdump>
          -o <out.pctrace> [--debug]
Exit 0 on complete decode; non-zero on decoder error.
"""

import argparse
import sys

import etrace_common


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", required=True, help="raw te_inst byte stream")
    ap.add_argument("-l", "--listing", required=True, help="objdump-style listing")
    ap.add_argument("-o", "--output", required=True, help="decoded PC trace out")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--tolerant-listing", action="store_true",
                    help="raw-binary listing: skip unparsable lines")
    ap.add_argument("--sijump", action="store_true",
                    help="mirror the adapter sijump folding (auipc/lui+jalr)")
    args = ap.parse_args()

    import decoder_model as dm
    from common.raw_file import RawFile
    from common import utils

    utils.init_debug(args.debug)
    dm.args = etrace_common.make_args(debug=args.debug, sijump=args.sijump)
    dm.args.decoder_input = args.input

    scf = etrace_common.make_scf()
    elf_data = etrace_common.ListingData(dm, args.listing,
                                        tolerant=args.tolerant_listing)

    npackets = 0
    ExtDecoder = etrace_common.make_ext_decoder(dm)
    with open(args.output, "w") as out_fd, open(args.input, "rb") as in_fd:
        decoder = ExtDecoder(scf, out_fd, elf_data, expected=[])
        rawfile = RawFile(in_fd)
        while rawfile.has_data():
            te = rawfile.process_packet(decoder.create_te_inst)
            npackets += 1
            if te is None:      # te_data / vendor DAQ: consumed, no PC walk
                continue
            decoder.add(te)

    print("etrace_decode: %d packets, %d PCs -> %s"
          % (npackets, decoder.i_count, args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
