// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_L23_preproc_comp_filters_tb.sv
 * @brief   Directed comparator and trap-window testbench for ct_L23_preproc_comp_filters.
 * @details Exercises comparator modes, latch behavior, exception-window
 *   tracking, interrupt and ecause matching, and data predicate filtering in
 *   isolation.
 * @environment Runs the standalone component-filter DUT on tip_clk with
 *   cs_tip configuration and observes both cf_filter and df_filter outputs.
 * @stimulus Queues directed vectors for mode-0 equality, mode-3 set/hold/
 *   clear behavior, nested exception entry and return, stack underflow,
 *   interrupt cases, and load/dsize predicates.
 * @checking Checks cf_filter and df_filter hit results against the expected
 *   queue whenever the DUT marks them valid.
 * @scoring Queue-based stimulus and scoreboarding keep comparator and
 *   trap-window cases aligned until all directed vectors are consumed.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 *
 */

`default_nettype none

// import math::*;
import tt::*;
import tip_pkg::*;
import tip_utils_pkg::*;
import ct_pkg::*;
import ct_cs_cpuif_pkg::*;
import ct_comp_filters_pkg::*;

module ct_L23_preproc_comp_filters_tb;

	localparam TIP_CLK_PERIOD   = 1.0;
	localparam EXTRA_DELAY_MAX  = 20;
	localparam NUM_TESTS        = 50;   // Comprehensive test suite

	//========================================================================
	// SIGNALS & CLOCKS
	//========================================================================

	logic tip_clk = 0;
	always #(TIP_CLK_PERIOD/2.0) tip_clk = ~tip_clk;

	logic tip_rst;
	tip_t tipt;

	ct_cs_tipclk_if cs_tip();

	// Control flags
	logic FeedingDone  = 0;
	logic CheckingDone = 0;

	tip_if tip();
	ct_hit_if cf_filter();
	ct_hit_if df_filter();

	delay_t idelay_comp_filters;
	delay_t extra_delay_comp_filters;

	//========================================================================
	// DUT INSTANTIATION
	//========================================================================

	ct_L23_preproc_comp_filters #(
		.EXTRA_DELAY_MAX(EXTRA_DELAY_MAX)
	) dut (
		.clk(tip_clk),
		.rst(tip_rst),
		.tip(tip),
		.cs_tip(cs_tip),
		.cf_filter(cf_filter),
		.df_filter(df_filter),
		.internal_delay(idelay_comp_filters),
		.extra_delay(extra_delay_comp_filters)
	);

	//========================================================================
	// TEST QUEUE STRUCTURES
	//========================================================================

	typedef struct {
		tip_t       tip;
		logic       cf_hit;
		logic       df_hit;
		string      desc;
		int         test_id;
	} test_queue_item_t;

	test_queue_item_t input_queue[$];
	test_queue_item_t expected_queue[$];

	//========================================================================
	// CONFIGURATION TASK
	//========================================================================

	task automatic configure_dut();

		CompFilterInit(cs_tip);

		// Configure comparator 0: P, Mode 0, EQUAL, iaddr=0x1000
		CompSetIaddr    (cs_tip, 0, 32'h1000);
		FilterSetInstComp   (cs_tip, 0, 0, 0);  // Filter 0: trTeFilterComp1 = 0

		// Configure comparator 1: Mode 3, Primary=iaddr>=0x2000, Secondary=iaddr>=0x2100
		// Assign comparator 1 to filter 1
		CompSetMode3    (cs_tip, 1, 32'h2000, 32'h2100);
		FilterSetInstComp   (cs_tip, 1, 0, 1);  // Filter 1: trTeFilterComp1 = 1

		// Configure filter 2: Exception cause matching
		FilterSetEcause(cs_tip, 2, ILLEGAL_INSTR);

		// Configure filter 3: Data filter (dtype + dsize)
		// NOTE: dsize encoding is log2(bytes). So dsize=4 => 16B.
		FilterSetDtype(cs_tip, 3, LOAD);
		FilterSetDsize(cs_tip, 3, 4);

		cs_tip.trTeDataTracingSet   = 0;
		cs_tip.trTeDataTracingClr   = 0;
		cs_tip.trTeDataTracing      = 1;

	endtask


	//========================================================================
	// TEST GENERATION TASK (Queue-based)
	//========================================================================

	task automatic generate_tests();
		test_queue_item_t   item;
		int                 test_id = 0;

		input_queue.delete();
		expected_queue.delete();

		TipTSetDefault(tipt);

		// ------------------------------------------------
		// 1. COMPARATOR MODE 0: Primary Result True
		// ------------------------------------------------
		item.tip            = tipt;
		item.tip.iaddr      = 32'h1000;
		item.tip.iretire    = 1;
		item.cf_hit         = 1;  // Assuming comp0 configured for iaddr=0x1000
		item.df_hit         = 0;
		item.desc           = "Mode 0: Primary=True";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// ------------------------------------------------
		// 2. COMPARATOR MODE 3: Latched (Set & Hold)
		// Primary=iaddr>=0x2000, Secondary=iaddr>=0x2100
		// ------------------------------------------------

		// 2a: Trigger latch with primary match
		item.tip            = tipt;
		item.tip.iaddr      = 32'h2000;  // Matches comp in mode 3
		item.tip.iretire    = 1;
		item.cf_hit         = 1;
		item.df_hit         = 0;
		item.desc           = "Mode 3: Latch SET on primary match";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// 2b: Hold latch (no match, but latch is set)
		item.tip            = tipt;
		item.tip.iaddr      = 32'h3000;  // Doesn't match anything
		item.tip.iretire    = 1;
		item.cf_hit         = 1;  // Latch keeps it active
		item.df_hit         = 0;
		item.desc           = "Mode 3: Latch HOLD";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// 2c: Clear latch on secondary match
		item.tip            = tipt;
		item.tip.iaddr      = 32'h2100;  // Triggers secondary in mode 3
		item.tip.iretire    = 1;
		item.cf_hit         = 1;  // This cycle still active (spec: "instruction after")
		item.df_hit         = 0;
		item.desc           = "Mode 3: Latch CLEAR on secondary";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// 2d: After clear
		item.tip            = tipt;
		item.tip.iaddr      = 32'h4000;
		item.tip.iretire    = 1;
		item.cf_hit         = 0;  // Latch cleared
		item.df_hit         = 0;
		item.desc           = "Mode 3: After CLEAR";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// ────────────────────────────────────────────────────────
		// 3. EXCEPTION/INTERRUPT STACK TESTS
		// ────────────────────────────────────────────────────────

		// 3a: Exception enter (push)
		// NOTE: With spec-style trapwindow implementation the counter becomes non-zero
		// *after* the trap has been observed. Therefore the filter hit typically starts
		// on the following retired instruction.
		item.tip            = tipt;
		item.tip.itype      = EXCEPTION_TRAP;
		item.tip.ecause     = ILLEGAL_INSTR;
		item.tip.iretire    = 1;
		item.cf_hit         = 0;
		item.df_hit         = 0;
		item.desc           = "Exception ENTER (ecause=2, match)";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// 3b: Inside exception window
		item.tip            = tipt;
		item.tip.itype      = OTHER;
		item.tip.iaddr      = 32'h8000;
		item.tip.iretire    = 1;
		item.cf_hit         = 1;  // Still in exception
		item.df_hit         = 0;
		item.desc           = "Exception WINDOW (normal instruction)";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// 3c: Exception return (pop)
		// NOTE: Window is still active on the return instruction itself, and ends after.
		item.tip            = tipt;
		item.tip.itype      = EXCEPTION_IR;
		item.tip.iretire    = 1;
		item.cf_hit         = 1;
		item.df_hit         = 0;
		item.desc           = "Exception RETURN (stack pop)";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// 3d: Nested exceptions
		item.tip            = tipt;
		item.tip.itype      = EXCEPTION_TRAP;
		item.tip.ecause     = ILLEGAL_INSTR;  // First nested
		item.tip.iretire    = 1;
		item.cf_hit         = 0;
		item.df_hit         = 0;
		item.desc           = "Nested Exception #1";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		item.tip            = tipt;
		item.tip.itype      = EXCEPTION_TRAP;
		item.tip.ecause     = LOAD_FAULT;  // Second nested (no match)
		item.tip.iretire    = 1;
		item.cf_hit         = 1;  // Still active (first exception matched)
		item.df_hit         = 0;
		item.desc           = "Nested Exception #2 (no match)";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// Return from second (no match)
		item.tip            = tipt;
		item.tip.itype      = EXCEPTION_IR;
		item.tip.iretire    = 1;
		item.cf_hit         = 1;  // First still active
		item.df_hit         = 0;
		item.desc           = "Return from nested (no match)";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// Return from first (match)
		item.tip            = tipt;
		item.tip.itype      = EXCEPTION_IR;
		item.tip.iretire    = 1;
		item.cf_hit         = 1;
		item.df_hit         = 0;
		item.desc           = "Return from nested (match)";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// ────────────────────────────────────────────────────────
		// 4. STACK UNDERFLOW TEST
		// ────────────────────────────────────────────────────────

		item.tip = tipt;
		item.tip.itype      = EXCEPTION_IR;  // Pop from empty stack
		item.tip.iretire    = 1;
		item.cf_hit         = 0;  // No hit (stack underflow, counter not affected)
		item.df_hit         = 0;
		item.desc           = "Stack UNDERFLOW (return without entry)";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// ────────────────────────────────────────────────────────
		// 5. INTERRUPT MATCHING
		// ────────────────────────────────────────────────────────

		item.tip            = tipt;
		item.tip.itype      = INTERRUPT;
		item.tip.iretire    = 1;
		item.cf_hit         = 0;  // Interrupt filter different from ecause
		item.df_hit         = 0;
		item.desc           = "Interrupt (if configured)";
		item.test_id        = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);

		// ────────────────────────────────────────────────────────
		// 6. PRIVILEGE / DTYPE / DSIZE PREDICATES
		// ────────────────────────────────────────────────────────

		item.tip            = tipt;
		item.tip.priv       = 0;  // USER
		item.tip.dtype      = LOAD;
		item.tip.dsize      = 4;
		item.tip.iretire    = 1;
		// This is a data filter only. Under spec-style AND semantics it must not
		// influence CF hit.
		item.cf_hit         = 0;
		item.df_hit         = 1;
		item.desc           = "Data Predicate: LOAD, 32-bit, USER";
		item.test_id = test_id++;
		input_queue.push_back(item);
		expected_queue.push_back(item);


	endtask

	//========================================================================
	// FEED TASK (Queue-based)
	//========================================================================

	task automatic feed_pipeline();
		test_queue_item_t item;

		while (input_queue.size() > 0) begin
			item = input_queue.pop_front();
			TipSendMsg(tip, tip_clk, item.tip, 0);
			// Optional: Print test desc
			// $display("[TB] Test %0d: %s", item.test_id, item.desc);
		end

		repeat (10) @(posedge tip_clk);

		FeedingDone <= '1;
		@(posedge tip_clk);

	endtask

	//========================================================================
	// CHECK TASK (Queue-based Scoreboarding)
	//========================================================================

	task automatic check_results();
		test_queue_item_t exp;

		CheckingDone <= 1'h1;
		@(posedge tip_clk);

		while (expected_queue.size() > 0) begin
			@(posedge tip_clk);

			if (cf_filter.hit_valid || df_filter.hit_valid) begin
				exp = expected_queue.pop_front();
			end

			if (cf_filter.hit_valid) begin
				void'(tt_assert(cf_filter.hit == exp.cf_hit , $sformatf("%0.2f: Line %0d / Test %0d (%s) unexpected cf_filter.hit: %0d (expected: %0d)",
					  $realtime, `__LINE__, exp.test_id, exp.desc, cf_filter.hit, exp.cf_hit)));
			end

			if (df_filter.hit_valid) begin
				void'(tt_assert(df_filter.hit == exp.df_hit , $sformatf("%0.2f: Line %0d / Test %0d (%s) unexpected df_filter.hit: %0d (expected: %0d)",
					  $realtime, `__LINE__, exp.test_id, exp.desc, df_filter.hit, exp.df_hit)));
			end
		end

		CheckingDone <= 1'h1;
		@(posedge tip_clk);

	endtask

	//========================================================================
	// MAIN TESTBENCH
	//========================================================================

	initial begin
		// Initialize
		tip_rst = 1;
		extra_delay_comp_filters = 0;

		// Configure DUT
		configure_dut();

		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);

		// Reset sequence
		repeat (5) @(posedge tip_clk);
		tip_rst = 0;
		repeat (5) @(posedge tip_clk);

		// Generate and run tests
		generate_tests();

		$display("\n====== STARTING ct_L23_preproc_comp_filters_tb ======");
		$display("Number of tests: %0d", input_queue.size());

		fork
			feed_pipeline();
			check_results();
		join

		// Wait for completion
		wait(FeedingDone && CheckingDone);

		repeat (10) @(posedge tip_clk);

		tt_evaluate();
		$finish();
	end

endmodule

`default_nettype wire
