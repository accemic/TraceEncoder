#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""bin_to_memh.py — RISC-V program binary → 32-bit `$readmemh` file for LMB BRAM sim init.

Reads a raw program image (objcopy -O binary, from 0x0) and writes a .memh with **one
32-bit little-endian hex word per line** (RISC-V is little-endian; the LMB BRAM is 32 bit
wide). Init for the XSIM BRAM (blk_mem_gen Load_Init_File resp. $readmemh in the
testbench), G0/G5.

Usage:  py scripts/bin_to_memh.py [--coe] <in.bin> [<depth_words>] > out.{memh,coe}
        --coe → Xilinx COE (blk_mem_gen Load_Init_File) instead of $readmemh.
"""
import sys


def main():
    args = sys.argv[1:]
    coe = False
    if args and args[0] == "--coe":
        coe = True
        args = args[1:]
    if not args:
        sys.stderr.write("usage: bin_to_memh.py [--coe] <in.bin> [depth_words] > out\n")
        sys.exit(2)
    data = open(args[0], "rb").read()
    if len(data) % 4:                       # pad up to a 4-byte word boundary
        data += b"\x00" * (4 - len(data) % 4)
    words = len(data) // 4
    depth = int(args[1]) if len(args) > 1 else words
    vals = [f"{int.from_bytes(data[4*i:4*i+4], 'little'):08x}" if i < words else "00000000"
            for i in range(depth)]
    out = sys.stdout
    if coe:
        out.write("memory_initialization_radix=16;\n")
        out.write("memory_initialization_vector=\n")
        out.write(",\n".join(vals))
        out.write(";\n")
    else:
        out.write("\n".join(vals) + "\n")


if __name__ == "__main__":
    main()
