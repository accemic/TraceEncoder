// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    AXIS watchpoint testbed top: 2x TGC5B, each with its own CTTE
 *           instance, one ct_axis_wp_shim per encoder AXIS, ct_L1_funnel +
 *           trace ring as the N-Trace capture (package C1,
 *           docs/PLAN_axis_wp_testbed.md §3a).
 *
 * @details
 *   Built after the duo_soc_top pattern (AXI4-Lite front end, loader mux and
 *   segment decode carried over 1:1), but both branches are TGC5B:
 *
 *     soc0/soc1  tgc5b_wp_synth_wrap  TGC5B + H2E adapter + ct_encoder
 *                                     (SPLIT=1), local wrapper copy with an
 *                                     external time_i (shared time base)
 *     shim0/1    ct_axis_wp_shim      CORE_ID 0/1, FIFO_DEPTH 256; 96-bit
 *                                     encoder AXIS -> 4x32-bit records with
 *                                     drop counter (the encoder never samples
 *                                     tready)
 *     funnel     ct_L1_funnel         N_STREAMS=2, MDO_WIDTH=6, EN_TE_RAW=0;
 *                                     source: rtl/ct_L1_funnel.sv (this
 *                                     repository's own copy, the delta version
 *                                     with chan_te_raw/te_tag_*; instantiation
 *                                     pattern: cva6_2_soc_synth_wrap).
 *                                     The predecessor repository also carried
 *                                     a second, upstream copy with
 *                                     LOGICAL_CHUNK_W=32 that still merged
 *                                     incorrectly -- that copy does not exist
 *                                     in this tree.
 *     sinks      ct_trace_sinks       T2: the shared three-sink subsystem at
 *                                     the funnel output -- 1 MiB URAM ring
 *                                     (like duo; before T2 only 256 KiB) +
 *                                     DDR4 sink (D2, AXI4 master m_axi_*) +
 *                                     PIB (parallel 4-bit DDR port pib_clk/
 *                                     pib_data, KV260 PMOD J2); additive
 *                                     observers, reset-inert
 *
 *   Shared time base: ONE free-running 64-bit fabric counter feeds both
 *   time_i inputs (-> tip._time -> TR_TS_CORE of both encoders) -- FINDINGS
 *   Teil C0 §4. Each core keeps its own mtime (CLINT in the wrapper).
 *
 *   The shim master AXIS (32 bit) plus drop_count/overflow_sticky/fill_level
 *   go out as flat top ports -- the MM-FIFO attachment (axi_fifo_mm_s) is
 *   package D1, the sim testbench hangs directly off the ports.
 *
 *   Address map (22-bit aperture, like duo_soc_top but without the AXIS
 *   capture window -- the AXIS path runs through the shims, not through a
 *   capture BRAM):
 *     0x00_0000  CTRL   CONTROL, STATUS, TRACE_BEATS/BYTES/BUFSZ
 *     0x01_0000  ENC0   CTTE CSRs, encoder core 0   (ct_axil_to_wb)
 *     0x02_0000  ENC1   CTTE CSRs, encoder core 1   (ct_axil_to_wb)
 *     0x08_0000  RAM1   TGC5B-1 program/data RAM (64 KiB; load while core1_run=0)
 *     0x10_0000  RAM0   TGC5B-0 program/data RAM (64 KiB; load while core0_run=0)
 *     0x20_0000  TRACE  merged ATB ring
 *
 *   CTRL:
 *     0x00 CONTROL (rw) b0 core_run (collective bit: BOTH cores)  b1 trace_clear
 *                       b2 trace_flush (global funnel flush)
 *                       b8 core0_run  b9 core1_run (U1: per-core, individually;
 *                       effective run state is b0 OR the core bit -- the two
 *                       cores have nothing to do with each other, no SMP)
 *                       Loader contract PER CORE: only write RAM_i while
 *                       core_i_run=0; an access to a RUNNING core's RAM never
 *                       gets ready and hangs the transaction (behavior
 *                       unchanged, just now per-core -- SPEC_axis_wp_memory_map.md §10)
 *     0x04 STATUS  (ro) b0 trace_overflow (ring wrapped)
 *                       b8 core0 running  b9 core1 running (effective state)
 *     0x08 TRACE_BEATS  (ro)
 *     0x0C TRACE_BYTES  (ro)
 *     0x10 TRACE_BUFSZ  (ro) bytes
 *
 *   CTRL extension T2 (shared sink window 0x18..0x38 in ct_trace_sinks, same
 *   offsets as duo_soc_top; SPEC_axis_wp_memory_map.md §9; replaces the D2
 *   single-sink wiring -- BREAKING vs. the C0B_DDR build: DDR_BEATS moved
 *   from 0x30 to 0x38, 0x30 is now PIB_DROPS):
 *     0x18 SINK_CTRL  (rw) b0 ddr_en  b1 ddr_clear (pulse)  b2 ddr_circ
 *                          b3 uram_oneshot  b4 pib_en  b5 pib_clear (pulse)
 *                          b6 pib_calib  b[10:8] pib_div  b[13:12] pib_pattern
 *     0x1C DDR_BASE   (rw) Reset 0x5000_0000 (resmem window, no-map;
 *                          address plan v4 = rocket2 window, U6)
 *     0x20 DDR_SIZE   (rw) Reset 0x1000_0000 (256 MiB, U6); ddr_en stays 0.
 *                          Base/size writable only while ddr_en=0
 *     0x24 DDR_WPTR   (ro) bytes written TOTAL (monotonic)
 *     0x28 SINK_STAT  (ro) b0 ddr_full  b1 ddr_axi_err  b2 ddr_wrapped
 *                          b3 uram_stopped  b4 ddr_cfg_rej (window write
 *                          rejected while the sink is armed, U6)
 *     0x2C DDR_DROPS  (ro) dropped beats (saturating)
 *     0x30 PIB_DROPS  (ro) dropped beats (saturating)
 *     0x38 DDR_BEATS  (ro) ATB beats offered to the sink since ddr_en (proof
 *                          that "beats reach the sink"; clear via ddr_clear)
 *
 *   Source separation in the merged stream: Nexus SRC field via CSR
 *   (trTeControl.InhibitSrc=0 + trTeInstFeatures.SrcID/SrcBits per instance,
 *   pure software). Funnel priority is fixed round-robin (both 1) -- this
 *   testbed does not need the duo top's FUNNEL_CTRL runtime control.
 */
