# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
Real `riscv objdump -d -M no-aliases,numeric` output -> the tab-separated
4-field listing ListingData/the vendored Instruction parser expect
(`addr:\tbinary\topcode\targs`).

Conversions beyond line filtering:
  * U-type (auipc/lui) operands are rewritten to the ABSOLUTE register
    value (auipc: pc + (hi20 << 12); lui: hi20 << 12). The vendored parser
    stores U-type imm = operand - address (the jal absolute-target
    convention), so the sijump target formula (last_pc + prev.imm) + imm2
    then yields the architecturally correct value for both opcodes.
  * `<symbol>` and `# comment` trailers are stripped from the args.

Branch/jal operands already carry absolute hex targets in objdump output
(matching the parser convention) and pass through unchanged; jalr keeps its
canonical `rd,imm(rs1)` form.

Usage: py objdump2listing.py <in.objdump> <out.listing>
"""

import re
import sys

INSTR_RE = re.compile(
    r"^\s*([0-9a-f]+):\s+([0-9a-f]{4}|[0-9a-f]{8})\s+(\S+)\s*(.*)$")

# The vendored Instruction.reg() only understands ABI register names --
# rewrite the `-M numeric` x-names.
ABI = (["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1"]
       + ["a%d" % i for i in range(8)]
       + ["s%d" % i for i in range(2, 12)]
       + ["t%d" % i for i in range(3, 7)])
XREG_RE = re.compile(r"\bx([12][0-9]|3[01]|[0-9])\b")


JALR_RE = re.compile(r"^(\S+),(-?\d+)\((\S+)\)$")


def clean_args(opcode, args):
    args = args.split("#", 1)[0]
    args = re.sub(r"<[^>]*>", "", args)
    args = XREG_RE.sub(lambda m: ABI[int(m.group(1))], args)
    args = args.strip()
    if opcode == "jalr":
        # objdump prints the offset in DECIMAL inside `off(rs1)`; the
        # vendored parser reads immediates base-16 and its off(reg)
        # PATTERN cannot hold hex letters -- rewrite to the 3-operand
        # I-type form `rd,rs1,0xIMM` which parses cleanly. Other memory
        # operands (loads/stores) keep the decimal form: their imm is
        # never consulted by the control-flow walk.
        m = JALR_RE.match(args)
        if m:
            rd, off, rs1 = m.groups()
            off = int(off)
            args = "%s,%s,%s0x%x" % (rd, rs1, "-" if off < 0 else "", abs(off))
    return args


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    n = 0
    with open(sys.argv[1]) as fin, open(sys.argv[2], "w") as fout:
        for line in fin:
            m = INSTR_RE.match(line.rstrip())
            if not m:
                continue
            addr_s, binary, opcode, args = m.groups()
            addr = int(addr_s, 16)
            args = clean_args(opcode, args)
            if opcode in ("auipc", "lui") and "," in args:
                reg, imm_s = args.rsplit(",", 1)
                value = (int(imm_s, 16) << 12) & 0xFFFFFFFF
                if opcode == "auipc":
                    value = (value + addr) & 0xFFFFFFFF
                args = "%s,0x%x" % (reg, value)
            fout.write("%x:\t%s\t%s\t%s\n" % (addr, binary, opcode, args))
            n += 1
    print("objdump2listing: %d instructions -> %s" % (n, sys.argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
