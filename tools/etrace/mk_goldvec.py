# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
Golden-vector generator + reference round-trip (ET1 gate):

For each scenario: build an encoder-input CSV (E-Trace hart-interface rows),
run the vendored reference ENCODER model -> .te_inst_raw byte stream, then
run the reference DECODER (via etrace_decode glue) on that stream with a
synthetic listing, and compare the reconstructed PC sequence against the
scenario's retired-PC oracle. PASS iff identical.

The .te_inst_raw streams are the golden vectors for the RTL unit TB
(tests/etrace/vectors/). Run from anywhere: py mk_goldvec.py [outdir]
"""

import csv
import os
import sys

import etrace_common

OUT_DEFAULT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "..", "tests", "etrace", "vectors")
)

# (name, program, rows). program: addr -> (listing_op, listing_args) with
# gap-fill addi for unvisited slots. rows: retired/trap events in order:
# (itype, cause, tval, priv, iaddr, iretire)
SCEN = []

# --- scenario 1: branches / uninferable jump / call / return ------------
prog1 = {
    0x1000: ("addi", "zero,zero,0"),
    0x1004: ("beq", "zero,zero,1010"),      # taken
    0x1010: ("addi", "zero,zero,0"),
    0x1014: ("jalr", "zero,0(t0)"),          # uninferable jump -> 0x1020
    0x1020: ("addi", "zero,zero,0"),
    0x1024: ("beq", "zero,zero,1040"),       # not taken
    0x1028: ("addi", "zero,zero,0"),
    0x102C: ("jal", "ra,2000"),              # inferable call
    0x2000: ("addi", "zero,zero,0"),
    0x2004: ("jalr", "zero,0(ra)"),          # return -> 0x1030
    0x1030: ("addi", "zero,zero,0"),
    0x1034: ("addi", "zero,zero,0"),
    0x1038: ("addi", "zero,zero,0"),
}
rows1 = [
    (0,  0, 0, 3, 0x1000, 2),
    (5,  0, 0, 3, 0x1004, 2),   # taken branch
    (0,  0, 0, 3, 0x1010, 2),
    (14, 0, 0, 3, 0x1014, 2),   # other uninferable jump
    (0,  0, 0, 3, 0x1020, 2),
    (4,  0, 0, 3, 0x1024, 2),   # non-taken branch
    (0,  0, 0, 3, 0x1028, 2),
    (9,  0, 0, 3, 0x102C, 2),   # inferable call (silent)
    (0,  0, 0, 3, 0x2000, 2),
    (13, 0, 0, 3, 0x2004, 2),   # return (updiscon, IR off)
    (0,  0, 0, 3, 0x1030, 2),
    (0,  0, 0, 3, 0x1034, 2),
    (0,  0, 0, 3, 0x1038, 2),
]
SCEN.append(("br_jump_ret", prog1, rows1))

# --- scenario 2: exception (ecall-like, iretire=0) + handler ------------
prog2 = {
    0x1000: ("addi", "zero,zero,0"),
    0x1004: ("addi", "zero,zero,0"),
    0x1008: ("jalr", "zero,0(t0)"),          # stand-in for the faulting instr
    0x3000: ("addi", "zero,zero,0"),
    0x3004: ("addi", "zero,zero,0"),
    0x3008: ("addi", "zero,zero,0"),
    0x300C: ("addi", "zero,zero,0"),
}
rows2 = [
    (0, 0,  0,      3, 0x1000, 2),
    (0, 0,  0,      3, 0x1004, 2),
    (1, 11, 0x1008, 3, 0x1008, 0),  # exception, does not retire
    (0, 0,  0,      3, 0x3000, 2),  # trap handler
    (0, 0,  0,      3, 0x3004, 2),
    (0, 0,  0,      3, 0x3008, 2),
    (0, 0,  0,      3, 0x300C, 2),
]
SCEN.append(("exception", prog2, rows2))


def write_inputs(outdir, name, prog, rows):
    stem = os.path.join(outdir, name)
    with open(stem + "_input", "w", newline="") as fd:
        w = csv.writer(fd)
        w.writerow(["itype_0", "cause", "tval", "priv", "iaddr_0",
                    "context", "ctype", "iretire_0", "ilastsize_0"])
        for (itype, cause, tval, priv, iaddr, iretire) in rows:
            w.writerow([itype, cause, "%x" % tval, priv, "%x" % iaddr,
                        0, 0, iretire, 1])
    with open(stem + ".objdump", "w") as fd:
        base, top = min(prog), max(prog)
        a = base
        while a <= top:
            op, args_ = prog.get(a, ("addi", "zero,zero,0"))
            fd.write("%x:\t%08x\t%s\t%s\n" % (a, 0, op, args_))
            a += 4
    with open(stem + ".expected.pcs", "w") as fd:
        for (itype, cause, tval, priv, iaddr, iretire) in rows:
            if iretire > 0:
                fd.write("%x\n" % iaddr)
    return stem


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else OUT_DEFAULT
    os.makedirs(outdir, exist_ok=True)

    import encoder_model as em
    import decoder_model as dm
    from common.raw_file import RawFile
    from common import utils

    utils.init_debug(False)
    em.args = etrace_common.make_args()
    dm.args = etrace_common.make_args()

    scf = etrace_common.make_scf()
    n_fail = 0
    for (name, prog, rows) in SCEN:
        stem = write_inputs(outdir, name, prog, rows)
        ucf = etrace_common.make_ucf(file_stem=name)

        # encoder model writes its outputs to CWD-relative basenames
        cwd = os.getcwd()
        os.chdir(outdir)
        try:
            em.EncoderHarness(scf, ucf, stem + "_input")
        finally:
            os.chdir(cwd)

        raw = stem + "_input.te_inst_raw"  # harness names outputs after the input file
        out = stem + ".ref.pctrace"
        elf_data = etrace_common.ListingData(dm, stem + ".objdump")
        with open(out, "w") as out_fd, open(raw, "rb") as in_fd:
            decoder = dm.Decoder(scf, out_fd, elf_data, expected=[])
            rawfile = RawFile(in_fd)
            while rawfile.has_data():
                decoder.add(rawfile.process_packet(decoder.create_te_inst))

        exp = [l.strip() for l in open(stem + ".expected.pcs") if l.strip()]
        got = [l.strip() for l in open(out) if l.strip()]
        ok = exp == got
        print("[goldvec] %-12s %s  (%d expected, %d decoded, raw %d B)"
              % (name, "PASS" if ok else "FAIL", len(exp), len(got),
                 os.path.getsize(raw)))
        if not ok:
            n_fail += 1
            for i in range(max(len(exp), len(got))):
                e = exp[i] if i < len(exp) else "-"
                g = got[i] if i < len(got) else "-"
                if e != g:
                    print("   first diff at #%d: expected %s got %s" % (i, e, g))
                    break
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
