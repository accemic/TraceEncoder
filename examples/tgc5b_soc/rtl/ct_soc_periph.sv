// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Example-SoC peripheral block: CLINT (timer + SW irq) + INTC.
 *
 * @details
 *   Thin RTL around the RDL-generated `ct_soc_regs` AXI4-Lite register block
 *   (see rdl/ct_soc.rdl, regenerate with `make rdl-soc`). It adds the behaviour
 *   the register storage alone cannot express:
 *
 *   - a free-running 64-bit `mtime` counter, exported to the core (`mtime_o`)
 *     and mirrored into the read-only `clint.mtimelo/hi` registers;
 *   - the machine timer interrupt `tim_irq_o = (mtime >= mtimecmp)`;
 *   - the machine software interrupt `sw_irq_o = clint.msip.Pending`;
 *   - the external interrupt `ext_irq_o = intc.trigger.Set & intc.enable.Enable`.
 *
 *   These are minimal teaching peripherals (see the RDL), enough to drive the
 *   core's three interrupt inputs so the trace exercises interrupt/return flow.
 *   The generated block wraps the storage; this wrapper wraps the behaviour.
 */

module ct_soc_periph (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous

	// -- AXI4-Lite slave (peripheral segment of the core dBus) -------------
	input  uwire logic        s_awvalid,
	output      logic         s_awready,
	input  uwire logic [12:0] s_awaddr,
	input  uwire logic [2:0]  s_awprot,
	input  uwire logic        s_wvalid,
	output      logic         s_wready,
	input  uwire logic [31:0] s_wdata,
	input  uwire logic [3:0]  s_wstrb,
	output      logic         s_bvalid,
	input  uwire logic        s_bready,
	output      logic [1:0]   s_bresp,
	input  uwire logic        s_arvalid,
	output      logic         s_arready,
	input  uwire logic [12:0] s_araddr,
	input  uwire logic [2:0]  s_arprot,
	output      logic         s_rvalid,
	input  uwire logic        s_rready,
	output      logic [31:0]  s_rdata,
	output      logic [1:0]   s_rresp,

	// -- Interrupt / time outputs to the core ------------------------------
	output      logic [63:0]  mtime_o,
	output      logic         tim_irq_o,
	output      logic         sw_irq_o,
	output      logic         ext_irq_o
);

	import ct_soc_regs_pkg::*;

	ct_soc_periph__in_t        hwif_in;
	uwire ct_soc_periph__out_t hwif_out;

	ct_soc_regs regs_inst (
		.clk,
		.rst,
		.s_axil_awready (s_awready),
		.s_axil_awvalid (s_awvalid),
		.s_axil_awaddr  (s_awaddr),
		.s_axil_awprot  (s_awprot),
		.s_axil_wready  (s_wready),
		.s_axil_wvalid  (s_wvalid),
		.s_axil_wdata   (s_wdata),
		.s_axil_wstrb   (s_wstrb),
		.s_axil_bready  (s_bready),
		.s_axil_bvalid  (s_bvalid),
		.s_axil_bresp   (s_bresp),
		.s_axil_arready (s_arready),
		.s_axil_arvalid (s_arvalid),
		.s_axil_araddr  (s_araddr),
		.s_axil_arprot  (s_arprot),
		.s_axil_rready  (s_rready),
		.s_axil_rvalid  (s_rvalid),
		.s_axil_rdata   (s_rdata),
		.s_axil_rresp   (s_rresp),
		.hwif_in,
		.hwif_out
	);

	// -- CLINT: free-running mtime counter ---------------------------------
	logic [63:0] mtime;

	always_ff @(posedge clk) begin
		if (rst) begin
			mtime <= '0;
		end
		else begin
			mtime <= mtime + 64'd1;
		end
	end

	assign mtime_o = mtime;

	// Mirror mtime into the read-only CLINT registers.
	always_comb begin
		hwif_in.clint.mtimelo.Value.next = mtime[31:0];
		hwif_in.clint.mtimehi.Value.next = mtime[63:32];
	end

	// -- Interrupt generation ----------------------------------------------
	uwire logic [63:0] mtimecmp = {hwif_out.clint.mtimecmphi.Value.value,
	                               hwif_out.clint.mtimecmplo.Value.value};

	assign tim_irq_o = (mtime >= mtimecmp);
	assign sw_irq_o  = hwif_out.clint.msip.Pending.value;
	assign ext_irq_o = hwif_out.intc.trigger.Set.value & hwif_out.intc.enable.Enable.value;

endmodule

`default_nettype wire
