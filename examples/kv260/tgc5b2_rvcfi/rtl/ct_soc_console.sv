// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Per-core character channel between a TGC5B and the PS: two BRAM
 *           FIFOs behind a memory-mapped register interface.
 *
 * @details
 *   The convenient way to talk to a bare-metal core from Linux is NOT
 *   necessarily a UART. A physical PL UART needs a device-tree overlay, a
 *   ttyUL* device whose number depends on probe order (the same instability
 *   this lab already knows from its ttyUSB enumeration), and it cannot be
 *   exercised in the SoC simulation at all. Two FIFOs behind registers need
 *   no kernel driver, ride the same /dev/mem path as every other window of
 *   this design, and the end-to-end bench can prove the channel before any
 *   bitstream exists. The terminal comfort lives in software (`rvmon
 *   console` drains TX to stdout and forwards stdin to RX).
 *
 *   CORE SIDE (AXI4-Lite slave, mapped at 0x4000_0100 next to the ACT-CAP
 *   doorbell through a second ct_axil_demux2 level):
 *
 *     0x00  TX       W: push one character (low byte)
 *                    R: TX free space (a blocking putchar spins on this --
 *                       uninstrumented, like every other spin in the demo)
 *     0x04  RX_CNT   R: characters waiting for the core
 *     0x08  RX_POP   R: pop one character. Bit 31 = valid, [7:0] = char.
 *                       First-word-fall-through, so the datum arrives in the
 *                       SAME read that pops it -- a side-effect read cannot
 *                       come back "one cycle later".
 *     0x0C  TX_DROPS R: characters dropped because TX was full (saturating).
 *                       A write to a full FIFO is counted, never silently
 *                       swallowed -- the lesson of this whole design is that
 *                       an unsupported operation that pretends to have
 *                       worked is the worst outcome.
 *
 *   PS SIDE: flat ports, folded into the SoC top's CTRL observation bank at
 *   0x60..0x7C. Same FWFT rule for the TX pop. The PS checks `rx_free`
 *   before pushing; a push into a full RX is dropped and counted the same
 *   way (`rx_drops`, visible core-side semantics mirrored -- the counter is
 *   exposed on the PS status word, because the party that can react to RX
 *   overflow is the pusher, i.e. the PS).
 *
 *   Both handshake channels carry the pending stage between accept and
 *   response -- the doorbell's AXI lesson (BVALID in the accept cycle wedges
 *   the TGC5B data bus) applies to every slave on this bus.
 */

