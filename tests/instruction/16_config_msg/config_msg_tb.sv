// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Vendor config message TCODE 58 (C1/C2) + NexRv autoconfig E2E (C4).
 *
 * @details
 *   One workload (branch-rich so the BP legs exercise real prediction),
 *   five CSR legs -- identical cpu_model stimulus, identical expected PCs:
 *
 *     none  : SendConfig=CFG_NONE(0)      -> no TCODE 58 anywhere; stream is
 *             byte-class-identical to the pre-C2 form (off-neutrality).
 *     once  : reset default CFG_ONCE(1)   -> exactly ONE TCODE 58, and it is
 *             MSG #0 (before the first sync).
 *     onsync: SendConfig=CFG_ON_SYNC(2)   -> one TCODE 58 immediately BEFORE
 *             every synchronizing message (count 58 == count SYNC fields).
 *     bp    : +InstEnBranchPrediction, SendConfig=CFG_ONCE -> NexRv decodes
 *             WITHOUT -bp via autoconfig (ENAB.5); pcout must equal the
 *             explicitly flagged decode (C4 "flagless == flagged").
 *     bpneg : +InstEnBranchPrediction, SendConfig=CFG_NONE -> negative
 *             control: without the config message AND without -bp the decode
 *             must NOT reproduce the reference.
 *
 *   Gates in scripts/cli_cfg_test.sh (NexRv is the reference decoder).
 *   Timestamps stay at their reset default (on) -- the config message
 *   carries a delta TSTAMP like any non-sync message.
 */

module config_msg_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("config_msg_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("config_msg_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("config_msg_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("config_msg_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd1; // 32-cycle window -> many periodic syncs (as in tests 04/06)

	localparam logic [31:0] MAIN_PC = 32'h0000_6000;

	initial begin
		$display("[config_msg_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[config_msg_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		if ($test$plusargs("NONELEG")) begin
			env.csr.Set_te_trTeControl_SendConfig(2'd0);
			$display("[config_msg_tb] %0t: SendConfig=CFG_NONE", $time);
		end
		if ($test$plusargs("ONSYNCLEG")) begin
			env.csr.Set_te_trTeControl_SendConfig(2'd2);
			$display("[config_msg_tb] %0t: SendConfig=CFG_ON_SYNC", $time);
		end
		if ($test$plusargs("BPLEG")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			$display("[config_msg_tb] %0t: InstEnBranchPrediction=1 (SendConfig at reset CFG_ONCE)", $time);
		end
		if ($test$plusargs("BPNEGLEG")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			env.csr.Set_te_trTeControl_SendConfig(2'd0);
			$display("[config_msg_tb] %0t: InstEnBranchPrediction=1 + SendConfig=CFG_NONE (negative control)", $time);
		end
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[config_msg_tb] %0t: scenario start", $time);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(16);

		// Branch-rich body: 8 direct branches with mixed outcomes (real BP
		// work: the weakly-not-taken predictor mispredicts several of them).
		env.cpu.branch_taken(.target(MAIN_PC + 32'h080));
		env.cpu.run(12);
		env.cpu.branch_not_taken();
		env.cpu.run(12);
		env.cpu.branch_taken(.target(MAIN_PC + 32'h100));
		env.cpu.run(12);
		env.cpu.branch_taken(.target(MAIN_PC + 32'h180));
		env.cpu.run(12);
		env.cpu.branch_not_taken();
		env.cpu.run(40);
		env.cpu.branch_not_taken();
		env.cpu.run(12);
		env.cpu.branch_taken(.target(MAIN_PC + 32'h200));
		env.cpu.run(40);
		env.cpu.branch_taken(.target(MAIN_PC + 32'h280));
		env.cpu.run(120);   // long linear stretch -> periodic syncs land here

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
			$error("[config_msg_tb] cpu_model event log empty");
		else
			$display("[config_msg_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[config_msg_tb] no ATB bytes observed");
		else
			$display("[config_msg_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[config_msg_tb] PASS (sim); decode verified by scripts/cli_cfg_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[config_msg_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : config_msg_tb

`default_nettype wire
