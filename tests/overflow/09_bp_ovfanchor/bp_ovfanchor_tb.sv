// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    FIFO_OVERRUN anchor landing on a branch retire, with branch
 *           prediction: the recovery-anchor variant of the state family.
 *
 * @details
 *   Found on KV260 hardware across several runs, all with periodic sync off,
 *   overflow active and branch prediction on: after a FIFO_OVERRUN recovery
 *   the decoder takes a direct conditional branch in the wrong direction
 *   ("VendorBP walk ended after 1 of 6", "indirect address encountered in
 *   ICNT", or -- worst case -- silently wrong PCs while still reporting
 *   "Decoded OK": the anchor sat ON a beq, the decode took it as taken, and
 *   the reference diverged on all 24 comparisons).
 *
 *   Mechanism (ovf_injector plus composer_etip): while injecting, presented
 *   eTIP items are DISCARDED. inject_hold covers PrevRetireWasCf and CF
 *   retires in the emission cycle -- but a NOT_TAKEN_BRANCH retire is NOT a
 *   control-flow change and slips through: its outcome item (the HIST bit or
 *   PredCnt contribution) is discarded while the anchor `PrevIAddr+size`
 *   points EXACTLY at that branch. The decoder (BpInit at SYNC==7) walks the
 *   branch from the anchor as the first post-anchor branch and consumes an
 *   outcome the encoder never counted, producing the BCNT/HIST shift behind
 *   all of the observed signatures.
 *
 *   This leg forces the collision statistically: an IBH-dense function-pointer
 *   ring (storm as in 04_ir_overflow) in which EVERY ring function carries a
 *   NOT-taken conditional branch immediately before its return, so every
 *   fourth instruction is a not-taken branch. Over hundreds of natural
 *   recoveries the anchor reliably lands several times on a branch retire that
 *   was discarded in the emission cycle.
 *
 *   The testbench rules of 03/04/08 apply: one role per address, call sites
 *   advance monotonically, no calm region is re-entered, and
 *   branch_not_taken ALWAYS gets an explicit target.
 *
 *   Gates: scripts/cli_bpovfanchor_test.sh
 *     A0  Control run (CALM_ONLY=1): ring traffic without an overflow decodes
 *         cleanly and transition-exactly
 *     A1  >=1 Nexus error message                 -> natural overflow reached
 *     A2  InstEnBranchPrediction=1 and >=1 VendorBP -> BP path active
 *     A3  NexRv "Decoded OK" AND every decoded PC transition appears in the
 *         expectation (scripts/check_transitions.py). "Decoded OK" on its own
 *         GREENWASHES this class -- one hardware run decoded OK with wrong
 *         PCs.
 */

