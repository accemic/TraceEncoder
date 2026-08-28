/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * misaligned_test.S -- misaligned load/store traps.
 * Exercises two further RISC-V causes: 4 = MISALIGNED_LOAD, 6 = MISALIGNED_STORE.
 * Purely software-triggerable; the MBV has C_MISALIGNED_EXCEPTIONS=1 (default)
 * so an unaligned word access traps. The shared crt0 handler treats synchronous
 * exceptions with mepc+=4 -> skips the faulting access and keeps going (the
 * load/store is never actually performed -- only the trace matters here).
 */
.option norvc
.section .text
.global main
.align 2
main:
	addi  sp, sp, -16
	sw    ra, 0(sp)

	li    a0, 0x11               /* linear instruction before the first trap */

	/* --- MISALIGNED LOAD (address +1 => not 4-byte aligned) -> cause 4 --- */
	la    t0, mbuf
	addi  t0, t0, 1
	lw    t1, 0(t0)              /* TRAP (MISALIGNED_LOAD); handler skips (mepc+=4) */
	addi  a0, a0, 1              /* first instruction AFTER return */

	/* --- MISALIGNED STORE (address +2 => halfword-aligned, not enough for sw) -> cause 6 --- */
	la    t2, mbuf
	addi  t2, t2, 2
	sw    a0, 0(t2)              /* TRAP (MISALIGNED_STORE); handler skips */
	addi  a0, a0, 1              /* after return */

	lw    ra, 0(sp)
	addi  sp, sp, 16
	ret                          /* RETURN to crt0 */

.section .bss
.align 4
mbuf:
	.space 32
