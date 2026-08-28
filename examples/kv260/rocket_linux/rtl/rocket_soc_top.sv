// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Rocket RV64 SoC with CTTE (RV64 program, package R4a).
 *
 * @details
 *   The counterpart to cva6_linux_soc_top for the Rocket64t1 branch. One
 *   core, one CTTE instance, everything controllable from the PS:
 *
 *     rocket_soc_synth_wrap   Rocket generat (CLINT + PLIC + bootrom ARE
 *                             inside it) + 8250 console + window guard +
 *                             shim + ct_encoder                     (L4)
 *     ct_soc_trace_ring       1-MiB URAM ring on the ATB
 *     ct_soc_ddr_sink         linear DDR sink for long windows
 *     ct_soc_pib              parallel trace port (optional)
 *
 *   THREE differences from the CVA6 Linux SoC, all from the L2 inventory:
 *     1. NO cva6_linux_periph -- CLINT and PLIC live in the generat, and the
 *        console is board RTL INSIDE the wrapper (rocket_con_8250 on the
 *        mmio_axi4 port @0x6001_0000). The SoC top only sees the PS side of
 *        the ring (con_*) anymore.
 *     2. NO cva6_linux_mem_xbar -- the Rocket resolves the A-extension
 *        internally (TLAtomicAutomata / L1D); only simple accesses remain at
 *        the AXI4 memory port, and the address demux is the window guard
 *        inside the wrapper (guest 0x8000_0000 -> PS DDR 0x6400_0000).
 *     3. NEW: the window guard's diagnosis is readable via devmem
 *        (WIN_ERR_*). Without it, "the core is hung" is indistinguishable
 *        from "the guard tripped" -- exactly the C6 lesson that forced the
 *        observation channel for the Trio (trio_soc_top.sv:214-227).
 *
 *   Memory view of the CORE (Rocket bus decoder, not freely choosable --
 *   D-L2-1):
 *     0x0200_0000  CLINT     (in the generat)
 *     0x0C00_0000  PLIC      (in the generat)
 *     0x0001_0000  bootrom   (in the generat, single-word patch D-L2-4)
 *     0x6001_0000  8250 console (MMIO window 0x4000_0000..0x7FFF_FFFF)
 *     0x8000_0000  RAM       -> window guard -> PS DDR 0x6400_0000
 *
 *   Address map of the PS aperture (22 bit, like the CVA6 Linux design):
 *     0x00_0000  CTRL    CONTROL, STATUS, TRACE_x, SINK_x, DDR_x, CON_x, WIN_x
 *     0x01_0000  ENC     CTTE CSRs (ct_axil_to_wb)
 *     0x20_0000  TRACE   trace ring (word read accesses)
 *     0x30_0000  CON     console ring (word read accesses)
 *
 *   CTRL registers (word offsets, 5-bit decode [6:2] -- one row more than the
 *   CVA6 design because guard diagnosis and a 64-bit PC are added):
 *     0x00 CONTROL  (rw) b0 core_run (0 = hold the Rocket in reset, load image)
 *                        b1 trace_clear  b2 con_clear  b3 win_err_clear
 *                        b4 obs_clear (clear the observation-channel sticky)
 *     0x04 STATUS   (ro) b0 trace_wrapped   b1 uram_stopped
 *                        b2 win_err_sticky  b3 win_err_was_write
 *                        b4 core_ndreset    b5 core_rst_hold
 *                        b[10:8]  observation sticky {rvalid_seen,
 *                                 arvalid_seen, retire_seen}
 *                        b[14:12] last privilege level observed
 *     0x08 TRACE_BEATS (ro)   0x0C TRACE_BYTES (ro)  0x10 TRACE_BUFSZ (ro)
 *     0x14 CON_BYTES   (ro)   0x18 CON_DROPS  (ro)
 *     0x1C SINK_CTRL   (rw) b0 ddr_en b1 ddr_clear b2 ddr_circ b3 uram_oneshot
 *                           b4 pib_en b5 pib_clear b[10:8] pib_div
 *     0x20 DDR_BASE    (rw)   0x24 DDR_SIZE (rw)  0x28 DDR_WPTR (ro)
 *     0x2C SINK_STAT   (ro)   0x30 DDR_DROPS (ro)
 *     0x34 CON_TX      (w)  b[7:0] character, b8 = commit
 *                      (ro) b[15:0] slots used, b[31:16] dropped
 *     0x38 CON_RPTR    (rw) the PS's read pointer into the console ring (bytes)
 *     0x3C WIN_ERR_CNT (ro) rejections by the window guard
 *     0x40 WIN_ERR_LO  (ro) address of the FIRST rejection, bits 31:0
 *     0x44 WIN_ERR_HI  (ro) same address, bits 63:32
 *     0x48 EXT_IRQ     (rw) b[7:0] -> the generat's PLIC inputs
 *     0x4C PC_LO       (ro) last retired PC, bits 31:0
 *     0x50 PC_HI       (ro) same PC, bits 63:32 (reads 0 today, see below)
 *     0x54 RETIRES     (ro) free-running retire counter (heartbeat)
 *
 *   PC_LO/PC_HI are built WIDTH-AGNOSTIC: `core_trace_pc` arrives from the
 *   wrapper with tip_pkg::TIP_IADDRESS_WIDTH and is zero-extended to 64 bit
 *   here. At today's 32-bit encoder stand, PC_HI reads 0; once the encoder
 *   tree is at CT_XLEN=64 (package R1.1), the same logic carries the full
 *   RV64 PC without a single line here needing a change.
 */
