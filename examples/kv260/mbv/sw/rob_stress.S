/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * rob_stress.S -- parameterized stress workload for board robustness campaigns.
 *
 * Goal: ONE ELF for the entire workload axis. All parameters live in one
 * block in RAM (`rob_params`), which the host overwrites BEFORE starting the
 * core (core_run=0) -- a sweep point is then a register write, not a
 * rebuild. That is what makes it feasible to fit a few thousand runs into a
 * measurement time budget.
 *
 * Structure per outer repetition:
 *   bursts x [ STORM (laps_per_burst ring laps of 14 uninferable jalr)
 *              CALM  (calm_iters iterations; content configurable) ]
 *
 * STORM: exactly the ring from jalr_storm_test.S (lesson learned: only
 * UNINFERABLE jumps saturate the encoder -- the composer's HIST
 * accumulation dampens direct-branch storms by roughly 32:1). 14 blocks of
 * one `jalr x0,0(rN)` each, spread 1 KiB apart, chained interleaved
 * (hop0->hop7->hop1->...) -> target XORs land around 0x2400..0x3400 ->
 * UADDR 13-14 bit.
 *
 * CALM: drains the backlog and produces the decodable reference segments
 * where recovery actually becomes visible (found the hard way: too short a
 * calm phase means the saturation bleeds into the following burst and
 * triggers a thrash-regime defect). Content is switchable:
 *   rand_branch : an xorshift-driven taken/not-taken branch per iteration
 *                 (breaks the branch predictor and RepeatedHistory matching
 *                 -- a different message mix)
 *   mix_calls   : jal/ret pairs (implicit return + return stack)
 *   mix_loads   : lw/sw on rob_buf (data-trace events, where the core
 *                 reports them)
 *   trap_every  : ecall every N calm iterations (the trap path is
 *                 historically the most fragile class)
 *   act_cmd     : csrw 0xB10 (ACT-CAP) once per burst -- set this ONLY on
 *                 cores that report CSR write accesses as
 *                 dretire/CSR_READ_WRITE; on the MBV it is an illegal
 *                 instruction (crt0 skips it) and therefore a trap stimulus.
 *
 * Progress: `rob_status` is written after every phase. The host reads the
 * block AFTER the run (core_run=0) and thereby knows exactly how far the
 * program got -- the reference PC sequence is generated from that (no
 * guessing about run length from outside).
 *
 * CAUTION register allocation: the ring occupies t0-t6 and a1-a7 as hop
 * pointers and a0 as the lap counter. All parameters therefore live in
 * s0-s11; the hop pointers are reloaded at the start of EVERY burst (the
 * calm phase is free to use t/a registers as it likes).
 */

.option norvc
.section .text
.global main
.align 2

/* ---- parameter indices (word offsets into rob_params) --------------------- */
.equ P_MAGIC,       0
.equ P_OUTER,       4
.equ P_BURSTS,      8
.equ P_LAPS,       12
.equ P_CALM,       16
.equ P_MIX_CALLS,  20
.equ P_MIX_LOADS,  24
.equ P_TRAP_EVERY, 28
.equ P_ACT_CMD,    32
.equ P_RAND_BR,    36
.equ P_SEED,       40

/* ---- status indices (word offsets into rob_status) ------------------------ */
.equ S_OUTER_DONE,  0
.equ S_BURST_DONE,  4
.equ S_CALM_DONE,   8
.equ S_DONE,       12

main:
	addi  sp, sp, -16
	sw    ra, 12(sp)

	la    s0, rob_params
	la    s10, rob_status
	lw    s1, P_OUTER(s0)           /* outer repetitions */
	lw    s8, P_SEED(s0)            /* xorshift state */
	bnez  s8, 1f
	li    s8, 0x1234abcd            /* seed 0 would be a dead xorshift */
1:
	lw    s9, P_RAND_BR(s0)
	lw    s5, P_MIX_CALLS(s0)
	lw    s6, P_MIX_LOADS(s0)
	lw    s7, P_TRAP_EVERY(s0)
	lw    s11, P_ACT_CMD(s0)
	beqz  s1, .Lfinish              /* outer_reps == 0 -> do nothing (idle reference) */

.Louter:
	lw    s2, P_BURSTS(s0)          /* bursts for this repetition */
	beqz  s2, .Lcalm_only

.Lburst:
	lw    s3, P_LAPS(s0)
	beqz  s3, .Lafter_storm         /* laps==0 -> skip the storm (pure calm load) */

	/* Load the hop pointers (ring position -> physical block, interleaved) */
	la    t0, hop0                  /* pos0 */
	la    t1, hop7                  /* pos1 */
	la    t2, hop1                  /* pos2 */
	la    t3, hop8                  /* pos3 */
	la    t4, hop2                  /* pos4 */
	la    t5, hop9                  /* pos5 */
	la    t6, hop3                  /* pos6 */
	la    a1, hop10                 /* pos7 */
	la    a2, hop4                  /* pos8 */
	la    a3, hop11                 /* pos9 */
	la    a4, hop5                  /* pos10 */
	la    a5, hop12                 /* pos11 */
	la    a6, hop6                  /* pos12 */
	la    a7, hop13                 /* pos13 */
	mv    a0, s3                    /* lap counter */
	jalr  x0, 0(t0)                 /* start the storm (already uninferable itself) */

