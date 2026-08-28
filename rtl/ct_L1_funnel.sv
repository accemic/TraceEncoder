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
 *   - Assumes 32-bit ATB beats carrying an integer number of Nexus MDO/MSEO
 *     chunks (MDO_WIDTH parameter: 30 = one 32-bit chunk per beat, the
 *     historical fixed-width reference; 6/14 = the byte/halfword chunk
 *     configurations of the MSEO/MDO formatter, four/two chunks per beat)
 *   - Detects packet boundaries from the chunk-local Nexus MSEO bits only;
 *     relies on the chunk packer's end-of-message alignment padding, so a
 *     beat never carries the end of one message plus the start of the next
 *   - Uses strict priority across priority levels and round-robin within a level
 *   - Never switches channels in the middle of a packet
 *   - Always emits full 4-byte beats with ATBYTES indicating 4 valid bytes
 *   - Consumes and drops pure-idle beats (flush padding / repeated END_IDLE)
 *     on every active channel so they cannot wedge a source queue
 *   - Provides per-channel flush requests plus global flush coordination
 *
 *   Dual-protocol operation (EN_TE_RAW = 1, per channel via `chan_te_raw`):
 *   - A te_raw channel carries the E-Trace reference-raw framing produced by
 *     ct_L2_te_packetizer: one byte per beat (atbytes = 0), packet = header
 *     byte {1'b0, msg_type[1:0], payload_len[4:0]} followed by payload_len
 *     payload bytes. Packet boundaries come from that length, not from MSEO,
 *     and there are no idle beats.
 *   - Because the reference-raw framing has no source field (and the on-chip
 *     ring stores ATDATA only, so ATID is lost), the funnel makes the merged
 *     byte stream self-describing by inserting a SOURCE TAG byte
 *     `8'h80 | channel index` ahead of a packet. Payload bytes may have bit 7
 *     set, so the tag is only unambiguous to a state machine that starts at a
 *     packet boundary -- which is exactly what the demultiplexer does
 *     (examples/kv260/trio/tools/etrace_trio_demux.py). Tags are emitted on
 *     every source change (default) or before every packet
 *     (`te_tag_always`).
 *   - The container is called CTMX; splitting it yields per-source byte
 *     streams that are byte-identical to a single-core capture and therefore
 *     consumable by an unmodified E-Trace reference decoder.
 *   - Mixed operation is legal: an MSEO channel and a te_raw channel may be
 *     merged in the same session (the tag disambiguates the te_raw part).
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
	int MSEO_WIDTH = 2,
	int MDO_WIDTH  = 30,
	// Elaboration switch for the E-Trace (te_inst raw) framing support.
	// 0 = Nexus/MSEO only: every te_raw input tie is constant-folded away and
	// the netlist is identical to the historical funnel.
	bit EN_TE_RAW  = 0
) (
	input  uwire logic                          atclk,
	input  uwire logic                          atresetn,
	input  uwire logic [$clog2(MAX_PRIO+1)-1:0] chan_prio              [N_STREAMS],
	input  uwire logic                          chan_flush_participate [N_STREAMS],
	input  uwire logic                          chan_flush_req         [N_STREAMS],
	// Per-channel framing select (quasi-static, mirror of that source's
	// trTeProtocolSel): 0 = Nexus MSEO chunks, 1 = E-Trace reference-raw
	// te_inst framing (1 byte per beat, header = msg_type|payload_len).
	input  uwire logic                          chan_te_raw            [N_STREAMS],
	// 1 = emit the source tag before EVERY te_raw packet (self-describing,
	// wrap-resync friendly), 0 = only when the source changes (minimal
	// overhead; requires a capture that starts at a packet boundary).
	input  uwire logic                          te_tag_always,
	// Level: forget which source was tagged last, so the next packet carries
	// a tag again. Wire this to whatever re-arms the capture (sink clear) --
	// otherwise a capture started mid-stream begins without a source tag.
	input  uwire logic                          te_tag_resync,
	input  uwire logic                          global_flush_req,
	output logic                                chan_flush_done        [N_STREAMS],
	output logic                                global_flush_done,
	atb_if.slave                                atb_in                 [N_STREAMS],
	atb_if.master                               atb_out
);

	import atb_pkg::*;
	import nexus::*;

	localparam int ATB_DATA_WIDTH    = atb_pkg::ATDATA_WIDTH;
	localparam int ATB_BYTES_WIDTH   = atb_pkg::ATBYTES_WIDTH;
	localparam int ATB_ID_WIDTH      = atb_pkg::ATID_WIDTH;
	localparam int CHUNK_W           = MDO_WIDTH + MSEO_WIDTH;
	localparam int CHUNKS_PER_BEAT   = ATB_DATA_WIDTH / CHUNK_W;
	localparam int BEAT_BYTES        = 4;
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
		logic [MDO_WIDTH-1:0] payload;
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
	// te_raw framing state: payload bytes still owed per channel, plus the
	// source-tag bookkeeping of the merged container.
	logic [4:0]           TeLeftQ [N_STREAMS];
	logic [IDX_W-1:0]     LastSrcQ             = '0;
	logic                 LastSrcValidQ        = 1'b0;
	logic                 TagSentQ             = 1'b0;

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

	logic [N_STREAMS-1:0] te_raw_eff;
	logic                 sel_te_raw;
	logic                 need_tag;
	logic                 tag_xfer;

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
		if (EN_TE_RAW && (N_STREAMS > 128)) begin
			$fatal(1, "ct_L1_funnel source tag encodes at most 128 channels, got %0d", N_STREAMS);
		end
		if ((ATB_DATA_WIDTH % CHUNK_W) != 0) begin
			$fatal(1, "ct_L1_funnel requires an integer number of %0d-bit chunks per %0d-bit ATB beat",
				CHUNK_W, ATB_DATA_WIDTH);
		end
	end

	// Folds the chunk-local MSEO states across all chunks of one beat
	// (chunk 0 = lowest bits = first chunk on the wire). For the historical
	// MDO_WIDTH=30 reference this degenerates to the original single-chunk
	// classification. Relies on the chunk packer's end-of-message alignment
	// padding: after an END_IDLE chunk the rest of the beat is idle padding,
	// so a beat never carries the start of a following message.
	function automatic beat_parse_t parse_beat(
		input logic [ATB_DATA_WIDTH-1:0] data,
		input logic                      in_packet_i
	);
		beat_parse_t result;
		funnel_chunk_t chunk;
		logic in_packet_run;

		result.has_data = 1'b0;
		result.start_seen = 1'b0;
		result.end_seen = 1'b0;
		result.packet_done = 1'b0;
		in_packet_run = in_packet_i;

		for (int c = 0; c < CHUNKS_PER_BEAT; c = c + 1) begin
			chunk = funnel_chunk_t'(data[c*CHUNK_W +: CHUNK_W]);

			unique case (chunk.mseo)
				START_TRANSMISSION: begin
					result.has_data = 1'b1;
					result.start_seen = 1'b1;
					in_packet_run = 1'b1;
				end

				END_IDLE: begin
					if (in_packet_run) begin
						result.has_data = 1'b1;
						result.end_seen = 1'b1;
						result.packet_done = 1'b1;
						in_packet_run = 1'b0;
					end
				end

				default: begin
					if (in_packet_run) begin
						result.has_data = 1'b1;
					end
				end
			endcase
		end

		result.in_packet_next = in_packet_run;

		return result;
	endfunction

	// E-Trace reference-raw framing: one byte per beat, packet length from the
	// header byte's low 5 bits. `te_left_i` is the number of payload bytes
	// still owed for the packet in flight on that channel.
	function automatic beat_parse_t parse_beat_te(
		input logic [ATB_DATA_WIDTH-1:0] data,
		input logic                      in_packet_i,
		input logic [4:0]                te_left_i
	);
		beat_parse_t result;

		result.has_data = 1'b1;          // no idle beats in this framing
		result.start_seen = !in_packet_i;
		result.end_seen = 1'b0;
		result.packet_done = 1'b0;
		result.in_packet_next = 1'b1;

		if (!in_packet_i) begin
			// Header byte: payload length in bits [4:0].
			if (data[4:0] == 5'd0) begin
				result.end_seen = 1'b1;
				result.packet_done = 1'b1;
				result.in_packet_next = 1'b0;
			end
		end
		else if (te_left_i <= 5'd1) begin
			// Last payload byte of this packet.
			result.end_seen = 1'b1;
			result.packet_done = 1'b1;
			result.in_packet_next = 1'b0;
		end

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
			te_raw_eff[i] = EN_TE_RAW && chan_te_raw[i];
			preview_parse[i] = te_raw_eff[i]
			                 ? parse_beat_te(in_atdata[i], InPacketQ[i], TeLeftQ[i])
			                 : parse_beat(in_atdata[i], InPacketQ[i]);
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
		sel_te_raw = 1'b0;
		if (SelectedValidQ) begin
			sel_te_raw = te_raw_eff[SelectedIdxQ];
			selected_xfer_parse = sel_te_raw
			                    ? parse_beat_te(in_atdata[SelectedIdxQ], InPacketQ[SelectedIdxQ],
			                                    TeLeftQ[SelectedIdxQ])
			                    : parse_beat(in_atdata[SelectedIdxQ], InPacketQ[SelectedIdxQ]);
		end

		// A te_raw packet is preceded by its source tag byte whenever the
		// source changed (or always, if configured). The tag occupies one
		// output beat during which the input beat is NOT consumed; the
		// selection stays locked because the pending header beat keeps
		// `start_seen` asserted.
		need_tag = SelectedValidQ && sel_te_raw && in_atvalid[SelectedIdxQ]
		        && !InPacketQ[SelectedIdxQ] && !TagSentQ
		        && (te_tag_always || !LastSrcValidQ || (LastSrcQ != SelectedIdxQ));
		tag_xfer = need_tag && atb_out.atready;

		xfer_curr = SelectedValidQ && in_atvalid[SelectedIdxQ] && !need_tag
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
			LastSrcQ <= '0;
			LastSrcValidQ <= 1'b0;
			TagSentQ <= 1'b0;
			for (i = 0; i < N_STREAMS; i = i + 1) begin
				InPacketQ[i] <= 1'b0;
				LocalAckSeenQ[i] <= 1'b0;
				GlobalAckSeenQ[i] <= 1'b0;
				TeLeftQ[i] <= 5'd0;
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

			if (te_tag_resync) begin
				LastSrcValidQ <= 1'b0;
			end
			else if (tag_xfer) begin
				TagSentQ      <= 1'b1;
				LastSrcQ      <= SelectedIdxQ;
				LastSrcValidQ <= 1'b1;
			end

			if (xfer_curr) begin
				InPacketQ[SelectedIdxQ] <= selected_xfer_parse.in_packet_next;

				if (sel_te_raw) begin
					// Header beat loads the payload length, payload beats
					// count it down (0 outside a packet).
					TeLeftQ[SelectedIdxQ] <= !InPacketQ[SelectedIdxQ]
					                       ? in_atdata[SelectedIdxQ][4:0]
					                       : (TeLeftQ[SelectedIdxQ] - 5'd1);
				end

				if (selected_xfer_parse.packet_done) begin
					TagSentQ <= 1'b0;   // next packet re-evaluates the tag
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
			// Pure-idle beats (flush padding / repeated END_IDLE outside a
			// packet) are consumed and dropped on every active channel --
			// they carry no information and would otherwise wedge the
			// source's ATB queue while the channel is not selected.
			out_atready_to_in[i] = active_cfg[i] && in_atvalid[i] && !preview_parse[i].has_data;
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
			out_atready_to_in[SelectedIdxQ] = (atb_out.atready && selected_xfer_parse.has_data
			                                && !need_tag)
			                               || (active_cfg[SelectedIdxQ] && in_atvalid[SelectedIdxQ]
			                                && !selected_xfer_parse.has_data);
			out_atdata = in_atdata[SelectedIdxQ];
			out_atid = in_atid[SelectedIdxQ];
			out_atvalid = in_atvalid[SelectedIdxQ] && selected_xfer_parse.has_data;

			if (sel_te_raw) begin
				// One byte per beat in the E-Trace framing (and in the tag).
				out_atbytes = ATB_BYTES_WIDTH'(0);
			end

			if (need_tag) begin
				// Source tag byte; upper bits follow the packetizer's idle
				// convention (all ones) so the beat looks like a byte lane.
				out_atdata  = {{(ATB_DATA_WIDTH-8){1'b1}},
				               1'b1, 7'(SelectedIdxQ)};
				out_atvalid = 1'b1;
			end
		end
	end

`ifndef SYNTHESIS
	// ------------------------------------------------------------------
	// Assertion-only history of the merged output.
	//
	// The packet-continuation check below used to compare SelectedIdxQ with
	// `dbg_selected_idx`, and that is a combinational ALIAS of the very same
	// register (always_comb above): both sides came out of one assignment, so
	// the comparison was a tautology and the funnel's central promise -- "never
	// switches channels in the middle of a packet", file header -- was never
	// actually checked. This register carries a quantity the selection cannot
	// equal by construction: the channel that owned the PREVIOUS output beat.
	// Simulation-only, drives nothing.
	// ------------------------------------------------------------------
	logic [IDX_W-1:0] ChkLastXferIdxQ   = '0;
	logic             ChkLastXferValidQ = 1'b0;

	always_ff @(posedge atclk) begin
		if (!atresetn) begin
			ChkLastXferIdxQ   <= '0;
			ChkLastXferValidQ <= 1'b0;
		end else if (xfer_curr) begin
			ChkLastXferIdxQ   <= SelectedIdxQ;
			ChkLastXferValidQ <= 1'b1;
		end
	end

	always_ff @(posedge atclk) begin
		int i;

		if (atresetn) begin
			if (SelectedValidQ) begin
				assert (chan_prio[SelectedIdxQ] != PRIO_W'(0)
				     || InPacketQ[SelectedIdxQ]
				     || (xfer_curr && selected_xfer_parse.in_packet_next))
					else $error("ct_L1_funnel: selected channel has priority 0 outside an active packet continuation");
			end

			// The file header's central promise, checked against quantities that
			// do NOT come from the selection's own assignment.
			//
			// (a) STATE view: while a packet of channel i is open, i must BE the
			//     selection. InPacketQ is written by the packet parser, the
			//     selection by the arbiter -- two independent registers, so a lock
			//     that releases one message (or one beat) too early makes this
			//     false in the cycle it happens.
			for (i = 0; i < N_STREAMS; i = i + 1) begin
				if (InPacketQ[i]) begin
					assert (SelectedValidQ && SelectedIdxQ == IDX_W'(i))
						else $error("ct_L1_funnel: channel switched during packet continuation -- channel %0d has an open packet while the selection is %0d (valid=%0b)",
							i, SelectedIdxQ, SelectedValidQ);
				end
			end

			// (b) WIRE view of the same property, and the one a consumer of the
			//     merged stream actually depends on: a beat that CONTINUES a
			//     packet must follow a beat of the SAME channel. Compared against
			//     the recorded history of the output, not against the selection.
			if (xfer_curr && InPacketQ[SelectedIdxQ]) begin
				assert (ChkLastXferValidQ && ChkLastXferIdxQ == SelectedIdxQ)
					else $error("ct_L1_funnel: packet of channel %0d continues after a beat of channel %0d -- messages interleaved on the merged stream",
						SelectedIdxQ, ChkLastXferIdxQ);
			end

			for (i = 0; i < N_STREAMS; i = i + 1) begin
				if (!SelectedValidQ || (SelectedIdxQ != IDX_W'(i))) begin
					assert (out_atready_to_in[i] == 1'b0
					     || (in_atvalid[i] && !preview_parse[i].has_data))
						else $error("ct_L1_funnel: non-selected channel %0d observed ATREADY outside idle-beat drop", i);
				end
			end

			if (atb_out.atvalid && SelectedValidQ) begin
				assert (need_tag || atb_out.atdata == in_atdata[SelectedIdxQ])
					else $error("ct_L1_funnel: ATDATA mismatch to selected input");
				assert (atb_out.atbytes == (sel_te_raw ? ATB_BYTES_WIDTH'(0)
				                                       : ATB_BYTES_WIDTH'(BEAT_BYTES - 1)))
					else $error("ct_L1_funnel: ATBYTES mismatch for the selected framing");
				assert (!need_tag || atb_out.atdata[7])
					else $error("ct_L1_funnel: source tag byte must have bit 7 set");
				assert (atb_out.atid == in_atid[SelectedIdxQ])
					else $error("ct_L1_funnel: ATID mismatch to selected input");

				// The source framing must match what the channel was told to
				// be: te_raw sources emit exactly one byte per beat.
				if (!need_tag && sel_te_raw) begin
					assert (in_atbytes[SelectedIdxQ] == ATB_BYTES_WIDTH'(0))
						else $error("ct_L1_funnel: te_raw channel %0d emitted %0d valid bytes (expected 1)",
							SelectedIdxQ, in_atbytes[SelectedIdxQ] + 1);
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