// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    RV64 Linux CVA6 SoC with CTTE (single core, single encoder).
 *
 * @details
 *   ADDITIVE RV64 variant of `cva6_linux_soc_top` (in
 *   [`../../cva6_linux/rtl/`](../../cva6_linux/rtl/)). The RV32 file stays
 *   unchanged -- it carries the board-proven boot path (2026-07-27).
 *
 *   Structure, register map and PS aperture are IDENTICAL to the RV32
 *   version (same CTRL offsets, same segments, same semantics), so the PS
 *   tooling (devmem scripts, dashboard) keeps working unchanged:
 *
 *     cva6_soc64_synth_wrap  CVA6 cv64a6_imac_sv39_ctrace (delta D6: RV64IMAC,
 *                            no FPU, Sv39, S+U, NrCommitPorts=1)
 *                            + RVFI + ITI + shim + ct_encoder
 *     cva6_linux_mem_xbar    atomics resolution + address demux
 *                            (**RISCV_WORD_WIDTH = 64**, see below)
 *     cva6_linux64_periph    CLINT (64-bit accesses!) + 8250 console ring
 *     ct_soc_trace_ring      1 MiB URAM ring on the ATB
 *     ct_soc_ddr_sink        linear DDR sink for long windows
 *     ct_soc_pib             parallel trace port (optional)
 *
 *   Core's own memory view (unchanged from RV32):
 *     0x0200_0000  CLINT (mtime/mtimecmp/msip)
 *     0x1000_0000  UART  (8250, TX ring + RX FIFO)
 *     from DRAM_BASE  PS DDR window (default 0x6400_0000, 192 MiB)
 *
 *   PS aperture address map (22 bit) and CTRL registers: see
 *   cva6_linux_soc_top.sv -- word for word the same map.
 *
 *   THREE RV64 deltas, each a boot stopper if missing:
 *
 *   1. **`RISCV_WORD_WIDTH = 64` on the atomics block.** The PULP block
 *      rejects AMOs whose `awsize` is larger than the configured word width
 *      (axi_riscv_amos.sv:286). With 32, every `amoadd.d` -- i.e. every
 *      kernel spinlock -- fails. The parameter is new on the (otherwise
 *      already fully width-parametric) `cva6_linux_mem_xbar`; default 32 =
 *      the RV32 state.
 *   2. **`cva6_linux64_periph`** serves CLINT write accesses exactly by
 *      byte strobe (one `sd` on `mtimecmp`), instead of selecting a 32-bit
 *      half. Without this, `mtimecmp[63:32]` keeps its reset value and
 *      `timer_irq` never fires (details in that file's own header).
 *   3. **`sw_irq` (msip) goes to the core.** The RV32 shell tied `ipi_i` to
 *      0; OpenSBI already uses IPI in the single-core start sequence.
 *
 *   Size correspondence rule (`third_party/CVA6_PIN.md` D5):
 *     DRAM_SIZE == the memory node in sw/cva6_linux64/cva6_kv260_rv64.dts
 *               == ExecuteRegionLength in cv64a6_imac_sv39_ctrace_config_pkg.sv
 *     = 0x0C00_0000 (192 MiB) starting at 0x6400_0000.
 *   NOTE for the bitstream stage: `CachedRegionLength` in D6 is also set to
 *   192 MiB; the board-proven conservative state is 64 MiB. This concerns
 *   the CORE configuration, not this module -- noted here only as a
 *   reminder because the two numbers are easily confused.
 */
module cva6_linux64_soc_top #(
	logic [63:0] BOOT_ADDR   = 64'h6400_0000,   // OpenSBI entry == start of RAM
	// Guest RAM size. BOOT_ADDR + DRAM_SIZE is also the hard address
	// boundary in the memory path (see cva6_linux_mem_xbar).
	logic [63:0] DRAM_SIZE   = 64'h0C00_0000,   // 192 MiB (SPEC v3)
	logic [31:0] CLINT_BASE  = 32'h0200_0000,
	logic [31:0] UART_BASE   = 32'h1000_0000,
	int unsigned CLK_HZ      = 75_000_000,
	int unsigned TICK_HZ     = 1_000_000,
	int unsigned CON_BYTES   = 65536,
	int unsigned TRACE_DEPTH = 262144,          // 1 MiB URAM
	bit          EN_ETRACE   = 1'b0             // backend PER INSTANCE (dual retired); 0 = N-Trace
) (
	input  uwire logic        clk,
	input  uwire logic        resetn,

	// --- PS AXI4-Lite slave (control + readback) -------------------------
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

	// --- CVA6 memory path: AXI4 to the PS HP port (64 bit) ---------------
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

	// --- PIB (optional, same as the trio example) -------------------------
	output      logic         pib_clk,
	output      logic [3:0]   pib_data
);

	uwire logic rst = ~resetn;

	// ------------------------------------------------------------------
	// CTRL registers
	// ------------------------------------------------------------------
	logic [31:0] control_reg, sink_ctrl_reg, ddr_base_reg, ddr_size_reg;
	uwire logic core_run    = control_reg[0];
	uwire logic trace_clear = control_reg[1];
	uwire logic con_clear   = control_reg[2];

	// ------------------------------------------------------------------
	// Core + encoder
	// ------------------------------------------------------------------
	uwire logic [31:0] atb_atdata;
	uwire logic [1:0]  atb_atbytes;
	uwire logic [6:0]  atb_atid;
	uwire logic        atb_atvalid, atb_te_raw, atb_afready;
	uwire logic [63:0] core_pc;
	uwire logic [1:0]  core_priv;
	uwire logic        core_pc_valid;
	uwire logic        timer_irq, sw_irq;

	// CVA6 master (before the atomics/demux block)
	uwire logic [3:0]  c_awid, c_arid;
	uwire logic [63:0] c_awaddr, c_araddr;
	uwire logic [7:0]  c_awlen, c_arlen;
	uwire logic [2:0]  c_awsize, c_arsize;
	uwire logic [1:0]  c_awburst, c_arburst;
	uwire logic [5:0]  c_awatop;
	// lock/cache/prot MUST be passed through. In particular lock:
	// axi_riscv_lrsc recognizes LR/SC via the AXI4 exclusive signals. If
	// they are tied to 0, lr.d reads correctly but sc.d never gets EXOKAY
	// and ALWAYS fails -- every atomic_cmpxchg is then dead. Visible on the
	// board as "sbi_hsm_hart_start_finish: ERR: The hart is in invalid
	// state" (2026-07-27, isolated with sw/cva6_char/lrsc_test.S).
	uwire logic        c_awlock, c_arlock;
	uwire logic [3:0]  c_awcache, c_arcache;
	uwire logic [2:0]  c_awprot, c_arprot;
	uwire logic        c_awvalid, c_wvalid, c_wlast, c_arvalid, c_bready, c_rready;
	uwire logic [63:0] c_wdata;
	uwire logic [7:0]  c_wstrb;
	logic              c_awready, c_wready, c_arready, c_bvalid, c_rvalid, c_rlast;
	logic [3:0]        c_bid, c_rid;
	logic [1:0]        c_bresp, c_rresp;
	logic [63:0]       c_rdata;

	// Wishbone bridge for the encoder CSRs
	uwire logic        enc_wb_en, enc_wb_cyc, enc_wb_stb, enc_wb_we;
	uwire logic [31:0] enc_wb_addr, enc_wb_m2s;
	uwire logic [3:0]  enc_wb_sel;
	uwire logic [31:0] enc_wb_s2m;
	uwire logic        enc_wb_ack, enc_wb_err;

	cva6_soc64_synth_wrap #(
		.BOOT_ADDR (BOOT_ADDR),
		.HART_ID   (64'd0),   // single core -> hart 0 (see the comment there)
		.EN_ETRACE (EN_ETRACE)
	) soc (
		.clk (clk), .rst (rst),
		.core_rst_hold (~core_run),
		.time_irq (timer_irq),
		.sw_irq   (sw_irq),
		.atb_atdata, .atb_atbytes, .atb_atid, .atb_atvalid,
		.atb_atready (1'b1),
		.atb_afready, .atb_te_raw,
		.atb_afvalid (1'b0), .atb_syncreq (1'b0),
		.cfg_wb_en (enc_wb_en), .cfg_wb_cyc (enc_wb_cyc), .cfg_wb_stb (enc_wb_stb),
		.cfg_wb_we (enc_wb_we), .cfg_wb_addr (enc_wb_addr),
		.cfg_wb_data_m2s (enc_wb_m2s), .cfg_wb_sel (enc_wb_sel),
		.cfg_wb_data_s2m (enc_wb_s2m), .cfg_wb_ack (enc_wb_ack), .cfg_wb_err (enc_wb_err),
		.mem_axi_awid (c_awid), .mem_axi_awaddr (c_awaddr), .mem_axi_awlen (c_awlen),
		.mem_axi_awsize (c_awsize), .mem_axi_awburst (c_awburst), .mem_axi_awlock (c_awlock),
		.mem_axi_awcache (c_awcache), .mem_axi_awprot (c_awprot), .mem_axi_awatop (c_awatop),
		.mem_axi_awvalid (c_awvalid), .mem_axi_awready (c_awready),
		.mem_axi_wdata (c_wdata), .mem_axi_wstrb (c_wstrb), .mem_axi_wlast (c_wlast),
		.mem_axi_wvalid (c_wvalid), .mem_axi_wready (c_wready),
		.mem_axi_bid (c_bid), .mem_axi_bresp (c_bresp), .mem_axi_bvalid (c_bvalid),
		.mem_axi_bready (c_bready),
		.mem_axi_arid (c_arid), .mem_axi_araddr (c_araddr), .mem_axi_arlen (c_arlen),
		.mem_axi_arsize (c_arsize), .mem_axi_arburst (c_arburst), .mem_axi_arlock (c_arlock),
		.mem_axi_arcache (c_arcache), .mem_axi_arprot (c_arprot),
		.mem_axi_arvalid (c_arvalid), .mem_axi_arready (c_arready),
		.mem_axi_rid (c_rid), .mem_axi_rdata (c_rdata), .mem_axi_rresp (c_rresp),
		.mem_axi_rlast (c_rlast), .mem_axi_rvalid (c_rvalid), .mem_axi_rready (c_rready),
		.core_trace_pc (core_pc), .core_trace_priv (core_priv),
		.core_trace_valid (core_pc_valid)
	);

	// ------------------------------------------------------------------
	// Memory path: atomics + demux
	// ------------------------------------------------------------------
	uwire logic [31:0] p_awaddr, p_araddr;
	uwire logic        p_awvalid, p_wvalid, p_arvalid, p_bready, p_rready;
	uwire logic [63:0] p_wdata;
	uwire logic [7:0]  p_wstrb;
	logic              p_awready, p_wready, p_bvalid, p_arready, p_rvalid;
	logic [1:0]        p_bresp, p_rresp;
	logic [63:0]       p_rdata;

	cva6_linux_mem_xbar #(
		.PERIPH_BASE (CLINT_BASE),
		// covers CLINT (0x0200_0000) up to and including UART (0x1000_0000)
		.PERIPH_SIZE (32'h1000_1000),
		// Guest RAM exactly as large as the memory node in the device tree.
		// The trace sink (0x6000_0000 +64 MiB) is thereby OUTSIDE and
		// unreachable for the guest -- it could otherwise overwrite its own
		// capture.
		.DRAM_BASE   (BOOT_ADDR[31:0]),
		.DRAM_SIZE   (DRAM_SIZE[31:0]),
		// RV64: otherwise the atomics block rejects every 8-byte AMO (see header)
		.RISCV_WORD_WIDTH (64)
	) xbar (
		.clk (clk), .rst (rst),
		.c_awid, .c_awaddr, .c_awlen, .c_awsize, .c_awburst,
		.c_awlock, .c_awcache, .c_awprot, .c_awatop,
		.c_awvalid, .c_awready,
		.c_wdata, .c_wstrb, .c_wlast, .c_wvalid, .c_wready,
		.c_bid, .c_bresp, .c_bvalid, .c_bready,
		.c_arid, .c_araddr, .c_arlen, .c_arsize, .c_arburst,
		.c_arlock, .c_arcache, .c_arprot,
		.c_arvalid, .c_arready,
		.c_rid, .c_rdata, .c_rresp, .c_rlast, .c_rvalid, .c_rready,
		.m_awid (m_axi_awid), .m_awaddr (m_axi_awaddr), .m_awlen (m_axi_awlen),
		.m_awsize (m_axi_awsize), .m_awburst (m_axi_awburst), .m_awlock (m_axi_awlock),
		.m_awcache (m_axi_awcache), .m_awprot (m_axi_awprot), .m_awatop (),
		.m_awvalid (m_axi_awvalid), .m_awready (m_axi_awready),
		.m_wdata (m_axi_wdata), .m_wstrb (m_axi_wstrb), .m_wlast (m_axi_wlast),
		.m_wvalid (m_axi_wvalid), .m_wready (m_axi_wready),
		.m_bid (m_axi_bid), .m_bresp (m_axi_bresp), .m_bvalid (m_axi_bvalid),
		.m_bready (m_axi_bready),
		.m_arid (m_axi_arid), .m_araddr (m_axi_araddr), .m_arlen (m_axi_arlen),
		.m_arsize (m_axi_arsize), .m_arburst (m_axi_arburst), .m_arlock (m_axi_arlock),
		.m_arcache (m_axi_arcache), .m_arprot (m_axi_arprot),
		.m_arvalid (m_axi_arvalid), .m_arready (m_axi_arready),
		.m_rid (m_axi_rid), .m_rdata (m_axi_rdata), .m_rresp (m_axi_rresp),
		.m_rlast (m_axi_rlast), .m_rvalid (m_axi_rvalid), .m_rready (m_axi_rready),
		.p_awaddr, .p_awvalid, .p_awready, .p_wdata, .p_wstrb, .p_wvalid, .p_wready,
		.p_bresp, .p_bvalid, .p_bready,
		.p_araddr, .p_arvalid, .p_arready, .p_rdata, .p_rresp, .p_rvalid, .p_rready
	);

	// ------------------------------------------------------------------
	// Peripherals (CLINT + console)
	// ------------------------------------------------------------------
	logic [31:0] con_rd_word;
	uwire logic [31:0] con_rd_data, con_bytes_cnt, con_drops, con_rx_drops;
	uwire logic [15:0] con_rx_used;
	// PS read pointer (CON_RPTR) and RX insertion (CON_TX). The insertion
	// is a ONE-CYCLE pulse per write access -- a level would keep pushing
	// the character into the FIFO until the next write access.
	logic [31:0] con_rptr_reg;
	logic        con_rx_wr;
	logic [7:0]  con_rx_data;

	cva6_linux64_periph #(
		.CLINT_BASE (CLINT_BASE), .UART_BASE (UART_BASE),
		.CLK_HZ (CLK_HZ), .TICK_HZ (TICK_HZ), .CON_BYTES (CON_BYTES)
	) periph (
		.clk (clk), .rst (rst),
		.s_awaddr (p_awaddr), .s_awvalid (p_awvalid), .s_awready (p_awready),
		.s_wdata (p_wdata), .s_wstrb (p_wstrb), .s_wvalid (p_wvalid), .s_wready (p_wready),
		.s_bresp (p_bresp), .s_bvalid (p_bvalid), .s_bready (p_bready),
		.s_araddr (p_araddr), .s_arvalid (p_arvalid), .s_arready (p_arready),
		.s_rdata (p_rdata), .s_rresp (p_rresp), .s_rvalid (p_rvalid), .s_rready (p_rready),
		.timer_irq, .sw_irq,
		.con_clear, .con_rd_word, .con_rd_data,
		.con_bytes (con_bytes_cnt), .con_drops,
		.con_rd_bytes (con_rptr_reg),
		.con_rx_wr, .con_rx_data, .con_rx_used, .con_rx_drops
	);

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

	// Serialize ENC accesses -- rationale spelled out at length in
	// cva6_linux_soc_top.sv (finding 2026-07-26, L5-lite).
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
			control_reg   <= 32'h0000_0000;     // core in reset, ring empty
			sink_ctrl_reg <= 32'h0000_0000;
			ddr_base_reg  <= 32'h6000_0000;     // reserved PL window
			ddr_size_reg  <= 32'h0400_0000;     // 64 MiB
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
			con_rx_wr       <= 1'b0;     // one-cycle pulse (see declaration)
			// con_clear resets CON_BYTES in the peripheral to 0. The read
			// pointer MUST reset along with it, otherwise con_used = 0 -
			// rptr would be huge and the ring would permanently report
			// itself as full.
			if (con_clear) con_rptr_reg <= '0;
			if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
			if (s_axi_rvalid && s_axi_rready) begin s_axi_rvalid <= 1'b0; rd_busy <= 1'b0; end

			// --- write channel ---
			if (s_axi_awvalid && s_axi_awready) begin awaddr_q <= s_axi_awaddr; aw_seen <= 1'b1; end
			if (s_axi_wvalid  && s_axi_wready)  begin wdata_q  <= s_axi_wdata;  w_seen  <= 1'b1; end

			if (aw_seen && w_seen && !s_axi_bvalid && !enc_start) begin
				wseg = seg_of(awaddr_q);
				if (wseg == SEG_ENC) begin
					enc_start <= 1'b1; enc_is_wr <= 1'b1;   // kick off the bridge
				end
				else begin
					if (wseg == SEG_CTRL) begin
						unique case (awaddr_q[5:2])
							4'd0: control_reg <= wdata_q;
							4'd7: begin                    // 0x1C SINK_CTRL
								sink_ctrl_reg   <= wdata_q & 32'hFFFF_FFDD;
								ddr_clear_pulse <= wdata_q[1];
								pib_clear_pulse <= wdata_q[5];
							end
							4'd8: ddr_base_reg <= {wdata_q[31:5], 5'b0};   // 0x20
							4'd9: ddr_size_reg <= {wdata_q[31:2], 2'b0};   // 0x24
							4'd13: begin                                   // 0x34 CON_TX
								con_rx_wr   <= wdata_q[8];
								con_rx_data <= wdata_q[7:0];
							end
							4'd14: con_rptr_reg <= wdata_q;                // 0x38 CON_RPTR
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

			// --- read channel ---
			if (s_axi_arvalid && s_axi_arready) begin
				araddr_q <= s_axi_araddr;
				rd_busy  <= 1'b1;
				rseg = seg_of(s_axi_araddr);
				unique case (rseg)
					SEG_TRACE: begin trace_rd_word <= {12'b0, s_axi_araddr[21:2]}; rd_wait <= 2'd2; end
					SEG_CON:   begin con_rd_word   <= {12'b0, s_axi_araddr[21:2]}; rd_wait <= 2'd2; end
					SEG_ENC:   begin enc_start <= 1'b1; enc_is_wr <= 1'b0; end
					SEG_CTRL: begin
						unique case (s_axi_araddr[5:2])
							4'd0:    rdata_q <= control_reg;
							4'd1:    rdata_q <= {28'b0, sw_irq, timer_irq, uram_stopped, trace_wrapped};
							4'd2:    rdata_q <= trace_beats;
							4'd3:    rdata_q <= trace_bytes;
							4'd4:    rdata_q <= 32'(TRACE_DEPTH * 4);
							4'd5:    rdata_q <= con_bytes_cnt;
							4'd6:    rdata_q <= con_drops;
							4'd7:    rdata_q <= sink_ctrl_reg;
							4'd8:    rdata_q <= ddr_base_reg;
							4'd9:    rdata_q <= ddr_size_reg;
							4'd10:   rdata_q <= ddr_wptr;
							4'd11:   rdata_q <= {28'b0, uram_stopped, ddr_wrapped, ddr_axi_err, ddr_full};
							4'd12:   rdata_q <= ddr_drops;
							4'd13:   rdata_q <= {con_rx_drops[15:0], con_rx_used}; // 0x34
							4'd14:   rdata_q <= con_rptr_reg;                      // 0x38
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
	// The core is only allowed to run if it has memory it can actually use.
	always_ff @(posedge clk) begin
		if (!rst && core_run && m_axi_arvalid) begin
			assert (m_axi_araddr >= BOOT_ADDR || m_axi_araddr < 64'h1000_0000)
				else $error("cva6_linux64_soc_top: fetch outside the boot window/peripherals: 0x%h", m_axi_araddr);
		end
	end
`endif

endmodule

`default_nettype wire
