// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Cross-term guard: trace window edge x FIFO overflow x branch
 *           prediction / JTC x dense periodic sync.
 *
 * @details
 *   Two hardware findings from randomized soak replays share this shape.
 *
 *   First: an abort with "IndirectBranchHist resolved source 0x90c to a
 *   non-indirect instruction" at 72 % of the stream. Message forensics show
 *   two structurally identical FIFO_OVERRUN recoveries at the SAME anchor;
 *   the good one carries an IBH with ICNT=24, which is the true half-word
 *   distance from the anchor to the return, while the bad one carries
 *   ICNT=18. The encoder UNDERCOUNTS by six half-words, the three linear
 *   instructions directly behind the anchor. No legal path yields 18.
 *
 *   Second: an abort with "ICNT adjustment ERROR" four messages before the
 *   stop correlation. Between a VendorBP (BCNT=3) and a periodic sync
 *   (ICNT=0 at the return target) the return JTC message (about ICNT=36) is
 *   missing entirely -- a message SWALLOWED at the stop drain, the mirror
 *   image of the duplicate-JTC class in gate 13.
 *
 *   Common denominator: emission-cycle collisions between the injector and
 *   drain chains under branch prediction and JTC, triggered by window and
 *   stop edges in the overflow regime.
 *
 *   This leg forces those cross terms statistically: a stress-style inner
 *   loop (mispredict-dense alternation, a seven-instruction linear run, a
 *   call/return loop, a JTC ring and a trained counting loop) under a hard
 *   ATB throttle to produce natural overflows, crossed with asynchronous
 *   InstTracing windows at prime-swept phases and a sync every 16
 *   instructions.
 *
 *   Testbench rules observed: one role per address; branch_not_taken ALWAYS
 *   with an explicit target (outcome alternation is allowed -- the rule
 *   constrains targets, not outcomes); the calm and exit regions are separate
 *   and never re-entered; a non-CF instruction immediately before an edge
 *   occurs naturally inside the linear run.
 *
 *   Gates: scripts/cli_ovfwindow_test.sh
 *     W0  Control leg (+NO_WINDOW): overflow + BP/JTC + dense sync WITHOUT
 *         windows -- a single-factor falsification, expected green
 *     W1  Window leg: >=1 Nexus error message -> overflow regime active
 *     W2  Window leg: >=1 VendorBP and >=4 correlations -> cross term active
 *     W3  NexRv "Decoded OK" (-bp) AND check_transitions legal. The class is
 *         fixed; red with either hardware signature means it has regressed.
 */
