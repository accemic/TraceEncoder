// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_L23_preproc_axis_tb.sv
 * @brief   Directed AXIS output testbench for ct_L23_preproc.
 * @details Exercises the AXIS DAQ path by sending repeated ACT_CAP
 *   command writes into the preprocessor and checking the emitted AXIS
 *   payload.
 * @environment Instantiates the full preprocessor with tip, AXIS, ETIP, ATB,
 *   and write-side interfaces across tip, proc, wb, wall, and ATB clocks.
 * @stimulus Queues a fixed number of ACT_CAP_ST_DAQ_PC_CURR commands targeted
 *   at the AXIS sink.
 * @checking Waits for each AXIS transfer and asserts that the lower 32 data
 *   bits match the expected instruction address.
 * @scoring Input and expected result queues keep the AXIS smoke test aligned
 *   until all directed commands have been observed.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_axis_tb;

	import tt::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import ct_etip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import nexus_vendor::*;

	localparam     NUM_TESTS    = 10;
	localparam int DELAY_CYCLES = 2;
	localparam     TIP_CLK_PERIOD  = 2.0;
	localparam     PROC_CLK_PERIOD = 5.0;
	localparam     WALL_CLK_PERIOD = 30.0;
	localparam     ATB_CLK_PERIOD  = 2.5;
	localparam     WB_CLK_PERIOD   = 4.0;

	logic       tip_rst;
	logic       proc_rst;
	logic       atresetn;
	logic       wall_clk_rst;
	logic       synq_req_trace_byte_count;
	delay_t     dut_delay;

	// Control flags
	logic FeedingDone;
	logic CheckingDone;

	logic  tip_clk    = 0; always #(TIP_CLK_PERIOD /2.0)  tip_clk    = ~tip_clk;
	logic  proc_clk   = 0; always #(PROC_CLK_PERIOD/2.0)  proc_clk   = ~proc_clk;
	logic  atclk      = 0; always #(ATB_CLK_PERIOD /2.0)  atclk      = ~atclk;
	logic  wb_clk     = 0; always #(WB_CLK_PERIOD  /2.0)  wb_clk     = ~wb_clk;
	logic  wall_clk   = 0; always #(WALL_CLK_PERIOD/2.0)  wall_clk   = ~wall_clk;

	// Instantiate interfaces
	tip_if          tip();
	ct_cs_tipclk_if cs_tip();

	axis_if #(
		.TDATA_WIDTH(ACT_CAP_AXIS_TDATA_WIDTH),
		.TID_WIDTH  (ACT_CAP_AXIS_TID_WIDTH))
	axis (
		.aclk   ( tip_clk),
		.aresetn(!tip_rst));

	source_if #(
		.T(etip_msg_struct_t),
		.STOP_ON_UNDERRUN(0))
	etip_q  (
		.clk(proc_clk),
		.rst(proc_rst));

	assign etip_q.ack = etip_q.valid;

	source_if #(
		.T(tip_iaddr_t),
		.STOP_ON_UNDERRUN(0))
	next_iaddr_q  (
		.clk(proc_clk),
		.rst(proc_rst));

	assign next_iaddr_q.ack = next_iaddr_q.valid;

	ocram_write_if #(.A_BITS(M0_STAGES), .T(m0_kr_t)) act_st_wext (wb_clk);
	ocram_write_if #(.A_BITS(M1_STAGES), .T(m1_kr_t)) df_range_wext (wb_clk);

	// Instantiate DUT
	ct_L23_preproc dut (
		.tip_clk,
		.tip_rst,
		.wall_clk,
		.wall_clk_rst,
		.proc_clk,
		.proc_rst,
		.tip,
		.axis,
		.etip_q,
		.next_iaddr_q,
		.atb_afvalid (0), .atb_syncreq (0),
		.synq_req_trace_byte_count,
		.synq_req_trace_msg_count (1'b0),
		.quota_cnt_clr            (),
		.cs_tip,
		.wext_clk (wb_clk),
		.act_st_wext,
		.df_range_wext,
		.internal_delay(dut_delay)
	);

	tip_t   tipt;    // struct with tip_if signals

	// Test queue structures
	typedef struct {
		ct_cs_cpuif__trActCapStCmd__out_t    cmd;
		int                             test_id;       // Test number
	} test_queue_item_t;

	test_queue_item_t    input_queue[$];    // Input test queue
	test_queue_item_t    expected_queue[$]; // Expected results queue

	// Task: Generate tests
	task automatic generate_tests();

		test_queue_item_t   test_queue_item;
		int                 test_id;

		input_queue.delete();
		expected_queue.delete();

		for(int i = 0; i < NUM_TESTS; i++) begin
			test_queue_item.cmd.Cmd.value           = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
			test_queue_item.cmd.Sink.value          = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS;
			test_queue_item.cmd.DirectData.value    = 0;
			test_queue_item.test_id                 = test_id++;
			input_queue.push_back(test_queue_item);
			expected_queue.push_back(test_queue_item);
		end

	endtask

	// Task: Feed pipeline continuously (Queue-based)
	task automatic feed_pipeline();

		TipTSetDefault(tipt);
		tipt.iretire = '1;
		tipt.dtype   = CSR_READ_WRITE;
		tipt.daddr   = ACT_CAP_CMD;
		tipt.dsize   = 2;
		tipt.dretire = '1;

		while(input_queue.size() > 0) begin
			test_queue_item_t item = input_queue.pop_front();
			tipt.data    = cmd_to_tip_data (item.cmd);
			TipSendMsg (tip, tip_clk, tipt, DELAY_CYCLES);
		end

		FeedingDone <= '1;
		@(posedge tip_clk);
	endtask

	// Task: Collect and check results (Queue-based)
	task automatic check_results();
		test_queue_item_t expected;
		// Wait for pipeline delay for first result
		repeat(dut_delay) @(posedge tip_clk);

		while(expected_queue.size() > 0) begin

			while(!axis.tvalid) begin
				@(posedge tip_clk);
			end

			expected = expected_queue.pop_front();
			void'(tt_assert(axis.tdata[31:0] == TIP_DEFAULT_IADDR, $sformatf("%0.2f: Line %0d / Test %0d: unexpected axis.tdata: %0h", $realtime, `__LINE__, expected.test_id, axis.tdata[31:0])));
			@(posedge tip_clk);

		end

		CheckingDone <= '1;
		@(posedge tip_clk);

	endtask

	// Test stimulus
	initial begin
		tip_clk  = 0;
		proc_clk = 0;
		atclk    = 0;
		wb_clk   = 0;
		wall_clk = 0;

		synq_req_trace_byte_count <= 0;
		cs_tip.trTeInstSyncReq    <= 0; // no explicit sync request (P8)

		act_st_wext.ce      <= '0;
		act_st_wext.we      <= '0;
		act_st_wext.addr    <= '0;
		act_st_wext.d       <= '0;
		df_range_wext.ce          <= '0;
		df_range_wext.we          <= '0;
		df_range_wext.addr        <= '0;
		df_range_wext.d           <= '0;

		FeedingDone  <= '0;
		CheckingDone <= '0;

		tip_rst         <= 1;
		proc_rst        <= 1;
		atresetn        <= 0;
		wall_clk_rst    <= 1;

		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);

		@(posedge tip_clk);
		@(posedge proc_clk);
		@(posedge atclk);
		@(posedge wb_clk);
		@(posedge wall_clk);
		tip_rst         <= 0;
		proc_rst        <= 0;
		atresetn        <= 1;
		wall_clk_rst    <= 0;
		repeat (3) @(posedge tip_clk);

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
