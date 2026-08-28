/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * trap_test.S -- synchronous traps + trap return (ecall - exception handler -
 * mret - ebreak). Purely software-triggerable (no SoC interrupt source
 * needed) -> runs in any MBV config. The shared crt0 trap handler catches
 * ecall/ebreak, skips the instruction (mepc+=4), and returns via `mret`.
 * Covers the critical ECALL_FROM_M / BREAKPOINT cases.
 *
 * NOTE on "trace disable/enable": toggling the CTTE encoder on/off goes
 * through its own CSR block (trTeControl.Enable), addressed via the ENC
 * region of the enclosing SoC (see ../rtl/mbv_soc_top.sv). This program only
 * marks the two spots as placeholders, not as an MBV instruction sequence.
 */
.option norvc
.section .text
.global main
.align 2
main:
	addi  sp, sp, -16
	sw    ra, 0(sp)

	/* --- ecall from machine mode (mcause=11 ECALL_FROM_M) -> handler -> mret --- */
	li    a7, 0                     /* "syscall number" (cosmetic, just for the trace picture) */
	ecall                           /* trap entry; the crt0 handler does mepc+=4 + mret */
	addi  a0, a7, 1                 /* first instruction AFTER returning from the handler */

	/* --- ebreak (mcause=3 BREAKPOINT) -> handler -> mret --- */
	ebreak                          /* trap entry; handler skips + mret */
	addi  a0, a0, 1                 /* after return */

	/* >>> trace disable  (SoC/CSR-dependent -- placeholder, no code) <<< */
	nop
	nop
	/* >>> trace enable   (SoC/CSR-dependent -- placeholder, no code) <<< */

	/* one more ecall, to show trap-entry/return repeatability in the trace */
	ecall
	addi  a0, a0, 1

	lw    ra, 0(sp)
	addi  sp, sp, 16
	ret                             /* RETURN to crt0 */
