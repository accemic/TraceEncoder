// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    1-to-2 AXI4-Lite demultiplexer on one address bit.
 *
 * @details
 *   Splits the core's external segment into the shared memory and the
 *   ACT-CAP doorbell:
 *
 *       addr[SEL_BIT] = 0  ->  port 0   (0x3000_0000, SHARED)
 *       addr[SEL_BIT] = 1  ->  port 1   (0x4000_0000, ACTCAP doorbell)
 *
 *   `SEL_BIT = 30` is what tells the two nibbles apart: 0x3 is `0011`, 0x4 is
 *   `0100`, and bit 30 is the only one of the four that differs in the
 *   direction we want.
 *
 *   SINGLE OUTSTANDING, and that is a contract rather than a simplification:
 *   the upstream master is the TGC5B data bus, which the reference SoC
 *   already treats as single-outstanding per direction (see the dBus decoder
 *   in `tgc5b_rvcfi_synth_wrap.sv`). The response side therefore only needs
 *   the destination latched at the address beat, exactly as that decoder
 *   does it -- no ID tracking, no reordering, no queue.
 *
 *   The two directions are independent: a read to the doorbell may be in
 *   flight while a write to the shared memory is, which is what an ordinary
 *   load/store pair does.
 */

module ct_axil_demux2 #(
	int SEL_BIT = 30
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous

	// -- upstream (slave) --------------------------------------------------
	input  uwire logic        s_awvalid,
	output      logic         s_awready,
	input  uwire logic [31:0] s_awaddr,
	input  uwire logic        s_wvalid,
	output      logic         s_wready,
	input  uwire logic [31:0] s_wdata,
	input  uwire logic [3:0]  s_wstrb,
	output      logic         s_bvalid,
	input  uwire logic        s_bready,
	output      logic [1:0]   s_bresp,
	input  uwire logic        s_arvalid,
	output      logic         s_arready,
	input  uwire logic [31:0] s_araddr,
	output      logic         s_rvalid,
	input  uwire logic        s_rready,
	output      logic [31:0]  s_rdata,
	output      logic [1:0]   s_rresp,

	// -- downstream port 0 (master) ---------------------------------------
	output      logic         m0_awvalid,
	input  uwire logic        m0_awready,
	output      logic [31:0]  m0_awaddr,
	output      logic         m0_wvalid,
	input  uwire logic        m0_wready,
	output      logic [31:0]  m0_wdata,
	output      logic [3:0]   m0_wstrb,
	input  uwire logic        m0_bvalid,
	output      logic         m0_bready,
	input  uwire logic [1:0]  m0_bresp,
	output      logic         m0_arvalid,
	input  uwire logic        m0_arready,
	output      logic [31:0]  m0_araddr,
	input  uwire logic        m0_rvalid,
	output      logic         m0_rready,
	input  uwire logic [31:0] m0_rdata,
	input  uwire logic [1:0]  m0_rresp,

	// -- downstream port 1 (master) ---------------------------------------
	output      logic         m1_awvalid,
	input  uwire logic        m1_awready,
	output      logic [31:0]  m1_awaddr,
	output      logic         m1_wvalid,
	input  uwire logic        m1_wready,
	output      logic [31:0]  m1_wdata,
	output      logic [3:0]   m1_wstrb,
	input  uwire logic        m1_bvalid,
	output      logic         m1_bready,
	input  uwire logic [1:0]  m1_bresp,
	output      logic         m1_arvalid,
	input  uwire logic        m1_arready,
	output      logic [31:0]  m1_araddr,
	input  uwire logic        m1_rvalid,
	output      logic         m1_rready,
	input  uwire logic [31:0] m1_rdata,
	input  uwire logic [1:0]  m1_rresp
);

	uwire logic wr_sel = s_awaddr[SEL_BIT];
	uwire logic rd_sel = s_araddr[SEL_BIT];

	// Destination latched at the accepted address beat (same idea as the
	// dBus decoder upstream).
	logic b_pending, r_pending, b_sel, r_sel;

	always_ff @(posedge clk) begin
		if (rst) begin
			b_pending <= 1'b0;
			r_pending <= 1'b0;
			b_sel     <= 1'b0;
			r_sel     <= 1'b0;
		end
		else begin
			if (s_awvalid && s_awready && s_wvalid && s_wready) begin
				b_pending <= 1'b1;
				b_sel     <= wr_sel;
			end
			else if (s_bvalid && s_bready) begin
				b_pending <= 1'b0;
			end

			if (s_arvalid && s_arready) begin
				r_pending <= 1'b1;
				r_sel     <= rd_sel;
			end
			else if (s_rvalid && s_rready) begin
				r_pending <= 1'b0;
			end
		end
	end

	// Address/data fan-out (payload goes to both; only valid selects).
	assign m0_awaddr = s_awaddr;
	assign m1_awaddr = s_awaddr;
	assign m0_wdata  = s_wdata;
	assign m1_wdata  = s_wdata;
	assign m0_wstrb  = s_wstrb;
	assign m1_wstrb  = s_wstrb;
	assign m0_araddr = s_araddr;
	assign m1_araddr = s_araddr;

	assign m0_awvalid = s_awvalid && !wr_sel && !b_pending;
	assign m1_awvalid = s_awvalid &&  wr_sel && !b_pending;
	assign m0_wvalid  = s_wvalid  && !wr_sel && !b_pending;
	assign m1_wvalid  = s_wvalid  &&  wr_sel && !b_pending;
	assign s_awready  = !b_pending && (wr_sel ? m1_awready : m0_awready);
	assign s_wready   = !b_pending && (wr_sel ? m1_wready  : m0_wready);

	assign s_bvalid  = b_sel ? m1_bvalid : m0_bvalid;
	assign s_bresp   = b_sel ? m1_bresp  : m0_bresp;
	assign m0_bready = !b_sel && s_bready;
	assign m1_bready =  b_sel && s_bready;

	assign m0_arvalid = s_arvalid && !rd_sel && !r_pending;
	assign m1_arvalid = s_arvalid &&  rd_sel && !r_pending;
	assign s_arready  = !r_pending && (rd_sel ? m1_arready : m0_arready);

	assign s_rvalid  = r_sel ? m1_rvalid : m0_rvalid;
	assign s_rdata   = r_sel ? m1_rdata  : m0_rdata;
	assign s_rresp   = r_sel ? m1_rresp  : m0_rresp;
	assign m0_rready = !r_sel && s_rready;
	assign m1_rready =  r_sel && s_rready;

endmodule // ct_axil_demux2

`default_nettype wire
