// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Bitstream top of the KV260 app -- Zynq PS + AXI plumbing around
 *           ct_soc_top, plain SV (no block design).
 *
 * @details
 *   PS M_AXI_HPM0_FPD (AXI4, 128-bit, pl_clk0 = 75 MHz)
 *     -> AXI data width converter 128 -> 32
 *     -> AXI4 -> AXI4-Lite protocol converter
 *     -> ct_soc_top @ 0xA000_0000 (the PS FPD window routed to HPM0)
 *
 *   The four Xilinx IPs (ct_soc_kv260_ps/_rst/_dwc/_pc) are generated as
 *   standalone XCIs by gen_ip.tcl -- see there for each configuration and for
 *   why HPM0 must stay at its native 128-bit width (byte-lane steering).
 *   Everything runs in the single pl_clk0 domain; ct_soc_kv260_rst
 *   synchronizes pl_resetn0 into it. No external pins: the PS pads are
 *   implicit, so the module has no ports.
 */

// the predecessor repository Phase 3/4 (dual-core): a 1:1 copy of mbv_kv260_top, the only
// change is the module name + SoC instance (`duo_soc_top` = MBV + TGC5B +
// ct_L1_funnel). The four standalone IPs (ct_soc_kv260_ps/_rst/_dwc/_pc)
// remain unchanged.
module duo_kv260_top (
	// PIB: parallel trace port on PMOD J2 (duo_pib_pmod.xdc)
	output wire       pib_clk,
	output wire [3:0] pib_data
);

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

	// -- DDR4 sink: AXI4 master of the SoC -> PS S_AXI_HP0_FPD (saxigp2) -----
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

	ct_soc_kv260_ps ps (
		.maxihpm0_fpd_aclk (pl_clk0),
		.saxihp0_fpd_aclk  (pl_clk0),
		// S_AXI_HP0_FPD write channels <- DDR4-Trace-Sink (read channels idle)
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
		// S_AXI_HP1_FPD (saxigp3, present since the trio IP regen): idle --
		// only the handshakes are tied (valid=0/ready=1), the rest may float.
		.saxihp1_fpd_aclk  (pl_clk0),
		.saxigp3_awvalid   (1'b0),
		.saxigp3_wvalid    (1'b0),
		.saxigp3_bready    (1'b1),
		.saxigp3_arvalid   (1'b0),
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
	uwire logic        lite_awvalid, lite_awready, lite_arvalid, lite_arready;
	uwire logic [31:0] lite_wdata,  lite_rdata;
	uwire logic [3:0]  lite_wstrb;
	uwire logic        lite_wvalid, lite_wready;
	uwire logic [1:0]  lite_bresp,  lite_rresp;
	uwire logic        lite_bvalid, lite_bready, lite_rvalid, lite_rready;

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

	// -- The SoC (decodes the low 22 address bits of its 4 MiB window) -------
	duo_soc_top soc (
		.clk           (pl_clk0),
		.resetn        (aresetn),
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
		.pib_clk       (pib_clk),
		.pib_data      (pib_data),
		.s_axi_awaddr  (lite_awaddr[21:0]),
		.s_axi_awprot  (lite_awprot),
		.s_axi_awvalid (lite_awvalid),
		.s_axi_awready (lite_awready),
		.s_axi_wdata   (lite_wdata),
		.s_axi_wstrb   (lite_wstrb),
		.s_axi_wvalid  (lite_wvalid),
		.s_axi_wready  (lite_wready),
		.s_axi_bresp   (lite_bresp),
		.s_axi_bvalid  (lite_bvalid),
		.s_axi_bready  (lite_bready),
		.s_axi_araddr  (lite_araddr[21:0]),
		.s_axi_arprot  (lite_arprot),
		.s_axi_arvalid (lite_arvalid),
		.s_axi_arready (lite_arready),
		.s_axi_rdata   (lite_rdata),
		.s_axi_rresp   (lite_rresp),
		.s_axi_rvalid  (lite_rvalid),
		.s_axi_rready  (lite_rready)
	);

endmodule // duo_kv260_top

`default_nettype wire
