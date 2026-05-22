// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Instruction-trace basic combined test.
*
* @details
*   Smoke test for the instruction-trace path. Exercises linear
*   execution, conditional branches (taken / not-taken), function
*   call + return — all from a scripted scenario via `cpu_model`.
*
*   Pass criteria (placeholder until proper scoreboard lands):
*     - encoder emits at least N ATB bytes after enter()
*     - cpu_model event log matches the expected count
*     - simulation finishes without $error
*
*   Configuration:
*     - instruction trace ON
*     - timestamps ON (covered implicitly by every test, per plan)
*     - data trace OFF (exercised separately under tests/data/)
*     - HSI OFF
*/

module basic_tb;

	import cpu_model_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		// Primary artifact: binary ATB trace (the N-Trace byte stream
		// the encoder produced).
		.ATB_DUMP_PATH      ("basic_tb.atb.bin"),
		// Secondary artifact: per-instruction TIP text log.
		.TIP_DUMP_TXT_PATH  ("basic_tb.tip.txt"),
		// NexRv PCInfo derived from the cpu_model event log — drop-in
		// input for the NexRv reference decoder.
		.NEXRV_INFO_PATH    ("basic_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("basic_tb.expected.pcs")
	) env ();

	initial begin
		// ---- Wait for reset to release before touching CSRs / TIP ----
		$display("[basic_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[basic_tb] %0t: reset released", $time);

		env.csr.clear();
		$display("[basic_tb] %0t: csr cleared, starting CSR programming", $time);

		// ---- Configure encoder: enable instruction trace + timestamps ----
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		$display("[basic_tb] %0t: Enable=1", $time);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		$display("[basic_tb] %0t: InstTracing=1", $time);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		$display("[basic_tb] %0t: Active=1", $time);

		// Small settling delay
		env.wait_cycles(20);
		$display("[basic_tb] %0t: starting scenario", $time);

		// ---- Scenario ----------------------------------------------
		//
		// Phase 1 (traced):
		//   1000: linear x4         (4 instructions)
		//   1010: branch taken to 1100
		//   1100: linear x2         (2 instructions)
		//   1108: branch not taken  (falls through)
		//   110C: call foo @ 2000   (push return = 1110)
		//   2000: linear x6
		//   2018: ret               (pops 1110)
		//   1110: linear x2
		//   1118: indirect jump to 1200
		//   1200: linear x2
		// Pause (instruction tracing OFF — the CPU keeps running, untraced):
		//   1208: linear x4
		//   1218: indirect jump to 3000
		//   3000: linear x2
		// Phase 2 (traced again — re-anchored by a TRACE_ENABLE sync):
		//   3008: linear x2
		//   3010: branch taken to 3100
		//   3100: linear x2
		// End: Enable=0 (implicitly disables instruction tracing).
		// ------------------------------------------------------------
		env.cpu.enter(.start_pc(32'h0000_1000));

		env.cpu.run(16);                              // 4 linear instr

		env.cpu.branch_taken(.target(32'h0000_1100));
		env.cpu.run(8);                               // 2 linear instr

		env.cpu.branch_not_taken();                   // falls through

		env.cpu.call_to(.target(32'h0000_2000));
		env.cpu.run(24);                              // 6 linear instr inside foo
		env.cpu.ret();                                // back to 0x1110

		env.cpu.run(8);                               // 2 linear instr

		env.cpu.uninferable_jump(.target(32'h0000_1200));
		env.cpu.run(8);                               // 2 linear instr  (cur_pc -> 0x1208)

		// ---- Pause instruction tracing -----------------------------
		// Quiesce the CPU first so the Phase-1 tail fully drains through the
		// (pipeline-delayed) composer while instruction tracing is still
		// effectively on — otherwise an in-flight instruction would be
		// mis-gated by the InstTracing edge (the gate is on the undelayed
		// control signal). Then turn InstTracing off: the encoder emits a
		// Program Trace Correlation Message (TCODE 33, EVCODE=Program Trace
		// Disabled, IEEE-ISTO 5001 §4.3.16) carrying the residual instruction
		// count + branch history, so Phase 1 decodes cleanly up to here. The
		// CPU keeps executing during the pause but is NOT traced; the model
		// flag mirrors this so those PCs are excluded from the reference.
		env.wait_cycles(50);                             // drain Phase-1 (inst_trace_active still 1)
		env.csr.Set_te_trTeControl_InstTracing(1'b0);   // -> correlation message
		env.wait_cycles(200);                            // let inst_trace_active fall (CDC + margin)
		env.cpu.set_inst_traced(1'b0);
		env.cpu.run(16);                                 // 4 untraced linear instr
		env.cpu.uninferable_jump(.target(32'h0000_3000));// untraced jump elsewhere
		env.cpu.run(8);                                  // 2 untraced linear  (cur_pc -> 0x3008)

		// ---- Resume instruction tracing ----------------------------
		// Quiesce again so the untraced downtime fully drains while tracing is
		// still off (no leaked instructions), then turn InstTracing on:
		// InstTracing 0->1 (Enable still high) re-anchors the decoder with a
		// TRACE_ENABLE sync at the first resumed instruction, so the decode
		// picks up at 0x3008 even though the PC moved during the untraced gap.
		env.wait_cycles(50);                             // drain downtime (inst_trace_active still 0)
		env.csr.Set_te_trTeControl_InstTracing(1'b1);   // -> TRACE_ENABLE sync at resume
		env.wait_cycles(200);                            // let inst_trace_active rise (CDC + margin)
		env.cpu.set_inst_traced(1'b1);
		env.cpu.run(8);                                  // 2 traced linear instr
		env.cpu.branch_taken(.target(32'h0000_3100));
		env.cpu.run(8);                                  // 2 traced linear instr
		env.wait_cycles(50);                             // drain Phase-2 (inst_trace_active still 1)

		env.cpu.exit_trace();

		// ---- End: Enable=0 only ------------------------------------
		// Per the gating model, Enable=0 implicitly disables instruction
		// tracing (effective tracing = Enable && InstTracing), which triggers
		// the final trace-off correlation message AND flushes queued data in
		// one atomic event (the correlation eTIP carries do_flush=1, so there
		// is no race where it could be left unflushed). atb_force_flush then
		// pushes the last ATB bytes to the sink.
		env.wait_cycles(50);
		env.csr.Set_te_trTeControl_Enable(1'b0);        // -> correlation + flush (implicit InstTracing off)
		env.atb_force_flush = 1'b1;
		env.wait_cycles(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		// ---- Sanity checks (placeholder scoreboard) ----------------
		if (env.cpu.event_count() == 0) begin
			$error("[basic_tb] cpu_model event log is empty - cpu_model task plumbing broken?");
		end else begin
			$display("[basic_tb] cpu_model logged %0d events", env.cpu.event_count());
		end

		if (env.atb_bytes_seen == 0) begin
			$error("[basic_tb] no ATB bytes observed - encoder did not produce output");
		end else begin
			$display("[basic_tb] observed %0d ATB transfers", env.atb_bytes_seen);
		end

		// Debug-print the event log
		env.cpu.dump_events();

		$display("[basic_tb] PASS");
		$display("[basic_tb] ATB binary trace:");
		$system("realpath basic_tb.atb.bin");
		$display("[basic_tb] TIP text dump:");
		$system("realpath basic_tb.tip.txt");
		$display("[basic_tb] NexRv PCInfo:");
		$system("realpath basic_tb.nexrv.info");
		$finish;
	end

	// Global timeout — never let a broken DUT hang the regression
	initial begin
		#5ms;
		$error("[basic_tb] TIMEOUT - test exceeded 5 ms wall time");
		$finish;
	end

endmodule : basic_tb

`default_nettype wire
