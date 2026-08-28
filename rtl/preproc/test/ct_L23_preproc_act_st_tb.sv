// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_L23_preproc_act_st_tb.sv
 * @brief   Directed table-lookup testbench for ct_L23_preproc_act_st.
 * @details Programs the action-state memory through wext and verifies
 *   instruction-address lookups with a mixed sequence of hit and miss inputs.
 * @environment Uses tip_clk stimulus and wb_clk memory writes to configure
 *   the lookup table before issuing retired instruction traces.
 * @stimulus Feeds a fixed set of instruction addresses that should produce a
 *   known subset of ACT_ST hits.
 * @checking Consumes act_st.valid pulses with a scoreboard queue of expected
 *   command words and asserts that no extra hits appear after the expected
 *   sequence.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_act_st_tb;

	import tt::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import ct_pkg::*;

	localparam delay_t   EXTRA_DELAY = 2;
	localparam int          DELAY_CYCLES = 0;

	localparam TIP_CLK_PERIOD    = 1.0;
	localparam WB_CLK_PERIOD     = 3.0;

	logic tip_rst;
	logic wb_rst;      // rst and clk for wext
	logic start_evaluation;

	logic tip_clk = 0; always #(TIP_CLK_PERIOD/2.0)  tip_clk  = ~tip_clk;
	logic wb_clk  = 0; always #(WB_CLK_PERIOD /2.0)   wb_clk  = ~wb_clk;

	delay_t dut_delay;

	// Instantiate interfaces

	tip_if                                      tip    ();
	ct_act_cap_if                               act_st ();
	ct_cs_tipclk_if                             cs_tip ();
	ocram_write_if #(.A_BITS(M0_STAGES), .T(m0_kr_t)) wext   (.clk(wb_clk));

	// Instantiate DUT. The explicit .DIM matters (C0b audit B-2): without
	// it the DUT elaborates at the module DEFAULT (4) while the TB loads
	// M0_N entries through a wext sized for M0_STAGES -- the run passes,
	// but it exercises a 15-slot tree, not the product dimension.
	ct_L23_preproc_act_st #(.DIM(ct_pkg::M0_DIM)) dut
	(
		.clk (tip_clk),
		.rst (tip_rst),
		.tip,
		.act_st,
		.cs_tip,
		.wext_clk (wb_clk),
		.wext,
		.internal_delay (dut_delay),
		.extra_delay (EXTRA_DELAY)
	);

	// Task to configure dut memory
	task automatic WriteExt(int addr, M0_K key, M0_R value);
		wext.ce   <= 1;
		wext.we   <= 1;
		wext.addr <= addr;
		// typed assignment pattern -- the historical `(m0_kr_t)'{...}`
		// cast-of-pattern is xsim-only; Verilator rejects it, and this TB
		// never had a Verilator run before C0b.
		wext.d    <= m0_kr_t'{key, value};
		@(posedge wb_clk);
	endtask

	// Test values (Hit/Miss mixed). We program each watchpoint slot so that
	// the cmd word (per the RDL trActCapStCmd layout) decodes to
	// DirectData = i and Cmd/Sink = 0 — i.e. the raw memory word is (i << 8).
	// On a hit, act_st.cmd holds the unpacked struct, which re-cast to a
	// 32-bit vector lands DirectData back into bits[23:0] → expected == i.
	localparam int TESTS = 6;
	M0_K    tests     [TESTS] = '{ 32'h0000_0003, 32'h0000_0005,  32'hDEAD_BEEF,  32'h0000_0001, 32'hDEAD_BEEF, 32'h1234_5678};
	bit     exp_hit   [TESTS] = '{             1,             1,              0,              1,             0,             0};
	M0_R    exp_value [TESTS] = '{   32'h0000_0003,   32'h0000_0005,    32'h0000_0000,    32'h0000_0001,   32'h0000_0000,   32'h0000_0000};

	tip_t   tipt;    // struct with tip_if signals
	M0_R    act_st_cmd;

	// Expected hit command queue (only for expected hits)
	M0_R expected_cmd_q[$];

	// Variables used by the checker process
	integer timeout_cycles;
	M0_R exp_cmd;

	initial begin

		wext.ce     <= '0;
		wext.we     <= '0;
		wext.addr   <= '0;
		wext.d      <= '0;
		start_evaluation    <= '0;

		// Initialize
		tip_rst         <= '1;
		wb_rst          <= '1;
		@(posedge tip_clk);
		@(posedge wb_clk);
		tip_rst         <= '0;
		wb_rst          <= '0;

		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 0);

		// Configure ascending key/value pairs. The memory word (hit_value) is
		// interpreted by ct_L23_preproc_act_st per the RDL trActCapStCmd bit
		// layout: [5:0]=Cmd, [7:6]=Sink, [31:8]=DirectData. Writing (i << 8)
		// parks the ascending label `i` into the DirectData slot, leaving
		// Cmd=NONE, Sink=NEXUS.
		for (int i = 0; i < M0_N; i++) begin
			WriteExt(i, i, i<<8);
		end

		wext.ce   <= '0;
		wext.we   <= '0;
		wext.addr <= '0;
		wext.d    <= '0;
		@(posedge wb_clk);

		start_evaluation <= '1;
		expected_cmd_q.delete();
		for (int i = 0; i < TESTS; i++) begin
			if (exp_hit[i]) expected_cmd_q.push_back(exp_value[i]);
		end
		// Feed pipeline
		for (int t=0; t<TESTS; t++) begin
			tipt.itype   = OTHER;
			tipt.iaddr   =  tests[t];
			tipt.iretire = '1;
			TipSendMsg (tip, tip_clk, tipt, DELAY_CYCLES);
		end

		// Stop issuing new data
		repeat (200) @(posedge tip_clk);
	end


	initial begin
		// Wait for start
		@(posedge tip_clk);
		while (!start_evaluation) begin
			@(posedge tip_clk);
		end

		// Robust scoreboard-style checking:
		// We only observe act_st.valid pulses and compare their cmd payload against the
		// expected hit sequence. This avoids tight coupling to internal pipeline timing.

		timeout_cycles = 0;
		while (expected_cmd_q.size() > 0) begin
			@(posedge tip_clk);
			if (act_st.valid) begin
				exp_cmd = expected_cmd_q.pop_front();
				// explicit repack in struct DECLARATION order ({Cmd, Sink,
				// DirectData} -- what the historical M0_R'(act_st.cmd) cast
				// flattened to under xsim; Verilator rejects casting an
				// UNPACKED hwif struct outright). For the (i << 8) memory
				// words of this TB that flattening equals plain i.
				act_st_cmd = { act_st.cmd.Cmd.value,
				               act_st.cmd.Sink.value,
				               act_st.cmd.DirectData.value };
				void'(tt_assert(act_st_cmd == exp_cmd,
					$sformatf("%0.2f: Line %0d *** Unexpected act_st.cmd: %h (expected: %h)",
						$realtime, `__LINE__, act_st_cmd, exp_cmd)));
				timeout_cycles = 0;
			end else begin
				timeout_cycles++;
				if (timeout_cycles > 2000) begin
					void'(tt_assert(1'b0, "Timeout waiting for expected act_st.valid pulses"));
					break;
				end
			end
		end

		// Ensure no spurious extra hits after we consumed all expected hits.
		repeat (200) begin
			@(posedge tip_clk);
			void'(tt_assert(!act_st.valid, "Unexpected extra act_st.valid after expected hits"));
		end

		tt_evaluate();
		$finish();
	end

endmodule
