// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Albert Schulz <aschulz@accemic.com>
 *
 * @brief    Proc-domain Nexus chunk packer
 *
 * @details
 *   Packs MDO/MSEO chunks into ATB-width payloads, inserts alignment padding at
 *   end-of-message, and emits flush payload beats on request.
 */

module ct_L2_mseo_mdo_formatter_atb_chunk_packer #(
	int unsigned NEXUS_MAX_FIELDS = nexus_vendor::NEXUS_MAX_FIELDS, // max number of fields per nexus message
	int unsigned MDO_WIDTH        = 4,                              // number of MDO payload bits per chunk
	int unsigned MSEO_WIDTH       = 2                               // number of MSEO bits per chunk
) (
	input uwire logic                            clk,
	input uwire logic                            rst,
	input uwire logic                            atb_full,
	input uwire logic                            flush_start,
	input uwire logic                            slice_valid,
	input uwire logic                            end_of_message,
	input uwire logic [MDO_WIDTH+MSEO_WIDTH-1:0] chunk_in,
	output uwire logic                           slice_ready,
	output uwire logic                           idle,
	output logic                                 wr,
	output logic [((atb_pkg::ATDATA_WIDTH >= (MDO_WIDTH+MSEO_WIDTH))
		? (atb_pkg::ATDATA_WIDTH / (MDO_WIDTH+MSEO_WIDTH))
		: 1) * (MDO_WIDTH+MSEO_WIDTH)-1:0]       payload_out
);
	localparam int unsigned CHUNK_WIDTH = MDO_WIDTH + MSEO_WIDTH;
	localparam int unsigned NUM_CHUNKS_PER_ATB_BEAT =
		(atb_pkg::ATDATA_WIDTH >= CHUNK_WIDTH) ? (atb_pkg::ATDATA_WIDTH / CHUNK_WIDTH) : 1;
	localparam int unsigned CHUNK_IDX_W = (NUM_CHUNKS_PER_ATB_BEAT > 1) ? $clog2(NUM_CHUNKS_PER_ATB_BEAT) : 1;
	localparam int unsigned PAD_COUNT_W = (NUM_CHUNKS_PER_ATB_BEAT > 1) ? $clog2(NUM_CHUNKS_PER_ATB_BEAT + 1) : 1;
	localparam int unsigned FLUSH_CHUNK_COUNT =
		((NEXUS_MAX_FIELDS + (NUM_CHUNKS_PER_ATB_BEAT - 1)) / NUM_CHUNKS_PER_ATB_BEAT) * NUM_CHUNKS_PER_ATB_BEAT;
	localparam int unsigned FLUSH_BEAT_COUNT = FLUSH_CHUNK_COUNT / NUM_CHUNKS_PER_ATB_BEAT;
	localparam int unsigned FLUSH_COUNT_W = (FLUSH_BEAT_COUNT > 1) ? $clog2(FLUSH_BEAT_COUNT + 1) : 1;
	localparam logic [MSEO_WIDTH-1:0] MSEO_END_IDLE = 2'b11;
	localparam logic [CHUNK_WIDTH-1:0] CHUNK_ALIGN_PAD = {{MDO_WIDTH{1'b1}}, MSEO_END_IDLE};
	localparam logic [CHUNK_WIDTH-1:0] CHUNK_FLUSH_PAD = {{MDO_WIDTH{1'b1}}, MSEO_END_IDLE};

	logic                       FlushActive = 1'b0;
	logic [FLUSH_COUNT_W-1:0]   FlushBeatsRem = '0;
	logic                       PadActive = 1'b0;
	logic [PAD_COUNT_W-1:0]     PadRem = '0;
	logic [CHUNK_IDX_W-1:0]     ChunkIdx = '0;
	logic [CHUNK_WIDTH-1:0]     Payload [(NUM_CHUNKS_PER_ATB_BEAT)-1:0] = '{default: '0};

	uwire logic flush_send = FlushActive && !atb_full;
	uwire logic pad_send = PadActive && !atb_full;
	uwire logic slice_fire = slice_valid && slice_ready;

	assign slice_ready = !atb_full && !PadActive && !FlushActive;
	assign idle = !PadActive && !FlushActive && (ChunkIdx == '0);

	always_comb begin
		logic [CHUNK_WIDTH-1:0] PayloadNext [(NUM_CHUNKS_PER_ATB_BEAT)-1:0];

		PayloadNext = Payload;
		payload_out = '0;
		wr = 1'b0;

		if (flush_send) begin
			for (int Idx = 0; Idx < NUM_CHUNKS_PER_ATB_BEAT; Idx++) begin
				PayloadNext[Idx] = CHUNK_FLUSH_PAD;
			end
			wr = 1'b1;
		end
		else if (pad_send) begin
			PayloadNext[ChunkIdx] = CHUNK_ALIGN_PAD;
			wr = (ChunkIdx == (NUM_CHUNKS_PER_ATB_BEAT - 1));
		end
		else if (slice_fire) begin
			PayloadNext[ChunkIdx] = chunk_in;
			wr = (ChunkIdx == (NUM_CHUNKS_PER_ATB_BEAT - 1));
		end

		for (int Idx = 0; Idx < NUM_CHUNKS_PER_ATB_BEAT; Idx++) begin
			payload_out[(Idx*CHUNK_WIDTH) +: CHUNK_WIDTH] = PayloadNext[Idx];
		end
	end

	always_ff @(posedge clk) begin
		logic [CHUNK_IDX_W-1:0]     NextChunkIdx;
		logic [PAD_COUNT_W-1:0]     PadNeed;

		if (rst) begin
			FlushActive <= 1'b0;
			FlushBeatsRem <= '0;
			PadActive <= 1'b0;
			PadRem <= '0;
			ChunkIdx <= '0;
			Payload <= '{default: '0};
		end
		else begin
			if (pad_send) begin
				Payload[ChunkIdx] <= CHUNK_ALIGN_PAD;
			end
			else if (slice_fire) begin
				Payload[ChunkIdx] <= chunk_in;
			end

			if (flush_start) begin
				FlushActive <= 1'b1;
				FlushBeatsRem <= FLUSH_BEAT_COUNT[FLUSH_COUNT_W-1:0];
			end
			else if (flush_send) begin
				if (FlushBeatsRem == 1) begin
					FlushActive <= 1'b0;
					FlushBeatsRem <= '0;
				end
				else begin
					FlushBeatsRem <= FlushBeatsRem - 1'b1;
				end
			end

			if (pad_send) begin
				if (PadRem == 1) begin
					PadActive <= 1'b0;
					PadRem <= '0;
					ChunkIdx <= '0;
					Payload <= '{default: '0};
				end
				else begin
					PadRem <= PadRem - 1'b1;
					ChunkIdx <= ChunkIdx + 1'b1;
				end
			end
			else if (slice_fire) begin
				NextChunkIdx = (ChunkIdx == (NUM_CHUNKS_PER_ATB_BEAT - 1)) ? '0 : (ChunkIdx + 1'b1);
				if (end_of_message && (NextChunkIdx != '0)) begin
					PadNeed = NUM_CHUNKS_PER_ATB_BEAT - NextChunkIdx;
					PadActive <= (PadNeed != '0);
					PadRem <= PadNeed;
					ChunkIdx <= NextChunkIdx;
				end
				else begin
					ChunkIdx <= NextChunkIdx;
					if (NextChunkIdx == '0) begin
						Payload <= '{default: '0};
					end
				end
			end
		end
	end
endmodule

`default_nettype wire
