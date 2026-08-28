// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Bitstream top of the AXIS watchpoint testbed (package D1): Zynq PS +
 *           AXI plumbing around tgc5b2_rvcfi_soc_top + 2x axi_fifo_mm_s, plain SV
 *           (no block design). Pattern: duo_kv260_top / mbv_kv260_top.
 *
 * @details
 *   PS M_AXI_HPM0_FPD (AXI4, 128 bit, pl_clk0 = 75 MHz)
 *     -> AXI data width converter 128 -> 32     (ct_soc_kv260_dwc)
 *     -> AXI4 -> AXI4-Lite protocol converter   (ct_soc_kv260_pc)
 *     -> 1:4 AXI4-Lite router (this module, serialized, ofs[22]/[17:16]):
 *          0xA000_0000  SOC     tgc5b2_rvcfi_soc_top (CTRL/ENC0/ENC1/RAM1/
 *                               RAM0/TRACE, decodes ofs[21:0])
 *          0xA040_0000  WPCTRL  D1 status registers (shim drops/fill/overflow,
 *                               fabric counter snapshot, magic)
 *          0xA041_0000  FIFO0   axi_fifo_mm_s core 0 (PG080 register set)
 *          0xA042_0000  FIFO1   axi_fifo_mm_s core 1
 *   Full map + register layout: docs/SPEC_axis_wp_memory_map.md.
 *
 *   The four PS glue XCIs (ct_soc_kv260_ps/_rst/_dwc/_pc) are project-local
 *   clones of the kv260_app pattern (vivado/tgc5b2_rvcfi/gen_ip.tcl) --
 *   same configuration; since D2 the PS XCI carries the S_AXI_GP2 slave port
 *   (= S_AXI_HP0_FPD, 32 bit) for the SoC top's DDR4 trace sink (folded into
 *   the three-sink subsystem ct_trace_sinks since T2, CTRL 0x18..0x38 --
 *   SPEC §8/§9; reset-inert), like the duo example. HPM0 stays 128 bit
 *   (a narrower width mis-steers write byte lanes, see gen_ip.tcl). Everything
 *   runs in the single pl_clk0 domain; ct_soc_kv260_rst synchronizes
 *   pl_resetn0. Since T2 the only external pins are the PIB port
 *   (pib_clk/pib_data[3:0] -> KV260 PMOD J2, pinout identical to
 *   duo_pib_pmod.xdc, tgc5b2_rvcfi.xdc); the PS pads remain implicit.
 *
 *   The router is deliberately store-and-forward with exactly one open
 *   transaction per direction -- the PS chain (dwc+pc) serializes anyway,
 *   throughput does not matter here, correctness does.
 *
 *   Fabric counter snapshot: the 64-bit counter that feeds both encoders'
 *   time_i lives INSIDE the SoC top and is not exported as a port there (D1
 *   must not touch the C1-verified SoC top). This top instead runs a
 *   clock-identical mirror counter (same clock, same synchronous reset
 *   ~aresetn, same increment logic) -- cycle-identical to the SoC-internal
 *   original by construction.
 */
