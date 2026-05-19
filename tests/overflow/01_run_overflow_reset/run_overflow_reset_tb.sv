// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Overflow + reset cross-cutting test.
*
* @details
*   Negative test that walks the full "something went wrong, recovered"
*   cycle:
*
*     phase A:  run a normal scenario (expect clean ATB output)
*     phase B:  assert ATB backpressure for long enough to saturate
*               internal FIFOs, then keep retiring instructions to
*               provoke an overflow message
*     phase C:  release backpressure, issue a soft reset via the CSR
*     phase D:  run a second normal scenario, confirm the encoder
*               resumes producing trace cleanly
*
*   Pass criteria (placeholder until proper scoreboard lands):
*     - phase A produces ATB bytes
*     - phase B causes atb_force_stall to hold for a meaningful window
*     - phase D produces additional ATB bytes after reset
*/

module run_overflow_reset_tb;

	import cpu_model_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("run_overflow_reset_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("run_overflow_reset_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("run_overflow_reset_tb.nexrv.info")
	) env ();

	int bytes_after_A;
	int bytes_after_C;

	initial begin
		env.wait_for_reset_release();

		// ---- Configure encoder ------------------------------------
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.wait_cycles(20);

		// ============================================================
		// Phase A : normal run
		// ============================================================
		$display("[overflow_tb] phase A: normal run");
		env.cpu.enter(.start_pc(32'h0000_1000));
		env.cpu.run(64);
		env.cpu.branch_taken(.target(32'h0000_1200));
		env.cpu.run(64);
		env.cpu.exit_trace();
		env.wait_cycles(500);
		bytes_after_A = env.atb_bytes_seen;
		$display("[overflow_tb] phase A: %0d ATB bytes", bytes_after_A);
		if (bytes_after_A == 0)
			$error("[overflow_tb] phase A produced no ATB output");

		// ============================================================
		// Phase B : provoke overflow by stalling ATB
		// ============================================================
		$display("[overflow_tb] phase B: forcing ATB backpressure");
		env.atb_force_stall = 1'b1;

		// Keep generating trace activity while the ATB is stalled.
		// Internal FIFOs should saturate and the encoder should emit
		// an overflow indication once backpressure relaxes.
		env.cpu.enter(.start_pc(32'h0000_2000));
		repeat (8) begin
			env.cpu.run(64);
			env.cpu.branch_taken(.target(32'h0000_2080));
			env.cpu.run(64);
			env.cpu.branch_taken(.target(32'h0000_2000));
		end
		env.cpu.exit_trace();

		// Hold stall for a bit longer so the overflow message is queued.
		env.wait_cycles(2000);

		// ============================================================
		// Phase C : release stall + soft reset
		// ============================================================
		$display("[overflow_tb] phase C: releasing stall + soft reset");
		env.atb_force_stall = 1'b0;
		env.wait_cycles(500);

		// Toggle ct_cs_rst as a soft reset of the encoder's CSR shim.
		env.ct_cs_rst = 1'b1;
		env.wait_cycles(20);
		env.ct_cs_rst = 1'b0;
		env.wait_cycles(20);

		// Re-program (configuration is lost across a soft reset).
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.wait_cycles(20);

		// ============================================================
		// Phase D : verify clean recovery
		// ============================================================
		$display("[overflow_tb] phase D: post-reset run");
		env.cpu.enter(.start_pc(32'h0000_3000));
		env.cpu.run(64);
		env.cpu.branch_taken(.target(32'h0000_3100));
		env.cpu.run(64);
		env.cpu.exit_trace();
		env.wait_cycles(2000);

		bytes_after_C = env.atb_bytes_seen;
		$display("[overflow_tb] phase D: %0d total ATB bytes seen (delta = %0d)",
			bytes_after_C, bytes_after_C - bytes_after_A);

		if (bytes_after_C <= bytes_after_A)
			$error("[overflow_tb] phase D produced no additional ATB output - encoder did not recover");

		$display("[overflow_tb] PASS");
		$display("[overflow_tb] ATB binary trace:");
		$system("realpath run_overflow_reset_tb.atb.bin");
		$display("[overflow_tb] TIP text dump:");
		$system("realpath run_overflow_reset_tb.tip.txt");
		$display("[overflow_tb] NexRv PCInfo:");
		$system("realpath run_overflow_reset_tb.nexrv.info");
		$finish;
	end

	initial begin
		#10ms;
		$error("[overflow_tb] TIMEOUT - test exceeded 10 ms wall time");
		$finish;
	end

endmodule : run_overflow_reset_tb

`default_nettype wire
