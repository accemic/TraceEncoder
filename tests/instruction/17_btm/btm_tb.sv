// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Branch Trace Messaging mode (InstMode=3, TCODE 3/4) -- seq 24 BTM.
 *
 * @details
 *   One branch-rich workload, two CSR legs (identical cpu_model stimulus ->
 *   identical expected-PC reference):
 *
 *     htm : reset default InstMode=6 (HTM) -> Branch-History path (TCODE 28
 *           IBH + accumulated HIST); NO TCODE 3/4.
 *     btm : InstMode=3 (BTM) -> DirectBranch (TCODE 3, one per taken
 *           conditional branch) + IndirectBranch (TCODE 4, per indirect CF);
 *           NO IndirectBranchHist (28) / HIST.
 *
 *   Both legs must decode PC-lossless against the SAME cpu_model reference
 *   (scripts/cli_btm_test.sh). This proves both N-Trace 1.0 instruction-trace
 *   modes (Table 8 "3 OR 6 settable") are implemented and equivalent.
 *   Timestamps OFF, drain via env.cpu.idle().
 */

module btm_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("btm_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("btm_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("btm_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("btm_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd2; // 64-cycle window (a few periodic syncs)

	localparam logic [31:0] MAIN_PC = 32'h0000_7000;
	localparam logic [31:0] SUB_PC  = 32'h0000_7800;

	initial begin
		$display("[btm_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[btm_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		// SendConfig=CFG_NONE so the two legs' streams are pure PC content
		// (the config message is proven separately in test 16).
		env.csr.Set_te_trTeControl_SendConfig   (2'd0);
		if ($test$plusargs("BTMLEG")) begin
			env.csr.Set_te_trTeControl_InstMode (3'd3); // ITR_BRANCH (BTM)
			$display("[btm_tb] %0t: InstMode=3 (BTM)", $time);
		end
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[btm_tb] %0t: scenario start", $time);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(12);

		// Branch-rich body: mixed taken / not-taken conditional branches
		// (each TAKEN -> one DirectBranch in BTM), a direct call+return pair
		// (inferable call = silent, return = indirect -> IndirectBranch in
		// BTM), and an indirect jump.
		env.cpu.branch_taken(.target(MAIN_PC + 32'h040));
		env.cpu.run(8);
		env.cpu.branch_not_taken();
		env.cpu.run(8);
		env.cpu.branch_not_taken();
		env.cpu.run(8);
		env.cpu.branch_taken(.target(MAIN_PC + 32'h0C0));
		env.cpu.run(8);
		env.cpu.call_to(.target(SUB_PC)); // inferable direct call (silent in BTM)
		env.cpu.run(8);
		env.cpu.branch_taken(.target(SUB_PC + 32'h040));
		env.cpu.run(8);
		env.cpu.ret();   // return -> IndirectBranch (TCODE 4) in BTM
		env.cpu.run(8);
		env.cpu.branch_not_taken();
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(MAIN_PC + 32'h200)); // -> IndirectBranch (TCODE 4)
		env.cpu.run(60);   // longer linear stretch -> periodic sync lands here
		env.cpu.branch_taken(.target(MAIN_PC + 32'h280));
		env.cpu.run(8);

		env.cpu.branch_not_taken();
		env.cpu.run(8);
		env.cpu.exit_trace();

		// ---- Trace-off drain (cpu.idle -- wait_cycles XSIM anomaly) ----
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
			$error("[btm_tb] cpu_model event log empty");
		else
			$display("[btm_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[btm_tb] no ATB bytes observed");
		else
			$display("[btm_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[btm_tb] PASS (sim); decode verified by scripts/cli_btm_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[btm_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : btm_tb

`default_nettype wire
