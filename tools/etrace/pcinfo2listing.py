# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
NexRv PCInfo (cpu_model write_nexrv_info output) -> synthetic objdump-style
listing for the E-Trace reference decoder.

The decoder only classifies instructions by mnemonic/operands (it is NOT a
real disassembler), so a canonical instruction per PCInfo type is sufficient:

  L   -> addi zero,zero,0          (linear)
  BD  -> beq  zero,zero,<target>   (conditional direct branch)
  JD  -> jal  zero,<target>        (inferable jump, no ra push)
  CD  -> jal  ra,<target>          (inferable call, ra push)
  JI  -> jalr zero,0(t0)           (uninferable jump)
  CI  -> jalr ra,0(t0)             (uninferable call)
  R   -> jalr zero,0(ra)           (return)

The encoded "binary" column is a placeholder (only its hex-digit LENGTH is
parsed, 8 digits = 4-byte instruction).

Usage: py pcinfo2listing.py <in.nexrv.info> <out.objdump>
"""

import sys


def convert(line):
    line = line.strip()
    if not line:
        return None
    parts = line.split(",")
    addr = int(parts[0], 16)
    type_len = parts[1]
    # split alpha type prefix from decimal length suffix
    i = 0
    while i < len(type_len) and not type_len[i].isdigit():
        i += 1
    ptype = type_len[:i]
    size = int(type_len[i:])
    assert size == 4, "only 4-byte instructions supported (got %s)" % line
    target = int(parts[2], 16) if len(parts) > 2 else None

    if ptype == "L":
        op, args = "addi", "zero,zero,0"
    elif ptype == "BD":
        op, args = "beq", "zero,zero,%x" % target
    elif ptype == "JD":
        op, args = "jal", "zero,%x" % target
    elif ptype == "CD":
        op, args = "jal", "ra,%x" % target
    elif ptype == "JI":
        op, args = "jalr", "zero,0(t0)"
    elif ptype == "CI":
        op, args = "jalr", "ra,0(t0)"
    elif ptype == "R":
        op, args = "jalr", "zero,0(ra)"
    else:
        raise ValueError("unknown PCInfo type '%s' in: %s" % (ptype, line))

    return "%x:\t%08x\t%s\t%s" % (addr, 0, op, args)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    n = 0
    with open(sys.argv[1]) as fin, open(sys.argv[2], "w") as fout:
        for line in fin:
            out = convert(line)
            if out is not None:
                fout.write(out + "\n")
                n += 1
    print("pcinfo2listing: %d instructions -> %s" % (n, sys.argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
