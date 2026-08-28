// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Dual-core KV260 top: MBV + MINRES TGC5B, each its own CTTE
 *           instance, ct_L1_funnel merges both ATB streams into ONE trace ring.
 *
 * @details
 *   Extends mbv_soc_top (whose AXI4-Lite front end and devmem semantics are
 *   carried over 1:1) with a second, independent core+encoder branch:
 *
 *     soc0  mbv_soc_synth_wrap   MicroBlaze-V + adapter + ct_encoder (SPLIT=0)
 *     soc1  ct_soc_synth_wrap    MINRES TGC5B + H2E adapter + ct_encoder (SPLIT=1)
 *     funnel ct_L1_funnel        N_STREAMS=2, MDO_WIDTH=6 (4 byte chunks/beat),
 *                                message-atomic, idle-drop; output -> trace ring
 *
 *   The decoder tells the sources apart via the Nexus SRC field (per CSR:
 *   trTeControl.InhibitSrc=0 + trTeInstFeatures.SrcID/SrcBits, per instance)
 *   -- the ring stores only ATDATA beats, ATID is lost (as before).
 *
 *   Address map (22-bit aperture, base 0xA000_0000 in the top-level router):
 *     0x00_0000  CTRL   like mbv_soc_top (CONTROL, STATUS, TRACE_BEATS/BYTES/BUFSZ, AXIS_BEATS)
 *     0x01_0000  ENC0   CTTE CSRs, MBV encoder     (ct_axil_to_wb)
 *     0x02_0000  ENC1   CTTE CSRs, TGC5B encoder   (ct_axil_to_wb)
 *     0x08_0000  RAM1   TGC5B program/data RAM (64 KiB; load while core1_run=0)
 *     0x10_0000  RAM0   MBV program/data RAM (128 KiB; load while core0_run=0)
 *     0x20_0000  TRACE  merged ATB ring (1 MiB URAM)
 *     0x30_0000  AXIS   AXIS capture (only the MBV encoder is connected)
 *
 *   CONTROL b0 starts BOTH cores together (collective bit, unchanged);
 *   b3 = IRQ pulse generator for the MBV branch. Since U1 additionally b8 =
 *   MBV (soc0) and b9 = TGC5B (soc1) INDIVIDUALLY -- effective is b0 OR the
 *   core bit; the two branches have nothing to do with each other. STATUS
 *   mirrors the effective run state in b8/b9. Loader contract therefore PER
 *   CORE: only write RAM_i while core_i_run=0 (an access to a RUNNING core's
 *   RAM never gets ready and hangs the transaction).
 *
 *   Trace sinks at the funnel output (folded into the shared three-sink
 *   subsystem ct_trace_sinks since T2, identical for all designs; all three
 *   run in parallel; the ring is the primary always-ready sink, DDR4/PIB are
 *   additive observers with their own FIFO + drop counter, NEVER backpressure
 *   the trace path):
 *     Mem(URAM)  1 MiB ring @TRACE (as before)
 *     Mem(DDR4)  ct_soc_ddr_sink -> AXI4 master m_axi_* (PS S_AXI_HP, linear)
 *     PIB        ct_soc_pib -> pib_clk/pib_data[3:0] (4-bit DDR, PIB_PAR_4,
 *                KR260-adapter-compatible pinout -- see duo_pib_pmod.xdc)
 *   CTRL extension:
 *     0x18 SINK_CTRL  (rw) b0 ddr_en  b1 ddr_clear  b2 ddr_circ (1=circular,
 *                          0=one shot)  b3 uram_oneshot (1=one shot,
 *                          0=circular)  b4 pib_en  b5 pib_clear
 *                          b6 pib_calib (pattern instead of trace, like the
 *                          reference PIB's trPibCalibrate)  b[10:8] pib_div
 *                          (port clock = clk/2^(div+1), min 1)  b[13:12]
 *                          pib_pattern (0=STANDARD AA/55/00/FF, 1=MOVING_ONE,
 *                          2=MOVING_ZERO)
 *     0x1C DDR_BASE   (rw) byte address in the PS DDR (32-byte aligned).
 *                          Reset 0x5000_0000 = the address plan v4 trace
 *                          window (U6, 2026-08-15: one central DDR4
 *                          window for all demos, the same window rocket2
 *                          has carried since C1). Ubuntu leaves
 *                          0x5000_0000..0x6FFF_FFFF (512 MiB) free via
 *                          reserved-memory/no-map -- overlay
 *                          vivado/kv260_app/ctrace_resmem.dtso, doc
 *                          examples/kv260/SPEC_board_memory_map.md. Split:
 *                          0x5000_0000 +256 MiB DDR trace sink (this
 *                          register), 0x6000_0000 +64 MiB gap (old window),
 *                          0x6400_0000 +192 MiB guest code/data (gate C5).
 *                          Writable only while ddr_en=0 (U6).
 *     0x20 DDR_SIZE   (rw) buffer size in bytes (4-aligned; 0 = off).
 *                          Reset 0x1000_0000 (256 MiB, see above); ddr_en
 *                          stays 0 out of reset -- the sink starts only via
 *                          SINK_CTRL. Writable only while ddr_en=0 (U6).
 *     0x24 DDR_WPTR   (ro) bytes written TOTAL (monotonic; buffer offset =
 *                          wptr % size, like the URAM ring)
 *     0x28 SINK_STAT  (ro) b0 ddr_full (one shot)  b1 ddr_axi_err
 *                          b2 ddr_wrapped (circular)  b3 uram_stopped
 *                          b4 ddr_cfg_rej (window write rejected while the
 *                          sink is armed, U6; cleared via ddr_clear)
 *     0x2C DDR_DROPS  (ro) dropped beats (saturating)
 *     0x30 PIB_DROPS  (ro) dropped beats (saturating)
 *     0x34 FUNNEL_CTRL(rw) b[1:0] priority channel 0 (MBV), b[5:4] priority
 *                          channel 1 (TGC5B); higher number = preferred,
 *                          equal = round-robin (reset 0x11). Changeable live
 *                          (takes effect at the next message boundary). NOT
 *                          part of the sink window (stays in this top).
 *     0x38 DDR_BEATS  (ro) ATB beats offered to the sink since ddr_en
 *                          (accepted = BEATS - DROPS; clear via ddr_clear)
 *                          -- T2 addition, before that 0x38 read 0.
 */
module duo_soc_top #(
	int unsigned MEM_WORDS   = 32768,    // MBV: 128 KiB
	int unsigned MEM2_WORDS  = 16384,    // TGC5B: 64 KiB
	int unsigned TRACE_DEPTH = 262144    // ring capacity in beats (1 MiB URAM)
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

	// DDR4 sink: AXI4 write-only master (to PS S_AXI_HP*_FPD)
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

	// PIB: parallel trace port (source-synchronous, DDR nibbles)
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

	// U1: one run bit per core (b8 = MBV/soc0, b9 = TGC5B/soc1). The two
	// branches have nothing to do with each other (different ISAs, separate
	// RAMs and peripherals), so they may start and stop independently. b0
	// remains the collective "both" bit (OR) -- existing board scripts that
	// write CONTROL=1 keep starting both cores unchanged.
	uwire logic  core0_run = core_run | control_reg[8];
	uwire logic  core1_run = core_run | control_reg[9];
	uwire logic  core0_rst_hold = ~core0_run;
	uwire logic  core1_rst_hold = ~core1_run;

	// -- Sink-window wiring (0x18..0x38 lives in ct_trace_sinks, T2) ------
	logic [31:0] funnel_ctrl_reg; // 0x34: b[1:0] prio ch0, b[5:4] prio ch1 (reset 0x11) -- stays in this top
	logic        sinks_reg_wr;                 // strobe: CTRL-segment write (assigned below)
	logic [3:0]  sinks_wr_ix, sinks_rd_ix;     // word indices awaddr/araddr[5:2]
	logic [31:0] sinks_wr_data, sinks_rd_data;

	// MBV IRQ pulse generator (CONTROL b3), unchanged from mbv_soc_top.
	logic [11:0] irq_div;
	logic        ext_irq;
	always_ff @(posedge clk) begin
		if (rst || !control_reg[3]) begin
			irq_div <= '0;
			ext_irq <= 1'b0;
		end
		else begin
			irq_div <= irq_div + 1'b1;
			ext_irq <= (irq_div == '0);
		end
	end

	// -- Sub-slave wiring ---------------------------------------------
	// Encoder CSR bridges (AXI4-Lite region -> Wishbone), one per encoder.
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

	logic [95:0] axis_tdata;
	logic [11:0] axis_tkeep;
	logic [7:0]  axis_tid;
	logic        axis_tlast;
	logic        axis_tvalid;
	logic [95:0] axis1_tdata;
	logic [11:0] axis1_tkeep;
	logic [7:0]  axis1_tid;
	logic        axis1_tlast;
	logic        axis1_tvalid;

	logic [31:0] core0_trace_pc,  core1_trace_pc;
	logic        core0_trace_valid, core1_trace_valid;

	mbv_soc_synth_wrap #(.MEM_WORDS(MEM_WORDS)) soc0 (
		.clk (clk), .rst (rst),
		.core_rst_hold (core0_rst_hold),
		.ext_irq (ext_irq),
		.atb_atdata (atb0_atdata), .atb_atbytes (atb0_atbytes), .atb_atid (atb0_atid),
		.atb_atvalid (atb0_atvalid), .atb_atready (atb0_atready),
		.atb_afready (atb0_afready), .atb_afvalid (atb0_afvalid), .atb_syncreq (atb0_syncreq),
		.axis_tdata (axis_tdata), .axis_tkeep (axis_tkeep), .axis_tid (axis_tid),
		.axis_tlast (axis_tlast), .axis_tvalid (axis_tvalid), .axis_tready (1'b1),
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

	// TGC5B branch: identical port contract (the MBV wrapper was built
	// port-compatible with the tgc5b ct_soc_synth_wrap -- that pays off
	// here). The second encoder's AXIS is not captured (ACT is not enabled
	// there).
	ct_soc_synth_wrap #(.MEM_WORDS(MEM2_WORDS)) soc1 (
		.clk (clk), .rst (rst),
		.core_rst_hold (core1_rst_hold),
		.atb_atdata (atb1_atdata), .atb_atbytes (atb1_atbytes), .atb_atid (atb1_atid),
		.atb_atvalid (atb1_atvalid), .atb_atready (atb1_atready),
		.atb_afready (atb1_afready), .atb_afvalid (atb1_afvalid), .atb_syncreq (atb1_syncreq),
		.axis_tdata (axis1_tdata), .axis_tkeep (axis1_tkeep), .axis_tid (axis1_tid),
		.axis_tlast (axis1_tlast), .axis_tvalid (axis1_tvalid), .axis_tready (1'b1),
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

	// -- Funnel: 2x ATB -> 1x ATB (message-atomic, MDO=6 wire format) ------
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

	// Channel priorities from FUNNEL_CTRL (reset: both 1 = round-robin).
	uwire logic [1:0] funnel_prio [2];
	assign funnel_prio[0] = funnel_ctrl_reg[1:0];
	assign funnel_prio[1] = funnel_ctrl_reg[5:4];
	uwire logic funnel_participate [2];
	assign funnel_participate[0] = 1'b1;
	assign funnel_participate[1] = 1'b1;
	uwire logic funnel_flush_req [2];
	assign funnel_flush_req[0] = 1'b0;
	assign funnel_flush_req[1] = 1'b0;
	uwire logic funnel_flush_done_u [2];
	uwire logic global_flush_done_u;

	ct_L1_funnel #(
		.N_STREAMS (2),
		.MAX_PRIO  (3),
		.MDO_WIDTH (6)
	) funnel (
		.atclk    (clk),
		.atresetn (resetn),
		.chan_prio (funnel_prio),
		.chan_flush_participate (funnel_participate),
		.chan_flush_req (funnel_flush_req),
		.global_flush_req (trace_flush),
		.chan_flush_done (funnel_flush_done_u),
		.global_flush_done (global_flush_done_u),
		.atb_in  (atb_in),
		.atb_out (atb_mrg)
	);

	assign atb_mrg.atready = 1'b1;    // the ring is always ready to accept
	assign atb_mrg.afvalid = 1'b0;    // global flush runs via global_flush_req
	assign atb_mrg.syncreq = 1'b0;

	// -- Capture buffer ----------------------------------------------------
	logic [31:0] trace_beats, trace_bytes, trace_rdata;
	logic        trace_overflow;
	logic [31:0] trace_rd_word;
	logic [31:0] axis_beats, axis_rdata;
	logic        axis_overflow;
	logic [31:0] axis_rd_word;

	// Three-sink subsystem (T2): URAM ring + DDR4 + PIB, observers at the
	// funnel output (atready is constant 1, every atvalid cycle is an
	// accepted beat). CTRL window 0x18..0x38 lives in the module.
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

	ct_soc_axis_buf axis_buf (
		.clk (clk), .rst (rst), .clear (trace_clear),
		.axis_tvalid (axis_tvalid), .axis_tready (1'b1),
		.axis_tdata (axis_tdata), .axis_tkeep (axis_tkeep),
		.axis_tid (axis_tid), .axis_tlast (axis_tlast),
		.beats_o (axis_beats), .overflow_o (axis_overflow),
		.rd_word (axis_rd_word), .rd_data (axis_rdata)
	);

	// -- Region decode -----------------------------------------------------
	typedef enum logic [2:0] { SEG_CTRL, SEG_ENC0, SEG_ENC1, SEG_RAM0, SEG_RAM1, SEG_TRACE, SEG_AXIS } seg_e;

	function automatic seg_e seg_of(input logic [21:0] a);
		if      (a[21] && a[20]) seg_of = SEG_AXIS;
		else if (a[21])          seg_of = SEG_TRACE;
		else if (a[20])          seg_of = SEG_RAM0;
		else if (a[19])          seg_of = SEG_RAM1;
		else if (a[17])          seg_of = SEG_ENC1;
		else if (a[16])          seg_of = SEG_ENC0;
		else                     seg_of = SEG_CTRL;
	endfunction

	// ======================================================================
	// AXI4-Lite front end (1:1 from mbv_soc_top)
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
		B_IDLE, B_WR, B_SUB_AW, B_SUB_B, B_RD, B_SUB_AR, B_SUB_R, B_TRACE0, B_TRACE1,
		B_AXIS0, B_AXIS1
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
			funnel_ctrl_reg <= 32'h0000_0011;   // both channels prio 1 (round-robin)
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
								4'd13: funnel_ctrl_reg <= wdata_q & 32'h0000_0033; // 0x34 FUNNEL_CTRL
								default: ;
							endcase
							axi_bvalid <= 1'b1; bstate <= B_IDLE;
						end
						SEG_ENC0, SEG_ENC1, SEG_RAM0, SEG_RAM1: bstate <= B_SUB_AW;
						default: begin axi_bvalid <= 1'b1; bstate <= B_IDLE; end   // TRACE/AXIS write ignored
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
								// (b0 OR the core bit).
								4'd1:    rdata_q <= {22'b0, core1_run, core0_run,
								                     6'b0, axis_overflow, trace_overflow};
								4'd2:    rdata_q <= trace_beats;
								4'd3:    rdata_q <= trace_bytes;
								4'd4:    rdata_q <= axis_beats;
								4'd5:    rdata_q <= 32'(TRACE_DEPTH * 4);
								4'd13:   rdata_q <= funnel_ctrl_reg;             // 0x34
								// 0x18..0x38: sink window (ct_trace_sinks, T2)
								default: rdata_q <= sinks_rd_data;
							endcase
							axi_rvalid <= 1'b1; bstate <= B_IDLE;
						end
						SEG_TRACE: bstate <= B_TRACE0;
						SEG_AXIS:  bstate <= B_AXIS0;
						default:   bstate <= B_SUB_AR;
					endcase
				end
				B_TRACE0: bstate <= B_TRACE1;
				B_TRACE1: begin rdata_q <= trace_rdata; axi_rvalid <= 1'b1; bstate <= B_IDLE; end
				B_AXIS0: bstate <= B_AXIS1;
				B_AXIS1: begin rdata_q <= axis_rdata; axi_rvalid <= 1'b1; bstate <= B_IDLE; end
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
	assign axis_rd_word  = {12'b0, araddr_q[21:2]};

	// Sink-window accesses (0x18..0x38) delegated to ct_trace_sinks: the
	// strobe fires in exactly the one B_WR cycle of the CTRL segment; the
	// module decodes its own indices (0x00/0x34 stay here).
	assign sinks_reg_wr  = (bstate == B_WR) && (seg == SEG_CTRL);
	assign sinks_wr_ix   = awaddr_q[5:2];
	assign sinks_wr_data = wdata_q;
	assign sinks_rd_ix   = araddr_q[5:2];

	// RAM loaders need the full 20 region-local address bits (RAM0 is
	// 128 KiB -> 17-bit byte address); the ENC bridges only the lower 16.
	assign ram_addr = {12'b0, acc_addr[19:0]};

endmodule

`default_nettype wire
