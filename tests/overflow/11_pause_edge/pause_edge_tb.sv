// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Pause-edge guard: InstTracing toggled off and on in the middle of
 *           a CF-dense retire stream, asynchronously and phase-swept.
 *
 * @details
 *   Found on KV260 hardware in runs that had NO overflow at all: the composer
 *   qualified DELAYED tip beats with a LIVE-sampled inst_trace_active. At the
 *   off edge it lost up to max_delay already retired instructions; at the on
 *   edge it processed up to max_delay instructions retired while paused out
 *   of the delay pipe, whose branches then entered the stream as VendorBP
 *   messages with BCNT=0 AHEAD of the TRACE_ENABLE re-anchor (five of them in
 *   one capture), with the sync carrying ICNT=24 instead of 0. The decoder
 *   derailed into the 0x40 idle trap (a 20-million-PC walk, "ICNT walk did
 *   not terminate").
 *
 *   Fix: qualifier pipelining (ItaPipe in ct_L23_preproc), a resume gate in
 *   the composer so no beat passes between the re-enable edge and the sync
 *   anchor, a pause capture for the outstanding next_iaddr pairing, and a
 *   RetStack clear at the off edge. On the decoder side, a correlation
 *   message unlocks: the pre-lock guards skip foreign content and the
 *   re-anchor happens without an ICNT walk.
 *
 *   The driver thread continuously feeds a CF-dense cell (not-taken branch
 *   head, call/return pair, jump back); the pauser thread toggles InstTracing
 *   ASYNCHRONOUSLY to it with prime-offset intervals. That phase sweep makes
 *   the edges hit every retire type across the run, including branch, call
 *   and return inside the emission window.
 *
 *   Gates: scripts/cli_pausedge_test.sh
 *     P0  Control leg (+NO_PAUSE): "Decoded OK", zero correlation messages
 *     P1  Pause leg: at least N_PAUSES correlation messages, each followed by
 *         a re-anchor sync
 *     P2  NexRv "Decoded OK" (-bp)
 *     P3  Contract: NO count or CF messages between the correlation and the
 *         re-anchor sync; the re-anchor sync carries ICNT=0
 *     P4  check_transitions: every transition legal (pause gaps only at
 *         segment boundaries)
 *     P5  trTeControl.Empty == 1 after stop and flush
 */
module pause_edge_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (5),
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("pause_edge_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("pause_edge_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("pause_edge_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("pause_edge_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC = 32'h0000_7000;
	localparam logic [31:0] LOOP_PC = 32'h0010_0000;
	localparam logic [31:0] LEAF_PC = 32'h0020_0000;
	localparam logic [31:0] CALM_PC = 32'h0030_0000;
	localparam int unsigned LAPS     = 600;
	localparam int unsigned N_PAUSES = 8;

	bit no_pause;
	bit driver_done = 1'b0;
	logic [31:0] ctrl_rd;
	int n_fail = 0;

	initial begin
		no_pause = $test$plusargs("NO_PAUSE");
		$display("[pause_edge_tb] %0t: waiting for reset release (NO_PAUSE=%0d)", $time, no_pause);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active (1'b0);
		// Full compression suite, as in the hardware runs (periodic sync off):
		env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn   (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache  (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory  (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt         (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch     (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnIbhs             (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatInstr      (1'b1);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);
		env.cpu.uninferable_jump(.target(LOOP_PC));

		fork
			// ------------------------------------------------------------
			// Driver: a CF-dense cell that keeps running WITHOUT interruption,
			// including during the pauses -- on hardware only the encoder is
			// paused, never the core. expected.pcs deliberately contains ALL
			// retires (a superset): the decoder's pause gaps fall on segment
			// boundaries and are exempt in check_transitions.
			// ------------------------------------------------------------
			begin : driver
				for (int lap = 0; lap < LAPS; lap++) begin
					// Head: not-taken branch; on the last lap taken, which is
					// the exit path. ONE target per branch address.
					if (lap != LAPS - 1)
						env.cpu.branch_not_taken(.target(LOOP_PC + 32'h200));
					else
						env.cpu.branch_taken(.target(LOOP_PC + 32'h200));
					if (lap != LAPS - 1) begin
						env.cpu.run(8);                          // body, 2 instructions
						env.cpu.call_to(.target(LEAF_PC));       // jal/ret-Paar
						env.cpu.run(8);                          //   leaf body
						env.cpu.ret();
						env.cpu.run(4);
						env.cpu.jump_to(.target(LOOP_PC));       // back edge
					end
				end
				env.cpu.run(16);                                 // exit path @LOOP+0x200
				driver_done = 1'b1;
			end
			// ------------------------------------------------------------
			// Pauser: asynchronous InstTracing edges at prime-offset intervals,
			// sweeping the phase against the cell period.
			// ------------------------------------------------------------
			begin : pauser
				if (!no_pause) begin
					#2500ns;
					for (int p = 0; p < N_PAUSES; p++) begin
						if (driver_done) break;
						env.csr.Set_te_trTeControl_InstTracing (1'b0);
						#(700ns + 130ns * p);                    // pause length sweeps
						env.csr.Set_te_trTeControl_InstTracing (1'b1);
						#(1900ns + 370ns * p);                   // interval sweeps (prime offsets)
					end
				end
			end
		join

		env.cpu.uninferable_jump(.target(CALM_PC));
		env.cpu.run(200);
		env.cpu.exit_trace();
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);

		// P5: after stop and flush, trTeControl.Empty (bit 3) must read 1.
		env.csr.Read_te_trTeControl(ctrl_rd);
		if (ctrl_rd[3] !== 1'b1) begin
			n_fail++;
			$error("[pause_edge_tb] P5 FAIL: trTeControl.Empty=%b nach Stop+Flush (ctrl=0x%08x)",
			       ctrl_rd[3], ctrl_rd);
		end
		else begin
			$display("[pause_edge_tb] P5 ok: trTeControl.Empty=1 nach Stop+Flush");
		end

		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(1000);

		if (env.cpu.event_count() == 0) $error("[pause_edge_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[pause_edge_tb] no ATB bytes observed");
		if (n_fail == 0)
			$display("[pause_edge_tb] PASS (sim); decode gates in scripts/cli_pausedge_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[pause_edge_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule
`default_nettype wire
