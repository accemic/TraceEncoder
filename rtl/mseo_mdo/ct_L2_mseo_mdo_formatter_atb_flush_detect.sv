// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Albert Schulz <aschulz@accemic.com>
 *
 * @brief    ATB-domain flush detector
 *
 * @details
 *   Watches transmitted ATB chunks for the legacy flush marker and holds
 *   `afready` high until the external flush request is released.
 */

module ct_L2_mseo_mdo_formatter_atb_flush_detect #(
	int unsigned MDO_WIDTH  = 4, // number of MDO payload bits per chunk
	int unsigned MSEO_WIDTH = 2  // number of MSEO bits per chunk
) (
	input uwire logic                      clk,
	input uwire logic                      rst,
	input uwire logic                      atvalid,
	input uwire logic                      afvalid,
	input uwire logic [((atb_pkg::ATDATA_WIDTH >= (MDO_WIDTH+MSEO_WIDTH))
		? (atb_pkg::ATDATA_WIDTH / (MDO_WIDTH+MSEO_WIDTH))
		: 1) * (MDO_WIDTH+MSEO_WIDTH)-1:0] atb_payload,
	output uwire logic                     afready
);
	localparam int unsigned CHUNK_WIDTH = MDO_WIDTH + MSEO_WIDTH;
	localparam int unsigned NUM_CHUNKS_PER_ATB_BEAT =
		(atb_pkg::ATDATA_WIDTH >= CHUNK_WIDTH) ? (atb_pkg::ATDATA_WIDTH / CHUNK_WIDTH) : 1;
	localparam logic [MSEO_WIDTH-1:0] MSEO_END_IDLE = 2'b11;
	localparam logic [CHUNK_WIDTH-1:0] CHUNK_ALIGN_PAD = {{MDO_WIDTH{1'b1}}, MSEO_END_IDLE};
	localparam logic [CHUNK_WIDTH-1:0] CHUNK_FLUSH_PAD = {{MDO_WIDTH{1'b1}}, MSEO_END_IDLE};

	typedef enum logic [1:0] {
		S_IDLE             = 2'd0,
		S_WAIT_IS_FLUSHED  = 2'd1,
		S_WAIT_AFVALID_LOW = 2'd2
	} flush_state_t;

	flush_state_t           FlushState = S_IDLE;
	logic [CHUNK_WIDTH-1:0] PrevChunk = CHUNK_ALIGN_PAD;
	logic                   flush_marker_seen;

	always_comb begin
		logic [CHUNK_WIDTH-1:0] prev_chunk;
		logic [CHUNK_WIDTH-1:0] curr_chunk;

		flush_marker_seen = 1'b0;
		for (int Idx = 0; Idx < NUM_CHUNKS_PER_ATB_BEAT; Idx++) begin
			prev_chunk = (Idx == 0) ? PrevChunk : atb_payload[((Idx-1)*CHUNK_WIDTH) +: CHUNK_WIDTH];
			curr_chunk = atb_payload[(Idx*CHUNK_WIDTH) +: CHUNK_WIDTH];
			if (   (prev_chunk[MSEO_WIDTH-1:0] == MSEO_END_IDLE)
				&& (curr_chunk == CHUNK_FLUSH_PAD)) begin
				flush_marker_seen = 1'b1;
			end
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			FlushState <= S_IDLE;
			PrevChunk <= CHUNK_ALIGN_PAD;
		end
		else begin
			if (atvalid) begin
				PrevChunk <= atb_payload[((NUM_CHUNKS_PER_ATB_BEAT-1)*CHUNK_WIDTH) +: CHUNK_WIDTH];
			end

			unique case (FlushState)
				S_IDLE: begin
					if (afvalid) begin
						FlushState <= S_WAIT_IS_FLUSHED;
					end
				end
				S_WAIT_IS_FLUSHED: begin
					if (atvalid && flush_marker_seen) begin
						FlushState <= S_WAIT_AFVALID_LOW;
					end
				end
				S_WAIT_AFVALID_LOW: begin
					if (!afvalid) begin
						FlushState <= S_IDLE;
					end
				end
				default: begin
					FlushState <= S_IDLE;
				end
			endcase
		end
	end

	assign afready = (FlushState == S_WAIT_AFVALID_LOW);
endmodule

`default_nettype wire
