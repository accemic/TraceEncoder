// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder L2 MSEO/MDO formatter (Nexus message -> ATB chunks)
 *
 * @details
 *   The module accepts one `nexus_message_t` whenever `ready_out` is high,
 *   slices/encodes it into MDO/MSEO chunks, packs chunks to ATB beats, and
 *   crosses into the ATB clock domain.
 */

module ct_L2_mseo_mdo_formatter #(
	int unsigned NEXUS_MAX_FIELDS           = nexus_vendor::NEXUS_MAX_FIELDS,           // max number of fields per nexus message
	int unsigned NEXUS_MAX_FIELD_DATA_WIDTH = nexus_vendor::NEXUS_MAX_FIELD_DATA_WIDTH, // max payload width per field (bits)
	int unsigned MDO_WIDTH,                                                             // number of MDO payload bits per chunk (no default — caller must set)
	int unsigned ATB_CDC_FIFO_DEPTH         = 8                                         // min depth of proc->atb CDC fifo
) (
	input uwire logic            proc_clk,                  // trace processing clock
	input uwire logic            proc_rst,                  // trace processing reset
	input uwire logic            atb_atclk,                 // ATB clock
	input uwire logic            atb_atresetn,              // ATB reset (low active)
	input nexus::nexus_message_t nexus_msg,                 // formatted nexus message input
	ct_cs_procclk_if.slave       cs_proc,                   // control / status interface (proc_clk domain)
	ct_cs_atbclk_if.slave        cs_atb,                    // control / status interface (atb_atclk domain)
	atb_if.master                atb,                       // ATB output
	// Trace-output quota (P2): HELD overflow levels toward the sync
	// generator (proc_clk domain; vector_cdc2-crossed inside preproc_sync)
	// plus the crossed SyncCntClr rearm input. See the quota-counter block.
	output logic                 synq_req_trace_byte_count, // byte-quota overflow level (InstSyncMode 4)
	output logic                 synq_req_trace_msg_count,  // message-quota overflow level (InstSyncMode 1)
	input  uwire logic           quota_cnt_clr,             // crossed SyncCntClr (proc_clk domain, rearm)
	output logic                 ready_out,                 // backpressure to previous pipeline stage
	// trTeControl.Empty chain: upstream_empty means every PRECEDING stage is
	// empty (eTIP / next_iaddr FIFOs, msg_gen). This module appends its own
	// stages (formatter output, msg_buffer, slicer, chunk packer, CDC FIFO)
	// and synchronizes the result conservatively into the ATB domain: a
	// two-flop synchronizer plus a quiet filter, so Empty only asserts after
	// 16 consecutive idle ATB cycles. Entries still in flight through the
	// gray-code crossing become visible as atvalid before that and reset the
	// filter.
	input uwire logic            upstream_empty,
	output uwire logic           chain_empty                // atb_atclk domain
);
	import nexus::*;

	localparam int unsigned MSEO_WIDTH = 2;
	localparam int unsigned FIELD_COUNT_W = $clog2(NEXUS_MAX_FIELDS) + 1;
	localparam int unsigned ATB_BEAT_BYTES = atb_pkg::ATDATA_WIDTH / 8;
	localparam int unsigned CHUNK_WIDTH = MDO_WIDTH + MSEO_WIDTH;
	localparam int unsigned NUM_CHUNKS_PER_ATB_BEAT =
		(atb_pkg::ATDATA_WIDTH >= CHUNK_WIDTH) ? (atb_pkg::ATDATA_WIDTH / CHUNK_WIDTH) : 1;
	localparam int unsigned ATB_PAYLOAD_WIDTH = NUM_CHUNKS_PER_ATB_BEAT * CHUNK_WIDTH;
	localparam int unsigned ATB_PADDING_WIDTH = atb_pkg::ATDATA_WIDTH - ATB_PAYLOAD_WIDTH;

	typedef logic [ATB_PAYLOAD_WIDTH-1:0] atb_data_t;
	typedef logic [CHUNK_WIDTH-1:0] chunk_t;

	uwire logic atb_rst = !atb_atresetn;
	uwire logic unused_cs_proc = cs_proc.trTeActive;
	uwire logic msg_valid = (nexus_msg.fields[0].field_type != FIELD_INVALID);
	uwire logic msg_ready;
	uwire logic [FIELD_COUNT_W-1:0] msg_num_fields;
	uwire logic buf_is_flush;
	uwire logic flush_ready;
	uwire logic flush_start;
	uwire logic slice_ready;
	uwire logic slice_fire;
	uwire logic packer_idle;
	uwire logic atb_valid;
	uwire logic atb_fire;
	uwire logic atb_afready;
	uwire logic [CHUNK_WIDTH-1:0] out_chunk;
	uwire atb_data_t packer_payload;
	uwire logic packer_wr;
	uwire logic [atb_pkg::ATDATA_WIDTH-1:0] atdata_payload;

	nexus_message_t msg_in;
	logic [FIELD_COUNT_W-1:0] buf_num_fields;
	logic buf_valid;
	logic buf_ready;
	nexus_message_t buf_msg;
	logic slicer_msg_ready;
	logic [MDO_WIDTH-1:0] slice_bits;
	logic slice_valid;
	logic slice_ends_field;
	logic slice_ends_var;
	logic slice_last_padded;
	logic som_pulse;
	logic eom_pulse;
	logic stall_data;
	logic [MSEO_WIDTH-1:0] mseo_bits;
	sink_if #(.T(atb_data_t)) atb_cdc_d (
		.clk(proc_clk),
		.rst(proc_rst)
	);

	source_if #(.T(atb_data_t)) atb_q (
		.clk(atb_atclk),
		.rst(atb_rst)
	);

	function automatic logic [FIELD_COUNT_W-1:0] count_valid_fields(
		input nexus_message_t msg
	);
		logic [FIELD_COUNT_W-1:0] count;
		count = '0;
		for (int Idx = 0; Idx < NEXUS_MAX_FIELDS; Idx++) begin
			if (msg.fields[Idx].field_type == FIELD_INVALID) begin
				break;
			end
			count = count + 1'b1;
		end
		return count;
	endfunction

	// ----------------------------------------------------------------
	// Trace-output quota counter (P2, D2/D3). ONE dedicated counter serves
	// both quota modes (mutually exclusive and quasi-static under swwel --
	// InstSyncMode is writable only while Enable=0): mode 4 counts emitted
	// bytes at packer_wr (whole ATB beats, step ATB_BEAT_BYTES -- alignment
	// padding and flush idle beats count toward the quota, N10), mode 1
	// counts on-wire message ends at slice_fire && eom_pulse (the FLUSH
	// pseudo-message never passes the slicer, so it does not count).
	// Deliberately NOT counter.sv: its add path flags overflow only at '>',
	// so a step-4 byte count landing EXACTLY on the threshold would widen
	// the window by one beat (formal finding F-1). This counter compares
	// '>=', saturates at the threshold and holds `ovf` as a LEVEL (CDC-
	// safe) until the crossed SyncCntClr clears it; clr has priority over
	// the increment. Mode gate INSIDE the module: in any other mode the
	// counter neither counts nor asserts, so the exported levels stay
	// semantically clean for SyncReqSource=3 and the OFF/other-mode stream
	// is byte-neutral by construction. Events during an asserted clr are
	// not counted -- part of the documented CDC delta of the window bound
	// (D7: <= 2^(Max+4) + Delta).
	// ----------------------------------------------------------------
	if (ct_pkg::CT_EN_QUOTA_SYNC) begin : genQuotaCnt
		localparam ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e
			QUOTA_MODE_MSG   = ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_MSG,
			QUOTA_MODE_BYTES = ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES;
		uwire logic quota_mode_bytes = (cs_proc.trTeInstSyncMode == QUOTA_MODE_BYTES);
		uwire logic quota_mode_msg   = (cs_proc.trTeInstSyncMode == QUOTA_MODE_MSG);
		uwire ct_pkg::ct_synccnt_counter_t quota_max = 1 << (cs_proc.trTeInstSyncMax + 4);
		uwire logic quota_byte_ev = packer_wr;               // one accepted ATB beat
		uwire logic quota_msg_ev  = slice_fire && eom_pulse; // last chunk of a message
		ct_pkg::ct_synccnt_counter_t QuotaCnt = '0;
		uwire logic quota_ovf = (QuotaCnt >= quota_max);
		always_ff @(posedge proc_clk) begin
			if (proc_rst || quota_cnt_clr || !(quota_mode_bytes || quota_mode_msg))
				QuotaCnt <= '0;
			else if (!quota_ovf) begin
				if      (quota_mode_bytes && quota_byte_ev) QuotaCnt <= QuotaCnt + ATB_BEAT_BYTES;
				else if (quota_mode_msg   && quota_msg_ev)  QuotaCnt <= QuotaCnt + 1'b1;
			end
		end
		assign synq_req_trace_byte_count = quota_ovf && quota_mode_bytes;
		assign synq_req_trace_msg_count  = quota_ovf && quota_mode_msg;
	end
	else begin : genNoQuotaCnt
		// Compiled out: zero cost, tie-offs like the pre-P2 state.
		assign synq_req_trace_byte_count = 1'b0;
		assign synq_req_trace_msg_count  = 1'b0;
		uwire logic unused_quota_cnt_clr = quota_cnt_clr;
	end
	assign msg_in = nexus_msg;
	assign ready_out = msg_ready;
	assign msg_num_fields = count_valid_fields(msg_in);
	assign buf_is_flush = (buf_num_fields == 1)
		&& (buf_msg.fields[0].field_type == FIXED)
		&& (buf_msg.fields[0].data[($bits(nexus_tcode_e)-1):0] == NEXUS_MSG_FLUSH);
	assign flush_ready = buf_valid
		&& buf_is_flush
		&& packer_idle
		&& !slice_valid
		&& !stall_data
		&& !atb_cdc_d.full;
	assign flush_start = buf_valid && buf_ready && buf_is_flush;
	assign slice_fire = slice_valid && slice_ready;
	assign out_chunk = {slice_bits, mseo_bits};
	assign atb_valid = atb_q.valid;
	assign atb_fire = atb_q.valid && atb.atready;

	ct_L2_mseo_mdo_formatter_msg_buffer #(
		.NEXUS_MAX_FIELDS(NEXUS_MAX_FIELDS)
	) u_buf (
		.clk(proc_clk),
		.rst(proc_rst),
		.msg_valid,
		.msg_ready,
		.msg_in,
		.msg_num_fields,
		.buf_valid,
		.buf_ready,
		.msg_out(buf_msg),
		.msg_num_fields_out(buf_num_fields)
	);

	assign buf_ready = buf_is_flush ? flush_ready : slicer_msg_ready;

	ct_L2_mseo_mdo_formatter_bit_slicer #(
		.NEXUS_MAX_FIELDS(NEXUS_MAX_FIELDS),
		.NEXUS_MAX_FIELD_DATA_WIDTH(NEXUS_MAX_FIELD_DATA_WIDTH),
		.MDO_WIDTH(MDO_WIDTH)
	) u_slicer (
		.clk(proc_clk),
		.rst(proc_rst),
		.msg_valid(buf_valid && !buf_is_flush),
		.msg_ready(slicer_msg_ready),
		.msg_in(buf_msg),
		.msg_num_fields(buf_num_fields),
		.slice_bits,
		.slice_valid,
		.slice_ready,
		.slice_ends_field,
		.slice_ends_variable_field(slice_ends_var),
		.slice_last_padded,
		.start_of_message(som_pulse),
		.end_of_message(eom_pulse)
	);

	ct_L2_mseo_mdo_formatter_mseo_controller #(
		.USE_DUAL_MSEO(1'b1),
		.MSEO_WIDTH(MSEO_WIDTH)
	) u_mseo (
		.clk(proc_clk),
		.rst(proc_rst),
		.start_of_message(som_pulse),
		.end_of_message(eom_pulse),
		.slice_valid(slice_valid),
		.slice_fire(slice_fire),
		.slice_ends_variable_field(slice_ends_var),
		.slice_ends_field(slice_ends_field),
		.stall_data,
		.mseo_bits
	);

	ct_L2_mseo_mdo_formatter_atb_chunk_packer #(
		.NEXUS_MAX_FIELDS(NEXUS_MAX_FIELDS),
		.MDO_WIDTH(MDO_WIDTH),
		.MSEO_WIDTH(MSEO_WIDTH)
	) u_chunk_packer (
		.clk(proc_clk),
		.rst(proc_rst),
		.atb_full(atb_cdc_d.full),
		.flush_start,
		.slice_valid,
		.end_of_message(eom_pulse),
		.chunk_in(out_chunk),
		.slice_ready,
		.idle(packer_idle),
		.wr(packer_wr),
		.payload_out(packer_payload)
	);

	assign atb_cdc_d.d = packer_payload;
	assign atb_cdc_d.wr = packer_wr;

	// proc_clk -> atb_clk. In a single-clock build the ATB/AXIS handshake's
	// downstream AXI(S) FIFO owns any real clock transfer, so a plain
	// single-clock FIFO suffices here.
	if (ct_pkg::CT_SINGLE_CLOCK) begin : genAtbFifo1clk
		fifo1clk_fwft #(
			.T(atb_data_t),
			.MIN_DEPTH(ATB_CDC_FIFO_DEPTH),
			.FIFO_STYLE("auto")
		) atb_cdc_fifo (
			.d(atb_cdc_d),
			.q(atb_q)
		);
	end
	else begin : genAtbFifo2clk
		fifo2clk_fwft #(
			.T(atb_data_t),
			.MIN_DEPTH(ATB_CDC_FIFO_DEPTH),
			.FIFO_STYLE("auto"),
			.SAFE_RESETS(1)
		) atb_cdc_fifo (
			.d(atb_cdc_d),
			.q(atb_q)
		);
	end

	assign atb_q.ack = atb_fire;
	assign atb.atvalid = atb_valid;
	if (ATB_PADDING_WIDTH > 0) begin : blkAtbPad
		assign atdata_payload = {{ATB_PADDING_WIDTH{1'b1}}, atb_q.q};
	end
	else begin : blkAtbPad
		assign atdata_payload = atb_pkg::ATDATA_WIDTH'(atb_q.q);
	end
	assign atb.atdata = atb_q.valid ? atdata_payload : {atb_pkg::ATDATA_WIDTH{1'b1}};
	assign atb.atid = cs_atb.trAtbId;
	assign atb.atbytes = atb_pkg::ATBYTES_WIDTH'(ATB_BEAT_BYTES - 1);

	ct_L2_mseo_mdo_formatter_atb_flush_detect #(
		.MDO_WIDTH(MDO_WIDTH),
		.MSEO_WIDTH(MSEO_WIDTH)
	) u_atb_flush_detect (
		.clk(atb_atclk),
		.rst(atb_rst),
		.atvalid(atb_fire),
		.afvalid(atb.afvalid),
		.atb_payload(atb_q.q),
		.afready(atb_afready)
	);

	assign atb.afready = atb_afready;

	// ----------------------------------------------------------------
	// trTeControl.Empty chain: registered on the proc side (a glitch-free
	// CDC source), two-flop synchronized, then quiet-filtered in the ATB
	// domain. Conservative by construction -- Empty drops IMMEDIATELY on any
	// visible activity and only rises after 16 consecutive idle ATB cycles.
	// ----------------------------------------------------------------
	logic       ProcEmptyQ    = 1'b0;
	logic [1:0] EmptySyncQ    = '0;
	logic [3:0] EmptyQuietCnt = '0;
	logic       ChainEmptyQ   = 1'b0;

	always_ff @(posedge proc_clk) begin
		if (proc_rst) ProcEmptyQ <= 1'b0;
		else ProcEmptyQ <= upstream_empty && !msg_valid && !buf_valid
		                   && !slice_valid && packer_idle;
	end

	always_ff @(posedge atb_atclk) begin
		if (atb_rst) begin
			EmptySyncQ    <= '0;
			EmptyQuietCnt <= '0;
			ChainEmptyQ   <= 1'b0;
		end
		else begin
			EmptySyncQ <= {EmptySyncQ[0], ProcEmptyQ};
			if (EmptySyncQ[1] && !atb_q.valid) begin
				if (&EmptyQuietCnt) ChainEmptyQ <= 1'b1;
				else                EmptyQuietCnt <= EmptyQuietCnt + 1'b1;
			end
			else begin
				EmptyQuietCnt <= '0;
				ChainEmptyQ   <= 1'b0;
			end
		end
	end
	assign chain_empty = ChainEmptyQ;

	// I8 (Empty contract, simulation only): Empty implies an idle ATB
	// output -- any remaining visible substance must drop Empty immediately.
	// pragma translate_off
`ifndef SYNTHESIS
	a_i8_empty_no_data: assert property (@(posedge atb_atclk) disable iff (atb_rst)
		ChainEmptyQ |-> !atb_q.valid)
		else $error("%m I8: trTeEmpty=1 while atb_q.valid=1");
`endif
	// pragma translate_on

	// Keep the compatibility tie-off explicit so lint does not flag the read.
	if (1) begin : blkCompat
		uwire logic unused_slice_last_padded = slice_last_padded;
		uwire logic unused_cs_proc_active = unused_cs_proc;
	end
endmodule

`default_nettype wire
