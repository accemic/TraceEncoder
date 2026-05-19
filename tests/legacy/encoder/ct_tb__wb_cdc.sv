// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_tb__wb_cdc.sv
 * @brief   Wishbone / register CDC regression testbench for the C-Trace encoder.
 * @description Exercises ONLY the WB-to-domain-crossing paths in
 *   ct_cs_cpuif_wb: wb_clk <-> tip_clk signal_cdc / strobe_cdc (via
 *   ct_hwif_ext_signal_cdc) and wb_clk <-> proc_clk signal_cdc. The
 *   testbench does not feed TIP stimuli and does not observe the ATB /
 *   Nexus output path at all. All checking is done by hierarchical peek
 *   into the CS interfaces at the destination clock domain.
 * @environment Clocks are chosen to be pairwise non-commensurable and to
 *   start with distinct phase offsets so that no edges line up at t=0.
 *   Additional per-write sub-cycle jitter is injected before each WB
 *   access so that the instant a source-domain value changes relative to
 *   the destination clock edge is swept rather than pinned. The goal is
 *   to avoid the common "same period, same phase" simulation artefact
 *   where CDC issues stay hidden behind perfect edge alignment.
 * @stimulus Sequences of Wishbone writes and reads against selected
 *   configuration registers. TIP is held idle (iretire=0) the whole time.
 * @checking For each field with a CDC path we compare the WB-side value
 *   against the destination-domain signal observed via hierarchical
 *   reference once the expected synchroniser latency has elapsed.
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
*/
module ct_tb__wb_cdc;

	localparam WB_DATA_WIDTH = 32;
	localparam WB_ADDR_WIDTH = 32;

	import tt::*;
	import tip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;
	import tip_utils_pkg::*;

	// Non-commensurable half-periods (full period = 2 * HALF).
	// TIP and WB are targeted at ~25 MHz. PROC is kept >~3x TIP and ATB
	// >~2x TIP per the integration rules documented at ct_encoder's port
	// list. The actual numbers are deliberately chosen as mutually
	// prime-ish floats so that the least common multiple of any pair is
	// long compared to the simulation horizon -- i.e. the pairwise edge
	// offset drifts continuously for the whole simulation and never
	// settles back into alignment (a "ppm mismatch" effect in miniature).
	localparam real TIP_CLK_HALF  = 19.67;  // ~25.4 MHz (full 39.34 ns)
	localparam real WB_CLK_HALF   = 20.83;  // ~24.0 MHz (full 41.66 ns)
	localparam real PROC_CLK_HALF =  3.29;  // ~152.0 MHz (full  6.58 ns)
	localparam real ATB_CLK_HALF  =  3.97;  // ~126.0 MHz (full  7.94 ns)
	localparam real WALL_CLK_HALF = 99.7;   // wall-clock reference (~5 MHz)

	// Maximum random start-phase applied to each clock at t=0. Drawing
	// these at random per run (with $urandom_range + the XSim
	// +ntb_random_seed=N plusarg) means different runs see different
	// relative edge alignments; combined with the non-commensurable
	// periods above, any transaction that happened to pass under one
	// alignment is exposed to a different one within the same simulation.
	localparam real TIP_PHASE_MAX  = 2.0 * TIP_CLK_HALF;
	localparam real PROC_PHASE_MAX = 2.0 * PROC_CLK_HALF;
	localparam real WB_PHASE_MAX   = 2.0 * WB_CLK_HALF;
	localparam real WALL_PHASE_MAX = 2.0 * WALL_CLK_HALF;
	localparam real ATB_PHASE_MAX  = 2.0 * ATB_CLK_HALF;

	// Synchroniser settle time we give each CDC path before reading back
	// its destination-domain signal. Worst case is strobe_cdc (toggle ->
	// 2-FF sync -> edge detect), so round up to a healthy margin.
	localparam int SETTLE_TIP_CYCLES  = 20;
	localparam int SETTLE_PROC_CYCLES = 20;

	// Clocks. Each clock gets an independent random start phase so that
	// no two clocks share a posedge at t=0 and the set of relative
	// alignments varies run-to-run.
	logic tip_clk    = 0;
	logic proc_clk   = 0;
	logic wb_clk     = 0;
	logic wall_clk   = 0;
	logic atb_atclk  = 0;

	function automatic real rand_phase(real max_ns);
		int r;
		r = $urandom_range(0, 1000000);
		return (real'(r) / 1000000.0) * max_ns;
	endfunction

	// All clock start-phases are drawn in a single initial block and
	// fork/join_none launches each clock's forever-toggle loop. An
	// optional +CT_CDC_SEED=N plusarg reseeds via $srandom (xsim does
	// not support $urandom(seed) as a re-seeder, but $srandom works).
	// Users can also sweep seeds via the standard +ntb_random_seed=N
	// xsim plusarg.
	initial begin
		int unsigned cdc_seed;
		real tip_ph, proc_ph, wb_ph, wall_ph, atb_ph;
		if ($value$plusargs("CT_CDC_SEED=%d", cdc_seed)) begin
			$display("%0.2f: ct_tb__wb_cdc: reseeding with CT_CDC_SEED=%0d",
				$realtime, cdc_seed);
			process::self().srandom(cdc_seed);
		end
		tip_ph  = rand_phase(TIP_PHASE_MAX);
		proc_ph = rand_phase(PROC_PHASE_MAX);
		wb_ph   = rand_phase(WB_PHASE_MAX);
		wall_ph = rand_phase(WALL_PHASE_MAX);
		atb_ph  = rand_phase(ATB_PHASE_MAX);
		$display("%0.2f: ct_tb__wb_cdc: clock phases (ns): tip=%0.3f proc=%0.3f wb=%0.3f wall=%0.3f atb=%0.3f",
			$realtime, tip_ph, proc_ph, wb_ph, wall_ph, atb_ph);
		fork
			begin #tip_ph;  forever #TIP_CLK_HALF  tip_clk   = ~tip_clk;   end
			begin #proc_ph; forever #PROC_CLK_HALF proc_clk  = ~proc_clk;  end
			begin #wb_ph;   forever #WB_CLK_HALF   wb_clk    = ~wb_clk;    end
			begin #wall_ph; forever #WALL_CLK_HALF wall_clk  = ~wall_clk;  end
			begin #atb_ph;  forever #ATB_CLK_HALF  atb_atclk = ~atb_atclk; end
		join_none
	end

	// Resets and miscellaneous tie-offs
	logic tip_rst;
	logic proc_rst;
	logic wb_rst;
	logic ct_cs_rst;
	logic wall_clk_rst;
	logic atb_atresetn;

	// Interfaces
	tip_if  tip       ();
	tip_if  tip_dir   ();

	// Driving tip via the same assign trick as ct_tb__directed so that
	// the tip_if.slave port inside ct_encoder sees coherent default
	// values from tip_dir (driven idle by TipIfSetDefault/TipTSetDefault).
	assign tip._time      = '0;
	assign tip.itype      = tip_dir.itype;
	assign tip.ecause     = tip_dir.ecause;
	assign tip.tval       = tip_dir.tval;
	assign tip.priv       = tip_dir.priv;
	assign tip.iaddr      = tip_dir.iaddr;
	assign tip._context   = tip_dir._context;
	assign tip.ctype      = tip_dir.ctype;
	assign tip.iretire    = tip_dir.iretire;
	assign tip.ilastsize  = tip_dir.ilastsize;
	assign tip.impdef     = tip_dir.impdef;
	assign tip.dretire    = tip_dir.dretire;
	assign tip.dtype      = tip_dir.dtype;
	assign tip.daddr      = tip_dir.daddr;
	assign tip.dsize      = tip_dir.dsize;
	assign tip.data       = tip_dir.data;

	axis_if #( .TDATA_WIDTH(ACT_CAP_AXIS_TDATA_WIDTH),
			   .TID_WIDTH  (ACT_CAP_AXIS_TID_WIDTH))
	  axis (.aclk(tip_clk), .aresetn(!tip_rst));

	atb_if atb ();
	assign atb.syncreq = '0;
	assign atb.afvalid = '0;

	wb_if #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_DATA_WIDTH)) wb();

	ct_cs_cpuif_wb_helper #(.WB_DATA_WIDTH(WB_DATA_WIDTH), .WB_ADDR_WIDTH(WB_DATA_WIDTH))
		ct_cs_wb (wb_clk, wb);

	ct_encoder ct_encoder_inst (
		.tip_clk,   .tip_rst,        .tip,
		.wb_clk,    .wb_rst,         .wb,
		.axis,
		.atb_atclk, .atb_atresetn,   .atb,
		.proc_clk,  .proc_rst,
		.ct_cs_rst,
		.wall_clk,  .wall_clk_rst
	);

	// Hierarchical shortcuts into the destination clock domains. The
	// checks below never look at the ATB / trace path; we only peek at
	// the register values as they appear on the far side of the CDC
	// primitives.
	`define CS_TIP  ct_encoder_inst.ct_cs_cpuif_wb_inst.cs_tip
	`define CS_PROC ct_encoder_inst.ct_cs_cpuif_wb_inst.cs_proc

	//========================================================================
	// Jitter helper: inject a pseudo-random sub-cycle delay before a WB
	// access so that the instant at which our write settles relative to
	// tip_clk / proc_clk edges gets swept rather than pinned. The
	// underlying RNG is XSim's global thread-local generator, seeded via
	// the standard +ntb_random_seed=N plusarg.
	//========================================================================
	task automatic jitter();
		real frac;
		int unsigned raw;
		raw  = $urandom();
		frac = real'(raw & 32'h0000_FFFF) / 65536.0; // [0.0, 1.0)
		#(frac * (2.0 * WB_CLK_HALF));
	endtask

	//========================================================================
	// Assertion helpers
	//========================================================================
	task automatic assert_tip_bit(input string what, input logic expected, input logic observed);
		void'(tt_assert(observed === expected,
			$sformatf("%0.2f: Line %0d: %s tip-side mismatch: exp=%0b got=%0b",
				$realtime, `__LINE__, what, expected, observed)));
	endtask

	task automatic assert_proc_bit(input string what, input logic expected, input logic observed);
		void'(tt_assert(observed === expected,
			$sformatf("%0.2f: Line %0d: %s proc-side mismatch: exp=%0b got=%0b",
				$realtime, `__LINE__, what, expected, observed)));
	endtask

	task automatic assert_wb_eq(input string what, input logic [31:0] expected, input logic [31:0] observed);
		void'(tt_assert(observed === expected,
			$sformatf("%0.2f: Line %0d: %s wb readback mismatch: exp=%08h got=%08h",
				$realtime, `__LINE__, what, expected, observed)));
	endtask

	task automatic settle_tip();
		repeat (SETTLE_TIP_CYCLES) @(posedge tip_clk);
	endtask

	task automatic settle_proc();
		repeat (SETTLE_PROC_CYCLES) @(posedge proc_clk);
	endtask

	//========================================================================
	// Individual CDC tests
	//========================================================================

	// trTeControl.Enable (wb -> tip, signal_cdc)
	task automatic test_enable_cdc(input logic value);
		jitter();
		ct_cs_wb.Set_te_trTeControl_Enable(value);
		settle_tip();
		assert_tip_bit($sformatf("trTeEnable=%0b", value), value, `CS_TIP.trTeEnable);
	endtask

	// trTeControl.InstTracing (wb -> tip, ct_hwif_ext_signal_cdc::value)
	task automatic test_inst_tracing_cdc(input logic value);
		jitter();
		ct_cs_wb.Set_te_trTeControl_InstTracing(value);
		settle_tip();
		assert_tip_bit($sformatf("trTeInstTracing=%0b", value), value, `CS_TIP.trTeInstTracing);
	endtask

	// trTeDataControl.DataTracing (wb -> tip, ct_hwif_ext_signal_cdc::value)
	task automatic test_data_tracing_cdc(input logic value);
		jitter();
		ct_cs_wb.Set_te_trTeDataControl_DataTracing(value);
		settle_tip();
		assert_tip_bit($sformatf("trTeDataTracing=%0b", value), value, `CS_TIP.trTeDataTracing);
	endtask

	// trTsControl.Enable (wb -> proc, signal_cdc)
	task automatic test_ts_enable_cdc(input logic value);
		jitter();
		ct_cs_wb.Set_te_trTsControl_Enable(value);
		settle_proc();
		assert_proc_bit($sformatf("trTsEnable=%0b", value), value, `CS_PROC.trTsEnable);
	endtask

	// trTsControl.Active (wb -> tip, signal_cdc)
	task automatic test_ts_active_cdc(input logic value);
		jitter();
		ct_cs_wb.Set_te_trTsControl_Active(value);
		settle_tip();
		assert_tip_bit($sformatf("trTsActive=%0b", value), value, `CS_TIP.trTsActive);
	endtask

	// trTsControl.Count (wb -> tip, signal_cdc)
	task automatic test_ts_count_cdc(input logic value);
		jitter();
		ct_cs_wb.Set_te_trTsControl_Count(value);
		settle_tip();
		assert_tip_bit($sformatf("trTsCount=%0b", value), value, `CS_TIP.trTsCount);
	endtask

	// Level-triggered clear bits on trTeTipFifoStatus (wb -> tip, signal_cdc).
	// These are NOT self-clearing (see memory note "trTeTipFifoStatus Clear
	// semantics"): SW must write 1 then 0 to pulse.
	task automatic test_tipfifo_max_fill_clear_cdc();
		jitter();
		ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(1'b1);
		settle_tip();
		assert_tip_bit("trTeTipFifoMaxFillClear=1", 1'b1, `CS_TIP.trTeTipFifoMaxFillClear);
		jitter();
		ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(1'b0);
		settle_tip();
		assert_tip_bit("trTeTipFifoMaxFillClear=0", 1'b0, `CS_TIP.trTeTipFifoMaxFillClear);
	endtask

	task automatic test_tipfifo_num_overflows_clear_cdc();
		jitter();
		ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear(1'b1);
		settle_tip();
		assert_tip_bit("trTeTipFifoNumOverflowsClear=1", 1'b1, `CS_TIP.trTeTipFifoNumOverflowsClear);
		jitter();
		ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear(1'b0);
		settle_tip();
		assert_tip_bit("trTeTipFifoNumOverflowsClear=0", 1'b0, `CS_TIP.trTeTipFifoNumOverflowsClear);
	endtask

	// Pure-WB config register: no CDC, just confirms the regfile round-trip
	// works under the non-commensurable clocking so later failures can be
	// unambiguously attributed to CDC paths instead of the shim.
	task automatic test_pure_wb_roundtrip();
		logic [31:0] rd;
		logic [31:0] pattern;
		pattern = 32'hA5A5_0001;
		jitter();
		// trTeInstFeatures: SrcID + SrcBits, SW-gated behind Enable=0.
		ct_cs_wb.Set_te_trTeInstFeatures_SrcBits(4'd7);
		ct_cs_wb.Set_te_trTeInstFeatures_SrcID(12'hABC);
		jitter();
		ct_cs_wb.Read_te_trTeInstFeatures(rd);
		// Lower 16 bits are reserved (zero); SrcID is bits [27:16], SrcBits [31:28].
		assert_wb_eq("trTeInstFeatures SrcBits",
			32'h7, (rd >> BITPOS_te_trTeInstFeatures_SrcBits_LSB) & 32'hF);
		assert_wb_eq("trTeInstFeatures SrcID",
			32'hABC, (rd >> BITPOS_te_trTeInstFeatures_SrcID_LSB) & 32'hFFF);
	endtask

	// Burst test: rapidly toggle Enable many times. Each write carries a
	// fresh sub-cycle phase so the source transition moves around the
	// tip_clk edge across iterations. After the burst we finally settle
	// and check consistency.
	task automatic test_enable_burst(input int iterations);
		logic expected;
		expected = 1'b0;
		for (int i = 0; i < iterations; i++) begin
			expected = ~expected;
			jitter();
			ct_cs_wb.Set_te_trTeControl_Enable(expected);
		end
		settle_tip();
		assert_tip_bit($sformatf("trTeEnable after burst (last=%0b)", expected),
			expected, `CS_TIP.trTeEnable);
	endtask

	task automatic test_inst_tracing_burst(input int iterations);
		logic expected;
		expected = 1'b0;
		for (int i = 0; i < iterations; i++) begin
			expected = ~expected;
			jitter();
			ct_cs_wb.Set_te_trTeControl_InstTracing(expected);
		end
		settle_tip();
		assert_tip_bit($sformatf("trTeInstTracing after burst (last=%0b)", expected),
			expected, `CS_TIP.trTeInstTracing);
	endtask

	//========================================================================
	// Missed-ack detection: incrementing write/read on a plain RW
	// register. Every write is immediately readback-verified via the
	// same WB master. A dropped ack (WB master never sees wb.ack) would
	// hang the task; a misaligned ack / dropped write would surface as
	// a readback mismatch because the register kept its previous value.
	//========================================================================
	task automatic test_inst_filters_incremental(input int iterations);
		logic [31:0] rd;
		logic [15:0] pattern;
		logic [31:0] expected;
		for (int i = 0; i < iterations; i++) begin
			// Use a non-sequential permutation so a bug that keeps
			// "old_value | new_value" can't accidentally look correct.
			pattern = 16'((i * 16'h9E37) ^ i);
			jitter();
			ct_cs_wb.Set_te_trTeInstFilters_Filters(pattern);
			jitter();
			ct_cs_wb.Read_te_trTeInstFilters(rd);
			expected = 32'(pattern);
			assert_wb_eq($sformatf("trTeInstFilters[%0d]", i), expected, rd);
		end
	endtask

	task automatic test_data_filters_incremental(input int iterations);
		logic [31:0] rd;
		logic [15:0] pattern;
		logic [31:0] expected;
		for (int i = 0; i < iterations; i++) begin
			pattern = 16'((i * 16'hBC31) ^ (i << 3));
			jitter();
			ct_cs_wb.Set_te_trTeDataFilters_Filters(pattern);
			jitter();
			ct_cs_wb.Read_te_trTeDataFilters(rd);
			expected = 32'(pattern);
			assert_wb_eq($sformatf("trTeDataFilters[%0d]", i), expected, rd);
		end
	endtask

	//========================================================================
	// Clear-bit pulse-shape / idempotency stress.
	//
	// The two TIP-FIFO clears are declared as plain level signals in
	// ct_cs_cpuif_wb.sv (signal_cdc from wb_clk -> tip_clk). SW writes 1
	// to assert, writes 0 to deassert. The canonical failure mode if the
	// RDL or CDC accidentally treats them as a strobe is a "double
	// clear": clear fires once when we write 1, and fires a second time
	// at an arbitrary later cycle (e.g. on wb_clk re-edges of the
	// already-stable 1 value, or on the 1->0 drop).
	//
	// Detection: sample the destination-domain level in a cycle-by-cycle
	// loop, count rising and falling edges, and compare against the
	// number we drove from SW. One write-1 -> exactly one rising edge;
	// one write-0 -> exactly one falling edge.
	//========================================================================
	int max_fill_clear_posedges;
	int max_fill_clear_negedges;
	int num_ovf_clear_posedges;
	int num_ovf_clear_negedges;

	initial begin
		logic prev_mfc = 1'b0;
		logic prev_noc = 1'b0;
		max_fill_clear_posedges = 0;
		max_fill_clear_negedges = 0;
		num_ovf_clear_posedges  = 0;
		num_ovf_clear_negedges  = 0;
		forever begin
			@(posedge tip_clk);
			if (!tip_rst) begin
				if (`CS_TIP.trTeTipFifoMaxFillClear && !prev_mfc)
					max_fill_clear_posedges++;
				if (!`CS_TIP.trTeTipFifoMaxFillClear && prev_mfc)
					max_fill_clear_negedges++;
				if (`CS_TIP.trTeTipFifoNumOverflowsClear && !prev_noc)
					num_ovf_clear_posedges++;
				if (!`CS_TIP.trTeTipFifoNumOverflowsClear && prev_noc)
					num_ovf_clear_negedges++;
				prev_mfc = `CS_TIP.trTeTipFifoMaxFillClear;
				prev_noc = `CS_TIP.trTeTipFifoNumOverflowsClear;
			end
		end
	end

	//========================================================================
	// Edge / pulse counter on the external-memory write interfaces that
	// carry watchpoint (act_st_wext) and df-range (df_range_wext) updates
	// from wb_clk into tip_clk. Inside vector_binary_search_2clk these
	// end up on the write port of a dual-clock BRAM whose read port runs
	// on tip_clk, so from the CDC point of view each SW value-word write
	// MUST produce exactly one wb_clk-wide {ce && we} pulse -- extra
	// pulses would corrupt the BRAM entry and dropped pulses would
	// leave the tip-side stale.
	//========================================================================
	int act_st_we_pulses;
	int df_range_we_pulses;

	initial begin
		logic prev_act_we = 1'b0;
		logic prev_df_we  = 1'b0;
		logic curr_act_we;
		logic curr_df_we;
		act_st_we_pulses   = 0;
		df_range_we_pulses = 0;
		forever begin
			@(posedge wb_clk);
			if (!wb_rst) begin
				curr_act_we = ct_encoder_inst.act_st_wext.ce   && ct_encoder_inst.act_st_wext.we;
				curr_df_we  = ct_encoder_inst.df_range_wext.ce && ct_encoder_inst.df_range_wext.we;
				if (curr_act_we && !prev_act_we) act_st_we_pulses++;
				if (curr_df_we  && !prev_df_we ) df_range_we_pulses++;
				prev_act_we = curr_act_we;
				prev_df_we  = curr_df_we;
			end
		end
	end

	task automatic test_tipfifo_clear_edge_count(input int pulses);
		int baseline_mfc_pos;
		int baseline_mfc_neg;
		int baseline_noc_pos;
		int baseline_noc_neg;

		baseline_mfc_pos = max_fill_clear_posedges;
		baseline_mfc_neg = max_fill_clear_negedges;
		baseline_noc_pos = num_ovf_clear_posedges;
		baseline_noc_neg = num_ovf_clear_negedges;

		for (int i = 0; i < pulses; i++) begin
			jitter();
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(1'b1);
			jitter();
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear(1'b1);
			settle_tip();
			jitter();
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(1'b0);
			jitter();
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear(1'b0);
			settle_tip();
		end

		// Exactly one rising edge and one falling edge per SW pulse.
		assert_wb_eq($sformatf("MaxFillClear rising edges (%0d pulses)", pulses),
			32'(pulses), 32'(max_fill_clear_posedges - baseline_mfc_pos));
		assert_wb_eq($sformatf("MaxFillClear falling edges (%0d pulses)", pulses),
			32'(pulses), 32'(max_fill_clear_negedges - baseline_mfc_neg));
		assert_wb_eq($sformatf("NumOverflowsClear rising edges (%0d pulses)", pulses),
			32'(pulses), 32'(num_ovf_clear_posedges - baseline_noc_pos));
		assert_wb_eq($sformatf("NumOverflowsClear falling edges (%0d pulses)", pulses),
			32'(pulses), 32'(num_ovf_clear_negedges - baseline_noc_neg));
	endtask

	// Very-short pulses: write 1 then 0 with only a sub-cycle of wb_clk
	// between them. A proper level-CDC (2-FF sync) may or may not
	// capture such a short level -- but whatever it does, it must not
	// generate MORE than one edge-pair per SW pulse.
	task automatic test_tipfifo_clear_short_pulses(input int pulses);
		int baseline_pos;
		int observed_pos;
		baseline_pos = max_fill_clear_posedges;
		for (int i = 0; i < pulses; i++) begin
			jitter();
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(1'b1);
			// no explicit settle: write 0 as fast as the WB master permits
			ct_cs_wb.Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(1'b0);
		end
		settle_tip();
		observed_pos = max_fill_clear_posedges - baseline_pos;
		// Must see at most one rising edge per SW pulse, never more.
		// (Dropped short pulses -- fewer observed -- are acceptable for
		// a level-CDC with a 2-FF sync; we only catch doubling here.)
		void'(tt_assert(observed_pos <= pulses,
			$sformatf("%0.2f: Line %0d: short-pulse stress: observed %0d rising edges for %0d SW pulses (double-trigger)",
				$realtime, `__LINE__, observed_pos, pulses)));
	endtask

	//========================================================================
	// Back-to-back burst with intermediate readbacks on a plain RW
	// register. Catches any variant of "APB master advanced but register
	// didn't latch" that a simple monotonic increment wouldn't: we read
	// back three times per write and ensure all three agree.
	//========================================================================
	task automatic test_filters_burst_with_readback(input int iterations);
		logic [31:0] rd0, rd1, rd2;
		logic [15:0] pattern;
		logic [31:0] expected;
		for (int i = 0; i < iterations; i++) begin
			pattern = 16'(i ^ (i << 5) ^ 16'h5A5A);
			jitter(); ct_cs_wb.Set_te_trTeInstFilters_Filters(pattern);
			jitter(); ct_cs_wb.Read_te_trTeInstFilters(rd0);
			jitter(); ct_cs_wb.Read_te_trTeInstFilters(rd1);
			jitter(); ct_cs_wb.Read_te_trTeInstFilters(rd2);
			expected = 32'(pattern);
			assert_wb_eq($sformatf("burst[%0d] rd0", i), expected, rd0);
			assert_wb_eq($sformatf("burst[%0d] rd1", i), expected, rd1);
			assert_wb_eq($sformatf("burst[%0d] rd2", i), expected, rd2);
		end
	endtask

	//========================================================================
	// Interleaved multi-domain CDC stress with a shadow model. On every
	// iteration we randomly pick one of the CDC-bearing fields, toggle
	// its model value, push it via WB, and occasionally settle and check
	// the destination-domain value against the model. This keeps several
	// independent CDC paths active simultaneously so they compete for
	// the APB bridge and for each domain's synchroniser chains.
	//========================================================================
	typedef enum int {
		SEL_ENABLE,
		SEL_INST_TRACING,
		SEL_DATA_TRACING,
		SEL_TS_ENABLE,
		SEL_TS_ACTIVE,
		SEL_TS_COUNT,
		SEL_NUM
	} cdc_sel_e;

	task automatic test_interleaved_cdc_stress(input int iterations, input int check_every);
		logic model_enable       = 1'b0;
		logic model_inst_tracing = 1'b0;
		logic model_data_tracing = 1'b0;
		logic model_ts_enable    = 1'b0;
		logic model_ts_active    = 1'b0;
		logic model_ts_count     = 1'b0;
		int which;

		for (int i = 0; i < iterations; i++) begin
			which = $urandom_range(0, SEL_NUM - 1);
			jitter();
			case (which)
				SEL_ENABLE: begin
					model_enable = ~model_enable;
					ct_cs_wb.Set_te_trTeControl_Enable(model_enable);
				end
				SEL_INST_TRACING: begin
					model_inst_tracing = ~model_inst_tracing;
					ct_cs_wb.Set_te_trTeControl_InstTracing(model_inst_tracing);
				end
				SEL_DATA_TRACING: begin
					model_data_tracing = ~model_data_tracing;
					ct_cs_wb.Set_te_trTeDataControl_DataTracing(model_data_tracing);
				end
				SEL_TS_ENABLE: begin
					model_ts_enable = ~model_ts_enable;
					ct_cs_wb.Set_te_trTsControl_Enable(model_ts_enable);
				end
				SEL_TS_ACTIVE: begin
					model_ts_active = ~model_ts_active;
					ct_cs_wb.Set_te_trTsControl_Active(model_ts_active);
				end
				SEL_TS_COUNT: begin
					model_ts_count = ~model_ts_count;
					ct_cs_wb.Set_te_trTsControl_Count(model_ts_count);
				end
			endcase

			if ((i % check_every) == (check_every - 1)) begin
				settle_tip();
				settle_proc();
				assert_tip_bit ("interleaved trTeEnable",      model_enable,       `CS_TIP.trTeEnable);
				assert_tip_bit ("interleaved trTeInstTracing", model_inst_tracing, `CS_TIP.trTeInstTracing);
				assert_tip_bit ("interleaved trTeDataTracing", model_data_tracing, `CS_TIP.trTeDataTracing);
				assert_proc_bit("interleaved trTsEnable",      model_ts_enable,    `CS_PROC.trTsEnable);
				assert_tip_bit ("interleaved trTsActive",      model_ts_active,    `CS_TIP.trTsActive);
				assert_tip_bit ("interleaved trTsCount",       model_ts_count,     `CS_TIP.trTsCount);
			end
		end

		// Final settle + full sweep.
		settle_tip();
		settle_proc();
		assert_tip_bit ("final trTeEnable",      model_enable,       `CS_TIP.trTeEnable);
		assert_tip_bit ("final trTeInstTracing", model_inst_tracing, `CS_TIP.trTeInstTracing);
		assert_tip_bit ("final trTeDataTracing", model_data_tracing, `CS_TIP.trTeDataTracing);
		assert_proc_bit("final trTsEnable",      model_ts_enable,    `CS_PROC.trTsEnable);
		assert_tip_bit ("final trTsActive",      model_ts_active,    `CS_TIP.trTsActive);
		assert_tip_bit ("final trTsCount",       model_ts_count,     `CS_TIP.trTsCount);

		// Leave all bits 0 so subsequent tests start from a clean state.
		jitter(); ct_cs_wb.Set_te_trTeControl_Enable      (1'b0);
		jitter(); ct_cs_wb.Set_te_trTeControl_InstTracing (1'b0);
		jitter(); ct_cs_wb.Set_te_trTeDataControl_DataTracing(1'b0);
		jitter(); ct_cs_wb.Set_te_trTsControl_Enable      (1'b0);
		jitter(); ct_cs_wb.Set_te_trTsControl_Active      (1'b0);
		jitter(); ct_cs_wb.Set_te_trTsControl_Count       (1'b0);
		settle_tip();
		settle_proc();
	endtask

	//========================================================================
	// TIP -> WB readback storm on the 64-bit timestamp counter.
	//
	// Path under test: ct_L23_preproc_ts -> cs_tip.trTeTs (64 b, tip_clk)
	//                  -> vector_cdc2#(DATA_WIDTH=64) in ct_cs_cpuif_wb
	//                  -> hwif_in.te.trTsCounter{High,Low}.Value.next
	//
	// vector_cdc2 uses a req/ack (gray / toggle) handshake to deliver a
	// coherent 64-bit snapshot to the wb_clk domain. If that handshake
	// tears the snapshot -- i.e. hands the wb side {H_new, L_old} or
	// similar -- a rapid stream of readbacks will show a 32-bit word
	// that goes BACKWARDS even though the source is monotonic.
	//
	// Test strategy:
	//   Phase 1: rapid reads of trTsCounterLow only. tip_clk=25 MHz and
	//            the counter ticks every tip_clk cycle at prescale=0,
	//            so within O(100 us) of sim time the low word cannot
	//            wrap (4 B ticks). Strict <=.
	//   Phase 2: same on trTsCounterHigh. The high word advances only
	//            after a low-word wrap; for this sim window it should
	//            stay at zero throughout -- any non-zero spike flags a
	//            handshake leaking stale bits.
	//   Phase 3: paired (Low, High) reads concatenated to a 64-bit
	//            value. Between a Low and the following High read the
	//            counter keeps ticking, but since no 32-bit wrap fits
	//            into our window, the composed value must be strictly
	//            monotonic; any backward step means either the CDC
	//            handshake tore a snapshot or the pipeline samples
	//            High and Low from disjoint windows.
	//========================================================================
	task automatic test_ts_counter_readback_storm(input int reads);
		logic [31:0] low;
		logic [31:0] high;
		logic [31:0] prev_low;
		logic [31:0] prev_high;
		logic [63:0] prev_composed;
		logic [63:0] curr_composed;
		logic [31:0] first_low;
		int max_high_value;

		// Configure the TS block: SYSTEM source, prescale=0 (tick every
		// cycle), then start it.
		jitter(); ct_cs_wb.Set_te_trTsControl_Type    (3'(ct_cs_cpuif__te__trTsControl__trTsType_e__TR_TS_SYSTEM));
		jitter(); ct_cs_wb.Set_te_trTsControl_Prescale(2'd0);
		jitter(); ct_cs_wb.Set_te_trTsControl_Reset   (1'b1);
		settle_tip();
		jitter(); ct_cs_wb.Set_te_trTsControl_Reset   (1'b0);
		jitter(); ct_cs_wb.Set_te_trTsControl_Active  (1'b1);
		jitter(); ct_cs_wb.Set_te_trTsControl_Count   (1'b1);
		jitter(); ct_cs_wb.Set_te_trTsControl_Enable  (1'b1);

		// Give the CDC enough wb cycles to propagate the first non-zero
		// snapshot before we start counting monotonicity from there.
		settle_tip();
		settle_proc();
		repeat (16) @(posedge wb_clk);

		// Phase 0: sanity -- after a few tip cycles the counter MUST be
		// non-zero. A zero read here usually means TsControl was not
		// actually armed through the CDC paths.
		ct_cs_wb.Read_te_trTsCounterLow(first_low);
		void'(tt_assert(first_low != 32'h0,
			$sformatf("%0.2f: Line %0d: TsCounter did not start (Low still %08h)",
				$realtime, `__LINE__, first_low)));

		// Phase 1: rapid Low-only storm, strictly non-decreasing.
		prev_low = first_low;
		for (int i = 0; i < reads; i++) begin
			ct_cs_wb.Read_te_trTsCounterLow(low);
			void'(tt_assert(low >= prev_low,
				$sformatf("%0.2f: Line %0d: Low[%0d] decreased across CDC: prev=%08h curr=%08h",
					$realtime, `__LINE__, i, prev_low, low)));
			prev_low = low;
		end

		// Phase 2: rapid High-only storm. Should stay at 0 for our
		// window; if it goes non-zero OR moves back to zero after
		// changing, the vector_cdc2 leaked half a snapshot.
		ct_cs_wb.Read_te_trTsCounterHigh(prev_high);
		max_high_value = int'(prev_high);
		for (int i = 0; i < reads; i++) begin
			ct_cs_wb.Read_te_trTsCounterHigh(high);
			void'(tt_assert(high >= prev_high,
				$sformatf("%0.2f: Line %0d: High[%0d] decreased across CDC: prev=%08h curr=%08h",
					$realtime, `__LINE__, i, prev_high, high)));
			prev_high = high;
			if (int'(high) > max_high_value) max_high_value = int'(high);
		end

		// Phase 3: paired (Low, High) reads, strict 64-bit monotonic
		// under the no-wrap assumption. Tear in the handshake would
		// deliver {H_old, L_new} or {H_new, L_old} inconsistently.
		ct_cs_wb.Read_te_trTsCounterLow (low);
		ct_cs_wb.Read_te_trTsCounterHigh(high);
		prev_composed = {high, low};
		for (int i = 0; i < reads; i++) begin
			ct_cs_wb.Read_te_trTsCounterLow (low);
			ct_cs_wb.Read_te_trTsCounterHigh(high);
			curr_composed = {high, low};
			void'(tt_assert(curr_composed >= prev_composed,
				$sformatf("%0.2f: Line %0d: composed[%0d] went backwards: prev=%016h curr=%016h",
					$realtime, `__LINE__, i, prev_composed, curr_composed)));
			prev_composed = curr_composed;
		end

		// Phase 4: same pattern, but with the read order inverted
		// (High first, then Low). Catches any read-order-dependent
		// pipelining in the regblock / bridge.
		ct_cs_wb.Read_te_trTsCounterHigh(high);
		ct_cs_wb.Read_te_trTsCounterLow (low);
		prev_composed = {high, low};
		for (int i = 0; i < reads; i++) begin
			ct_cs_wb.Read_te_trTsCounterHigh(high);
			ct_cs_wb.Read_te_trTsCounterLow (low);
			curr_composed = {high, low};
			// With High-first the composed value tends to lag by one
			// tick across the pair, so we weaken to "the low word's
			// 32-bit monotonic property holds" instead of pure 64-bit.
			void'(tt_assert(low >= prev_composed[31:0] || high > prev_composed[63:32],
				$sformatf("%0.2f: Line %0d: high-first composed[%0d] went backwards: prev=%016h curr=%016h",
					$realtime, `__LINE__, i, prev_composed, curr_composed)));
			prev_composed = curr_composed;
		end

		// Stop the counter for tidy downstream state.
		jitter(); ct_cs_wb.Set_te_trTsControl_Count  (1'b0);
		jitter(); ct_cs_wb.Set_te_trTsControl_Active (1'b0);
		jitter(); ct_cs_wb.Set_te_trTsControl_Enable (1'b0);
		settle_tip();
		settle_proc();

		$display("%0.2f: TsCounter storm done: %0d reads/phase, first_low=%08h, max_high=%0d",
			$realtime, reads, first_low, max_high_value);
	endtask

	//========================================================================
	// Watchpoints (ACT-ST) memory write interface stress.
	//
	// Write path: SW writes key at base+0 (latched into wb_clk register),
	// then value at base+4 -> triggers WrWatchpoints=1 for exactly one
	// wb_clk cycle -> drives act_st_wext.{ce,we,addr,d} -> consumed by
	// vector_binary_search_2clk's dual-clock BRAM whose read port runs
	// on tip_clk. So for each helper Write_..._ACT_ST(idx, 64b) call
	// the monitor MUST see exactly one posedge on (ce && we).
	//
	// Separately the shadow memory in wb_clk is written in lockstep and
	// exposed via RDL readback; Write / Read round-trip verifies the
	// dual-word regfile handling did not drop half of the payload.
	//========================================================================
	task automatic test_watchpoints_write_readback(input int iterations);
		logic [63:0] pattern;
		logic [63:0] rd;
		int base_pulses;
		int idx;
		base_pulses = act_st_we_pulses;
		for (int i = 0; i < iterations; i++) begin
			idx     = i % WATCHPOINTS_MEMORY_ACT_ST_NUM_ENTRIES;
			pattern = (64'h0123_4567_89AB_CDEF * (64'(i) + 64'd1))
					^ {32'hA5A5_5A5A, 32'(i)};
			jitter();
			ct_cs_wb.Write_Watchpoints_Memory_ACT_ST(idx, pattern);
			jitter();
			ct_cs_wb.Read_Watchpoints_Memory_ACT_ST(idx, rd);
			void'(tt_assert(rd === pattern,
				$sformatf("%0.2f: Line %0d: Watchpoint[%0d] readback mismatch: wr=%016h rd=%016h",
					$realtime, `__LINE__, idx, pattern, rd)));
		end
		// One write pulse per Write_Watchpoints_Memory_ACT_ST() call.
		// More pulses = doubled strobe corrupting the tip-side BRAM;
		// fewer = dropped write leaving tip-side stale.
		assert_wb_eq($sformatf("act_st_wext we pulses (%0d writes)", iterations),
			32'(iterations),
			32'(act_st_we_pulses - base_pulses));
	endtask

	//========================================================================
	// DF-range (mem1) memory write interface stress -- same shape as the
	// watchpoints path but feeds ct_L23_preproc_df_range instead.
	//
	// mem1 is sized via NUM_DF_RANGE (= 15, matching M1_DIM=4 ->
	// M1_N=2^4-1 comparator entries). The shadow in ct_cs_cpuif_wb
	// ends up 16 deep, of which 0..14 are RDL-addressable and 15 is
	// padding. Out-of-range accesses are rejected by the regfile
	// decoder and read as 0 (verified by test_df_range_oor_reads).
	//========================================================================
	task automatic test_df_range_write_readback(input int iterations);
		logic [63:0] pattern;
		logic [63:0] rd;
		int base_pulses;
		int idx;
		base_pulses = df_range_we_pulses;
		for (int i = 0; i < iterations; i++) begin
			// Hardware supports 15 range-comparator entries (M1_DIM=4).
			idx     = i % 15;
			pattern = (64'hDEAD_BEEF_CAFE_F00D * (64'(i) + 64'd1))
					^ {32'(i), 32'h5A5A_A5A5};
			jitter();
			ct_cs_wb.Write_DF_RangeFilter_Memory(idx, pattern);
			jitter();
			ct_cs_wb.Read_DF_RangeFilter_Memory(idx, rd);
			void'(tt_assert(rd === pattern,
				$sformatf("%0.2f: Line %0d: DfRange[%0d] readback mismatch: wr=%016h rd=%016h",
					$realtime, `__LINE__, idx, pattern, rd)));
		end
		assert_wb_eq($sformatf("df_range_wext we pulses (%0d writes)", iterations),
			32'(iterations),
			32'(df_range_we_pulses - base_pulses));
	endtask

	//========================================================================
	// Out-of-range read behaviour on DF-range. NUM_DF_RANGE=15 sizes
	// the memory to 15 entries; the RDL regfile decoder must reject
	// any WB access with an entry index >= 15 and return 0. This used
	// to come back with X / wrapped-entry content before the RDL was
	// fixed to align with the hardware.
	//========================================================================
	task automatic test_df_range_oor_reads();
		logic [63:0] pattern;
		logic [63:0] rd;
		int probe_idx[$] = '{15, 16, 31, 63, 128, 1023};
		foreach (probe_idx[i]) begin
			int unsigned ii = probe_idx[i];
			pattern = (64'hA5A5_5A5A_C001_CAFE * (64'(ii) + 64'd1))
					^ {32'(ii), 32'hCAFEBABE};
			jitter();
			ct_cs_wb.Write_DF_RangeFilter_Memory(ii, pattern);
			jitter();
			ct_cs_wb.Read_DF_RangeFilter_Memory(ii, rd);
			void'(tt_assert(rd === 64'h0,
				$sformatf("%0.2f: Line %0d: df_range out-of-range read at entry %0d should be 0, got %016h",
					$realtime, `__LINE__, ii, rd)));
		end
	endtask

	//========================================================================
	// Walking-1 / walking-0 bit coverage on the watchpoints entry. A
	// bit-swap / muxing bug in the 64-bit dual-word assembly or in the
	// RDL wiring would show as exactly one bit mismatch; a random
	// permuted pattern can hide those.
	//========================================================================
	task automatic test_watchpoints_walking_bits();
		logic [63:0] pattern;
		logic [63:0] rd;
		for (int b = 0; b < 64; b++) begin
			pattern = 64'b1 << b;
			jitter();
			ct_cs_wb.Write_Watchpoints_Memory_ACT_ST(0, pattern);
			jitter();
			ct_cs_wb.Read_Watchpoints_Memory_ACT_ST(0, rd);
			void'(tt_assert(rd === pattern,
				$sformatf("%0.2f: Line %0d: Watchpoint walking-1 bit %0d: wr=%016h rd=%016h",
					$realtime, `__LINE__, b, pattern, rd)));
		end
		for (int b = 0; b < 64; b++) begin
			pattern = ~(64'b1 << b);
			jitter();
			ct_cs_wb.Write_Watchpoints_Memory_ACT_ST(0, pattern);
			jitter();
			ct_cs_wb.Read_Watchpoints_Memory_ACT_ST(0, rd);
			void'(tt_assert(rd === pattern,
				$sformatf("%0.2f: Line %0d: Watchpoint walking-0 bit %0d: wr=%016h rd=%016h",
					$realtime, `__LINE__, b, pattern, rd)));
		end
	endtask

	//========================================================================
	// Main
	//========================================================================
	initial begin
		tip_dir.itype      = OTHER;
		tip_dir.ecause     = ECAUSE_NONE;
		tip_dir.tval       = '0;
		tip_dir.priv       = '0;
		tip_dir.iaddr      = '0;
		tip_dir._context   = '0;
		tip_dir.ctype      = UNREPORTED;
		tip_dir.iretire    = '0;
		tip_dir.ilastsize  = '0;
		tip_dir.impdef     = '0;
		tip_dir.dretire    = '0;
		tip_dir.dtype      = LOAD;
		tip_dir.daddr      = '0;
		tip_dir.dsize      = '0;
		tip_dir.data       = '0;
		tip_dir.sdata      = '0;
		tip_dir.lresp      = '0;
		tip_dir.ldata      = '0;
	end

	initial begin
		int timeout_cycles;

		// Asynchronous asserts
		tip_rst      <= 1'b1;
		proc_rst     <= 1'b1;
		wb_rst       <= 1'b1;
		ct_cs_rst    <= 1'b1;
		wall_clk_rst <= 1'b1;
		atb_atresetn <= 1'b0;

		timeout_cycles = 200000;
		void'($value$plusargs("CT_TIMEOUT_CYCLES=%d", timeout_cycles));
		$display("%0.2f: wb_cdc TB start: CT_TIMEOUT_CYCLES=%0d", $realtime, timeout_cycles);

		// Release resets in each domain, staggered by that domain's own
		// posedge so CDC synchronisers initialise cleanly.
		@(posedge tip_clk);  tip_rst      <= 1'b0;
		@(posedge proc_clk); proc_rst     <= 1'b0;
		@(posedge wb_clk);   wb_rst       <= 1'b0;
		@(posedge wb_clk);   ct_cs_rst    <= 1'b0;
		@(posedge wall_clk); wall_clk_rst <= 1'b0;
		@(posedge atb_atclk);atb_atresetn <= 1'b1;

		// Wait for all synchroniser chains to be out of reset before
		// starting real stimuli.
		settle_tip();
		settle_proc();

		$display("%0.2f: ct_tb__wb_cdc: shadow depths -- WATCHPOINTS_DEPTH=%0d MEM1_DEPTH=%0d (WrAddrMem1 width=%0d)",
			$realtime,
			ct_encoder_inst.ct_cs_cpuif_wb_inst.WATCHPOINTS_DEPTH,
			ct_encoder_inst.ct_cs_cpuif_wb_inst.MEM1_DEPTH,
			$bits(ct_encoder_inst.ct_cs_cpuif_wb_inst.WrAddrMem1));

		// 0) Pure-WB sanity (no CDC): fails unambiguously attributable
		// to the regfile / bridge, not to CDC shims.
		test_pure_wb_roundtrip();

		// 1) Single-bit wb -> tip CDC paths.
		test_enable_cdc(1'b1);
		test_enable_cdc(1'b0);
		test_enable_cdc(1'b1);

		// 2) Bidirectional hwif-ext CDC (strobe hwset/hwclr + value feedback).
		test_inst_tracing_cdc(1'b1);
		test_inst_tracing_cdc(1'b0);
		test_data_tracing_cdc(1'b1);
		test_data_tracing_cdc(1'b0);

		// 3) Timestamp control CDC paths in multiple domains.
		test_ts_enable_cdc(1'b1);
		test_ts_active_cdc(1'b1);
		test_ts_count_cdc(1'b1);
		test_ts_count_cdc(1'b0);
		test_ts_active_cdc(1'b0);
		test_ts_enable_cdc(1'b0);

		// 4) Level-triggered clear bits (SW 1 -> 0 pulse).
		test_tipfifo_max_fill_clear_cdc();
		test_tipfifo_num_overflows_clear_cdc();

		// 5) Short-burst hammer tests to chase edge-coincidence hazards.
		test_enable_burst(64);
		test_inst_tracing_burst(64);

		// 6) Missed-ack / silently-dropped-write detection on plain RW
		// registers with readback after each write.
		test_inst_filters_incremental(256);
		test_data_filters_incremental(256);

		// 7) Back-to-back burst with triple-readback per write -- traps
		// intermittent bridge anomalies that a single readback might let
		// through.
		test_filters_burst_with_readback(128);

		// 8) Pulse-shape / idempotency on the two TIP-FIFO clear bits.
		// If anything accidentally treats these as strobes or glitches
		// a second time, the edge counter will disagree with the number
		// of SW pulses we drove.
		test_tipfifo_clear_edge_count(64);
		test_tipfifo_clear_short_pulses(64);

		// 9) Large-scale interleaved multi-domain stress with shadow
		// model. 1000 iterations; full sweep every 16 writes.
		test_interleaved_cdc_stress(1000, 16);

		// 10) 1000-write back-to-back Enable hammer.
		test_enable_burst(1000);

		// 11) TIP -> WB readback storm on the 64-bit TsCounter via
		// vector_cdc2. Only path in the shim we haven't exercised
		// yet; specifically looks for word-tearing in the req/ack
		// handshake of the coherent-snapshot CDC.
		test_ts_counter_readback_storm(1000);

		// 12) Watchpoints (ACT-ST) and DF-range (mem1) memory write
		// interfaces. These carry SW configuration across wb_clk ->
		// tip_clk into dual-clock BRAMs via a strict one-pulse-per-
		// write protocol on ce/we. Edge counter enforces the pulse
		// count; round-trip shadow readback enforces payload.
		test_watchpoints_write_readback(256);
		test_df_range_write_readback(256);
		test_watchpoints_walking_bits();
		test_df_range_oor_reads();

		// Final consistent state: Enable=0 so the swwe gate reopens.
		jitter();
		ct_cs_wb.Set_te_trTeControl_Enable(1'b0);
		settle_tip();
		assert_tip_bit("trTeEnable final", 1'b0, `CS_TIP.trTeEnable);

		repeat (10) @(posedge wb_clk);

		tt_evaluate();
		$finish();
	end

	`undef CS_TIP
	`undef CS_PROC

endmodule
