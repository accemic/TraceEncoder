// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder Nexus Decoder (ATB -> nexus_message_t)
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

module ct_nexus_decoder #(
	bit INCLUDE_SRC    = 1'b0,
	bit INCLUDE_TSTAMP = 1'b1
) (
	input uwire logic             atb_atclk,    // ATB clock
	input uwire logic             atb_atresetn, // ATB reset (low active)
	atb_if.slave                  atb,
	output uwire                  dec_msg_valid,
	output uwire                  dec_msg_error,
	output nexus::nexus_message_t dec_msg
);

	import nexus_vendor::*;
	import nexus::*;
	import ct_pkg::*;
	import atb_pkg::*;

	localparam int ATB_BEAT_WIDTH            = $bits(atb.atdata);
	localparam int NUM_CHUNKS_PER_ATB_BEAT  = ATB_BEAT_WIDTH / NEXUS_CHUNK_WIDTH;
	localparam int DF_ADDR_MAX_BITS         = NEXUS_MSG_ADDRESS_WIDTH + NEXUS_MSG_DSZ_WIDTH;
	// The package-level NEXUS_MAX_CHUNKS is sized for generic packet transport,
	// but real CTTE DF messages with 64-bit payloads and timestamps can exceed
	// 20 chunks. Keep a larger local decoder window so long messages are not
	// truncated before their terminating END_IDLE chunk arrives.
	localparam int DECODER_MAX_CHUNKS        = 64;

	function automatic nexus_msg_format_t get_msg_format_local(input nexus_tcode_e tcode);
		nexus_msg_format_t fmt;
		int idx;

		fmt.tcode      = tcode;
		fmt.num_fields = 0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			fmt.fmt[i].name       = INVALID;
			fmt.fmt[i].field_type = FIELD_INVALID;
			fmt.fmt[i].max_bits   = 0;
		end

		idx = 0;
		fmt.fmt[idx] = '{ name: TCODE, field_type: FIXED, max_bits: 6 };
		idx++;

		if (INCLUDE_SRC && (tcode != NEXUS_MSG_FLUSH)) begin
			fmt.fmt[idx] = '{ name: SRC, field_type: VENDOR_FIXED, max_bits: NEXUS_MSG_SOURCE_WIDTH };
			idx++;
		end

		unique case (tcode)
			NEXUS_MSG_PROGRAM_TRACE_SYNC: begin
				fmt.fmt[idx++] = '{ name: SYNC, field_type: VENDOR_FIXED, max_bits: $bits(nexus_sync_reason_e) };
				fmt.fmt[idx++] = '{ name: ICNT, field_type: VARIABLE, max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[idx++] = '{ name: PC_FADDR, field_type: VARIABLE, max_bits: NEXUS_MSG_ADDRESS_WIDTH };
			end
			NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH: begin
				fmt.fmt[idx++] = '{ name: ICNT, field_type: VARIABLE, max_bits: NEXUS_MSG_I_CNT_WIDTH };
			end
			NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC: begin
				fmt.fmt[idx++] = '{ name: SYNC, field_type: VENDOR_FIXED, max_bits: $bits(nexus_sync_reason_e) };
				fmt.fmt[idx++] = '{ name: ICNT, field_type: VARIABLE, max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[idx++] = '{ name: PC_FADDR, field_type: VARIABLE, max_bits: NEXUS_MSG_ADDRESS_WIDTH };
			end
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH: begin
				fmt.fmt[idx++] = '{ name: BTYPE, field_type: VENDOR_FIXED, max_bits: $bits(nexus_btype_e) };
				fmt.fmt[idx++] = '{ name: ICNT, field_type: VARIABLE, max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[idx++] = '{ name: UADDR, field_type: VARIABLE, max_bits: NEXUS_MSG_ADDRESS_WIDTH };
			end
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC: begin
				fmt.fmt[idx++] = '{ name: SYNC, field_type: VENDOR_FIXED, max_bits: $bits(nexus_sync_reason_e) };
				fmt.fmt[idx++] = '{ name: BTYPE, field_type: VENDOR_FIXED, max_bits: $bits(nexus_btype_e) };
				fmt.fmt[idx++] = '{ name: ICNT, field_type: VARIABLE, max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[idx++] = '{ name: PC_FADDR, field_type: VARIABLE, max_bits: NEXUS_MSG_ADDRESS_WIDTH };
			end
			NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL: begin
				fmt.fmt[idx++] = '{ name: RCODE, field_type: VENDOR_FIXED, max_bits: $bits(nexus_rcode_e) };
				fmt.fmt[idx++] = '{ name: RDATA0, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_RDATA_WIDTH };
			end
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY: begin
				fmt.fmt[idx++] = '{ name: BTYPE, field_type: VENDOR_FIXED, max_bits: $bits(nexus_btype_e) };
				fmt.fmt[idx++] = '{ name: ICNT, field_type: VARIABLE, max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[idx++] = '{ name: UADDR, field_type: VARIABLE, max_bits: NEXUS_MSG_ADDRESS_WIDTH };
				fmt.fmt[idx++] = '{ name: RDATA0, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_RDATA_WIDTH };
			end
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC: begin
				fmt.fmt[idx++] = '{ name: SYNC, field_type: VENDOR_FIXED, max_bits: $bits(nexus_sync_reason_e) };
				fmt.fmt[idx++] = '{ name: BTYPE, field_type: VENDOR_FIXED, max_bits: $bits(nexus_btype_e) };
				fmt.fmt[idx++] = '{ name: ICNT, field_type: VARIABLE, max_bits: NEXUS_MSG_I_CNT_WIDTH };
				fmt.fmt[idx++] = '{ name: PC_FADDR, field_type: VARIABLE, max_bits: NEXUS_MSG_ADDRESS_WIDTH };
				fmt.fmt[idx++] = '{ name: RDATA0, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_RDATA_WIDTH };
			end
			NEXUS_MSG_DATA_TRACE_WRITE,
			NEXUS_MSG_DATA_TRACE_READ: begin
				fmt.fmt[idx++] = '{ name: DSZ, field_type: VENDOR_FIXED, max_bits: $bits(nexus_dsz_e) };
				fmt.fmt[idx++] = '{ name: ELSZ, field_type: VENDOR_FIXED, max_bits: $bits(nexus_elsz_e) };
				fmt.fmt[idx++] = '{ name: UADDR, field_type: VARIABLE, max_bits: DF_ADDR_MAX_BITS };
				fmt.fmt[idx++] = '{ name: DQDATA, field_type: VARIABLE, max_bits: NEXUS_DQDATA_WIDTH };
			end
			// TCODE 13/14 (P3, CT_EN_DF_ADDR_COMPRESS): synchronizing 5/6
			// forms; same layout, but the address slot carries the FULL
			// (uncompressed) data address. Field name ADDR mirrors the
			// package-level get_msg_format() table (the 5/6 slot stays
			// UADDR there, carrying the XOR delta when compression is on).
			// DF_ADDR_MAX_BITS keeps the shared variable-field window.
			NEXUS_MSG_DATA_TRACE_WRITE_SYNC,
			NEXUS_MSG_DATA_TRACE_READ_SYNC: begin
				fmt.fmt[idx++] = '{ name: DSZ, field_type: VENDOR_FIXED, max_bits: $bits(nexus_dsz_e) };
				fmt.fmt[idx++] = '{ name: ELSZ, field_type: VENDOR_FIXED, max_bits: $bits(nexus_elsz_e) };
				fmt.fmt[idx++] = '{ name: ADDR, field_type: VARIABLE, max_bits: DF_ADDR_MAX_BITS };
				fmt.fmt[idx++] = '{ name: DQDATA, field_type: VARIABLE, max_bits: NEXUS_DQDATA_WIDTH };
			end
			NEXUS_MSG_DATA_ACQUISITION: begin
				fmt.fmt[idx++] = '{ name: IDTAG, field_type: VENDOR_FIXED, max_bits: NEXUS_IDTAG_WIDTH };
				fmt.fmt[idx++] = '{ name: DQDATA, field_type: VENDOR_VARIABLE, max_bits: NEXUS_DQDATA_WIDTH };
			end
			NEXUS_MSG_ERROR: begin
				fmt.fmt[idx++] = '{ name: ETYPE, field_type: FIXED, max_bits: $bits(nexus_etype_e) };
				fmt.fmt[idx++] = '{ name: ECODE, field_type: VENDOR_FIXED, max_bits: NEXUS_MSG_ECODE_WIDTH };
			end
			NEXUS_MSG_OWNERSHIP_TRACE: begin
				fmt.fmt[idx++] = '{ name: PROCESS, field_type: VENDOR_VARIABLE, max_bits: $bits(nexus_process_t) };
			end
			// TCODE 1 / 15 (P4): single variable payload field each -- the
			// static device identifier resp. the watchpoint hit bitmap.
			// Mirrors the package-level get_msg_format() table.
			NEXUS_MSG_DEVICE_ID: begin
				fmt.fmt[idx++] = '{ name: DEVID, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_DEVID_WIDTH };
			end
			NEXUS_MSG_WATCHPOINT: begin
				fmt.fmt[idx++] = '{ name: WPHIT, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_WPHIT_IMPL_WIDTH };
			end
			NEXUS_MSG_VENDOR_CONFIG: begin
				// SPEC_config_message.md v1: CFGVER fixed(4) + 6 var fields.
				fmt.fmt[idx++] = '{ name: CFGVER, field_type: VENDOR_FIXED,    max_bits: NEXUS_MSG_CFGVER_WIDTH };
				fmt.fmt[idx++] = '{ name: CAPS,   field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_CFG_CAPS_WIDTH };
				fmt.fmt[idx++] = '{ name: ENAB,   field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_CFG_CAPS_WIDTH };
				fmt.fmt[idx++] = '{ name: PARAM0, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_CFG_P0_WIDTH };
				fmt.fmt[idx++] = '{ name: PARAM1, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_CFG_P1_WIDTH };
				fmt.fmt[idx++] = '{ name: PARAM2, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_CFG_P2_WIDTH };
				fmt.fmt[idx++] = '{ name: PARAM3, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_CFG_P3_WIDTH };
			end
			NEXUS_MSG_FLUSH: begin
				// TCODE only
			end
			default: begin
				// leave num_fields = 0 to report an unknown TCODE
				return fmt;
			end
		endcase

		if (INCLUDE_TSTAMP && (tcode != NEXUS_MSG_FLUSH)) begin
			fmt.fmt[idx++] = '{ name: TSTAMP, field_type: VENDOR_VARIABLE, max_bits: NEXUS_MSG_TSTAMP_WIDTH };
		end

		fmt.num_fields = idx;
		return fmt;
	endfunction

	// ----------------------------------------------------------------
	// Process Chunk
	// Decode one full Nexus message from its chunk array.
	// Handles FIXED and VARIABLE fields, even when multiple fields
	// share or span the same chunk.
	// ----------------------------------------------------------------
	task automatic task_decode (
		input nexus_chunk_t [DECODER_MAX_CHUNKS-1:0]  chunks,
		ref   nexus_message_t                         msg,
		output logic                                 decode_error
	);
		// local variables
		nexus_msg_format_t        fmt;
		nexus_field_format_t      fd;
		int                       data_width;
		int                       mdo_ptr;
		int                       chunk_id;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] field_data;

		decode_error = 0;

		// Init all fields to invalid
		for (int f = 0; f < NEXUS_MAX_FIELDS; f++) begin
			msg.fields[f].name       = INVALID;
			msg.fields[f].field_type = FIELD_INVALID;
			msg.fields[f].data       = '0;
			msg.fields[f].data_width = 0;
		end

		// Init field 0 (TCODE)
		msg.fields[0].name       = TCODE;
		msg.fields[0].field_type = FIXED;
		msg.fields[0].data       = chunks[0].mdo[NEXUS_MDO_WIDTH-1 -: 6];
		msg.fields[0].data_width = 6;

		// Get TCODE specific format descriptor
		fmt = get_msg_format_local(nexus_tcode_e'(msg.fields[0].data[5:0]));
		if (fmt.num_fields == 0) begin // unknown TCODE
			decode_error = 1;
			return;
		end

		// Walk through the fields
		chunk_id = 1;
		mdo_ptr  = 0;
		for (int fld = 1; fld < fmt.num_fields; fld++) begin
			fd        = fmt.fmt[fld];
			field_data = '0;
			case (fd.field_type)
				FIXED, VENDOR_FIXED: begin
					data_width = fd.max_bits;
					for (int i = 0; i < fd.max_bits; i++) begin
						field_data[i] = chunks[chunk_id].mdo[mdo_ptr];
						mdo_ptr = mdo_ptr + 1;
						if (mdo_ptr == NEXUS_MDO_WIDTH) begin
							mdo_ptr  = 0;
							chunk_id = chunk_id + 1;
						end
					end
				end
				VARIABLE, VENDOR_VARIABLE: begin
					data_width = 0;
					for (int i = 0; i < (fd.max_bits + (NEXUS_MDO_WIDTH-1)); i++) begin
						field_data[i] = chunks[chunk_id].mdo[mdo_ptr];
						if (field_data[i]) begin
							data_width = i + 1;
						end

						if (mdo_ptr == (NEXUS_MDO_WIDTH-1)) begin
							nexus_mseo_e mseo_cur = chunks[chunk_id].mseo;
							mdo_ptr  = 0;
							chunk_id = chunk_id + 1;
							if ((mseo_cur == VAR) || (mseo_cur == END_IDLE)) begin
								break;
							end
						end else begin
							mdo_ptr = mdo_ptr + 1;
						end
					end
				end
				default: begin
					$finish();
				end
			endcase

			msg.fields[fld].name       = fd.name;
			msg.fields[fld].field_type = fd.field_type;
			msg.fields[fld].data       = field_data;
			msg.fields[fld].data_width = data_width;
		end
	endtask : task_decode

	cvsink_if    #(.T(nexus_chunk_t), .P(NUM_CHUNKS_PER_ATB_BEAT)) cvs_d (.clk(atb_atclk), .rst(!atb_atresetn));
	cvsource_if2 #(.T(nexus_chunk_t), .P(1))                       cvs_q (.clk(atb_atclk), .rst(!atb_atresetn));

	assign atb.atready = !cvs_d.full;
	assign cvs_d.d     = atb.atdata;
	assign cvs_d.cnt   = (atb.atvalid && atb.atready) ? NUM_CHUNKS_PER_ATB_BEAT : 0;

	// Compacting FIFO
	cvs_fifo2 #(
		.T(nexus_chunk_t),
		.P(NUM_CHUNKS_PER_ATB_BEAT),
		.PO(1),
		.MIN_DEPTH(128)
	) cvs_fifo2_inst (
		.clk(atb_atclk),
		.rst(!atb_atresetn),
		.d(cvs_d),
		.q(cvs_q)
	);

	// ----------------------------------------------------------------
	// MSEO state machine -- one chunk per cycle
	// ----------------------------------------------------------------
	uwire chunk_avail = (cvs_q.cnt > 0);
	assign cvs_q.ack  = chunk_avail ? 1 : 0;

	nexus_mseo_state_e         mseo_state;
	logic [NEXUS_MDO_WIDTH-1:0] mseo_mdo_out;
	logic [1:0]                mseo_mseo_out;
	logic                      mseo_state_valid;
	logic                      mseo_err;

	mseo2_decoder #(
		.OUTPUT_IDLE (1),
		.MDO_WIDTH   (NEXUS_MDO_WIDTH)
	) mseo_dec (
		.clk        (atb_atclk),
		.rst        (!atb_atresetn),
		.mseo       (cvs_q.q[0].mseo),
		.mseo_valid (chunk_avail),
		.mdo_in     (cvs_q.q[0].mdo),
		.state      (mseo_state),
		.mdo_out    (mseo_mdo_out),
		.mseo_out   (mseo_mseo_out),
		.state_valid(mseo_state_valid),
		.error      (mseo_err)
	);

	// ----------------------------------------------------------------
	// Chunk accumulator -- driven by mseo2_decoder state
	// ----------------------------------------------------------------
	nexus_chunk_t [DECODER_MAX_CHUNKS-1:0] chunk_buf;
	int chunk_cnt;
	nexus_message_t msg;
	int msg_id;
	logic decode_error;
	logic MsgValid;
	logic MsgError;
	nexus_message_t Msg;

	always_ff @(negedge atb_atclk) begin // negedge for simulation stability
		// verilog_lint: waive-start always-ff-non-blocking
		MsgValid <= 0;
		MsgError <= 0;
		Msg      <= '0;

		if (!atb_atresetn) begin
			chunk_cnt = 0;
			msg       = '0;
			msg_id    = 0;
		end else if (mseo_state_valid) begin
			case (mseo_state)
				NEXUS_STATE_IDLE: begin
					// idle filler -- nothing to accumulate
				end
				NEXUS_STATE_START_MSG: begin
					chunk_cnt = 0;
					chunk_buf[0].mdo  = mseo_mdo_out;
					chunk_buf[0].mseo = nexus_mseo_e'(mseo_mseo_out);
					chunk_cnt = 1;
				end
				NEXUS_STATE_NORMAL,
				NEXUS_STATE_END_PACKET: begin
					chunk_buf[chunk_cnt].mdo  = mseo_mdo_out;
					chunk_buf[chunk_cnt].mseo = nexus_mseo_e'(mseo_mseo_out);
					chunk_cnt = chunk_cnt + 1;
				end
				NEXUS_STATE_END_MSG: begin
					chunk_buf[chunk_cnt].mdo  = mseo_mdo_out;
					chunk_buf[chunk_cnt].mseo = nexus_mseo_e'(mseo_mseo_out);
					chunk_cnt = chunk_cnt + 1;
					task_decode(chunk_buf, msg, decode_error);
					msg.id   = msg_id;
					msg_id   = msg_id + 1;
					MsgValid <= 1;
					MsgError <= decode_error || mseo_err;
					Msg      <= msg;
					chunk_cnt = 0;
				end
			endcase
		end
	end
	// verilog_lint: waive-stop always-ff-non-blocking

	assign dec_msg_valid = MsgValid;
	assign dec_msg_error = MsgError;
	assign dec_msg       = Msg;

endmodule // ct_nexus_decoder

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
