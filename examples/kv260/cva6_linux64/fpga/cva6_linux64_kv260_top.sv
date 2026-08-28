// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Bitstream top of the RV64 Linux CVA6 demonstrator: Zynq PS +
 *           AXI plumbing around cva6_linux64_soc_top.
 *
 * @details
 *   ADDITIVE RV64 twin of `cva6_linux_kv260_top` (in
 *   [`../../cva6_linux/fpga/`](../../cva6_linux/fpga/)). The RV32 file
 *   stays unchanged -- it carries the board-proven bitstream (2026-07-27).
 *   PS provisioning is BIT-IDENTICAL: the same four XCIs from gen_ip.tcl,
 *   the same 75 MHz domain, the same aperture. The only difference is the
 *   SoC instance (cva6_linux64_soc_top instead of cva6_linux_soc_top) and
 *   thereby the core (cv64a6_imac_sv39_ctrace, delta D6: RV64IMAC, no FPU,
 *   Sv39).
 *
 *   Three PS interfaces:
 *
 *     M_AXI_HPM0_FPD (128 bit) -> dwc 128->32 -> pc AXI4->Lite
 *         -> cva6_linux64_soc_top @ 0xA000_0000 (4 MiB aperture)
 *     S_AXI_HP0_FPD (saxigp2, 32 bit)  <- trace DDR sink (write only)
 *     S_AXI_HP1_FPD (saxigp3, 64 bit)  <- CVA6 memory path (read+write)
 *
 *   Memory map (the RV64 devicetree sw/cva6_linux64/cva6_kv260_rv64.dts
 *   carries the same numbers -- memory@64000000, reg = <0x64000000 0x0C000000>):
 *     0x6000_0000 + 64 MiB   trace-sink ring
 *     0x6400_0000 + 192 MiB  CVA6 Linux RAM (OpenSBI @ 0x6400_0000)
 *   Both live inside the same reserved 256 MiB window; addresses pass
 *   through 1:1 (no translation in the PL). The core carries 64-bit
 *   addresses but exclusively uses this window -- hence the saxigp3 wiring
 *   is bit-identical to the RV32 version (araddr[48:0] to the HP port).
 *
 *   The CVA6 is the ONLY core here; no funnel -- the encoder's ATB goes
 *   directly into the ring. Unlike the RV32 design, the encoder here is
 *   **N-Trace only** (`EN_ETRACE = 0`) -- measured rationale at the
 *   instantiation below. The encoder comes from the PINNED tree and is
 *   32-bit wide there (tip_pkg::TIP_IADDRESS_WIDTH = 32); this bitstream is
 *   therefore the carrier for the Linux BOOT, not for the gapless RV64 PC
 *   proof. That needs a rebuild against a 64-bit encoder tree (CT_XLEN=64).
 */
module cva6_linux64_kv260_top (
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

	// -- CVA6 memory path: SoC's AXI4 master -> PS S_AXI_HP1_FPD (saxigp3)
	uwire logic [3:0]  hp1_awid, hp1_arid, hp1_bid, hp1_rid;
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
	assign hp1_bid = hp1_bid_w[3:0];
	assign hp1_rid = hp1_rid_w[3:0];

	ct_soc_kv260_ps ps (
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
		// S_AXI_HP1_FPD (64 bit) <- CVA6 memory path.
		// No atop input on the HP port -- none is needed either: the
		// axi_riscv_atomics_wrap in cva6_linux_mem_xbar already resolves
		// AMOs (the assertion there secures atop==0 at the DRAM port).
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
	// BOOT_ADDR/DRAM_SIZE are 64 bit here (the core takes VLEN-wide
	// boot_addr); the numbers themselves are unchanged from the RV32
	// design and must match the memory node in cva6_kv260_rv64.dts and
	// ExecuteRegionLength in the core configuration (correspondence rule,
	// third_party/cva6_ref/CVA6_PIN.md).
	cva6_linux64_soc_top #(
		.BOOT_ADDR   (64'h6400_0000),
		.DRAM_SIZE   (64'h0C00_0000),   // 192 MiB == memory@64000000 in the DTS
		.CLK_HZ      (75_000_000),
		.TICK_HZ     (1_000_000),
		.CON_BYTES   (65536),
		.TRACE_DEPTH (262144),     // 1 MiB URAM ring (same as the trio example)
		// N-Trace ONLY (measured): the E-Trace backend costs 10,245 LUT and
		// carries the critical path (OOC DUAL: te_inst_gen -> te_packetizer,
		// 38 logic levels, WNS +1.355 ns; without it: WNS +3.331 ns,
		// critical path moves into the core). There is also no decoder for
		// a 64-bit E-Trace stream in this program regardless -- that gap
		// is deferred, the 64-bit chain is N-Trace only. The compression
		// suite (IR/RH/WideICNT/RB/JTC/BP) stays ON: it decides how much of
		// the boot fits into the 1 MiB ring.
		.EN_ETRACE   (1'b0)
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
		.m_axi_awid     (hp1_awid),
		.m_axi_awaddr   (hp1_awaddr),
		.m_axi_awlen    (hp1_awlen),
		.m_axi_awsize   (hp1_awsize),
		.m_axi_awburst  (hp1_awburst),
		.m_axi_awlock   (hp1_awlock),
		.m_axi_awcache  (hp1_awcache),
		.m_axi_awprot   (hp1_awprot),
		.m_axi_awvalid  (hp1_awvalid),
		.m_axi_awready  (hp1_awready),
		.m_axi_wdata    (hp1_wdata),
		.m_axi_wstrb    (hp1_wstrb),
		.m_axi_wlast    (hp1_wlast),
		.m_axi_wvalid   (hp1_wvalid),
		.m_axi_wready   (hp1_wready),
		.m_axi_bid      (hp1_bid),
		.m_axi_bresp    (hp1_bresp),
		.m_axi_bvalid   (hp1_bvalid),
		.m_axi_bready   (hp1_bready),
		.m_axi_arid     (hp1_arid),
		.m_axi_araddr   (hp1_araddr),
		.m_axi_arlen    (hp1_arlen),
		.m_axi_arsize   (hp1_arsize),
		.m_axi_arburst  (hp1_arburst),
		.m_axi_arlock   (hp1_arlock),
		.m_axi_arcache  (hp1_arcache),
		.m_axi_arprot   (hp1_arprot),
		.m_axi_arvalid  (hp1_arvalid),
		.m_axi_arready  (hp1_arready),
		.m_axi_rid      (hp1_rid),
		.m_axi_rdata    (hp1_rdata),
		.m_axi_rresp    (hp1_rresp),
		.m_axi_rlast    (hp1_rlast),
		.m_axi_rvalid   (hp1_rvalid),
		.m_axi_rready   (hp1_rready),
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

endmodule // cva6_linux64_kv260_top

`default_nettype wire