// CALM_ONLY=1 runs the CONTROL leg (wrapper top, see 04_ir_overflow).
//
// SUITE=1 enables the FULL feature suite, which is the configuration the
// hardware runs used. The BP-only leg stayed GREEN on the unfixed RTL (988
// recoveries, 988 VendorBP messages, transition-exact), which is a
// falsification datum: branch prediction combined with the overflow anchor
// does NOT on its own carry this defect class.
//
// ATB_HALF_NS is the ATB half period. The suite leg needs a harder throttle
// (40 instead of 5): with the full suite the JTC absorbs the call ring (one
// install, then hits) and the message rate drops so far that the FIFO NEVER
// overflows at a 1:1 clock ratio -- the first suite leg produced zero
// recoveries. Same lesson as 04_ir_overflow, whose eight-instruction body
// never overflowed.
module bp_ovfanchor_tb #(parameter bit CALM_ONLY   = 1'b0,
						 parameter bit SUITE       = 1'b0,
						 parameter int ATB_HALF_NS = 5);

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (ATB_HALF_NS), // >= tip half period, so the drain cannot outrun the source
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("bp_ovfanchor_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("bp_ovfanchor_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("bp_ovfanchor_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("bp_ovfanchor_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC      = 32'h0000_7000;
	localparam int unsigned STORM_CALLS  = 4000;
	localparam int unsigned RING_TARGETS = 14;
	localparam logic [31:0] RING_BASE    = 32'h0020_0000;
	localparam logic [31:0] RING_STRIDE  = 32'h400;
	// Call-site regions: one per phase, monotonic, never re-entered.
	localparam logic [31:0] SITES_WARM   = 32'h0010_0000;
	localparam logic [31:0] SITES_STORM1 = 32'h0011_0000;  // 4000*4B = 16 KiB
	localparam logic [31:0] SITES_STORM2 = 32'h0013_0000;
	localparam logic [31:0] SITES_CALM   = 32'h0015_0000;  // control leg

	// One pass through the ring. Each iteration is an indirect call (IBH) to
	// a ring function of the shape L / BD / [L] / RET: the conditional branch
	// sits directly after the function head and its outcome ALTERNATES per
	// iteration (taken -> fn+12, not taken -> fn+8 body -> fn+12).
	//
	// An alternating pattern keeps the two-bit predictor permanently
	// mispredicting, which produces dense VendorBP/BCNT traffic. An earlier
	// version with always-not-taken branches produced 1040 recoveries and ZERO
	// VendorBP messages: correctly predicted branches are silent, and without
	// BCNT traffic the anchor collision has no observable consequence.
	//
	// Roles stay unambiguous: fn+4 is a BD with ONE target, fn+12. The outcome
	// may change per iteration -- the one-target rule constrains targets, not
	// outcomes.
	task automatic anchor_storm(input logic [31:0] sites_base, input int unsigned n);
		env.cpu.uninferable_jump(.target(sites_base));
		for (int i = 0; i < n; i++) begin
			logic [31:0] fn = RING_BASE + 32'((i % RING_TARGETS) + 1) * RING_STRIDE;
			env.cpu.indirect_call_to(.target(fn));    // call site (4 B per iteration)
			env.cpu.run(4);                           // fn+0  (L)
			if (i[0]) begin
				env.cpu.branch_taken(.target(fn + 32'hc));     // fn+4 BD taken
			end
			else begin
				env.cpu.branch_not_taken(.target(fn + 32'hc)); // fn+4 BD nt
				env.cpu.run(4);                                // fn+8  (L)
			end
			env.cpu.ret();                            // fn+12 -> call site + 4
		end
	endtask

	initial begin
		$display("[bp_ovfanchor_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();

		env.csr.clear();
		// As in 07_board_replay: the hardware runs never write trTsControl, so
		// the reset default leaves timestamps ACTIVE. The suite leg reproduces
		// that configuration exactly (timestamps on); the BP-only leg keeps
		// them off as its single-factor baseline.
		env.csr.Set_te_trTsControl_Active                      (SUITE);
		// Single-factor baseline: branch prediction on, no JTC and no implicit
		// return -- those have their own anchor clears and their own gates in
		// 03 and 04. SUITE=1 adds the full feature suite the hardware runs
		// used.
		env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
		if (SUITE) begin
			env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache  (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn   (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory  (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt         (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch     (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnIbhs             (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatInstr      (1'b1);
			$display("[bp_ovfanchor_tb] SUITE=1 (full feature suite)");
		end
		$display("[bp_ovfanchor_tb] InstEnBranchPrediction=1");
		env.csr.Set_te_trTeControl_Enable                      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing                 (1'b1);
		env.csr.Set_te_trTeControl_Active                      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);

		// Quiet warm-up lap: encoder and decoder are guaranteed to agree here.
		anchor_storm(SITES_WARM, RING_TARGETS);
		env.cpu.run(400);

		// CONTROL leg: ring traffic without an overflow, in its own call-site region.
		if (CALM_ONLY) begin
			anchor_storm(SITES_CALM, 3 * RING_TARGETS);
			env.cpu.run(400);
		end
		else begin
			// STORM: two waves with a short calm phase in between, which gives
			// a recovery window with a fresh anchor in the middle of ring
			// traffic.
			anchor_storm(SITES_STORM1, STORM_CALLS);
			env.cpu.run(200);
			anchor_storm(SITES_STORM2, STORM_CALLS);
			env.cpu.run(400);
		end

		env.cpu.exit_trace();
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(1000);

		if (env.cpu.event_count() == 0) $error("[bp_ovfanchor_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[bp_ovfanchor_tb] no ATB bytes observed");
		$display("[bp_ovfanchor_tb] PASS (sim); decode gates in scripts/cli_bpovfanchor_test.sh");
		$finish;
	end

endmodule
`default_nettype wire
