// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab

/**
 * @file    ct_L23_preproc_perfcnt_tb.sv
 * @brief   Directed counter testbench for ct_L23_preproc_perfcnt.
 * @description Validates read-range performance counting and axis clear
 *   behavior for the preprocessor performance counter block.
 * @environment Drives tip traffic and perfcnt clear signals on a single tip
 *   clock after configuring one DATA_RD address range through cs_tip.
 * @stimulus Generates ten matching LOAD accesses interleaved with retired
 *   instructions, then asserts the clear controls.
 * @checking Asserts that the read counter reaches ten before clear and
 *   returns to zero afterward.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_perfcnt_tb;

	import tt::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import ct_perfcnt_pkg::*;
	import ct_pkg::*;

	localparam delay_t   	EXTRA_DELAY = 2;
	localparam int          DELAY_CYCLES = 0;

	localparam TIP_CLK_PERIOD    = 1.0;

	logic tip_rst;
	tip_t tipt;
	logic start_evaluation;

	logic tip_clk = 0; always #(TIP_CLK_PERIOD/2.0)  tip_clk   = ~tip_clk;

	tip_if          				tip    ();
	ct_cs_tipclk_if 				cs_tip ();
	ct_perfcnt_if					perfcnt();
	uwire[7:0]          			internal_delay;
	tip_data_t						data;

	// Parameters for DUT
	localparam type T = logic [31:0];

	ct_L23_preproc_perfcnt #(
		.IADDR_RANGES (2),
		.DADDR_RANGES (2)
	) dut (
		.clk (tip_clk),
		.rst (tip_rst),
		.tip,
		.cs_tip,
		.perfcnt,
		.internal_delay
	);

	initial begin

		tip_rst         <= '1;

		perfcnt.data_rd_counter_clr_etip 	<= '0;
		perfcnt.data_wr_counter_clr_etip 	<= '0;
		perfcnt.data_rd_th_counter_clr_etip <= '0;
		perfcnt.ifetch_th_counter_clr_etip 	<= '0;

		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 2);

		tip_rst         <= '0;
		PerfCntInit(cs_tip);
		PerfCntSetRange(cs_tip,DATA_RD, 0, 2, 8);

		@(posedge tip_clk);
		perfcnt.data_rd_counter_clr_axis 	<= '1;
		perfcnt.data_wr_counter_clr_axis 	<= '1;
		perfcnt.data_rd_th_counter_clr_axis	<= '1;
		perfcnt.ifetch_th_counter_clr_axis 	<= '1;

		@(posedge tip_clk);
		perfcnt.data_rd_counter_clr_axis 	<= '0;
		perfcnt.data_wr_counter_clr_axis 	<= '0;
		perfcnt.data_rd_th_counter_clr_axis	<= '0;
		perfcnt.ifetch_th_counter_clr_axis 	<= '0;

		for (int i = 0 ; i < 10; i++) begin
			TipTSetDefault(tipt);
			tipt.dtype 		= LOAD;
			tipt.daddr		= 5;
			tipt.data		= 32'h0123_0000 + i;
			tipt.dsize		= 2;
			tipt.dretire	= '1;
			TipSendMsg (tip, tip_clk, tipt, DELAY_CYCLES);

			TipTSetDefault(tipt);
			tipt.itype		= OTHER;
			tipt.iaddr		= 100;
			tipt.iretire	= '1;
			TipSendMsg (tip, tip_clk, tipt, DELAY_CYCLES);
		end

		// readout and clear
		repeat (2) @(posedge tip_clk);
		perfcnt.data_rd_counter_clr_axis[0] <= '1;
		@(posedge tip_clk);
		void'(tt_assert(perfcnt.data_rd_counter_value == 10, $sformatf("%0.2f: Line %0d / Test 0 *** data_rd_counter_value[0] is: %0h, expected: 10", $realtime, `__LINE__, perfcnt.data_rd_counter_value)));

		perfcnt.data_rd_counter_clr_axis[0] <= '0;
		repeat (2) @(posedge tip_clk);
		void'(tt_assert(perfcnt.data_rd_counter_value == 0, $sformatf("%0.2f: Line %0d / Test 1 *** data_rd_counter_value[0] is: %0h, expected: 0", $realtime, `__LINE__, perfcnt.data_rd_counter_value)));

		repeat (20) @(posedge tip_clk);

		tt_evaluate();
		$finish();
	end

endmodule
