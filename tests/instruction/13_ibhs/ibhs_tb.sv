// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    IBHS (TCODE 29): syncs carry pending HIST instead of pre-flushing (B2).
 *
 * @details
 *   Regression gate for CT_EN_IBHS / trTeInstFeatures.InstEnIbhs (seq 24 B2).
 *   Workload: a 2L+1BD loop with a short periodic-sync window (the test-04
 *   regime) so periodic syncs repeatedly fire with pending HIST bits.
 *
 *     OFF leg (reset default): historical two-message form -- every such
 *          sync is preceded by a ResourceFull(RCODE=1) HIST pre-flush
 *          (cf_sync_hist_flush_hold), NO TCODE 29 in the stream.
 *     ON leg (+IBHS): the sync itself carries the history as
 *          IndirectBranchHistorySync (TCODE 29) -- no pre-flush pair,
 *          fewer bytes on the wire.
 *
 *   Both legs must decode PC-lossless against the same cpu_model reference
 *   (checked by scripts/cli_ibhs_test.sh via NexRv; TCODE-29 walk = ICNT
 *   walked with HIST bits, then hard re-anchor at FADDR).
 *
 *   Deterministic; instruction trace ON (BRANCH_HIST), timestamps OFF,
 *   data OFF. Trace-off drain uses env.cpu.idle() (see the wait_cycles
 *   XSIM anomaly note in tests/instruction/12_debug_power_events).
 */

module ibhs_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("ibhs_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("ibhs_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("ibhs_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("ibhs_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd1;

	localparam logic [31:0] BODY_PC   = 32'h0000_3000;
	localparam logic [31:0] BRANCH_PC = BODY_PC + 32'd8;
	localparam int          N         = 60;

	initial begin
		$display("[ibhs_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[ibhs_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		if ($test$plusargs("IBHS")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnIbhs(1'b1);
			$display("[ibhs_tb] %0t: InstEnIbhs=1 (ON leg)", $time);
		end
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[ibhs_tb] %0t: driving %0d loop iters", $time, N);

		env.cpu.enter(.start_pc(BODY_PC));
		for (int i = 0; i < N; i++) begin
			env.cpu.run(.n_bytes(8));
			if (i < N - 1)
				env.cpu.branch_taken(.target(BODY_PC));
			else
				env.cpu.branch_not_taken();
		end
		env.cpu.run(8);
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
			$error("[ibhs_tb] cpu_model event log empty");
		else
			$display("[ibhs_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[ibhs_tb] no ATB bytes observed");
		else
			$display("[ibhs_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[ibhs_tb] PASS (sim); decode verified by scripts/cli_ibhs_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[ibhs_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : ibhs_tb

`default_nettype wire
