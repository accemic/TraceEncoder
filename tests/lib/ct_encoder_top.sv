// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Synthesis Wrapper for ct_encoder
 *
 * @details
 * This wrapper is meant as a *pin reduced* synthesis top-level.
 * - No SystemVerilog interfaces appear at the top-level (Vivado synthesis wrapper constraint).
 * - Wishbone stays unfolded (functional external control).
 * - TIP is *compressed* by providing only a small stimulus control interface; the wrapper
 *   generates a synthetic TIP stream internally (lossy, not suitable for connecting a real CPU).
 * - AXIS/ATB outputs are exported as compact XOR-folded signatures.
 *
 * If you need a “real” top-level (full TIP/AXIS unfolded), create a second wrapper.
 *
 * - Resource usage: 16.400 LUTs, 10.900 FF's
 */

module ct_encoder_top (
	// --------------------------------------------------------------------
	// Clocks / resets (kept explicit)
	// --------------------------------------------------------------------
	input  uwire logic tip_clk,
	input  uwire logic tip_rst,

	input  uwire logic wb_clk,
	input  uwire logic wb_rst,

	input  uwire logic proc_clk,
	input  uwire logic proc_rst,
	input  uwire logic ct_cs_rst,

	input  uwire logic wall_clk,
	input  uwire logic wall_clk_rst,

	input  uwire logic atb_atclk,
	input  uwire logic atb_atresetn,

	// --------------------------------------------------------------------
	// Unfolded Wishbone interface (external control)
	// --------------------------------------------------------------------
	input  uwire logic [31:0] wb_addr,
	input  uwire logic [31:0] wb_data_m2s,
	input  uwire logic        wb_cyc,
	input  uwire logic [3:0]  wb_sel,
	input  uwire logic        wb_stb,
	input  uwire logic        wb_we,

	output       logic [31:0] wb_data_s2m,
	output       logic        wb_ack,
	output       logic        wb_err,

	// --------------------------------------------------------------------
	// Compressed TIP control (synthetic stimulus)
	// --------------------------------------------------------------------
	input  uwire logic        tip_enable,
	input  uwire logic [31:0] tip_seed,

	// --------------------------------------------------------------------
	// ATB: keep inputs explicit, compress outputs
	// --------------------------------------------------------------------
	input  uwire logic        atb_atready,
	input  uwire logic        atb_afvalid,
	input  uwire logic        atb_syncreq,
	output uwire logic        atb_valid,
	output       logic [7:0]  atb_sig,

	// --------------------------------------------------------------------
	// AXIS: provide backpressure input, compress outputs
	// --------------------------------------------------------------------
	input  uwire logic        axis_tready,
	output uwire logic        axis_valid,
	output       logic [7:0]  axis_sig
);

	// --------------------------------------------------------------------
	// Internal interfaces
	// --------------------------------------------------------------------
	tip_if tip();
	wb_if  #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb();

	// Keep AXIS width constants local to avoid extra package dependencies in this wrapper.
	// Must match ct_pkg::ACT_CAP_AXIS_TDATA_WIDTH / ct_pkg::ACT_CAP_AXIS_TID_WIDTH.
	localparam int unsigned AXIS_TDATA_WIDTH = 96;
	localparam int unsigned AXIS_TID_WIDTH   = 8;
	axis_if #(
		.TDATA_WIDTH(AXIS_TDATA_WIDTH),
		.TID_WIDTH  (AXIS_TID_WIDTH)
	) axis (
		.aclk    (tip_clk),
		.aresetn (!tip_rst)
	);

	atb_if atb();

	// --------------------------------------------------------------------
	// Wishbone pin mapping
	// --------------------------------------------------------------------
	always_comb begin
		wb.addr     = wb_addr;
		wb.data_m2s = wb_data_m2s;
		wb.cyc      = wb_cyc;
		wb.sel      = wb_sel;
		wb.stb      = wb_stb;
		wb.we       = wb_we;
	end

	always_comb begin
		wb_data_s2m = wb.data_s2m;
		wb_ack      = wb.ack;
		wb_err      = wb.err;
	end

	// --------------------------------------------------------------------
	// TIP synthetic stimulus (pin reduced)
	// --------------------------------------------------------------------
	function automatic logic [31:0] lfsr32_next(input logic [31:0] s);
		// Primitive LFSR polynomial (32, 22, 2, 1, 0)
		lfsr32_next = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
	endfunction

	logic [31:0] lfsr;
	logic [63:0] time_ctr;

	always_ff @(posedge tip_clk) begin
		if (tip_rst) begin
			lfsr     <= tip_seed;
			time_ctr <= '0;
		end else begin
			if (!tip_enable) begin
				lfsr <= tip_seed;
			end else begin
				lfsr     <= lfsr32_next(lfsr);
				time_ctr <= time_ctr + 64'd1;
			end
		end
	end

	always_comb begin
		// Control-flow defaults
		tip._time     = time_ctr;
		tip.itype     = '0;              // tip_pkg::OTHER
		tip.ecause    = '0;
		tip.tval      = 32'h0;
		tip.priv      = 3'b0;
		tip.iaddr     = lfsr;
		tip._context  = lfsr[1:0];
		tip.ctype     = '0;
		tip.iretire   = tip_enable;      // keep pipeline active
		tip.ilastsize = 2'd2;
		tip.impdef    = '0;

		// Data-trace activity (some toggling so logic doesn't constant-fold)
		tip.dretire   = tip_enable & lfsr[2];
		tip.dtype     = lfsr[3] ? 4'd1 : 4'd0;   // STORE / LOAD
		tip.daddr     = ~lfsr;
		tip.dsize     = {2'b0, lfsr[5:2]};
		tip.data      = {lfsr, ~lfsr};
	end

	// --------------------------------------------------------------------
	// AXIS + ATB pin mapping & compressed signatures
	// --------------------------------------------------------------------
	assign axis.tready = axis_tready;
	assign axis_valid  = axis.tvalid;

	assign atb.atready = atb_atready;
	assign atb.afvalid = atb_afvalid;
	assign atb.syncreq = atb_syncreq;
	assign atb_valid   = atb.atvalid;

	logic [AXIS_TDATA_WIDTH + (AXIS_TDATA_WIDTH/8) + AXIS_TID_WIDTH + 2 - 1:0] axis_vec;
	// Note: we intentionally only include signals actively used/driven by current ct_encoder implementation.
	//       (tkeep/tlast/tdest/tuser are currently undriven inside the design.)
	assign axis_vec = {
		axis.tdata,
		axis.tstrb,
		axis.tid,
		axis.tvalid,
		axis.tready
	};

	always_comb begin
		axis_sig = '0;
		for (int i = 0; i < $bits(axis_vec); i++) begin
			axis_sig[i % 8] ^= axis_vec[i];
		end
	end

	logic [atb_pkg::ATDATA_WIDTH + atb_pkg::ATBYTES_WIDTH + atb_pkg::ATID_WIDTH + 5 - 1:0] atb_vec;
	assign atb_vec = {
		atb.atdata,
		atb.atbytes,
		atb.atid,
		atb.atvalid,
		atb.afready,
		atb.atready,
		atb.afvalid,
		atb.syncreq
	};

	always_comb begin
		atb_sig = '0;
		for (int i = 0; i < $bits(atb_vec); i++) begin
			atb_sig[i % 8] ^= atb_vec[i];
		end
	end

	// --------------------------------------------------------------------
	// DUT
	// --------------------------------------------------------------------
	ct_encoder ct_encoder_inst (
		.tip_clk,
		.tip_rst,
		.tip (tip.slave),

		.wb_clk,
		.wb_rst,
		.wb  (wb.slave),

		.axis (axis.master),

		.atb_atclk,
		.atb_atresetn,
		.atb (atb.master),

		.proc_clk,
		.proc_rst,
		.ct_cs_rst,
		.wall_clk,
		.wall_clk_rst
	);

endmodule

`default_nettype wire
