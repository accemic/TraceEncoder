// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @file    ct_L23_preproc_df_split_tb.sv
 * @brief   Directed testbench for ct_L23_preproc_df in SPLIT_DATA_ACCESS=1 mode.
 *
 * @details
 *   Verifies split-load data trace qualification in the split-load path.
 *   In SPLIT_DATA_ACCESS mode, data trace events are split into two phases:
 *     - Address phase: dretire pulse carries daddr/dsize (LOAD or STORE)
 *     - Data phase:    lresp[1]=1 carries ldata (LOAD); sdata at dretire (STORE)
 *
 *   Test cases (with extra_delay=0):
 *     T1: STORE hit   — df_qualifier.hit fires 1 cycle after dretire (immediate)
 *     T2: STORE miss  — no hit
 *     T3: LOAD hit    — df_qualifier.hit fires 1 cycle after lresp (NOT after dretire)
 *     T4: LOAD miss   — no hit at lresp
 *     T5: Sequential LOADs — two back-to-back loads; hits arrive in order at respective lresps
 *     T6: lresp=3 (error) — bit[1]=1, should still trigger hit (error response is valid data)
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_df_split_tb;

	import tip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	localparam real CLK_PERIOD    = 10.0;
	localparam int  EXTRA_DELAY_MAX = 4;
	localparam int  EXTRA_DELAY     = 0;     // tap at HitPipe[0]

	// -----------------------------------------------------------------------
	// Clock / reset
	// -----------------------------------------------------------------------
	logic clk = 0, rst = 1;
	always #(CLK_PERIOD/2.0) clk = ~clk;

	// -----------------------------------------------------------------------
	// Interfaces
	// -----------------------------------------------------------------------
	tip_if          tip();
	ct_hit_if       df_filter();
	ct_hit_if       df_range();
	ct_hit_if       df_qualifier();
	ct_cs_tipclk_if cs_tip();

	delay_t         internal_delay;
	delay_t         extra_delay = EXTRA_DELAY;

	// -----------------------------------------------------------------------
	// DUT
	// -----------------------------------------------------------------------
	ct_L23_preproc_df #(
		.SPLIT_DATA_ACCESS(1),
		.EXTRA_DELAY_MAX(EXTRA_DELAY_MAX)
	) dut (
		.clk,
		.rst,
		.tip,
		.df_filter,
		.df_range,
		.df_qualifier,
		.cs_tip,
		// Unit TB: no mid-stream DataTracing edges, so the live level is
		// the aligned level (integration alignment lives in ct_L23_preproc).
		.data_trace_active_q(cs_tip.trTeDataTracing),
		.internal_delay,
		.extra_delay
	);

	// Tie off df_range (not used in these tests; df_filter drives hit directly)
	assign df_range.hit_valid = 0;
	assign df_range.hit       = 0;

	// -----------------------------------------------------------------------
	// Test result tracking
	// -----------------------------------------------------------------------
	int  pass_count = 0;
	int  fail_count = 0;

	task automatic chk(
		string desc,
		logic  got,
		logic  expected
	);
		if (got !== expected) begin
			$display("FAIL [%0t] %s: got=%0b expected=%0b", $realtime, desc, got, expected);
			fail_count++;
		end else begin
			$display("PASS [%0t] %s", $realtime, desc);
			pass_count++;
		end
	endtask

	// -----------------------------------------------------------------------
	// Helper: drive TIP bus to idle
	// -----------------------------------------------------------------------
	task automatic drive_idle();
		tip.itype     <= OTHER;
		tip.ecause    <= ECAUSE_NONE;
		tip.tval      <= '0;
		tip.priv      <= '0;
		tip.iaddr     <= '0;
		tip._context  <= '0;
		tip._time     <= '0;
		tip.ctype     <= UNREPORTED;
		tip.iretire   <= '0;
		tip.ilastsize <= '0;
		tip.impdef    <= '0;
		tip.dretire   <= '0;
		tip.dtype     <= LOAD;
		tip.daddr     <= '0;
		tip.dsize     <= '0;
		tip.data      <= '0;
		tip.sdata     <= '0;
		tip.lresp     <= '0;
		tip.ldata     <= '0;
		df_filter.hit_valid <= '0;
		df_filter.hit       <= '0;
	endtask

	// -----------------------------------------------------------------------
	// Helper: drive a STORE dretire for one cycle
	// -----------------------------------------------------------------------
	task automatic do_store(
		input tip_daddr_t  addr,
		input tip_dsize_t  dsize,
		input logic [31:0] sdata,
		input logic        filter_hit
	);
		@(posedge clk);
		tip.dretire          <= 1;
		tip.dtype            <= STORE;
		tip.daddr            <= addr;
		tip.dsize            <= dsize;
		tip.sdata            <= sdata;
		df_filter.hit_valid  <= 1;
		df_filter.hit        <= filter_hit;
		@(posedge clk);
		drive_idle();
	endtask

	// -----------------------------------------------------------------------
	// Helper: drive a LOAD address-phase dretire for one cycle
	// -----------------------------------------------------------------------
	task automatic do_load_addr(
		input tip_daddr_t  addr,
		input tip_dsize_t  dsize,
		input logic        filter_hit
	);
		@(posedge clk);
		tip.dretire          <= 1;
		tip.dtype            <= LOAD;
		tip.daddr            <= addr;
		tip.dsize            <= dsize;
		df_filter.hit_valid  <= 1;
		df_filter.hit        <= filter_hit;
		@(posedge clk);
		drive_idle();
	endtask

	// -----------------------------------------------------------------------
	// Helper: drive a LOAD data-phase (lresp) for one cycle
	// -----------------------------------------------------------------------
	task automatic do_load_resp(
		input logic [1:0]  lresp_val,   // 2'b10=OK, 2'b11=error
		input logic [31:0] ldata_val
	);
		@(posedge clk);
		tip.lresp <= lresp_val;
		tip.ldata <= ldata_val;
		@(posedge clk);
		tip.lresp <= '0;
		tip.ldata <= '0;
	endtask

	// -----------------------------------------------------------------------
	// Main stimulus
	// -----------------------------------------------------------------------
	initial begin

		drive_idle();
		cs_tip.trTeDataTracing    = 1;
		cs_tip.trTeDataTracingSet = 0;
		cs_tip.trTeDataTracingClr = 0;

		// Reset for 3 cycles
		repeat(3) @(posedge clk);
		rst <= 0;
		@(posedge clk);

		// ===================================================================
		// T1: STORE hit → hit fires 1 cycle after dretire
		// ===================================================================
		$display("--- T1: STORE hit ---");
		do_store(32'hA000_1000, 2, 32'hDEAD_BEEF, 1);
		// After do_store returns we are at posedge T+2, one cycle after dretire
		// HitPipe[0] was clocked at posedge T+1 with store_dretire=1, hit=1
		@(negedge clk);   // sample after posedge T+2
		chk("T1 STORE hit: hit=1",       df_qualifier.hit,       1'b1);
		chk("T1 STORE hit: hit_valid=1", df_qualifier.hit_valid, 1'b1);
		@(posedge clk);
		@(negedge clk);
		chk("T1 STORE hit: clears after one cycle", df_qualifier.hit, 1'b0);

		// ===================================================================
		// T2: STORE miss → no hit
		// ===================================================================
		$display("--- T2: STORE miss ---");
		do_store(32'hB000_0000, 1, 32'h1234_5678, 0);   // filter_hit=0
		@(negedge clk);
		chk("T2 STORE miss: hit=0", df_qualifier.hit, 1'b0);

		// ===================================================================
		// T3: LOAD hit with 6-cycle latency
		//     hit must NOT fire after dretire; MUST fire after lresp
		// ===================================================================
		$display("--- T3: LOAD hit (6-cycle latency) ---");
		do_load_addr(32'hC000_2000, 2, 1);   // address phase

		// One cycle after dretire: expect NO hit (pending load, not yet resolved)
		@(negedge clk);
		chk("T3 LOAD: no spurious hit at dretire+1 (hit)",       df_qualifier.hit,       1'b0);
		chk("T3 LOAD: no spurious hit at dretire+1 (hit_valid)", df_qualifier.hit_valid, 1'b0);

		// Wait 4 more idle cycles (total of 5 idle after addr-phase), then lresp
		repeat(4) @(posedge clk);
		do_load_resp(2'b10, 32'hCAFE_BABE);   // lresp=OK

		// One cycle after lresp: expect hit
		@(negedge clk);
		chk("T3 LOAD: hit fires at lresp+1 (hit)",       df_qualifier.hit,       1'b1);
		chk("T3 LOAD: hit fires at lresp+1 (hit_valid)", df_qualifier.hit_valid, 1'b1);
		@(posedge clk);
		@(negedge clk);
		chk("T3 LOAD: hit clears after lresp+1", df_qualifier.hit, 1'b0);

		// ===================================================================
		// T4: LOAD miss (filter reports no-hit) → no hit at lresp
		// ===================================================================
		$display("--- T4: LOAD miss ---");
		do_load_addr(32'hD000_FFFF, 2, 0);   // filter_hit=0

		repeat(5) @(posedge clk);
		do_load_resp(2'b10, 32'hBAAD_F00D);

		@(negedge clk);
		chk("T4 LOAD miss: no hit at lresp+1", df_qualifier.hit, 1'b0);
		@(posedge clk);

		// ===================================================================
		// T5: Sequential loads (A then B, non-overlapping lresps)
		//     A: addr=0xE000_0A00, lresp arrives at T+8 after A's dretire
		//     B: addr=0xE000_0B00, dretire at T+3, lresp at T+12 after A's dretire
		//     Both should produce hits in order.
		// ===================================================================
		$display("--- T5: Sequential loads ---");
		// Load A address phase
		do_load_addr(32'hE000_0A00, 2, 1);
		// 2 idle cycles before Load B
		repeat(2) @(posedge clk);
		// Load B address phase
		do_load_addr(32'hE000_0B00, 1, 1);
		// 3 idle cycles, then lresp for A
		repeat(3) @(posedge clk);
		do_load_resp(2'b10, 32'hAAAA_1111);   // lresp-A

		@(negedge clk);
		chk("T5 SeqLoad: hit for load A at lresp-A", df_qualifier.hit, 1'b1);
		@(posedge clk);
		// 3 idle cycles, then lresp for B
		repeat(3) @(posedge clk);
		do_load_resp(2'b10, 32'hBBBB_2222);   // lresp-B

		@(negedge clk);
		chk("T5 SeqLoad: hit for load B at lresp-B", df_qualifier.hit, 1'b1);
		@(posedge clk);

		// ===================================================================
		// T6: lresp=3 (error response, bit[1]=1) still produces hit
		// ===================================================================
		$display("--- T6: LOAD hit with lresp=error ---");
		do_load_addr(32'hF000_0000, 0, 1);

		repeat(4) @(posedge clk);
		do_load_resp(2'b11, 32'hFF_FFFF);   // lresp=3 (error, but bit[1]=1)

		@(negedge clk);
		chk("T6 LOAD error-resp: hit fires at lresp+1", df_qualifier.hit, 1'b1);
		@(posedge clk);

		// ===================================================================
		// Summary
		// ===================================================================
		repeat(5) @(posedge clk);
		$display("========================================");
		$display("ct_L23_preproc_df_split_tb: PASS=%0d  FAIL=%0d", pass_count, fail_count);
		$display("========================================");
		if (fail_count == 0)
			$display("ALL TESTS PASSED");
		else
			$error("SOME TESTS FAILED (%0d failures)", fail_count);
		$finish();
	end

	// Watchdog
	initial begin
		#1_000_000;
		$error("TIMEOUT — testbench took too long");
		$finish();
	end

endmodule // ct_L23_preproc_df_split_tb
`default_nettype wire
