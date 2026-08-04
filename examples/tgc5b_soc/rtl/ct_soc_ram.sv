// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Dual-port AXI4-Lite program/data RAM for the TGC5B example SoC.
 *
 * @details
 *   One word array behind two AXI4-Lite slave ports over one clock:
 *   - Port I: read-only, driven by the core instruction bus (iBus).
 *   - Port D: read/write, driven by the RAM segment of the core data bus (dBus).
 *   von-Neumann layout — code and data share the array.
 *
 *   Two BRAM ports total (port I = one read port; port D = one read/write port
 *   sharing a single muxed address per cycle), so the array infers a true
 *   dual-port block RAM. Port D services one access at a time (the encoder-SoC
 *   masters are single-outstanding), so read and write never contend for the
 *   port in the same cycle. `INIT_FILE`, if set, is loaded with `$readmemh` at
 *   time 0. `wstrb` gives per-byte writes on port D.
 *
 *   Cost note: Vivado gives each read port its own copy of the array, so the
 *   default 16384 x 32 b (64 KiB) occupies 32 RAMB36 tiles rather than the 16 a
 *   single copy would need — the whole ct_soc_synth_wrap BRAM budget on the
 *   KV260 build. Shrink MEM_WORDS if tiles are tight.
 */

module ct_soc_ram #(
	int unsigned MEM_WORDS = 16384,         // 64 KiB
	string       INIT_FILE = ""
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous

	// -- Port I: instruction fetch (read-only) -----------------------------
	input  uwire logic        i_arvalid,
	output      logic         i_arready,
	input  uwire logic [31:0] i_araddr,
	output      logic         i_rvalid,
	input  uwire logic        i_rready,
	output      logic [31:0]  i_rdata,
	output      logic [1:0]   i_rresp,

	// -- Port D: data access (read/write) ----------------------------------
	input  uwire logic        d_awvalid,
	output      logic         d_awready,
	input  uwire logic [31:0] d_awaddr,
	input  uwire logic        d_wvalid,
	output      logic         d_wready,
	input  uwire logic [31:0] d_wdata,
	input  uwire logic [3:0]  d_wstrb,
	output      logic         d_bvalid,
	input  uwire logic        d_bready,
	output      logic [1:0]   d_bresp,
	input  uwire logic        d_arvalid,
	output      logic         d_arready,
	input  uwire logic [31:0] d_araddr,
	output      logic         d_rvalid,
	input  uwire logic        d_rready,
	output      logic [31:0]  d_rdata,
	output      logic [1:0]   d_rresp
);

	localparam int unsigned AW  = $clog2(MEM_WORDS);
	localparam logic [1:0]  OKAY = 2'b00;

	(* ram_style = "block" *) logic [31:0] mem [0:MEM_WORDS-1];

	initial begin
		if (INIT_FILE != "") begin
			$readmemh(INIT_FILE, mem);
		end
	end

	function automatic logic [AW-1:0] word_idx(input logic [31:0] byte_addr);
		return byte_addr[AW+1:2];
	endfunction

	// -- Port I: read-only (one BRAM read port) ----------------------------
	logic        i_rvalid_q;
	logic [31:0] i_rdata_q;
	uwire logic  i_rd_fire = i_arvalid && !i_rvalid_q;

	assign i_arready = !i_rvalid_q;
	assign i_rvalid  = i_rvalid_q;
	assign i_rdata   = i_rdata_q;
	assign i_rresp   = OKAY;

	always_ff @(posedge clk) begin
		if (rst) begin
			i_rvalid_q <= 1'b0;
		end
		else begin
			if (i_rd_fire) begin
				i_rdata_q  <= mem[word_idx(i_araddr)];
				i_rvalid_q <= 1'b1;
			end
			else if (i_rvalid && i_rready) begin
				i_rvalid_q <= 1'b0;
			end
		end
	end

	// -- Port D: read/write (one BRAM port), fully registered handshake -------
	// The prior version derived d_awready (and the memory write-enable) from a
	// *combinational* d_wr_fire = d_awvalid && d_wvalid && !d_bvalid_q. Driven
	// across the ct_soc_top -> ct_soc_synth_wrap(ldr mux) -> ct_soc_ram boundary and
	// back, that made the write-enable a long cross-hierarchy combinational
	// path; on hardware it glitched (corrupting/dropping writes) while zero-delay
	// simulation was clean. Registering the accept (awready/wready pulse under an
	// aw_en gate) and committing the write one cycle later from *registered*
	// address/data/strobe makes every cross-module signal a flop output.
	logic          d_awready_q, d_wready_q, d_bvalid_q, d_aw_en;
	logic          d_arready_q, d_rvalid_q;
	logic          d_wpend;                 // write accepted, commit next cycle
	logic          d_rpend;                 // read accepted, present data next cycle
	logic [AW-1:0] d_waddr_q, d_raddr_q;
	logic [31:0]   d_wdata_q, d_rdata_q;
	logic [3:0]    d_wstrb_q;

	assign d_awready = d_awready_q;
	assign d_wready  = d_wready_q;
	assign d_bvalid  = d_bvalid_q;
	assign d_bresp   = OKAY;
	assign d_arready = d_arready_q;
	assign d_rvalid  = d_rvalid_q;
	assign d_rdata   = d_rdata_q;
	assign d_rresp   = OKAY;

	always_ff @(posedge clk) begin
		if (rst) begin
			d_awready_q <= 1'b0; d_wready_q <= 1'b0; d_bvalid_q <= 1'b0;
			d_aw_en <= 1'b1; d_wpend <= 1'b0;
			d_arready_q <= 1'b0; d_rvalid_q <= 1'b0; d_rpend <= 1'b0;
		end
		else begin
			// Accept write address + data together (single outstanding: aw_en
			// blocks a new accept until the current B response is taken).
			if (!d_awready_q && d_awvalid && d_wvalid && d_aw_en) begin
				d_awready_q <= 1'b1;
				d_wready_q  <= 1'b1;
				d_aw_en     <= 1'b0;
				d_waddr_q   <= word_idx(d_awaddr);
				d_wdata_q   <= d_wdata;
				d_wstrb_q   <= d_wstrb;
				d_wpend     <= 1'b1;
			end
			else begin
				d_awready_q <= 1'b0;
				d_wready_q  <= 1'b0;
			end

			// Commit the accepted write one cycle later from registered fields.
			if (d_wpend) begin
				for (int b = 0; b < 4; b++) begin
					if (d_wstrb_q[b]) mem[d_waddr_q][b*8 +: 8] <= d_wdata_q[b*8 +: 8];
				end
				d_wpend    <= 1'b0;
				d_bvalid_q <= 1'b1;
			end
			if (d_bvalid_q && d_bready) begin
				d_bvalid_q <= 1'b0;
				d_aw_en    <= 1'b1;
			end

			// Reads are staged so arready (accept) and rvalid (data) land in
			// SEPARATE cycles — a same-cycle arready+rvalid wedges the
			// single-outstanding dBus decoder (its r_pending latches the AR
			// handshake while the R beat is simultaneously consumed, so it never
			// clears). Cycle 1: accept the address (arready pulse, latch it).
			if (!d_arready_q && d_arvalid && !d_rvalid_q && !d_rpend) begin
				d_arready_q <= 1'b1;
				d_raddr_q   <= word_idx(d_araddr);
				d_rpend     <= 1'b1;
			end
			else begin
				d_arready_q <= 1'b0;
			end
			// Cycle 2: present the data (deferred while a write is committing, so
			// the single BRAM port does at most one access per cycle).
			if (d_rpend && !d_wpend) begin
				d_rdata_q  <= mem[d_raddr_q];
				d_rvalid_q <= 1'b1;
				d_rpend    <= 1'b0;
			end
			if (d_rvalid_q && d_rready) begin
				d_rvalid_q <= 1'b0;
			end
		end
	end

endmodule

`default_nettype wire
