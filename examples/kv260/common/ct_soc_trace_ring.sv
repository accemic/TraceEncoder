// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    On-chip ATB trace-capture RING buffer (devmem-readable, URAM).
 *
 * @details
 *   Renamed from `ct_soc_trace_buf` on migration into examples/kv260/common/
 *   (2026-08-17): examples/kv260/common/tgc5b/rtl/ct_soc_trace_buf.sv keeps that name
 *   for its own, functionally different simple BRAM fill-and-stop buffer --
 *   same module name, two unrelated designs, so this one disambiguates as
 *   the ring (see ../README.md, "Naming").
 *
 *   Passively watches the encoder's ATB master and stores one 32-bit word per
 *   accepted beat (atvalid && atready), so the captured N-Trace can be read
 *   back from Linux over `devmem` and decoded on the host with CTTD.
 *
 *   Ring operation (oneshot_i=0, default): the write pointer wraps modulo
 *   DEPTH and capture never stops — the buffer always holds the most recent
 *   DEPTH beats. `wrapped_o` latches once the pointer has wrapped at least
 *   once (oldest data has been overwritten); `clear` re-arms. `beats_o`/
 *   `bytes_o` count monotonically (32 bit), so the host derives the ring
 *   write position as beats_o % DEPTH and re-orders [wr..DEPTH) ++ [0..wr)
 *   when wrapped.
 *
 *   One-shot operation (oneshot_i=1): capture stops after DEPTH beats — the
 *   buffer keeps the FIRST DEPTH beats, wrapped_o stays 0 and beats_o/bytes_o
 *   freeze at the stored amount (stopped_o = 1). `clear` re-arms. The mode
 *   input is meant to be switched only while cleared/quiesced; switching to
 *   one-shot after a wrap simply stops the ring where it is.
 *
 *   Storage: two 32-bit beats are packed per 64-bit word so URAM width is
 *   used efficiently (DEPTH=262144 beats = 1 MiB = 32 URAM288 blocks on the
 *   K26 instead of 64 with a 32-bit-wide array). Per-half write enables
 *   follow the byte-enable RAM template so Vivado infers URAM with BWE.
 *
 *   Byte accounting is unchanged: all beats carry 4 valid bytes except the
 *   final beat of a flushed stream (atbytes+1 valid), so the host keeps the
 *   first/last `bytes_o` bytes of the re-ordered word stream.
 */

module ct_soc_trace_ring #(
	int unsigned DEPTH = 262144        // captured beats (words) ring capacity; 1 MiB
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous
	input  uwire logic        clear,        // level: hold to reset the capture
	input  uwire logic        oneshot_i,    // 1: stop when full (keep FIRST beats)

	// ATB monitor (observe the encoder master + its sink handshake)
	input  uwire logic        atb_atvalid,
	input  uwire logic        atb_atready,
	input  uwire logic [31:0] atb_atdata,
	input  uwire logic [1:0]  atb_atbytes,

	// Status
	output      logic [31:0]  beats_o,      // total beats captured (monotonic)
	output      logic [31:0]  bytes_o,      // total valid ATB bytes captured (monotonic)
	output      logic         wrapped_o,    // ring wrapped: oldest beats overwritten
	output      logic         stopped_o,    // one-shot: buffer full, capture stopped

	// Read-back port (word addressed): rd_data reflects mem[rd_word] next cycle
	input  uwire logic [31:0] rd_word,
	output      logic [31:0]  rd_data
);

	localparam int AW = $clog2(DEPTH);

	// 64-bit-wide URAM array, two beats per word.
	(* ram_style = "ultra" *) logic [63:0] mem [0:DEPTH/2-1];

	logic [AW-1:0] wptr;                    // ring position (wraps naturally)
	logic [31:0]   beats_q, bytes_q;
	logic          wrapped_q;

	assign stopped_o = oneshot_i && (beats_q >= 32'(DEPTH));

	uwire logic capture = atb_atvalid && atb_atready && !stopped_o;
	uwire logic we_lo   = capture && !wptr[0];
	uwire logic we_hi   = capture &&  wptr[0];
	uwire logic [AW-2:0] waddr = wptr[AW-1:1];

	always_ff @(posedge clk) begin
		if (rst || clear) begin
			wptr      <= '0;
			beats_q   <= '0;
			bytes_q   <= '0;
			wrapped_q <= 1'b0;
		end
		else if (capture) begin
			wptr    <= wptr + AW'(1);
			beats_q <= beats_q + 32'd1;
			bytes_q <= bytes_q + {30'b0, atb_atbytes} + 32'd1;
			// one shot: capture stops at DEPTH, nothing is ever overwritten
			// -> wrapped stays 0 (ring semantics keep the G7 host contract).
			if (wptr == AW'(DEPTH - 1) && !oneshot_i) begin
				wrapped_q <= 1'b1;
			end
		end
	end

	// Per-half write enables (byte-enable template -> URAM BWE inference).
	always_ff @(posedge clk) begin
		if (we_lo) mem[waddr][31:0]  <= atb_atdata;
		if (we_hi) mem[waddr][63:32] <= atb_atdata;
	end

	// Registered read-back (URAM sync read port), half-select registered
	// alongside so rd_data reflects mem[rd_word] one cycle later.
	logic [63:0] rword_q;
	logic        rsel_q;
	always_ff @(posedge clk) begin
		rword_q <= mem[rd_word[AW-1:1]];
		rsel_q  <= rd_word[0];
	end
	assign rd_data = rsel_q ? rword_q[63:32] : rword_q[31:0];

	assign beats_o   = beats_q;
	assign bytes_o   = bytes_q;
	assign wrapped_o = wrapped_q;

endmodule

`default_nettype wire
