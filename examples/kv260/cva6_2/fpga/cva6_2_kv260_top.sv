// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Bitstream top of the dual-CVA6 demonstrator.
 *
 * @details
 *   Twin of `rocket2_kv260_top` / `cva6_linux64_kv260_top`. The same
 *   75 MHz domain, the same glue IPs (dwc 128->32, pc AXI4->Lite, rst) --
 *   and ONE difference in PS provisioning that follows from the AMP
 *   design:
 *
 *     M_AXI_HPM0_FPD (128 bit) -> dwc 128->32 -> pc AXI4->Lite
 *         -> cva6_2_soc_top @ 0xA000_0000 (4 MiB aperture)
 *     S_AXI_HP0_FPD (saxigp2, 32 bit)  <- trace DDR sink (write only)
 *     S_AXI_HP1_FPD (saxigp3, 64 bit)  <- private memory path core 0
 *     S_AXI_HP2_FPD (saxigp4, 64 bit)  <- private memory path core 1   NEW
 *     S_AXI_HP3_FPD (saxigp5, 64 bit)  <- shared mailbox                NEW
 *
 *   FOUR slave ports instead of two -- hence an OWN PS instance
 *   `ct_soc_kv260_ps4` instead of the shared `ct_soc_kv260_ps`. Extending
 *   the shared IP would have forced every other app to resynthesize and
 *   left the two new slaves' ports undriven in every other top -- and a
 *   demonstrator is running from one of these bitstreams right now on some
 *   board. An additive second IP costs a minute of generation and touches
 *   nothing.
 *
 *   WHY TWO MEMORY PORTS AND NO CROSSBAR: the two cv64a6 cores are
 *   INCOHERENT (no L1 coherence path in this tree, `NOC_TYPE_AXI4_ATOP`).
 *   A shared cached window would be silent data corruption. Each core
 *   therefore gets its own cached window and its own port; only the
 *   UNCACHED mailbox on HP3 is shared. Full rationale: header of
 *   `rtl/cva6_2_mem_xbar.sv`.
 *
 *   Memory map (reserved-memory window):
 *     0x6000_0000 + 64 MiB   trace-sink ring        (unchanged)
 *     0x6400_0000 + 32 MiB   guest RAM core 0
 *     0x6600_0000 + 32 MiB   guest RAM core 1
 *     0x6800_0000 + 16 MiB   mailbox (uncached, both cores)
 *   The used range therefore stays within 0x6000_0000..0x6FFF_FFFF (which
 *   the reservation covers) -- and cacheable memory ends at 0x6800_0000,
 *   below the board-proven boundary.
 *
 *   RV32 OR RV64 is decided solely by the CVA6 configuration in the run's
 *   file list (`run_cva6_2_bitstream.tcl`, second tclarg). This file is
 *   identical for both -- the requirement of a congruent view.
 *
 *   EN_ETRACE is FIXED at 0: the funnel recognizes packet boundaries via
 *   the Nexus MSEO bits, an E-Trace backend delivers raw bytes without
 *   MSEO (`cva6_2_soc_synth_wrap` aborts elaboration at 1).
 */
