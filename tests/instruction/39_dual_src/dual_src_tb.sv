// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Two encoders, two SrcIDs, one funnel -- and the merged stream is
 *           taken apart again.
 *
 * @details
 *   THE GAP THIS CLOSES. Until this testbench existed, no unit-level test in
 *   this repository instantiated two encoders with DIFFERENT
 *   trTeInstFeatures.SrcID, and `SrcBits = 2` -- the width every demonstrator
 *   uses (duo, trio, rocket2, cva6_2) -- appeared in no test at all. The
 *   combination "SRC emission + funnel merge + decoder separation" was
 *   exercised only at whole-SoC level, where a failure has many possible
 *   causes. The analysis is an internal audit document (2026-08-19, not part
 *   of this repository; cited below as "L" -- §4.2 and §5, points 4 and 5).
 *
 *   WHY THE TWO PROGRAMS DIFFER, and why that is the whole point. A capture in
 *   which both sources run the SAME code at the SAME addresses cannot prove
 *   anything about separation: a decoder that evaluates SRC perfectly and one
 *   that ignores it produce the same answer, so the test cannot fail (measured
 *   on the board capture c2_rv32.bin -- 106 222 messages that differ in exactly
 *   ONE bit per message, L §3.3/§3.4). The two cpu_models here therefore run
 *   DIFFERENT programs at DISJOINT addresses:
 *
 *     source 0 (SrcID 0): base 0x0000_7000, direct branches, call/return
 *     source 1 (SrcID 1): base 0x2000_0000, indirect jumps, taken branches
 *
 *   Each model writes its own PCInfo and its own expected-PC list, so
 *   scripts/cli_dualsrc_test.sh can require that EACH half of the merged
 *   stream matches the sequence of ITS OWN source -- not merely that it is
 *   well formed. Swapped, merged or ignored source identities all show up as a
 *   PC sequence that belongs to nobody.
 *
 *   WHAT RUNS AT THE SAME TIME. Both workloads are started in one `fork ...
 *   join`, so the two encoders push messages into the funnel in the same
 *   cycles; both channels sit at priority 1, which is the round-robin case the
 *   demonstrators configure (FUNNEL_CTRL = 0x11). The gate script measures how
 *   often the merged stream actually alternates between the two sources and
 *   holds a floor on it -- an interleaving that stopped happening would make
 *   the separation trivially true.
 *
 *   The configuration is the demonstrators' one, not a convenient one:
 *   SrcBits = 2, SrcID 0 / 1, InhibitSrc = 0, funnel MDO_WIDTH = 6 (four byte
 *   chunks per beat), N_STREAMS = 2, MAX_PRIO = 3, both channels priority 1.
 *
 *   Artefacts (simulator CWD), all consumed by scripts/cli_dualsrc_test.sh:
 *     dual_src_tb.merged.bin             funnel output -- the stream under test
 *     dual_src_tb.src0.bin               encoder 0 output alone (equivalence leg)
 *     dual_src_tb.src1.bin               encoder 1 output alone
 *     dual_src_tb.src{0,1}.info          per-source PCInfo for the decoder
 *     dual_src_tb.src{0,1}.expected.pcs  per-source reference PC sequence
 */

