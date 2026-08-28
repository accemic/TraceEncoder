// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    cva6_2_soc_synth_wrap -- the TWO-CORE cv64a6 branch, built as
 *           a twin of rocket2_soc_synth_wrap:
 *
 *     cva6_trace_wrap core0 (HART_ID 0)
 *       |- AXI4 master 64 bit -> mem0_axi_*
 *       `- ITI -> cva6_iti_to_ctte_tip shim0 -> tip0 -> ct_encoder enc0 -+
 *                                                                          |-> ct_L1_funnel -> ATB
 *     cva6_trace_wrap core1 (HART_ID 1)                                   |
 *       |- AXI4 master 64 bit -> mem1_axi_*                               |
 *       `- ITI -> cva6_iti_to_ctte_tip shim1 -> tip1 -> ct_encoder enc1 -+
 *
 * @details
 *   =======================================================================
 *   PURPOSE AND SCOPE -- this is a MEASUREMENT CIRCUIT, not a SoC
 *   =======================================================================
 *
 *   This module answers the FIRST question ("does a dual-cv64a6 with two
 *   encoders fit on the xck26?") and ONLY that. It is deliberately cut as
 *   a **LOWER BOUND**:
 *
 *     - TWO separate AXI masters instead of a shared memory tree. The real
 *       SoC additionally needs a crossbar + atomics + demux
 *       (cva6_linux_mem_xbar: 2,558 LUT in the single-core build, of which
 *       atomics is 1,726) and a coherence solution (see below). All of
 *       that makes the picture WORSE, never better.
 *     - No console, no URAM ring, no DDR sink, no PIB, no periph, no PS
 *       glue IPs.
 *
 *   The direction of proof follows from that, and it is the only one this
 *   module carries: **if already the lower bound exceeds capacity, the
 *   question is conclusively answered with NO.** If it stays under it,
 *   NOTHING is proven -- then the full build must be measured.
 *
 *   The binding size is CLB occupancy, NOT the LUT count (finding from
 *   synth_rocket2_ooc.tcl: a trio sat at 85.9% LUT and 99.8% CLB). A plain
 *   synthesis evaluation therefore cannot answer the question --
 *   `report_utilization` after synth_design has no CLB row at all. The
 *   companion run (synth_cva6_2_ooc.tcl) therefore additionally places.
 *
 *   =======================================================================
 *   WARNING: COHERENCE -- the second blocker, independent of area
 *   =======================================================================
 *
 *   The two-hart Rocket gets SMP for free: its generat supplies ONE mem
 *   port for both harts, and TLBroadcast keeps the L1 coherent (see the
 *   header of rocket2_soc_synth_wrap). cv64a6 in this tree has nothing of
 *   the sort -- each core carries its own private L1 D-cache and its own
 *   AXI master. Two such cores on one shared DDR are INCOHERENT: core 0
 *   does not see a write from core 1, and an SMP Linux (which relies
 *   precisely on that coherence) does not run reliably on it, but by
 *   chance.
 *
 *   `axi_riscv_atomics_wrap` in the existing xbar does NOT solve this: it
 *   makes LR/SC and AMO system-wide correct, i.e. the synchronization
 *   PRIMITIVE -- but not the visibility of ordinary cacheable writes.
 *
 *   This module therefore deliberately does NOT wire up a shared memory
 *   tree: it would be a memory tree that silently answers the coherence
 *   question wrong. The question belongs before the full build, not after.
 *
 *   =======================================================================
 *
 *   FUNNEL (taken over from rocket2_soc_synth_wrap): there are TWO versions
 *   of ct_L1_funnel.sv, and the wrong one merges silently broken. This
 *   binds the delta version with MDO_WIDTH = 6 (four byte chunks per
 *   32-bit beat = this encoder's real wire format), not the upstream
 *   version with LOGICAL_CHUNK_W = 32.
 *
 *   SOURCE SEPARATION: the decoder separates the two streams again via the
 *   Nexus SRC field that each encoder instance carries per CSR
 *   (trTeControl.InhibitSrc = 0 + trTeInstFeatures.SrcID/SrcBits) -- pure
 *   software, no RTL difference between the instances. Same as rocket2.
 *
 *   Width/context clamps are bit-for-bit those of the single-core twin
 *   (cva6_soc64_synth_wrap): they derive the width from tip_pkg, not from
 *   a number in the code.
 */

module cva6_2_soc_synth_wrap #(
	parameter logic [63:0] BOOT_ADDR = 64'h6400_0000,
	// Per-instance backend choice of the encoder (default = build profile).
	bit EN_ETRACE = ct_pkg::CT_EN_ETRACE
) (
	input  uwire logic        clk,
	input  uwire logic        rst,
	input  uwire logic        core_rst_hold,
	// AMP: EACH core gets its own timer interrupt line. A shared time_irq
	// would be the silent bug here -- both guests have their own mtimecmp
	// (cva6_2_periph delta 1), and a shared line would deliver one guest's
	// tick to the other. The TIME BASE (mtime) stays shared, only the
	// comparison is per hart.
	input  uwire logic        time_irq0,
	input  uwire logic        time_irq1,
	input  uwire logic        sw_irq0,
	input  uwire logic        sw_irq1,

	// MERGED ATB (funnel output)
	output logic [31:0]       atb_atdata,
	output logic [1:0]        atb_atbytes,
	output logic [6:0]        atb_atid,
	output logic              atb_atvalid,
	input  uwire logic        atb_atready,
	output logic              atb_afready,
	output logic              atb_te_raw,
	input  uwire logic        atb_afvalid,
	input  uwire logic        atb_syncreq,

	// Funnel control (higher number = preferred, equal = round-robin)
	input  uwire logic [1:0]  funnel_prio0,
	input  uwire logic [1:0]  funnel_prio1,
	input  uwire logic        funnel_flush_req,
	output logic              funnel_flush_done,

	// Encoder CSRs: TWO windows (one per instance)
	input  uwire logic        cfg0_wb_en,
	input  uwire logic        cfg0_wb_cyc,
	input  uwire logic        cfg0_wb_stb,
	input  uwire logic        cfg0_wb_we,
	input  uwire logic [31:0] cfg0_wb_addr,
	input  uwire logic [31:0] cfg0_wb_data_m2s,
	input  uwire logic [3:0]  cfg0_wb_sel,
	output logic [31:0]       cfg0_wb_data_s2m,
	output logic              cfg0_wb_ack,
	output logic              cfg0_wb_err,

	input  uwire logic        cfg1_wb_en,
	input  uwire logic        cfg1_wb_cyc,
	input  uwire logic        cfg1_wb_stb,
	input  uwire logic        cfg1_wb_we,
	input  uwire logic [31:0] cfg1_wb_addr,
	input  uwire logic [31:0] cfg1_wb_data_m2s,
	input  uwire logic [3:0]  cfg1_wb_sel,
	output logic [31:0]       cfg1_wb_data_s2m,
	output logic              cfg1_wb_ack,
	output logic              cfg1_wb_err,

	// Core 0: AXI4 master 64 bit
	output logic [3:0]        mem0_axi_awid,
	output logic [63:0]       mem0_axi_awaddr,
	output logic [7:0]        mem0_axi_awlen,
	output logic [2:0]        mem0_axi_awsize,
	output logic [1:0]        mem0_axi_awburst,
	output logic              mem0_axi_awlock,
	output logic [3:0]        mem0_axi_awcache,
	output logic [2:0]        mem0_axi_awprot,
	output logic [5:0]        mem0_axi_awatop,
	output logic              mem0_axi_awvalid,
	input  uwire logic        mem0_axi_awready,
	output logic [63:0]       mem0_axi_wdata,
	output logic [7:0]        mem0_axi_wstrb,
	output logic              mem0_axi_wlast,
	output logic              mem0_axi_wvalid,
	input  uwire logic        mem0_axi_wready,
	input  uwire logic [3:0]  mem0_axi_bid,
	input  uwire logic [1:0]  mem0_axi_bresp,
	input  uwire logic        mem0_axi_bvalid,
	output logic              mem0_axi_bready,
	output logic [3:0]        mem0_axi_arid,
	output logic [63:0]       mem0_axi_araddr,
	output logic [7:0]        mem0_axi_arlen,
	output logic [2:0]        mem0_axi_arsize,
	output logic [1:0]        mem0_axi_arburst,
	output logic              mem0_axi_arlock,
	output logic [3:0]        mem0_axi_arcache,
	output logic [2:0]        mem0_axi_arprot,
	output logic              mem0_axi_arvalid,
	input  uwire logic        mem0_axi_arready,
	input  uwire logic [3:0]  mem0_axi_rid,
	input  uwire logic [63:0] mem0_axi_rdata,
	input  uwire logic [1:0]  mem0_axi_rresp,
	input  uwire logic        mem0_axi_rlast,
	input  uwire logic        mem0_axi_rvalid,
	output logic              mem0_axi_rready,

	// Core 1: AXI4 master 64 bit
	output logic [3:0]        mem1_axi_awid,
	output logic [63:0]       mem1_axi_awaddr,
	output logic [7:0]        mem1_axi_awlen,
	output logic [2:0]        mem1_axi_awsize,
	output logic [1:0]        mem1_axi_awburst,
	output logic              mem1_axi_awlock,
	output logic [3:0]        mem1_axi_awcache,
	output logic [2:0]        mem1_axi_awprot,
	output logic [5:0]        mem1_axi_awatop,
	output logic              mem1_axi_awvalid,
	input  uwire logic        mem1_axi_awready,
	output logic [63:0]       mem1_axi_wdata,
	output logic [7:0]        mem1_axi_wstrb,
	output logic              mem1_axi_wlast,
	output logic              mem1_axi_wvalid,
	input  uwire logic        mem1_axi_wready,
	input  uwire logic [3:0]  mem1_axi_bid,
	input  uwire logic [1:0]  mem1_axi_bresp,
	input  uwire logic        mem1_axi_bvalid,
	output logic              mem1_axi_bready,
	output logic [3:0]        mem1_axi_arid,
	output logic [63:0]       mem1_axi_araddr,
	output logic [7:0]        mem1_axi_arlen,
	output logic [2:0]        mem1_axi_arsize,
	output logic [1:0]        mem1_axi_arburst,
	output logic              mem1_axi_arlock,
	output logic [3:0]        mem1_axi_arcache,
	output logic [2:0]        mem1_axi_arprot,
	output logic              mem1_axi_arvalid,
	input  uwire logic        mem1_axi_arready,
	input  uwire logic [3:0]  mem1_axi_rid,
	input  uwire logic [63:0] mem1_axi_rdata,
	input  uwire logic [1:0]  mem1_axi_rresp,
	input  uwire logic        mem1_axi_rlast,
	input  uwire logic        mem1_axi_rvalid,
	output logic              mem1_axi_rready,

	// Golden reference per core (pruned away on the board)
	output logic [63:0]       core0_trace_pc,
	output logic [1:0]        core0_trace_priv,
	output logic              core0_trace_valid,
	output logic [63:0]       core1_trace_pc,
	output logic [1:0]        core1_trace_priv,
	output logic              core1_trace_valid
);

	// verilog_lint: waive parameter-name-style -- CVA6 names this parameter
	// itself: `Cfg` is the identifier the vendored core's own modules and
	// config package use. ALL_CAPS here would diverge from upstream for a
	// style rule, and the delta would have to be carried in CVA6_PIN.md.
	localparam config_pkg::cva6_cfg_t Cfg =
		build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

	uwire logic core_rst_n = ~(rst | core_rst_hold);
	uwire logic rst_n      = ~rst;

	// Width/context clamps: identical to the single-core twin.
	localparam int unsigned TIP_AW = tip_pkg::TIP_IADDRESS_WIDTH;
	localparam int unsigned CTX_W =
		(tip_pkg::TIP_CONTEXT_WIDTH == Cfg.ASIDW) ? Cfg.ASIDW : 0;
	localparam int unsigned CTX_PORT_W = (CTX_W > 0) ? CTX_W : 1;

	// ------------------------------------------------------------------
	// Core 0
	// ------------------------------------------------------------------
	logic                 iti0_valid;
	logic [31:0]          iti0_iretire;
	logic                 iti0_ilastsize;
	logic [2:0]           iti0_itype;
	logic [4:0]           iti0_cause;
	logic [Cfg.XLEN-1:0]  iti0_tval;
	logic [1:0]           iti0_priv;
	logic [Cfg.XLEN-1:0]  iti0_iaddr;
	logic [63:0]          iti0_cycles;
	logic [Cfg.ASIDW-1:0] core0_satp_asid;

	cva6_trace_wrap core0 (
		.clk_i(clk), .rst_ni(core_rst_n),
		.boot_addr_i(Cfg.VLEN'(BOOT_ADDR)),
		.hart_id_i(Cfg.XLEN'(64'd0)),
		.irq_i(2'b00), .ipi_i(sw_irq0),
		.time_irq_i(time_irq0), .debug_req_i(1'b0),
		.m_axi_awid(mem0_axi_awid), .m_axi_awaddr(mem0_axi_awaddr), .m_axi_awlen(mem0_axi_awlen),
		.m_axi_awsize(mem0_axi_awsize), .m_axi_awburst(mem0_axi_awburst), .m_axi_awlock(mem0_axi_awlock),
		.m_axi_awcache(mem0_axi_awcache), .m_axi_awprot(mem0_axi_awprot), .m_axi_awatop(mem0_axi_awatop),
		.m_axi_awvalid(mem0_axi_awvalid), .m_axi_awready(mem0_axi_awready),
		.m_axi_wdata(mem0_axi_wdata), .m_axi_wstrb(mem0_axi_wstrb), .m_axi_wlast(mem0_axi_wlast),
		.m_axi_wvalid(mem0_axi_wvalid), .m_axi_wready(mem0_axi_wready),
		.m_axi_bid(mem0_axi_bid), .m_axi_bresp(mem0_axi_bresp), .m_axi_bvalid(mem0_axi_bvalid),
		.m_axi_bready(mem0_axi_bready),
		.m_axi_arid(mem0_axi_arid), .m_axi_araddr(mem0_axi_araddr), .m_axi_arlen(mem0_axi_arlen),
		.m_axi_arsize(mem0_axi_arsize), .m_axi_arburst(mem0_axi_arburst), .m_axi_arlock(mem0_axi_arlock),
		.m_axi_arcache(mem0_axi_arcache), .m_axi_arprot(mem0_axi_arprot),
		.m_axi_arvalid(mem0_axi_arvalid), .m_axi_arready(mem0_axi_arready),
		.m_axi_rid(mem0_axi_rid), .m_axi_rdata(mem0_axi_rdata), .m_axi_rresp(mem0_axi_rresp),
		.m_axi_rlast(mem0_axi_rlast), .m_axi_rvalid(mem0_axi_rvalid), .m_axi_rready(mem0_axi_rready),
		.rvfi_valid_o(), .rvfi_pc_o(), .rvfi_pc_wdata_o(), .rvfi_insn_o(),
		.rvfi_trap_o(), .rvfi_cause_o(), .rvfi_intr_o(),
		.iti_valid_o(iti0_valid), .iti_iretire_o(iti0_iretire), .iti_ilastsize_o(iti0_ilastsize),
		.iti_itype_o(iti0_itype), .iti_cause_o(iti0_cause), .iti_tval_o(iti0_tval),
		.iti_priv_o(iti0_priv), .iti_iaddr_o(iti0_iaddr), .iti_cycles_o(iti0_cycles),
		.satp_asid_o(core0_satp_asid)
	);

	uwire logic [CTX_PORT_W-1:0] shim0_ctx =
		(CTX_W > 0) ? core0_satp_asid[CTX_PORT_W-1:0] : '0;
	uwire logic [63:0] iaddr0_64 = 64'(iti0_iaddr);
	uwire logic [63:0] tval0_64  = 64'(iti0_tval);

	tip_if tip0 ();

	cva6_iti_to_ctte_tip #(.ITI_XLEN(TIP_AW), .ITI_CONTEXT_WIDTH(CTX_W)) shim0 (
		.clk_i(clk), .rst_ni(rst_n),
		.iti_valid_i(iti0_valid), .iti_iretire_i(iti0_iretire),
		.iti_ilastsize_i(iti0_ilastsize), .iti_itype_i(iti0_itype),
		.iti_cause_i(iti0_cause), .iti_tval_i(tval0_64[TIP_AW-1:0]), .iti_priv_i(iti0_priv),
		.iti_iaddr_i(iaddr0_64[TIP_AW-1:0]), .iti_cycles_i(iti0_cycles),
		.iti_context_i(shim0_ctx),
		.tip(tip0.master)
	);

	// ------------------------------------------------------------------
	// Core 1
	// ------------------------------------------------------------------
	logic                 iti1_valid;
	logic [31:0]          iti1_iretire;
	logic                 iti1_ilastsize;
	logic [2:0]           iti1_itype;
	logic [4:0]           iti1_cause;
	logic [Cfg.XLEN-1:0]  iti1_tval;
	logic [1:0]           iti1_priv;
	logic [Cfg.XLEN-1:0]  iti1_iaddr;
	logic [63:0]          iti1_cycles;
	logic [Cfg.ASIDW-1:0] core1_satp_asid;

	cva6_trace_wrap core1 (
		.clk_i(clk), .rst_ni(core_rst_n),
		.boot_addr_i(Cfg.VLEN'(BOOT_ADDR)),
		.hart_id_i(Cfg.XLEN'(64'd1)),
		.irq_i(2'b00), .ipi_i(sw_irq1),
		.time_irq_i(time_irq1), .debug_req_i(1'b0),
		.m_axi_awid(mem1_axi_awid), .m_axi_awaddr(mem1_axi_awaddr), .m_axi_awlen(mem1_axi_awlen),
		.m_axi_awsize(mem1_axi_awsize), .m_axi_awburst(mem1_axi_awburst), .m_axi_awlock(mem1_axi_awlock),
		.m_axi_awcache(mem1_axi_awcache), .m_axi_awprot(mem1_axi_awprot), .m_axi_awatop(mem1_axi_awatop),
		.m_axi_awvalid(mem1_axi_awvalid), .m_axi_awready(mem1_axi_awready),
		.m_axi_wdata(mem1_axi_wdata), .m_axi_wstrb(mem1_axi_wstrb), .m_axi_wlast(mem1_axi_wlast),
		.m_axi_wvalid(mem1_axi_wvalid), .m_axi_wready(mem1_axi_wready),
		.m_axi_bid(mem1_axi_bid), .m_axi_bresp(mem1_axi_bresp), .m_axi_bvalid(mem1_axi_bvalid),
		.m_axi_bready(mem1_axi_bready),
		.m_axi_arid(mem1_axi_arid), .m_axi_araddr(mem1_axi_araddr), .m_axi_arlen(mem1_axi_arlen),
		.m_axi_arsize(mem1_axi_arsize), .m_axi_arburst(mem1_axi_arburst), .m_axi_arlock(mem1_axi_arlock),
		.m_axi_arcache(mem1_axi_arcache), .m_axi_arprot(mem1_axi_arprot),
		.m_axi_arvalid(mem1_axi_arvalid), .m_axi_arready(mem1_axi_arready),
		.m_axi_rid(mem1_axi_rid), .m_axi_rdata(mem1_axi_rdata), .m_axi_rresp(mem1_axi_rresp),
		.m_axi_rlast(mem1_axi_rlast), .m_axi_rvalid(mem1_axi_rvalid), .m_axi_rready(mem1_axi_rready),
		.rvfi_valid_o(), .rvfi_pc_o(), .rvfi_pc_wdata_o(), .rvfi_insn_o(),
		.rvfi_trap_o(), .rvfi_cause_o(), .rvfi_intr_o(),
		.iti_valid_o(iti1_valid), .iti_iretire_o(iti1_iretire), .iti_ilastsize_o(iti1_ilastsize),
		.iti_itype_o(iti1_itype), .iti_cause_o(iti1_cause), .iti_tval_o(iti1_tval),
		.iti_priv_o(iti1_priv), .iti_iaddr_o(iti1_iaddr), .iti_cycles_o(iti1_cycles),
		.satp_asid_o(core1_satp_asid)
	);

	uwire logic [CTX_PORT_W-1:0] shim1_ctx =
		(CTX_W > 0) ? core1_satp_asid[CTX_PORT_W-1:0] : '0;
	uwire logic [63:0] iaddr1_64 = 64'(iti1_iaddr);
	uwire logic [63:0] tval1_64  = 64'(iti1_tval);

	tip_if tip1 ();

	cva6_iti_to_ctte_tip #(.ITI_XLEN(TIP_AW), .ITI_CONTEXT_WIDTH(CTX_W)) shim1 (
		.clk_i(clk), .rst_ni(rst_n),
		.iti_valid_i(iti1_valid), .iti_iretire_i(iti1_iretire),
		.iti_ilastsize_i(iti1_ilastsize), .iti_itype_i(iti1_itype),
		.iti_cause_i(iti1_cause), .iti_tval_i(tval1_64[TIP_AW-1:0]), .iti_priv_i(iti1_priv),
		.iti_iaddr_i(iaddr1_64[TIP_AW-1:0]), .iti_cycles_i(iti1_cycles),
		.iti_context_i(shim1_ctx),
		.tip(tip1.master)
	);

	// ------------------------------------------------------------------
	// Encoder CSR windows
	// ------------------------------------------------------------------
	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb0 ();
	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb1 ();
	axis_if #(.TDATA_WIDTH(96), .TID_WIDTH(8)) axis0 (.aclk(clk), .aresetn(rst_n));
	axis_if #(.TDATA_WIDTH(96), .TID_WIDTH(8)) axis1 (.aclk(clk), .aresetn(rst_n));
	atb_if atb0 ();
	atb_if atb1 ();

	assign wb0.cyc          = cfg0_wb_en & cfg0_wb_cyc;
	assign wb0.stb          = cfg0_wb_en & cfg0_wb_stb;
	assign wb0.we           = cfg0_wb_we;
	assign wb0.addr         = cfg0_wb_addr;
	assign wb0.data_m2s     = cfg0_wb_data_m2s;
	assign wb0.sel          = cfg0_wb_sel;
	assign cfg0_wb_data_s2m = wb0.data_s2m;
	assign cfg0_wb_ack      = wb0.ack;
	assign cfg0_wb_err      = wb0.err;

	assign wb1.cyc          = cfg1_wb_en & cfg1_wb_cyc;
	assign wb1.stb          = cfg1_wb_en & cfg1_wb_stb;
	assign wb1.we           = cfg1_wb_we;
	assign wb1.addr         = cfg1_wb_addr;
	assign wb1.data_m2s     = cfg1_wb_data_m2s;
	assign wb1.sel          = cfg1_wb_sel;
	assign cfg1_wb_data_s2m = wb1.data_s2m;
	assign cfg1_wb_ack      = wb1.ack;
	assign cfg1_wb_err      = wb1.err;

	uwire logic enc0_te_raw, enc1_te_raw;

	// CORE_XLEN: width of the hart on this encoder (elaboration guard of
	// the synced encoder). Like the single-core twin, NO number sits in
	// the code: the core configuration comes via the file list (cv64a6 =>
	// 64, the RV32 comparison run cv32a6_ima_sv32_fpga => 32), and exactly
	// this width is the statement the guard requires. A hard 64 would be
	// simply wrong in the RV32 comparison.
	ct_encoder #(.SPLIT_DATA_ACCESS(0), .EN_ETRACE(EN_ETRACE), .EN_NTRACE(!EN_ETRACE),
	             .CORE_XLEN(Cfg.XLEN)) enc0 (
		.tip_clk(clk), .tip_rst(rst), .tip(tip0.slave),
		.wb_clk(clk),  .wb_rst(rst),  .wb(wb0),
		.ct_cs_rst(rst),
		.axis(axis0),
		.atb_atclk(clk), .atb_atresetn(rst_n), .atb(atb0), .atb_te_raw(enc0_te_raw),
		.proc_clk(clk), .proc_rst(rst), .wall_clk(clk), .wall_clk_rst(rst)
	);

	ct_encoder #(.SPLIT_DATA_ACCESS(0), .EN_ETRACE(EN_ETRACE), .EN_NTRACE(!EN_ETRACE),
	             .CORE_XLEN(Cfg.XLEN)) enc1 (
		.tip_clk(clk), .tip_rst(rst), .tip(tip1.slave),
		.wb_clk(clk),  .wb_rst(rst),  .wb(wb1),
		.ct_cs_rst(rst),
		.axis(axis1),
		.atb_atclk(clk), .atb_atresetn(rst_n), .atb(atb1), .atb_te_raw(enc1_te_raw),
		.proc_clk(clk), .proc_rst(rst), .wall_clk(clk), .wall_clk_rst(rst)
	);

	assign axis0.tready = 1'b1;
	assign axis1.tready = 1'b1;

	// ------------------------------------------------------------------
	// Funnel: 2x ATB -> 1x ATB (message-atomic, MSEO-based)
	// ------------------------------------------------------------------
	// Same elaboration clamp as rocket2: the funnel recognizes packet
	// boundaries EXCLUSIVELY via the Nexus MSEO bits. An E-Trace backend
	// delivers raw bytes without MSEO -- the funnel would switch channel
	// mid-packet and make BOTH streams unusable, without anything turning
	// red. Hence abort here instead of silently merging wrong.
	if (EN_ETRACE) begin : g_etrace_guard
		initial $fatal(1, "cva6_2_soc_synth_wrap: EN_ETRACE=1 is incompatible with ct_L1_funnel (the funnel parses MSEO; E-Trace delivers raw bytes)");
	end

	atb_if atb_in [2] ();
	atb_if atb_mrg ();

	assign atb_in[0].atdata  = atb0.atdata;
	assign atb_in[0].atbytes = atb0.atbytes;
	assign atb_in[0].atid    = atb0.atid;
	assign atb_in[0].atvalid = atb0.atvalid;
	assign atb_in[0].afready = atb0.afready;
	assign atb0.atready = atb_in[0].atready;
	assign atb0.afvalid = atb_in[0].afvalid;
	assign atb0.syncreq = atb_in[0].syncreq;

	assign atb_in[1].atdata  = atb1.atdata;
	assign atb_in[1].atbytes = atb1.atbytes;
	assign atb_in[1].atid    = atb1.atid;
	assign atb_in[1].atvalid = atb1.atvalid;
	assign atb_in[1].afready = atb1.afready;
	assign atb1.atready = atb_in[1].atready;
	assign atb1.afvalid = atb_in[1].afvalid;
	assign atb1.syncreq = atb_in[1].syncreq;

	uwire logic [1:0] funnel_prio [2];
	assign funnel_prio[0] = funnel_prio0;
	assign funnel_prio[1] = funnel_prio1;
	uwire logic funnel_participate [2];
	assign funnel_participate[0] = 1'b1;
	assign funnel_participate[1] = 1'b1;
	uwire logic funnel_chan_flush_req [2];
	assign funnel_chan_flush_req[0] = 1'b0;
	assign funnel_chan_flush_req[1] = 1'b0;
	uwire logic funnel_chan_flush_done [2];
	uwire logic funnel_chan_te_raw [2];
	assign funnel_chan_te_raw[0] = 1'b0;
	assign funnel_chan_te_raw[1] = 1'b0;

	ct_L1_funnel #(
		.N_STREAMS  (2),
		.MAX_PRIO   (3),
		.MSEO_WIDTH (2),
		// 6 = four byte chunks per 32-bit beat = this encoder's real wire
		// format (NEXUS_MDO_WIDTH, see header). NOT the default 30.
		.MDO_WIDTH  (6),
		.EN_TE_RAW  (0)
	) funnel (
		.atclk    (clk),
		.atresetn (rst_n),
		.chan_prio              (funnel_prio),
		.chan_flush_participate (funnel_participate),
		.chan_flush_req         (funnel_chan_flush_req),
		.chan_te_raw            (funnel_chan_te_raw),
		.te_tag_always          (1'b0),
		.te_tag_resync          (1'b0),
		.global_flush_req       (funnel_flush_req),
		.chan_flush_done        (funnel_chan_flush_done),
		.global_flush_done      (funnel_flush_done),
		.atb_in  (atb_in),
		.atb_out (atb_mrg)
	);

	assign atb_atdata   = atb_mrg.atdata;
	assign atb_atbytes  = atb_mrg.atbytes;
	assign atb_atid     = atb_mrg.atid;
	assign atb_atvalid  = atb_mrg.atvalid;
	assign atb_mrg.atready = atb_atready;
	assign atb_afready  = atb_mrg.afready;
	assign atb_mrg.afvalid = atb_afvalid;
	assign atb_mrg.syncreq = atb_syncreq;

	// Both instances carry the same profile, hence the same framing.
	assign atb_te_raw = enc0_te_raw;

`ifndef SYNTHESIS
	a_same_framing: assert property (@(posedge clk) disable iff (!rst_n)
		enc0_te_raw == enc1_te_raw)
		else $error("cva6_2_soc_synth_wrap: encoders report different ATB framing (%0b vs %0b)", enc0_te_raw, enc1_te_raw);

	initial begin
		if (CTX_W > 0)
			$display("[cva6_2_soc] context ACTIVE: ITI_CONTEXT_WIDTH = %0d (satp.ASID)", CTX_W);
		else
			$display("[cva6_2_soc] context OFF: TIP_CONTEXT_WIDTH = %0d != Cfg.ASIDW = %0d",
			         tip_pkg::TIP_CONTEXT_WIDTH, Cfg.ASIDW);
		if (TIP_AW != 64)
			$display("[cva6_2_soc] NOTE: TIP_IADDRESS_WIDTH = %0d (< 64) -- iaddr is truncated", TIP_AW);
	end
`endif

	// Golden reference: the FULL 64-bit PC directly from the ITI.
	assign core0_trace_pc    = 64'(iti0_iaddr);
	assign core0_trace_priv  = iti0_priv;
	assign core0_trace_valid = iti0_valid;
	assign core1_trace_pc    = 64'(iti1_iaddr);
	assign core1_trace_priv  = iti1_priv;
	assign core1_trace_valid = iti1_valid;

endmodule

`default_nettype wire
