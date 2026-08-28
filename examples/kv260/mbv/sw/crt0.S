/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * crt0.S -- minimal startup + generic trap handler shared by all the MBV
 * test programs in this directory. RV32I(M) without the C extension
 * (baseline, no MVP program uses RVC except rvc_test.S). Every program only
 * supplies its own `main`. Goal: instruction sequences as short and
 * deterministic as possible, so the resulting TRACE-bus/PC stream stays
 * easy to read for characterization and regression.
 *
 * Migrated from an internal predecessor repository
 * (2026-08-17).
 */
.option norvc                       /* no 16-bit instructions (RVC is a separate experiment, rvc_test.S) */

/* --------------------------------------------------------------------- */
.section .text.init,"ax",@progbits
.global _start
_start:
	la    sp, _stack_top            /* initialize the stack */
	/* zero .bss */
	la    t0, _bss_start
	la    t1, _bss_end
1:	bgeu  t0, t1, 2f
	sw    zero, 0(t0)
	addi  t0, t0, 4
	j     1b
2:
	la    t0, trap_handler          /* mtvec = trap_handler (direct mode, [1:0]=00) */
	csrw  mtvec, t0
	li    a0, 0
	li    a1, 0
	call  main
_exit:
	/* clear trace end marker: a tight halt loop (one taken backward branch). */
	j     _exit

/* --------------------------------------------------------------------- */
/* Generic trap handler (direct mode).
 *   - synchronous exception (mcause[31]=0): skip the faulting/trapping
 *     instruction (mepc += 4; valid for RV32 without C: ecall/ebreak/illegal
 *     are all 4 bytes) and return.
 *   - interrupt (mcause[31]=1): call the weak C hook `mei_handler`, then
 *     return to the interrupted instruction (mepc unchanged).
 * All caller-saved registers are saved so the C hook cannot clobber anything.
 * --------------------------------------------------------------------- */
.section .text
.global trap_handler
.align 4
trap_handler:
	addi  sp, sp, -64
	sw    ra,  0(sp)
	sw    t0,  4(sp)
	sw    t1,  8(sp)
	sw    t2, 12(sp)
	sw    a0, 16(sp)
	sw    a1, 20(sp)
	sw    a2, 24(sp)
	sw    a3, 28(sp)
	sw    a4, 32(sp)
	sw    a5, 36(sp)
	sw    a6, 40(sp)
	sw    a7, 44(sp)
	sw    t3, 48(sp)
	sw    t4, 52(sp)
	sw    t5, 56(sp)
	sw    t6, 60(sp)

	csrr  t0, mcause
	bltz  t0, .Lirq                 /* mcause[31]=1 -> interrupt */

	/* --- synchronous exception: skip the instruction --- */
	csrr  t1, mepc
	addi  t1, t1, 4
	csrw  mepc, t1
	j     .Lret

.Lirq:
	call  mei_handler               /* weak default returns immediately */

.Lret:
	lw    ra,  0(sp)
	lw    t0,  4(sp)
	lw    t1,  8(sp)
	lw    t2, 12(sp)
	lw    a0, 16(sp)
	lw    a1, 20(sp)
	lw    a2, 24(sp)
	lw    a3, 28(sp)
	lw    a4, 32(sp)
	lw    a5, 36(sp)
	lw    a6, 40(sp)
	lw    a7, 44(sp)
	lw    t3, 48(sp)
	lw    t4, 52(sp)
	lw    t5, 56(sp)
	lw    t6, 60(sp)
	addi  sp, sp, 64
	mret

/* Weak default interrupt hook: programs may override it. */
.weak mei_handler
.align 2
mei_handler:
	ret