module ovf_window_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (40),     // throttle: drain << source rate -> natural overflows
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("ovf_window_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("ovf_window_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("ovf_window_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("ovf_window_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC   = 32'h0000_7000;
	localparam logic [31:0] LOOP      = 32'h0010_0000;  // fixed cell, shaped like the hardware stress loop
	localparam logic [31:0] LEAF_PC   = 32'h0020_0000;  // call target
	localparam logic [31:0] RING_BASE = 32'h0021_0000;  // JTC-Ring (INSTALL/HIT)
	localparam logic [31:0] CALM_PC   = 32'h0030_0000;
	localparam int unsigned RING_TARGETS = 6;
	localparam logic [31:0] RING_STRIDE  = 32'h100;
	localparam int unsigned LAPS      = 2000;
	localparam int unsigned N_WINDOWS = 12;

	bit no_window;
	bit driver_done = 1'b0;

	// One lap of the cell. Shape and roles follow the inner loop of the
	// hardware stress workload: a head branch skips the linear run, a second
	// branch at the end of the run targets the SAME address, then a join
	// branch, a two-iteration call/return loop, a trained four-iteration
	// counting loop, a JTC ring call and the back edge.
	task automatic one_lap(input int lap);
		logic [31:0] fn = RING_BASE + 32'((lap % RING_TARGETS) + 1) * RING_STRIDE;
		// +0x00 BD_A -> +0x28 (alternierend: mispredict-dicht)
		if (lap[0]) begin
			env.cpu.branch_taken(.target(LOOP + 32'h28));
		end
		else begin
			env.cpu.branch_not_taken(.target(LOOP + 32'h28));
			env.cpu.run(28);                                   // +0x04..+0x1f: the 7-instruction linear run that was undercounted
			// +0x20 BD_B -> +0x28 (its own alternation phase)
			if (lap[1]) env.cpu.branch_taken(.target(LOOP + 32'h28));
			else begin
				env.cpu.branch_not_taken(.target(LOOP + 32'h28));
				env.cpu.run(4);                                // +0x24 L
			end
		end
		// +0x28 BD_C -> +0x58 (Periode 3)
		if (lap % 3 == 0) begin
			env.cpu.branch_taken(.target(LOOP + 32'h58));
		end
		else begin
			env.cpu.branch_not_taken(.target(LOOP + 32'h58));
			env.cpu.run(4);                                    // +0x2c L
			// Call/return loop: two iterations, as in the hardware workload
			for (int c = 0; c < 2; c++) begin
				env.cpu.call_to(.target(LEAF_PC));             // +0x30 CD
				env.cpu.run(4);                                //   LEAF L
				env.cpu.ret();                                 //   LEAF+4 R -> +0x34
				env.cpu.run(4);                                // +0x34 L
				if (c == 0) env.cpu.branch_taken(.target(LOOP + 32'h30));      // +0x38 BD_D
				else        env.cpu.branch_not_taken(.target(LOOP + 32'h30));
			end
			env.cpu.run(4);                                    // +0x3c L
			env.cpu.jump_to(.target(LOOP + 32'h58));           // +0x40 JD -> Join
		end
		// +0x58 Join: getrainte Zaehlschleife (Back-Edge 3x taken, Exit NT)
		for (int k = 0; k < 4; k++) begin
			env.cpu.run(16);                                   // +0x58..+0x67: 4 L
			if (k != 3) env.cpu.branch_taken(.target(LOOP + 32'h58));          // +0x68 BD_E
			else        env.cpu.branch_not_taken(.target(LOOP + 32'h58));
		end
		env.cpu.run(4);                                        // +0x6c L
		env.cpu.indirect_call_to(.target(fn));                 // +0x70 CI (JTC)
		env.cpu.run(4);                                        //   fn L
		env.cpu.ret();                                         //   fn+4 R -> +0x74
		env.cpu.run(4);                                        // +0x74 L
		// +0x78 BD_F back edge -> LOOP (last lap: not taken -> exit path)
		if (lap != LAPS - 1) begin
			env.cpu.branch_taken(.target(LOOP));
		end
		else begin
			env.cpu.branch_not_taken(.target(LOOP));
			env.cpu.run(4);                                    // +0x7c L
			env.cpu.jump_to(.target(CALM_PC));                 // +0x80 JD -> Calm
		end
	endtask

	initial begin
		no_window = $test$plusargs("NO_WINDOW");
		$display("[ovf_window_tb] %0t: waiting for reset release (NO_WINDOW=%0d)", $time, no_window);
		env.wait_for_reset_release();

		env.csr.clear();
		// As in 07/09/10: the hardware runs never write trTsControl, so timestamps are ACTIVE.
		env.csr.Set_te_trTsControl_Active       (1'b1);
		// Sync axis as on hardware: InstSyncMode=instructions, Max=0 -> 2^4 = 16.
		env.csr.Set_te_trTeControl_InstSyncMode (4'd6);
		env.csr.Set_te_trTeControl_InstSyncMax  (4'd0);
		// Feature set of the hardware runs: ONLY branch prediction and the jump-target cache.
		env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache  (1'b1);
		$display("[ovf_window_tb] BP+JTC + timestamps + sync every 16 instructions, ATB throttled to 40 ns");
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);
		env.cpu.uninferable_jump(.target(LOOP));

		fork
			// Driver: the cell runs WITHOUT interruption -- on hardware only
			// the encoder is paused, never the core. expected.pcs is a
			// superset of all retires.
			begin : driver
				for (int lap = 0; lap < LAPS; lap++) one_lap(lap);
				env.cpu.run(16);
				driver_done = 1'b1;
			end
			// Windower: asynchronous InstTracing edges at prime offsets,
			// sweeping the phase against both the cell period and the
			// overflow episodes.
			begin : windower
				if (!no_window) begin
					#3100ns;
					for (int p = 0; p < N_WINDOWS; p++) begin
						if (driver_done) break;
						env.csr.Set_te_trTeControl_InstTracing (1'b0);
						#(900ns + 170ns * p);                  // window length sweeps
						env.csr.Set_te_trTeControl_InstTracing (1'b1);
						#(2300ns + 410ns * p);                 // Abstand sweept (Primz.)
					end
				end
			end
		join

		env.cpu.run(400);                                      // Calm-Region
		env.cpu.exit_trace();
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(8000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(1000);

		if (env.cpu.event_count() == 0) $error("[ovf_window_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[ovf_window_tb] no ATB bytes observed");
		$display("[ovf_window_tb] PASS (sim); decode gates in scripts/cli_ovfwindow_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#60ms;
		$error("[ovf_window_tb] TIMEOUT - test exceeded 60 ms wall time");
		$finish;
	end

endmodule
`default_nettype wire
