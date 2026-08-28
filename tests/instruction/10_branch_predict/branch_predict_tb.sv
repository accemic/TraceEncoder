// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Branch-prediction compression test (vendor TCODE 56).
 *
 * @details
 *   Exercises the branch-prediction compression: with
 *   trTeInstFeatures.InstEnBranchPrediction set, direct branches accumulate
 *   NO HIST bits. Encoder and decoder run bit-identical predictors (2^9
 *   two-bit saturating counters, index = iaddr[10:2], init weakly
 *   not-taken); a correctly predicted branch is silent and the decoder
 *   resolves it from its own model while walking. Only a MISPREDICT emits
 *   VendorBP (TCODE 56, BCNT = correct predictions since the last
 *   PC-walking message); NexRv (-bp) walks BCNT+1 branches eagerly, the
 *   last one inverted.
 *
 *   Scenario:
 *     - Segment A: tight all-taken counting loop (the predictor's best
 *       case): 2 mispredicts total (cold counter + loop exit) versus one
 *       HIST bit per iteration OFF -> the compression win.
 *     - Interlude: two mid-stream uninferable jumps (A -> 0x2000 -> B):
 *       their IBHs' (empty-HIST) ICNT walks cover pending correctly-
 *       predicted branches -- the BP/IBH composability path.
 *     - Segment B: single branch PC with ALTERNATING outcome (the
 *       predictor's worst case, ~every branch mispredicts) -> exercises
 *       the TCODE-56-per-branch path and BCNT=0 runs, plus a second
 *       always-taken branch inside the same loop (correct predictions
 *       BETWEEN mispredicts).
 *     - Segment C: straight-line "seed hunt" (never-taken branch every
 *       3rd instruction over >3 sync periods): the rotating periodic-sync
 *       phase provably lands one sync ON a not-taken branch, forcing the
 *       ProgTraceSync HIST-seed path in BP mode.
 *     - Segment D: all-taken tail loop that absorbs the host-ATB tail
 *       truncation, keeping the coverage-carrying segments inside the
 *       verified prefix.
 *   Periodic sync every 512 tip-clk cycles (~128 instructions) lands on
 *   arbitrary instructions -- some ON branches, exercising
 *   DirectBranchSync (taken) and the seed path (not-taken) in BP mode.
 *
 *   Run twice from the same binary:
 *     - default (no plusarg)  -> BP OFF (HIST bits per branch)
 *     - +BP                   -> BP ON  (TCODE 56 on mispredicts only)
 *   The decoded PC prefix must be IDENTICAL OFF vs ON (lossless; the ON
 *   decode needs NexRv -bp), and ON must produce a smaller ATB.
 */

module branch_predict_tb;

	import cpu_model_pkg::*;

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd5;   // 512-cycle periodic sync
	                                                     // (~128 instr): enough syncs
	                                                     // that some land ON branches,
	                                                     // exercising DirectBranchSync
	                                                     // and the seed path in BP mode
	localparam int         N_ITERS_A           = 400;    // all-taken loop
	localparam int         N_BLOCKS_C          = 160;    // straight-line seed hunt:
	                                                     // >3 sync periods so one
	                                                     // periodic sync provably
	                                                     // lands ON a not-taken
	                                                     // branch (HIST-seed path)
	localparam int         N_ITERS_D           = 120;    // all-taken tail loop
	                                                     // (truncation absorber)
	localparam int         N_ITERS_B           = 41;     // alternating loop; ODD so
	                                                     // the last iteration exits
	                                                     // through 0x1020 (not-taken)
	                                                     // and the coda starts at
	                                                     // 0x1024, keeping every PC's
	                                                     // instruction kind consistent

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("branch_predict_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("branch_predict_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("branch_predict_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("branch_predict_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		// BEFORE Enable: trTeInstFeatures is swwel-gated like the rest of the
		// configuration (U10 F-1) -- a write after arming is silently void.
		if ($test$plusargs("BP")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			$display("[bp_tb] %0t: InstEnBranchPrediction=1 (BP ON)", $time);
		end else begin
			$display("[bp_tb] %0t: BP OFF (baseline)", $time);
		end

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);

		env.wait_cycles(20);

		// ---- Scenario --------------------------------------------------
		// Segment A @ 0x1000 (12-byte body, all-taken counting loop):
		//   0x1000: L        (run 4)
		//   0x1004: L        (run 4)
		//   0x1008: BD taken -> 0x1000   (last iteration: not taken)
		env.cpu.enter(.start_pc(32'h0000_1000));
		for (int i = 0; i < N_ITERS_A; i++) begin
			env.cpu.run(8);
			if (i < N_ITERS_A - 1)
				env.cpu.branch_taken(.target(32'h0000_1000));
			else
				// Would-be target MUST be passed explicitly: 0x1008 is
				// taken elsewhere and PCInfo's first-observation-wins
				// rule would otherwise record the cur_pc+8 default.
				env.cpu.branch_not_taken(.target(32'h0000_1000)); // fall through to segment B
		end

		// Interlude: indirect dispatch A -> 0x2000 -> back to segment B.
		// The two IBHs sit MID-stream, so their (empty-HIST, in BP mode)
		// ICNT walks cover pending correctly-predicted branches -- the
		// composability path that a tail-positioned IBH would lose to the
		// host ATB truncation.
		//   0x100c: JI -> 0x2000
		//   0x2000: L, 0x2004: L, 0x2008: JI -> 0x1010
		env.cpu.uninferable_jump(.target(32'h0000_2000));
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(32'h0000_1010));

		// Segment B @ 0x1010 (24-byte body):
		//   0x1010: L        (run 4)
		//   0x1014: L        (run 4)
		//   0x1018: BD       ALTERNATING: even iters not taken, odd iters
		//                    taken -> 0x1010 (predictor worst case)
		//   0x101c: L        (run 4)         } only on even iterations
		//   0x1020: L        (run 4)         }
		//   0x1024: BD taken -> 0x1010   (last iteration: not taken)
		for (int i = 0; i < N_ITERS_B; i++) begin
			env.cpu.run(8);
			if (i[0]) begin
				env.cpu.branch_taken(.target(32'h0000_1010));
			end
			else begin
				// Explicit would-be target: 0x1018/0x1024 are taken in
				// other iterations -- the PCInfo target must be the real
				// branch target, not the not-taken default (cur_pc+8).
				env.cpu.branch_not_taken(.target(32'h0000_1010));
				env.cpu.run(8);
				if (i < N_ITERS_B - 1)
					env.cpu.branch_taken(.target(32'h0000_1010));
				else
					env.cpu.branch_not_taken(.target(32'h0000_1010)); // fall through to coda
			end
		end

		// Coda @ 0x1028 (reached via 0x1024 not-taken on the final, even
		// segment-B iteration): linear run, then dispatch to segment C.
		//   0x1028: L, 0x102c: L, 0x1030: JI -> 0x3000
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(32'h0000_3000));

		// Segment C @ 0x3000: straight-line seed hunt. N_BLOCKS_C blocks of
		// {L, L, BD never-taken} march forward 12 bytes each. The periodic
		// sync period (512 cycles) is 8 mod the 12-cycle block, so the sync
		// attach point ROTATES through all three instruction slots across
		// any three consecutive sync periods -- one of them is GUARANTEED
		// to land ON a not-taken branch, forcing the ProgTraceSync HIST-
		// seed path (the one branch-resolution source that is neither the
		// predictor nor a message contract). The never-taken branches
		// themselves settle to correct predictions immediately.
		for (int i = 0; i < N_BLOCKS_C; i++) begin
			env.cpu.run(8);
			env.cpu.branch_not_taken(); // unique PC, never taken: default target OK
		end
		env.cpu.uninferable_jump(.target(32'h0000_4000));

		// Segment D @ 0x4000: all-taken tail loop. Its only job is to sit
		// at the END of the capture so the host-ATB tail truncation eats
		// boring, cleanly-decodable all-taken content instead of the
		// coverage-carrying segments above.
		//   0x4000: L, 0x4004: L, 0x4008: BD taken -> 0x4000
		for (int i = 0; i < N_ITERS_D; i++) begin
			env.cpu.run(8);
			if (i < N_ITERS_D - 1)
				env.cpu.branch_taken(.target(32'h0000_4000));
			else
				env.cpu.branch_not_taken(.target(32'h0000_4000));
		end
		env.cpu.run(8);

		env.cpu.exit_trace();

		// ---- End drain (mirrors 07/08/09) ------------------------------
		env.wait_cycles(50);
		env.atb_force_flush = 1'b1;
		env.atb_force_sync  = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.atb_force_sync  = 1'b0;
		env.wait_cycles(500);

		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(2000);

		if (env.cpu.event_count() == 0)
			$error("[bp_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)
			$error("[bp_tb] no ATB bytes observed");

		$display("[bp_tb] PASS (scenario driven, %0d events)", env.cpu.event_count());
		$finish;
	end

	// Global timeout
	initial begin
		#40_000_000;
		$display("[bp_tb] TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
