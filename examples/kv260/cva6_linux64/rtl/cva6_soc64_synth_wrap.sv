// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    cva6_soc64_synth_wrap -- RV64 twin of cva6_soc_synth_wrap:
 *
 *     CVA6 (cv64a6_imac_sv39_ctrace, delta D6: RV64IMAC, no FPU, Sv39,
 *       |    S+U, NrCommitPorts=1)
 *       |- AXI4 master (64 bit) -> mem_axi_* (board: PS S_AXI_HP -> DDR4
 *       |  window 0x6400_0000; sim: axi_ram_sim)
 *       `- cva6_rvfi -> cva6_iti -> cva6_iti_to_ctte_tip -> tip_if
 *            `- ct_encoder -> ATB outward, CSR via Wishbone
 *
 * @details
 *   ADDITIVE: cva6_soc_synth_wrap.sv (RV32, in
 *   [`../../cva6_linux/rtl/`](../../cva6_linux/rtl/)) stays unchanged. The
 *   deltas are EXCLUSIVELY:
 *
 *   1. **Widths from CVA6Cfg instead of a fixed 32.** cva6_trace_wrap is
 *      already fully parametric over CVA6Cfg (XLEN/VLEN/Axi*), only the
 *      RV32 shell held the ITI nets fixed at [31:0]. Here they sit at
 *      CVA6Cfg.XLEN (= 64) resp. CVA6Cfg.VLEN.
 *   2. **core_trace_pc is 64 bit** (golden reference of the boot TB).
 *   3. **HART_ID/BOOT_ADDR are 64 bit.** Both feed XLEN-/VLEN-wide core
 *      ports; the RV32 shell's 32-bit form would leave the upper bits open
 *      on RV64.
 *   4. **TIP width clamp.** The encoder side hangs off
 *      tip_pkg::TIP_IADDRESS_WIDTH -- NOT a 32 in the code. As long as the
 *      encoder tree carries the 32-bit stand, the lower 32 address bits go
 *      to the existing, already-audited shim; a counter makes visible how
 *      often the upper 32 bits were nonzero (the case that occurs once the
 *      kernel runs in the virtual Sv39 address space). See `// TODO X2`
 *      below.
 *
 *   Encoder contract for the boot: the ct_encoder is OFF after reset
 *   (trTeControl.Enable = 0, RDL reset) and is only armed via the ENC
 *   aperture. It must not influence the boot; its ATB output goes into a
 *   ring that accepts at any time.
 */