module cva6_2_kv260_top #(
	parameter bit EN_ETRACE = 1'b0,
	// Guest RAM per core. Must match the memory node of the respective
	// devicetree (correspondence rule, CVA6_PIN.md §D5).
	parameter logic [63:0] DRAM_SIZE = 64'h0200_0000     // 32 MiB
) (
	// PIB: parallel trace port on PMOD J2 (cva6_pib_pmod.xdc)
	output wire       pib_clk,
	output wire [3:0] pib_data
);

	// -- Clock + reset -------------------------------------------------------
	uwire logic        pl_clk0;
	uwire logic        pl_resetn0;
	uwire logic        aresetn;

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

	// -- Trace sink: SoC's AXI4 master -> PS S_AXI_HP0_FPD (saxigp2) -------
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

	// -- Core 0 -> PS S_AXI_HP1_FPD (saxigp3) --------------------------------
	uwire logic [3:0]  hp1_awid, hp1_arid;
	uwire logic [63:0] hp1_awaddr, hp1_araddr;
	uwire logic [7:0]  hp1_awlen, hp1_arlen;
	uwire logic [2:0]  hp1_awsize, hp1_arsize;
	uwire logic [1:0]  hp1_awburst, hp1_arburst;
	uwire logic        hp1_awlock, hp1_arlock;
	uwire logic [3:0]  hp1_awcache, hp1_arcache;
	uwire logic [2:0]  hp1_awprot, hp1_arprot;
	uwire logic        hp1_awvalid, hp1_awready, hp1_arvalid, hp1_arready;
	uwire logic [63:0] hp1_wdata, hp1_rdata;
	uwire logic [7:0]  hp1_wstrb;
	uwire logic        hp1_wlast, hp1_wvalid, hp1_wready;
	uwire logic [1:0]  hp1_bresp, hp1_rresp;
	uwire logic        hp1_bvalid, hp1_bready, hp1_rlast, hp1_rvalid, hp1_rready;
	uwire logic [5:0]  hp1_bid_w, hp1_rid_w;   // 6 bit ID on the PS side
	uwire logic [3:0]  hp1_bid = hp1_bid_w[3:0];
	uwire logic [3:0]  hp1_rid = hp1_rid_w[3:0];

	// -- Core 1 -> PS S_AXI_HP2_FPD (saxigp4) --------------------------------
	uwire logic [3:0]  hp2_awid, hp2_arid;
	uwire logic [63:0] hp2_awaddr, hp2_araddr;
	uwire logic [7:0]  hp2_awlen, hp2_arlen;
	uwire logic [2:0]  hp2_awsize, hp2_arsize;
	uwire logic [1:0]  hp2_awburst, hp2_arburst;
	uwire logic        hp2_awlock, hp2_arlock;
	uwire logic [3:0]  hp2_awcache, hp2_arcache;
	uwire logic [2:0]  hp2_awprot, hp2_arprot;
	uwire logic        hp2_awvalid, hp2_awready, hp2_arvalid, hp2_arready;
	uwire logic [63:0] hp2_wdata, hp2_rdata;
	uwire logic [7:0]  hp2_wstrb;
	uwire logic        hp2_wlast, hp2_wvalid, hp2_wready;
	uwire logic [1:0]  hp2_bresp, hp2_rresp;
	uwire logic        hp2_bvalid, hp2_bready, hp2_rlast, hp2_rvalid, hp2_rready;
	uwire logic [5:0]  hp2_bid_w, hp2_rid_w;
	uwire logic [3:0]  hp2_bid = hp2_bid_w[3:0];
	uwire logic [3:0]  hp2_rid = hp2_rid_w[3:0];

	// -- Mailbox -> PS S_AXI_HP3_FPD (saxigp5) ------------------------------
	// ID width 2 (cva6_2_mem_xbar: one ID per core) -- zero-extended above
	// to the PS port's 6 bit and truncated again on the way back.
	uwire logic [1:0]  mb_awid, mb_arid;
	uwire logic [63:0] mb_awaddr, mb_araddr;
	uwire logic [7:0]  mb_awlen, mb_arlen;
	uwire logic [2:0]  mb_awsize, mb_arsize;
	uwire logic [1:0]  mb_awburst, mb_arburst;
	uwire logic        mb_awlock, mb_arlock;
	uwire logic [3:0]  mb_awcache, mb_arcache;
	uwire logic [2:0]  mb_awprot, mb_arprot;
	uwire logic        mb_awvalid, mb_awready, mb_arvalid, mb_arready;
	uwire logic [63:0] mb_wdata, mb_rdata;
	uwire logic [7:0]  mb_wstrb;
	uwire logic        mb_wlast, mb_wvalid, mb_wready;
	uwire logic [1:0]  mb_bresp, mb_rresp;
	uwire logic        mb_bvalid, mb_bready, mb_rlast, mb_rvalid, mb_rready;
	uwire logic [5:0]  mb_bid_w, mb_rid_w;
	uwire logic [1:0]  mb_bid = mb_bid_w[1:0];
	uwire logic [1:0]  mb_rid = mb_rid_w[1:0];

	ct_soc_kv260_ps4 ps (
		.maxihpm0_fpd_aclk (pl_clk0),
		.saxihp0_fpd_aclk  (pl_clk0),
		// S_AXI_HP0_FPD <- trace DDR sink (write only)
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
		// S_AXI_HP1_FPD (64 bit) <- private memory path core 0.
		// No atop input on the HP port -- none is needed either: the A
		// extension is resolved by the atomics block in the fabric, the
		// guard drives m_awatop constant 0 (rocket_mem_window.sv).
		.saxihp1_fpd_aclk  (pl_clk0),
		.saxigp3_awid      ({2'd0, hp1_awid}),
		.saxigp3_awaddr    (hp1_awaddr[48:0]),
		.saxigp3_awlen     (hp1_awlen),
		.saxigp3_awsize    (hp1_awsize),
		.saxigp3_awburst   (hp1_awburst),
		.saxigp3_awlock    (hp1_awlock),
		.saxigp3_awcache   (hp1_awcache),
		.saxigp3_awprot    (hp1_awprot),
		.saxigp3_awvalid   (hp1_awvalid),
		.saxigp3_awready   (hp1_awready),
		.saxigp3_awqos     (4'd0),
		.saxigp3_awuser    (1'b0),
		.saxigp3_wdata     (hp1_wdata),
		.saxigp3_wstrb     (hp1_wstrb),
		.saxigp3_wlast     (hp1_wlast),
		.saxigp3_wvalid    (hp1_wvalid),
		.saxigp3_wready    (hp1_wready),
		.saxigp3_bid       (hp1_bid_w),
		.saxigp3_bresp     (hp1_bresp),
		.saxigp3_bvalid    (hp1_bvalid),
		.saxigp3_bready    (hp1_bready),
		.saxigp3_arid      ({2'd0, hp1_arid}),
		.saxigp3_araddr    (hp1_araddr[48:0]),
		.saxigp3_arlen     (hp1_arlen),
		.saxigp3_arsize    (hp1_arsize),
		.saxigp3_arburst   (hp1_arburst),
		.saxigp3_arlock    (hp1_arlock),
		.saxigp3_arcache   (hp1_arcache),
		.saxigp3_arprot    (hp1_arprot),
		.saxigp3_arvalid   (hp1_arvalid),
		.saxigp3_arready   (hp1_arready),
		.saxigp3_arqos     (4'd0),
		.saxigp3_aruser    (1'b0),
		.saxigp3_rid       (hp1_rid_w),
		.saxigp3_rdata     (hp1_rdata),
		.saxigp3_rresp     (hp1_rresp),
		.saxigp3_rlast     (hp1_rlast),
		.saxigp3_rvalid    (hp1_rvalid),
		.saxigp3_rready    (hp1_rready),
		// S_AXI_HP2_FPD (64 bit) <- private memory path core 1.
		.saxihp2_fpd_aclk  (pl_clk0),
		.saxigp4_awid      ({2'd0, hp2_awid}),
		.saxigp4_awaddr    (hp2_awaddr[48:0]),
		.saxigp4_awlen     (hp2_awlen),
		.saxigp4_awsize    (hp2_awsize),
		.saxigp4_awburst   (hp2_awburst),
		.saxigp4_awlock    (hp2_awlock),
		.saxigp4_awcache   (hp2_awcache),
		.saxigp4_awprot    (hp2_awprot),
		.saxigp4_awvalid   (hp2_awvalid),
		.saxigp4_awready   (hp2_awready),
		.saxigp4_awqos     (4'd0),
		.saxigp4_awuser    (1'b0),
		.saxigp4_wdata     (hp2_wdata),
		.saxigp4_wstrb     (hp2_wstrb),
		.saxigp4_wlast     (hp2_wlast),
		.saxigp4_wvalid    (hp2_wvalid),
		.saxigp4_wready    (hp2_wready),
		.saxigp4_bid       (hp2_bid_w),
		.saxigp4_bresp     (hp2_bresp),
		.saxigp4_bvalid    (hp2_bvalid),
		.saxigp4_bready    (hp2_bready),
		.saxigp4_arid      ({2'd0, hp2_arid}),
		.saxigp4_araddr    (hp2_araddr[48:0]),
		.saxigp4_arlen     (hp2_arlen),
		.saxigp4_arsize    (hp2_arsize),
		.saxigp4_arburst   (hp2_arburst),
		.saxigp4_arlock    (hp2_arlock),
		.saxigp4_arcache   (hp2_arcache),
		.saxigp4_arprot    (hp2_arprot),
		.saxigp4_arvalid   (hp2_arvalid),
		.saxigp4_arready   (hp2_arready),
		.saxigp4_arqos     (4'd0),
		.saxigp4_aruser    (1'b0),
		.saxigp4_rid       (hp2_rid_w),
		.saxigp4_rdata     (hp2_rdata),
		.saxigp4_rresp     (hp2_rresp),
		.saxigp4_rlast     (hp2_rlast),
		.saxigp4_rvalid    (hp2_rvalid),
		.saxigp4_rready    (hp2_rready),
		// S_AXI_HP3_FPD (64 bit) <- shared mailbox (both cores).
		.saxihp3_fpd_aclk  (pl_clk0),
		.saxigp5_awid      ({4'd0, mb_awid}),
		.saxigp5_awaddr    (mb_awaddr[48:0]),
		.saxigp5_awlen     (mb_awlen),
		.saxigp5_awsize    (mb_awsize),
		.saxigp5_awburst   (mb_awburst),
		.saxigp5_awlock    (mb_awlock),
		.saxigp5_awcache   (mb_awcache),
		.saxigp5_awprot    (mb_awprot),
		.saxigp5_awvalid   (mb_awvalid),
		.saxigp5_awready   (mb_awready),
		.saxigp5_awqos     (4'd0),
		.saxigp5_awuser    (1'b0),
		.saxigp5_wdata     (mb_wdata),
		.saxigp5_wstrb     (mb_wstrb),
		.saxigp5_wlast     (mb_wlast),
		.saxigp5_wvalid    (mb_wvalid),
		.saxigp5_wready    (mb_wready),
		.saxigp5_bid       (mb_bid_w),
		.saxigp5_bresp     (mb_bresp),
		.saxigp5_bvalid    (mb_bvalid),
		.saxigp5_bready    (mb_bready),
		.saxigp5_arid      ({4'd0, mb_arid}),
		.saxigp5_araddr    (mb_araddr[48:0]),
		.saxigp5_arlen     (mb_arlen),
		.saxigp5_arsize    (mb_arsize),
		.saxigp5_arburst   (mb_arburst),
		.saxigp5_arlock    (mb_arlock),
		.saxigp5_arcache   (mb_arcache),
		.saxigp5_arprot    (mb_arprot),
		.saxigp5_arvalid   (mb_arvalid),
		.saxigp5_arready   (mb_arready),
		.saxigp5_arqos     (4'd0),
		.saxigp5_aruser    (1'b0),
		.saxigp5_rid       (mb_rid_w),
		.saxigp5_rdata     (mb_rdata),
		.saxigp5_rresp     (mb_rresp),
		.saxigp5_rlast     (mb_rlast),
		.saxigp5_rvalid    (mb_rvalid),
		.saxigp5_rready    (mb_rready),
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
		.maxigp0_awuser    (),
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
		.maxigp0_aruser    (),
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
		.aux_reset_in         (1'b1),
		.mb_debug_sys_rst     (1'b0),
		.dcm_locked           (1'b1),
		.mb_reset             (),
		.bus_struct_reset     (),
		.peripheral_reset     (),
		.interconnect_aresetn (),
		.peripheral_aresetn   (aresetn)
	);

	// -- 128 -> 32 downsize --------------------------------------------------
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
		.s_axi_awregion (4'b0),
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

	// -- The SoC (decodes the lower 22 address bits of its 4 MiB window) --
	cva6_2_soc_top #(
		.BOOT_ADDR   (64'h6400_0000),   // core-side view, both cores the same
		.DRAM_SIZE   (DRAM_SIZE),       // 32 MiB per core
		.MBOX_BASE   (64'h6800_0000),   // outside the cached region (64 MiB)
		.MBOX_SIZE   (64'h0100_0000),   // 16 MiB
		.PS_DRAM0    (64'h6400_0000),
		.PS_DRAM1    (64'h6600_0000),
		.PS_MBOX     (64'h6800_0000),
		.CLINT_BASE  (32'h0200_0000),
		.UART_BASE   (32'h1000_0000),
		.CLK_HZ      (75_000_000),
		.TICK_HZ     (1_000_000),
		.CON_BYTES   (65536),
		.TRACE_DEPTH (262144),          // 1 MiB URAM ring (same as rocket2/CVA6)
		.EN_ETRACE   (EN_ETRACE)        // MUST stay 0, see header (funnel parses MSEO)
	) soc (
		.clk            (pl_clk0),
		.resetn         (aresetn),
		.s_axi_awaddr   (lite_awaddr[21:0]),
		.s_axi_awvalid  (lite_awvalid),
		.s_axi_awready  (lite_awready),
		.s_axi_wdata    (lite_wdata),
		.s_axi_wstrb    (lite_wstrb),
		.s_axi_wvalid   (lite_wvalid),
		.s_axi_wready   (lite_wready),
		.s_axi_bresp    (lite_bresp),
		.s_axi_bvalid   (lite_bvalid),
		.s_axi_bready   (lite_bready),
		.s_axi_araddr   (lite_araddr[21:0]),
		.s_axi_arvalid  (lite_arvalid),
		.s_axi_arready  (lite_arready),
		.s_axi_rdata    (lite_rdata),
		.s_axi_rresp    (lite_rresp),
		.s_axi_rvalid   (lite_rvalid),
		.s_axi_rready   (lite_rready),
		.m0_axi_awid    (hp1_awid),
		.m0_axi_awaddr  (hp1_awaddr),
		.m0_axi_awlen   (hp1_awlen),
		.m0_axi_awsize  (hp1_awsize),
		.m0_axi_awburst (hp1_awburst),
		.m0_axi_awlock  (hp1_awlock),
		.m0_axi_awcache (hp1_awcache),
		.m0_axi_awprot  (hp1_awprot),
		.m0_axi_awvalid (hp1_awvalid),
		.m0_axi_awready (hp1_awready),
		.m0_axi_wdata   (hp1_wdata),
		.m0_axi_wstrb   (hp1_wstrb),
		.m0_axi_wlast   (hp1_wlast),
		.m0_axi_wvalid  (hp1_wvalid),
		.m0_axi_wready  (hp1_wready),
		.m0_axi_bid     (hp1_bid),
		.m0_axi_bresp   (hp1_bresp),
		.m0_axi_bvalid  (hp1_bvalid),
		.m0_axi_bready  (hp1_bready),
		.m0_axi_arid    (hp1_arid),
		.m0_axi_araddr  (hp1_araddr),
		.m0_axi_arlen   (hp1_arlen),
		.m0_axi_arsize  (hp1_arsize),
		.m0_axi_arburst (hp1_arburst),
		.m0_axi_arlock  (hp1_arlock),
		.m0_axi_arcache (hp1_arcache),
		.m0_axi_arprot  (hp1_arprot),
		.m0_axi_arvalid (hp1_arvalid),
		.m0_axi_arready (hp1_arready),
		.m0_axi_rid     (hp1_rid),
		.m0_axi_rdata   (hp1_rdata),
		.m0_axi_rresp   (hp1_rresp),
		.m0_axi_rlast   (hp1_rlast),
		.m0_axi_rvalid  (hp1_rvalid),
		.m0_axi_rready  (hp1_rready),
		.m1_axi_awid    (hp2_awid),
		.m1_axi_awaddr  (hp2_awaddr),
		.m1_axi_awlen   (hp2_awlen),
		.m1_axi_awsize  (hp2_awsize),
		.m1_axi_awburst (hp2_awburst),
		.m1_axi_awlock  (hp2_awlock),
		.m1_axi_awcache (hp2_awcache),
		.m1_axi_awprot  (hp2_awprot),
		.m1_axi_awvalid (hp2_awvalid),
		.m1_axi_awready (hp2_awready),
		.m1_axi_wdata   (hp2_wdata),
		.m1_axi_wstrb   (hp2_wstrb),
		.m1_axi_wlast   (hp2_wlast),
		.m1_axi_wvalid  (hp2_wvalid),
		.m1_axi_wready  (hp2_wready),
		.m1_axi_bid     (hp2_bid),
		.m1_axi_bresp   (hp2_bresp),
		.m1_axi_bvalid  (hp2_bvalid),
		.m1_axi_bready  (hp2_bready),
		.m1_axi_arid    (hp2_arid),
		.m1_axi_araddr  (hp2_araddr),
		.m1_axi_arlen   (hp2_arlen),
		.m1_axi_arsize  (hp2_arsize),
		.m1_axi_arburst (hp2_arburst),
		.m1_axi_arlock  (hp2_arlock),
		.m1_axi_arcache (hp2_arcache),
		.m1_axi_arprot  (hp2_arprot),
		.m1_axi_arvalid (hp2_arvalid),
		.m1_axi_arready (hp2_arready),
		.m1_axi_rid     (hp2_rid),
		.m1_axi_rdata   (hp2_rdata),
		.m1_axi_rresp   (hp2_rresp),
		.m1_axi_rlast   (hp2_rlast),
		.m1_axi_rvalid  (hp2_rvalid),
		.m1_axi_rready  (hp2_rready),
		.mb_axi_awid    (mb_awid),
		.mb_axi_awaddr  (mb_awaddr),
		.mb_axi_awlen   (mb_awlen),
		.mb_axi_awsize  (mb_awsize),
		.mb_axi_awburst (mb_awburst),
		.mb_axi_awlock  (mb_awlock),
		.mb_axi_awcache (mb_awcache),
		.mb_axi_awprot  (mb_awprot),
		.mb_axi_awvalid (mb_awvalid),
		.mb_axi_awready (mb_awready),
		.mb_axi_wdata   (mb_wdata),
		.mb_axi_wstrb   (mb_wstrb),
		.mb_axi_wlast   (mb_wlast),
		.mb_axi_wvalid  (mb_wvalid),
		.mb_axi_wready  (mb_wready),
		.mb_axi_bid     (mb_bid),
		.mb_axi_bresp   (mb_bresp),
		.mb_axi_bvalid  (mb_bvalid),
		.mb_axi_bready  (mb_bready),
		.mb_axi_arid    (mb_arid),
		.mb_axi_araddr  (mb_araddr),
		.mb_axi_arlen   (mb_arlen),
		.mb_axi_arsize  (mb_arsize),
		.mb_axi_arburst (mb_arburst),
		.mb_axi_arlock  (mb_arlock),
		.mb_axi_arcache (mb_arcache),
		.mb_axi_arprot  (mb_arprot),
		.mb_axi_arvalid (mb_arvalid),
		.mb_axi_arready (mb_arready),
		.mb_axi_rid     (mb_rid),
		.mb_axi_rdata   (mb_rdata),
		.mb_axi_rresp   (mb_rresp),
		.mb_axi_rlast   (mb_rlast),
		.mb_axi_rvalid  (mb_rvalid),
		.mb_axi_rready  (mb_rready),
		.t_axi_awaddr   (hp0_awaddr),
		.t_axi_awlen    (hp0_awlen),
		.t_axi_awsize   (hp0_awsize),
		.t_axi_awburst  (hp0_awburst),
		.t_axi_awvalid  (hp0_awvalid),
		.t_axi_awready  (hp0_awready),
		.t_axi_wdata    (hp0_wdata),
		.t_axi_wstrb    (hp0_wstrb),
		.t_axi_wlast    (hp0_wlast),
		.t_axi_wvalid   (hp0_wvalid),
		.t_axi_wready   (hp0_wready),
		.t_axi_bresp    (hp0_bresp),
		.t_axi_bvalid   (hp0_bvalid),
		.t_axi_bready   (hp0_bready),
		.pib_clk        (pib_clk),
		.pib_data       (pib_data)
	);

endmodule // cva6_2_kv260_top

`default_nettype wire
