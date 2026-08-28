// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Reproducer: full compression suite combined with periodic sync,
 *           WITHOUT an overflow.
 *
 * @details
 *   Found on hardware with the full compression suite enabled AND periodic
 *   sync active: the decode aborts even in the baseline run, entirely without
 *   an overflow:
 *
 *     ERROR: ICNT adjustment ERROR
 *     ERROR: VendorBP walk ended after n of n+1 branches
 *
 *   Quantified on the hardware capture: at the next ICNT carrier after each
 *   VendorBP message exactly two half-words are missing, and the oracle
 *   comparison shows the decoder one trained loop iteration short -- a
 *   predictor / counting divergence at the sync boundary. The single-factor
 *   legs (BP only, BP plus IRQs, 05_bp_hwsync) are GREEN; it takes the suite
 *   combination to reproduce.
 *
 *   Workload, modelled on the stress pattern that triggers it on hardware:
 *     (a) a trained counting loop (back edge taken 8x, exit not taken):
 *         silent under BP via PredCnt, the exit is the mispredict -> TCODE 56
 *     (b) an indirect jalr ring (JTC installs and hits)
 *     (c) call/return pairs (implicit return)
 *   The address-role rules of 03/04/05 apply: one role per address, the ring
 *   is left through the last jump, and the closing calm phase has its own
 *   region.
 *
 *   Gates: scripts/cli_suiteisync_test.sh
 *     S0  >=2 periodic syncs      -> the axis was active
 *     S1  >=1 VendorBP (TCODE 56) -> the BP path was active
 *     S2  NexRv "Decoded OK" (-bp) -> the actual guard. The defect is fixed;
 *                                     a red result means it has regressed.
 */
module suite_isync_tb #(parameter logic [3:0] SYNC_MODE = 4'd6,  // ITR_SYNC_INSTRUCTIONS
						parameter logic [3:0] SYNC_MAX  = 4'd0); // 2^(0+4) = 16 instructions

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (5),
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("suite_isync_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("suite_isync_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("suite_isync_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("suite_isync_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC      = 32'h0000_7000;
	localparam int unsigned ITERS        = 400;
	localparam int unsigned RING_TARGETS = 7;
	localparam logic [31:0] RING_BASE    = 32'h0020_0000;
	localparam logic [31:0] RING_STRIDE  = 32'h400;
	localparam logic [31:0] LOOP_BASE    = 32'h0010_0000;  // counting-loop region
	localparam logic [31:0] FN_PC        = 32'h0002_1000;  // shared function (implicit return)
	localparam logic [31:0] CALM_PC      = 32'h0030_0000;

	initial begin
		$display("[suite_isync_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (SYNC_MODE);
		env.csr.Set_te_trTeControl_InstSyncMax  (SYNC_MAX);
		// The full compression suite, as run on hardware.
		env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache  (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn   (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory  (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt         (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch     (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnIbhs             (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatInstr      (1'b1);
		$display("[suite_isync_tb] suite=BP+JTC+IR+RH+WideICNT+RB, SyncMode=%0d Max=%0d",
		         SYNC_MODE, SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);
		env.cpu.uninferable_jump(.target(LOOP_BASE));

		// ITERS laps: a counting loop (silent under branch prediction), a
		// call/return pair and a jalr ring. The loop region moves on every
		// iteration so each address keeps one role; the loop itself spins on
		// the fixed addresses of its own iteration cell.
		for (int i = 0; i < ITERS; i++) begin
			logic [31:0] cell_pc = LOOP_BASE + 32'(i) * 32'h40;
			logic [31:0] fn   = RING_BASE + 32'((i % RING_TARGETS) + 1) * RING_STRIDE;
			// (a) Trained loop: three-instruction body, back edge taken 8x,
			//     exit not taken -> a mispredict after training.
			for (int lap = 0; lap < 8; lap++) begin
				env.cpu.run(12);                                  // cell+0..8 (3 L)
				if (lap != 7)
					env.cpu.branch_taken(.target(cell_pc));           // cell+0xc BD taken
				else
					env.cpu.branch_not_taken();                   // exit: not taken
			end
			// (b) Call/return (implicit return; FN is shared, one role per address)
			env.cpu.call_to(.target(FN_PC));                      // cell+0x10 CD
			env.cpu.run(4);                                       // FN (L)
			env.cpu.ret();                                        // FN+4 -> cell+0x14
			// (c) Indirect jump into the ring and back to the next cell
			env.cpu.run(4);                                       // cell+0x14 (L)
			env.cpu.indirect_call_to(.target(fn));                // cell+0x18 CI
			env.cpu.run(4);                                       // F_i (L)
			env.cpu.ret();                                        // F_i+4 -> cell+0x1c
			env.cpu.run(4);                                       // cell+0x1c (L)
			env.cpu.uninferable_jump(.target((i == ITERS - 1)
			                                 ? CALM_PC
			                                 : (LOOP_BASE + 32'(i + 1) * 32'h40))); // cell+0x20 JI
		end

		env.cpu.run(400);                                         // Calm, eigene Region
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

		if (env.cpu.event_count() == 0) $error("[suite_isync_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[suite_isync_tb] no ATB bytes observed");
		$display("[suite_isync_tb] PASS (sim); decode gates in scripts/cli_suiteisync_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[suite_isync_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule
