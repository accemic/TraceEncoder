// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_L23_preproc_tb.sv
 * @brief   Directed integration testbench for ct_L23_preproc.
 * @details Verifies that ACT_CAP commands propagate through the
 *   preprocessor into the expected AXIS and ETIP DAQ outputs.
 * @environment Instantiates the full preprocessor, control/status interfaces,
 *   AXIS output, ETIP sources, ATB interface, and external memories across
 *   tip, proc, wb, and wall clocks.
 * @stimulus Configures tracing, then injects ACT_CAP commands for AXIS-only,
 *   NEXUS-only, and combined AXIS+NEXUS sinks with distinct instruction
 *   addresses.
 * @checking Runs parallel checks on AXIS transfers and hierarchical ETIP
 *   composer data against queue-based expectations.
 * @scoring Separate AXIS and ETIP expectation queues must drain before the
 *   integration testbench finishes.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_tb;

	import tt::*;
	import nexus_vendor::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import ct_pkg::*;
	import ct_etip_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import ct_comp_filters_pkg::*;

	localparam TIP_CLK_PERIOD       = 1;    // trace source clock
	localparam PROC_CLK_PERIOD      = 2;    // trace encoder internal processing clock
	localparam WALL_CLK_PERIOD      = 10;   // wall clock
	localparam WB_CLK_PERIOD        = 4;    // wishbone clock

	localparam int DELAY_CYCLES = 0;

	logic       tip_rst;
	logic       proc_rst;
	logic       wb_rst;
	logic       ct_cs_rst;
	logic       wall_clk_rst;
	logic       synq_req_trace_byte_count;
	delay_t     internal_delay;

	ct_cs_cpuif__trActCapStCmd__out_t cmd;

	// Clocks
	logic  tip_clk    = 0; always #TIP_CLK_PERIOD      tip_clk    = ~tip_clk;
	logic  proc_clk   = 0; always #PROC_CLK_PERIOD     proc_clk   = ~proc_clk;
	logic  wb_clk     = 0; always #WB_CLK_PERIOD       wb_clk     = ~wb_clk;
	logic  wall_clk   = 0; always #WALL_CLK_PERIOD     wall_clk   = ~wall_clk;

	// Control flags
	logic FeedingDone       = 0;
	logic AxisCheckingDone  = 0;
	logic EtipCheckingDone  = 0;

	// Instantiate interfaces
	tip_if              tip    ();
	ct_act_cap_if       act_st ();
	ct_cs_tipclk_if     cs_tip ();
	ct_cs_procclk_if    cs_proc();
	ct_cs_atbclk_if     cs_atb ();
	ct_cs_decclk_if     cs_dec ();

	ocram_write_if #(.A_BITS(M0_STAGES), .T(m0_kr_t)) act_st_wext   (.clk(wb_clk));
	ocram_write_if #(.A_BITS(M1_STAGES), .T(m1_kr_t)) df_range_wext (.clk(wb_clk));

	axis_if #(
		.TDATA_WIDTH(ACT_CAP_AXIS_TDATA_WIDTH),
		.TID_WIDTH  (ACT_CAP_AXIS_TID_WIDTH))
	axis (
		.aclk (tip_clk),
		.aresetn(!tip_rst));

	source_if #(.T(etip_msg_struct_t))      etip_q       (.clk(proc_clk), .rst(proc_rst));
	source_if #(.T(tip_iaddr_t))            next_iaddr_q (.clk(proc_clk), .rst(proc_rst));
	wb_if #(.ADDR_WIDTH(32),.DATA_WIDTH(32)) wb();

	assign proc_rst = tip_rst;
	assign wall_clk_rst = tip_rst;

	// instantiate ct_cs_cpuif_wb
	ct_cs_cpuif_wb ct_cs_cpuif_wb_inst (
		.wb_clk,
		.wb_rst,
		.ct_cs_rst,
		.tip_clk,
		.tip_rst,
		.proc_clk,
		.proc_rst,
		.cs_tip,
		.act_st_wext,
		.df_range_wext,
		.cs_proc,
		.cs_atb,
		.cs_dec,
		.wb
	);

	ct_L23_preproc preproc_inst (
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
		.wext_clk       (wb_clk),
		.act_st_wext,
		.df_range_wext,
		.internal_delay
 );

	// etip_q, next_iaddr_q dummy read
	assign etip_q.ack       = etip_q.valid;
	assign next_iaddr_q.ack = next_iaddr_q.valid;

	tip_t           tipt;    // struct with tip_if signals
	ct_act_cap_te_t act_cap_te;

	//========================================================================
	// CONFIGURATION TASK
	//========================================================================

	task automatic configure_dut();

		// Initialize CompFilter (always FALSE)
		CompFilterInit (cs_tip);
		CompSetInactive(cs_tip, 0);             // comp 0 output FALSE
		FilterSetDataComp  (cs_tip, 0, 0, 0);   // Filter 0: trTeFilterComp1 = 0

		// enable CompFilter for data tracing
		cs_tip.trTeDataTracingSet   = 1;
		cs_tip.trTeDataTracingClr   = 0;
		cs_tip.trTeDataTracing      = 1;

		// enable CompFilter for control flow tracing
		cs_tip.trTeInstTracingSet   = 1;
		cs_tip.trTeInstTracingClr   = 0;
		cs_tip.trTeInstTracing      = 1;

		// no explicit sync request from the control bus (P8)
		cs_tip.trTeInstSyncReq      = 0;

	endtask

	//========================================================================
	// Task: Generate tests
	//========================================================================

	typedef struct {
		tip_t       tip;                    // input
		string      desc;                   // test case description
		int         test_id;                // test number
	} test_queue_item_t;

	test_queue_item_t    input_queue[$];         // Input test queue
	test_queue_item_t    expected_queue_etip[$]; // Expected results queue
	test_queue_item_t    expected_queue_axis[$]; // Expected results queue

	task automatic generate_tests();

		test_queue_item_t item;
		int     test_id = 0;
		TipTSetDefault(tipt);

		input_queue.delete();
		expected_queue_axis.delete();
		expected_queue_etip.delete();

		TipTSetDefault(tipt);

		// ------------------------------------------------
		// 1. Enable Instruction Tracing via ATC-CAP
		// ------------------------------------------------

		item.tip                    = tipt;
		act_cap_te.ctrl             = ACT_CAP_TE_INSTR_TRACING;
		act_cap_te.data             = 16'h1;                        // trTeControl.InstTracing = 1;
		cmd.DirectData.value        = act_cap_te;
		cmd.Sink.value              = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_TE;
		cmd.Cmd.value               = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_TE;
		item.tip.iretire            = '1;
		item.tip.dtype              = CSR_READ_WRITE;
		item.tip.daddr              = ACT_CAP_CMD;
		item.tip.data               = cmd_to_tip_data(cmd);
		item.tip.dsize              = 2;
		item.tip.dretire            = '1;
		item.desc                   = "Enable Instruction Tracing by ACT-CAP";
		item.test_id                = test_id++;
		input_queue.push_back(item);

		// ------------------------------------------------
		// 2. Send AXIS message
		// ------------------------------------------------

		item.tip                    = tipt;
		cmd.DirectData.value        = '0;
		cmd.Sink.value              = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS;
		cmd.Cmd.value               = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
		item.tip.data               = cmd_to_tip_data(cmd);
		item.tip.dtype              = CSR_READ_WRITE;
		item.tip.daddr              = ACT_CAP_CMD;
		item.tip.data               = cmd_to_tip_data(cmd);
		item.tip.dsize              = 2;
		item.tip.dretire            = '1;
		tipt.iaddr                  = 32'h1234_0000;
		item.tip.iretire            = '1;
		item.desc                   = "Send AXIS message with iaddr = 32'h1234_0000";
		item.test_id                = test_id++;
		input_queue.push_back(item);
		expected_queue_axis.push_back(item);

		// ------------------------------------------------
		// 3. Send ETIP DAQ message
		// ------------------------------------------------

		item.tip                    = tipt;
		cmd.DirectData.value        = '0;
		cmd.Sink.value              = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
		cmd.Cmd.value               = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
		item.tip.data               = cmd_to_tip_data(cmd);
		item.tip.dtype              = CSR_READ_WRITE;
		item.tip.daddr              = ACT_CAP_CMD;
		item.tip.data               = cmd_to_tip_data(cmd);
		item.tip.dsize              = 2;
		item.tip.dretire            = '1;
		tipt.iaddr                  = 32'h1234_1000;
		item.tip.iretire            = '1;
		item.desc                   = "Send ETIP message with iaddr = 32'h1234_1000";
		item.test_id                = test_id++;
		input_queue.push_back(item);
		expected_queue_etip.push_back(item);

		// ------------------------------------------------
		// 3. Send AXIS and ETIP DAQ message
		// ------------------------------------------------

		item.tip                    = tipt;
		cmd.DirectData.value        = '0;
		cmd.Sink.value              = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS;
		cmd.Cmd.value               = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
		item.tip.data               = cmd_to_tip_data(cmd);
		item.tip.dtype              = CSR_READ_WRITE;
		item.tip.daddr              = ACT_CAP_CMD;
		item.tip.data               = cmd_to_tip_data(cmd);
		item.tip.dsize              = 2;
		item.tip.dretire            = '1;
		tipt.iaddr                  = 32'h1234_2000;
		item.tip.iretire            = '1;
		item.desc                   = "Send AXIS and ETIP message with iaddr = 32'h1234_2000";
		item.test_id                = test_id++;
		input_queue.push_back(item);
		expected_queue_axis.push_back(item);
		expected_queue_etip.push_back(item);

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
	// Task: Check results (AXIS)
	//========================================================================
	task automatic check_results_axis();
		test_queue_item_t exp;

		while(expected_queue_axis.size() > 0) begin
			if (axis.tvalid == '1) begin
				exp = expected_queue_axis.pop_front();
				void'(tt_assert(axis.tdata[31:0] == exp.tip.iaddr , $sformatf("%0.2f: Line %0d / Test %0d (%s) unexpected axis.tdata: %0h (expected: %0h)",
					  $realtime, `__LINE__, exp.test_id, exp.desc, axis.tdata[31:0], exp.tip.iaddr)));
			end
			@(posedge tip_clk);
		end

		AxisCheckingDone <= 1'h1;
		@(posedge tip_clk);

	endtask

	//========================================================================
	// Task: Check results (ETIP)
	//========================================================================
	task automatic check_results_etip();
		test_queue_item_t exp;

		while(expected_queue_etip.size() > 0) begin
			for (int i = 0; i < 3; i++) begin
				if (preproc_inst.composer_etip_inst.etip_cvs_d.d[i].sub_type == SUB_MSG_DAQ) begin
					exp = expected_queue_etip.pop_front();
					void'(tt_assert(preproc_inst.composer_etip_inst.etip_cvs_d.d[i].sub.daq.data[0] == exp.tip.iaddr , $sformatf("%0.2f: Line %0d / Test %0d (%s) unexpected etip.iaddr: %0h (expected: %0h)",
						$realtime, `__LINE__, exp.test_id, exp.desc, preproc_inst.composer_etip_inst.etip_cvs_d.d[i].sub.daq.data[0] , exp.tip.iaddr)));
				end
			end
			@(posedge tip_clk);
		end

		EtipCheckingDone <= 1'h1;
		@(posedge tip_clk);

	endtask

	//========================================================================
	// Main
	//========================================================================

	initial begin

		// Initialize
		tip_rst         <= '1;
		ct_cs_rst       <= '1;
		wb_rst          <= '1;

		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);
		@(posedge tip_clk);
		tip_rst     <= '0;
		@(posedge tip_clk);
		ct_cs_rst   <= '0;
		@(posedge wb_clk);
		wb_rst      <= '0;

		configure_dut();
		@(posedge tip_clk);

		generate_tests();
		fork
			feed_pipeline();            // Continuously feed tests
			check_results_axis();       // Continuously collect and check results
			check_results_etip();       // Continuously collect and check results
		join

		// Wait for completion
		wait(FeedingDone && AxisCheckingDone && EtipCheckingDone);

		repeat (10) @(posedge tip_clk);

		tt_evaluate();
		$finish();

	end

endmodule
