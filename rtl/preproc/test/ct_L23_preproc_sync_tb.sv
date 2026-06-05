// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab

/**
 * @file    ct_L23_preproc_sync_tb.sv
 * @brief   Directed sync-generation testbench for ct_L23_preproc_sync.
 * @description Checks reset-exit sync generation, periodic syncs driven by
 *   tip and wall clocks, and externally requested syncs.
 * @environment Runs the DUT with independent tip and wall clocks and measures
 *   sync spacing with a simple stopwatch.
 * @stimulus Reconfigures the sync mode between reset-exit, tip-clock
 *   periodic, wall-clock periodic, and trace-byte-triggered cases.
 * @checking Asserts sync.reason values and wall-clock timing windows for the
 *   generated periodic sync events.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_sync_tb;

	import tt::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import nexus::*;
	import ct_cs_cpuif_pkg::*;

	localparam int DELAY_CYCLES = 2;
	localparam TIP_CLK_PERIOD       =  1.0;
	localparam DO_SYNC_CLK_PERIOD   =  5.0;
	localparam WALL_CLK_PERIOD      = 12.0;

	logic tip_rst;
	tip_t tipt;
	logic wall_clk_rst;
	int   StopwatchStart;
	int   StopwatchDiff;
	logic sync_req_atb_synq;
	logic synq_req_trace_byte_count;
	logic synq_req_trace_msg_count;
	logic [7:0] idelay_sync;
	logic [7:0] extra_delay_sync;

	logic tip_clk     = 0; always #(TIP_CLK_PERIOD    /2.0)  tip_clk       = ~tip_clk;
	logic wall_clk    = 0; always #(WALL_CLK_PERIOD/2.0)     wall_clk      = ~wall_clk;

	// Instantiate interfaces
	tip_if          tip   ();
	ct_cs_tipclk_if cs_tip();
	ct_sync_if      sync();

	// Instantiate DUT
	ct_L23_preproc_sync sync_inst (
		.clk (tip_clk),
		.rst (tip_rst),
		.tip,
		.wall_clk_rst,
		.wall_clk,
		.sync_req_atb_synq,
		.synq_req_trace_byte_count,
		.synq_req_trace_msg_count,
		.sync,
		.cs_tip,
		.internal_delay (idelay_sync),
		.extra_delay (extra_delay_sync)
	);

	always_ff @(posedge tip_clk) begin
		if (tip_rst) begin
			StopwatchStart <= $realtime;
		end
		else begin
			if (sync.reason == NEXUS_SYNC_PERIODIC) begin
				StopwatchDiff  <= $realtime - StopwatchStart;
				StopwatchStart <= $realtime;
			end
		end
	end

	// Gentle watchdog: aborts the run if the DUT never produces the expected
	// sync events (e.g. after a control-signal rename/addition on the
	// ct_cs_tipclk_if). Keep the timeout comfortably above the longest
	// legitimate wait in the tests (Test 3 waits multiple wall-clock-based
	// periodic syncs; WALL_CLK_PERIOD * 2**(trTeInstSyncMax+4) ~= 192 ns, so
	// 50 us gives ~2 orders of magnitude of headroom).
	localparam realtime WATCHDOG_TIMEOUT_NS = 50_000.0;
	initial begin
		#(WATCHDOG_TIMEOUT_NS);
		$fatal(1, "%0.2f: ct_L23_preproc_sync_tb watchdog timeout after %0.0f ns -- DUT did not produce the expected sync events",
			$realtime, WATCHDOG_TIMEOUT_NS);
	end

	// Test stimulus
	initial begin
		wall_clk_rst = 1;
		sync_req_atb_synq = 0;
		synq_req_trace_byte_count = 0;
		synq_req_trace_msg_count = 0;
		extra_delay_sync = 2;
		// The DUT requires both the master enable and the instruction-tracing
		// flag to produce any sync message; leaving trTeEnable at its default
		// makes every `while (sync.reason != ...)` loop hang forever.
		cs_tip.trTeEnable       = 1;
		cs_tip.trTeInstTracing  = 1;
		cs_tip.trTeInstSyncMax  = 0; // sync after 2**4 tip.clk cycles
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_CLK_CYCLES;

		tip_rst = 1;
		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		@(posedge tip_clk);
		wall_clk_rst = 0;

		// ------------------------------------------------------------
		// Test 1: Check for NEXUS_SYNC_EXIT_FROM_SYS_RST
		// ------------------------------------------------------------
		tipt.iretire = '1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		void'(tt_assert((sync.reason == NEXUS_SYNC_EXIT_FROM_SYS_RST), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_EXIT_FROM_SYS_RST expected", $realtime, `__LINE__)));

		// ------------------------------------------------------------
		// Test 2: Check for NEXUS_SYNC_PERIODIC (count tip.clk)
		// ------------------------------------------------------------
		cs_tip.trTeInstSyncMax  = 0; // sync after 2**4 tip.clk cycles
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_CLK_CYCLES;
		tip_rst = 1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_PERIODIC), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (tip.clk) expected", $realtime, `__LINE__)));
		// ------------------------------------------------------------
		// Test 3: Check for NEXUS_SYNC_PERIODIC (count wall_clk)
		// ------------------------------------------------------------
		wall_clk_rst = 1;
		cs_tip.trTeInstSyncMax  = 0; // sync after 2**4 tip.clk cycles
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_WALL_CLK;
		tip_rst = 1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		@(posedge tip_clk);
		wall_clk_rst = 0;
		TipSendMsg (tip, tip_clk, tipt, 3);
		void'(tt_assert((sync.reason == NEXUS_SYNC_EXIT_FROM_SYS_RST), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_EXIT_FROM_SYS_RST expected", $realtime, `__LINE__)));
		// measure time between this synq and periodic wallclock sync
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		TipSendMsg (tip, tip_clk, tipt, 0);
		void'(tt_assert( (StopwatchDiff > 250) && (StopwatchDiff < 450), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (wall_clk) expected, StopwatchDiff: %0d", $realtime, `__LINE__, StopwatchDiff)));
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		TipSendMsg (tip, tip_clk, tipt, 0);
		void'(tt_assert( (StopwatchDiff > 250) && (StopwatchDiff < 450), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (wall_clk) expected, StopwatchDiff: %0d", $realtime, `__LINE__, StopwatchDiff)));

		// ------------------------------------------------------------
		// Test 4: Check external sync
		// ------------------------------------------------------------
		wall_clk_rst = 1;
		cs_tip.trTeInstSyncMax  = 0; // sync after 2**4 tip.clk cycles
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES;
		tip_rst = 1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		TipSendMsg (tip, tip_clk, tipt, 3);
		void'(tt_assert((sync.reason == NEXUS_SYNC_EXIT_FROM_SYS_RST), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_EXIT_FROM_SYS_RST expected", $realtime, `__LINE__)));
		repeat (20) TipSendMsg (tip, tip_clk, tipt, 0);
		synq_req_trace_byte_count  = 1;
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_PERIODIC), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (trace bytes) expected", $realtime, `__LINE__)));
		synq_req_trace_byte_count  = 0;
		repeat (50)     TipSendMsg (tip, tip_clk, tipt, 0);
		tt_evaluate();
		$finish();
	end

endmodule
