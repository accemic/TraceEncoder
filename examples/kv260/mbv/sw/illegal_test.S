/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * illegal_test.S -- illegal-instruction trap. A *fault* (not requested, like
 * ecall/ebreak), cause 2 (ILLEGAL_INSTR). The crt0 handler treats synchronous
 * exceptions with mepc+=4 -> skips the illegal instruction and keeps going.
 * Purely software-triggerable.
 * (`C_ILL_INSTR_EXCEPTION=2` is active in the MBV baseline config -> 0x00000000
 * reliably traps as illegal.)
 */
.option norvc
.section .text
.global main
.align 2
main:
	addi  sp, sp, -16
	sw    ra, 0(sp)

	li    a0, 0x100
	li    a1, 0x200
	add   a2, a0, a1          /* linear instruction BEFORE the illegal one */

	.word 0x00000000          /* ILLEGAL INSTRUCTION -> trap (mcause=2); handler skips (mepc+=4) */

	add   a3, a2, a0          /* first instruction AFTER returning from the handler */
	xor   a4, a3, a1

	lw    ra, 0(sp)
	addi  sp, sp, 16
	ret                       /* RETURN to crt0 */
