// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @file    ct_L23_preproc_df_range_tb.sv
 * @brief   Directed data-address range lookup testbench for ct_L23_preproc_df_range.
 * @details Programs the external range table and verifies hit generation
 *   for addresses inside and outside the configured data ranges.
 * @environment Uses wb_clk to fill the M1 range memory and tip_clk to drive
 *   retired data accesses into the DUT.
 * @stimulus Feeds a mixed queue of data addresses that covers misses, lower
 *   and upper bound hits, and interior hits across the programmed ranges.
 * @checking Compares df_range.hit against an expected hit queue whenever
 *   df_range.hit_valid asserts.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */
`default_nettype none


module ct_L23_preproc_df_range_tb;

	import tt::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	localparam      NUM_TESTS         = 10;
	localparam int  DELAY_CYCLES      = 0;
	localparam      TIP_CLK_PERIOD    = 1.0;
	localparam      WB_CLK_PERIOD     = 3.0;

	logic tip_rst;
	tip_t tipt;
	logic wb_rst;

	delay_t dut_delay, extra_delay;

	// Control flags
	logic FeedingDone  = 0;
	logic CheckingDone = 0;

	typedef tip_daddr_t K;

	m1_kr_t     kr;

	tip_if                                              tip();
	ocram_write_if #(.A_BITS(M1_STAGES), .T(m1_kr_t))   wext   (.clk(wb_clk));
	ct_hit_if                                           df_range();

	// Clock and reset
	logic tip_clk = 0, wb_clk = 0, rst = 0, valid = 0;
	always #(TIP_CLK_PERIOD/2.0) tip_clk = ~tip_clk;
	always #(WB_CLK_PERIOD/2.0)  wb_clk  = ~wb_clk;

	// Search input, hit, and control
	logic hit, hit_valid;
	delay_t internal_delay;

	// DUT instantiation
	ct_L23_preproc_df_range #(
		.DIM            (M1_DIM),
		.EXTRA_DELAY_MAX(EXTRA_DELAY_MAX)
	) dut (
		.clk             (tip_clk),
		.rst,
		.tip,
		.wext_clk        (wb_clk),
		.wext,
		.df_range,
		.internal_delay  (internal_delay),
		.extra_delay     (delay_t'(0))
	);

	// Test queue structures
	typedef struct {
		tip_t               tip;
		logic               hit_valid;
		logic               hit;
		int                 test_id;    // Test number
	} test_queue_item_t;

	test_queue_item_t    input_queue[$];    // Input test queue
	test_queue_item_t    expected_queue[$]; // Expected results queue

	// Test values (Hit/Miss mixed)
	localparam int TESTS = 12;

	M1_K    key         [TESTS] = '{   32'h03,   32'h05,   32'h07,   32'h08,   32'h0B,   32'h0A,   32'h0F,   32'h01,   32'h14,  32'h16,    32'h09,   32'h1E };
	logic   exp_hit     [TESTS] = '{        0,        0,        0,        1,        1,        1,        1,        0,        1,       1,         1,        1 };

	// Task: Generate tests
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
			test_queue_item.hit_valid   = '1;
			test_queue_item.hit         = exp_hit[i];
			test_queue_item.test_id     = test_id++;

			input_queue.push_back(test_queue_item);
			expected_queue.push_back(test_queue_item);
		end
	endtask

	// Task: Feed pipeline continuously (Queue-based)
	task automatic feed_pipeline();

		while(input_queue.size() > 0) begin
			test_queue_item_t item = input_queue.pop_front();
			TipSendMsg (tip, tip_clk, item.tip, 0);
		end

		FeedingDone <= '1;
		@(posedge tip_clk);
	endtask

	task automatic check_results();
		test_queue_item_t expected;

		while(expected_queue.size() > 0) begin
			if (df_range.hit_valid) begin
				expected = expected_queue.pop_front();
				void'(tt_assert(df_range.hit == expected.hit , $sformatf("%0.2f: Line %0d / Test %0d: unexpected df_range.hit: %0d (expected: %0d)", $realtime, `__LINE__, expected.test_id, df_range.hit, expected.hit)));
			end
			@(posedge tip_clk);
		end

		CheckingDone <= 1'h1;
		@(posedge tip_clk);

	endtask

	// Task to configure dut memory
	task automatic WriteExt(int addr, m1_kr_t kr);
		wext.ce   <= 1;
		wext.we   <= 1;
		wext.addr <= addr;
		wext.d    <= kr;
		@(posedge wb_clk);
	endtask

	initial begin

		extra_delay = 0;
		wext.ce          <= '0;
		wext.we          <= '0;
		wext.addr        <= '0;
		wext.d           <= '0;

		// Initialize
		tip_rst         <= '1;
		wb_rst          <= '1;
		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);
		@(posedge wb_clk);
		tip_rst         <= '0;
		wb_rst          <= '0;

		// Configure ranges
		// Configure ascending ranges / values
		// DUT0 Range   DUT1 Value  DUT0 Result
		// 08..09       08          0000
		// 0A..0B       0A          0101
		// 0C..0D       0C          0202
		// 0E..0F       0E          0303
		// 10..11       10          0404
		// 12..13       12          0505
		// 14..15       14          0606
		// 16..17       16          0707
		// 18..19       18          0808
		// 1A..1B       1A          0909
		// 1C..1D       1C          0A0A
		// 1E..1F       1E          0B0B
		// 20..21       20          0C0C
		// 22..23       22          0D0D
		// 24..25       24          0E0E
		for (int i = 0; i < M1_N; i++) begin
			kr.key[0]   = 8+(2*i);
			kr.key[1]   = 8+(2*i)+1;
			WriteExt(i, m1_kr_t'(kr));
		end

		wext.ce   <= '0;
		wext.we   <= '0;
		wext.addr <= '0;
		wext.d    <= '0;
		@(posedge wb_clk);

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
