/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * sijump_test.S -- sequentially-inferable-jump pairs (auipc/lui + jalr) for
 * the sijump adapter path. Deterministic, pure RV32I. Every pair is ADJACENT
 * (auipc/lui immediately before the jalr, rs1 = a freshly written register)
 * -- exactly the shape the adapter (sijump_en=1) classifies as INFERRABLE
 * and that msg_gen then folds (no IndirectBranchHist, no UADDR). The decoder
 * resolves the targets from the static PCInfo (NexRv -conv -objd ... -sijump).
 * Contains:
 *   - auipc+jalr CALL pairs (rd=ra) in a loop (the compression win case),
 *   - one lui+jalr JUMP pair (rd=x0, absolute target via lui),
 *   - NEGATIVE cases: a jalr with a NON-adjacent auipc (an instruction in
 *     between) and a classic register call (la = auipc+addi, the last write
 *     is the addi) -- both MUST stay uninferable (full IBH, UADDR),
 *   - ordinary branches/returns around them (interference with HIST/fold paths).
 * `main` is called by crt0 and returns normally.
 */
.option norvc
.section .text
.global main
.align 2
main:
	/* save ra: the jalr-ra calls below CLOBBER ra; without a prologue/epilogue
	 * main would return to the last call site instead of to crt0 (found by the
	 * two-encoder cross-validation: both encoders reported the same "wrong"
	 * target identically -> the hardware was right, the program was wrong). */
	addi  sp, sp, -8
	sw    ra, 4(sp)

	/* --- loop with an auipc+jalr call pair (adjacent, rs1=t0 fresh) --- */
	li    s0, 6                    /* iterations */
	li    s1, 0                    /* accumulator */
.Lloop:
	/* the real GCC far-call idiom: base register = ra itself (rd==rs1==x1 ->
	 * UNINFERABLE_CALL, convertible). A t0/t1 base register (x5!) would fall
	 * under the co-routine rule (rd_link && rs1_link && rd!=rs1) and would
	 * deliberately stay dynamic on both sides. */
1:	auipc ra, %pcrel_hi(leaf_add)  /* pair half 1: ra = pc + hi20 */
	jalr  ra, %pcrel_lo(1b)(ra)    /* pair half 2: inferable CALL -> folded */
	addi  s0, s0, -1
	bnez  s0, .Lloop               /* a taken backward branch per iteration */

	/* --- NEGATIVE 1: auipc and jalr NOT adjacent (an addi in between) --- */
2:	auipc t1, %pcrel_hi(leaf_xor)
	addi  s1, s1, 1                /* breaks adjacency -> pair invalid */
	jalr  ra, %pcrel_lo(2b)(t1)    /* stays uninferable (full IBH + UADDR) */

	/* --- NEGATIVE 2: classic register call (no U-type immediately before) --- */
	la    t2, leaf_add             /* la = auipc+addi; the last write is the addi */
	jalr  ra, 0(t2)                /* stays uninferable */

	/* --- lui+jalr JUMP pair (rd=x0): absolute target --- */
	lui   t3, %hi(hop_target)
	jalr  x0, %lo(hop_target)(t3)  /* inferable JUMP (no link) -> folded */
.Lafter_hop:

	/* --- wrap-up: a short branch sequence + return --- */
	li    t0, 8
.Ltail:
	addi  s1, s1, 5
	addi  t0, t0, -1
	bnez  t0, .Ltail
	mv    a0, s1
	lw    ra, 4(sp)
	addi  sp, sp, 8
	ret

.align 2
leaf_add:                          /* small leaf: 2 linear + return */
	addi  s1, s1, 7
	xori  s1, s1, 0x11
	ret

.align 2
leaf_xor:
	xori  s1, s1, 0x33
	ret

.align 2
hop_target:                        /* target of the lui+jalr jump: keeps running linearly */
	addi  s1, s1, 2
	j     .Lafter_hop
