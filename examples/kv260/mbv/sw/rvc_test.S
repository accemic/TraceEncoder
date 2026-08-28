/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * rvc_test.S -- RVC raw-encoding measurement. NOT part of the MVP program-flow
 * regression: the baseline config keeps the C extension OFF (see the other
 * programs in this directory). This one program alone is built with
 * rv32imc via the Makefile's dedicated rule (`make coe` / the rvc_test.elf
 * target), and needs the core itself rebuilt with C_USE_COMPRESSION=1
 * (MBV_USE_COMPRESSION=1 in ../fpga/create_bd.tcl) to actually be meaningful.
 *
 * Measurement question: does `Trace_Instruction[0:31]` carry the ORIGINAL RVC
 * encoding for a 16-bit instruction (then ilastsize is derivable from
 * instr[1:0]!=2'b11) or an EXPANDED 32-bit instruction (then the length
 * information is lost -> an extra source would be needed)?
 *
 * Evaluation: compare the captured Trace_Instruction against the objdump
 * word for each retired PC. Original encoding -> the 16-bit instruction
 * matches; expansion -> the comparison reports a mismatch, showing
 * `trace_instr` vs. the disassembly oracle -- either result answers the
 * question unambiguously.
 */
.option rvc
.section .text
.global main
.align 2
main:
	addi   sp, sp, -16
	sw     ra, 0(sp)

	li     a0, 1
	c.li   a1, 7            /* 16-bit RVC */
	c.addi a1, 1            /* 16-bit RVC */
	c.mv   a2, a1           /* 16-bit RVC */
	c.nop                   /* 16-bit RVC */
	add    a0, a0, a2       /* 32-bit (contrast, right next to it) */
	c.addi a0, 1            /* 16-bit RVC */

	lw     ra, 0(sp)
	addi   sp, sp, 16
	ret