module tgc5b2_rvcfi_kv260_top (
	// PIB: parallel trace port (T2) -> KV260 PMOD J2 (tgc5b2_rvcfi.xdc)
	output wire       pib_clk,
	output wire [3:0] pib_data
);

	// Informative mirrors of the build parameters (WPCTRL register; must
	// match gen_ip.tcl's C_RX_FIFO_DEPTH and tgc5b2_rvcfi_soc_top's
	// SHIM_FIFO_DEPTH).
	localparam int unsigned RX_FIFO_WORDS = 4096;   // per axi_fifo_mm_s
	localparam int unsigned SHIM_RECORDS  = 256;    // per ct_axis_wp_shim

	localparam logic [1:0] RESP_OKAY = 2'b00;

	// -- Clock + reset -------------------------------------------------------
	uwire logic        pl_clk0;
	uwire logic        pl_resetn0;
	uwire logic        aresetn;         // synchronized peripheral reset

	// -- PS M_AXI_HPM0_FPD (AXI4, 128 bit) -----------------------------------
	uwire logic [15:0] hpm0_awid,    hpm0_arid,   hpm0_bid,    hpm0_rid;
	uwire logic [39:0] hpm0_awaddr,  hpm0_araddr;
	uwire logic [7:0]  hpm0_awlen,   hpm0_arlen;
	uwire logic [2:0]  hpm0_awsize,  hpm0_arsize, hpm0_awprot, hpm0_arprot;
	uwire logic [1:0]  hpm0_awburst, hpm0_arburst, hpm0_bresp, hpm0_rresp;
	uwire logic        hpm0_awlock,  hpm0_arlock;
	uwire logic [3:0]  hpm0_awcache, hpm0_arcache, hpm0_awqos, hpm0_arqos;
	uwire logic        hpm0_awvalid, hpm0_awready, hpm0_arvalid, hpm0_arready;
	uwire logic [127:0] hpm0_wdata,  hpm0_rdata;
	uwire logic [15:0] hpm0_wstrb;
	uwire logic        hpm0_wlast,   hpm0_wvalid, hpm0_wready;
	uwire logic        hpm0_bvalid,  hpm0_bready;
	uwire logic        hpm0_rlast,   hpm0_rvalid, hpm0_rready;

	// -- DDR4 record rings (N3): core 0 -> S_AXI_HP0_FPD (saxigp2),
	//    core 1 -> S_AXI_HP1_FPD (saxigp3) -- one 32-bit HP port per ring ----
	uwire logic [31:0] hp0_awaddr;
	uwire logic [7:0]  hp0_awlen;
	uwire logic [2:0]  hp0_awsize;
	uwire logic [1:0]  hp0_awburst;
	uwire logic        hp0_awvalid, hp0_awready;
	uwire logic [31:0] hp0_wdata;
	uwire logic [3:0]  hp0_wstrb;
	uwire logic        hp0_wlast, hp0_wvalid, hp0_wready;
	uwire logic [1:0]  hp0_bresp;
	uwire logic        hp0_bvalid, hp0_bready;

	uwire logic [31:0] hp1_awaddr;
	uwire logic [7:0]  hp1_awlen;
	uwire logic [2:0]  hp1_awsize;
	uwire logic [1:0]  hp1_awburst;
	uwire logic        hp1_awvalid, hp1_awready;
	uwire logic [31:0] hp1_wdata;
	uwire logic [3:0]  hp1_wstrb;
	uwire logic        hp1_wlast, hp1_wvalid, hp1_wready;
	uwire logic [1:0]  hp1_bresp;
	uwire logic        hp1_bvalid, hp1_bready;

	ct_soc_kv260_ps ps (
		.maxihpm0_fpd_aclk (pl_clk0),
		.saxihp0_fpd_aclk  (pl_clk0),
		// S_AXI_HP0_FPD write channels <- DDR4 trace sink (read channels idle)
		.saxigp2_awid      (6'd0),
		.saxigp2_awaddr    ({17'd0, hp0_awaddr}),
		.saxigp2_awlen     (hp0_awlen),
		.saxigp2_awsize    (hp0_awsize),
		.saxigp2_awburst   (hp0_awburst),
		.saxigp2_awlock    (1'b0),
		.saxigp2_awcache   (4'b0011),
		.saxigp2_awprot    (3'b000),
		.saxigp2_awvalid   (hp0_awvalid),
		.saxigp2_awready   (hp0_awready),
		.saxigp2_awqos     (4'd0),
		.saxigp2_awuser    (1'b0),
		.saxigp2_wdata     (hp0_wdata),
		.saxigp2_wstrb     (hp0_wstrb),
		.saxigp2_wlast     (hp0_wlast),
		.saxigp2_wvalid    (hp0_wvalid),
		.saxigp2_wready    (hp0_wready),
		.saxigp2_bid       (),
		.saxigp2_bresp     (hp0_bresp),
		.saxigp2_bvalid    (hp0_bvalid),
		.saxigp2_bready    (hp0_bready),
		.saxigp2_arid      (6'd0),
		.saxigp2_araddr    (49'd0),
		.saxigp2_arlen     (8'd0),
		.saxigp2_arsize    (3'd0),
		.saxigp2_arburst   (2'b01),
		.saxigp2_arlock    (1'b0),
		.saxigp2_arcache   (4'd0),
		.saxigp2_arprot    (3'd0),
		.saxigp2_arvalid   (1'b0),
		.saxigp2_arready   (),
		.saxigp2_arqos     (4'd0),
		.saxigp2_aruser    (1'b0),
		.saxigp2_rid       (),
		.saxigp2_rdata     (),
		.saxigp2_rresp     (),
		.saxigp2_rlast     (),
		.saxigp2_rvalid    (),
		.saxigp2_rready    (1'b1),
		// S_AXI_HP1_FPD write channels <- core-1 record ring (read idle)
		.saxihp1_fpd_aclk  (pl_clk0),
		.saxigp3_awid      (6'd0),
		.saxigp3_awaddr    ({17'd0, hp1_awaddr}),
		.saxigp3_awlen     (hp1_awlen),
		.saxigp3_awsize    (hp1_awsize),
		.saxigp3_awburst   (hp1_awburst),
		.saxigp3_awlock    (1'b0),
		.saxigp3_awcache   (4'b0011),
		.saxigp3_awprot    (3'b000),
		.saxigp3_awvalid   (hp1_awvalid),
		.saxigp3_awready   (hp1_awready),
		.saxigp3_awqos     (4'd0),
		.saxigp3_awuser    (1'b0),
		.saxigp3_wdata     (hp1_wdata),
		.saxigp3_wstrb     (hp1_wstrb),
		.saxigp3_wlast     (hp1_wlast),
		.saxigp3_wvalid    (hp1_wvalid),
		.saxigp3_wready    (hp1_wready),
		.saxigp3_bid       (),
		.saxigp3_bresp     (hp1_bresp),
		.saxigp3_bvalid    (hp1_bvalid),
		.saxigp3_bready    (hp1_bready),
		.saxigp3_arid      (6'd0),
		.saxigp3_araddr    (49'd0),
		.saxigp3_arlen     (8'd0),
		.saxigp3_arsize    (3'd0),
		.saxigp3_arburst   (2'b01),
		.saxigp3_arlock    (1'b0),
		.saxigp3_arcache   (4'd0),
		.saxigp3_arprot    (3'd0),
		.saxigp3_arvalid   (1'b0),
		.saxigp3_arready   (),
		.saxigp3_arqos     (4'd0),
		.saxigp3_aruser    (1'b0),
		.saxigp3_rid       (),
		.saxigp3_rdata     (),
		.saxigp3_rresp     (),
		.saxigp3_rlast     (),
		.saxigp3_rvalid    (),
		.saxigp3_rready    (1'b1),
		.pl_clk0           (pl_clk0),
		.pl_resetn0        (pl_resetn0),
		.maxigp0_awid      (hpm0_awid),
		.maxigp0_awaddr    (hpm0_awaddr),
		.maxigp0_awlen     (hpm0_awlen),
		.maxigp0_awsize    (hpm0_awsize),
		.maxigp0_awburst   (hpm0_awburst),
		.maxigp0_awlock    (hpm0_awlock),
		.maxigp0_awcache   (hpm0_awcache),
		.maxigp0_awprot    (hpm0_awprot),
		.maxigp0_awqos     (hpm0_awqos),
		.maxigp0_awuser    (),                // unused (dropped by the downsizer)
		.maxigp0_awvalid   (hpm0_awvalid),
		.maxigp0_awready   (hpm0_awready),
		.maxigp0_wdata     (hpm0_wdata),
		.maxigp0_wstrb     (hpm0_wstrb),
		.maxigp0_wlast     (hpm0_wlast),
		.maxigp0_wvalid    (hpm0_wvalid),
		.maxigp0_wready    (hpm0_wready),
		.maxigp0_bid       (hpm0_bid),
		.maxigp0_bresp     (hpm0_bresp),
		.maxigp0_bvalid    (hpm0_bvalid),
		.maxigp0_bready    (hpm0_bready),
		.maxigp0_arid      (hpm0_arid),
		.maxigp0_araddr    (hpm0_araddr),
		.maxigp0_arlen     (hpm0_arlen),
		.maxigp0_arsize    (hpm0_arsize),
		.maxigp0_arburst   (hpm0_arburst),
		.maxigp0_arlock    (hpm0_arlock),
		.maxigp0_arcache   (hpm0_arcache),
		.maxigp0_arprot    (hpm0_arprot),
		.maxigp0_arqos     (hpm0_arqos),
		.maxigp0_aruser    (),                // unused
		.maxigp0_arvalid   (hpm0_arvalid),
		.maxigp0_arready   (hpm0_arready),
		.maxigp0_rid       (hpm0_rid),
		.maxigp0_rdata     (hpm0_rdata),
		.maxigp0_rresp     (hpm0_rresp),
		.maxigp0_rlast     (hpm0_rlast),
		.maxigp0_rvalid    (hpm0_rvalid),
		.maxigp0_rready    (hpm0_rready)
	);

	ct_soc_kv260_rst rst (
		.slowest_sync_clk     (pl_clk0),
		.ext_reset_in         (pl_resetn0),
		.aux_reset_in         (1'b1),         // inactive (active-low)
		.mb_debug_sys_rst     (1'b0),
		.dcm_locked           (1'b1),
		.mb_reset             (),
		.bus_struct_reset     (),
		.peripheral_reset     (),
		.interconnect_aresetn (),
		.peripheral_aresetn   (aresetn)
	);

	// -- 128 -> 32 downsize (byte-lane-correct; see gen_ip.tcl) ---------------
	uwire logic [39:0] ds_awaddr,  ds_araddr;
	uwire logic [7:0]  ds_awlen,   ds_arlen;
	uwire logic [2:0]  ds_awsize,  ds_arsize, ds_awprot, ds_arprot;
	uwire logic [1:0]  ds_awburst, ds_arburst, ds_bresp, ds_rresp;
	uwire logic        ds_awlock,  ds_arlock;
	uwire logic [3:0]  ds_awcache, ds_arcache, ds_awqos, ds_arqos;
	uwire logic [3:0]  ds_awregion, ds_arregion;
	uwire logic        ds_awvalid, ds_awready, ds_arvalid, ds_arready;
	uwire logic [31:0] ds_wdata,   ds_rdata;
	uwire logic [3:0]  ds_wstrb;
	uwire logic        ds_wlast,   ds_wvalid, ds_wready;
	uwire logic        ds_bvalid,  ds_bready;
	uwire logic        ds_rlast,   ds_rvalid, ds_rready;

	ct_soc_kv260_dwc dwc (
		.s_axi_aclk     (pl_clk0),
		.s_axi_aresetn  (aresetn),
		.s_axi_awid     (hpm0_awid),
		.s_axi_awaddr   (hpm0_awaddr),
		.s_axi_awlen    (hpm0_awlen),
		.s_axi_awsize   (hpm0_awsize),
		.s_axi_awburst  (hpm0_awburst),
		.s_axi_awlock   (hpm0_awlock),
		.s_axi_awcache  (hpm0_awcache),
		.s_axi_awprot   (hpm0_awprot),
		.s_axi_awregion (4'b0),               // the PS master has no region
		.s_axi_awqos    (hpm0_awqos),
		.s_axi_awvalid  (hpm0_awvalid),
		.s_axi_awready  (hpm0_awready),
		.s_axi_wdata    (hpm0_wdata),
		.s_axi_wstrb    (hpm0_wstrb),
		.s_axi_wlast    (hpm0_wlast),
		.s_axi_wvalid   (hpm0_wvalid),
		.s_axi_wready   (hpm0_wready),
		.s_axi_bid      (hpm0_bid),
		.s_axi_bresp    (hpm0_bresp),
		.s_axi_bvalid   (hpm0_bvalid),
		.s_axi_bready   (hpm0_bready),
		.s_axi_arid     (hpm0_arid),
		.s_axi_araddr   (hpm0_araddr),
		.s_axi_arlen    (hpm0_arlen),
		.s_axi_arsize   (hpm0_arsize),
		.s_axi_arburst  (hpm0_arburst),
		.s_axi_arlock   (hpm0_arlock),
		.s_axi_arcache  (hpm0_arcache),
		.s_axi_arprot   (hpm0_arprot),
		.s_axi_arregion (4'b0),
		.s_axi_arqos    (hpm0_arqos),
		.s_axi_arvalid  (hpm0_arvalid),
		.s_axi_arready  (hpm0_arready),
		.s_axi_rid      (hpm0_rid),
		.s_axi_rdata    (hpm0_rdata),
		.s_axi_rresp    (hpm0_rresp),
		.s_axi_rlast    (hpm0_rlast),
		.s_axi_rvalid   (hpm0_rvalid),
		.s_axi_rready   (hpm0_rready),
		.m_axi_awaddr   (ds_awaddr),
		.m_axi_awlen    (ds_awlen),
		.m_axi_awsize   (ds_awsize),
		.m_axi_awburst  (ds_awburst),
		.m_axi_awlock   (ds_awlock),
		.m_axi_awcache  (ds_awcache),
		.m_axi_awprot   (ds_awprot),
		.m_axi_awregion (ds_awregion),
		.m_axi_awqos    (ds_awqos),
		.m_axi_awvalid  (ds_awvalid),
		.m_axi_awready  (ds_awready),
		.m_axi_wdata    (ds_wdata),
		.m_axi_wstrb    (ds_wstrb),
		.m_axi_wlast    (ds_wlast),
		.m_axi_wvalid   (ds_wvalid),
		.m_axi_wready   (ds_wready),
		.m_axi_bresp    (ds_bresp),
		.m_axi_bvalid   (ds_bvalid),
		.m_axi_bready   (ds_bready),
		.m_axi_araddr   (ds_araddr),
		.m_axi_arlen    (ds_arlen),
		.m_axi_arsize   (ds_arsize),
		.m_axi_arburst  (ds_arburst),
		.m_axi_arlock   (ds_arlock),
		.m_axi_arcache  (ds_arcache),
		.m_axi_arprot   (ds_arprot),
		.m_axi_arregion (ds_arregion),
		.m_axi_arqos    (ds_arqos),
		.m_axi_arvalid  (ds_arvalid),
		.m_axi_arready  (ds_arready),
		.m_axi_rdata    (ds_rdata),
		.m_axi_rresp    (ds_rresp),
		.m_axi_rlast    (ds_rlast),
		.m_axi_rvalid   (ds_rvalid),
		.m_axi_rready   (ds_rready)
	);

	// -- AXI4 -> AXI4-Lite ----------------------------------------------------
	uwire logic [39:0] lite_awaddr, lite_araddr;
	uwire logic [2:0]  lite_awprot, lite_arprot;
	uwire logic        lite_awvalid, lite_arvalid;
	logic              lite_awready, lite_arready;
	uwire logic [31:0] lite_wdata;
	logic [31:0]       lite_rdata;
	uwire logic [3:0]  lite_wstrb;
	uwire logic        lite_wvalid;
	logic              lite_wready;
	logic [1:0]        lite_bresp,  lite_rresp;
	logic              lite_bvalid, lite_rvalid;
	uwire logic        lite_bready, lite_rready;

	ct_soc_kv260_pc pc (
		.aclk           (pl_clk0),
		.aresetn        (aresetn),
		.s_axi_awaddr   (ds_awaddr),
		.s_axi_awlen    (ds_awlen),
		.s_axi_awsize   (ds_awsize),
		.s_axi_awburst  (ds_awburst),
		.s_axi_awlock   (ds_awlock),
		.s_axi_awcache  (ds_awcache),
		.s_axi_awprot   (ds_awprot),
		.s_axi_awregion (ds_awregion),
		.s_axi_awqos    (ds_awqos),
		.s_axi_awvalid  (ds_awvalid),
		.s_axi_awready  (ds_awready),
		.s_axi_wdata    (ds_wdata),
		.s_axi_wstrb    (ds_wstrb),
		.s_axi_wlast    (ds_wlast),
		.s_axi_wvalid   (ds_wvalid),
		.s_axi_wready   (ds_wready),
		.s_axi_bresp    (ds_bresp),
		.s_axi_bvalid   (ds_bvalid),
		.s_axi_bready   (ds_bready),
		.s_axi_araddr   (ds_araddr),
		.s_axi_arlen    (ds_arlen),
		.s_axi_arsize   (ds_arsize),
		.s_axi_arburst  (ds_arburst),
		.s_axi_arlock   (ds_arlock),
		.s_axi_arcache  (ds_arcache),
		.s_axi_arprot   (ds_arprot),
		.s_axi_arregion (ds_arregion),
		.s_axi_arqos    (ds_arqos),
		.s_axi_arvalid  (ds_arvalid),
		.s_axi_arready  (ds_arready),
		.s_axi_rdata    (ds_rdata),
		.s_axi_rresp    (ds_rresp),
		.s_axi_rlast    (ds_rlast),
		.s_axi_rvalid   (ds_rvalid),
		.s_axi_rready   (ds_rready),
		.m_axi_awaddr   (lite_awaddr),
		.m_axi_awprot   (lite_awprot),
		.m_axi_awvalid  (lite_awvalid),
		.m_axi_awready  (lite_awready),
		.m_axi_wdata    (lite_wdata),
		.m_axi_wstrb    (lite_wstrb),
		.m_axi_wvalid   (lite_wvalid),
		.m_axi_wready   (lite_wready),
		.m_axi_bresp    (lite_bresp),
		.m_axi_bvalid   (lite_bvalid),
		.m_axi_bready   (lite_bready),
		.m_axi_araddr   (lite_araddr),
		.m_axi_arprot   (lite_arprot),
		.m_axi_arvalid  (lite_arvalid),
		.m_axi_arready  (lite_arready),
		.m_axi_rdata    (lite_rdata),
		.m_axi_rresp    (lite_rresp),
		.m_axi_rvalid   (lite_rvalid),
		.m_axi_rready   (lite_rready)
	);

	// ======================================================================
	// Target decode (SPEC_axis_wp_memory_map.md §1)
	// ======================================================================
	typedef enum logic [1:0] { T_SOC, T_WPC, T_F0, T_F1 } tgt_e;

	function automatic tgt_e tgt_of(input logic [23:0] a);
		if (!a[22]) tgt_of = T_SOC;
		else begin
			unique case (a[17:16])
				2'd1:    tgt_of = T_F0;
				2'd2:    tgt_of = T_F1;
				default: tgt_of = T_WPC;   // 0 = WPCTRL, 3 = reserved alias
			endcase
		end
	endfunction

	// -- Sub-slave signals ----------------------------------------------------
	// SoC (decodes ofs[21:0])
	logic        soc_awvalid, soc_wvalid, soc_bready, soc_arvalid, soc_rready;
	uwire logic  soc_awready, soc_wready, soc_bvalid, soc_arready, soc_rvalid;
	uwire logic [1:0]  soc_bresp, soc_rresp;
	uwire logic [31:0] soc_rdata;

	// FIFO0/FIFO1 (PG080 lite, lower 16 bit)
	logic        f0_awvalid, f0_wvalid, f0_bready, f0_arvalid, f0_rready;
	uwire logic  f0_awready, f0_wready, f0_bvalid, f0_arready, f0_rvalid;
	uwire logic [1:0]  f0_bresp, f0_rresp;
	uwire logic [31:0] f0_rdata;
	logic        f1_awvalid, f1_wvalid, f1_bready, f1_arvalid, f1_rready;
	uwire logic  f1_awready, f1_wready, f1_bvalid, f1_arready, f1_rvalid;
	uwire logic [1:0]  f1_bresp, f1_rresp;
	uwire logic [31:0] f1_rdata;

	// -- Shim status + WP record streams of the SoC ------------------------
	uwire logic        m0_tvalid, m0_tready, m0_tlast;
	uwire logic [31:0] m0_tdata;
	uwire logic [3:0]  m0_tkeep;          // constant 4'hF; FIFO IP has no tkeep
	uwire logic [31:0] shim0_drop, shim0_fill;
	uwire logic        shim0_ovf;
	uwire logic        m1_tvalid, m1_tready, m1_tlast;
	uwire logic [31:0] m1_tdata;
	uwire logic [3:0]  m1_tkeep;          // constant 4'hF; FIFO IP has no tkeep
	uwire logic [31:0] shim1_drop, shim1_fill;
	uwire logic        shim1_ovf;

	// ======================================================================
	// Write path (one open transaction; WPCTRL writes = no-op with OKAY)
	// ======================================================================
	typedef enum logic [1:0] { W_IDLE, W_ISSUE, W_BRESP, W_LB } wstate_e;

	wstate_e     wstate;
	tgt_e        wtgt;
	logic [23:0] wa_q;
	logic [31:0] wd_q;
	logic [3:0]  ws_q;
	logic        aw_pend, w_pend;

	assign lite_awready = (wstate == W_IDLE) && lite_awvalid && lite_wvalid;
	assign lite_wready  = lite_awready;

	// Return path of the selected write target.
	logic sub_awready, sub_wready, sub_bvalid;
	logic [1:0] sub_bresp;
	always_comb begin
		unique case (wtgt)
			T_SOC:   begin sub_awready = soc_awready; sub_wready = soc_wready;
			               sub_bvalid = soc_bvalid;   sub_bresp = soc_bresp; end
			T_F0:    begin sub_awready = f0_awready;  sub_wready = f0_wready;
			               sub_bvalid = f0_bvalid;    sub_bresp = f0_bresp; end
			T_F1:    begin sub_awready = f1_awready;  sub_wready = f1_wready;
			               sub_bvalid = f1_bvalid;    sub_bresp = f1_bresp; end
			default: begin sub_awready = 1'b0; sub_wready = 1'b0;
			               sub_bvalid = 1'b0; sub_bresp = RESP_OKAY; end
		endcase
	end

	always_ff @(posedge pl_clk0) begin
		if (!aresetn) begin
			wstate <= W_IDLE; wtgt <= T_SOC;
			wa_q <= '0; wd_q <= '0; ws_q <= '0;
			aw_pend <= 1'b0; w_pend <= 1'b0;
			lite_bvalid <= 1'b0; lite_bresp <= RESP_OKAY;
		end
		else begin
			if (lite_bvalid && lite_bready) lite_bvalid <= 1'b0;

			unique case (wstate)
				W_IDLE: if (lite_awready) begin
					wa_q <= lite_awaddr[23:0];
					wd_q <= lite_wdata;
					ws_q <= lite_wstrb;
					wtgt <= tgt_of(lite_awaddr[23:0]);
					if (tgt_of(lite_awaddr[23:0]) == T_WPC) begin
						// All WPCTRL registers are read-only: write no-op, OKAY
						lite_bresp <= RESP_OKAY; lite_bvalid <= 1'b1;
						wstate <= W_LB;
					end
					else begin
						aw_pend <= 1'b1; w_pend <= 1'b1;
						wstate <= W_ISSUE;
					end
				end
				W_ISSUE: begin
					aw_pend <= aw_pend && !sub_awready;
					w_pend  <= w_pend  && !sub_wready;
					if ((!aw_pend || sub_awready) && (!w_pend || sub_wready))
						wstate <= W_BRESP;
				end
				W_BRESP: if (sub_bvalid) begin
					lite_bresp <= sub_bresp; lite_bvalid <= 1'b1;
					wstate <= W_LB;
				end
				W_LB: if (lite_bvalid && lite_bready) wstate <= W_IDLE;
				default: wstate <= W_IDLE;
			endcase
		end
	end

	assign soc_awvalid = (wstate == W_ISSUE) && (wtgt == T_SOC) && aw_pend;
	assign soc_wvalid  = (wstate == W_ISSUE) && (wtgt == T_SOC) && w_pend;
	assign soc_bready  = (wstate == W_BRESP) && (wtgt == T_SOC);
	assign f0_awvalid  = (wstate == W_ISSUE) && (wtgt == T_F0) && aw_pend;
	assign f0_wvalid   = (wstate == W_ISSUE) && (wtgt == T_F0) && w_pend;
	assign f0_bready   = (wstate == W_BRESP) && (wtgt == T_F0);
	assign f1_awvalid  = (wstate == W_ISSUE) && (wtgt == T_F1) && aw_pend;
	assign f1_wvalid   = (wstate == W_ISSUE) && (wtgt == T_F1) && w_pend;
	assign f1_bready   = (wstate == W_BRESP) && (wtgt == T_F1);

	// ======================================================================
	// Read path (WPCTRL served locally in one cycle)
	// ======================================================================
	typedef enum logic [1:0] { R_IDLE, R_ISSUE, R_RRESP, R_LR } rstate_e;

	rstate_e     rstate;
	tgt_e        rtgt;
	logic [23:0] ra_q;

	// Fabric counter mirror (cycle-identical to the SoC-internal fabric_time,
	// see @details) + coherent 64-bit snapshot (FTIME_LO latches).
	logic [63:0] ftime_mirror, ftime_snap;
	always_ff @(posedge pl_clk0) begin
		if (!aresetn) ftime_mirror <= '0;
		else          ftime_mirror <= ftime_mirror + 64'd1;
	end

	assign lite_arready = (rstate == R_IDLE) && lite_arvalid;

	logic sub_arready, sub_rvalid;
	logic [1:0] sub_rresp;
	logic [31:0] sub_rdata;
	always_comb begin
		unique case (rtgt)
			T_SOC:   begin sub_arready = soc_arready; sub_rvalid = soc_rvalid;
			               sub_rresp = soc_rresp;     sub_rdata = soc_rdata; end
			T_F0:    begin sub_arready = f0_arready;  sub_rvalid = f0_rvalid;
			               sub_rresp = f0_rresp;      sub_rdata = f0_rdata; end
			T_F1:    begin sub_arready = f1_arready;  sub_rvalid = f1_rvalid;
			               sub_rresp = f1_rresp;      sub_rdata = f1_rdata; end
			default: begin sub_arready = 1'b0; sub_rvalid = 1'b0;
			               sub_rresp = RESP_OKAY; sub_rdata = '0; end
		endcase
	end

	always_ff @(posedge pl_clk0) begin
		if (!aresetn) begin
			rstate <= R_IDLE; rtgt <= T_SOC; ra_q <= '0;
			lite_rvalid <= 1'b0; lite_rdata <= '0; lite_rresp <= RESP_OKAY;
			ftime_snap <= '0;
		end
		else begin
			if (lite_rvalid && lite_rready) lite_rvalid <= 1'b0;

			unique case (rstate)
				R_IDLE: if (lite_arready) begin
					ra_q <= lite_araddr[23:0];
					rtgt <= tgt_of(lite_araddr[23:0]);
					if (tgt_of(lite_araddr[23:0]) == T_WPC) begin
						// WPCTRL: SPEC_axis_wp_memory_map.md §3
						unique case (lite_araddr[7:2])
							6'd0:    lite_rdata <= 32'h4157_5031;          // "AWP1"
							6'd1:    lite_rdata <= shim0_drop;
							6'd2:    lite_rdata <= shim0_fill;
							6'd3:    lite_rdata <= {31'b0, shim0_ovf};
							6'd4:    lite_rdata <= shim1_drop;
							6'd5:    lite_rdata <= shim1_fill;
							6'd6:    lite_rdata <= {31'b0, shim1_ovf};
							6'd7:    begin                                 // FTIME_LO
								lite_rdata <= ftime_mirror[31:0];
								ftime_snap <= ftime_mirror;
							end
							6'd8:    lite_rdata <= ftime_snap[63:32];      // FTIME_HI
							6'd9:    lite_rdata <= 32'(RX_FIFO_WORDS);
							6'd10:   lite_rdata <= 32'(SHIM_RECORDS);
							default: lite_rdata <= '0;
						endcase
						lite_rresp <= RESP_OKAY; lite_rvalid <= 1'b1;
						rstate <= R_LR;
					end
					else rstate <= R_ISSUE;
				end
				R_ISSUE: if (sub_arready) rstate <= R_RRESP;
				R_RRESP: if (sub_rvalid) begin
					lite_rdata <= sub_rdata; lite_rresp <= sub_rresp;
					lite_rvalid <= 1'b1;
					rstate <= R_LR;
				end
				R_LR: if (lite_rvalid && lite_rready) rstate <= R_IDLE;
				default: rstate <= R_IDLE;
			endcase
		end
	end

	assign soc_arvalid = (rstate == R_ISSUE) && (rtgt == T_SOC);
	assign soc_rready  = (rstate == R_RRESP) && (rtgt == T_SOC);
	assign f0_arvalid  = (rstate == R_ISSUE) && (rtgt == T_F0);
	assign f0_rready   = (rstate == R_RRESP) && (rtgt == T_F0);
	assign f1_arvalid  = (rstate == R_ISSUE) && (rtgt == T_F1);
	assign f1_rready   = (rstate == R_RRESP) && (rtgt == T_F1);

	// ======================================================================
	// SoC: 2x TGC5B + CTTE + shims + funnel + trace ring
	// ======================================================================
	tgc5b2_rvcfi_soc_top soc (
		.clk           (pl_clk0),
		.resetn        (aresetn),
		.s_axi_awaddr  (wa_q[21:0]),
		.s_axi_awprot  (3'b000),
		.s_axi_awvalid (soc_awvalid),
		.s_axi_awready (soc_awready),
		.s_axi_wdata   (wd_q),
		.s_axi_wstrb   (ws_q),
		.s_axi_wvalid  (soc_wvalid),
		.s_axi_wready  (soc_wready),
		.s_axi_bresp   (soc_bresp),
		.s_axi_bvalid  (soc_bvalid),
		.s_axi_bready  (soc_bready),
		.s_axi_araddr  (ra_q[21:0]),
		.s_axi_arprot  (3'b000),
		.s_axi_arvalid (soc_arvalid),
		.s_axi_arready (soc_arready),
		.s_axi_rdata   (soc_rdata),
		.s_axi_rresp   (soc_rresp),
		.s_axi_rvalid  (soc_rvalid),
		.s_axi_rready  (soc_rready),
		.m0_axis_tvalid        (m0_tvalid),
		.m0_axis_tready        (m0_tready),
		.m0_axis_tdata         (m0_tdata),
		.m0_axis_tkeep         (m0_tkeep),
		.m0_axis_tlast         (m0_tlast),
		.shim0_drop_count      (shim0_drop),
		.shim0_overflow_sticky (shim0_ovf),
		.shim0_fill_level      (shim0_fill),
		.m1_axis_tvalid        (m1_tvalid),
		.m1_axis_tready        (m1_tready),
		.m1_axis_tdata         (m1_tdata),
		.m1_axis_tkeep         (m1_tkeep),
		.m1_axis_tlast         (m1_tlast),
		.shim1_drop_count      (shim1_drop),
		.shim1_overflow_sticky (shim1_ovf),
		.shim1_fill_level      (shim1_fill),
		// DDR4 sink -> PS S_AXI_HP0_FPD (saxigp2, see above)
		.m_axi_awaddr  (hp0_awaddr),
		.m_axi_awlen   (hp0_awlen),
		.m_axi_awsize  (hp0_awsize),
		.m_axi_awburst (hp0_awburst),
		.m_axi_awvalid (hp0_awvalid),
		.m_axi_awready (hp0_awready),
		.m_axi_wdata   (hp0_wdata),
		.m_axi_wstrb   (hp0_wstrb),
		.m_axi_wlast   (hp0_wlast),
		.m_axi_wvalid  (hp0_wvalid),
		.m_axi_wready  (hp0_wready),
		.m_axi_bresp   (hp0_bresp),
		.m_axi_bvalid  (hp0_bvalid),
		.m_axi_bready  (hp0_bready),
		// core-1 record ring -> PS S_AXI_HP1_FPD (saxigp3, see above)
		.m1_axi_awaddr  (hp1_awaddr),
		.m1_axi_awlen   (hp1_awlen),
		.m1_axi_awsize  (hp1_awsize),
		.m1_axi_awburst (hp1_awburst),
		.m1_axi_awvalid (hp1_awvalid),
		.m1_axi_awready (hp1_awready),
		.m1_axi_wdata   (hp1_wdata),
		.m1_axi_wstrb   (hp1_wstrb),
		.m1_axi_wlast   (hp1_wlast),
		.m1_axi_wvalid  (hp1_wvalid),
		.m1_axi_wready  (hp1_wready),
		.m1_axi_bresp   (hp1_bresp),
		.m1_axi_bvalid  (hp1_bvalid),
		.m1_axi_bready  (hp1_bready),
		// PIB -> PMOD pins (T2)
		.pib_clk       (pib_clk),
		.pib_data      (pib_data)
	);

	// ======================================================================
	// 2x AMD axi_fifo_mm_s (RX-only, PG080; config rationale in gen_ip.tcl
	// and SPEC §4). The shims' tkeep outputs (constant 4'hF) stay
	// unconnected -- the IP is configured without tkeep, records are full
	// words.
	// ======================================================================
	wp_axi_fifo fifo0 (
		.interrupt          (),
		.s_axi_aclk         (pl_clk0),
		.s_axi_aresetn      (aresetn),
		.s_axi_awaddr       ({16'b0, wa_q[15:0]}),
		.s_axi_awvalid      (f0_awvalid),
		.s_axi_awready      (f0_awready),
		.s_axi_wdata        (wd_q),
		.s_axi_wstrb        (ws_q),
		.s_axi_wvalid       (f0_wvalid),
		.s_axi_wready       (f0_wready),
		.s_axi_bresp        (f0_bresp),
		.s_axi_bvalid       (f0_bvalid),
		.s_axi_bready       (f0_bready),
		.s_axi_araddr       ({16'b0, ra_q[15:0]}),
		.s_axi_arvalid      (f0_arvalid),
		.s_axi_arready      (f0_arready),
		.s_axi_rdata        (f0_rdata),
		.s_axi_rresp        (f0_rresp),
		.s_axi_rvalid       (f0_rvalid),
		.s_axi_rready       (f0_rready),
		.axi_str_rxd_tvalid (m0_tvalid),
		.axi_str_rxd_tready (m0_tready),
		.axi_str_rxd_tlast  (m0_tlast),
		.axi_str_rxd_tdata  (m0_tdata)
	);

	wp_axi_fifo fifo1 (
		.interrupt          (),
		.s_axi_aclk         (pl_clk0),
		.s_axi_aresetn      (aresetn),
		.s_axi_awaddr       ({16'b0, wa_q[15:0]}),
		.s_axi_awvalid      (f1_awvalid),
		.s_axi_awready      (f1_awready),
		.s_axi_wdata        (wd_q),
		.s_axi_wstrb        (ws_q),
		.s_axi_wvalid       (f1_wvalid),
		.s_axi_wready       (f1_wready),
		.s_axi_bresp        (f1_bresp),
		.s_axi_bvalid       (f1_bvalid),
		.s_axi_bready       (f1_bready),
		.s_axi_araddr       ({16'b0, ra_q[15:0]}),
		.s_axi_arvalid      (f1_arvalid),
		.s_axi_arready      (f1_arready),
		.s_axi_rdata        (f1_rdata),
		.s_axi_rresp        (f1_rresp),
		.s_axi_rvalid       (f1_rvalid),
		.s_axi_rready       (f1_rready),
		.axi_str_rxd_tvalid (m1_tvalid),
		.axi_str_rxd_tready (m1_tready),
		.axi_str_rxd_tlast  (m1_tlast),
		.axi_str_rxd_tdata  (m1_tdata)
	);

endmodule // tgc5b2_rvcfi_kv260_top

`default_nettype wire
