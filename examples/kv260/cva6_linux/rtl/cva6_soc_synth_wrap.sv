// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    cva6_soc_synth_wrap -- the single-core cv32a60x-family CVA6
 *           branch: core + RVFI + ITI + shim + ct_encoder.
 *
 * @details
 *     CVA6 (config from the file list, e.g. cv32a6_ima_sv32_fpga for Linux)
 *       |- AXI4 master (64 bit) -> mem_axi_* (board: PS S_AXI_HP -> DDR4
 *       |  window 0x6400_0000; sim: axi_ram_sim)
 *       `- cva6_rvfi -> cva6_iti -> cva6_iti_to_ctte_tip -> tip_if
 *            `- ct_encoder -> ATB outward, CSR via Wishbone
 *
 *   Port contract analogous to mbv_soc_synth_wrap/ct_soc_synth_wrap
 *   (ATB/cfg_wb/core_trace), but WITHOUT a RAM-loader window: the CVA6
 *   fetches code/data itself from the DDR window (ELF load via devmem from
 *   the PS). Single clock like its sibling wrappers (all encoder domains
 *   on clk).
 */

module cva6_soc_synth_wrap #(
	parameter logic [31:0] BOOT_ADDR = 32'h6400_0000,
	// mhartid of the core. Default 2 originates from a trio (three-core)
	// bring-up, where the CVA6 was the third core and simultaneously trace
	// source 2. A SINGLE-CORE SoC must set this to 0 here: OpenSBI and
	// Linux index their hart tables via hart_index2id, and a hart ID
	// outside [0, hart_count) first leads to _start_hang (wfi, no console
	// output) and -- even with a matching devicetree -- afterwards to
	// "sbi_hsm_hart_start_finish: ERR: The hart is in invalid state". Both
	// diagnosed on the board (2026-07-27, via CTTE capture).
	parameter logic [31:0] HART_ID = 32'd2,
	// Per-instance backend choice of the encoder (default = build profile):
	// 1 = also build in the E-Trace backend (DUAL, if N-Trace is on too).
	bit EN_ETRACE = ct_pkg::CT_EN_ETRACE
) (
	input  uwire logic        clk,
	input  uwire logic        rst,
	input  uwire logic        core_rst_hold,   // CONTROL b5 (inverted): only start after the DDR load
	input  uwire logic        time_irq,

	// ATB (to the funnel)
	output logic [31:0]       atb_atdata,
	output logic [1:0]        atb_atbytes,
	output logic [6:0]        atb_atid,
	output logic              atb_atvalid,
	input  uwire logic        atb_atready,
	output logic              atb_afready,
	// ATB framing of this encoder (0 = Nexus MSEO, 1 = E-Trace raw bytes)
	output logic              atb_te_raw,
	input  uwire logic        atb_afvalid,
	input  uwire logic        atb_syncreq,

	// Encoder CSRs (Wishbone, via the ct_axil_to_wb bridge in the top)
	input  uwire logic        cfg_wb_en,
	input  uwire logic        cfg_wb_cyc,
	input  uwire logic        cfg_wb_stb,
	input  uwire logic        cfg_wb_we,
	input  uwire logic [31:0] cfg_wb_addr,
	input  uwire logic [31:0] cfg_wb_data_m2s,
	input  uwire logic [3:0]  cfg_wb_sel,
	output logic [31:0]       cfg_wb_data_s2m,
	output logic              cfg_wb_ack,
	output logic              cfg_wb_err,

	// CVA6 memory path: AXI4 master 64 bit (board: PS S_AXI_HP; sim: RAM model)
	output logic [3:0]        mem_axi_awid,
	output logic [63:0]       mem_axi_awaddr,
	output logic [7:0]        mem_axi_awlen,
	output logic [2:0]        mem_axi_awsize,
	output logic [1:0]        mem_axi_awburst,
	output logic              mem_axi_awlock,
	output logic [3:0]        mem_axi_awcache,
	output logic [2:0]        mem_axi_awprot,
	output logic [5:0]        mem_axi_awatop,
	output logic              mem_axi_awvalid,
	input  uwire logic        mem_axi_awready,
	output logic [63:0]       mem_axi_wdata,
	output logic [7:0]        mem_axi_wstrb,
	output logic              mem_axi_wlast,
	output logic              mem_axi_wvalid,
	input  uwire logic        mem_axi_wready,
	input  uwire logic [3:0]  mem_axi_bid,
	input  uwire logic [1:0]  mem_axi_bresp,
	input  uwire logic        mem_axi_bvalid,
	output logic              mem_axi_bready,
	output logic [3:0]        mem_axi_arid,
	output logic [63:0]       mem_axi_araddr,
	output logic [7:0]        mem_axi_arlen,
	output logic [2:0]        mem_axi_arsize,
	output logic [1:0]        mem_axi_arburst,
	output logic              mem_axi_arlock,
	output logic [3:0]        mem_axi_arcache,
	output logic [2:0]        mem_axi_arprot,
	output logic              mem_axi_arvalid,
	input  uwire logic        mem_axi_arready,
	input  uwire logic [3:0]  mem_axi_rid,
	input  uwire logic [63:0] mem_axi_rdata,
	input  uwire logic [1:0]  mem_axi_rresp,
	input  uwire logic        mem_axi_rlast,
	input  uwire logic        mem_axi_rvalid,
	output logic              mem_axi_rready,

	// Golden reference (tip side, iretire rule; pruned away on the board)
	output logic [31:0]       core_trace_pc,
	output logic              core_trace_valid
);

	uwire logic core_rst_n = ~(rst | core_rst_hold);

	logic        iti_valid;
	logic [31:0] iti_iretire;
	logic        iti_ilastsize;
	logic [2:0]  iti_itype;
	logic [4:0]  iti_cause;
	logic [31:0] iti_tval;
	logic [1:0]  iti_priv;
	logic [31:0] iti_iaddr;
	logic [63:0] iti_cycles;

	cva6_trace_wrap core (
		.clk_i(clk), .rst_ni(core_rst_n),
		.boot_addr_i(BOOT_ADDR),
		.hart_id_i(HART_ID),
		.irq_i(2'b00), .ipi_i(1'b0),
		.time_irq_i(time_irq), .debug_req_i(1'b0),
		.m_axi_awid(mem_axi_awid), .m_axi_awaddr(mem_axi_awaddr), .m_axi_awlen(mem_axi_awlen),
		.m_axi_awsize(mem_axi_awsize), .m_axi_awburst(mem_axi_awburst), .m_axi_awlock(mem_axi_awlock),
		.m_axi_awcache(mem_axi_awcache), .m_axi_awprot(mem_axi_awprot), .m_axi_awatop(mem_axi_awatop),
		.m_axi_awvalid(mem_axi_awvalid), .m_axi_awready(mem_axi_awready),
		.m_axi_wdata(mem_axi_wdata), .m_axi_wstrb(mem_axi_wstrb), .m_axi_wlast(mem_axi_wlast),
		.m_axi_wvalid(mem_axi_wvalid), .m_axi_wready(mem_axi_wready),
		.m_axi_bid(mem_axi_bid), .m_axi_bresp(mem_axi_bresp), .m_axi_bvalid(mem_axi_bvalid),
		.m_axi_bready(mem_axi_bready),
		.m_axi_arid(mem_axi_arid), .m_axi_araddr(mem_axi_araddr), .m_axi_arlen(mem_axi_arlen),
		.m_axi_arsize(mem_axi_arsize), .m_axi_arburst(mem_axi_arburst), .m_axi_arlock(mem_axi_arlock),
		.m_axi_arcache(mem_axi_arcache), .m_axi_arprot(mem_axi_arprot),
		.m_axi_arvalid(mem_axi_arvalid), .m_axi_arready(mem_axi_arready),
		.m_axi_rid(mem_axi_rid), .m_axi_rdata(mem_axi_rdata), .m_axi_rresp(mem_axi_rresp),
		.m_axi_rlast(mem_axi_rlast), .m_axi_rvalid(mem_axi_rvalid), .m_axi_rready(mem_axi_rready),
		.rvfi_valid_o(), .rvfi_pc_o(), .rvfi_pc_wdata_o(), .rvfi_insn_o(),
		.rvfi_trap_o(), .rvfi_cause_o(), .rvfi_intr_o(),
		.iti_valid_o(iti_valid), .iti_iretire_o(iti_iretire), .iti_ilastsize_o(iti_ilastsize),
		.iti_itype_o(iti_itype), .iti_cause_o(iti_cause), .iti_tval_o(iti_tval),
		.iti_priv_o(iti_priv), .iti_iaddr_o(iti_iaddr), .iti_cycles_o(iti_cycles)
	);

	tip_if tip ();

	// ITI_XLEN = width of the CORE side (cv32a60x-family: iti_iaddr is
	// [31:0]), not the encoder's. Spelled out explicitly: with the earlier
	// default TIP_IADDRESS_WIDTH this branch would have silently gotten
	// 64-bit ports against a CT_XLEN=64 netlist and zero-extended the
	// 32-bit core's signal into it -- the elaboration contract in the shim
	// could not see that by construction.
	cva6_iti_to_ctte_tip #(.ITI_XLEN(32)) shim (
		.clk_i(clk), .rst_ni(~rst),
		.iti_valid_i(iti_valid), .iti_iretire_i(iti_iretire),
		.iti_ilastsize_i(iti_ilastsize), .iti_itype_i(iti_itype),
		.iti_cause_i(iti_cause), .iti_tval_i(iti_tval), .iti_priv_i(iti_priv),
		.iti_iaddr_i(iti_iaddr), .iti_cycles_i(iti_cycles),
		.tip(tip.master)
	);

	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb ();
	axis_if #(.TDATA_WIDTH(96), .TID_WIDTH(8)) axis (.aclk(clk), .aresetn(~rst));
	atb_if  atb ();

	assign wb.cyc        = cfg_wb_en & cfg_wb_cyc;
	assign wb.stb        = cfg_wb_en & cfg_wb_stb;
	assign wb.we         = cfg_wb_we;
	assign wb.addr       = cfg_wb_addr;
	assign wb.data_m2s   = cfg_wb_data_m2s;
	assign wb.sel        = cfg_wb_sel;
	assign cfg_wb_data_s2m = wb.data_s2m;
	assign cfg_wb_ack      = wb.ack;
	assign cfg_wb_err      = wb.err;

	// CORE_XLEN(32): cv32a60x-family is an RV32 hart; the synced encoder
	// (elaboration guard) requires the explicit value here.
	// EN_NTRACE as the complement: dual builds are retired, the elaboration
	// guard in ct_encoder demands EXACTLY ONE backend per instance -- with
	// the package default (CT_EN_NTRACE=1) a bare .EN_ETRACE(1) would set both.
	ct_encoder #(.SPLIT_DATA_ACCESS(0), .EN_ETRACE(EN_ETRACE),
	             .EN_NTRACE(!EN_ETRACE),
	             .CORE_XLEN(32)) encoder (
		.tip_clk      (clk),
		.tip_rst      (rst),
		.tip          (tip.slave),
		.wb_clk       (clk),
		.wb_rst       (rst),
		.wb           (wb),
		.ct_cs_rst    (rst),
		.axis         (axis),
		.atb_atclk    (clk),
		.atb_atresetn (~rst),
		.atb          (atb),
		.atb_te_raw   (atb_te_raw),
		.proc_clk     (clk),
		.proc_rst     (rst),
		.wall_clk     (clk),
		.wall_clk_rst (rst)
	);

	assign axis.tready = 1'b1;   // AXIS of this encoder unused (like the single-encoder siblings)

	assign atb_atdata  = atb.atdata;
	assign atb_atbytes = atb.atbytes;
	assign atb_atid    = atb.atid;
	assign atb_atvalid = atb.atvalid;
	assign atb.atready = atb_atready;
	assign atb_afready = atb.afready;
	assign atb.afvalid = atb_afvalid;
	assign atb.syncreq = atb_syncreq;

	assign core_trace_pc    = tip.iaddr;
	assign core_trace_valid = |tip.iretire;

endmodule

`default_nettype wire
