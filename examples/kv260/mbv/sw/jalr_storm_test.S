/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * jalr_storm_test.S -- a jump-indirect storm for proving on-chip
 * overflow->resync recovery under hardening/robustness testing.
 *
 * Lesson learned (from characterization work + prior board hardening):
 * overflow workloads need UNINFERABLE jumps -- the composer's HIST
 * accumulation dampens direct-branch storms by roughly 32:1 (2,400 branches
 * -> only 372 eTIP slots). Every uninferable jalr produces its own
 * IndirectBranchHist message; if the core produces them faster than the
 * formatter can serialize, the eTIP/sideband FIFO overflows -> ERROR
 * (TCODE 8, QueueOverrun) + SYNC=7 recovery (FIFO_OVERFLOW resync).
 *
 * Burst structure (found empirically across several hardening runs):
 * a CONTINUOUS storm saturates the encoder so hard that no control-flow
 * window remains between recovery sync and the next overflow -- the decode
 * then contains ONLY the prologue plus ERROR/SYNC pairs, but no
 * post-resync segments (onset: the ~128-deep eTIP FIFO absorbs ~430 jumps,
 * then thrashing sets in). Hence bursts:
 *   * STORM burst: LAPS_PER_BURST ring laps x 14 uninferable jalr back-to-back
 *     (60 laps = 840 jumps >> the ~430 onset) -> guarantees >=1 overflow per burst;
 *   * the CALM PHASE MUST FULLY DRAIN THE BACKLOG (found the hard way: 150
 *     iterations ~= 450 cycles is marginal -- the saturation bled into the
 *     following burst and triggered a thrash-regime defect): 600 iterations of
 *     a tight counting loop (HIST bits only) -> recovery becomes VISIBLE:
 *     decodable reference segments appear between bursts;
 *   * 6 bursts, ending on a calm phase -> a clean, decodable tail up to trace-off.
 *
 * Hop ring: 14 blocks of exactly ONE `jalr x0, 0(rN)` each (rs1 = a
 * one-time preloaded register -> uninferable for both the adapter
 * (sijump_en=0) and the decoder), physically spread 1 KiB apart, chained in
 * INTERLEAVED order (hop0->hop7->hop1->...): target XORs land around
 * 0x2400..0x3400 -> UADDR 13-14 bit (~3 MDO bytes per message). Block 13
 * carries the lap bookkeeping.
 *
 * Expected result (the overflow-checking tooling): >=1 error message,
 * "Decoded OK", decoded PCs = reference segments with gaps ONLY at overflow
 * points, >=1 gap WITH a post-resync segment (recovery proven), gap count
 * <= error count (no silent loss).
 */
.option norvc
.section .text
.global main
.align 2

.equ BURSTS,         6
.equ LAPS_PER_BURST, 60
.equ CALM_ITERS,     600

main:
	addi  sp, sp, -8
	sw    s1, 4(sp)
	li    s1, BURSTS
	/* Load the ring registers (ring position -> physical block, interleaved): */
	la    t0, hop0                 /* pos0 */
	la    t1, hop7                 /* pos1 */
	la    t2, hop1                 /* pos2 */
	la    t3, hop8                 /* pos3 */
	la    t4, hop2                 /* pos4 */
	la    t5, hop9                 /* pos5 */
	la    t6, hop3                 /* pos6 */
	la    a1, hop10                /* pos7 */
	la    a2, hop4                 /* pos8 */
	la    a3, hop11                /* pos9 */
	la    a4, hop5                 /* pos10 */
	la    a5, hop12                /* pos11 */
	la    a6, hop6                 /* pos12 */
	la    a7, hop13                /* pos13 */

.Louter:
	li    a0, LAPS_PER_BURST       /* lap counter for this burst */
	jalr  x0, 0(t0)                /* start the storm (already uninferable itself) */

storm_done:                        /* ring exit (a0 == 0) -> calm phase */
	li    a0, CALM_ITERS
.Lcalm:
	addi  a0, a0, -1
	bnez  a0, .Lcalm               /* HIST bits only; drains the encoder's backlog */
	addi  s1, s1, -1
	bnez  s1, .Louter

	li    a0, 0
	lw    s1, 4(sp)
	addi  sp, sp, 8
	ret

/* --- Hop ring: exactly one uninferable jump per block; 1 KiB apart --------- */
.balign 0x400
hop0:   jalr  x0, 0(t1)            /* -> hop7 */
.balign 0x400
hop1:   jalr  x0, 0(t3)            /* -> hop8 */
.balign 0x400
hop2:   jalr  x0, 0(t5)            /* -> hop9 */
.balign 0x400
hop3:   jalr  x0, 0(a1)            /* -> hop10 */
.balign 0x400
hop4:   jalr  x0, 0(a3)            /* -> hop11 */
.balign 0x400
hop5:   jalr  x0, 0(a5)            /* -> hop12 */
.balign 0x400
hop6:   jalr  x0, 0(a7)            /* -> hop13 */
.balign 0x400
hop7:   jalr  x0, 0(t2)            /* -> hop1 */
.balign 0x400
hop8:   jalr  x0, 0(t4)            /* -> hop2 */
.balign 0x400
hop9:   jalr  x0, 0(t6)            /* -> hop3 */
.balign 0x400
hop10:  jalr  x0, 0(a2)            /* -> hop4 */
.balign 0x400
hop11:  jalr  x0, 0(a4)            /* -> hop5 */
.balign 0x400
hop12:  jalr  x0, 0(a6)            /* -> hop6 */
.balign 0x400
hop13:                             /* lap bookkeeping (the only block with >1 instruction) */
	addi  a0, a0, -1
	beqz  a0, 1f                   /* (LAPS-1)x not taken, 1x taken (1 HIST bit per lap) */
	jalr  x0, 0(t0)                /* -> hop0 (next lap) */
1:	j     storm_done