storm_done:                         /* ring exit (a0 == 0) */
.Lafter_storm:
	/* ACT-CAP command once per burst (0 = off). On cores without ACT-CAP this
	 * is an illegal instruction and therefore a deliberately chosen trap
	 * stimulus. */
	beqz  s11, .Lcalm_phase
	csrw  0xB10, s11

.Lcalm_phase:
	lw    a0, P_CALM(s0)
	beqz  a0, .Lburst_done
	mv    t5, s7                    /* trap pre-counter (0 = off) */
.Lcalm:
	addi  a0, a0, -1

	/* --- xorshift-driven branch (breaks BP/RH compression) --- */
	beqz  s9, .Lno_rand
	slli  t1, s8, 13
	xor   s8, s8, t1
	srli  t1, s8, 17
	xor   s8, s8, t1
	slli  t1, s8, 5
	xor   s8, s8, t1
	andi  t1, s8, 1
	beqz  t1, .Lno_rand
	addi  t2, x0, 0                 /* the taken arm (only so the branch has an effect) */
.Lno_rand:

	/* --- jal/ret pairs (implicit return / return stack) --- */
	beqz  s5, .Lno_calls
	mv    t3, s5
.Lcallloop:
	jal   ra, rob_leaf
	addi  t3, t3, -1
	bnez  t3, .Lcallloop
.Lno_calls:

	/* --- load/store pairs (data-trace events) --- */
	beqz  s6, .Lno_loads
	mv    t3, s6
	la    t4, rob_buf
.Lldloop:
	lw    t2, 0(t4)
	addi  t2, t2, 1
	sw    t2, 0(t4)
	addi  t4, t4, 4
	addi  t3, t3, -1
	bnez  t3, .Lldloop
.Lno_loads:

	/* --- ecall every trap_every iterations --- */
	beqz  s7, .Lno_trap
	addi  t5, t5, -1
	bnez  t5, .Lno_trap
	mv    t5, s7
	ecall                           /* the crt0 handler sets mepc += 4 and returns */
.Lno_trap:

	bnez  a0, .Lcalm

	/* book calm progress (also a store event) */
	lw    t1, S_CALM_DONE(s10)
	lw    t2, P_CALM(s0)
	add   t1, t1, t2
	sw    t1, S_CALM_DONE(s10)

.Lburst_done:
	lw    t1, S_BURST_DONE(s10)
	addi  t1, t1, 1
	sw    t1, S_BURST_DONE(s10)
	addi  s2, s2, -1
	bnez  s2, .Lburst

.Lcalm_only:
	lw    t1, S_OUTER_DONE(s10)
	addi  t1, t1, 1
	sw    t1, S_OUTER_DONE(s10)
	addi  s1, s1, -1
	bnez  s1, .Louter

.Lfinish:
	li    t1, 1
	sw    t1, S_DONE(s10)
	li    a0, 0
	lw    ra, 12(sp)
	addi  sp, sp, 16
	ret

/* ---- leaf function for the jal/ret pairs ---------------------------------- */
.align 2
rob_leaf:
	ret

/* --- Hop ring: exactly one uninferable jump per block; 1 KiB apart -------- */
.balign 0x400
hop0:   jalr  x0, 0(t1)             /* -> hop7 */
.balign 0x400
hop1:   jalr  x0, 0(t3)             /* -> hop8 */
.balign 0x400
hop2:   jalr  x0, 0(t5)             /* -> hop9 */
.balign 0x400
hop3:   jalr  x0, 0(a1)             /* -> hop10 */
.balign 0x400
hop4:   jalr  x0, 0(a3)             /* -> hop11 */
.balign 0x400
hop5:   jalr  x0, 0(a5)             /* -> hop12 */
.balign 0x400
hop6:   jalr  x0, 0(a7)             /* -> hop13 */
.balign 0x400
hop7:   jalr  x0, 0(t2)             /* -> hop1 */
.balign 0x400
hop8:   jalr  x0, 0(t4)             /* -> hop2 */
.balign 0x400
hop9:   jalr  x0, 0(t6)             /* -> hop3 */
.balign 0x400
hop10:  jalr  x0, 0(a2)             /* -> hop4 */
.balign 0x400
hop11:  jalr  x0, 0(a4)             /* -> hop5 */
.balign 0x400
hop12:  jalr  x0, 0(a6)             /* -> hop6 */
.balign 0x400
hop13:                              /* lap bookkeeping (the only block with >1 instruction) */
	addi  a0, a0, -1
	beqz  a0, 1f                    /* (LAPS-1)x not taken, 1x taken */
	jalr  x0, 0(t0)                 /* -> hop0 (next lap) */
1:	j     storm_done

/* ---- parameter block (overwritten by the host before starting) ----------- */
.section .data
.balign 16
.global rob_params
rob_params:
	.word 0x53424f52                /* 'ROBS' -- magic, so the agent can verify the block */
	.word 1                         /* outer_reps */
	.word 4                         /* bursts */
	.word 60                        /* laps_per_burst */
	.word 600                       /* calm_iters */
	.word 0                         /* mix_calls */
	.word 0                         /* mix_loads */
	.word 0                         /* trap_every */
	.word 0                         /* act_cmd */
	.word 0                         /* rand_branch */
	.word 0x1234abcd                /* seed */

.balign 16
.global rob_status
rob_status:
	.word 0                         /* outer_done */
	.word 0                         /* bursts_done */
	.word 0                         /* calm_iters_done */
	.word 0                         /* done */

.section .bss
.balign 16
.global rob_buf
rob_buf:
	.space 1024
