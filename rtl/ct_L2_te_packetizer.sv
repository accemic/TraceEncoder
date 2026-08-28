// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder L2 E-Trace packetizer (te_inst payload -> framed ATB bytes).
 *
 * @details
 *   Applies the whole-packet sign-based compression of "Efficient Trace for
 *   RISC-V" (ch. 7 preamble) to the raw payload from ct_L2_te_inst_gen,
 *   prepends the reference-raw 1-byte header (payload_len[4:0] | msg_type
 *   TE_INST<<5 = 0x40) and streams the bytes over ATB, one byte per beat
 *   (atbytes=0). No MSEO state, no idle bytes: the accepted-byte stream IS
 *   a .te_inst_raw file consumable by the vendored reference decoder.
 *
 *   ATB flush (afvalid) is acknowledged from the ATB clock domain once the
 *   CDC FIFO has drained (a byte still in the proc-side shift stage may
 *   follow afterwards -- acceptable for the simulation flows this MVP
 *   backend targets; noted in PLAN_etrace_output).
 */

module ct_L2_te_packetizer (
	input uwire logic                                      proc_clk,
	input uwire logic                                      proc_rst,

	// Packet input (from ct_L2_te_inst_gen)
	input uwire logic [ct_pkg::CT_ETRACE_PKT_MAX_BITS-1:0] pkt_payload,
	input uwire logic [7:0]                                pkt_nbits,
	input uwire logic [1:0]                                pkt_mtype,
	input uwire logic                                      pkt_valid,
	output uwire logic                                     pkt_ready,

	// ATB
	input uwire logic                                      atb_atclk,
	input uwire logic                                      atb_atresetn,
	atb_if.master                                          atb,
	ct_cs_atbclk_if.slave                                  cs_atb,
	// Trace-output quota (P2, D9 E-Trace parity) -- see
	// ct_L2_mseo_mdo_formatter, identical contract: held overflow levels
	// + crossed SyncCntClr rearm. cs_proc carries InstSyncMode/Max.
	ct_cs_procclk_if.slave                                 cs_proc,
	output logic                                           synq_req_trace_byte_count, // byte-quota overflow level (InstSyncMode 4)
	output logic                                           synq_req_trace_msg_count,  // message-quota overflow level (InstSyncMode 1)
	input uwire logic                                      quota_cnt_clr,             // crossed SyncCntClr (proc_clk domain, rearm)
	// trTeControl.Empty chain -- see ct_L2_mseo_mdo_formatter, identical
	// semantics.
	input uwire logic                                      upstream_empty,
	output uwire logic                                     chain_empty // atb_atclk domain
);
	import ct_pkg::*;

	localparam int unsigned MAXB      = CT_ETRACE_PKT_MAX_BITS;
	localparam int unsigned MAX_BYTES = (MAXB + 7) / 8;          // payload bytes

	// ------------------------------------------------------------------
	// Sign-based compression: number of significant payload bytes
	// (keep = index of the highest bit differing from the sign, +2 --
	// data bits through that index plus one surviving sign bit).
	// ------------------------------------------------------------------
	function automatic logic [4:0] sig_bytes(
		input logic [MAXB-1:0] p, input logic [7:0] nbits);
		automatic logic        sign = p[nbits-1];
		automatic int unsigned keep = 1;
		for (int i = 0; i < MAXB; i++)
			if ((i + 1 < nbits) && (p[i] != sign))
				keep = i + 2;
		return 5'((keep + 7) / 8);
	endfunction

	// Payload with sign extension up to the byte boundary above nbits.
	function automatic logic [MAX_BYTES*8-1:0] sign_ext(
		input logic [MAXB-1:0] p, input logic [7:0] nbits);
		automatic logic [MAX_BYTES*8-1:0] e;
		automatic logic sign = p[nbits-1];
		for (int i = 0; i < MAX_BYTES*8; i++)
			e[i] = (i < nbits) ? p[i] : sign;
		return e;
	endfunction

	// ------------------------------------------------------------------
	// Serializer: header + payload bytes into the CDC FIFO
	// ------------------------------------------------------------------
	typedef logic [7:0] te_byte_t;

	sink_if #(.T(te_byte_t)) atb_cdc_d (
		.clk(proc_clk),
		.rst(proc_rst)
	);
	uwire logic atb_rst = !atb_atresetn;
	source_if #(.T(te_byte_t)) atb_q (
		.clk(atb_atclk),
		.rst(atb_rst)
	);

	logic [MAX_BYTES*8-1:0] ShiftBuf = '0;
	logic [4:0]             BytesLeft = '0;   // payload bytes still to send
	logic                   HdrPend   = 1'b0; // header byte not yet sent
	logic [4:0]             PktBytes  = '0;
	logic [1:0]             PktMtype  = 2'd2; // raw-framing msg_type of this packet

	uwire busy = HdrPend || (BytesLeft != 0);
	assign pkt_ready = !proc_rst && !busy;

	uwire te_byte_t out_byte = HdrPend ? {1'b0, PktMtype, 5'(PktBytes)}
	                                   : ShiftBuf[7:0];
	uwire out_wr = busy && !atb_cdc_d.full;

	assign atb_cdc_d.d  = out_byte;
	assign atb_cdc_d.wr = out_wr;

	always_ff @(posedge proc_clk) begin
		if (proc_rst) begin
			BytesLeft <= '0;
			HdrPend   <= 1'b0;
		end
		else begin
			if (pkt_valid && pkt_ready) begin
				automatic logic [4:0] nb = sig_bytes(pkt_payload, pkt_nbits);
				// pragma translate_off
				if ($test$plusargs("TE_PKT_DUMP"))
					$display("[te_pktz] nbits=%0d nb=%0d sign=%b p80=%b p_hi=%08x",
						pkt_nbits, nb, pkt_payload[pkt_nbits-1], pkt_payload[80],
						32'(pkt_payload >> 80));
				// pragma translate_on
				ShiftBuf  <= sign_ext(pkt_payload, pkt_nbits);
				PktBytes  <= nb;
				PktMtype  <= pkt_mtype;
				BytesLeft <= nb;
				HdrPend   <= 1'b1;
			end
			else if (out_wr) begin
				if (HdrPend) begin
					HdrPend <= 1'b0;
				end
				else begin
					ShiftBuf  <= ShiftBuf >> 8;
					BytesLeft <= BytesLeft - 1'b1;
				end
			end
		end
	end

	// ----------------------------------------------------------------
	// Trace-output quota counter (P2, D2/D3) -- same dedicated counter as
	// in ct_L2_mseo_mdo_formatter (see the design rationale there; NOT
	// counter.sv, '>='-compare, held level, clr priority, in-module mode
	// gate). E-Trace parity (D9): byte event = out_wr, step 1 (every
	// framed byte accepted into the CDC FIFO -- header + payload);
	// message event = the LAST payload byte of a packet:
	// out_wr && !HdrPend && BytesLeft==1.
	// ----------------------------------------------------------------
	if (ct_pkg::CT_EN_QUOTA_SYNC) begin : genQuotaCnt
		localparam ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e
			QUOTA_MODE_MSG   = ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_MSG,
			QUOTA_MODE_BYTES = ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES;
		uwire logic quota_mode_bytes = (cs_proc.trTeInstSyncMode == QUOTA_MODE_BYTES);
		uwire logic quota_mode_msg   = (cs_proc.trTeInstSyncMode == QUOTA_MODE_MSG);
		uwire ct_pkg::ct_synccnt_counter_t quota_max = 1 << (cs_proc.trTeInstSyncMax + 4);
		uwire logic quota_byte_ev = out_wr;                                     // one accepted framed byte
		uwire logic quota_msg_ev  = out_wr && !HdrPend && (BytesLeft == 5'd1);  // packet end
		ct_pkg::ct_synccnt_counter_t QuotaCnt = '0;
		uwire logic quota_ovf = (QuotaCnt >= quota_max);
		always_ff @(posedge proc_clk) begin
			if (proc_rst || quota_cnt_clr || !(quota_mode_bytes || quota_mode_msg))
				QuotaCnt <= '0;
			else if (!quota_ovf) begin
				if      (quota_mode_bytes && quota_byte_ev) QuotaCnt <= QuotaCnt + 1'b1;
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
		uwire logic unused_cs_proc       = cs_proc.trTeActive;
	end

	// ------------------------------------------------------------------
	// CDC + ATB drive (one byte per beat, atbytes = 0)
	// ------------------------------------------------------------------
	localparam int unsigned TE_ATB_FIFO_DEPTH = 64;

	if (ct_pkg::CT_SINGLE_CLOCK) begin : genAtbFifo1clk
		fifo1clk_fwft #(
			.T(te_byte_t),
			.MIN_DEPTH(TE_ATB_FIFO_DEPTH),
			.FIFO_STYLE("auto")
		) atb_cdc_fifo (
			.d(atb_cdc_d),
			.q(atb_q)
		);
	end
	else begin : genAtbFifo2clk
		fifo2clk_fwft #(
			.T(te_byte_t),
			.MIN_DEPTH(TE_ATB_FIFO_DEPTH),
			.FIFO_STYLE("auto"),
			.SAFE_RESETS(1)
		) atb_cdc_fifo (
			.d(atb_cdc_d),
			.q(atb_q)
		);
	end

	assign atb_q.ack   = atb_q.valid && atb.atready;
	assign atb.atvalid = atb_q.valid;
	assign atb.atdata  = atb_q.valid
	                     ? {{(atb_pkg::ATDATA_WIDTH-8){1'b1}}, atb_q.q}
	                     : {atb_pkg::ATDATA_WIDTH{1'b1}};
	assign atb.atid    = cs_atb.trAtbId;
	assign atb.atbytes = atb_pkg::ATBYTES_WIDTH'(0);

	// Flush: acknowledge once the CDC FIFO shows empty in the ATB domain.
	logic AfReady = 1'b0;
	always_ff @(posedge atb_atclk) begin
		if (atb_rst) AfReady <= 1'b0;
		else         AfReady <= atb.afvalid && !atb_q.valid && !AfReady;
	end
	assign atb.afready = AfReady;

	// ----------------------------------------------------------------
	// trTeControl.Empty chain: registered on the proc side, two-flop
	// synchronized, 16-cycle quiet filter in the ATB domain (see
	// mseo_mdo_formatter).
	// ----------------------------------------------------------------
	logic       ProcEmptyQ    = 1'b0;
	logic [1:0] EmptySyncQ    = '0;
	logic [3:0] EmptyQuietCnt = '0;
	logic       ChainEmptyQ   = 1'b0;

	always_ff @(posedge proc_clk) begin
		if (proc_rst) ProcEmptyQ <= 1'b0;
		else ProcEmptyQ <= upstream_empty && !pkt_valid && !busy;
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

endmodule // ct_L2_te_packetizer

`default_nettype wire
