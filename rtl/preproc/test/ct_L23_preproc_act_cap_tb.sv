// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_L23_preproc_act_cap_tb.sv
 * @brief   Directed command-detection testbench for ct_L23_preproc_act_cap.
 * @details Verifies that only matching ACT_CAP CSR transactions generate
 *   act_cap output after the configured pipeline delay.
 * @stimulus Sends one LOAD transaction that should miss and one
 *   CSR_READ_WRITE transaction that should emit the programmed ACT_CAP
 *   command.
 * @checking Asserts act_cap.valid suppression for the miss case and exact
 *   command reproduction for the hit case.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_act_cap_tb;

	import tt::*;
	import nexus_vendor::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import ct_pkg::*;

	localparam delay_t  EXTRA_DELAY = 2;
	localparam int      TIP_DELAY = 0;
	localparam          TIP_CLK_PERIOD = 1.0;

	logic           tip_rst;
	delay_t         dut_delay;
	delay_t         extra_delay;

	ct_cs_cpuif__trActCapStCmd__out_t cmd;

	logic tip_clk = 0; always #(TIP_CLK_PERIOD/2.0)  tip_clk   = ~tip_clk;

	// Instantiate interfaces
	tip_if          tip    ();
	ct_act_cap_if   act_cap();
	ct_cs_tipclk_if cs_tip ();

	// Instantiate DUT
	ct_L23_preproc_act_cap dut (
		.clk (tip_clk),
		.rst (tip_rst),
		.tip,
		.act_cap,
		.cs_tip,
		.internal_delay (dut_delay),
		.extra_delay    (EXTRA_DELAY)
	);

	tip_t tipt;    // struct with tip_if signals

	// Test sequences
	initial begin

		cmd.Cmd.value           = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
		cmd.Sink.value          = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
		cmd.DirectData.value    = 24'h12_3456;

		tip_rst <= 1;
		extra_delay <= 2;
		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst <= 0;
		repeat (4) @(posedge tip_clk);

		// Test 1: No match (LOAD) — should not assert HSI
		tipt.dtype = LOAD;
		tipt.daddr = ACT_CAP_CMD;
		tipt.data  = cmd_to_tip_data(cmd);
		tipt.dsize = 2;
		tipt.dretire = '1;
		TipSendMsg (tip, tip_clk, tipt, TIP_DELAY);
		repeat (EXTRA_DELAY) @(posedge tip_clk);
		void'(tt_assert(!act_cap.valid, $sformatf("%0.2f: Line %0d: Test failed: valid asserted on no match",$realtime, `__LINE__)));
		repeat (4) @(posedge tip_clk);

		// Test 2: Set HSI command
		tipt.dtype = CSR_READ_WRITE;
		TipSendMsg (tip, tip_clk, tipt, TIP_DELAY);
		repeat (EXTRA_DELAY) @(posedge tip_clk);
		void'(tt_assert(act_cap.valid,      $sformatf("%0.2f: Line %0d: Test failed: unexpected not valid",$realtime, `__LINE__)));
		void'(tt_assert(act_cap.cmd == cmd, $sformatf("%0.2f: Line %0d: Test failed: data do not match",   $realtime, `__LINE__)));
		repeat (4) @(posedge tip_clk);

		tt_evaluate();
		$finish();
	end

endmodule
