#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""objdump_to_oracle.py — static program oracle from `objdump -d -M no-aliases,numeric`.

Reads RISC-V disassembly (with no-aliases,numeric → rd/rs1 explicitly as xN) from stdin and
writes a CSV to stdout:

    addr,word,mnemonic,operands,cf_class,itype_candidate

Purpose (independent of Vivado):
  * G0 baseline: Trace_PC / Trace_Instruction of the MicroBlaze V must hit address and
    instruction word of this static image bit-exactly (bit-order acceptance criterion).
  * G2 prep: cf_class + itype_candidate are the spec-derived non-trap classification
    (JAL/JALR link-register relation, N-Trace `itype`). TAKEN/NOT_TAKEN of a branch is
    dynamic (decided in the trace) → marked as such. Trap `iretire` stays a G1 matter.

IMPORTANT: no-aliases,numeric is required — the alias form (`jalr a5`, `ret`, `j`) hides rd
and leads to misclassification (indirect call ↔ indirect jump). ISA-based, NO assumption
about AMD `TRACE` bus semantics.
"""
import re
import sys

# objdump instruction line:  "  150:\t000780e7          \tjalr\tx1,0(x15)"
LINE = re.compile(r"^\s*([0-9a-fA-F]+):\s+([0-9a-fA-F]{4,8})\s+(.*)$")
RS1_PAREN = re.compile(r"\(?(x\d+)\)?")          # rs1 from "0(x15)" or "x15"

BRANCH = {"beq", "bne", "blt", "bge", "bltu", "bgeu"}
TRAP_RET = {"mret", "sret", "uret", "dret"}
LINK = {"x1", "x5"}                               # N-Trace link registers (§5.1)


def regs(ops):
    """(rd, rs1) from the no-aliases,numeric operand list; '' when absent."""
    fields = [f.strip() for f in ops.split(",")] if ops else []
    rd = fields[0] if fields else ""
    rs1 = ""
    if len(fields) >= 2:
        m = RS1_PAREN.search(fields[1])           # jalr: rd,imm(rs1)  or jal: rd,target
        rs1 = m.group(1) if m else ""
    return rd, rs1


def classify(mnem, ops):
    """(cf_class, itype_candidate) — spec-derived, without trap coupling."""
    m = mnem.lower()

    if m in BRANCH:
        return "BRANCH", "TAKEN_BRANCH|NOT_TAKEN_BRANCH (dynamic)"
    if m == "ecall":
        return "SYSTEM", "EXCEPTION_TRAP@ecall (G1: iretire)"
    if m == "ebreak":
        return "SYSTEM", "EXCEPTION_TRAP@ebreak (G1: iretire)"
    if m in TRAP_RET:
        return "TRAP_RETURN", "EXCEPTION_IR"
    if m in ("wfi", "fence", "fence.i") or m.startswith("csr"):
        return "SYSTEM", "OTHER"

    if m == "jal":                                # direct jump: rd,target
        rd, _ = regs(ops)
        if rd in LINK:
            return "CALL", "INFERRABLE_CALL"
        return "JUMP", "OTHER_INFERABLE_JUMP"     # rd=x0 (jump/tail) or any other rd

    if m == "jalr":                               # indirect jump: rd,imm(rs1)
        rd, rs1 = regs(ops)
        rd_link, rs1_link = rd in LINK, rs1 in LINK
        if rd_link and not rs1_link:
            return "CALL", "UNINFERABLE_CALL"
        if rd_link and rs1_link:
            return ("CALL", "UNINFERABLE_CALL") if rd == rs1 \
                else ("COROUTINE", "CO_ROUTINE_SWAP")
        if (not rd_link) and rs1_link:
            return "RETURN", "RETURN"
        return "JUMP", "OTHER_UNINFERABLE_JUMP"   # neither rd nor rs1 is a link register

    return "LINEAR", "OTHER"


def main():
    out = sys.stdout
    out.write("addr,word,mnemonic,operands,cf_class,itype_candidate\n")
    for raw in sys.stdin:
        mo = LINE.match(raw.rstrip("\n"))
        if not mo:
            continue
        addr, word, rest = mo.group(1), mo.group(2), mo.group(3).strip()
        parts = rest.split(None, 1)
        mnem = parts[0]
        ops = parts[1].strip() if len(parts) > 1 else ""
        ops = re.split(r"\s+#|\s+<", ops)[0].strip()   # strip symbol annotation/comment
        cf, itc = classify(mnem, ops)
        out.write(f"0x{int(addr,16):08x},0x{word.zfill(8)},{mnem},{ops.replace(',', ';')},{cf},{itc}\n")


if __name__ == "__main__":
    main()
