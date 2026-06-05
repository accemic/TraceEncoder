// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab
`default_nettype none

/**
 * @file    ct_L23_preproc_df_tb.sv
 * @brief   Directed data-filter integration testbench for ct_L23_preproc_df.
 * @description Verifies data-filter qualification after aligning tip delay,
 *   data-range lookup, and component-filter paths.
 * @environment Integrates ct_L23_preproc_tip_delay,
 *   ct_L23_preproc_df_range, ct_L23_preproc_comp_filters, and
 *   ct_L23_preproc_df across tip_clk and wb_clk.
 * @stimulus Programs data ranges, enables data tracing, and sends a queue of
 *   retired data accesses that covers hit and miss cases.
 * @checking Compares df_qualifier.hit against a queue of expected results
 *   after the aligned pipeline delay.
 * @scoring Queue-based feed and check tasks keep the integrated DF pipeline
 *   aligned until all expected accesses have been observed.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */


module ct_L23_preproc_df_tb;

	import math::*;
	import tt::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_comp_filters_pkg::*;

	localparam int  DELAY_CYCLES      = 0;
	localparam      TIP_CLK_PERIOD    = 1.0;
	localparam      WB_CLK_PERIOD     = 3.0;
	localparam      EXTRA_DELAY_MAX   = 20;
	localparam int  CHECK_TIMEOUT_CYCLES = 500;

	logic tip_rst;
	tip_t tipt;
	logic wb_rst;

	ct_hit_if           cf_filter();
	ct_hit_if           df_range();
	ct_hit_if           df_filter();
	ct_hit_if           df_qualifier();

	// Compute delays
	delay_t     idelay_tip_delay;                   //  1
	delay_t     idelay_comp_filters;                //  1
	delay_t     idelay_df_range;                    // 18
	delay_t     idelay_df;                          //  1
	delay_t     extra_delay_comp_filters;
	delay_t     extra_delay_df_range;
	delay_t     extra_delay_df;
	delay_t     extra_delay_tip_delay_composer;
	delay_t     extra_delay_tip_delay_cfdf;
	delay_t     idelay_arr[];
	delay_t     max_delay;

	always_comb begin
		idelay_arr =  { idelay_tip_delay,
						idelay_df_range,
						idelay_comp_filters};

		max_delay = array_math#(delay_t)::max_array(idelay_arr);    // 18

		extra_delay_comp_filters        = max_delay - idelay_comp_filters;          // 17
		extra_delay_df_range            = max_delay - idelay_df_range;              //  0
		extra_delay_tip_delay_cfdf      = max_delay - idelay_tip_delay;             // 17
		extra_delay_tip_delay_composer  = extra_delay_tip_delay_cfdf + idelay_df;   // 18
		extra_delay_df                  = '0;
	end

	m1_kr_t     kr;

	// Control flags
	logic FeedingDone  = 0;
	logic CheckingDone = 0;
	int   SeenResults  = 0;
	logic tip_clk = 0;
	logic wb_clk  = 0;

	tip_if                                      tip();
	tip_if                                      tip_delayed_composer();
	tip_if                                      tip_delayed_cfdf();
	ct_cs_tipclk_if                             cs_tip();
	ocram_write_if #(.A_BITS(M1_STAGES), .T(m1_kr_t)) wext (.clk(wb_clk));

	always #(TIP_CLK_PERIOD/2.0)  tip_clk = ~tip_clk;
	always #(WB_CLK_PERIOD/2.0)   wb_clk  = ~wb_clk;

	ct_L23_preproc_tip_delay #(
		.EXTRA_DELAY_MAX            (EXTRA_DELAY_MAX))
	tip_delay_inst (
		.clk                        (tip_clk),
		.rst                        (tip_rst),
		.tip,
		.tip_delayed0               (tip_delayed_composer),
		.tip_delayed1               (tip_delayed_cfdf),
		.internal_delay             (idelay_tip_delay),
		.extra_delay0               (extra_delay_tip_delay_composer),
		.extra_delay1               (extra_delay_tip_delay_cfdf)
	);

	ct_L23_preproc_df_range #(
		.DIM                        (M1_DIM),
		.EXTRA_DELAY_MAX            (EXTRA_DELAY_MAX))
	df_range_inst (
		.clk                        (tip_clk),
		.rst                        (tip_rst),
		.tip,
		.wext_clk                   (wb_clk),
		.wext,
		.df_range,
		.internal_delay             (idelay_df_range),
		.extra_delay                (extra_delay_df_range)
	);

	ct_L23_preproc_comp_filters #(
	.EXTRA_DELAY_MAX                (EXTRA_DELAY_MAX))
	comp_filters_inst (
		.clk                        (tip_clk),
		.rst                        (tip_rst),
		.tip,
		.cs_tip,
		.cf_filter,
		.df_filter,
		.internal_delay             (idelay_comp_filters),
		.extra_delay                (extra_delay_comp_filters)
	);

	ct_L23_preproc_df #(
		.EXTRA_DELAY_MAX            (EXTRA_DELAY_MAX))
	df_inst (
		.clk                        (tip_clk),
		.rst                        (tip_rst),
		.tip                        (tip_delayed_cfdf),
		.df_filter,
		.df_range,
		.df_qualifier,
		.cs_tip,
		.internal_delay             (idelay_df),
		.extra_delay                (extra_delay_df)
	);

	//========================================================================
	// Task to configure dut memory
	//========================================================================
	task automatic WriteExt(int addr, m1_kr_t kr);
		wext.ce   <= 1;
		wext.we   <= 1;
		wext.addr <= addr;
		wext.d    <= kr;
		@(posedge wb_clk);
	endtask

	//========================================================================
	// CONFIGURATION TASK
	//========================================================================

	task automatic configure_dut();

		// Initialize CompFilter (always FALSE)
		CompFilterInit (cs_tip);
		CompSetInactive(cs_tip, 0);             // comp 0 output FALSE
		FilterSetDataComp  (cs_tip, 0, 0, 0);   // Filter 0: trTeFilterComp1 = 0

		// enable CompFilter for data tracing
		cs_tip.trTeDataTracingSet 	= 1;
		cs_tip.trTeDataTracingClr 	= 0;
		cs_tip.trTeDataTracing      = 1;

		// Initialize df_range

		// Configure ranges
		// Configure ascending ranges / values
		// DUT0 Range	DUT1 Value	DUT0 Result
		// 08..09		08			0000
		// 0A..0B		0A			0101
		// 0C..0D		0C			0202
		// 0E..0F		0E			0303
		// 10..11		10			0404
		// 12..13		12			0505
		// 14..15		14			0606
		// 16..17		16			0707
		// 18..19		18			0808
		// 1A..1B		1A			0909
		// 1C..1D		1C			0A0A
		// 1E..1F		1E			0B0B
		// 20..21		20			0C0C
		// 22..23		22			0D0D
		// 24..25		24			0E0E
		for (int i = 0; i < M1_N; i++) begin
			kr.key[0]	= 8+(2*i);
			kr.key[1]	= 8+(2*i)+1;
			WriteExt(i, m1_kr_t'(kr));
		end

		wext.ce   <= '0;
		wext.we   <= '0;
		wext.addr <= '0;
		wext.d    <= '0;
		@(posedge wb_clk);

	endtask

	//========================================================================
	// Task: Generate tests
	//========================================================================
	typedef struct {
		tip_t               tip;
		logic               hit;
		int                 test_id;    // Test number
	} test_queue_item_t;

	test_queue_item_t    input_queue[$];    // Input test queue
	test_queue_item_t    expected_queue[$]; // Expected results queue

	localparam int TESTS = 12; // 14;
								//          0         1         2         3         4         5         6         7         8         9        10        11
	M1_K    key         [TESTS] = '{   32'h03,   32'h05,   32'h07,   32'h08,   32'h0B,   32'h0A,   32'h0F,   32'h01,   32'h14,   32'h16,   32'h09,   32'h1E}; //,  32'h1040,  32'h1050 };
	logic   exp_hit 	[TESTS] = '{        0,        0,        0,        1,        1,        1,        1,        0,        1,        1,        1,        1}; //,         0,         1 };

	task automatic generate_tests();

		test_queue_item_t test_queue_item;
		int     test_id = 0;
		TipTSetDefault(tipt);

		input_queue.delete();
		expected_queue.delete();

		for(int i = 0; i < TESTS; i++) begin
			tipt.dretire                = '1;
			tipt.daddr                  = tip_daddr_t'(key[i]);
			test_queue_item.tip         = tipt;
			test_queue_item.hit         = exp_hit[i];
			test_queue_item.test_id     = test_id++;

			input_queue.push_back(test_queue_item);
			expected_queue.push_back(test_queue_item);
		end
	endtask

	//========================================================================
	// Task: Feed pipeline continuously (Queue-based)
	//========================================================================
	task automatic feed_pipeline();

		while(input_queue.size() > 0) begin
			test_queue_item_t item = input_queue.pop_front();
			TipSendMsg (tip, tip_clk, item.tip, 0);
		end

		FeedingDone <= '1;
		@(posedge tip_clk);
	endtask

	//========================================================================
	// Task: Check results
	//========================================================================
	task automatic check_results();
		test_queue_item_t expected;
		int timeout_cycles = 0;

		while((expected_queue.size() > 0) && (timeout_cycles < CHECK_TIMEOUT_CYCLES)) begin
			if (df_qualifier.hit_valid) begin
				expected = expected_queue.pop_front();
				SeenResults++;
				void'(tt_assert(df_qualifier.hit == expected.hit , $sformatf("%0.2f: Line %0d / Test %0d: unexpected dut.hit: %0d (expected: %0d)", $realtime, `__LINE__, expected.test_id, df_qualifier.hit, expected.hit)));
				timeout_cycles = 0;
			end
			else begin
				timeout_cycles++;
			end
			@(posedge tip_clk);
		end

		void'(tt_assert(expected_queue.size() == 0,
			$sformatf("%0.2f: DF TB timed out waiting for results: seen=%0d remaining=%0d",
				$realtime, SeenResults, expected_queue.size())));

		CheckingDone <= 1'h1;
		@(posedge tip_clk);

	endtask


	//========================================================================
	// Main
	//========================================================================

	initial begin

		// Initialize
		wext.ce         <= '0;
		wext.we         <= '0;
		tip_rst         <= '1;
		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);
		@(posedge wb_clk);
		tip_rst         <= '0;
		@(posedge tip_clk);
		configure_dut();
		@(posedge tip_clk);

		generate_tests();
		fork
			feed_pipeline();     // Continuously feed tests
			check_results();     // Continuously collect and check results
		join

		// Wait for completion
		wait(FeedingDone && CheckingDone);

		repeat (10) @(posedge tip_clk);

		tt_evaluate();
		$finish();

	end

endmodule
`default_nettype wire