module rocket_soc_top #(
	// Window translation (forwarded to rocket_soc_synth_wrap).
	// WIN_BASE is the GUEST view and fixed by the Rocket bus decoder
	// (D-L2-1); PS_BASE is the reserved PL DDR window from
	// examples/kv260/SPEC_board_memory_map.md. WIN_SIZE must match the memory node in
	// sw/rocket_linux/rocket_kv260_rv64.dts.
	longint unsigned WIN_BASE    = 64'h8000_0000,
	longint unsigned WIN_SIZE    = 64'h0C00_0000,   // 192 MiB
	longint unsigned PS_BASE     = 64'h6400_0000,
	longint unsigned UART_BASE   = 64'h6001_0000,
	int unsigned     CON_BYTES   = 65536,
	int unsigned     TRACE_DEPTH = 262144,          // 1 MiB URAM
	bit              EN_ETRACE   = 1'b1
) (
	input  uwire logic        clk,
	input  uwire logic        resetn,

	// --- PS AXI4-Lite slave (control + readout) --------------------------
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

	// --- Rocket memory path: AXI4 to the PS HP port (64 bit) -------------
	// Addresses are ALREADY translated (PS view) -- the guard sits in the
	// wrapper in front and rejects everything outside the window with
	// DECERR.
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

	// --- Trace DDR sink: AXI4 write-only (second HP port) ----------------
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

	// --- PIB (optional, like the Trio/CVA6) -------------------------------
	output      logic         pib_clk,
	output      logic [3:0]   pib_data
);

	uwire logic rst = ~resetn;

	// ------------------------------------------------------------------
	// CTRL registers
	// ------------------------------------------------------------------
	logic [31:0] control_reg, sink_ctrl_reg, ddr_base_reg, ddr_size_reg;
	logic [31:0] ext_irq_reg;
	uwire logic core_run      = control_reg[0];
	uwire logic trace_clear   = control_reg[1];
	uwire logic con_clear     = control_reg[2];
	uwire logic win_err_clear = control_reg[3];
	uwire logic obs_clear     = control_reg[4];

	// ------------------------------------------------------------------
	// Core + encoder (the whole branch sits in one instance -- L4)
	// ------------------------------------------------------------------
	uwire logic [31:0] atb_atdata;
	uwire logic [1:0]  atb_atbytes;
	uwire logic [6:0]  atb_atid;
	uwire logic        atb_atvalid, atb_te_raw, atb_afready;
	uwire logic [tip_pkg::TIP_IADDRESS_WIDTH-1:0] core_pc;
	uwire logic        core_pc_valid;
	uwire logic [2:0]  core_priv;
	uwire logic        core_ndreset;

	// Console, PS side
	logic [31:0]       con_rd_word;
	uwire logic [31:0] con_rd_data, con_bytes, con_drops, con_rx_drops;
	uwire logic [15:0] con_rx_used;
	logic [31:0]       con_rptr_reg;
	logic              con_rx_wr;
	logic [7:0]        con_rx_data;

	// Window guard diagnosis
	uwire logic        win_err_sticky, win_err_was_write;
	uwire logic [31:0] win_err_count;
	uwire logic [63:0] win_err_addr;

	// Wishbone bridge for the encoder CSRs
	uwire logic        enc_wb_en, enc_wb_cyc, enc_wb_stb, enc_wb_we;
	uwire logic [31:0] enc_wb_addr, enc_wb_m2s;
	uwire logic [3:0]  enc_wb_sel;
	uwire logic [31:0] enc_wb_s2m;
	uwire logic        enc_wb_ack, enc_wb_err;

	rocket_soc_synth_wrap #(
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
		.cfg_wb_en (enc_wb_en), .cfg_wb_cyc (enc_wb_cyc), .cfg_wb_stb (enc_wb_stb),
		.cfg_wb_we (enc_wb_we), .cfg_wb_addr (enc_wb_addr),
		.cfg_wb_data_m2s (enc_wb_m2s), .cfg_wb_sel (enc_wb_sel),
		.cfg_wb_data_s2m (enc_wb_s2m), .cfg_wb_ack (enc_wb_ack), .cfg_wb_err (enc_wb_err),
		.mem_axi_awid (m_axi_awid), .mem_axi_awaddr (m_axi_awaddr),
		.mem_axi_awlen (m_axi_awlen), .mem_axi_awsize (m_axi_awsize),
		.mem_axi_awburst (m_axi_awburst), .mem_axi_awlock (m_axi_awlock),
		.mem_axi_awcache (m_axi_awcache), .mem_axi_awprot (m_axi_awprot),
		// The guard drives atop constant 0 (the Rocket resolves the
		// A-extension internally); the PS HP port has no atop input anyway.
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
		.core_trace_pc (core_pc), .core_trace_valid (core_pc_valid),
		.core_trace_priv (core_priv)
	);

	// ------------------------------------------------------------------
	// Observation channel (C6 lesson, trio_soc_top.sv:214-227)
	// ------------------------------------------------------------------
	// On the board, "the core is hung" and "the encoder is silent" cannot be
	// told apart without these four sticky bits -- for the Trio that cost
	// half a day. Cheap (four FFs), hence present from the start. In
	// addition a free-running retire counter and the last PC seen: a second
	// devmem two seconds later then immediately says whether the core is
	// still making progress (diagnostic ladder §14.3).
	logic        obs_retire, obs_arvalid, obs_rvalid;
	logic [31:0] retire_cnt;
	logic [63:0] pc_seen;
	logic [2:0]  priv_seen;

	always_ff @(posedge clk) begin
		if (rst) begin
			obs_retire <= 1'b0; obs_arvalid <= 1'b0; obs_rvalid <= 1'b0;
			retire_cnt <= '0; pc_seen <= '0; priv_seen <= '0;
		end
		else if (obs_clear) begin
			obs_retire <= 1'b0; obs_arvalid <= 1'b0; obs_rvalid <= 1'b0;
			retire_cnt <= '0;
		end
		else begin
			if (core_pc_valid) begin
				obs_retire <= 1'b1;
				retire_cnt <= retire_cnt + 32'd1;
				pc_seen    <= 64'(core_pc);
				priv_seen  <= core_priv;
			end
			if (m_axi_arvalid) obs_arvalid <= 1'b1;
			if (m_axi_rvalid)  obs_rvalid  <= 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// Trace sinks
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
	// PS AXI4-Lite: CTRL / ENC / TRACE / CON
	// ------------------------------------------------------------------
	typedef enum logic [1:0] { SEG_CTRL, SEG_ENC, SEG_TRACE, SEG_CON } seg_e;
	function automatic seg_e seg_of(input logic [21:0] a);
		if      (a[21:20] == 2'b11) seg_of = SEG_CON;     // 0x30_0000
		else if (a[21:20] == 2'b10) seg_of = SEG_TRACE;   // 0x20_0000
		else if (a[16])             seg_of = SEG_ENC;     // 0x01_0000
		else                        seg_of = SEG_CTRL;
	endfunction

	logic [21:0] awaddr_q, araddr_q;
	logic [31:0] wdata_q, rdata_q;
	logic        aw_seen, w_seen, rd_busy;
	logic [1:0]  rd_wait;

	// Serialize ENC accesses -- identical to the CVA6 Linux SoC. Without
	// this, a read access could take over a write cycle already in flight
	// (finding 2026-07-26: trTeInstFeatures read 0x400a0000, the encoder
	// stayed silent).
	assign s_axi_awready = !aw_seen && !s_axi_bvalid && !enc_start;
	assign s_axi_wready  = !w_seen  && !s_axi_bvalid && !enc_start;
	assign s_axi_arready = !rd_busy && !s_axi_rvalid && !enc_start
	                       && !(aw_seen && w_seen);
	assign s_axi_bresp   = 2'b00;
	assign s_axi_rresp   = 2'b00;
	assign s_axi_rdata   = rdata_q;

	logic enc_start, enc_is_wr;
	uwire logic        eb_awready, eb_wready, eb_bvalid, eb_arready, eb_rvalid;
	uwire logic [31:0] eb_rdata;
	uwire logic [1:0]  eb_bresp, eb_rresp;

	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) enc_wb ();

	ct_axil_to_wb enc_bridge (
		.clk (clk), .rst (rst),
		.s_awvalid (enc_start &&  enc_is_wr), .s_awready (eb_awready),
		.s_awaddr  ({16'b0, awaddr_q[15:0]}),
		.s_wvalid  (enc_start &&  enc_is_wr), .s_wready  (eb_wready),
		.s_wdata   (wdata_q), .s_wstrb (4'hF),
		.s_bvalid  (eb_bvalid), .s_bready (1'b1), .s_bresp (eb_bresp),
		.s_arvalid (enc_start && !enc_is_wr), .s_arready (eb_arready),
		.s_araddr  ({16'b0, araddr_q[15:0]}),
		.s_rvalid  (eb_rvalid), .s_rready (1'b1), .s_rdata (eb_rdata),
		.s_rresp   (eb_rresp),
		.wb (enc_wb.master)
	);

	assign enc_wb_en   = enc_wb.cyc;
	assign enc_wb_cyc  = enc_wb.cyc;
	assign enc_wb_stb  = enc_wb.stb;
	assign enc_wb_we   = enc_wb.we;
	assign enc_wb_addr = enc_wb.addr;
	assign enc_wb_m2s  = enc_wb.data_m2s;
	assign enc_wb_sel  = enc_wb.sel;
	assign enc_wb.data_s2m = enc_wb_s2m;
	assign enc_wb.ack      = enc_wb_ack;
	assign enc_wb.err      = enc_wb_err;

	always_ff @(posedge clk) begin
		// Combinational address-decode temporaries. Declared HERE, not at
		// module scope: their lifetime is one evaluation of this block, and
		// a module-scope variable that is blocking-assigned inside an
		// always_ff reads like state that it is not.
		seg_e wseg, rseg;
		if (rst) begin
			control_reg   <= 32'h0000_0000;     // core held in reset, ring empty
			sink_ctrl_reg <= 32'h0000_0000;
			ddr_base_reg  <= 32'h6000_0000;     // reserved PL window
			ddr_size_reg  <= 32'h0400_0000;     // 64 MiB
			ext_irq_reg   <= 32'h0000_0000;
			aw_seen <= 0; w_seen <= 0; s_axi_bvalid <= 0;
			s_axi_rvalid <= 0; rd_busy <= 0; rd_wait <= 0; rdata_q <= '0;
			enc_start <= 0; enc_is_wr <= 0;
			ddr_clear_pulse <= 0; pib_clear_pulse <= 0;
			trace_rd_word <= '0; con_rd_word <= '0;
			con_rptr_reg <= '0; con_rx_wr <= 1'b0; con_rx_data <= '0;
		end
		else begin
			ddr_clear_pulse <= 1'b0;
			pib_clear_pulse <= 1'b0;
			con_rx_wr       <= 1'b0;     // one-cycle pulse
			// con_clear sets CON_BYTES to 0 -- the read pointer MUST go back
			// with it, otherwise the ring would report itself permanently
			// full.
			if (con_clear) con_rptr_reg <= '0;
			if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
			if (s_axi_rvalid && s_axi_rready) begin s_axi_rvalid <= 1'b0; rd_busy <= 1'b0; end

			// --- Write channel ---
			if (s_axi_awvalid && s_axi_awready) begin awaddr_q <= s_axi_awaddr; aw_seen <= 1'b1; end
			if (s_axi_wvalid  && s_axi_wready)  begin wdata_q  <= s_axi_wdata;  w_seen  <= 1'b1; end

			if (aw_seen && w_seen && !s_axi_bvalid && !enc_start) begin
				wseg = seg_of(awaddr_q);
				if (wseg == SEG_ENC) begin
					enc_start <= 1'b1; enc_is_wr <= 1'b1;   // kick off the bridge
				end
				else begin
					if (wseg == SEG_CTRL) begin
						unique case (awaddr_q[6:2])
							5'd0: control_reg <= wdata_q;
							5'd7: begin                    // 0x1C SINK_CTRL
								sink_ctrl_reg   <= wdata_q & 32'hFFFF_FFDD;
								ddr_clear_pulse <= wdata_q[1];
								pib_clear_pulse <= wdata_q[5];
							end
							5'd8: ddr_base_reg <= {wdata_q[31:5], 5'b0};   // 0x20
							5'd9: ddr_size_reg <= {wdata_q[31:2], 2'b0};   // 0x24
							5'd13: begin                                   // 0x34 CON_TX
								// b8 = "commit" -- without this valid bit, a
								// write with value 0 would not be
								// distinguishable from a NUL character.
								con_rx_wr   <= wdata_q[8];
								con_rx_data <= wdata_q[7:0];
							end
							5'd14: con_rptr_reg <= wdata_q;                // 0x38 CON_RPTR
							5'd18: ext_irq_reg  <= wdata_q;                // 0x48 EXT_IRQ
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
					SEG_ENC:   begin enc_start <= 1'b1; enc_is_wr <= 1'b0; end
					SEG_CTRL: begin
						unique case (s_axi_araddr[6:2])
							5'd0:    rdata_q <= control_reg;
							5'd1:    rdata_q <= {17'b0, priv_seen,
							                     1'b0, obs_rvalid, obs_arvalid, obs_retire,
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
							5'd19:   rdata_q <= pc_seen[31:0];                     // 0x4C
							5'd20:   rdata_q <= pc_seen[63:32];                    // 0x50
							5'd21:   rdata_q <= retire_cnt;                        // 0x54
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
					// Ring read ports respond registered (2 cycles)
					rdata_q      <= (seg_of(araddr_q) == SEG_CON) ? con_rd_data : trace_rd_data;
					s_axi_rvalid <= 1'b1;
				end
			end
		end
	end

`ifndef SYNTHESIS
	// The core may only run if it is actually given memory: after the
	// window translation, EVERY allowed access lies inside the PS window.
	// Everything else has already been rejected by the guard and must never
	// appear here (negative test G2a of the L4 package).
	always_ff @(posedge clk) begin
		if (!rst && core_run && m_axi_arvalid) begin
			assert (m_axi_araddr >= PS_BASE && m_axi_araddr < PS_BASE + WIN_SIZE)
				else $error("rocket_soc_top: read access outside the PS window: 0x%h", m_axi_araddr);
		end
	end
`endif

endmodule

`default_nettype wire
