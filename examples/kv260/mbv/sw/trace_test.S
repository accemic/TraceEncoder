/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * trace_test.S -- basic program-flow shapes: linear code, a not-taken
 * branch, a taken branch, and a branch-dense loop. Deterministic, pure
 * RV32I. Covers the decoder's `itype` base classes NOT_TAKEN_BRANCH /
 * TAKEN_BRANCH / OTHER (linear). `main` is called by crt0 and returns
 * normally.
 */
.option norvc
.section .text
.global main
.align 2
main:
	/* --- linear instructions (itype OTHER) --- */
	li    t0, 0
	addi  t0, t0, 1
	addi  t0, t0, 1
	addi  t0, t0, 1
	slli  t1, t0, 2
	xori  t1, t1, 0x55
	or    t2, t0, t1

	/* --- not-taken branch (condition false -> NOT_TAKEN_BRANCH) --- */
	li    a0, 5
	li    a1, 7
	beq   a0, a1, .Lnever          /* 5 != 7 -> not taken */
	addi  a0, a0, 1                /* falls through (linear) */

	/* --- taken branch (condition true -> TAKEN_BRANCH) --- */
	li    a1, 6
	beq   a0, a1, .Ltaken          /* a0 is now 6 -> taken */
	ebreak                         /* should NOT be reached */
.Lnever:
	/* dead branch; only present as the not-taken case's jump target */
	nop
.Ltaken:

	/* --- long branch-dense loop (many taken backward branches; worst-case density) --- */
	li    t0, 64                   /* iteration counter */
	li    t1, 0                    /* accumulator */
.Lloop:
	addi  t1, t1, 3
	andi  t1, t1, 0x7ff
	addi  t0, t0, -1
	bnez  t0, .Lloop               /* a taken backward branch per iteration */

	mv    a0, t1                   /* return value (cosmetic only) */
	ret                            /* RETURN to crt0 */
