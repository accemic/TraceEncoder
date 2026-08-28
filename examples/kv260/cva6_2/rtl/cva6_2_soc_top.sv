// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Dual-CVA6 SoC (AMP) with TWO CTTE instances and a funnel.
 *
 * @details
 *   Twin of `rocket2_soc_top` for the CVA6 branch. Two INDEPENDENT cv64a6
 *   cores (or cv32a6, see below), each with one CTTE instance, ONE
 *   merged stream:
 *
 *     cva6_2_soc_synth_wrap  2x cva6_trace_wrap + 2x ITI shim
 *                            + 2x ct_encoder + ct_L1_funnel
 *     cva6_2_mem_xbar        private path per core (own atomics, own
 *                            guard, own PS port) + ONE shared path
 *                            (peripherals + mailbox) behind ONE atomics
 *     cva6_2_periph          two-hart CLINT + 8250 console ring
 *     ct_soc_trace_ring      1 MiB URAM ring on the funnel output
 *     ct_soc_ddr_sink        linear DDR sink
 *     ct_soc_pib             parallel trace port (optional)
 *
 *   =======================================================================
 *   AMP, NOT SMP -- and that is a decision, not a shortcoming
 *   =======================================================================
 *   cv64a6 in this tree carries `NOC_TYPE_AXI4_ATOP` and no coherence path
 *   (the OpenPiton L1.5 connection sits behind `` `ifdef PITON_ARIANE ``
 *   and is not compiled in). Two such cores on ONE cached DDR window would
 *   be incoherent, and the failure mode would be silent data corruption.
 *   Hence:
 *
 *     - each core has its OWN cached window (same core-side view, different
 *       PS base) and its OWN PS port;
 *     - the only thing shared is an UNCACHED mailbox that lies outside the
 *       cached region of the core configuration -- coherent by
 *       construction, because no cache is involved at all;
 *     - synchronization across it goes through ONE shared atomics instance
 *       (rationale and the silent failure mode of the alternative: header
 *       of `cva6_2_mem_xbar.sv`).
 *
 *   One process spanning two cores (SMP) is therefore NOT built; two
 *   guests, two encoders, one stream are.
 *
 *   =======================================================================
 *   FOUR differences vs. the single-core CVA6, all from dual-core operation
 *   =======================================================================
 *     1. TWO ENC windows (the trio/rocket2 pattern ENC0/ENC1), one
 *        `ct_axil_to_wb` bridge each. Without this the software could not
 *        set the instances to SrcID 0 resp. 1 separately -- and exactly
 *        this SrcID is what the decoder uses to separate the streams
 *        again.
 *     2. FUNNEL_CTRL (0x58): channel priorities and a global flush
 *        trigger, live-changeable. Reset 0x11 = both channels priority 1
 *        = round-robin.
 *     3. Golden reference and the observation channel PER CORE. "Is the
 *        core hung" is not one question with two cores, but two.
 *     4. EN_ETRACE defaults to OFF. The funnel recognizes packet
 *        boundaries via the Nexus MSEO bits; an E-Trace backend delivers
 *        raw bytes and would silently be merged wrong (the shell aborts
 *        elaboration at EN_ETRACE=1).
 *
 *   RV32 AND RV64 from THIS file: which core gets built is decided solely
 *   by the CVA6 configuration in the run's file list
 *   (`cv64a6_imac_sv39_ctrace` resp. `cv32a6_ima_sv32_fpga`). Register map,
 *   segments, memory layout and block sequence are IDENTICAL in both cases
 *   -- the same demonstrator must not tell two different stories depending
 *   on the visitor.
 *
 *   Core-side memory view (identical for both -- one shared CVA6Cfg is
 *   enough, because outside the cached region accesses go uncached instead
 *   of being rejected):
 *     0x0200_0000  CLINT (mtime, mtimecmp[0..1], msip[0..1])   shared
 *     0x1000_0000  UART  (8250, TX ring + RX FIFO)             shared
 *     0x6400_0000  +32 MiB  private RAM, CACHED   -> core 0 PS 0x6400_0000
 *                                                    core 1 PS 0x6600_0000
 *     0x6800_0000  +16 MiB  mailbox,    UNCACHED  -> both    PS 0x6800_0000
 *
 *   PS aperture address map (22 bit) -- word for word the same as rocket2:
 *     0x00_0000  CTRL
 *     0x01_0000  ENC0    CTTE CSRs core 0
 *     0x02_0000  ENC1    CTTE CSRs core 1
 *     0x20_0000  TRACE   merged ring (word read accesses)
 *     0x30_0000  CON     console ring (word read accesses)
 *
 *   CTRL registers (word offsets, [6:2]); 0x00..0x44 and 0x4C..0x64 sit
 *   bit-identical to `rocket2_soc_top`, so the existing board scripts and
 *   the dashboard card keep working unchanged:
 *     0x00 CONTROL  (rw) b0 core_run (holds BOTH cores)  b1 trace_clear
 *                        b2 con_clear  b3 win_err_clear  b4 obs_clear
 *     0x04 STATUS   (ro) b0 trace_wrapped   b1 uram_stopped
 *                        b2 win_err_sticky (OR across both cores AND the
 *                           mailbox -- stays bit-identical readable to the
 *                           single-core design)
 *                        b3 win_err_was_write (core 0)
 *                        b4 0 (rocket2: core_ndreset; CVA6 exposes none)
 *                        b5 core_rst_hold
 *                        b[10:8]  observation sticky {rvalid, arvalid,
 *                                 retire(core 0 OR core 1)}
 *                        b[14:12] last-seen privilege level, core 0
 *                        b18 retire_seen core 0   b19 retire_seen core 1
 *                        b[22:20] last-seen privilege level, core 1
 *                        b24 win0_err_sticky  b25 win1_err_sticky
 *                        b26 mbox_err_sticky
 *                        b27 timer_irq0  b28 timer_irq1
 *                        b29 sw_irq0     b30 sw_irq1
 *     0x08 TRACE_BEATS (ro)   0x0C TRACE_BYTES (ro)  0x10 TRACE_BUFSZ (ro)
 *     0x14 CON_BYTES   (ro)   0x18 CON_DROPS  (ro)
 *     0x1C SINK_CTRL   (rw)   0x20 DDR_BASE   (rw)   0x24 DDR_SIZE  (rw)
 *     0x28 DDR_WPTR    (ro)   0x2C SINK_STAT  (ro)   0x30 DDR_DROPS (ro)
 *     0x34 CON_TX      (rw)   0x38 CON_RPTR   (rw)
 *     0x3C WIN_ERR_CNT (ro)   0x40 WIN_ERR_LO (ro)   0x44 WIN_ERR_HI (ro)
 *                        [guard, core 0]
 *     0x48 reserved -- on rocket2 this word holds EXT_IRQ for the
 *          generat's PLIC. This build has no PLIC (polled console,
 *          CLINT-only), so the word stays empty instead of faking a line
 *          that does not exist. The offset is NOT reused, so the map
 *          stays congruent.
 *     0x4C PC_LO    (ro)  0x50 PC_HI  (ro)  0x54 RETIRES  (ro)   [core 0]
 *     0x58 FUNNEL_CTRL (rw) b[1:0] priority channel 0, b[5:4] channel 1,
 *                        b8 = global flush trigger (level). Reset 0x11.
 *                   (ro) b16 = funnel_flush_done (acknowledgment).
 *                        Deliberately in a free bit and NOT b0 -- a
 *                        priority sits there, and a pending done would
 *                        otherwise corrupt it on read.
 *     0x5C PC1_LO   (ro)  0x60 PC1_HI (ro)  0x64 RETIRES1 (ro)   [core 1]
 *     0x68 WIN1_ERR_CNT (ro)  0x6C WIN1_ERR_LO (ro)  0x70 WIN1_ERR_HI (ro)
 *                        [guard, core 1 -- NEW vs. rocket2, because here
 *                         there are two separate memory windows]
 *     0x74 MBOX_ERR_CNT (ro)  guard of the shared mailbox
 */
module cva6_2_soc_top #(
	// Core-side view of the private RAM (both cores the same) and the
	// point where OpenSBI/the payload enters.
	logic [63:0] BOOT_ADDR   = 64'h6400_0000,
	// Size of the private guest RAM PER CORE. Must match the memory node
	// in the respective devicetree (correspondence rule, CVA6_PIN.md §D5).
	logic [63:0] DRAM_SIZE   = 64'h0200_0000,   // 32 MiB
	// Mailbox: core-side view + size. MUST lie outside the cached region
	// of the core configuration (64 MiB from BOOT_ADDR, board-proven state).
	logic [63:0] MBOX_BASE   = 64'h6800_0000,
	logic [63:0] MBOX_SIZE   = 64'h0100_0000,   // 16 MiB
	// PS-side view of the three windows.
	logic [63:0] PS_DRAM0    = 64'h6400_0000,
	logic [63:0] PS_DRAM1    = 64'h6600_0000,
	logic [63:0] PS_MBOX     = 64'h6800_0000,
	logic [31:0] CLINT_BASE  = 32'h0200_0000,
	logic [31:0] UART_BASE   = 32'h1000_0000,
	int unsigned CLK_HZ      = 75_000_000,
	int unsigned TICK_HZ     = 1_000_000,
	int unsigned CON_BYTES   = 65536,
	int unsigned TRACE_DEPTH = 262144,          // 1 MiB URAM
	// Default OFF -- see difference 4 in the header.
	bit          EN_ETRACE   = 1'b0
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

	// --- Private memory path core 0 -> PS S_AXI_HP1_FPD (64 bit) ---------
	output      logic [3:0]   m0_axi_awid,
	output      logic [63:0]  m0_axi_awaddr,
	output      logic [7:0]   m0_axi_awlen,
	output      logic [2:0]   m0_axi_awsize,
	output      logic [1:0]   m0_axi_awburst,
	output      logic         m0_axi_awlock,
	output      logic [3:0]   m0_axi_awcache,
	output      logic [2:0]   m0_axi_awprot,
	output      logic         m0_axi_awvalid,
	input  uwire logic        m0_axi_awready,
	output      logic [63:0]  m0_axi_wdata,
	output      logic [7:0]   m0_axi_wstrb,
	output      logic         m0_axi_wlast,
	output      logic         m0_axi_wvalid,
	input  uwire logic        m0_axi_wready,
	input  uwire logic [3:0]  m0_axi_bid,
	input  uwire logic [1:0]  m0_axi_bresp,
	input  uwire logic        m0_axi_bvalid,
	output      logic         m0_axi_bready,
	output      logic [3:0]   m0_axi_arid,
	output      logic [63:0]  m0_axi_araddr,
	output      logic [7:0]   m0_axi_arlen,
	output      logic [2:0]   m0_axi_arsize,
	output      logic [1:0]   m0_axi_arburst,
	output      logic         m0_axi_arlock,
	output      logic [3:0]   m0_axi_arcache,
	output      logic [2:0]   m0_axi_arprot,
	output      logic         m0_axi_arvalid,
	input  uwire logic        m0_axi_arready,
	input  uwire logic [3:0]  m0_axi_rid,
	input  uwire logic [63:0] m0_axi_rdata,
	input  uwire logic [1:0]  m0_axi_rresp,
	input  uwire logic        m0_axi_rlast,
	input  uwire logic        m0_axi_rvalid,
	output      logic         m0_axi_rready,

	// --- Private memory path core 1 -> PS S_AXI_HP2_FPD (64 bit) ---------
	output      logic [3:0]   m1_axi_awid,
	output      logic [63:0]  m1_axi_awaddr,
	output      logic [7:0]   m1_axi_awlen,
	output      logic [2:0]   m1_axi_awsize,
	output      logic [1:0]   m1_axi_awburst,
	output      logic         m1_axi_awlock,
	output      logic [3:0]   m1_axi_awcache,
	output      logic [2:0]   m1_axi_awprot,
	output      logic         m1_axi_awvalid,
	input  uwire logic        m1_axi_awready,
	output      logic [63:0]  m1_axi_wdata,
	output      logic [7:0]   m1_axi_wstrb,
	output      logic         m1_axi_wlast,
	output      logic         m1_axi_wvalid,
	input  uwire logic        m1_axi_wready,
	input  uwire logic [3:0]  m1_axi_bid,
	input  uwire logic [1:0]  m1_axi_bresp,
	input  uwire logic        m1_axi_bvalid,
	output      logic         m1_axi_bready,
	output      logic [3:0]   m1_axi_arid,
	output      logic [63:0]  m1_axi_araddr,
	output      logic [7:0]   m1_axi_arlen,
	output      logic [2:0]   m1_axi_arsize,
	output      logic [1:0]   m1_axi_arburst,
	output      logic         m1_axi_arlock,
	output      logic [3:0]   m1_axi_arcache,
	output      logic [2:0]   m1_axi_arprot,
	output      logic         m1_axi_arvalid,
	input  uwire logic        m1_axi_arready,
	input  uwire logic [3:0]  m1_axi_rid,
	input  uwire logic [63:0] m1_axi_rdata,
	input  uwire logic [1:0]  m1_axi_rresp,
	input  uwire logic        m1_axi_rlast,
	input  uwire logic        m1_axi_rvalid,
	output      logic         m1_axi_rready,

	// --- Shared mailbox -> PS S_AXI_HP3_FPD (64 bit) ---------------------
	output      logic [1:0]   mb_axi_awid,
	output      logic [63:0]  mb_axi_awaddr,
	output      logic [7:0]   mb_axi_awlen,
	output      logic [2:0]   mb_axi_awsize,
	output      logic [1:0]   mb_axi_awburst,
	output      logic         mb_axi_awlock,
	output      logic [3:0]   mb_axi_awcache,
	output      logic [2:0]   mb_axi_awprot,
	output      logic         mb_axi_awvalid,
	input  uwire logic        mb_axi_awready,
	output      logic [63:0]  mb_axi_wdata,
	output      logic [7:0]   mb_axi_wstrb,
	output      logic         mb_axi_wlast,
	output      logic         mb_axi_wvalid,
	input  uwire logic        mb_axi_wready,
	input  uwire logic [1:0]  mb_axi_bid,
	input  uwire logic [1:0]  mb_axi_bresp,
	input  uwire logic        mb_axi_bvalid,
	output      logic         mb_axi_bready,
	output      logic [1:0]   mb_axi_arid,
	output      logic [63:0]  mb_axi_araddr,
	output      logic [7:0]   mb_axi_arlen,
	output      logic [2:0]   mb_axi_arsize,
	output      logic [1:0]   mb_axi_arburst,
	output      logic         mb_axi_arlock,
	output      logic [3:0]   mb_axi_arcache,
	output      logic [2:0]   mb_axi_arprot,
	output      logic         mb_axi_arvalid,
	input  uwire logic        mb_axi_arready,
	input  uwire logic [1:0]  mb_axi_rid,
	input  uwire logic [63:0] mb_axi_rdata,
	input  uwire logic [1:0]  mb_axi_rresp,
	input  uwire logic        mb_axi_rlast,
	input  uwire logic        mb_axi_rvalid,
	output      logic         mb_axi_rready,

	// --- Trace DDR sink: AXI4 write-only (PS S_AXI_HP0_FPD, 32 bit) ------
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

	// --- PIB ---------------------------------------------------------------
	output      logic         pib_clk,
	output      logic [3:0]   pib_data
);

	uwire logic rst = ~resetn;

	// ------------------------------------------------------------------
	// CTRL registers
	// ------------------------------------------------------------------
	logic [31:0] control_reg, sink_ctrl_reg, ddr_base_reg, ddr_size_reg;
	logic [31:0] funnel_ctrl_reg;
	uwire logic core_run      = control_reg[0];
	uwire logic trace_clear   = control_reg[1];
	uwire logic con_clear     = control_reg[2];
	uwire logic win_err_clear = control_reg[3];
	uwire logic obs_clear     = control_reg[4];

	// ------------------------------------------------------------------
	// Cores + both encoders + funnel
	// ------------------------------------------------------------------
	uwire logic [31:0] atb_atdata;
	uwire logic [1:0]  atb_atbytes;
	uwire logic [6:0]  atb_atid;
	uwire logic        atb_atvalid, atb_te_raw, atb_afready, funnel_flush_done;
	uwire logic [63:0] core0_pc, core1_pc;
	uwire logic [1:0]  core0_priv, core1_priv;
	uwire logic        core0_pc_valid, core1_pc_valid;
	uwire logic        timer_irq0, timer_irq1, sw_irq0, sw_irq1;

	// Core masters (before the demux/atomics block)
	uwire logic [3:0]  c0_awid, c0_arid, c1_awid, c1_arid;
	uwire logic [63:0] c0_awaddr, c0_araddr, c1_awaddr, c1_araddr;
	uwire logic [7:0]  c0_awlen, c0_arlen, c1_awlen, c1_arlen;
	uwire logic [2:0]  c0_awsize, c0_arsize, c1_awsize, c1_arsize;
	uwire logic [1:0]  c0_awburst, c0_arburst, c1_awburst, c1_arburst;
	uwire logic [5:0]  c0_awatop, c1_awatop;
	// lock/cache/prot MUST be passed through. In particular lock:
	// axi_riscv_lrsc recognizes LR/SC via the AXI4 exclusive signals. Tied
	// to 0, lr.d reads correctly but sc.d never gets EXOKAY and ALWAYS
	// fails -- every atomic_cmpxchg would be dead. Visible on the board as
	// "sbi_hsm_hart_start_finish: ERR: The hart is in invalid state"
	// (2026-07-27, isolated with sw/cva6_char/lrsc_test.S).
	uwire logic        c0_awlock, c0_arlock, c1_awlock, c1_arlock;
	uwire logic [3:0]  c0_awcache, c0_arcache, c1_awcache, c1_arcache;
	uwire logic [2:0]  c0_awprot, c0_arprot, c1_awprot, c1_arprot;
	uwire logic        c0_awvalid, c0_wvalid, c0_wlast, c0_arvalid, c0_bready, c0_rready;
	uwire logic        c1_awvalid, c1_wvalid, c1_wlast, c1_arvalid, c1_bready, c1_rready;
	uwire logic [63:0] c0_wdata, c1_wdata;
	uwire logic [7:0]  c0_wstrb, c1_wstrb;
	uwire logic        c0_awready, c0_wready, c0_arready, c0_bvalid, c0_rvalid, c0_rlast;
	uwire logic        c1_awready, c1_wready, c1_arready, c1_bvalid, c1_rvalid, c1_rlast;
	uwire logic [3:0]  c0_bid, c0_rid, c1_bid, c1_rid;
	uwire logic [1:0]  c0_bresp, c0_rresp, c1_bresp, c1_rresp;
	uwire logic [63:0] c0_rdata, c1_rdata;

	// Two Wishbone bridges -- one per encoder instance.
	uwire logic        e0_cyc, e0_stb, e0_we, e1_cyc, e1_stb, e1_we;
	uwire logic [31:0] e0_addr, e0_m2s, e1_addr, e1_m2s;
	uwire logic [3:0]  e0_sel, e1_sel;
	uwire logic [31:0] e0_s2m, e1_s2m;
	uwire logic        e0_ack, e0_err, e1_ack, e1_err;

	cva6_2_soc_synth_wrap #(
		.BOOT_ADDR (BOOT_ADDR),
		.EN_ETRACE (EN_ETRACE)
	) soc (
		.clk (clk), .rst (rst),
		.core_rst_hold (~core_run),
		.time_irq0 (timer_irq0), .time_irq1 (timer_irq1),
		.sw_irq0 (sw_irq0), .sw_irq1 (sw_irq1),
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
		.mem0_axi_awid (c0_awid), .mem0_axi_awaddr (c0_awaddr), .mem0_axi_awlen (c0_awlen),
		.mem0_axi_awsize (c0_awsize), .mem0_axi_awburst (c0_awburst), .mem0_axi_awlock (c0_awlock),
		.mem0_axi_awcache (c0_awcache), .mem0_axi_awprot (c0_awprot), .mem0_axi_awatop (c0_awatop),
		.mem0_axi_awvalid (c0_awvalid), .mem0_axi_awready (c0_awready),
		.mem0_axi_wdata (c0_wdata), .mem0_axi_wstrb (c0_wstrb), .mem0_axi_wlast (c0_wlast),
		.mem0_axi_wvalid (c0_wvalid), .mem0_axi_wready (c0_wready),
		.mem0_axi_bid (c0_bid), .mem0_axi_bresp (c0_bresp), .mem0_axi_bvalid (c0_bvalid),
		.mem0_axi_bready (c0_bready),
		.mem0_axi_arid (c0_arid), .mem0_axi_araddr (c0_araddr), .mem0_axi_arlen (c0_arlen),
		.mem0_axi_arsize (c0_arsize), .mem0_axi_arburst (c0_arburst), .mem0_axi_arlock (c0_arlock),
		.mem0_axi_arcache (c0_arcache), .mem0_axi_arprot (c0_arprot),
		.mem0_axi_arvalid (c0_arvalid), .mem0_axi_arready (c0_arready),
		.mem0_axi_rid (c0_rid), .mem0_axi_rdata (c0_rdata), .mem0_axi_rresp (c0_rresp),
		.mem0_axi_rlast (c0_rlast), .mem0_axi_rvalid (c0_rvalid), .mem0_axi_rready (c0_rready),
		.mem1_axi_awid (c1_awid), .mem1_axi_awaddr (c1_awaddr), .mem1_axi_awlen (c1_awlen),
		.mem1_axi_awsize (c1_awsize), .mem1_axi_awburst (c1_awburst), .mem1_axi_awlock (c1_awlock),
		.mem1_axi_awcache (c1_awcache), .mem1_axi_awprot (c1_awprot), .mem1_axi_awatop (c1_awatop),
		.mem1_axi_awvalid (c1_awvalid), .mem1_axi_awready (c1_awready),
		.mem1_axi_wdata (c1_wdata), .mem1_axi_wstrb (c1_wstrb), .mem1_axi_wlast (c1_wlast),
		.mem1_axi_wvalid (c1_wvalid), .mem1_axi_wready (c1_wready),
		.mem1_axi_bid (c1_bid), .mem1_axi_bresp (c1_bresp), .mem1_axi_bvalid (c1_bvalid),
		.mem1_axi_bready (c1_bready),
		.mem1_axi_arid (c1_arid), .mem1_axi_araddr (c1_araddr), .mem1_axi_arlen (c1_arlen),
		.mem1_axi_arsize (c1_arsize), .mem1_axi_arburst (c1_arburst), .mem1_axi_arlock (c1_arlock),
		.mem1_axi_arcache (c1_arcache), .mem1_axi_arprot (c1_arprot),
		.mem1_axi_arvalid (c1_arvalid), .mem1_axi_arready (c1_arready),
		.mem1_axi_rid (c1_rid), .mem1_axi_rdata (c1_rdata), .mem1_axi_rresp (c1_rresp),
		.mem1_axi_rlast (c1_rlast), .mem1_axi_rvalid (c1_rvalid), .mem1_axi_rready (c1_rready),
		.core0_trace_pc (core0_pc), .core0_trace_priv (core0_priv),
		.core0_trace_valid (core0_pc_valid),
		.core1_trace_pc (core1_pc), .core1_trace_priv (core1_priv),
		.core1_trace_valid (core1_pc_valid)
	);

	// ------------------------------------------------------------------
	// Memory path: private per core + ONE shared path
	// ------------------------------------------------------------------
	uwire logic [31:0] p_awaddr, p_araddr;
	uwire logic        p_awvalid, p_wvalid, p_arvalid, p_bready, p_rready;
	uwire logic [63:0] p_wdata;
	uwire logic [7:0]  p_wstrb;
	uwire logic        p_awready, p_wready, p_bvalid, p_arready, p_rvalid;
	uwire logic [1:0]  p_bresp, p_rresp;
	uwire logic [63:0] p_rdata;

	uwire logic        win0_err_sticky, win0_err_was_write;
	uwire logic [31:0] win0_err_count;
	uwire logic [63:0] win0_err_addr;
	uwire logic        win1_err_sticky, win1_err_was_write;
	uwire logic [31:0] win1_err_count;
	uwire logic [63:0] win1_err_addr;
	uwire logic        winmb_err_sticky;
	uwire logic [31:0] winmb_err_count;

	cva6_2_mem_xbar #(
		.PERIPH_BASE (CLINT_BASE),
		// covers CLINT (0x0200_0000) up to and including UART (0x1000_0000)
		.PERIPH_SIZE (32'h1000_1000),
		.DRAM_BASE   (BOOT_ADDR),
		.DRAM_SIZE   (DRAM_SIZE),
		.MBOX_BASE   (MBOX_BASE),
		.MBOX_SIZE   (MBOX_SIZE),
		.PS_DRAM0    (PS_DRAM0),
		.PS_DRAM1    (PS_DRAM1),
		.PS_MBOX     (PS_MBOX)
	) xbar (
		.clk (clk), .rst (rst),
		.c0_awid, .c0_awaddr, .c0_awlen, .c0_awsize, .c0_awburst,
		.c0_awlock, .c0_awcache, .c0_awprot, .c0_awatop,
		.c0_awvalid, .c0_awready,
		.c0_wdata, .c0_wstrb, .c0_wlast, .c0_wvalid, .c0_wready,
		.c0_bid, .c0_bresp, .c0_bvalid, .c0_bready,
		.c0_arid, .c0_araddr, .c0_arlen, .c0_arsize, .c0_arburst,
		.c0_arlock, .c0_arcache, .c0_arprot,
		.c0_arvalid, .c0_arready,
		.c0_rid, .c0_rdata, .c0_rresp, .c0_rlast, .c0_rvalid, .c0_rready,
		.c1_awid, .c1_awaddr, .c1_awlen, .c1_awsize, .c1_awburst,
		.c1_awlock, .c1_awcache, .c1_awprot, .c1_awatop,
		.c1_awvalid, .c1_awready,
		.c1_wdata, .c1_wstrb, .c1_wlast, .c1_wvalid, .c1_wready,
		.c1_bid, .c1_bresp, .c1_bvalid, .c1_bready,
		.c1_arid, .c1_araddr, .c1_arlen, .c1_arsize, .c1_arburst,
		.c1_arlock, .c1_arcache, .c1_arprot,
		.c1_arvalid, .c1_arready,
		.c1_rid, .c1_rdata, .c1_rresp, .c1_rlast, .c1_rvalid, .c1_rready,
		.m0_awid (m0_axi_awid), .m0_awaddr (m0_axi_awaddr), .m0_awlen (m0_axi_awlen),
		.m0_awsize (m0_axi_awsize), .m0_awburst (m0_axi_awburst), .m0_awlock (m0_axi_awlock),
		.m0_awcache (m0_axi_awcache), .m0_awprot (m0_axi_awprot),
		.m0_awvalid (m0_axi_awvalid), .m0_awready (m0_axi_awready),
		.m0_wdata (m0_axi_wdata), .m0_wstrb (m0_axi_wstrb), .m0_wlast (m0_axi_wlast),
		.m0_wvalid (m0_axi_wvalid), .m0_wready (m0_axi_wready),
		.m0_bid (m0_axi_bid), .m0_bresp (m0_axi_bresp), .m0_bvalid (m0_axi_bvalid),
		.m0_bready (m0_axi_bready),
		.m0_arid (m0_axi_arid), .m0_araddr (m0_axi_araddr), .m0_arlen (m0_axi_arlen),
		.m0_arsize (m0_axi_arsize), .m0_arburst (m0_axi_arburst), .m0_arlock (m0_axi_arlock),
		.m0_arcache (m0_axi_arcache), .m0_arprot (m0_axi_arprot),
		.m0_arvalid (m0_axi_arvalid), .m0_arready (m0_axi_arready),
		.m0_rid (m0_axi_rid), .m0_rdata (m0_axi_rdata), .m0_rresp (m0_axi_rresp),
		.m0_rlast (m0_axi_rlast), .m0_rvalid (m0_axi_rvalid), .m0_rready (m0_axi_rready),
		.m1_awid (m1_axi_awid), .m1_awaddr (m1_axi_awaddr), .m1_awlen (m1_axi_awlen),
		.m1_awsize (m1_axi_awsize), .m1_awburst (m1_axi_awburst), .m1_awlock (m1_axi_awlock),
		.m1_awcache (m1_axi_awcache), .m1_awprot (m1_axi_awprot),
		.m1_awvalid (m1_axi_awvalid), .m1_awready (m1_axi_awready),
		.m1_wdata (m1_axi_wdata), .m1_wstrb (m1_axi_wstrb), .m1_wlast (m1_axi_wlast),
		.m1_wvalid (m1_axi_wvalid), .m1_wready (m1_axi_wready),
		.m1_bid (m1_axi_bid), .m1_bresp (m1_axi_bresp), .m1_bvalid (m1_axi_bvalid),
		.m1_bready (m1_axi_bready),
		.m1_arid (m1_axi_arid), .m1_araddr (m1_axi_araddr), .m1_arlen (m1_axi_arlen),
		.m1_arsize (m1_axi_arsize), .m1_arburst (m1_axi_arburst), .m1_arlock (m1_axi_arlock),
		.m1_arcache (m1_axi_arcache), .m1_arprot (m1_axi_arprot),
		.m1_arvalid (m1_axi_arvalid), .m1_arready (m1_axi_arready),
		.m1_rid (m1_axi_rid), .m1_rdata (m1_axi_rdata), .m1_rresp (m1_axi_rresp),
		.m1_rlast (m1_axi_rlast), .m1_rvalid (m1_axi_rvalid), .m1_rready (m1_axi_rready),
		.mb_awid (mb_axi_awid), .mb_awaddr (mb_axi_awaddr), .mb_awlen (mb_axi_awlen),
		.mb_awsize (mb_axi_awsize), .mb_awburst (mb_axi_awburst), .mb_awlock (mb_axi_awlock),
		.mb_awcache (mb_axi_awcache), .mb_awprot (mb_axi_awprot),
		.mb_awvalid (mb_axi_awvalid), .mb_awready (mb_axi_awready),
		.mb_wdata (mb_axi_wdata), .mb_wstrb (mb_axi_wstrb), .mb_wlast (mb_axi_wlast),
		.mb_wvalid (mb_axi_wvalid), .mb_wready (mb_axi_wready),
		.mb_bid (mb_axi_bid), .mb_bresp (mb_axi_bresp), .mb_bvalid (mb_axi_bvalid),
		.mb_bready (mb_axi_bready),
		.mb_arid (mb_axi_arid), .mb_araddr (mb_axi_araddr), .mb_arlen (mb_axi_arlen),
		.mb_arsize (mb_axi_arsize), .mb_arburst (mb_axi_arburst), .mb_arlock (mb_axi_arlock),
		.mb_arcache (mb_axi_arcache), .mb_arprot (mb_axi_arprot),
		.mb_arvalid (mb_axi_arvalid), .mb_arready (mb_axi_arready),
		.mb_rid (mb_axi_rid), .mb_rdata (mb_axi_rdata), .mb_rresp (mb_axi_rresp),
		.mb_rlast (mb_axi_rlast), .mb_rvalid (mb_axi_rvalid), .mb_rready (mb_axi_rready),
		.p_awaddr, .p_awvalid, .p_awready, .p_wdata, .p_wstrb, .p_wvalid, .p_wready,
		.p_bresp, .p_bvalid, .p_bready,
		.p_araddr, .p_arvalid, .p_arready, .p_rdata, .p_rresp, .p_rvalid, .p_rready,
		.win_err_clear (win_err_clear),
		.win0_err_sticky, .win0_err_was_write, .win0_err_count, .win0_err_addr,
		.win1_err_sticky, .win1_err_was_write, .win1_err_count, .win1_err_addr,
		.winmb_err_sticky, .winmb_err_count
	);

	// ------------------------------------------------------------------
	// Peripherals (two-hart CLINT + shared console)
	// ------------------------------------------------------------------
	logic [31:0]       con_rd_word;
	uwire logic [31:0] con_rd_data, con_bytes_cnt, con_drops, con_rx_drops;
	uwire logic [15:0] con_rx_used;
	// PS read pointer (CON_RPTR) and RX insertion (CON_TX). The insertion
	// is a ONE-CYCLE pulse per write access -- a level would keep pushing
	// the character into the FIFO until the next write access.
	logic [31:0] con_rptr_reg;
	logic        con_rx_wr;
	logic [7:0]  con_rx_data;

	cva6_2_periph #(
		.CLINT_BASE (CLINT_BASE), .UART_BASE (UART_BASE),
		.CLK_HZ (CLK_HZ), .TICK_HZ (TICK_HZ), .CON_BYTES (CON_BYTES)
	) periph (
		.clk (clk), .rst (rst),
		.s_awaddr (p_awaddr), .s_awvalid (p_awvalid), .s_awready (p_awready),
		.s_wdata (p_wdata), .s_wstrb (p_wstrb), .s_wvalid (p_wvalid), .s_wready (p_wready),
		.s_bresp (p_bresp), .s_bvalid (p_bvalid), .s_bready (p_bready),
		.s_araddr (p_araddr), .s_arvalid (p_arvalid), .s_arready (p_arready),
		.s_rdata (p_rdata), .s_rresp (p_rresp), .s_rvalid (p_rvalid), .s_rready (p_rready),
		.timer_irq0, .sw_irq0, .timer_irq1, .sw_irq1,
		.con_clear, .con_rd_word, .con_rd_data,
		.con_bytes (con_bytes_cnt), .con_drops,
		.con_rd_bytes (con_rptr_reg),
		.con_rx_wr, .con_rx_data, .con_rx_used, .con_rx_drops
	);

	// ------------------------------------------------------------------
	// Observation channel PER CORE (difference 3 in the header)
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
				pc0_seen    <= core0_pc;
				priv0_seen  <= {1'b0, core0_priv};
			end
			if (core1_pc_valid) begin
				obs_retire1 <= 1'b1;
				retire_cnt1 <= retire_cnt1 + 32'd1;
				pc1_seen    <= core1_pc;
				priv1_seen  <= {1'b0, core1_priv};
			end
			// Both private memory paths count into the SAME sticky -- the
			// question it answers ("is anyone fetching memory at all?")
			// is a shared one. The retires give the core-precise answer.
			if (m0_axi_arvalid || m1_axi_arvalid) obs_arvalid <= 1'b1;
			if (m0_axi_rvalid  || m1_axi_rvalid)  obs_rvalid  <= 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// Trace sinks (at the FUNNEL output, i.e. both cores in one ring)
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

	// Serialize ENC accesses -- identical to the single-core SoC. Without
	// this a read access could take over a running write cycle (finding
	// 2026-07-26: trTeInstFeatures read 0x400a0000, the encoder stayed
	// silent).
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

	// The active bridge -- one access is always on only one of the two.
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
			control_reg     <= 32'h0000_0000;   // cores in reset, ring empty
			sink_ctrl_reg   <= 32'h0000_0000;
			ddr_base_reg    <= 32'h6000_0000;   // reserved PL window
			ddr_size_reg    <= 32'h0400_0000;   // 64 MiB
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
							// 0x58 FUNNEL_CTRL: only the occupied bits, so
							// a write access does not set a reserve bit
							// that later gains meaning.
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

			// --- read channel ---
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
							5'd1:    rdata_q <= {1'b0, sw_irq1, sw_irq0,
							                     timer_irq1, timer_irq0,
							                     winmb_err_sticky, win1_err_sticky,
							                     win0_err_sticky,
							                     1'b0, priv1_seen,
							                     obs_retire1, obs_retire0, 3'b0,
							                     priv0_seen,
							                     1'b0, obs_rvalid, obs_arvalid,
							                     obs_retire0 | obs_retire1,
							                     2'b0, ~core_run, 1'b0,
							                     win0_err_was_write,
							                     win0_err_sticky | win1_err_sticky
							                       | winmb_err_sticky,
							                     uram_stopped, trace_wrapped};
							5'd2:    rdata_q <= trace_beats;
							5'd3:    rdata_q <= trace_bytes;
							5'd4:    rdata_q <= 32'(TRACE_DEPTH * 4);
							5'd5:    rdata_q <= con_bytes_cnt;
							5'd6:    rdata_q <= con_drops;
							5'd7:    rdata_q <= sink_ctrl_reg;
							5'd8:    rdata_q <= ddr_base_reg;
							5'd9:    rdata_q <= ddr_size_reg;
							5'd10:   rdata_q <= ddr_wptr;
							5'd11:   rdata_q <= {28'b0, uram_stopped, ddr_wrapped, ddr_axi_err, ddr_full};
							5'd12:   rdata_q <= ddr_drops;
							5'd13:   rdata_q <= {con_rx_drops[15:0], con_rx_used}; // 0x34
							5'd14:   rdata_q <= con_rptr_reg;                      // 0x38
							5'd15:   rdata_q <= win0_err_count;                    // 0x3C
							5'd16:   rdata_q <= win0_err_addr[31:0];               // 0x40
							5'd17:   rdata_q <= win0_err_addr[63:32];              // 0x44
							// 5'd18 (0x48) stays free: on rocket2 this is
							// EXT_IRQ for the generat's PLIC. This build
							// has no PLIC -- returning 0 is more honest
							// than faking a register that does not exist.
							5'd19:   rdata_q <= pc0_seen[31:0];                    // 0x4C
							5'd20:   rdata_q <= pc0_seen[63:32];                   // 0x50
							5'd21:   rdata_q <= retire_cnt0;                       // 0x54
							// 0x58: reads back the register + the
							// acknowledgment in a FREE bit. ORing into bit
							// 0 would be a bug -- a priority sits there,
							// and a pending flush_done would corrupt it
							// on read.
							5'd22:   rdata_q <= {15'b0, funnel_flush_done, 16'b0}
							                    | funnel_ctrl_reg;                 // 0x58
							5'd23:   rdata_q <= pc1_seen[31:0];                    // 0x5C
							5'd24:   rdata_q <= pc1_seen[63:32];                   // 0x60
							5'd25:   rdata_q <= retire_cnt1;                       // 0x64
							5'd26:   rdata_q <= win1_err_count;                    // 0x68
							5'd27:   rdata_q <= win1_err_addr[31:0];               // 0x6C
							5'd28:   rdata_q <= win1_err_addr[63:32];              // 0x70
							5'd29:   rdata_q <= winmb_err_count;                   // 0x74
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
	// After the window translation, EVERY allowed access lies in its
	// core's PS window; everything else the guard has rejected. The two
	// assertions are at the same time the probe on the core of the AMP
	// design: the cores must NOT overlap in the PS DDR.
	always_ff @(posedge clk) begin
		if (!rst && core_run && m0_axi_arvalid) begin
			assert (m0_axi_araddr >= PS_DRAM0 && m0_axi_araddr < PS_DRAM0 + DRAM_SIZE)
				else $error("cva6_2_soc_top: core 0 reads outside its PS window: 0x%h", m0_axi_araddr);
		end
		if (!rst && core_run && m1_axi_arvalid) begin
			assert (m1_axi_araddr >= PS_DRAM1 && m1_axi_araddr < PS_DRAM1 + DRAM_SIZE)
				else $error("cva6_2_soc_top: core 1 reads outside its PS window: 0x%h", m1_axi_araddr);
		end
		// The funnel may only output ONE stream, and the ring may never
		// drop beats because it is always ready.
		if (!rst && atb_atvalid) begin
			assert (atb_atbytes <= 2'd3)
				else $error("cva6_2_soc_top: ATBYTES %0d outside the contract", atb_atbytes);
		end
	end

	initial begin
		// The memory map must be self-consistent: overlapping PS windows
		// would be exactly the silent data corruption AMP is built
		// against here.
		if (!((PS_DRAM0 + DRAM_SIZE <= PS_DRAM1) || (PS_DRAM1 + DRAM_SIZE <= PS_DRAM0)))
			$fatal(1, "cva6_2_soc_top: private PS windows overlap (0x%h / 0x%h, %0d MiB)",
			       PS_DRAM0, PS_DRAM1, DRAM_SIZE >> 20);
		if (MBOX_BASE < BOOT_ADDR + DRAM_SIZE)
			$fatal(1, "cva6_2_soc_top: mailbox overlaps the private core window");
	end
`endif

endmodule

`default_nettype wire
