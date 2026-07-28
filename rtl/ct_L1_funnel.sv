// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    ct_L1_funnel.sv
 * @brief   Packet-aware CEDARtools.TraceEncoder L1 funnel for fixed-width ATB/Nexus streams
 *
 * @details
 *   - Merges N ATB input streams into one ATB output stream
 *   - Implements a deterministic fixed-width reference configuration only
 *   - Explicitly assumes 32-bit ATB beats and one 32-bit logical chunk per beat
 *   - Detects packet boundaries from the chunk-local Nexus MSEO bits only
 *   - Uses strict priority across priority levels and round-robin within a level
 *   - Never switches channels in the middle of a packet
 *   - Always emits full 4-byte beats with ATBYTES indicating 4 valid bytes
 *   - Provides per-channel flush requests plus global flush coordination
 *
 *   Flush signal mapping note:
 *   - On input channels (funnel = ATB slave), `afvalid` is driven by the funnel
 *     toward the source and therefore acts as "flush request to source".
 *   - On input channels, `afready` is driven by the source toward the funnel and
 *     therefore acts as "flush acknowledge / completion from source".
 *   - On the output channel (funnel = ATB master), `afvalid` is observed from the
 *     downstream side and is treated as an external global flush request.
 *   - On the output channel, `afready` is driven by the funnel and is treated as
 *     the global flush completion indication.
 */

