// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Debug-/power-/EVTI-event handling (B1): SYNC 3/9/0 + Correlation EVCODE 0/1.
 *
 * @details
 *   Regression gate for the seq-24 B1 feature group (CT_EN_DEBUG_EVENTS /
 *   CT_EN_POWER_EVENTS / CT_EN_EVTI + the generic tip.debug_mode / tip.evti
 *   / tip.power_down event sideband):
 *
 *     1. Debug entry with PENDING branch history: the encoder emits a
 *        Program Trace Correlation Message with EVCODE=0 (Entry into Debug
 *        Mode, N-Trace Required) carrying the residual ICNT and the pending
 *        HIST (CDF=1; exercises the A1 always-HIST rule with a non-empty
 *        payload). Instructions retired while tip.debug_mode=1 are NOT
 *        traced and NOT counted ("no trace in debug").
 *     2. Debug exit: the very first retire re-anchors with SYNC=3 (Exit
 *        from Debug Mode, Required) -- NOT with SYNC=5.
 *     3. EVTI pulse while tracing: the next retire is upgraded to a SYNC=0
 *        marker (External Trace Trigger).
 *     4. Power-down entry: Correlation EVCODE=1 (Entry into Low-power
 *        Mode); after the exit the first retire re-anchors with SYNC=9
 *        (Exit from Powerdown).
 *     5. Normal trace-off at the end still emits the EVCODE=4 correlation
 *        (Program Trace Disabled) -- the EVCODE-via-rdata1 plumbing must
 *        not disturb the historical path.
 *
 *   Verification: scripts/cli_dbg_test.sh --
 *     decode_and_check.sh --pc (HARD, strict full match: debug-window PCs
 *     appear in neither the stream nor the reference) plus greps for
 *     SYNC[4]=0x3 / 0x9 / 0x0 and EVCODE[4]=0x0 / 0x1 / 0x4 in the NexRv
 *     -full decode log.
 *
 *   Deterministic (behavioural cpu_model); instruction trace ON
 *   (BRANCH_HIST), periodic sync OFF, timestamps OFF, data OFF.
 */

module debug_events_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("debug_events_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("debug_events_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("debug_events_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("debug_events_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC  = 32'h0000_2000;
	localparam logic [31:0] DBG_PC   = 32'h0000_8000; // "debug ROM" window
	localparam logic [31:0] LOOP_PC  = 32'h0000_2100;

	initial begin
		$display("[debug_events_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[debug_events_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active      (1'b0);   // timestamps OFF
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.wait_cycles(20);
		$display("[debug_events_tb] %0t: scenario start", $time);

		// ---- Phase 1: build pending state, then enter debug ----
		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(16);                                   // 4 L retires
		env.cpu.branch_taken(.target(LOOP_PC));            // BD -> 1 pending HIST bit
		env.cpu.run(8);                                    // 2 L retires (pending ICNT)

		// Debug entry: correlation EVCODE=0 with residual ICNT + pending
		// HIST (CDF=1, non-empty). Debug-window retires are not traced.
		env.cpu.debug_enter();
		env.cpu.enter(.start_pc(DBG_PC));                  // "debug ROM" body
		env.cpu.run(24);                                   // 6 untraced retires
		env.cpu.debug_exit();

		// ---- Phase 2: exit from debug -> SYNC=3 on the first retire ----
		env.cpu.enter(.start_pc(LOOP_PC + 32'h10));
		env.cpu.run(12);                                   // first retire carries SYNC=3
		env.cpu.branch_taken(.target(LOOP_PC + 32'h40));

		// ---- Phase 3: EVTI marker (SYNC=0) ----
		env.cpu.evti_pulse();
		env.cpu.run(12);                                   // next retire carries SYNC=0

		// ---- Phase 4: power-down window ----
		env.cpu.power_down_enter();                        // correlation EVCODE=1
		env.cpu.idle(50);                                  // no retires while down
		env.cpu.power_down_exit();
		env.cpu.run(12);                                   // first retire carries SYNC=9
		env.cpu.branch_not_taken();
		env.cpu.run(8);
		env.cpu.exit_trace();

		// ---- Trace-off drain (correlation EVCODE=4 + flush) ----
		// NOTE: env.wait_cycles() waits far shorter than requested under
		// XSIM (pre-existing anomaly, likely the root of the known suite
		// "end-drain" tail-loss class). This test's gates depend on the
		// tail surviving, so the drain uses env.cpu.idle() -- the
		// cpu_model-side wait provably consumes real tip_clk cycles (the
		// power-down window above measures 50 idles = 500 ns on the wire).
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(2000);

		// ---- Liveness checks (the real gate is cli_dbg_test.sh) ----
		if (env.cpu.event_count() == 0)
			$error("[debug_events_tb] cpu_model event log empty");
		else
			$display("[debug_events_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[debug_events_tb] no ATB bytes observed");
		else
			$display("[debug_events_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[debug_events_tb] PASS (sim); decode verified by scripts/cli_dbg_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[debug_events_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : debug_events_tb

`default_nettype wire