module cva6_soc64_synth_wrap #(
	// 64-bit, because boot_addr_i is VLEN-wide (D6: VLEN = 64).
	parameter logic [63:0] BOOT_ADDR = 64'h6400_0000,
	// mhartid. Single-core SoC => 0. Rationale (board finding 2026-07-27) is
	// spelled out at length in cva6_soc_synth_wrap.sv: a hart ID outside
	// [0, hart_count) leads OpenSBI into _start_hang, without a single
	// console character. Both diagnosed on the board.
	parameter logic [63:0] HART_ID = 64'd0,
	// Per-instance backend choice of the encoder (default = build profile).
	bit EN_ETRACE = ct_pkg::CT_EN_ETRACE
) (
	input  uwire logic        clk,
	input  uwire logic        rst,
	input  uwire logic        core_rst_hold,   // CONTROL b0 (inverted): only start after the DDR load
	input  uwire logic        time_irq,
	input  uwire logic        sw_irq,          // CLINT msip (RV64 addition, see below)

	// ATB (to the ring/funnel)
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
	output logic [63:0]       core_trace_pc,
	output logic [1:0]        core_trace_priv,
	output logic              core_trace_valid
);

	// Core configuration: same resolution as in cva6_trace_wrap -- the
	// configuration name comes via the file list (target), not via a
	// parameter. Only mirrored here to set the net widths.
	// verilog_lint: waive parameter-name-style -- CVA6 names this parameter
	// itself: `Cfg` is the identifier the vendored core's own modules and
	// config package use. ALL_CAPS here would diverge from upstream for a
	// style rule, and the delta would have to be carried in CVA6_PIN.md.
	localparam config_pkg::cva6_cfg_t Cfg =
		build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

	uwire logic core_rst_n = ~(rst | core_rst_hold);

	logic                 iti_valid;
	logic [31:0]          iti_iretire;
	logic                 iti_ilastsize;
	logic [2:0]           iti_itype;
	logic [4:0]           iti_cause;
	logic [Cfg.XLEN-1:0]  iti_tval;
	logic [1:0]           iti_priv;
	logic [Cfg.XLEN-1:0]  iti_iaddr;
	logic [63:0]          iti_cycles;
	// Context identifier of the core (W2): satp.ASID from the RVFI CSR
	// shadow path that cva6_trace_wrap has exposed since W2. At Sv39,
	// Cfg.ASIDW = 16 (build_config_pkg.sv:179, IS_XLEN32 ? 9 : 16).
	logic [Cfg.ASIDW-1:0] core_satp_asid;

	cva6_trace_wrap core (
		.clk_i(clk), .rst_ni(core_rst_n),
		.boot_addr_i(Cfg.VLEN'(BOOT_ADDR)),
		.hart_id_i(Cfg.XLEN'(HART_ID)),
		// {[1]=m-ext, [0]=m-sw}: the CLINT supplies msip. The RV32 shell
		// tied both to 0, because only the timer IRQ was needed there;
		// OpenSBI already uses IPI in the single-core start sequence.
		.irq_i(2'b00), .ipi_i(sw_irq),
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
		.iti_priv_o(iti_priv), .iti_iaddr_o(iti_iaddr), .iti_cycles_o(iti_cycles),
		.satp_asid_o(core_satp_asid)
	);

	// ------------------------------------------------------------------
	// TIP width clamp -- address width comes from tip_pkg, not from a 32
	// in the code.
	// ------------------------------------------------------------------
	localparam int unsigned TIP_AW = tip_pkg::TIP_IADDRESS_WIDTH;

	// ------------------------------------------------------------------
	// Context clamp (W5) -- same mechanism as the address clamp above:
	// the width comes from tip_pkg, not from a number in the code.
	//
	// The context is ONLY set up if the encoder netlist is exactly as wide
	// as the core's ASID (CT_CONTEXT_WIDTH == Cfg.ASIDW). Otherwise
	// CTX_W = 0 and the shim behaves bit-for-bit as before W5 -- that is
	// the case for every encoder with the default CT_CONTEXT_WIDTH = 2
	// (among others, the pinned tree used by this repository's default
	// build). The alternative -- setting up the context anyway -- is
	// forbidden by the shim itself with a $fatal
	// (cva6_iti_to_ctte_tip.sv:131), and for good reason: a silently
	// truncated identifier names the WRONG process, and the ownership
	// filter has demonstrably then filtered on the wrong value.
	localparam int unsigned CTX_W =
		(tip_pkg::TIP_CONTEXT_WIDTH == Cfg.ASIDW) ? Cfg.ASIDW : 0;
	localparam int unsigned CTX_PORT_W = (CTX_W > 0) ? CTX_W : 1;
	uwire logic [CTX_PORT_W-1:0] shim_ctx =
		(CTX_W > 0) ? core_satp_asid[CTX_PORT_W-1:0] : '0;

	// The shim has been width-parametric (ITI_XLEN, default
	// TIP_IADDRESS_WIDTH == ct_pkg::CT_XLEN) since R2.1. This means NO case
	// distinction is needed here anymore: the core address is normalized
	// to 64 bit and exactly the encoder width is taken from that. On a
	// 32-bit netlist that is the previous 32-bit expression, on a 64-bit
	// netlist it is the full PC -- without a single number in the code.
	//
	// TODO X2: as long as the VENDORED encoder carries CT_XLEN=32, the
	// trace loses the upper address bits as soon as the kernel runs in the
	// virtual Sv39 address space. The counter below makes exactly that
	// visible; this spot is done once a 64-bit stand of the encoder is
	// vendored (then nothing needs to change here, only re-elaboration).
	uwire logic [63:0] iaddr64 = 64'(iti_iaddr);
	uwire logic [63:0] tval64  = 64'(iti_tval);
	uwire logic [TIP_AW-1:0] shim_iaddr = iaddr64[TIP_AW-1:0];
	uwire logic [TIP_AW-1:0] shim_tval  = tval64[TIP_AW-1:0];

	tip_if tip ();

	cva6_iti_to_ctte_tip #(.ITI_XLEN(TIP_AW), .ITI_CONTEXT_WIDTH(CTX_W)) shim (
		.clk_i(clk), .rst_ni(~rst),
		.iti_valid_i(iti_valid), .iti_iretire_i(iti_iretire),
		.iti_ilastsize_i(iti_ilastsize), .iti_itype_i(iti_itype),
		.iti_cause_i(iti_cause), .iti_tval_i(shim_tval), .iti_priv_i(iti_priv),
		.iti_iaddr_i(shim_iaddr), .iti_cycles_i(iti_cycles),
		.iti_context_i(shim_ctx),
		.tip(tip.master)
	);

`ifndef SYNTHESIS
	initial begin
		if (CTX_W > 0)
			$display("[cva6_soc64] context ACTIVE: ITI_CONTEXT_WIDTH = %0d (satp.ASID)", CTX_W);
		else
			$display("[cva6_soc64] context OFF: TIP_CONTEXT_WIDTH = %0d != Cfg.ASIDW = %0d",
			         tip_pkg::TIP_CONTEXT_WIDTH, Cfg.ASIDW);
	end
`endif

`ifndef SYNTHESIS
	// Visibility instead of silent truncation: counts the retire beats
	// whose upper address bits exceed the TIP width. If the counter rises,
	// X2 is mandatory for this path (occurs at the latest once the kernel
	// runs in the virtual Sv39 address space 0xFFFF_FFC0_....).
	int unsigned tip_iaddr_trunc_cnt = 0;
	always_ff @(posedge clk) begin
		if (!rst && iti_valid && (iti_iaddr[Cfg.XLEN-1:32] != '0))
			tip_iaddr_trunc_cnt <= tip_iaddr_trunc_cnt + 1;
	end
	initial begin
		if (TIP_AW != 64)
			$display("[cva6_soc64] NOTE: TIP_IADDRESS_WIDTH = %0d (< 64) -- TODO X2, iaddr is truncated", TIP_AW);
	end
`endif

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

	// CORE_XLEN: width of the hart on this encoder (elaboration guard of
	// the synced encoder). Like the address and context clamps above, NO
	// number sits in the code here -- the width comes from the same source
	// as the core nets, namely the configuration chosen via the file list
	// (cv64a6 => 64). The second guard (CORE_XLEN != ct_pkg::CT_XLEN) thus
	// makes TODO X2 loud: a 32-bit encoder tree under this core truncates
	// the address and is now rejected instead of silently accepted.
	// EN_NTRACE as the complement: dual builds are retired, the elaboration
	// guard in ct_encoder demands EXACTLY ONE backend per instance.
	ct_encoder #(.SPLIT_DATA_ACCESS(0), .EN_ETRACE(EN_ETRACE), .EN_NTRACE(!EN_ETRACE),
	             .CORE_XLEN(Cfg.XLEN)) encoder (
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

	assign axis.tready = 1'b1;   // AXIS unused (like the RV32 shell)

	assign atb_atdata  = atb.atdata;
	assign atb_atbytes = atb.atbytes;
	assign atb_atid    = atb.atid;
	assign atb_atvalid = atb.atvalid;
	assign atb.atready = atb_atready;
	assign atb_afready = atb.afready;
	assign atb.afvalid = atb_afvalid;
	assign atb.syncreq = atb_syncreq;

	// Golden reference: the FULL 64-bit PC directly from the ITI --
	// deliberately NOT tip.iaddr (that carries the possibly truncated
	// form, see TODO X2 above). The boot TB should see the real PC, even
	// while the TIP is 32 bit.
	assign core_trace_pc    = 64'(iti_iaddr);
	assign core_trace_priv  = iti_priv;
	assign core_trace_valid = iti_valid;

endmodule

`default_nettype wire