module ct_L1_funnel #(
	int N_STREAMS  = 4,
	int MAX_PRIO   = 3,
	int MSEO_WIDTH = 2
) (
	input  uwire logic atclk,
	input  uwire logic atresetn,
	input  uwire logic [$clog2(MAX_PRIO+1)-1:0] chan_prio [N_STREAMS],
	input  uwire logic                           chan_flush_participate [N_STREAMS],
	input  uwire logic                           chan_flush_req [N_STREAMS],
	input  uwire logic                           global_flush_req,
	output logic                           chan_flush_done [N_STREAMS],
	output logic                           global_flush_done,
	atb_if.slave                           atb_in [N_STREAMS],
	atb_if.master                          atb_out
);

	import atb_pkg::*;
	import nexus::*;

	localparam int ATB_DATA_WIDTH    = atb_pkg::ATDATA_WIDTH;
	localparam int ATB_BYTES_WIDTH   = atb_pkg::ATBYTES_WIDTH;
	localparam int ATB_ID_WIDTH      = atb_pkg::ATID_WIDTH;
	localparam int LOGICAL_CHUNK_W   = 32;
	localparam int BEAT_BYTES        = 4;
	localparam int CHUNK_BYTES       = 4;
	localparam int IDX_W             = (N_STREAMS > 1) ? $clog2(N_STREAMS) : 1;
	localparam int PRIO_W            = (MAX_PRIO > 0) ? $clog2(MAX_PRIO+1) : 1;

	typedef struct packed {
		logic has_data;
		logic start_seen;
		logic end_seen;
		logic packet_done;
		logic in_packet_next;
	} beat_parse_t;

	typedef struct packed {
		logic [29:0] payload;
		nexus_mseo_e mseo;
	} funnel_chunk_t;

	logic [N_STREAMS-1:0] active_cfg;
	logic [N_STREAMS-1:0] flush_participates;
	logic [N_STREAMS-1:0] GlobalAckSeenQ       = '0;
	logic [N_STREAMS-1:0] LocalAckSeenQ        = '0;
	logic [N_STREAMS-1:0] normal_eligible;
	logic [N_STREAMS-1:0] flush_sched_eligible;
	logic [N_STREAMS-1:0] InPacketQ            = '0;
	logic [IDX_W-1:0]     SelectedIdxQ         = '0;
	logic                 SelectedValidQ       = 1'b0;
	logic [IDX_W-1:0]     RrHeadQ [0:MAX_PRIO] = '{default: '0};
	logic [IDX_W-1:0]     FlushRrHeadQ         = '0;
	logic                 GlobalFlushActiveQ   = 1'b0;

	logic [ATB_DATA_WIDTH-1:0]  in_atdata [N_STREAMS];
	logic [ATB_BYTES_WIDTH-1:0] in_atbytes [N_STREAMS];
	logic [ATID_WIDTH-1:0]      in_atid [N_STREAMS];
	logic                       in_atvalid [N_STREAMS];
	logic                       in_afready [N_STREAMS];
	logic                       out_atready_to_in [N_STREAMS];
	logic                       out_afvalid_to_in [N_STREAMS];
	logic                       out_syncreq_to_in [N_STREAMS];
	logic [ATB_DATA_WIDTH-1:0]  out_atdata;
	logic [ATB_BYTES_WIDTH-1:0] out_atbytes;
	logic [ATID_WIDTH-1:0]      out_atid;
	logic                       out_atvalid;
	logic                       out_afready;

	beat_parse_t          preview_parse [N_STREAMS];
	beat_parse_t          selected_xfer_parse;
	logic                 global_flush_active;
	logic                 global_flush_rise;
	logic [N_STREAMS-1:0] global_flush_pending;
	logic [N_STREAMS-1:0] local_flush_pending;
	logic                 any_flush_sched_eligible;
	logic                 current_locked;
	logic                 xfer_curr;
	logic                 keep_current;
	logic [IDX_W-1:0]     arb_idx;
	logic                 arb_valid;
	logic [PRIO_W-1:0]    arb_prio;
	logic                 arb_is_flush;
	logic                 all_global_participants_done;

	logic [IDX_W-1:0]     dbg_selected_idx;
	logic                 dbg_selected_valid;
	logic                 dbg_curr_in_packet;
	logic                 dbg_any_flush_pending;
	logic                 dbg_global_flush_done;

	generate
		for (genvar gi = 0; gi < N_STREAMS; gi++) begin : g_if_map
			assign in_atdata[gi] = atb_in[gi].atdata;
			assign in_atbytes[gi] = atb_in[gi].atbytes;
			assign in_atid[gi] = atb_in[gi].atid;
			assign in_atvalid[gi] = atb_in[gi].atvalid;
			assign in_afready[gi] = atb_in[gi].afready;
			assign atb_in[gi].atready = out_atready_to_in[gi];
			assign atb_in[gi].afvalid = out_afvalid_to_in[gi];
			assign atb_in[gi].syncreq = out_syncreq_to_in[gi];
		end
	endgenerate

	assign atb_out.atdata = out_atdata;
	assign atb_out.atbytes = out_atbytes;
	assign atb_out.atid = out_atid;
	assign atb_out.atvalid = out_atvalid;
	assign atb_out.afready = out_afready;

	initial begin
		if (MSEO_WIDTH != 2) begin
			$fatal(1, "ct_L1_funnel requires MSEO_WIDTH == 2, got %0d", MSEO_WIDTH);
		end
		if (ATB_DATA_WIDTH != 32) begin
			$fatal(1, "ct_L1_funnel fixed-width reference requires ATDATA_WIDTH == 32, got %0d", ATB_DATA_WIDTH);
		end
		if ((1 << ATB_BYTES_WIDTH) < BEAT_BYTES) begin
			$fatal(1, "ATBYTES width %0d cannot encode %0d beat bytes", ATB_BYTES_WIDTH, BEAT_BYTES);
		end
		if (LOGICAL_CHUNK_W != 32) begin
			$fatal(1, "ct_L1_funnel fixed-width reference requires a 32-bit logical chunk");
		end
		if (CHUNK_BYTES != BEAT_BYTES) begin
			$fatal(1, "ct_L1_funnel requires one logical chunk per ATB beat");
		end
	end

	function automatic beat_parse_t parse_beat(
		input logic [ATB_DATA_WIDTH-1:0] data,
		input logic                      in_packet_i
	);
		beat_parse_t result;
		funnel_chunk_t chunk;

		chunk = funnel_chunk_t'(data);

		result.has_data = in_packet_i;
		result.start_seen = 1'b0;
		result.end_seen = 1'b0;
		result.packet_done = 1'b0;
		result.in_packet_next = in_packet_i;

		unique case (chunk.mseo)
			START_TRANSMISSION: begin
				result.has_data = 1'b1;
				result.start_seen = 1'b1;
				result.in_packet_next = 1'b1;
			end

			END_IDLE: begin
				if (in_packet_i) begin
					result.has_data = 1'b1;
					result.end_seen = 1'b1;
					result.packet_done = 1'b1;
					result.in_packet_next = 1'b0;
				end else begin
					result.has_data = 1'b0;
				end
			end

			default: begin
				result.has_data = in_packet_i;
			end
		endcase

		return result;
	endfunction

	function automatic int pick_rr(
		input logic [N_STREAMS-1:0] candidates,
		input int unsigned          start_idx
	);
		int offs;
		int idx;

		pick_rr = -1;
		for (offs = 0; offs < N_STREAMS; offs = offs + 1) begin
			idx = (start_idx + offs) % N_STREAMS;
			if (candidates[idx]) begin
				pick_rr = idx;
				break;
			end
		end
	endfunction

	always_comb begin
		int i;

		global_flush_active = global_flush_req || atb_out.afvalid;
		global_flush_rise = global_flush_active && !GlobalFlushActiveQ;
		all_global_participants_done = 1'b1;

		for (i = 0; i < N_STREAMS; i = i + 1) begin
			preview_parse[i] = parse_beat(in_atdata[i], InPacketQ[i]);
			active_cfg[i] = (chan_prio[i] != PRIO_W'(0));
			flush_participates[i] = active_cfg[i] && chan_flush_participate[i];
			local_flush_pending[i] = chan_flush_req[i] && !LocalAckSeenQ[i];
			global_flush_pending[i] = global_flush_active && flush_participates[i] && !GlobalAckSeenQ[i];
			normal_eligible[i] = active_cfg[i] && in_atvalid[i] && preview_parse[i].has_data;
			flush_sched_eligible[i] = active_cfg[i] && in_atvalid[i] && preview_parse[i].has_data
			                       && (local_flush_pending[i] || global_flush_pending[i]);

			if (SelectedValidQ && xfer_curr && (SelectedIdxQ == IDX_W'(i))) begin
				normal_eligible[i] = 1'b0;
				flush_sched_eligible[i] = 1'b0;
			end

			if (flush_participates[i] && !GlobalAckSeenQ[i]) begin
				all_global_participants_done = 1'b0;
			end
		end

		any_flush_sched_eligible = |flush_sched_eligible;
		global_flush_done = global_flush_active && all_global_participants_done;
		dbg_any_flush_pending = |(local_flush_pending | global_flush_pending);
		dbg_global_flush_done = global_flush_done;
	end

	always_comb begin
		int i;
		int pr;
		int sel_idx;
		logic [N_STREAMS-1:0] prio_candidates;

		arb_valid = 1'b0;
		arb_idx = '0;
		arb_prio = '0;
		arb_is_flush = 1'b0;

		for (pr = MAX_PRIO; pr >= 1; pr = pr - 1) begin
			prio_candidates = '0;
			for (i = 0; i < N_STREAMS; i = i + 1) begin
				prio_candidates[i] = normal_eligible[i] && (chan_prio[i] == PRIO_W'(pr));
			end
			if (|prio_candidates) begin
				sel_idx = pick_rr(prio_candidates, RrHeadQ[pr]);
				if (sel_idx >= 0) begin
					arb_valid = 1'b1;
					arb_idx = IDX_W'(sel_idx);
					arb_prio = PRIO_W'(pr);
					arb_is_flush = 1'b0;
				end
				break;
			end
		end
	end

	always_comb begin
		selected_xfer_parse = parse_beat('0, 1'b0);
		if (SelectedValidQ) begin
			selected_xfer_parse = parse_beat(in_atdata[SelectedIdxQ], InPacketQ[SelectedIdxQ]);
		end

		xfer_curr = SelectedValidQ && in_atvalid[SelectedIdxQ]
		         && selected_xfer_parse.has_data && atb_out.atready;

		if (xfer_curr) begin
			current_locked = SelectedValidQ && selected_xfer_parse.in_packet_next;
		end else begin
			current_locked = SelectedValidQ
			              && (InPacketQ[SelectedIdxQ]
			               || (in_atvalid[SelectedIdxQ] && selected_xfer_parse.start_seen));
		end

		keep_current = current_locked;

		dbg_selected_idx = SelectedIdxQ;
		dbg_selected_valid = SelectedValidQ;
		dbg_curr_in_packet = SelectedValidQ ? InPacketQ[SelectedIdxQ] : 1'b0;
	end

	always_ff @(posedge atclk) begin
		int i;
		int pr;

		if (!atresetn) begin
			SelectedValidQ <= 1'b0;
			SelectedIdxQ <= '0;
			FlushRrHeadQ <= '0;
			GlobalFlushActiveQ <= 1'b0;
			for (pr = 0; pr <= MAX_PRIO; pr = pr + 1) begin
				RrHeadQ[pr] <= '0;
			end
			for (i = 0; i < N_STREAMS; i = i + 1) begin
				InPacketQ[i] <= 1'b0;
				LocalAckSeenQ[i] <= 1'b0;
				GlobalAckSeenQ[i] <= 1'b0;
			end
		end else begin
			GlobalFlushActiveQ <= global_flush_active;

			for (i = 0; i < N_STREAMS; i = i + 1) begin
				if (!chan_flush_req[i]) begin
					LocalAckSeenQ[i] <= 1'b0;
				end else if (in_afready[i]) begin
					LocalAckSeenQ[i] <= 1'b1;
				end

				if (!global_flush_active) begin
					GlobalAckSeenQ[i] <= 1'b0;
				end else if (global_flush_rise && flush_participates[i]) begin
					GlobalAckSeenQ[i] <= 1'b0;
				end else if (global_flush_rise && !flush_participates[i]) begin
					GlobalAckSeenQ[i] <= 1'b1;
				end else if (global_flush_active && !flush_participates[i]) begin
					GlobalAckSeenQ[i] <= 1'b1;
				end else if (in_afready[i]) begin
					GlobalAckSeenQ[i] <= 1'b1;
				end
			end

			if (xfer_curr) begin
				InPacketQ[SelectedIdxQ] <= selected_xfer_parse.in_packet_next;

				if (selected_xfer_parse.packet_done) begin
					if (flush_sched_eligible[SelectedIdxQ]) begin
						FlushRrHeadQ <= IDX_W'((SelectedIdxQ + 1'b1) % N_STREAMS);
					end
					if (chan_prio[SelectedIdxQ] != PRIO_W'(0)) begin
						RrHeadQ[chan_prio[SelectedIdxQ]] <= IDX_W'((SelectedIdxQ + 1'b1) % N_STREAMS);
					end
				end
			end

			if (keep_current) begin
				SelectedValidQ <= SelectedValidQ;
				SelectedIdxQ <= SelectedIdxQ;
			end else begin
				SelectedValidQ <= arb_valid;
				SelectedIdxQ <= arb_idx;
			end
		end
	end

	always_comb begin
		int i;

		for (i = 0; i < N_STREAMS; i = i + 1) begin
			out_atready_to_in[i] = 1'b0;
			out_afvalid_to_in[i] = (chan_flush_req[i] && !LocalAckSeenQ[i])
			                   || (global_flush_active && flush_participates[i] && !GlobalAckSeenQ[i]);
			out_syncreq_to_in[i] = atb_out.syncreq;
			chan_flush_done[i] = chan_flush_req[i] && LocalAckSeenQ[i];
		end

		out_atdata = '0;
		out_atbytes = ATB_BYTES_WIDTH'(BEAT_BYTES - 1);
		out_atid = '0;
		out_atvalid = 1'b0;
		out_afready = global_flush_done;

		if (SelectedValidQ) begin
			out_atready_to_in[SelectedIdxQ] = atb_out.atready && selected_xfer_parse.has_data;
			out_atdata = in_atdata[SelectedIdxQ];
			out_atid = in_atid[SelectedIdxQ];
			out_atvalid = in_atvalid[SelectedIdxQ] && selected_xfer_parse.has_data;
		end
	end

`ifndef SYNTHESIS
	always_ff @(posedge atclk) begin
		int i;

		if (atresetn) begin
			if (SelectedValidQ) begin
				assert (chan_prio[SelectedIdxQ] != PRIO_W'(0)
				     || InPacketQ[SelectedIdxQ]
				     || (xfer_curr && selected_xfer_parse.in_packet_next))
					else $error("ct_L1_funnel: selected channel has priority 0 outside an active packet continuation");
			end

			for (i = 0; i < N_STREAMS; i = i + 1) begin
				if (!SelectedValidQ || (SelectedIdxQ != IDX_W'(i))) begin
					assert (out_atready_to_in[i] == 1'b0)
						else $error("ct_L1_funnel: non-selected channel %0d observed ATREADY", i);
				end
			end

			if (atb_out.atvalid && SelectedValidQ) begin
				assert (atb_out.atdata == in_atdata[SelectedIdxQ])
					else $error("ct_L1_funnel: ATDATA mismatch to selected input");
				assert (atb_out.atbytes == ATB_BYTES_WIDTH'(BEAT_BYTES - 1))
					else $error("ct_L1_funnel: ATBYTES mismatch for fixed-width output");
				assert (atb_out.atid == in_atid[SelectedIdxQ])
					else $error("ct_L1_funnel: ATID mismatch to selected input");

				if (InPacketQ[SelectedIdxQ]) begin
					assert (SelectedIdxQ == dbg_selected_idx)
						else $error("ct_L1_funnel: channel switched during packet continuation");
				end
			end

			if (global_flush_done) begin
				assert (all_global_participants_done)
					else $error("ct_L1_funnel: global flush done asserted before all participants completed");
			end
		end
	end
`endif

endmodule

`default_nettype wire