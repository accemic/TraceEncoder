# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
CTXP control-flow reference for EC3: decode a te_inst_raw stream with the
VENDORED Siemens reference model (unmodified) and emit the same CTXP CF-record
grammar NexRv's exporter uses (SYNC/BRANCH_TAKEN/BRANCH_NOTTAKEN/CALL/RETURN).

This is a second, independent decoder over the identical input, so it audits
the C E-Trace front-end's CF classification the way the Python PC oracle audits
its PC reconstruction (audit-the-auditor). Trap/sync boundaries are handled by
the model itself (next_pc is not called on the trap path), so a return that a
trap subsumes does NOT become a CF edge -- exactly as the C decoder does.

Usage: py etrace_ctxp_ref.py -i <stream.te_inst_raw> -l <listing.objdump>
          -o <out.ctxp.cf>
"""

import argparse
import sys

import etrace_common


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", required=True)
    ap.add_argument("-l", "--listing", required=True)
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    import decoder_model as dm
    from common.raw_file import RawFile
    from common import utils

    utils.init_debug(args.debug)
    dm.args = etrace_common.make_args(debug=args.debug)
    dm.args.decoder_input = args.input

    scf = etrace_common.make_scf()
    elf_data = etrace_common.ListingData(dm, args.listing)
    ExtDecoder = etrace_common.make_ext_decoder(dm)

    records = []

    def is_call(instr):
        return (instr.opcode in ("c.jalr", "c.jal")
                or (instr.opcode == "jalr" and instr.rd == 1)
                or (instr.opcode == "jal" and instr.rd == 1))

    def is_return(instr):
        return (instr.opcode == "jalr" and instr.rd == 0 and instr.rs1 == 1) \
            or (instr.opcode == "c.jr" and instr.rs1 == 1)

    def is_jump(instr):
        return instr.opcode in ("jal", "c.jal", "c.j") or instr.opcode in ("jalr", "c.jr", "c.jalr")

    class CfDecoder(ExtDecoder):
        _suppress = False

        def exception_address(self, te_inst):
            # The model calls next_pc() here purely to compute the EPC; that is
            # not a retired control-flow edge (the faulting instruction did not
            # retire). Suppress CF recording during it, matching the C decoder
            # which treats the trap as a SYNC boundary, not a CF edge.
            self._suppress = True
            try:
                return super().exception_address(te_inst)
            finally:
                self._suppress = False

        def next_pc(self, address):
            this_pc = self.pc
            instr = self.get_instr(this_pc)
            stop = super().next_pc(address)
            if self._suppress:
                return stop
            new_pc = self.pc
            typ = None
            if instr.is_branch:
                taken = (new_pc != this_pc + instr.size)
                typ = "BRANCH_TAKEN" if taken else "BRANCH_NOTTAKEN"
            elif is_call(instr):
                typ = "CALL"
            elif is_return(instr):
                typ = "RETURN"
            elif is_jump(instr):
                typ = "BRANCH_TAKEN"
            if typ is not None:
                records.append("%s:0x%x:0x%x" % (typ, this_pc, new_pc))
            return stop

    import os
    with open(os.devnull, "w") as devnull:
        with open(args.input, "rb") as in_fd:
            decoder = CfDecoder(scf, devnull, elf_data, expected=[])
            rawfile = RawFile(in_fd)
            while rawfile.has_data():
                decoder.add(rawfile.process_packet(decoder.create_te_inst))

    with open(args.output, "w") as out_fd:
        for r in records:
            out_fd.write(r + "\n")
    print("etrace_ctxp_ref: %d CF records -> %s" % (len(records), args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
