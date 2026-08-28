// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Encoder-AXIS (96 bit, no backpressure) to 32-bit AXIS shim
 *           with drop accounting, for the watchpoint/DAQ export path.
 *
 * @details
 *   The CTTE ACT-CAP/ACT-ST AXIS master never samples `tready` and drives
 *   neither `tkeep` nor `tlast` (FINDINGS_axis_wp_analyse.md, Teil W2
 *   §3.2) — every `s_tvalid` beat MUST be consumed in the same cycle or
 *   it is lost. This shim therefore:
 *
 *     - accepts each incoming beat into an internal FIFO (FIFO_DEPTH
 *       records of 116 bit = tdata+tstrb+tid); if the FIFO is full the
 *       beat is dropped, `drop_count` increments (saturating at
 *       32'hFFFF_FFFF) and `overflow_sticky` latches (cleared by `rst`
 *       only),
 *     - serializes each record as four 32-bit words on a fully
 *       handshaken AXI4-Stream master (stall-safe, no loss after FIFO
 *       admission, back-to-back capable):
 *
 *         word 0   s_tdata[31:0]    PC            (DAQ_PC_CURR element 0)
 *         word 1   s_tdata[63:32]   DirectData    (element 1)
 *         word 2   s_tdata[95:64]   Timestamp     (element 2, CT_EN_AXIS_TS)
 *         word 3   {8'h00, CORE_ID[3:0], s_tstrb[11:0], s_tid[7:0]}
 *                   [7:0] tid (ACT-CAP/ACT-ST command), [19:8] tstrb,
 *                   [23:20] core_id, [31:24] zero; `m_tlast` on word 3,
 *                   `m_tkeep` constant 4'hF.
 *
 *   `fill_level` reports the records currently held in the FIFO (the
 *   unload holding register is NOT included, so up to FIFO_DEPTH+1
 *   records are buffered before the first drop); the top level maps
 *   `drop_count`/`overflow_sticky`/`fill_level` into a CTRL window.
 *
 *   Single clock domain, synchronous active-high reset — no CDC (the
 *   downstream `axi_fifo_mm_s` runs on the same PL clock; any clock
 *   crossing is that IP's job, not this shim's).
 */

module ct_axis_wp_shim #(
	logic [3:0]  CORE_ID     = 4'd0,   // tagged into word 3 [23:20]
	int unsigned FIFO_DEPTH  = 256,    // records; power of two
	int unsigned TDATA_WIDTH = 96,     // fixed by the encoder AXIS master
	int unsigned TID_WIDTH   = 8,
	int unsigned TSTRB_WIDTH = 12
) (
	input  uwire logic                    clk,
	input  uwire logic                    rst,        // active-high, synchronous

	// Encoder AXIS (no tready towards the encoder — see @details)
	input  uwire logic                    s_tvalid,
	input  uwire logic [TDATA_WIDTH-1:0]  s_tdata,
	input  uwire logic [TSTRB_WIDTH-1:0]  s_tstrb,
	input  uwire logic [TID_WIDTH-1:0]    s_tid,

	// 32-bit AXIS master (towards axi_fifo_mm_s), full handshake
	output      logic                     m_tvalid,
	input  uwire logic                    m_tready,
	output      logic [31:0]              m_tdata,
	output      logic [3:0]               m_tkeep,
	output      logic                     m_tlast,

	// Status (top level maps these into a CTRL window)
	output      logic [31:0]              drop_count,       // saturating
	output      logic                     overflow_sticky,  // rst-cleared
	output      logic [31:0]              fill_level        // records in FIFO
);

	localparam int AW    = $clog2(FIFO_DEPTH);
	localparam int REC_W = TDATA_WIDTH + TSTRB_WIDTH + TID_WIDTH;   // 116

	// The word-3 layout and the 3x32-bit unload fix these widths
	// (elaboration-time checks, evaluated by sim and synth alike).
	if (TDATA_WIDTH != 96 || TSTRB_WIDTH != 12 || TID_WIDTH != 8) begin : g_bad_width
		$fatal(1, "ct_axis_wp_shim: unsupported width configuration");
	end
	if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_bad_depth
		$fatal(1, "ct_axis_wp_shim: FIFO_DEPTH must be a power of two >= 2");
	end

	// ------------------------------------------------------------------
	// Record FIFO (write side never stalls the encoder; full => drop)
	// ------------------------------------------------------------------
	(* ram_style = "block" *) logic [REC_W-1:0] mem [0:FIFO_DEPTH-1];

	logic [AW:0] wptr;      // one extra bit: wptr==rptr+DEPTH means full
	logic [AW:0] rptr;

	uwire logic empty = (wptr == rptr);
	uwire logic full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);

	uwire logic push  = s_tvalid && !full;
	uwire logic drop  = s_tvalid && full;

	// ------------------------------------------------------------------
	// Unload stage: pop one record, emit it as four handshaken words
	// ------------------------------------------------------------------
	logic             out_busy;     // holding register carries a record
	logic [1:0]       out_sel;      // word 0..3 of the current record
	logic [REC_W-1:0] out_rec;

	uwire logic out_take = m_tvalid && m_tready;
	uwire logic out_done = out_take && (out_sel == 2'd3);
	uwire logic pop      = !empty && (!out_busy || out_done);

	logic [31:0] drop_count_q;
	logic        overflow_q;

	always_ff @(posedge clk) begin
		if (rst) begin
			wptr         <= '0;
			rptr         <= '0;
			out_busy     <= 1'b0;
			out_sel      <= 2'd0;
			drop_count_q <= '0;
			overflow_q   <= 1'b0;
		end
		else begin
			if (push) begin
				mem[wptr[AW-1:0]] <= {s_tid, s_tstrb, s_tdata};
				wptr              <= wptr + (AW+1)'(1);
			end
			if (drop) begin
				overflow_q <= 1'b1;
				if (drop_count_q != 32'hFFFF_FFFF) begin
					drop_count_q <= drop_count_q + 32'd1;
				end
			end
			if (pop) begin
				out_rec  <= mem[rptr[AW-1:0]];
				rptr     <= rptr + (AW+1)'(1);
				out_busy <= 1'b1;
				out_sel  <= 2'd0;
			end
			else if (out_done) begin
				out_busy <= 1'b0;
			end
			else if (out_take) begin
				out_sel <= out_sel + 2'd1;
			end
		end
	end

	// Record fields (packed as {tid, tstrb, tdata} above)
	uwire logic [TDATA_WIDTH-1:0] rec_tdata = out_rec[TDATA_WIDTH-1:0];
	uwire logic [TSTRB_WIDTH-1:0] rec_tstrb = out_rec[TDATA_WIDTH +: TSTRB_WIDTH];
	uwire logic [TID_WIDTH-1:0]   rec_tid   = out_rec[TDATA_WIDTH+TSTRB_WIDTH +: TID_WIDTH];

	assign m_tvalid = out_busy;
	assign m_tkeep  = 4'hF;
	assign m_tlast  = out_busy && (out_sel == 2'd3);
	always_comb begin
		if (out_sel == 2'd3) begin
			m_tdata = {8'h00, CORE_ID, rec_tstrb, rec_tid};
		end
		else begin
			m_tdata = rec_tdata[out_sel*32 +: 32];
		end
	end

	assign drop_count      = drop_count_q;
	assign overflow_sticky = overflow_q;
	assign fill_level      = {{(32-AW-1){1'b0}}, wptr - rptr};

endmodule

`default_nettype wire
