// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Split data-access leg: elaborates the chain with
 *           SPLIT_DATA_ACCESS=1.
 *
 * @details
 *   SPLIT_DATA_ACCESS is an elaboration parameter that defaults to 0, so
 *   without this testbench the split arms in composer_etip and df are dead at
 *   elaboration time.
 *
 *   With it set, STOREs emit their DF at dretire (as in combined mode) while
 *   LOADs capture the filter hit at dretire and only emit at lresp, using
 *   tip.ldata together with the remembered daddr/dsize. cpu_model has no
 *   split-response path, so this testbench drives tip.lresp hierarchically
 *   (lresp[1]=1 meaning OK) one cycle after the load's dretire.
 *
 *   Pass criterion (P3 step 4 retrofit, D-P3-9 -- this TB previously had
 *   no round-trip gate at all): a clean run plus
 *     scripts/decode_and_check.sh --pc --data split_load_tb
 *   The --data oracle encodes the split-load contract: the pending slot
 *   holds ONE load, so the 0x8000_0300 load (overwritten by 0x8000_0304
 *   before its lresp) never reaches the wire -- the TB marks it with
 *   mark_last_event_data_untraced(). Emission order equals access order
 *   here because every other load's lresp arrives before the next data
 *   access. NOT gated with --ctxp: the MEM record VALUES of split loads
 *   come from the TB-driven lresp data, which cpu_model cannot see, and
 *   with instruction+data tracing both on the strict CTXP line diff does
 *   not apply anyway (see the sim-combined note in the Makefile).
 */

module split_load_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (1),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("split_load_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("split_load_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("split_load_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("split_load_tb.expected.pcs"),
		.EXPECTED_DATA_PATH  ("split_load_tb.expected.data")
	) env ();

	localparam logic [31:0] MAIN_PC = 32'h0000_2000;

	// Drive one OK lresp (value 2) for a single cycle. cpu_model has no
	// split-response path; bit[1]=1 is the lresp_valid criterion in df and
	// the composer.
	task automatic pulse_lresp(input logic [31:0] ldata);
		@(negedge env.tip_clk);
		env.cpu.r_lresp = 2'd2;
		env.cpu.r_data  = ldata;
		@(posedge env.tip_clk);
		@(negedge env.tip_clk);
		env.cpu.r_lresp = '0;
	endtask

	initial begin
		$display("[split_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (4'd0);
		env.csr.Set_te_trTeControl_SendConfig   (2'd0);
		env.csr.Set_te_trTeDataControl_DataTracing  (1'b1);
		env.csr.Set_te_trTeDataControl_DataSplitLoad(1'b1);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[split_tb] %0t: scenario start", $time);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(16);

		// STORE path (directly at dretire, as in combined mode)
		env.cpu.store_data(.addr(32'h8000_0100), .size(2), .data(64'hAA55));
		env.cpu.run(16);

		// LOAD path: dretire (capture) -> lresp (emission)
		for (int i = 0; i < 4; i++) begin
			env.cpu.load_data(.addr(32'h8000_0200 + 32'h10 * i), .size(2));
			env.cpu.run(8);
			pulse_lresp(32'h1000_0000 + i);
			env.cpu.run(8);
		end

		// LOAD without an lresp until the next LOAD (pending-overwrite path).
		// This load never emits a data message (the next LOAD replaces it in
		// the single pending slot) -- exclude it from the data oracle.
		env.cpu.load_data(.addr(32'h8000_0300), .size(2));
		env.cpu.mark_last_event_data_untraced();
		env.cpu.run(8);
		env.cpu.load_data(.addr(32'h8000_0304), .size(2));
		env.cpu.run(8);
		pulse_lresp(32'h2000_0000);
		env.cpu.run(16);

		env.cpu.exit_trace();

		// ---- Trace-off drain ----
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
			$error("[split_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)
			$error("[split_tb] no ATB bytes observed");
		else
			$display("[split_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[split_tb] PASS (sim)");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[split_tb] TIMEOUT");
		$finish;
	end

endmodule : split_load_tb

`default_nettype wire
