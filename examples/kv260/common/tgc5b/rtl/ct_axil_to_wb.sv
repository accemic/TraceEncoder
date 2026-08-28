// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    AXI4-Lite (slave) -> Wishbone B4 (master) bridge.
 *
 * @details
 *   Adapts the TGC5B data bus (AXI4-Lite) to the encoder's Wishbone CSR port.
 *   Single outstanding transaction, one classic Wishbone cycle per AXI beat:
 *   `cyc`+`stb` are held until the slave asserts `ack`/`err`. Writes prefer the
 *   AXI write channel over a concurrent read. Address/data/strobe are latched at
 *   the AXI accept handshake (the master may drop them afterwards). The address
 *   handed to Wishbone is the byte offset presented on the AXI channel (the
 *   caller decodes the CSR region and offsets it), matching the encoder's
 *   `wb_to_cpuif` expectation. `wstrb` maps to `wb.sel`; a Wishbone `err`
 *   becomes an AXI SLVERR response.
 */

module ct_axil_to_wb (
	input  uwire logic        clk,
	input  uwire logic        rst,        // active-high, synchronous

	// -- AXI4-Lite slave ---------------------------------------------------
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

	// -- Wishbone master ---------------------------------------------------
	wb_if.master wb
);

	localparam logic [1:0] RESP_OKAY   = 2'b00;
	localparam logic [1:0] RESP_SLVERR = 2'b10;

	typedef enum logic [2:0] {
		S_IDLE,
		S_WR,      // Wishbone write cycle in flight
		S_WR_RESP, // holding AXI B response
		S_RD,      // Wishbone read cycle in flight
		S_RD_RESP  // holding AXI R response
	} state_e;

	state_e      state;
	logic [31:0] addr_q;
	logic [31:0] wdata_q;
	logic [3:0]  wstrb_q;
	logic [31:0] rd_data_q;
	logic [1:0]  resp_q;

	// Accept a write (AW+W together) or, failing that, a read while idle.
	uwire logic accept_wr = (state == S_IDLE) && s_awvalid && s_wvalid;
	uwire logic accept_rd = (state == S_IDLE) && !(s_awvalid && s_wvalid) && s_arvalid;

	// Watchdog: force-complete a never-acked Wishbone cycle with SLVERR.
	//
	// A Wishbone slave that never acknowledges stalls this bridge forever, and
	// the stall propagates: on the board that is one non-acking CSR access
	// (measured: an unmapped-hole read) freezing the PS FPD AXI read channel
	// and progressively wedging Linux -- devmem in D state first, then the
	// network. The CSR slave acknowledges within single-digit cycles, so 256 is
	// orders of magnitude above any legal latency and cannot fire in normal
	// operation. Ported from the board integration tree (G7 hardening,
	// 2026-07-22), where it was found the expensive way.
	localparam int unsigned WDOG_CYCLES = 256;
	logic [$clog2(WDOG_CYCLES):0] wdog_q;
	uwire logic wdog_fire = (32'(wdog_q) == WDOG_CYCLES - 1);
	uwire logic wb_done   = wb.ack || wb.err || wdog_fire;

	// Watchdog counter: runs while a Wishbone cycle is in flight.
	always_ff @(posedge clk) begin
		if (rst || state == S_IDLE || wb.ack || wb.err) begin
			wdog_q <= '0;
		end
		else if (state == S_WR || state == S_RD) begin
			wdog_q <= wdog_q + 1'b1;
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			state     <= S_IDLE;
			addr_q    <= '0;
			wdata_q   <= '0;
			wstrb_q   <= '0;
			rd_data_q <= '0;
			resp_q    <= RESP_OKAY;
		end
		else begin
			case (state)
				S_IDLE: begin
					if (accept_wr) begin
						addr_q  <= s_awaddr;
						wdata_q <= s_wdata;
						wstrb_q <= s_wstrb;
						state   <= S_WR;
					end
					else if (accept_rd) begin
						addr_q <= s_araddr;
						state  <= S_RD;
					end
				end

				S_WR: begin
					if (wb_done) begin
						resp_q <= (wb.err || wdog_fire) ? RESP_SLVERR : RESP_OKAY;
						state  <= S_WR_RESP;
					end
				end

				S_WR_RESP: begin
					if (s_bready) begin
						state <= S_IDLE;
					end
				end

				S_RD: begin
					if (wb_done) begin
						rd_data_q <= wdog_fire ? 32'hDEAD_ACC0 : wb.data_s2m;
						resp_q    <= (wb.err || wdog_fire) ? RESP_SLVERR : RESP_OKAY;
						state     <= S_RD_RESP;
					end
				end

				S_RD_RESP: begin
					if (s_rready) begin
						state <= S_IDLE;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

	// AXI handshakes.
	assign s_awready = accept_wr;
	assign s_wready  = accept_wr;
	assign s_arready = accept_rd;

	assign s_bvalid  = (state == S_WR_RESP);
	assign s_bresp   = resp_q;
	assign s_rvalid  = (state == S_RD_RESP);
	assign s_rdata   = rd_data_q;
	assign s_rresp   = resp_q;

	// Wishbone master drive (from latched request).
	always_comb begin
		wb.cyc      = (state == S_WR) || (state == S_RD);
		wb.stb      = (state == S_WR) || (state == S_RD);
		wb.we       = (state == S_WR);
		wb.addr     = addr_q;
		wb.data_m2s = wdata_q;
		wb.sel      = (state == S_WR) ? wstrb_q : 4'hF;
	end

endmodule

`default_nettype wire