module ct_soc_console #(
	int unsigned DEPTH = 2048           // characters per direction (power of two)
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous

	// -- Core side: AXI4-Lite slave ----------------------------------------
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

	// -- PS side: flat ports for the CTRL observation bank ------------------
	output      logic [15:0]  ps_tx_cnt,     // characters waiting for the PS
	output      logic         ps_tx_valid,   // head valid (FWFT)
	output      logic [7:0]   ps_tx_data,    // head character
	input  uwire logic        ps_tx_pop,     // strobe: consume the head
	output      logic [15:0]  ps_rx_free,    // space the PS may push into
	input  uwire logic        ps_rx_push,    // strobe: push ps_rx_data
	input  uwire logic [7:0]  ps_rx_data,
	output      logic [15:0]  ps_rx_drops    // pushes into a full RX (saturating)
);

	localparam int AW = $clog2(DEPTH);
	localparam logic [1:0] OKAY = 2'b00;

	// -----------------------------------------------------------------
	// TX FIFO: core -> PS
	// -----------------------------------------------------------------
	logic [7:0]    tx_mem [0:DEPTH-1];
	logic [AW-1:0] tx_wp, tx_rp;
	logic [AW:0]   tx_cnt;
	logic [15:0]   tx_drops;

	uwire logic tx_full  = (tx_cnt == DEPTH[AW:0]);
	uwire logic tx_empty = (tx_cnt == '0);

	assign ps_tx_cnt   = 16'(tx_cnt);
	assign ps_tx_valid = !tx_empty;
	assign ps_tx_data  = tx_mem[tx_rp];    // FWFT: head visible before the pop

	// -----------------------------------------------------------------
	// RX FIFO: PS -> core
	// -----------------------------------------------------------------
	logic [7:0]    rx_mem [0:DEPTH-1];
	logic [AW-1:0] rx_wp, rx_rp;
	logic [AW:0]   rx_cnt;
	logic [15:0]   rx_drops;

	uwire logic rx_full  = (rx_cnt == DEPTH[AW:0]);
	uwire logic rx_empty = (rx_cnt == '0);

	assign ps_rx_free  = 16'(DEPTH[AW:0] - rx_cnt);
	assign ps_rx_drops = rx_drops;

	// -----------------------------------------------------------------
	// Core-side AXI4-Lite slave (doorbell handshake pattern: accept, then
	// respond one cycle later -- never both in the same cycle).
	// -----------------------------------------------------------------
	logic        awready_q, wready_q, bvalid_q, aw_en, wpend;
	logic        arready_q, rvalid_q, rpend;
	logic [31:0] rdata_q;
	logic [3:0]  racc_off;                  // latched read offset [5:2]
	logic        core_tx_push;              // this cycle commits a TX char
	logic [7:0]  core_tx_char;
	logic        core_rx_pop;               // this cycle consumes an RX char

	assign s_awready = awready_q;
	assign s_wready  = wready_q;
	assign s_bvalid  = bvalid_q;
	assign s_bresp   = OKAY;
	assign s_arready = arready_q;
	assign s_rvalid  = rvalid_q;
	assign s_rdata   = rdata_q;
	assign s_rresp   = OKAY;

	always_ff @(posedge clk) begin
		if (rst) begin
			awready_q <= 1'b0; wready_q <= 1'b0; bvalid_q <= 1'b0; aw_en <= 1'b1;
			arready_q <= 1'b0; rvalid_q <= 1'b0; wpend <= 1'b0; rpend <= 1'b0;
			core_tx_push <= 1'b0; core_rx_pop <= 1'b0;
		end
		else begin
			awready_q    <= 1'b0;
			wready_q     <= 1'b0;
			arready_q    <= 1'b0;
			wpend        <= 1'b0;
			rpend        <= 1'b0;
			core_tx_push <= 1'b0;
			core_rx_pop  <= 1'b0;

			// write: only offset 0x00 (TX push) does anything
			if (aw_en && s_awvalid && s_wvalid && !bvalid_q) begin
				awready_q <= 1'b1;
				wready_q  <= 1'b1;
				aw_en     <= 1'b0;
				wpend     <= 1'b1;
				if (s_awaddr[5:2] == 4'd0) begin
					core_tx_push <= 1'b1;
					core_tx_char <= s_wdata[7:0];
				end
			end
			if (wpend)  bvalid_q <= 1'b1;
			if (bvalid_q && s_bready) begin
				bvalid_q <= 1'b0;
				aw_en    <= 1'b1;
			end

			// read: datum latched in the pend cycle, pop strobed with it
			if (s_arvalid && !rvalid_q && !rpend) begin
				arready_q <= 1'b1;
				rpend     <= 1'b1;
				racc_off  <= s_araddr[5:2];
			end
			if (rpend) begin
				rvalid_q <= 1'b1;
				unique case (racc_off)
					4'd0:    rdata_q <= 32'(DEPTH[AW:0] - tx_cnt);        // TX free
					4'd1:    rdata_q <= 32'(rx_cnt);                      // RX count
					4'd2: begin                                           // RX pop (FWFT)
						rdata_q <= {!rx_empty, 23'b0, rx_mem[rx_rp]};
						if (!rx_empty) core_rx_pop <= 1'b1;
					end
					4'd3:    rdata_q <= 32'(tx_drops);                    // TX drops
					default: rdata_q <= 32'h0;
				endcase
			end
			if (rvalid_q && s_rready) begin
				rvalid_q <= 1'b0;
			end
		end
	end

	// -----------------------------------------------------------------
	// FIFO state. Push and pop strobes of the two sides never target the
	// same pointer, so there is no arbitration to get wrong: TX is written
	// by the core and read by the PS, RX the other way round.
	// -----------------------------------------------------------------
	always_ff @(posedge clk) begin
		if (rst) begin
			tx_wp <= '0; tx_rp <= '0; tx_cnt <= '0; tx_drops <= '0;
			rx_wp <= '0; rx_rp <= '0; rx_cnt <= '0; rx_drops <= '0;
		end
		else begin
			// TX: core pushes, PS pops
			case ({core_tx_push && !tx_full, ps_tx_pop && !tx_empty})
				2'b10:   tx_cnt <= tx_cnt + 1'b1;
				2'b01:   tx_cnt <= tx_cnt - 1'b1;
				default: ;                          // both or neither: net zero
			endcase
			if (core_tx_push && !tx_full) begin
				tx_mem[tx_wp] <= core_tx_char;
				tx_wp         <= tx_wp + 1'b1;
			end
			else if (core_tx_push && tx_full && tx_drops != 16'hFFFF) begin
				tx_drops <= tx_drops + 1'b1;        // counted, never silent
			end
			if (ps_tx_pop && !tx_empty) begin
				tx_rp <= tx_rp + 1'b1;
			end

			// RX: PS pushes, core pops
			case ({ps_rx_push && !rx_full, core_rx_pop && !rx_empty})
				2'b10:   rx_cnt <= rx_cnt + 1'b1;
				2'b01:   rx_cnt <= rx_cnt - 1'b1;
				default: ;
			endcase
			if (ps_rx_push && !rx_full) begin
				rx_mem[rx_wp] <= ps_rx_data;
				rx_wp         <= rx_wp + 1'b1;
			end
			else if (ps_rx_push && rx_full && rx_drops != 16'hFFFF) begin
				rx_drops <= rx_drops + 1'b1;
			end
			if (core_rx_pop && !rx_empty) begin
				rx_rp <= rx_rp + 1'b1;
			end
		end
	end

endmodule // ct_soc_console

`default_nettype wire
