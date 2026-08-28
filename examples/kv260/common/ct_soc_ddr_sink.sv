// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    DDR4 trace sink: observes the (funnel-merged) ATB beat stream and
 *           writes it into PS DDR via an AXI4 write-only master (S_AXI_HP).
 *
 * @details
 *   Additive observer -- NEVER back-pressures the trace path (the URAM ring
 *   stays the always-ready primary sink). Beats are buffered in a small FIFO;
 *   if the FIFO or the DDR buffer is full, incoming beats are dropped and
 *   counted (drops_o, saturating) instead of stalling.
 *
 *   Write policy (single-clock, AXI4 INCR, 32-bit beats):
 *     - address 32-byte aligned  -> 8-beat burst as soon as >= 8 words queued
 *     - otherwise                -> single-beat until re-aligned
 *   This keeps every burst inside a 4-KiB page by construction (base must be
 *   32-byte aligned; software contract, checked by masking).
 *
 *   Buffer model (circ_i=0, one shot): LINEAR capture from base_i, size_i
 *   bytes. When full, full_o sets and further beats are dropped (host reads
 *   [base, base+wptr)).
 *
 *   Buffer model (circ_i=1, circular): the write offset wraps modulo size_i
 *   (bursts never cross the buffer end -- the engine falls back to single
 *   beats near the end, so the wrap lands exactly on offset 0). full_o stays
 *   0, wrapped_o latches after the first wrap. wptr_o keeps counting TOTAL
 *   bytes monotonically; the host derives the write offset as
 *   wptr_o % size_i and re-orders [off..size) ++ [0..off) when wrapped
 *   (same contract as the URAM ring). Switch circ_i only while cleared.
 *
 *   clear_i (pulse, only sensible while enable_i=0) resets
 *   wptr/full/wrapped/drops.
 *
 *   bresp != OKAY sets the sticky axi_err_o (cleared by clear_i).
 *
 *   Window guard (U6, closes B-C1-1): the engine only ever issues a burst
 *   while off_q < size_i. In legal operation that is an invariant -- it can
 *   only be violated by shrinking size_i BELOW the current write offset while
 *   the sink runs, and then bytes_left = size_i - off_q underflows (unsigned)
 *   and used to let exactly one transfer escape the buffer (byte-exactly
 *   measured, docs/handoffs/C1_sink_overrun.md §5). The guard costs one
 *   comparator, changes nothing in legal operation, and turns the escape into
 *   a stall that the drop counter makes visible. The documented order stays
 *   the same: disable -> clear -> base/size -> enable.
 */
