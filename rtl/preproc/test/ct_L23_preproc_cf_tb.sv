// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_L23_preproc_cf_tb.sv
 * @brief   Directed control-flow qualifier testbench for ct_L23_preproc_cf.
 * @details Validates CF qualification by combining delayed TIP traffic,
 *   component-filter outputs, and programmable address-based match conditions.
 * @environment Integrates ct_L23_preproc_tip_delay,
 *   ct_L23_preproc_comp_filters, and ct_L23_preproc_cf on tip_clk with
 *   cs_tip configuration access.
 * @stimulus Programs comparator filters, then sends a queue of retired
 *   instruction addresses spanning miss cases, direct matches, and in-range
 *   matches.
 * @checking Compares cf_qualifier.hit against the expected queue after
 *   pipeline alignment.
 * @scoring Queue-based injection and scoreboarding keep CF qualifier checks
 *   aligned until all directed vectors have been consumed.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 *
 */



module ct_L23_preproc_cf_tb;

	import math::*;
	import tt::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import ct_pkg::*;
	import ct_comp_filters_pkg::*;

	localparam      NUM_TESTS         = 30;
	localparam int  DELAY_CYCLES      = 0;
	localparam      TIP_CLK_PERIOD    = 1.0;
	localparam      EXTRA_DELAY_MAX   = 20;
	localparam      RANGE_LOW         = 32'h1000;
	localparam      RANGE_HIGH        = 32'h1100;
	localparam      MATCH_ADDRESS     = 32'h1180;

	logic tip_rst;
	tip_t tipt;
	logic wb_rst;

	// Compute delays
	delay_t     idelay_tip_delay;
	delay_t     idelay_comp_filters;
	delay_t     idelay_cf;
	delay_t     extra_delay_comp_filters;
	delay_t     extra_delay_cf_range;
	delay_t     extra_delay_cf;
	delay_t     extra_delay_tip_delay_composer;
	delay_t     extra_delay_tip_delay_cfdf;
	delay_t     idelay_arr[];
	delay_t     max_delay;

	always_comb begin
		idelay_arr =  { idelay_tip_delay,
						idelay_comp_filters};

		max_delay = array_math#(delay_t)::max_array(idelay_arr);

		extra_delay_cf                  = '0;
		extra_delay_comp_filters        = max_delay - idelay_comp_filters;
		extra_delay_tip_delay_cfdf      = max_delay - idelay_tip_delay;
		extra_delay_tip_delay_composer  = extra_delay_tip_delay_cfdf + idelay_cf;
	end

	m1_kr_t     kr;

	// Control flags
	logic FeedingDone  = 0;
	logic CheckingDone = 0;

	tip_if              tip();
	tip_if              tip_delayed_composer();
	tip_if              tip_delayed_cfdf();
	ct_cs_tipclk_if     cs_tip();
	ct_hit_if           cf_filter();
	ct_hit_if           df_filter();
	ct_hit_if           cf_qualifier();

	logic tip_clk = 0; always #(TIP_CLK_PERIOD/2.0)  tip_clk   = ~tip_clk;

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

	ct_L23_preproc_cf #(
		.EXTRA_DELAY_MAX            (EXTRA_DELAY_MAX))
	cf_inst (
		.clk                        (tip_clk),
		.rst                        (tip_rst),
		.tip                        (tip_delayed_cfdf),
		.cf_filter,
		.cf_qualifier,
		.cs_tip,
		.internal_delay             (idelay_cf),
		.extra_delay                (extra_delay_cf)
	);

	//========================================================================
	// CONFIGURATION TASK
	//========================================================================

	task automatic configure_dut();

		CompFilterInit(cs_tip);

		// Configure comparator 0: P, Mode 0, EQUAL, iaddr=MATCH_ADDRESS
		// Assign comparator 0 to filter 0
		CompSetIaddr    (cs_tip, 0, MATCH_ADDRESS);
		FilterSetInstComp   (cs_tip, 0, 0, 0);  // Filter 0: trTeFilterComp1 = 0

		// Configure comparator 1: Mode 3, Primary: iaddr=RANGE_LOW, Secondary: iaddr=RANGE_HIGH
		// Assign comparator 1 to filter 1
		CompSetMode3    (cs_tip, 1, RANGE_LOW, RANGE_HIGH);
		FilterSetInstComp   (cs_tip, 1, 0, 1);  // Filter 1: trTeFilterComp1 = 1

		cs_tip.trTeInstTracingSet   = 0;
		cs_tip.trTeInstTracingSet   = 0;
		cs_tip.trTeInstTracing      = 1;

	endtask

	//========================================================================
	// Task: Generate tests
	//========================================================================

	// Test queue structures
	typedef struct {
		tip_t               tip;
		logic               hit;
		int                 test_id;    // Test number
	} test_queue_item_t;

	test_queue_item_t    input_queue[$];    // Input test queue
	test_queue_item_t    expected_queue[$]; // Expected results queue

	task automatic generate_tests();

		test_queue_item_t test_queue_item;
		int test_id;
		test_id = 0;

		TipTSetDefault(tipt);

		input_queue.delete();
		expected_queue.delete();

		// Step 1: Test of ct_L23_preproc_comp_filters

		for(int i = 0; i < NUM_TESTS; i++) begin
			tipt.iaddr                              = 32'h0F00 + (test_id * 32'h40);
			tipt.iretire                            = '1;
			test_queue_item.tip                     = tipt;
			test_queue_item.hit                     = (tipt.iaddr == MATCH_ADDRESS);
			test_queue_item.hit                    |= (tipt.iaddr >= RANGE_LOW) && (tipt.iaddr <= RANGE_HIGH);
			test_queue_item.test_id                 = test_id++;

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

		while(expected_queue.size() > 0) begin
			if (cf_qualifier.hit_valid) begin
				expected = expected_queue.pop_front();
				void'(tt_assert(cf_qualifier.hit == expected.hit , $sformatf("%0.2f: Line %0d / Test %0d: unexpected dut.hit: %0d (expected: %0d)", $realtime, `__LINE__, expected.test_id, cf_qualifier.hit, expected.hit)));
			end
			@(posedge tip_clk);
		end

		CheckingDone <= 1'h1;
		@(posedge tip_clk);

	endtask

	//========================================================================
	// Main
	//========================================================================
	initial begin

		configure_dut();


		// Initialize
		tip_rst         <= '1;
		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst         <= '0;

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