module tgc5b2_axis_soc_top #(
	int unsigned MEM_WORDS      = 16384,     // per core: 64 KiB
	int unsigned TRACE_DEPTH    = 262144,    // ring capacity in beats (1 MiB URAM, like duo -- T2)
	int unsigned SHIM_FIFO_DEPTH = 256,      // records per shim (D0 contract)
	string       MEM_INIT_FILE0 = "",        // $readmemh image, core 0
	string       MEM_INIT_FILE1 = ""         // $readmemh image, core 1
) (
	input  uwire logic        clk,
	input  uwire logic        resetn,

	input  uwire logic [21:0] s_axi_awaddr,
	input  uwire logic [2:0]  s_axi_awprot,
	input  uwire logic        s_axi_awvalid,
	output      logic         s_axi_awready,
	input  uwire logic [31:0] s_axi_wdata,
	input  uwire logic [3:0]  s_axi_wstrb,
	input  uwire logic        s_axi_wvalid,
	output      logic         s_axi_wready,
	output      logic [1:0]   s_axi_bresp,
	output      logic         s_axi_bvalid,
	input  uwire logic        s_axi_bready,
	input  uwire logic [21:0] s_axi_araddr,
	input  uwire logic [2:0]  s_axi_arprot,
	input  uwire logic        s_axi_arvalid,
	output      logic         s_axi_arready,
	output      logic [31:0]  s_axi_rdata,
	output      logic [1:0]   s_axi_rresp,
	output      logic         s_axi_rvalid,
	input  uwire logic        s_axi_rready,

	// -- WP record streams of both shims (D1 hangs axi_fifo_mm_s here) --
	output      logic         m0_axis_tvalid,
	input  uwire logic        m0_axis_tready,
	output      logic [31:0]  m0_axis_tdata,
	output      logic [3:0]   m0_axis_tkeep,
	output      logic         m0_axis_tlast,
	output      logic [31:0]  shim0_drop_count,
	output      logic         shim0_overflow_sticky,
	output      logic [31:0]  shim0_fill_level,

	output      logic         m1_axis_tvalid,
	input  uwire logic        m1_axis_tready,
	output      logic [31:0]  m1_axis_tdata,
	output      logic [3:0]   m1_axis_tkeep,
	output      logic         m1_axis_tlast,
	output      logic [31:0]  shim1_drop_count,
	output      logic         shim1_overflow_sticky,
	output      logic [31:0]  shim1_fill_level,

	// -- DDR4 sink: AXI4 write-only master (to PS S_AXI_HP*_FPD, duo pattern) --
	output      logic [31:0]  m_axi_awaddr,
	output      logic [7:0]   m_axi_awlen,
	output      logic [2:0]   m_axi_awsize,
	output      logic [1:0]   m_axi_awburst,
	output      logic         m_axi_awvalid,
	input  uwire logic        m_axi_awready,
	output      logic [31:0]  m_axi_wdata,
	output      logic [3:0]   m_axi_wstrb,
	output      logic         m_axi_wlast,
	output      logic         m_axi_wvalid,
	input  uwire logic        m_axi_wready,
	input  uwire logic [1:0]  m_axi_bresp,
	input  uwire logic        m_axi_bvalid,
	output      logic         m_axi_bready,

	// -- PIB: parallel trace port (source-synchronous, DDR nibbles; T2) -------
	output      logic         pib_clk,
	output      logic [3:0]   pib_data
);

	localparam logic [1:0] RESP_OKAY = 2'b00;

	uwire logic rst = ~resetn;

	// -- Control / status --------------------------------------------------
	logic [31:0] control_reg;
	uwire logic  core_run    = control_reg[0];
	uwire logic  trace_clear = control_reg[1];
	uwire logic  trace_flush = control_reg[2];

	// U1: one run bit per core (b8/b9). The two TGC5Bs have nothing to do
	// with each other (own RAM, own CLINT, own encoder), so they may start
	// and stop independently. The old collective bit b0 remains valid and
	// acts as "both" (OR) -- any existing software that writes CONTROL=1
	// keeps starting both cores. A single core is stopped by leaving b0=0
	// and setting only its own bit.
	uwire logic  core0_run = core_run | control_reg[8];
	uwire logic  core1_run = core_run | control_reg[9];
	uwire logic  core0_rst_hold = ~core0_run;
	uwire logic  core1_rst_hold = ~core1_run;

	// -- Sink-window wiring (0x18..0x38 lives in ct_trace_sinks, T2) --------
	logic        sinks_reg_wr;                 // strobe: CTRL-segment write (assigned below)
	logic [3:0]  sinks_wr_ix, sinks_rd_ix;     // word indices awaddr/araddr[5:2]
	logic [31:0] sinks_wr_data, sinks_rd_data;

	// -- Shared time base: ONE free-running 64-bit fabric counter -----------
	// feeds both encoders' time_i (tip._time -> TR_TS_CORE), FINDINGS Teil
	// C0 §4: the cores' own mcycle counters would drift apart from each
	// other (per-core core_rst_hold already shifts the start).
	logic [63:0] fabric_time;
	always_ff @(posedge clk) begin
		if (rst) fabric_time <= '0;
		else     fabric_time <= fabric_time + 64'd1;
	end

	// -- Sub-slave wiring (1:1 duo_soc_top) ----------------------------
	logic        e0_awvalid, e0_awready, e0_wvalid, e0_wready, e0_bvalid, e0_bready;
	logic [1:0]  e0_bresp;
	logic        e0_arvalid, e0_arready, e0_rvalid, e0_rready;
	logic [31:0] e0_rdata;
	logic [1:0]  e0_rresp;
	logic        e1_awvalid, e1_awready, e1_wvalid, e1_wready, e1_bvalid, e1_bready;
	logic [1:0]  e1_bresp;
	logic        e1_arvalid, e1_arready, e1_rvalid, e1_rready;
	logic [31:0] e1_rdata;
	logic [1:0]  e1_rresp;
	logic [31:0] sub_addr, sub_wdata;   // ENC bridges: lower 16 bit, region-local
	logic [31:0] ram_addr;              // RAM loader: lower 20 bit, region-local
	logic [3:0]  sub_wstrb;

	// RAM loader windows of both SoCs.
	logic        r0_awvalid, r0_awready, r0_wvalid, r0_wready, r0_bvalid, r0_bready;
	logic [1:0]  r0_bresp;
	logic        r0_arvalid, r0_arready, r0_rvalid, r0_rready;
	logic [31:0] r0_rdata;
	logic [1:0]  r0_rresp;
	logic        r1_awvalid, r1_awready, r1_wvalid, r1_wready, r1_bvalid, r1_bready;
	logic [1:0]  r1_bresp;
	logic        r1_arvalid, r1_arready, r1_rvalid, r1_rready;
	logic [31:0] r1_rdata;
	logic [1:0]  r1_rresp;

	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) cfg0();
	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) cfg1();

	ct_axil_to_wb enc0_bridge (
		.clk (clk), .rst (rst),
		.s_awvalid (e0_awvalid), .s_awready (e0_awready), .s_awaddr (sub_addr),
		.s_wvalid  (e0_wvalid),  .s_wready  (e0_wready),  .s_wdata  (sub_wdata), .s_wstrb (sub_wstrb),
		.s_bvalid  (e0_bvalid),  .s_bready  (e0_bready),  .s_bresp  (e0_bresp),
		.s_arvalid (e0_arvalid), .s_arready (e0_arready), .s_araddr (sub_addr),
		.s_rvalid  (e0_rvalid),  .s_rready  (e0_rready),  .s_rdata  (e0_rdata), .s_rresp (e0_rresp),
		.wb (cfg0.master)
	);

	ct_axil_to_wb enc1_bridge (
		.clk (clk), .rst (rst),
		.s_awvalid (e1_awvalid), .s_awready (e1_awready), .s_awaddr (sub_addr),
		.s_wvalid  (e1_wvalid),  .s_wready  (e1_wready),  .s_wdata  (sub_wdata), .s_wstrb (sub_wstrb),
		.s_bvalid  (e1_bvalid),  .s_bready  (e1_bready),  .s_bresp  (e1_bresp),
		.s_arvalid (e1_arvalid), .s_arready (e1_arready), .s_araddr (sub_addr),
		.s_rvalid  (e1_rvalid),  .s_rready  (e1_rready),  .s_rdata  (e1_rdata), .s_rresp (e1_rresp),
		.wb (cfg1.master)
	);

	// -- SoC branches ----------------------------------------------------------
	logic [31:0] atb0_atdata,  atb1_atdata;
	logic [1:0]  atb0_atbytes, atb1_atbytes;
	logic [6:0]  atb0_atid,    atb1_atid;
	logic        atb0_atvalid, atb1_atvalid;
	logic        atb0_atready, atb1_atready;
	logic        atb0_afready, atb1_afready;
	logic        atb0_afvalid, atb1_afvalid;
	logic        atb0_syncreq, atb1_syncreq;
	logic        atb0_te_raw,  atb1_te_raw;

	logic [95:0] axis0_tdata,  axis1_tdata;
	logic [11:0] axis0_tstrb,  axis1_tstrb;
	logic [7:0]  axis0_tid,    axis1_tid;
	logic        axis0_tvalid, axis1_tvalid;

	logic [31:0] core0_trace_pc,  core1_trace_pc;
	logic        core0_trace_valid, core1_trace_valid;

	tgc5b_wp_synth_wrap #(.MEM_WORDS(MEM_WORDS), .MEM_INIT_FILE(MEM_INIT_FILE0)) soc0 (
		.clk (clk), .rst (rst),
		.core_rst_hold (core0_rst_hold),
		.time_i (fabric_time),
		.atb_atdata (atb0_atdata), .atb_atbytes (atb0_atbytes), .atb_atid (atb0_atid),
		.atb_atvalid (atb0_atvalid), .atb_atready (atb0_atready),
		.atb_afready (atb0_afready), .atb_te_raw (atb0_te_raw),
		.atb_afvalid (atb0_afvalid), .atb_syncreq (atb0_syncreq),
		.axis_tdata (axis0_tdata), .axis_tstrb (axis0_tstrb), .axis_tid (axis0_tid),
		.axis_tvalid (axis0_tvalid), .axis_tready (1'b1),
		.cfg_wb_en (1'b1),
		.cfg_wb_cyc (cfg0.cyc), .cfg_wb_stb (cfg0.stb), .cfg_wb_we (cfg0.we),
		.cfg_wb_addr (cfg0.addr), .cfg_wb_data_m2s (cfg0.data_m2s), .cfg_wb_sel (cfg0.sel),
		.cfg_wb_data_s2m (cfg0.data_s2m), .cfg_wb_ack (cfg0.ack), .cfg_wb_err (cfg0.err),
		.ldr_awvalid (r0_awvalid), .ldr_awready (r0_awready), .ldr_awaddr (ram_addr),
		.ldr_wvalid (r0_wvalid), .ldr_wready (r0_wready), .ldr_wdata (sub_wdata), .ldr_wstrb (sub_wstrb),
		.ldr_bvalid (r0_bvalid), .ldr_bready (r0_bready), .ldr_bresp (r0_bresp),
		.ldr_arvalid (r0_arvalid), .ldr_arready (r0_arready), .ldr_araddr (ram_addr),
		.ldr_rvalid (r0_rvalid), .ldr_rready (r0_rready), .ldr_rdata (r0_rdata), .ldr_rresp (r0_rresp),
		.core_trace_pc (core0_trace_pc), .core_trace_valid (core0_trace_valid)
	);

	tgc5b_wp_synth_wrap #(.MEM_WORDS(MEM_WORDS), .MEM_INIT_FILE(MEM_INIT_FILE1)) soc1 (
		.clk (clk), .rst (rst),
		.core_rst_hold (core1_rst_hold),
		.time_i (fabric_time),
		.atb_atdata (atb1_atdata), .atb_atbytes (atb1_atbytes), .atb_atid (atb1_atid),
		.atb_atvalid (atb1_atvalid), .atb_atready (atb1_atready),
		.atb_afready (atb1_afready), .atb_te_raw (atb1_te_raw),
		.atb_afvalid (atb1_afvalid), .atb_syncreq (atb1_syncreq),
		.axis_tdata (axis1_tdata), .axis_tstrb (axis1_tstrb), .axis_tid (axis1_tid),
		.axis_tvalid (axis1_tvalid), .axis_tready (1'b1),
		.cfg_wb_en (1'b1),
		.cfg_wb_cyc (cfg1.cyc), .cfg_wb_stb (cfg1.stb), .cfg_wb_we (cfg1.we),
		.cfg_wb_addr (cfg1.addr), .cfg_wb_data_m2s (cfg1.data_m2s), .cfg_wb_sel (cfg1.sel),
		.cfg_wb_data_s2m (cfg1.data_s2m), .cfg_wb_ack (cfg1.ack), .cfg_wb_err (cfg1.err),
		.ldr_awvalid (r1_awvalid), .ldr_awready (r1_awready), .ldr_awaddr (ram_addr),
		.ldr_wvalid (r1_wvalid), .ldr_wready (r1_wready), .ldr_wdata (sub_wdata), .ldr_wstrb (sub_wstrb),
		.ldr_bvalid (r1_bvalid), .ldr_bready (r1_bready), .ldr_bresp (r1_bresp),
		.ldr_arvalid (r1_arvalid), .ldr_arready (r1_arready), .ldr_araddr (ram_addr),
		.ldr_rvalid (r1_rvalid), .ldr_rready (r1_rready), .ldr_rdata (r1_rdata), .ldr_rresp (r1_rresp),
		.core_trace_pc (core1_trace_pc), .core_trace_valid (core1_trace_valid)
	);

	// -- WP record shims: encoder AXIS (no tready!) -> 32-bit records ------
	ct_axis_wp_shim #(.CORE_ID(4'd0), .FIFO_DEPTH(SHIM_FIFO_DEPTH)) shim0 (
		.clk (clk), .rst (rst),
		.s_tvalid (axis0_tvalid), .s_tdata (axis0_tdata),
		.s_tstrb (axis0_tstrb), .s_tid (axis0_tid),
		.m_tvalid (m0_axis_tvalid), .m_tready (m0_axis_tready),
		.m_tdata (m0_axis_tdata), .m_tkeep (m0_axis_tkeep), .m_tlast (m0_axis_tlast),
		.drop_count (shim0_drop_count),
		.overflow_sticky (shim0_overflow_sticky),
		.fill_level (shim0_fill_level)
	);

	ct_axis_wp_shim #(.CORE_ID(4'd1), .FIFO_DEPTH(SHIM_FIFO_DEPTH)) shim1 (
		.clk (clk), .rst (rst),
		.s_tvalid (axis1_tvalid), .s_tdata (axis1_tdata),
		.s_tstrb (axis1_tstrb), .s_tid (axis1_tid),
		.m_tvalid (m1_axis_tvalid), .m_tready (m1_axis_tready),
		.m_tdata (m1_axis_tdata), .m_tkeep (m1_axis_tkeep), .m_tlast (m1_axis_tlast),
		.drop_count (shim1_drop_count),
		.overflow_sticky (shim1_overflow_sticky),
		.fill_level (shim1_fill_level)
	);

	// -- Funnel: 2x ATB -> 1x ATB (message-atomic, MDO=6 wire format) ------
	// Instantiation pattern: cva6_2_soc_synth_wrap (delta
	// version with chan_te_raw/te_tag_*; duo_soc_top leaves these inputs
	// open -- here it does NOT).
	atb_if atb_in [2] ();
	atb_if atb_mrg ();

	assign atb_in[0].atdata  = atb0_atdata;
	assign atb_in[0].atbytes = atb0_atbytes;
	assign atb_in[0].atid    = atb0_atid;
	assign atb_in[0].atvalid = atb0_atvalid;
	assign atb_in[0].afready = atb0_afready;
	assign atb0_atready = atb_in[0].atready;
	assign atb0_afvalid = atb_in[0].afvalid;
	assign atb0_syncreq = atb_in[0].syncreq;

	assign atb_in[1].atdata  = atb1_atdata;
	assign atb_in[1].atbytes = atb1_atbytes;
	assign atb_in[1].atid    = atb1_atid;
	assign atb_in[1].atvalid = atb1_atvalid;
	assign atb_in[1].afready = atb1_afready;
	assign atb1_atready = atb_in[1].atready;
	assign atb1_afvalid = atb_in[1].afvalid;
	assign atb1_syncreq = atb_in[1].syncreq;

	uwire logic [1:0] funnel_prio [2];
	assign funnel_prio[0] = 2'd1;            // both 1 = round-robin
	assign funnel_prio[1] = 2'd1;
	uwire logic funnel_participate [2];
	assign funnel_participate[0] = 1'b1;
	assign funnel_participate[1] = 1'b1;
	uwire logic funnel_chan_flush_req [2];
	assign funnel_chan_flush_req[0] = 1'b0;
	assign funnel_chan_flush_req[1] = 1'b0;
	uwire logic funnel_chan_te_raw [2];
	assign funnel_chan_te_raw[0] = atb0_te_raw;
	assign funnel_chan_te_raw[1] = atb1_te_raw;
	uwire logic funnel_flush_done_u [2];
	uwire logic global_flush_done_u;

	ct_L1_funnel #(
		.N_STREAMS  (2),
		.MAX_PRIO   (3),
		.MSEO_WIDTH (2),
		// 6 = four byte chunks per 32-bit beat = this encoder's real wire
		// format (NOT the default 30).
		.MDO_WIDTH  (6),
		.EN_TE_RAW  (0)
	) funnel (
		.atclk    (clk),
		.atresetn (resetn),
		.chan_prio              (funnel_prio),
		.chan_flush_participate (funnel_participate),
		.chan_flush_req         (funnel_chan_flush_req),
		.chan_te_raw            (funnel_chan_te_raw),
		.te_tag_always          (1'b0),
		.te_tag_resync          (1'b0),
		.global_flush_req       (trace_flush),
		.chan_flush_done        (funnel_flush_done_u),
		.global_flush_done      (global_flush_done_u),
		.atb_in  (atb_in),
		.atb_out (atb_mrg)
	);

	assign atb_mrg.atready = 1'b1;    // the ring is always ready to accept
	assign atb_mrg.afvalid = 1'b0;    // global flush runs via global_flush_req
	assign atb_mrg.syncreq = 1'b0;

	// -- Three-sink subsystem (T2): URAM ring + DDR4 + PIB at the funnel output --
	// (atready is constant 1, every atvalid cycle is an accepted beat).
	// Reset: all extra sinks off -> inert; the ring remains the primary sink.
	logic [31:0] trace_beats, trace_bytes, trace_rdata;
	logic        trace_overflow;
	logic [31:0] trace_rd_word;

	ct_trace_sinks #(.TRACE_DEPTH(TRACE_DEPTH)) sinks (
		.clk (clk), .rst (rst),
		.trace_clear (trace_clear),
		.atb_atvalid (atb_mrg.atvalid),
		.atb_atdata (atb_mrg.atdata),
		.atb_atbytes (atb_mrg.atbytes),
		.reg_wr_i (sinks_reg_wr), .reg_wr_ix_i (sinks_wr_ix), .reg_wr_data_i (sinks_wr_data),
		.reg_rd_ix_i (sinks_rd_ix), .reg_rd_data_o (sinks_rd_data),
		.trace_beats_o (trace_beats), .trace_bytes_o (trace_bytes),
		.trace_wrapped_o (trace_overflow),
		.trace_rd_word (trace_rd_word), .trace_rd_data (trace_rdata),
		.m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
		.m_axi_awvalid, .m_axi_awready,
		.m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid, .m_axi_wready,
		.m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
		.pib_clk, .pib_data
	);

	// -- Region decode (duo_soc_top without an AXIS window) -----------------
	typedef enum logic [2:0] { SEG_CTRL, SEG_ENC0, SEG_ENC1, SEG_RAM0, SEG_RAM1, SEG_TRACE } seg_e;

	function automatic seg_e seg_of(input logic [21:0] a);
		if      (a[21])          seg_of = SEG_TRACE;
		else if (a[20])          seg_of = SEG_RAM0;
		else if (a[19])          seg_of = SEG_RAM1;
		else if (a[17])          seg_of = SEG_ENC1;
		else if (a[16])          seg_of = SEG_ENC0;
		else                     seg_of = SEG_CTRL;
	endfunction

	// ======================================================================
	// AXI4-Lite front end (1:1 from mbv_soc_top/duo_soc_top)
	// ======================================================================
	logic        axi_awready, axi_wready, axi_bvalid, axi_arready, axi_rvalid;
	logic        aw_en;
	logic        rd_busy;
	logic [21:0] awaddr_q, araddr_q;
	logic [31:0] wdata_q, rdata_q;
	logic [3:0]  wstrb_q;

	assign s_axi_awready = axi_awready;
	assign s_axi_wready  = axi_wready;
	assign s_axi_bvalid  = axi_bvalid;
	assign s_axi_bresp   = RESP_OKAY;
	assign s_axi_arready = axi_arready;
	assign s_axi_rvalid  = axi_rvalid;
	assign s_axi_rdata   = rdata_q;
	assign s_axi_rresp   = RESP_OKAY;

	always_ff @(posedge clk) begin
		if (rst) begin
			axi_awready <= 1'b0;
			aw_en       <= 1'b1;
			awaddr_q    <= '0;
		end
		else if (!axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
			axi_awready <= 1'b1;
			awaddr_q    <= s_axi_awaddr;
			aw_en       <= 1'b0;
		end
		else if (axi_bvalid && s_axi_bready) begin
			aw_en       <= 1'b1;
			axi_awready <= 1'b0;
		end
		else begin
			axi_awready <= 1'b0;
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			axi_wready <= 1'b0;
			wdata_q    <= '0;
			wstrb_q    <= '0;
		end
		else if (!axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en) begin
			axi_wready <= 1'b1;
			wdata_q    <= s_axi_wdata;
			wstrb_q    <= s_axi_wstrb;
		end
		else begin
			axi_wready <= 1'b0;
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			axi_arready <= 1'b0;
			araddr_q    <= '0;
		end
		else if (!axi_arready && s_axi_arvalid && !rd_busy) begin
			axi_arready <= 1'b1;
			araddr_q    <= s_axi_araddr;
		end
		else begin
			axi_arready <= 1'b0;
		end
	end

	uwire logic wr_fire = axi_awready && s_axi_awvalid && axi_wready && s_axi_wvalid;
	uwire logic rd_fire = axi_arready && s_axi_arvalid;

	// ======================================================================
	// Backend (region service; 4 sub-slaves: ENC0/ENC1/RAM0/RAM1)
	// ======================================================================
	typedef enum logic [3:0] {
		B_IDLE, B_WR, B_SUB_AW, B_SUB_B, B_RD, B_SUB_AR, B_SUB_R, B_TRACE0, B_TRACE1
	} bstate_e;

	bstate_e     bstate;
	seg_e        seg;

	// Sub-slave return path of the currently selected target.
	logic sub_awready, sub_wready, sub_bvalid, sub_arready, sub_rvalid;
	logic [31:0] sub_rdata;
	always_comb begin
		unique case (seg)
			SEG_ENC0: begin sub_awready = e0_awready; sub_wready = e0_wready; sub_bvalid = e0_bvalid;
			                sub_arready = e0_arready; sub_rvalid = e0_rvalid; sub_rdata = e0_rdata; end
			SEG_ENC1: begin sub_awready = e1_awready; sub_wready = e1_wready; sub_bvalid = e1_bvalid;
			                sub_arready = e1_arready; sub_rvalid = e1_rvalid; sub_rdata = e1_rdata; end
			SEG_RAM0: begin sub_awready = r0_awready; sub_wready = r0_wready; sub_bvalid = r0_bvalid;
			                sub_arready = r0_arready; sub_rvalid = r0_rvalid; sub_rdata = r0_rdata; end
			SEG_RAM1: begin sub_awready = r1_awready; sub_wready = r1_wready; sub_bvalid = r1_bvalid;
			                sub_arready = r1_arready; sub_rvalid = r1_rvalid; sub_rdata = r1_rdata; end
			default:  begin sub_awready = 1'b0; sub_wready = 1'b0; sub_bvalid = 1'b0;
			                sub_arready = 1'b0; sub_rvalid = 1'b0; sub_rdata = '0; end
		endcase
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			bstate <= B_IDLE; seg <= SEG_CTRL; rd_busy <= 1'b0;
			axi_bvalid <= 1'b0; axi_rvalid <= 1'b0; rdata_q <= '0;
			control_reg <= '0;
		end
		else begin
			if (axi_bvalid && s_axi_bready) axi_bvalid <= 1'b0;
			if (axi_rvalid && s_axi_rready) begin axi_rvalid <= 1'b0; rd_busy <= 1'b0; end

			case (bstate)
				B_IDLE: begin
					if (wr_fire) begin seg <= seg_of(awaddr_q); bstate <= B_WR; end
					else if (rd_fire) begin seg <= seg_of(araddr_q); rd_busy <= 1'b1; bstate <= B_RD; end
				end

				B_WR: begin
					unique case (seg)
						SEG_CTRL: begin
							case (awaddr_q[5:2])
								4'd0: control_reg <= wdata_q;
								// 0x18..0x38: sink window in ct_trace_sinks
								// (sinks_reg_wr strobes in this cycle).
								default: ;
							endcase
							axi_bvalid <= 1'b1; bstate <= B_IDLE;
						end
						SEG_ENC0, SEG_ENC1, SEG_RAM0, SEG_RAM1: bstate <= B_SUB_AW;
						default: begin axi_bvalid <= 1'b1; bstate <= B_IDLE; end   // TRACE write ignored
					endcase
				end
				B_SUB_AW: if (sub_awready && sub_wready) bstate <= B_SUB_B;
				B_SUB_B:  if (sub_bvalid) begin axi_bvalid <= 1'b1; bstate <= B_IDLE; end

				B_RD: begin
					unique case (seg)
						SEG_CTRL: begin
							case (araddr_q[5:2])
								4'd0:    rdata_q <= control_reg;
								// U1: b8/b9 = EFFECTIVE run state per core
								// (b0 OR b8/b9) -- one read suffices to see
								// which core is really running.
								4'd1:    rdata_q <= {22'b0, core1_run, core0_run,
								                     7'b0, trace_overflow};
								4'd2:    rdata_q <= trace_beats;
								4'd3:    rdata_q <= trace_bytes;
								4'd4:    rdata_q <= 32'(TRACE_DEPTH * 4);
								4'd5:    rdata_q <= '0;
								// 0x18..0x38: sink window (ct_trace_sinks, T2)
								default: rdata_q <= sinks_rd_data;
							endcase
							axi_rvalid <= 1'b1; bstate <= B_IDLE;
						end
						SEG_TRACE: bstate <= B_TRACE0;
						default:   bstate <= B_SUB_AR;
					endcase
				end
				B_TRACE0: bstate <= B_TRACE1;
				B_TRACE1: begin rdata_q <= trace_rdata; axi_rvalid <= 1'b1; bstate <= B_IDLE; end
				B_SUB_AR: if (sub_arready) bstate <= B_SUB_R;
				B_SUB_R:  if (sub_rvalid) begin
					rdata_q <= sub_rdata;
					axi_rvalid <= 1'b1; bstate <= B_IDLE;
				end
				default: bstate <= B_IDLE;
			endcase
		end
	end

	// Region-local byte address to all sub-slaves (valids select the target).
	uwire logic [21:0] acc_addr = (bstate == B_SUB_AR || bstate == B_SUB_R) ? araddr_q : awaddr_q;
	assign sub_addr  = {16'b0, acc_addr[15:0]};
	assign sub_wdata = wdata_q;
	assign sub_wstrb = wstrb_q;

	assign e0_awvalid = (bstate == B_SUB_AW) && (seg == SEG_ENC0);
	assign e0_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_ENC0);
	assign e0_bready  = (bstate == B_SUB_B)  && (seg == SEG_ENC0);
	assign e0_arvalid = (bstate == B_SUB_AR) && (seg == SEG_ENC0);
	assign e0_rready  = (bstate == B_SUB_R)  && (seg == SEG_ENC0);

	assign e1_awvalid = (bstate == B_SUB_AW) && (seg == SEG_ENC1);
	assign e1_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_ENC1);
	assign e1_bready  = (bstate == B_SUB_B)  && (seg == SEG_ENC1);
	assign e1_arvalid = (bstate == B_SUB_AR) && (seg == SEG_ENC1);
	assign e1_rready  = (bstate == B_SUB_R)  && (seg == SEG_ENC1);

	assign r0_awvalid = (bstate == B_SUB_AW) && (seg == SEG_RAM0);
	assign r0_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_RAM0);
	assign r0_bready  = (bstate == B_SUB_B)  && (seg == SEG_RAM0);
	assign r0_arvalid = (bstate == B_SUB_AR) && (seg == SEG_RAM0);
	assign r0_rready  = (bstate == B_SUB_R)  && (seg == SEG_RAM0);

	assign r1_awvalid = (bstate == B_SUB_AW) && (seg == SEG_RAM1);
	assign r1_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_RAM1);
	assign r1_bready  = (bstate == B_SUB_B)  && (seg == SEG_RAM1);
	assign r1_arvalid = (bstate == B_SUB_AR) && (seg == SEG_RAM1);
	assign r1_rready  = (bstate == B_SUB_R)  && (seg == SEG_RAM1);

	assign trace_rd_word = {12'b0, araddr_q[21:2]};

	// Sink-window accesses (0x18..0x38) delegated to ct_trace_sinks: the
	// strobe fires in exactly the one B_WR cycle of the CTRL segment; the
	// module decodes its own indices (0x00/0x04.. stay here).
	assign sinks_reg_wr  = (bstate == B_WR) && (seg == SEG_CTRL);
	assign sinks_wr_ix   = awaddr_q[5:2];
	assign sinks_wr_data = wdata_q;
	assign sinks_rd_ix   = araddr_q[5:2];

	// RAM loader: 20 region-local address bits (like duo; both RAMs are
	// 64 KiB, the higher bits run idle in the RAM). ENC bridges only the
	// lower 16.
	assign ram_addr = {12'b0, acc_addr[19:0]};

endmodule

`default_nettype wire