module ct_soc_ddr_sink #(
	int unsigned FIFO_WORDS = 512
) (
	input  uwire logic        clk,
	input  uwire logic        rst,

	input  uwire logic        enable_i,
	input  uwire logic        clear_i,
	input  uwire logic [31:0] base_i,       // byte address in PS DDR (32-byte aligned)
	input  uwire logic [31:0] size_i,       // buffer size in bytes (multiple of 4)
	input  uwire logic        circ_i,       // 1: circular (wrap), 0: one shot

	// ATB beat observer (already-accepted beats: valid means "captured")
	input  uwire logic        beat_valid_i,
	input  uwire logic [31:0] beat_data_i,

	output logic [31:0]       wptr_o,       // TOTAL bytes written (monotonic)
	output logic              full_o,       // one shot only: buffer full
	output logic              wrapped_o,    // circular only: wrapped at least once
	output logic              axi_err_o,
	output logic [31:0]       drops_o,

	// AXI4 write-only master (to PS S_AXI_HP*_FPD, 32-bit data)
	output logic [31:0]       m_axi_awaddr,
	output logic [7:0]        m_axi_awlen,
	output logic [2:0]        m_axi_awsize,
	output logic [1:0]        m_axi_awburst,
	output logic              m_axi_awvalid,
	input  uwire logic        m_axi_awready,
	output logic [31:0]       m_axi_wdata,
	output logic [3:0]        m_axi_wstrb,
	output logic              m_axi_wlast,
	output logic              m_axi_wvalid,
	input  uwire logic        m_axi_wready,
	input  uwire logic [1:0]  m_axi_bresp,
	input  uwire logic        m_axi_bvalid,
	output logic              m_axi_bready
);

	localparam int unsigned AW = $clog2(FIFO_WORDS);

	// ------------------------------------------------------------------
	// Beat FIFO (simple synchronous, BRAM-inferable)
	// ------------------------------------------------------------------
	logic [31:0] fifo_mem [0:FIFO_WORDS-1];
	logic [AW:0] wr_ptr, rd_ptr;
	uwire logic [AW:0] fill = wr_ptr - rd_ptr;
	uwire logic fifo_full  = (fill == FIFO_WORDS[AW:0]);
	uwire logic fifo_empty = (fill == 0);

	// registered FIFO read data (1-cycle latency, consumed by the W channel)
	logic [31:0] rd_data_q;

	// ------------------------------------------------------------------
	// Space accounting. off_q = write offset into the buffer (wraps at
	// size_i in circular mode; equals wptr_o in one-shot mode). Bursts
	// never cross the buffer end, so a wrap lands exactly on offset 0.
	// ------------------------------------------------------------------
	logic [31:0] off_q;
	uwire logic [31:0] bytes_left = size_i - off_q;
	// Invariant in legal operation; false only after an illegal live shrink
	// (see "Window guard" in the header). Gating both room terms with it means
	// the engine stops instead of writing outside [base, base+size).
	uwire logic        in_window = (off_q < size_i);
	uwire logic        room1  = enable_i && !full_o && in_window &&
	                            (circ_i ? (size_i >= 32'd4) : (bytes_left >= 32'd4));
	uwire logic        room8  = enable_i && !full_o && in_window && (bytes_left >= 32'd32);
	uwire logic        addr_aligned32 = ((base_i + off_q) & 32'h1F) == 0;

	// accept a beat only if it can ever be written (enable + space); count
	// everything else as a drop so the host sees the loss explicitly.
	uwire logic accept = beat_valid_i && enable_i && !fifo_full && !full_o;
	uwire logic dropped = beat_valid_i && enable_i && (fifo_full || full_o);

	always_ff @(posedge clk) begin
		if (rst) begin
			wr_ptr <= '0;
		end
		else if (clear_i && !enable_i) begin
			wr_ptr <= '0;
		end
		else if (accept) begin
			fifo_mem[wr_ptr[AW-1:0]] <= beat_data_i;
			wr_ptr <= wr_ptr + 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// AXI write engine
	// ------------------------------------------------------------------
	typedef enum logic [1:0] { S_IDLE, S_AW, S_W, S_B } st_e;
	st_e st;
	logic [3:0] burst_len;     // beats in current burst (1 or 8)
	logic [3:0] beat_ix;
	logic [31:0] wcount_bytes; // bytes of current burst (for wptr update at B)

	assign m_axi_awsize  = 3'b010;      // 4 bytes
	assign m_axi_awburst = 2'b01;       // INCR
	assign m_axi_wstrb   = 4'hF;
	assign m_axi_bready  = (st == S_B);

	// launch condition evaluated in S_IDLE
	uwire logic can_burst8  = room8 && addr_aligned32 && (fill >= 8);
	uwire logic can_single  = room1 && !fifo_empty;

	always_ff @(posedge clk) begin
		if (rst) begin
			st <= S_IDLE;
			rd_ptr <= '0;
			m_axi_awvalid <= 1'b0; m_axi_awaddr <= '0; m_axi_awlen <= '0;
			m_axi_wvalid <= 1'b0; m_axi_wlast <= 1'b0; m_axi_wdata <= '0;
			burst_len <= 4'd1; beat_ix <= '0; wcount_bytes <= '0;
			wptr_o <= '0; full_o <= 1'b0; axi_err_o <= 1'b0; drops_o <= '0;
			off_q <= '0; wrapped_o <= 1'b0;
			rd_data_q <= '0;
		end
		else begin
			if (clear_i && !enable_i && st == S_IDLE) begin
				// U6 FIX: '0, not wr_ptr. The write pointer is reset to 0 in
				// the block above IN THE SAME CYCLE, so "rd_ptr <= wr_ptr"
				// sampled the OLD value and left the two pointers maximally
				// inconsistent: fill = 0 - old_wr = 2**(AW+1) - old_wr, i.e.
				// the FIFO reads nearly FULL right after a clear and the
				// engine flushes up to 2**(AW+1)-1 stale words into the fresh
				// buffer -- re-reading the memory once when it wraps, which
				// duplicates them. That is the leftover-flush the board script
				// papers over with a second clear (rocket2_linux_run.sh:397,
				// M7 E-1, translated: "every capture begins with the tail end
				// of its predecessor ... duplicated at the 2-KiB boundary" --
				// 2 KiB = 512 words = exactly one FIFO wrap). Measured in
				// sim/board_kv260/tb_ddr_sink_window.sv phase 3.
				rd_ptr <= '0;                  // discard queued beats
				wptr_o <= '0; full_o <= 1'b0; axi_err_o <= 1'b0; drops_o <= '0;
				off_q <= '0; wrapped_o <= 1'b0;
			end

			if (dropped && drops_o != 32'hFFFF_FFFF)
				drops_o <= drops_o + 1'b1;

			case (st)
				S_IDLE: begin
					if (can_burst8 || can_single) begin
						burst_len <= can_burst8 ? 4'd8 : 4'd1;
						wcount_bytes <= can_burst8 ? 32'd32 : 32'd4;
						m_axi_awaddr <= base_i + off_q;
						m_axi_awlen <= can_burst8 ? 8'd7 : 8'd0;
						m_axi_awvalid <= 1'b1;
						beat_ix <= 4'd0;
						// prefetch first word
						rd_data_q <= fifo_mem[rd_ptr[AW-1:0]];
						rd_ptr <= rd_ptr + 1'b1;
						st <= S_AW;
					end
				end
				S_AW: if (m_axi_awready) begin
					m_axi_awvalid <= 1'b0;
					m_axi_wdata <= rd_data_q;
					m_axi_wvalid <= 1'b1;
					m_axi_wlast <= (burst_len == 4'd1);
					beat_ix <= 4'd1;
					if (burst_len != 4'd1) begin  // prefetch next
						rd_data_q <= fifo_mem[rd_ptr[AW-1:0]];
						rd_ptr <= rd_ptr + 1'b1;
					end
					st <= S_W;
				end
				S_W: if (m_axi_wready) begin
					if (m_axi_wlast) begin
						m_axi_wvalid <= 1'b0;
						m_axi_wlast <= 1'b0;
						st <= S_B;
					end
					else begin
						m_axi_wdata <= rd_data_q;
						m_axi_wlast <= (beat_ix == burst_len - 1);
						beat_ix <= beat_ix + 1'b1;
						if (beat_ix != burst_len - 1) begin
							rd_data_q <= fifo_mem[rd_ptr[AW-1:0]];
							rd_ptr <= rd_ptr + 1'b1;
						end
					end
				end
				S_B: if (m_axi_bvalid) begin
					if (m_axi_bresp != 2'b00) axi_err_o <= 1'b1;
					wptr_o <= wptr_o + wcount_bytes;
					if (circ_i) begin
						// bursts never cross the end -> wrap hits exactly size_i
						if (off_q + wcount_bytes >= size_i) begin
							off_q <= (off_q + wcount_bytes) - size_i;
							wrapped_o <= 1'b1;
						end
						else off_q <= off_q + wcount_bytes;
					end
					else begin
						off_q <= off_q + wcount_bytes;
						if ((size_i - (off_q + wcount_bytes)) < 32'd4)
							full_o <= 1'b1;
					end
					st <= S_IDLE;
				end
				default: st <= S_IDLE;
			endcase
		end
	end

`ifndef SYNTHESIS
	// U6 regression guard for the defect class B-C1-1: NO burst may leave the
	// configured buffer. Removing the in_window gate above makes this fire on
	// the shrink-while-running stimulus instead of silently corrupting memory
	// outside the reserved window.
	always_ff @(posedge clk) begin
		if (!rst && m_axi_awvalid) begin
			assert (m_axi_awaddr >= base_i &&
			        ((m_axi_awaddr - base_i) + ((32'(m_axi_awlen) + 32'd1) << 2)) <= size_i)
				else $error("ct_soc_ddr_sink: burst 0x%08x + %0d B leaves the window 0x%08x + 0x%08x",
				            m_axi_awaddr, (32'(m_axi_awlen) + 32'd1) << 2, base_i, size_i);
		end
	end
`endif

endmodule

`default_nettype wire
