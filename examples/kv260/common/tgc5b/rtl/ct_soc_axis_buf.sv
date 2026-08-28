// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    On-chip AXIS instrumentation-capture buffer (devmem-readable).
 *
 * @details
 *   Passively watches the encoder's AXI-Stream master (the ACT-CAP/ACT-ST
 *   DAQ sink, 96-bit tdata) and stores one 128-bit record per accepted beat
 *   (tvalid && tready) into a BRAM, so the instrumentation stream can be read
 *   back from Linux over `devmem`:
 *
 *     word 0..2   tdata[31:0] / [63:32] / [95:64]   (three 32-bit elements)
 *     word 3      {11'b0, tlast, tid[7:0], tkeep[11:0]}
 *                  tid[5:0] is the ACT-CAP/ACT-ST command that produced the
 *                  beat — it also tells you which elements carry data.
 *
 *   The encoder qualifies its AXIS elements with `tstrb` and never asserts
 *   `tlast` (one beat per DAQ command — see doc/enhanced-features.adoc). This
 *   buffer stores the `tkeep`/`tlast` lines ct_soc_synth_wrap exports, which the
 *   encoder leaves undriven, so both fields of word 3 read back as 0: decode a
 *   beat from its command, not from tkeep.
 *
 *   `clear` re-arms the buffer; capture stops (and `overflow_o` latches) once
 *   DEPTH beats are stored.
 *
 *   Capacity: DEPTH beats of 16 bytes — 256 beats = 4 KiB by default, read back
 *   as 4*DEPTH = 1024 words of 32 bit (2 BRAM tiles on the KV260 build).
 *   `beats_o` saturates at DEPTH and stops growing while `overflow_o` is set,
 *   i.e. a full buffer means beats were dropped. The read-back port only
 *   decodes the low $clog2(DEPTH)+2 address bits, so `rd_word` >= 4*DEPTH
 *   aliases back to the start of the buffer.
 */

module ct_soc_axis_buf #(
	int unsigned DEPTH = 256           // captured beats (4 words each) -> 4 KiB
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous
	input  uwire logic        clear,        // level: hold to reset the capture

	// AXIS monitor (observe the encoder master + its sink handshake)
	input  uwire logic        axis_tvalid,
	input  uwire logic        axis_tready,
	input  uwire logic [95:0] axis_tdata,
	input  uwire logic [11:0] axis_tkeep,
	input  uwire logic [7:0]  axis_tid,
	input  uwire logic        axis_tlast,

	// Status
	output      logic [31:0]  beats_o,      // beats captured
	output      logic         overflow_o,   // buffer filled, beats dropped

	// Read-back port (word addressed): rd_data reflects mem[rd_word] next cycle
	input  uwire logic [31:0] rd_word,
	output      logic [31:0]  rd_data
);

	localparam int AW = $clog2(DEPTH);

	(* ram_style = "block" *) logic [127:0] mem [0:DEPTH-1];

	logic [AW:0] wptr;       // one extra bit so wptr==DEPTH means full
	logic        overflow_q;

	uwire logic is_full = (wptr == (AW+1)'(DEPTH));
	uwire logic capture = axis_tvalid && axis_tready && !is_full;

	always_ff @(posedge clk) begin
		if (rst || clear) begin
			wptr       <= '0;
			overflow_q <= 1'b0;
		end
		else begin
			if (axis_tvalid && axis_tready && is_full) begin
				overflow_q <= 1'b1;
			end
			if (capture) begin
				mem[wptr[AW-1:0]] <= {11'b0, axis_tlast, axis_tid, axis_tkeep,
				                      axis_tdata};
				wptr              <= wptr + (AW+1)'(1);
			end
		end
	end

	// Registered read-back (BRAM read port); rd_word[1:0] selects the 32-bit
	// word within the 128-bit beat record.
	logic [127:0] rd_beat;
	logic [1:0]   rd_sel;
	always_ff @(posedge clk) begin
		rd_beat <= mem[rd_word[AW+1:2]];
		rd_sel  <= rd_word[1:0];
	end
	assign rd_data = rd_beat[rd_sel*32 +: 32];

	assign beats_o    = {{(32-AW-1){1'b0}}, wptr};
	assign overflow_o = overflow_q;

endmodule

`default_nettype wire
