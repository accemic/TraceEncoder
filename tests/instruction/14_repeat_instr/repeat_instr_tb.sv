// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    RepeatInstruction (TCODE 31/32): spin-loop compression (B3).
 *
 * @details
 *   Regression gate for CT_EN_REPEAT_INSTR / trTeInstFeatures.
 *   InstEnRepeatInstr (seq 24 B3; ISTO-5001 4.3.14/15 -- TCODE 31/32 are
 *   RESERVED in N-Trace 1.0, hence the runtime enable resets to 0).
 *
 *   Workload: a single-instruction spin loop (taken branch targeting its
 *   own address, 60 iterations) inside a short periodic-sync window, so
 *   periodic syncs repeatedly land ON the loop branch mid-run:
 *
 *     OFF leg: one HIST bit per iteration -- HIST-overflow flushes +
 *          plain sync forms; NO TCODE 31/32.
 *     ON leg (+RPTI): iterations after the first are counted; runs close
 *          as TCODE 31 (R-CNT/I-CNT/HIST) or -- when the periodic sync
 *          lands on the loop branch -- as TCODE 32 (SYNC/R-CNT/I-CNT/
 *          F-ADDR/HIST). Far fewer messages/bytes.
 *     RH leg (+RPTI_RH): the THIRD repeat form for contrast -- repeated
 *          identical HIST windows compress as ResourceFull RCODE=2
 *          (no TCODE 31/32 involved).
 *
 *   All legs must decode PC-lossless against the same cpu_model reference
 *   (scripts/cli_rpti_test.sh; NexRv TCODE-31/32 walk = ICNT+HIST walk,
 *   then R-CNT[+1] loop-PC replays[, anchor at F-ADDR]).
 *
 *   Deterministic; BRANCH_HIST mode, timestamps OFF, data OFF; drain via
 *   env.cpu.idle() (wait_cycles XSIM anomaly, FINDINGS §6).
 */

module repeat_instr_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("repeat_instr_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("repeat_instr_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("repeat_instr_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("repeat_instr_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	// 2^(4+4)=256-cycle window = 128 retires at CPI=2: long uninterrupted
	// runs (real compression win) while still landing 2-3 periodic syncs
	// ON the loop branch across 400 iterations (exercises TCODE 32).
	localparam logic [3:0] INST_SYNC_MAX       = 4'd4;

	localparam logic [31:0] MAIN_PC = 32'h0000_4000;
	localparam int          N_LOOP  = 400;
	localparam int          N_PRE   = 4;  // linear instrs before the loop

	initial begin
		logic [31:0] loop_pc;
		$display("[repeat_instr_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[repeat_instr_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		// NOTE: $test$plusargs does PREFIX matching -- leg selectors must
		// not be prefixes of each other (first run used RPTI/RPTI_RH and
		// the RH leg silently enabled RepeatInstr too).
		if ($test$plusargs("RPTI")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatInstr(1'b1);
			$display("[repeat_instr_tb] %0t: InstEnRepeatInstr=1 (ON leg)", $time);
		end
		if ($test$plusargs("RHLEG")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory(1'b1);
			$display("[repeat_instr_tb] %0t: InstEnRepeatedHistory=1 (RH contrast leg)", $time);
		end
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(N_PRE * 4);
		loop_pc = MAIN_PC + N_PRE * 4;
		$display("[repeat_instr_tb] %0t: spin loop at 0x%08h, %0d iterations", $time, loop_pc, N_LOOP);

		// Single-instruction spin loop: taken branch targeting itself.
		for (int i = 0; i < N_LOOP; i++)
			env.cpu.branch_taken(.target(loop_pc));
		// Loop exit: the same branch falls through (not taken).
		env.cpu.branch_not_taken();
		env.cpu.run(16);
		env.cpu.exit_trace();

		// ---- Trace-off drain (cpu.idle -- see header note) ----
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(2000);

		if (env.cpu.event_count() == 0)
			$error("[repeat_instr_tb] cpu_model event log empty");
		else
			$display("[repeat_instr_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[repeat_instr_tb] no ATB bytes observed");
		else
			$display("[repeat_instr_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[repeat_instr_tb] PASS (sim); decode verified by scripts/cli_rpti_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[repeat_instr_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : repeat_instr_tb

`default_nettype wire