module dual_src_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;
	import atb_pkg::*;

	localparam int WB_DATA_WIDTH = 32;
	localparam int WB_ADDR_WIDTH = 32;

	localparam int N_STREAMS = 2;
	localparam int MAX_PRIO  = 3;
	localparam int MDO_WIDTH = 6;    // the demonstrators' chunk width

	// Disjoint address ranges -- see the header: two sources that execute the
	// same code at the same addresses cannot falsify anything.
	localparam logic [31:0] PC_A = 32'h0000_7000;
	localparam logic [31:0] PC_B = 32'h2000_0000;

	localparam logic [3:0]  SRC_BITS = 4'd2;   // duo / trio / rocket2 / cva6_2
	localparam logic [11:0] SRC_ID_A = 12'd0;
	localparam logic [11:0] SRC_ID_B = 12'd1;

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd4;

	localparam int WORKLOAD_ROUNDS = 10;

	// ------------------------------------------------------------------
	// Clocks / resets -- ONE set for both encoders, as in every SoC that
	// merges two encoders into one funnel (the funnel is single-clock by
	// construction). Rates as in tests/lib/ct_env.sv.
	// ------------------------------------------------------------------
	logic tip_clk      = 0;
	logic atb_atclk    = 0;
	logic proc_clk     = 0;
	logic wb_clk       = 0;
	logic wall_clk     = 0;

	initial forever #5ns tip_clk   = ~tip_clk;
	initial forever #2ns atb_atclk = ~atb_atclk;
	initial forever #2ns proc_clk  = ~proc_clk;
	initial forever #5ns wb_clk    = ~wb_clk;
	initial forever #5ns wall_clk  = ~wall_clk;

	logic tip_rst      = 1;
	logic atb_atresetn = 0;
	logic proc_rst     = 1;
	logic wb_rst       = 1;
	logic ct_cs_rst    = 1;
	logic wall_clk_rst = 1;

	initial begin
		#80ns;
		@(posedge tip_clk);   tip_rst      <= 0;
		@(posedge atb_atclk); atb_atresetn <= 1;
		@(posedge proc_clk);  proc_rst     <= 0;
		@(posedge wb_clk);    wb_rst       <= 0;
		@(posedge wb_clk);    ct_cs_rst    <= 0;
		@(posedge wall_clk);  wall_clk_rst <= 0;
	end

	// ------------------------------------------------------------------
	// Interfaces -- one set per encoder, plus the merged ATB
	// ------------------------------------------------------------------
	tip_if  tip_a ();
	tip_if  tip_b ();
	wb_if  #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_ADDR_WIDTH)) wb_a ();
	wb_if  #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_ADDR_WIDTH)) wb_b ();
	axis_if #(.TDATA_WIDTH(ct_pkg::ACT_CAP_AXIS_TDATA_WIDTH)) axis_a (.aclk(wb_clk), .aresetn(~wb_rst));
	axis_if #(.TDATA_WIDTH(ct_pkg::ACT_CAP_AXIS_TDATA_WIDTH)) axis_b (.aclk(wb_clk), .aresetn(~wb_rst));
	atb_if  atb_src [N_STREAMS] ();
	atb_if  atb_mrg ();

	uwire logic te_raw_a;
	uwire logic te_raw_b;

	// ------------------------------------------------------------------
	// DUTs -- two encoders out of the same sources; the identity that
	// separates them is a CSR, not an elaboration parameter.
	//
	// CORE_XLEN (P0-07): both TIPs are driven by cpu_model, whose addresses
	// are tip_pkg types -- the model hart IS the netlist width. Same waiver
	// as tests/lib/ct_env.sv, tracked by scripts/check_core_xlen.py.
	// ------------------------------------------------------------------
	ct_encoder #(.CORE_XLEN(ct_pkg::CT_XLEN)) enc_a (
		.tip_clk   (tip_clk),    .tip_rst      (tip_rst),      .tip (tip_a),
		.wb_clk    (wb_clk),     .wb_rst       (wb_rst),       .wb  (wb_a),
		.ct_cs_rst (ct_cs_rst),
		.axis      (axis_a),
		.atb_atclk (atb_atclk),  .atb_atresetn (atb_atresetn),
		.atb       (atb_src[0]), .atb_te_raw   (te_raw_a),
		.proc_clk  (proc_clk),   .proc_rst     (proc_rst),
		.wall_clk  (wall_clk),   .wall_clk_rst (wall_clk_rst)
	);

	ct_encoder #(.CORE_XLEN(ct_pkg::CT_XLEN)) enc_b (
		.tip_clk   (tip_clk),    .tip_rst      (tip_rst),      .tip (tip_b),
		.wb_clk    (wb_clk),     .wb_rst       (wb_rst),       .wb  (wb_b),
		.ct_cs_rst (ct_cs_rst),
		.axis      (axis_b),
		.atb_atclk (atb_atclk),  .atb_atresetn (atb_atresetn),
		.atb       (atb_src[1]), .atb_te_raw   (te_raw_b),
		.proc_clk  (proc_clk),   .proc_rst     (proc_rst),
		.wall_clk  (wall_clk),   .wall_clk_rst (wall_clk_rst)
	);

	// ------------------------------------------------------------------
	// Stimulus -- two DIFFERENT programs (see header)
	// ------------------------------------------------------------------
	cpu_model #(
		.CYCLES_PER_INSTR  (2),
		.NEXRV_INFO_PATH   ("dual_src_tb.src0.info"),
		.EXPECTED_PCS_PATH ("dual_src_tb.src0.expected.pcs")
	) cpu_a (.clk (tip_clk), .rst (tip_rst), .tip (tip_a.master));

	cpu_model #(
		.CYCLES_PER_INSTR  (2),
		.NEXRV_INFO_PATH   ("dual_src_tb.src1.info"),
		.EXPECTED_PCS_PATH ("dual_src_tb.src1.expected.pcs")
	) cpu_b (.clk (tip_clk), .rst (tip_rst), .tip (tip_b.master));

	ct_cs_cpuif_wb_helper csr_a (.clk (wb_clk), .wb (wb_a.master));
	ct_cs_cpuif_wb_helper csr_b (.clk (wb_clk), .wb (wb_b.master));

	// ------------------------------------------------------------------
	// The funnel, in the demonstrators' configuration
	// ------------------------------------------------------------------
	logic [$clog2(MAX_PRIO+1)-1:0] chan_prio              [N_STREAMS];
	logic                          chan_flush_participate [N_STREAMS];
	logic                          chan_flush_req         [N_STREAMS];
	logic                          chan_te_raw            [N_STREAMS];
	logic                          chan_flush_done        [N_STREAMS];
	logic                          global_flush_req = 1'b0;
	logic                          global_flush_done;

	initial begin
		int i;
		for (i = 0; i < N_STREAMS; i = i + 1) begin
			chan_prio[i]              = 2'd1;   // both prio 1 == round robin
			chan_flush_participate[i] = 1'b1;
			chan_flush_req[i]         = 1'b0;
			chan_te_raw[i]            = 1'b0;   // Nexus MSEO on both channels
		end
	end

	ct_L1_funnel #(
		.N_STREAMS (N_STREAMS),
		.MAX_PRIO  (MAX_PRIO),
		.MDO_WIDTH (MDO_WIDTH)
	) funnel (
		.atclk    (atb_atclk),
		.atresetn (atb_atresetn),
		.chan_prio,
		.chan_flush_participate,
		.chan_flush_req,
		.chan_te_raw,
		.te_tag_always (1'b0),
		.te_tag_resync (1'b0),
		.global_flush_req,
		.chan_flush_done,
		.global_flush_done,
		.atb_in  (atb_src),
		.atb_out (atb_mrg)
	);

	// Always-ready sink on the merged side, exactly as the SoC ring does
	// (examples/kv260/duo/rtl/duo_soc_top.sv:355-357): the flush runs via
	// global_flush_req.
	assign atb_mrg.atready = 1'b1;
	assign atb_mrg.afvalid = 1'b0;
	assign atb_mrg.syncreq = 1'b0;
	assign axis_a.tready   = 1'b1;
	assign axis_b.tready   = 1'b1;

	// ------------------------------------------------------------------
	// Recorders. The merged file is the stream under test; the two
	// per-source files give the gate an equivalence leg ("the merged stream
	// filtered by SRC decodes to what that source produced alone").
	// ------------------------------------------------------------------
	atb_dump #(.FILEPATH("dual_src_tb.merged.bin")) rec_mrg (
		.atb_atclk, .atb_atresetn, .atb (atb_mrg.monitor));
	atb_dump #(.FILEPATH("dual_src_tb.src0.bin")) rec_src0 (
		.atb_atclk, .atb_atresetn, .atb (atb_src[0].monitor));
	atb_dump #(.FILEPATH("dual_src_tb.src1.bin")) rec_src1 (
		.atb_atclk, .atb_atresetn, .atb (atb_src[1].monitor));

	int merged_beats = 0;
	always_ff @(posedge atb_atclk) begin
		if (atb_atresetn && atb_mrg.atvalid && atb_mrg.atready) begin
			merged_beats <= merged_beats + 1;
		end
	end

	// ------------------------------------------------------------------
	// Scenario
	// ------------------------------------------------------------------
	task automatic arm_encoder_a(input logic [11:0] srcid);
		csr_a.clear();
		csr_a.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		csr_a.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		// SrcBits / SrcID / InhibitSrc are swwel-gated by Enable, so they are
		// written BEFORE the encoder goes live (rdl/ct_cs_cpuif.rdl:1883,
		// 1888,1889 -- the trap L §2.1 F3).
		csr_a.Set_te_trTeInstFeatures_SrcBits (SRC_BITS);
		csr_a.Set_te_trTeInstFeatures_SrcID   (srcid);
		csr_a.Set_te_trTeControl_InhibitSrc   (1'b0);
		csr_a.Set_te_trTeControl_Enable       (1'b1);
		csr_a.Set_te_trTeControl_InstTracing  (1'b1);
		csr_a.Set_te_trTeControl_Active       (1'b1);
	endtask

	task automatic arm_encoder_b(input logic [11:0] srcid);
		csr_b.clear();
		csr_b.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		csr_b.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		csr_b.Set_te_trTeInstFeatures_SrcBits (SRC_BITS);
		csr_b.Set_te_trTeInstFeatures_SrcID   (srcid);
		csr_b.Set_te_trTeControl_InhibitSrc   (1'b0);
		csr_b.Set_te_trTeControl_Enable       (1'b1);
		csr_b.Set_te_trTeControl_InstTracing  (1'b1);
		csr_b.Set_te_trTeControl_Active       (1'b1);
	endtask

	// Program A: direct branches, call/return -- base PC_A.
	task automatic workload_a();
		int r;
		cpu_a.enter(.start_pc(PC_A));
		for (r = 0; r < WORKLOAD_ROUNDS; r = r + 1) begin
			cpu_a.run(16);
			cpu_a.branch_taken(.target(PC_A + 32'h100));
			cpu_a.run(12);
			cpu_a.call_to(.target(PC_A + 32'h400));
			cpu_a.run(8);
			cpu_a.ret();
			cpu_a.run(12);
			cpu_a.branch_not_taken();
			cpu_a.run(20);
			cpu_a.branch_taken(.target(PC_A + 32'h040));
			cpu_a.run(16);
		end
		cpu_a.exit_trace();
	endtask

	// Program B: indirect jumps and a different branch pattern -- base PC_B.
	task automatic workload_b();
		int r;
		cpu_b.enter(.start_pc(PC_B));
		for (r = 0; r < WORKLOAD_ROUNDS; r = r + 1) begin
			cpu_b.run(8);
			cpu_b.uninferable_jump(.target(PC_B + 32'h800));
			cpu_b.run(24);
			cpu_b.branch_taken(.target(PC_B + 32'h840));
			cpu_b.run(4);
			cpu_b.branch_taken(.target(PC_B + 32'h8C0));
			cpu_b.run(28);
			cpu_b.uninferable_jump(.target(PC_B + 32'h900));
			cpu_b.run(12);
			cpu_b.branch_not_taken();
			cpu_b.run(8);
		end
		cpu_b.exit_trace();
	endtask

	initial begin
		$display("[dual_src_tb] %0t: waiting for reset release", $time);
		wait (tip_rst      == 1'b0);
		wait (proc_rst     == 1'b0);
		wait (atb_atresetn == 1'b1);
		wait (wb_rst       == 1'b0);
		wait (ct_cs_rst    == 1'b0);
		wait (wall_clk_rst == 1'b0);
		repeat (4) @(posedge tip_clk);
		$display("[dual_src_tb] %0t: reset released", $time);

		fork
			arm_encoder_a(SRC_ID_A);
			arm_encoder_b(SRC_ID_B);
		join
		$display("[dual_src_tb] %0t: both encoders armed (SrcBits=%0d, SrcID %0d / %0d)",
			$time, SRC_BITS, SRC_ID_A, SRC_ID_B);

		fork
			cpu_a.idle(20);
			cpu_b.idle(20);
		join

		// The point of this testbench: BOTH sources retire in the same
		// cycles, so the funnel really has to arbitrate.
		fork
			workload_a();
			workload_b();
		join
		$display("[dual_src_tb] %0t: both workloads done (events: %0d / %0d)",
			$time, cpu_a.event_count(), cpu_b.event_count());

		// ---- drain -----------------------------------------------------
		fork
			cpu_a.idle(50);
			cpu_b.idle(50);
		join
		csr_a.Set_te_trTeControl_InstTracing (1'b0);
		csr_b.Set_te_trTeControl_InstTracing (1'b0);
		fork
			cpu_a.idle(200);
			cpu_b.idle(200);
		join
		csr_a.Set_te_trTeControl_Enable (1'b0);
		csr_b.Set_te_trTeControl_Enable (1'b0);
		global_flush_req = 1'b1;
		fork
			cpu_a.idle(4000);
			cpu_b.idle(4000);
		join
		global_flush_req = 1'b0;
		csr_a.Set_te_trTeControl_Active (1'b0);
		csr_b.Set_te_trTeControl_Active (1'b0);
		fork
			cpu_a.idle(2000);
			cpu_b.idle(2000);
		join

		if (cpu_a.event_count() == 0 || cpu_b.event_count() == 0)
			$error("[dual_src_tb] a cpu_model event log is empty (%0d / %0d)",
				cpu_a.event_count(), cpu_b.event_count());
		if (merged_beats == 0)
			$error("[dual_src_tb] the funnel emitted no beat at all");
		else
			$display("[dual_src_tb] merged stream: %0d beats", merged_beats);

		$display("[dual_src_tb] PASS (sim); the separation is judged by scripts/cli_dualsrc_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[dual_src_tb] TIMEOUT");
		$finish;
	end

endmodule : dual_src_tb

`default_nettype wire
