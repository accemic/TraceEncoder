// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Two-hart Rocket SoC with TWO CTTE instances and a funnel (M4).
 *
 * @details
 *   Twin of rocket_soc_top for the Rocket64t2 branch. One SMP-capable core
 *   with two harts, one CTTE instance each, ONE merged stream:
 *
 *     rocket2_soc_synth_wrap  generat rocket64t2 (CLINT + PLIC + bootrom
 *                             inside it) + 8250 console + window guard
 *                             + 2x shim + 2x ct_encoder + ct_L1_funnel
 *     ct_soc_trace_ring       1-MiB URAM ring at the funnel output
 *     ct_soc_ddr_sink         linear DDR sink
 *     ct_soc_pib              parallel trace port (optional)
 *
 *   FOUR differences from rocket_soc_top, all from two-hart operation:
 *
 *     1. TWO ENC windows. Each encoder instance has its own CSR map (Trio
 *        pattern ENC0/ENC1) and thus its own ct_axil_to_wb bridge. Without
 *        that, software could not set the two instances to SrcID 0 and 1
 *        separately -- and exactly that SrcID is what the decoder uses to
 *        split the streams apart again.
 *     2. FUNNEL_CTRL. Channel priorities and a global flush kick, live
 *        adjustable (template duo_soc_top.sv:0x34). Reset 0x11 = both
 *        channels priority 1 = round-robin.
 *     3. Golden reference and observation channel PER HART. "The core is
 *        hung" is no longer one question with two harts, but two: a shared
 *        retire counter could keep happily running while ONE hart is
 *        stalled. Hence PC/retires/privilege tracked separately.
 *     4. EN_ETRACE is OFF by default here. The funnel recognizes packet
 *        boundaries via the Nexus MSEO bits; an E-Trace backend delivers
 *        raw bytes and would be silently merged wrong (the wrapper
 *        therefore aborts elaboration at EN_ETRACE=1).
 *
 *   Address map of the PS aperture (22 bit), extended over the one-hart
 *   design only by ENC1:
 *     0x00_0000  CTRL    CONTROL, STATUS, TRACE_x, SINK_x, DDR_x, CON_x,
 *                        WIN_x, PC/RETIRES per hart, FUNNEL_CTRL
 *     0x01_0000  ENC0    CTTE CSRs hart 0
 *     0x02_0000  ENC1    CTTE CSRs hart 1
 *     0x20_0000  TRACE   merged ring (word read accesses)
 *     0x30_0000  CON     console ring (word read accesses)
 *
 *   CTRL registers (word offsets, [6:2]); 0x00..0x54 identical to
 *   rocket_soc_top so existing board scripts keep working:
 *     0x00 CONTROL  (rw) b0 core_run (holds BOTH harts)  b1 trace_clear
 *                        b2 con_clear  b3 win_err_clear  b4 obs_clear
 *     0x04 STATUS   (ro) b0 trace_wrapped   b1 uram_stopped
 *                        b2 win_err_sticky  b3 win_err_was_write
 *                        b4 core_ndreset    b5 core_rst_hold
 *                        b[10:8]  observation sticky {rvalid, arvalid,
 *                                 retire(hart0 OR hart1)}
 *                        b[14:12] last privilege level observed, hart 0
 *                        b18 retire_seen hart 0   b19 retire_seen hart 1
 *                        b[22:20] last privilege level observed, hart 1
 *                        (b8 is the OR of both harts -- that keeps it
 *                         bit-identical to the one-hart design's reading)
 *     0x08..0x18, 0x1C..0x30, 0x34..0x48  like rocket_soc_top
 *     0x4C PC0_LO   (ro)  0x50 PC0_HI (ro)  0x54 RETIRES0 (ro)   [hart 0]
 *     0x58 FUNNEL_CTRL (rw) b[1:0] priority channel 0, b[5:4] channel 1,
 *                        b8 = global flush kick (level). Reset 0x11.
 *                   (ro) b16 = funnel_flush_done (acknowledgement).
 *                        Deliberately in a free bit and NOT in b0 -- that
 *                        holds a priority, which a stuck done would
 *                        otherwise corrupt on read.
 *     0x5C PC1_LO   (ro)  0x60 PC1_HI (ro)  0x64 RETIRES1 (ro)   [hart 1]
 */
module rocket2_soc_top #(
	longint unsigned WIN_BASE    = 64'h8000_0000,
	longint unsigned WIN_SIZE    = 64'h0C00_0000,   // 192 MiB
	longint unsigned PS_BASE     = 64'h6400_0000,
	longint unsigned UART_BASE   = 64'h6001_0000,
	int unsigned     CON_BYTES   = 65536,
	int unsigned     TRACE_DEPTH = 262144,          // 1 MiB URAM
	// Default OFF -- see difference 4 in the header.
	bit              EN_ETRACE   = 1'b0
) (
	input  uwire logic        clk,
	input  uwire logic        resetn,

	// --- PS AXI4-Lite slave -----------------------------------------------
	input  uwire logic [21:0] s_axi_awaddr,
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
	input  uwire logic        s_axi_arvalid,
	output      logic         s_axi_arready,
	output      logic [31:0]  s_axi_rdata,
	output      logic [1:0]   s_axi_rresp,
	output      logic         s_axi_rvalid,
	input  uwire logic        s_axi_rready,

	// --- Rocket memory path: AXI4 to the PS HP port (64 bit) --------------
	output      logic [3:0]   m_axi_awid,
	output      logic [63:0]  m_axi_awaddr,
	output      logic [7:0]   m_axi_awlen,
	output      logic [2:0]   m_axi_awsize,
	output      logic [1:0]   m_axi_awburst,
	output      logic         m_axi_awlock,
	output      logic [3:0]   m_axi_awcache,
	output      logic [2:0]   m_axi_awprot,
	output      logic         m_axi_awvalid,
	input  uwire logic        m_axi_awready,
	output      logic [63:0]  m_axi_wdata,
	output      logic [7:0]   m_axi_wstrb,
	output      logic         m_axi_wlast,
	output      logic         m_axi_wvalid,
	input  uwire logic        m_axi_wready,
	input  uwire logic [3:0]  m_axi_bid,
	input  uwire logic [1:0]  m_axi_bresp,
	input  uwire logic        m_axi_bvalid,
	output      logic         m_axi_bready,
	output      logic [3:0]   m_axi_arid,
	output      logic [63:0]  m_axi_araddr,
	output      logic [7:0]   m_axi_arlen,
	output      logic [2:0]   m_axi_arsize,
	output      logic [1:0]   m_axi_arburst,
	output      logic         m_axi_arlock,
	output      logic [3:0]   m_axi_arcache,
	output      logic [2:0]   m_axi_arprot,
	output      logic         m_axi_arvalid,
	input  uwire logic        m_axi_arready,
	input  uwire logic [3:0]  m_axi_rid,
	input  uwire logic [63:0] m_axi_rdata,
	input  uwire logic [1:0]  m_axi_rresp,
	input  uwire logic        m_axi_rlast,
	input  uwire logic        m_axi_rvalid,
	output      logic         m_axi_rready,

	// --- Trace DDR sink: AXI4 write-only ------------------------------------
	output      logic [31:0]  t_axi_awaddr,
	output      logic [7:0]   t_axi_awlen,
	output      logic [2:0]   t_axi_awsize,
	output      logic [1:0]   t_axi_awburst,
	output      logic         t_axi_awvalid,
	input  uwire logic        t_axi_awready,
	output      logic [31:0]  t_axi_wdata,
	output      logic [3:0]   t_axi_wstrb,
	output      logic         t_axi_wlast,
	output      logic         t_axi_wvalid,
	input  uwire logic        t_axi_wready,
	input  uwire logic [1:0]  t_axi_bresp,
	input  uwire logic        t_axi_bvalid,
	output      logic         t_axi_bready,

	// --- PIB -----------------------------------------------------------------
	output      logic         pib_clk,
	output      logic [3:0]   pib_data
);

	uwire logic rst = ~resetn;

	// ------------------------------------------------------------------
	// CTRL registers
	// ------------------------------------------------------------------
	logic [31:0] control_reg, sink_ctrl_reg, ddr_base_reg, ddr_size_reg;
	logic [31:0] ext_irq_reg, funnel_ctrl_reg;
	uwire logic core_run      = control_reg[0];
	uwire logic trace_clear   = control_reg[1];
	uwire logic con_clear     = control_reg[2];
	uwire logic win_err_clear = control_reg[3];
	uwire logic obs_clear     = control_reg[4];

	// ------------------------------------------------------------------
	// Core + both encoders + funnel (one wrapper, like the one-hart branch)
	// ------------------------------------------------------------------
	uwire logic [31:0] atb_atdata;
	uwire logic [1:0]  atb_atbytes;
	uwire logic [6:0]  atb_atid;
	uwire logic        atb_atvalid, atb_te_raw, atb_afready, funnel_flush_done;
	uwire logic [tip_pkg::TIP_IADDRESS_WIDTH-1:0] core0_pc, core1_pc;
	uwire logic        core0_pc_valid, core1_pc_valid;
	uwire logic [2:0]  core0_priv, core1_priv;
	uwire logic        core_ndreset;

	logic [31:0]       con_rd_word;
	uwire logic [31:0] con_rd_data, con_bytes, con_drops, con_rx_drops;
	uwire logic [15:0] con_rx_used;
	logic [31:0]       con_rptr_reg;
	logic              con_rx_wr;
	logic [7:0]        con_rx_data;

	uwire logic        win_err_sticky, win_err_was_write;
	uwire logic [31:0] win_err_count;
	uwire logic [63:0] win_err_addr;

	// Two Wishbone bridges -- one per encoder instance.
	uwire logic        e0_cyc, e0_stb, e0_we, e1_cyc, e1_stb, e1_we;
	uwire logic [31:0] e0_addr, e0_m2s, e1_addr, e1_m2s;
	uwire logic [3:0]  e0_sel, e1_sel;
	uwire logic [31:0] e0_s2m, e1_s2m;
	uwire logic        e0_ack, e0_err, e1_ack, e1_err;

	rocket2_soc_synth_wrap #(
		.WIN_BASE  (WIN_BASE),
		.WIN_SIZE  (WIN_SIZE),
		.PS_BASE   (PS_BASE),
		.UART_BASE (UART_BASE),
		.CON_BYTES (CON_BYTES),
		.EN_ETRACE (EN_ETRACE)
	) soc (
		.clk (clk), .rst (rst),
		.core_rst_hold (~core_run),
		.ext_irq (ext_irq_reg[7:0]),
		.atb_atdata, .atb_atbytes, .atb_atid, .atb_atvalid,
		.atb_atready (1'b1),
		.atb_afready, .atb_te_raw,
		.atb_afvalid (1'b0), .atb_syncreq (1'b0),
		.funnel_prio0 (funnel_ctrl_reg[1:0]),
		.funnel_prio1 (funnel_ctrl_reg[5:4]),
		.funnel_flush_req (funnel_ctrl_reg[8]),
		.funnel_flush_done (funnel_flush_done),
		.cfg0_wb_en (e0_cyc), .cfg0_wb_cyc (e0_cyc), .cfg0_wb_stb (e0_stb),
		.cfg0_wb_we (e0_we), .cfg0_wb_addr (e0_addr),
		.cfg0_wb_data_m2s (e0_m2s), .cfg0_wb_sel (e0_sel),
		.cfg0_wb_data_s2m (e0_s2m), .cfg0_wb_ack (e0_ack), .cfg0_wb_err (e0_err),
		.cfg1_wb_en (e1_cyc), .cfg1_wb_cyc (e1_cyc), .cfg1_wb_stb (e1_stb),
		.cfg1_wb_we (e1_we), .cfg1_wb_addr (e1_addr),
		.cfg1_wb_data_m2s (e1_m2s), .cfg1_wb_sel (e1_sel),
		.cfg1_wb_data_s2m (e1_s2m), .cfg1_wb_ack (e1_ack), .cfg1_wb_err (e1_err),
		.mem_axi_awid (m_axi_awid), .mem_axi_awaddr (m_axi_awaddr),
		.mem_axi_awlen (m_axi_awlen), .mem_axi_awsize (m_axi_awsize),
		.mem_axi_awburst (m_axi_awburst), .mem_axi_awlock (m_axi_awlock),
		.mem_axi_awcache (m_axi_awcache), .mem_axi_awprot (m_axi_awprot),
		.mem_axi_awatop (),
		.mem_axi_awvalid (m_axi_awvalid), .mem_axi_awready (m_axi_awready),
		.mem_axi_wdata (m_axi_wdata), .mem_axi_wstrb (m_axi_wstrb),
		.mem_axi_wlast (m_axi_wlast), .mem_axi_wvalid (m_axi_wvalid),
		.mem_axi_wready (m_axi_wready),
		.mem_axi_bid (m_axi_bid), .mem_axi_bresp (m_axi_bresp),
		.mem_axi_bvalid (m_axi_bvalid), .mem_axi_bready (m_axi_bready),
		.mem_axi_arid (m_axi_arid), .mem_axi_araddr (m_axi_araddr),
		.mem_axi_arlen (m_axi_arlen), .mem_axi_arsize (m_axi_arsize),
		.mem_axi_arburst (m_axi_arburst), .mem_axi_arlock (m_axi_arlock),
		.mem_axi_arcache (m_axi_arcache), .mem_axi_arprot (m_axi_arprot),
		.mem_axi_arvalid (m_axi_arvalid), .mem_axi_arready (m_axi_arready),
		.mem_axi_rid (m_axi_rid), .mem_axi_rdata (m_axi_rdata),
		.mem_axi_rresp (m_axi_rresp), .mem_axi_rlast (m_axi_rlast),
		.mem_axi_rvalid (m_axi_rvalid), .mem_axi_rready (m_axi_rready),
		.con_clear (con_clear), .con_rd_word (con_rd_word), .con_rd_data (con_rd_data),
		.con_bytes (con_bytes), .con_drops (con_drops), .con_rd_bytes (con_rptr_reg),
		.con_rx_wr (con_rx_wr), .con_rx_data (con_rx_data),
		.con_rx_used (con_rx_used), .con_rx_drops (con_rx_drops),
		.win_err_clear (win_err_clear), .win_err_sticky (win_err_sticky),
		.win_err_was_write (win_err_was_write), .win_err_count (win_err_count),
		.win_err_addr (win_err_addr),
		.core_ndreset (core_ndreset),
		.core0_trace_pc (core0_pc), .core0_trace_valid (core0_pc_valid),
		.core0_trace_priv (core0_priv),
		.core1_trace_pc (core1_pc), .core1_trace_valid (core1_pc_valid),
		.core1_trace_priv (core1_priv)
	);

	// ------------------------------------------------------------------
	// Observation channel PER HART (difference 3 in the header)
	// ------------------------------------------------------------------
	logic        obs_retire0, obs_retire1, obs_arvalid, obs_rvalid;
	logic [31:0] retire_cnt0, retire_cnt1;
	logic [63:0] pc0_seen, pc1_seen;
	logic [2:0]  priv0_seen, priv1_seen;

	always_ff @(posedge clk) begin
		if (rst) begin
			obs_retire0 <= 1'b0; obs_retire1 <= 1'b0;
			obs_arvalid <= 1'b0; obs_rvalid <= 1'b0;
			retire_cnt0 <= '0; retire_cnt1 <= '0;
			pc0_seen <= '0; pc1_seen <= '0; priv0_seen <= '0; priv1_seen <= '0;
		end
		else if (obs_clear) begin
			obs_retire0 <= 1'b0; obs_retire1 <= 1'b0;
			obs_arvalid <= 1'b0; obs_rvalid <= 1'b0;
			retire_cnt0 <= '0; retire_cnt1 <= '0;
		end
		else begin
			if (core0_pc_valid) begin
				obs_retire0 <= 1'b1;
				retire_cnt0 <= retire_cnt0 + 32'd1;
				pc0_seen    <= 64'(core0_pc);
				priv0_seen  <= core0_priv;
			end
			if (core1_pc_valid) begin
				obs_retire1 <= 1'b1;
				retire_cnt1 <= retire_cnt1 + 32'd1;
				pc1_seen    <= 64'(core1_pc);
				priv1_seen  <= core1_priv;
			end
			if (m_axi_arvalid) obs_arvalid <= 1'b1;
			if (m_axi_rvalid)  obs_rvalid  <= 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// Trace sinks (at the FUNNEL output, i.e. both harts in one ring)
	// ------------------------------------------------------------------
	logic [31:0] trace_beats, trace_bytes, trace_rd_word, trace_rd_data;
	uwire logic  trace_wrapped, uram_stopped;
	uwire logic [31:0] ddr_wptr, ddr_drops;
	uwire logic  ddr_full, ddr_axi_err, ddr_wrapped;
	logic        ddr_clear_pulse, pib_clear_pulse;

	ct_soc_trace_ring #(.DEPTH(TRACE_DEPTH)) trace_buf (
		.clk (clk), .rst (rst), .clear (trace_clear),
		.oneshot_i (sink_ctrl_reg[3]),
		.atb_atvalid (atb_atvalid), .atb_atready (1'b1),
		.atb_atdata (atb_atdata), .atb_atbytes (atb_atbytes),
		.beats_o (trace_beats), .bytes_o (trace_bytes), .wrapped_o (trace_wrapped),
		.stopped_o (uram_stopped),
		.rd_word (trace_rd_word), .rd_data (trace_rd_data)
	);

	ct_soc_ddr_sink ddr_sink (
		.clk (clk), .rst (rst),
		.enable_i (sink_ctrl_reg[0]), .clear_i (ddr_clear_pulse),
		.base_i (ddr_base_reg), .size_i (ddr_size_reg), .circ_i (sink_ctrl_reg[2]),
		.beat_valid_i (atb_atvalid), .beat_data_i (atb_atdata),
		.wptr_o (ddr_wptr), .full_o (ddr_full), .wrapped_o (ddr_wrapped),
		.axi_err_o (ddr_axi_err), .drops_o (ddr_drops),
		.m_axi_awaddr (t_axi_awaddr), .m_axi_awlen (t_axi_awlen),
		.m_axi_awsize (t_axi_awsize), .m_axi_awburst (t_axi_awburst),
		.m_axi_awvalid (t_axi_awvalid), .m_axi_awready (t_axi_awready),
		.m_axi_wdata (t_axi_wdata), .m_axi_wstrb (t_axi_wstrb),
		.m_axi_wlast (t_axi_wlast), .m_axi_wvalid (t_axi_wvalid),
		.m_axi_wready (t_axi_wready),
		.m_axi_bresp (t_axi_bresp), .m_axi_bvalid (t_axi_bvalid),
		.m_axi_bready (t_axi_bready)
	);

	ct_soc_pib pib (
		.clk (clk), .rst (rst),
		.enable_i (sink_ctrl_reg[4]), .clear_i (pib_clear_pulse),
		.div_i (sink_ctrl_reg[10:8]), .calib_i (1'b0), .pattern_i (2'b00),
		.beat_valid_i (atb_atvalid), .beat_data_i (atb_atdata),
		.drops_o (), .pib_clk, .pib_data
	);

	// ------------------------------------------------------------------
	// PS AXI4-Lite: CTRL / ENC0 / ENC1 / TRACE / CON
	// ------------------------------------------------------------------
	typedef enum logic [2:0] { SEG_CTRL, SEG_ENC0, SEG_ENC1, SEG_TRACE, SEG_CON } seg_e;
	function automatic seg_e seg_of(input logic [21:0] a);
		if      (a[21:20] == 2'b11) seg_of = SEG_CON;     // 0x30_0000
		else if (a[21:20] == 2'b10) seg_of = SEG_TRACE;   // 0x20_0000
		else if (a[17])             seg_of = SEG_ENC1;    // 0x02_0000
		else if (a[16])             seg_of = SEG_ENC0;    // 0x01_0000
		else                        seg_of = SEG_CTRL;
	endfunction

	logic [21:0] awaddr_q, araddr_q;
	logic [31:0] wdata_q, rdata_q;
	logic        aw_seen, w_seen, rd_busy;
	logic [1:0]  rd_wait;

	logic enc_start, enc_is_wr, enc_sel;   // enc_sel: 0 = ENC0, 1 = ENC1

	// Serialize ENC accesses -- identical to the one-hart SoC. Without this,
	// a read access could take over a write cycle already in flight
	// (finding 2026-07-26: trTeInstFeatures read 0x400a0000, the encoder
	// stayed silent).
	assign s_axi_awready = !aw_seen && !s_axi_bvalid && !enc_start;
	assign s_axi_wready  = !w_seen  && !s_axi_bvalid && !enc_start;
	assign s_axi_arready = !rd_busy && !s_axi_rvalid && !enc_start
	                       && !(aw_seen && w_seen);
	assign s_axi_bresp   = 2'b00;
	assign s_axi_rresp   = 2'b00;
	assign s_axi_rdata   = rdata_q;

	uwire logic        b0_awready, b0_wready, b0_bvalid, b0_arready, b0_rvalid;
	uwire logic [31:0] b0_rdata;
	uwire logic [1:0]  b0_bresp, b0_rresp;
	uwire logic        b1_awready, b1_wready, b1_bvalid, b1_arready, b1_rvalid;
	uwire logic [31:0] b1_rdata;
	uwire logic [1:0]  b1_bresp, b1_rresp;

	// The active bridge -- an access is only ever at one of the two.
	uwire logic        eb_bvalid = enc_sel ? b1_bvalid : b0_bvalid;
	uwire logic        eb_rvalid = enc_sel ? b1_rvalid : b0_rvalid;
	uwire logic [31:0] eb_rdata  = enc_sel ? b1_rdata  : b0_rdata;

	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) enc0_wb ();
	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) enc1_wb ();

	ct_axil_to_wb enc0_bridge (
		.clk (clk), .rst (rst),
		.s_awvalid (enc_start &&  enc_is_wr && !enc_sel), .s_awready (b0_awready),
		.s_awaddr  ({16'b0, awaddr_q[15:0]}),
		.s_wvalid  (enc_start &&  enc_is_wr && !enc_sel), .s_wready  (b0_wready),
		.s_wdata   (wdata_q), .s_wstrb (4'hF),
		.s_bvalid  (b0_bvalid), .s_bready (1'b1), .s_bresp (b0_bresp),
		.s_arvalid (enc_start && !enc_is_wr && !enc_sel), .s_arready (b0_arready),
		.s_araddr  ({16'b0, araddr_q[15:0]}),
		.s_rvalid  (b0_rvalid), .s_rready (1'b1), .s_rdata (b0_rdata),
		.s_rresp   (b0_rresp),
		.wb (enc0_wb.master)
	);

	ct_axil_to_wb enc1_bridge (
		.clk (clk), .rst (rst),
		.s_awvalid (enc_start &&  enc_is_wr &&  enc_sel), .s_awready (b1_awready),
		.s_awaddr  ({16'b0, awaddr_q[15:0]}),
		.s_wvalid  (enc_start &&  enc_is_wr &&  enc_sel), .s_wready  (b1_wready),
		.s_wdata   (wdata_q), .s_wstrb (4'hF),
		.s_bvalid  (b1_bvalid), .s_bready (1'b1), .s_bresp (b1_bresp),
		.s_arvalid (enc_start && !enc_is_wr &&  enc_sel), .s_arready (b1_arready),
		.s_araddr  ({16'b0, araddr_q[15:0]}),
		.s_rvalid  (b1_rvalid), .s_rready (1'b1), .s_rdata (b1_rdata),
		.s_rresp   (b1_rresp),
		.wb (enc1_wb.master)
	);

	assign e0_cyc = enc0_wb.cyc;  assign e0_stb = enc0_wb.stb;
	assign e0_we  = enc0_wb.we;   assign e0_addr = enc0_wb.addr;
	assign e0_m2s = enc0_wb.data_m2s; assign e0_sel = enc0_wb.sel;
	assign enc0_wb.data_s2m = e0_s2m;
	assign enc0_wb.ack      = e0_ack;
	assign enc0_wb.err      = e0_err;

	assign e1_cyc = enc1_wb.cyc;  assign e1_stb = enc1_wb.stb;
	assign e1_we  = enc1_wb.we;   assign e1_addr = enc1_wb.addr;
	assign e1_m2s = enc1_wb.data_m2s; assign e1_sel = enc1_wb.sel;
	assign enc1_wb.data_s2m = e1_s2m;
	assign enc1_wb.ack      = e1_ack;
	assign enc1_wb.err      = e1_err;

	always_ff @(posedge clk) begin
		// Combinational address-decode temporaries. Declared HERE, not at
		// module scope: their lifetime is one evaluation of this block, and
		// a module-scope variable that is blocking-assigned inside an
		// always_ff reads like state that it is not.
		seg_e wseg, rseg;
		if (rst) begin
			control_reg     <= 32'h0000_0000;   // core held in reset, ring empty
			sink_ctrl_reg   <= 32'h0000_0000;
			// Address plan v4 (2026-08-10): 256 MiB trace starting at
			// 0x5000_0000, followed by a 64 MiB GAP (the former window),
			// only then the guest starting at 0x6400_0000. Before this,
			// the window and the guest abutted with zero bytes of margin.
			// Measured: 64 MiB wraps every 2.3 s at 29.7 MB/s, 256 MiB
			// every 9.0 s (docs/handoffs/C1_sink_overrun.md). PS_BASE/
			// WIN_SIZE of the guest are unchanged.
			// WARNING: these values MUST match ctrace_resmem.dtso
			// (correspondence rule, examples/kv260/SPEC_board_memory_map.md). Until
			// a bitstream is built with this reset, rocket2_linux_run.sh
			// restores them at runtime -- and checks them in EVERY case
			// against the live devicetree.
			ddr_base_reg    <= 32'h5000_0000;   // reserved PL window
			ddr_size_reg    <= 32'h1000_0000;   // 256 MiB
			ext_irq_reg     <= 32'h0000_0000;
			funnel_ctrl_reg <= 32'h0000_0011;   // both channels prio 1 = RR
			aw_seen <= 0; w_seen <= 0; s_axi_bvalid <= 0;
			s_axi_rvalid <= 0; rd_busy <= 0; rd_wait <= 0; rdata_q <= '0;
			enc_start <= 0; enc_is_wr <= 0; enc_sel <= 0;
			ddr_clear_pulse <= 0; pib_clear_pulse <= 0;
			trace_rd_word <= '0; con_rd_word <= '0;
			con_rptr_reg <= '0; con_rx_wr <= 1'b0; con_rx_data <= '0;
		end
		else begin
			ddr_clear_pulse <= 1'b0;
			pib_clear_pulse <= 1'b0;
			con_rx_wr       <= 1'b0;
			if (con_clear) con_rptr_reg <= '0;
			if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
			if (s_axi_rvalid && s_axi_rready) begin s_axi_rvalid <= 1'b0; rd_busy <= 1'b0; end

			// --- Write channel ---
			if (s_axi_awvalid && s_axi_awready) begin awaddr_q <= s_axi_awaddr; aw_seen <= 1'b1; end
			if (s_axi_wvalid  && s_axi_wready)  begin wdata_q  <= s_axi_wdata;  w_seen  <= 1'b1; end

			if (aw_seen && w_seen && !s_axi_bvalid && !enc_start) begin
				wseg = seg_of(awaddr_q);
				if (wseg == SEG_ENC0 || wseg == SEG_ENC1) begin
					enc_start <= 1'b1; enc_is_wr <= 1'b1;
					enc_sel   <= (wseg == SEG_ENC1);
				end
				else begin
					if (wseg == SEG_CTRL) begin
						unique case (awaddr_q[6:2])
							5'd0: control_reg <= wdata_q;
							5'd7: begin                     // 0x1C SINK_CTRL
								sink_ctrl_reg   <= wdata_q & 32'hFFFF_FFDD;
								ddr_clear_pulse <= wdata_q[1];
								pib_clear_pulse <= wdata_q[5];
							end
							5'd8: ddr_base_reg <= {wdata_q[31:5], 5'b0};   // 0x20
							5'd9: ddr_size_reg <= {wdata_q[31:2], 2'b0};   // 0x24
							5'd13: begin                                   // 0x34 CON_TX
								con_rx_wr   <= wdata_q[8];
								con_rx_data <= wdata_q[7:0];
							end
							5'd14: con_rptr_reg <= wdata_q;                // 0x38 CON_RPTR
							5'd18: ext_irq_reg  <= wdata_q;                // 0x48 EXT_IRQ
							// 0x58 FUNNEL_CTRL: only the occupied bits, so a
							// write access never sets a reserved bit that
							// later gets a meaning.
							5'd22: funnel_ctrl_reg <= wdata_q & 32'h0000_0133;
							default: ;
						endcase
					end
					aw_seen <= 1'b0; w_seen <= 1'b0; s_axi_bvalid <= 1'b1;
				end
			end
			else if (enc_start && enc_is_wr && eb_bvalid) begin
				enc_start <= 1'b0; enc_is_wr <= 1'b0;
				aw_seen <= 1'b0; w_seen <= 1'b0; s_axi_bvalid <= 1'b1;
			end

			// --- Read channel ---
			if (s_axi_arvalid && s_axi_arready) begin
				araddr_q <= s_axi_araddr;
				rd_busy  <= 1'b1;
				rseg = seg_of(s_axi_araddr);
				unique case (rseg)
					SEG_TRACE: begin trace_rd_word <= {12'b0, s_axi_araddr[21:2]}; rd_wait <= 2'd2; end
					SEG_CON:   begin con_rd_word   <= {12'b0, s_axi_araddr[21:2]}; rd_wait <= 2'd2; end
					SEG_ENC0:  begin enc_start <= 1'b1; enc_is_wr <= 1'b0; enc_sel <= 1'b0; end
					SEG_ENC1:  begin enc_start <= 1'b1; enc_is_wr <= 1'b0; enc_sel <= 1'b1; end
					SEG_CTRL: begin
						unique case (s_axi_araddr[6:2])
							5'd0:    rdata_q <= control_reg;
							5'd1:    rdata_q <= {9'b0, priv1_seen,
							                     obs_retire1, obs_retire0, 3'b0,
							                     priv0_seen,
							                     1'b0, obs_rvalid, obs_arvalid,
							                     obs_retire0 | obs_retire1,
							                     2'b0, ~core_run, core_ndreset,
							                     win_err_was_write, win_err_sticky,
							                     uram_stopped, trace_wrapped};
							5'd2:    rdata_q <= trace_beats;
							5'd3:    rdata_q <= trace_bytes;
							5'd4:    rdata_q <= 32'(TRACE_DEPTH * 4);
							5'd5:    rdata_q <= con_bytes;
							5'd6:    rdata_q <= con_drops;
							5'd7:    rdata_q <= sink_ctrl_reg;
							5'd8:    rdata_q <= ddr_base_reg;
							5'd9:    rdata_q <= ddr_size_reg;
							5'd10:   rdata_q <= ddr_wptr;
							5'd11:   rdata_q <= {28'b0, uram_stopped, ddr_wrapped, ddr_axi_err, ddr_full};
							5'd12:   rdata_q <= ddr_drops;
							5'd13:   rdata_q <= {con_rx_drops[15:0], con_rx_used}; // 0x34
							5'd14:   rdata_q <= con_rptr_reg;                      // 0x38
							5'd15:   rdata_q <= win_err_count;                     // 0x3C
							5'd16:   rdata_q <= win_err_addr[31:0];                // 0x40
							5'd17:   rdata_q <= win_err_addr[63:32];               // 0x44
							5'd18:   rdata_q <= ext_irq_reg;                       // 0x48
							5'd19:   rdata_q <= pc0_seen[31:0];                    // 0x4C
							5'd20:   rdata_q <= pc0_seen[63:32];                   // 0x50
							5'd21:   rdata_q <= retire_cnt0;                       // 0x54
							// 0x58: reads the register back plus the
							// acknowledgement in a FREE bit. An OR into bit 0
							// would be a bug -- that bit holds priority
							// channel 0, and a stuck flush_done would OR it
							// to 1 on read.
							5'd22:   rdata_q <= {15'b0, funnel_flush_done, 16'b0}
							                    | funnel_ctrl_reg;                 // 0x58
							5'd23:   rdata_q <= pc1_seen[31:0];                    // 0x5C
							5'd24:   rdata_q <= pc1_seen[63:32];                   // 0x60
							5'd25:   rdata_q <= retire_cnt1;                       // 0x64
							default: rdata_q <= '0;
						endcase
						s_axi_rvalid <= 1'b1;
					end
				endcase
			end
			else if (rd_busy && !s_axi_rvalid) begin
				if (enc_start && !enc_is_wr) begin
					if (eb_rvalid) begin
						rdata_q <= eb_rdata; enc_start <= 1'b0; s_axi_rvalid <= 1'b1;
					end
				end
				else if (rd_wait != 0) rd_wait <= rd_wait - 2'd1;
				else begin
					rdata_q      <= (seg_of(araddr_q) == SEG_CON) ? con_rd_data : trace_rd_data;
					s_axi_rvalid <= 1'b1;
				end
			end
		end
	end

`ifndef SYNTHESIS
	// Like the one-hart branch: after the window translation, EVERY allowed
	// access lies inside the PS window; everything else has been rejected
	// by the guard.
	always_ff @(posedge clk) begin
		if (!rst && core_run && m_axi_arvalid) begin
			assert (m_axi_araddr >= PS_BASE && m_axi_araddr < PS_BASE + WIN_SIZE)
				else $error("rocket2_soc_top: read access outside the PS window: 0x%h", m_axi_araddr);
		end
	end
	// Two-hart-specific: the funnel may only ever output ONE stream, and the
	// ring must never lose beats since it is always ready.
	always_ff @(posedge clk) begin
		if (!rst && atb_atvalid) begin
			assert (atb_atbytes <= 2'd3)
				else $error("rocket2_soc_top: ATBYTES %0d outside the contract", atb_atbytes);
		end
	end
`endif

endmodule

`default_nettype wire
