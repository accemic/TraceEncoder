// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    On-chip ATB trace-capture buffer (devmem-readable).
 *
 * @details
 *   Passively watches the encoder's ATB master and stores one 32-bit word per
 *   accepted beat (atvalid && atready) into a BRAM, so the captured N-Trace can
 *   be read back from Linux over `devmem` and decoded on the host with NexRv.
 *
 *   One word per beat keeps the writer to a single BRAM port. `bytes_o` counts
 *   the exact number of valid ATB bytes (sum of atbytes+1), so the host reads
 *   `beats_o` words back and keeps the first `bytes_o` bytes — identical to the
 *   atb_dump byte stream (the encoder packs full 32-bit words, so only the final
 *   beat can be partial). `clear` re-arms the buffer; capture stops (and
 *   `overflow_o` latches) once DEPTH beats are stored.
 *
 *   Capacity: DEPTH words of 4 bytes — 4096 words = 16 KiB by default (4 BRAM
 *   tiles on the KV260 build). `beats_o` saturates at DEPTH and `bytes_o` at
 *   4*DEPTH; both stop growing while `overflow_o` is set, i.e. a full buffer
 *   means the trace is truncated, not that the run ended. The read-back port
 *   only decodes the low $clog2(DEPTH) address bits, so `rd_word` >= DEPTH
 *   aliases back to the start of the buffer.
 */

module ct_soc_trace_buf #(
	int unsigned DEPTH = 4096          // captured beats (1 word each) -> 16 KiB
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous
	input  uwire logic        clear,        // level: hold to reset the capture

	// ATB monitor (observe the encoder master + its sink handshake)
	input  uwire logic        atb_atvalid,
	input  uwire logic        atb_atready,
	input  uwire logic [31:0] atb_atdata,
	input  uwire logic [1:0]  atb_atbytes,

	// Status
	output      logic [31:0]  beats_o,      // beats captured
	output      logic [31:0]  bytes_o,      // valid ATB bytes captured
	output      logic         overflow_o,   // buffer filled, beats dropped

	// Read-back port (word addressed): rd_data reflects mem[rd_word] next cycle
	input  uwire logic [31:0] rd_word,
	output      logic [31:0]  rd_data
);

	localparam int AW = $clog2(DEPTH);

	(* ram_style = "block" *) logic [31:0] mem [0:DEPTH-1];

	logic [AW:0]  wptr;      // one extra bit so wptr==DEPTH means full
	logic [31:0]  bytes_q;
	logic         overflow_q;

	uwire logic is_full = (wptr == (AW+1)'(DEPTH));
	uwire logic capture = atb_atvalid && atb_atready && !is_full;

	always_ff @(posedge clk) begin
		if (rst || clear) begin
			wptr       <= '0;
			bytes_q    <= '0;
			overflow_q <= 1'b0;
		end
		else begin
			if (atb_atvalid && atb_atready && is_full) begin
				overflow_q <= 1'b1;
			end
			if (capture) begin
				mem[wptr[AW-1:0]] <= atb_atdata;
				wptr              <= wptr + (AW+1)'(1);
				bytes_q           <= bytes_q + {30'b0, atb_atbytes} + 32'd1;
			end
		end
	end

	// Registered read-back (BRAM read port).
	always_ff @(posedge clk) begin
		rd_data <= mem[rd_word[AW-1:0]];
	end

	assign beats_o    = {{(32-AW-1){1'b0}}, wptr};
	assign bytes_o    = bytes_q;
	assign overflow_o = overflow_q;

endmodule

`default_nettype wire
