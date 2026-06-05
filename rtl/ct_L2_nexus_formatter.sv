// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    Nexus message formatter (proc_clk): generic CF/DF/DAQ messages -> Nexus field lists.
 *
 * @details
 *   Converts C-Trace generic trace messages (CF/DF/DAQ) into a Nexus message
 *   field list (`nexus_message_t`) — the field-oriented representation that the
 *   subsequent MDO/MSEO formatter packs into ATB chunks. A Nexus message is a
 *   sequence of fields and always starts with a TCODE field; understanding this
 *   module requires knowledge of the Nexus and ATB protocols. Field reference:
 *   https://github.com/riscv-non-isa/tg-nexus-trace/blob/master/docs/NexusTrace-TG-MessageDetails.adoc#71-fields-in-messages
 *
 *   Backpressure:
 *   - `ready_in` stalls the formatter chain.
 *   - When stalled, this module holds its output stable and deasserts
 *     `ready_out` to prevent upstream consumption.
 *
 *   Documentation reference:
 *   - See the C-Trace Reference Manual (Processing Stage chapter).
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import nexus_vendor::*;
import nexus::*;
import ct_pkg::*;
import ct_cs_cpuif_pkg::*;

module ct_L2_nexus_formatter (
	input uwire logic               proc_clk,                   // trace processing clock
	input uwire logic               proc_rst,                   // reset
	ct_cs_procclk_if.slave          cs_proc,                    // control / status interface
	input uwire nexus_msg_struct_t  trace_msg,                  // generic trace msg input
	output nexus_message_t          nexus_msg,                  // nexus msg output
	input uwire logic               ready_in,
	output uwire                    ready_out                   // ready for receiving new trace_msg
);

	// ----------------------------------------------------------------
	// Sanity checks (simulation only)
	// ----------------------------------------------------------------
	// pragma translate_off
		initial begin
			if ($bits(nexus_process_t) != 49) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_process_t)=%0d (expected 49)", $bits(nexus_process_t));
			end
			if ($bits(nexus_cf_msg_struct_t) != NEXUS_MSG_SUB_WIDTH) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_cf_msg_struct_t)=%0d (expected %0d)",
					$bits(nexus_cf_msg_struct_t), NEXUS_MSG_SUB_WIDTH);
			end
			if ($bits(nexus_df_daq_msg_struct_t) != NEXUS_MSG_SUB_WIDTH) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_df_daq_msg_struct_t)=%0d (expected %0d)",
					$bits(nexus_df_daq_msg_struct_t), NEXUS_MSG_SUB_WIDTH);
			end
			if ($bits(nexus_other_msg_struct_t) != NEXUS_MSG_SUB_WIDTH) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_other_msg_struct_t)=%0d (expected %0d)",
					$bits(nexus_other_msg_struct_t), NEXUS_MSG_SUB_WIDTH);
			end
			if ($bits(nexus_error_msg_struct_t) != NEXUS_MSG_SUB_WIDTH) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_error_msg_struct_t)=%0d (expected %0d)",
					$bits(nexus_error_msg_struct_t), NEXUS_MSG_SUB_WIDTH);
			end
		end
	// pragma translate_on



	// fixed nexus message field indices
	localparam IDX_TCODE                = 0;
	localparam IDX_SRC                  = 1;
	localparam IDX_DATA                 = 2;
	localparam IDX_TSTAMP               = NEXUS_MAX_FIELDS-1;


	nexus_cf_msg_struct_t       cf;
	nexus_df_daq_msg_struct_t   df_daq;
	nexus_error_msg_struct_t    err;
	nexus_other_msg_struct_t    other;

	assign cf     = trace_msg.sub.cf;
	assign df_daq = trace_msg.sub.df_daq;
	assign err    = trace_msg.sub.err;
	assign other  = trace_msg.sub.other;

	nexus_message_t             NexusMsg;
	// NEXUS_MSG_PC_ADDR_SHIFT (from nexus_vendor) is the number of bits the encoder
	// drops from PC_FADDR / UADDR before emission; the decoder applies the
	// same count as a left-shift when reconstructing PCs. For RISC-V the
	// value is 1 (instructions are 16-bit aligned, so the LSB is always 0).
	// RefAddr stores the pre-shifted value so GetUaddr's XOR operates on
	// shifted coordinates consistently with FADDR emissions.
	logic [31:0]                RefAddr  = 0;   //  reference address, see https://github.com/riscv-non-isa/tg-nexus-trace/blob/master/docs/NexusTrace-TG-MessageDetails.adoc#91-address-compression
	logic [31:0]                MsgNum   = 0;   // # of generated message (for debug only)

	// TSTAMP encoding follows RISC-V N-Trace 8.5 / IEEE-ISTO 5001:
	//   - Synchronizing messages carry an *absolute* TSTAMP. The decoder
	//     re-baselines its accumulated time on each sync.
	//   - All other messages carry a *delta* relative to the previous TSTAMP-
	//     carrying message. The decoder reconstructs absolute time by adding
	//     each delta to its baseline.
	// On reset TsLastEmitted is 0, so the first emitted delta would equal
	// absolute time anyway — but real traces always start with a sync, which
	// carries the absolute value explicitly.
	// Unsigned 64-bit subtraction handles monotonic counter wrap naturally.
	nexus_ts_t                  TsLastEmitted = '0;
	nexus_ts_t                  TsDelta;
	nexus_ts_t                  ts_field;
	logic                       tcode_is_sync;
	always_comb begin
		TsDelta = trace_msg.ts - TsLastEmitted;
		tcode_is_sync = (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_SYNC)
					 || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC)
					 || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC);
		ts_field = tcode_is_sync ? trace_msg.ts : TsDelta;
	end

	logic [ADDR_WIDTH-1:0] uaddr;
	always_comb begin
		uaddr = GetUaddr(cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, RefAddr);
	end

	// No internal buffering: upstream may only advance when the downstream
	// formatter chain is ready. Keep this path combinational so backpressure is
	// visible in the same cycle, but gate it off during reset.
	assign ready_out = !proc_rst && ready_in;

	// ----------------------------------------------------------------
	// Task for simulation log output
	// ----------------------------------------------------------------

	task SimulationOutput;
		input integer       line;
		input integer       msg_num;
		input nexus_tcode_e tcode;

		// pragma translate_off
		$display("*** INFO (nexus_formatter, line %0d): (Msg %d) %s", line, msg_num, tcode.name());
		// pragma translate_on

	endtask

	// ----------------------------------------------------------------
	// convert generic trace msg to Nexus Message
	// ----------------------------------------------------------------
	always_ff @(posedge proc_clk)begin
		logic insert_src;
		int idx_data;
		int idx_next;

		if (proc_rst) begin
			// Initialize NexusMsg.fields (for simulation) on reset.
			for (int j = 0; j < NEXUS_MAX_FIELDS; j++) begin
				NexusMsg.fields[j].field_type   <= FIELD_INVALID;
				NexusMsg.fields[j].name         <= X;
				NexusMsg.fields[j].data         <= '0;
				NexusMsg.fields[j].data_width   <= 0;
			end
			RefAddr       <= 0;
			MsgNum        <= 0;
			TsLastEmitted <= '0;
		end
		else if (ready_in) begin
			// Only update output when the downstream is ready. Otherwise keep
			// NexusMsg stable to avoid dropping messages.
			//
			// Initialize NexusMsg.fields (for simulation)
			for (int j = 0; j < NEXUS_MAX_FIELDS; j++) begin
				NexusMsg.fields[j].field_type   <= FIELD_INVALID;
				NexusMsg.fields[j].name         <= X;
				NexusMsg.fields[j].data         <= '0;
				NexusMsg.fields[j].data_width   <= 0;
			end

			if (trace_msg.sub_type != SUB_MSG_NONE) begin

				MsgNum <= MsgNum+1;

				NexusMsg.id <= trace_msg.id;    // id of corresponding trace message, for debug

				// compose Nexus message: TCODE & SRC (first field for all Nexus messages)
				NexusMsg.fields[IDX_TCODE] <= '{TCODE, FIXED, trace_msg.tcode, 6};

				insert_src = !cs_proc.trTeInhibitSrc && trace_msg.tcode != NEXUS_MSG_FLUSH;
				idx_data = insert_src ? IDX_DATA : IDX_SRC;
				idx_next = idx_data;

				// Optional SRC must keep the field array dense because the new
				// parallel formatter consumes fields sequentially from index 0.
				if (insert_src) begin
					NexusMsg.fields[IDX_SRC] <= '{SRC, VENDOR_FIXED, cs_proc.trTeSrcID, cs_proc.trTeSrcBits};
				end

					case (trace_msg.tcode)
						NEXUS_MSG_PROGRAM_TRACE_SYNC: begin                     // compose Nexus Sync message
							NexusMsg.fields[idx_data+0] <= '{SYNC,      VENDOR_FIXED,    cf.sync_reason,    $size(nexus_sync_reason_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT,      VARIABLE,        cf.icnt,           LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{PC_FADDR,  VARIABLE,        cf.curr_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(cf.curr_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT)};
							idx_next                    = idx_data + 3;
							RefAddr                     <= cf.curr_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH: begin
							NexusMsg.fields[idx_data+0] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							idx_next                    = idx_data + 1;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC: begin
							NexusMsg.fields[idx_data+0] <= '{SYNC, VENDOR_FIXED, cf.sync_reason, $size(nexus_sync_reason_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{PC_FADDR, VARIABLE, cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT)};
							idx_next                    = idx_data + 3;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH: begin
							NexusMsg.fields[idx_data+0] <= '{BTYPE, VENDOR_FIXED, cf.btype, $size(nexus_btype_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{UADDR, VARIABLE, uaddr, LengthWoLeadingZeros(uaddr)};
							idx_next                    = idx_data + 3;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC: begin
							NexusMsg.fields[idx_data+0] <= '{SYNC, VENDOR_FIXED, cf.sync_reason, $size(nexus_sync_reason_e)};
							NexusMsg.fields[idx_data+1] <= '{BTYPE, VENDOR_FIXED, cf.btype, $size(nexus_btype_e)};
							NexusMsg.fields[idx_data+2] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+3] <= '{PC_FADDR, VARIABLE, cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT)};
							idx_next                    = idx_data + 4;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL: begin
							NexusMsg.fields[idx_data+0] <= '{RCODE, VENDOR_FIXED, cf.rcode, $size(nexus_rcode_e)};
							NexusMsg.fields[idx_data+1] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
							idx_next                    = idx_data + 2;
							if (cf.rcode == NEXUS_RCODE_HIST_OVERFLOW_REPEATED) begin
								NexusMsg.fields[idx_data+2] <= '{RDATA1, VENDOR_VARIABLE, cf.rdata1, LengthWoLeadingZeros(cf.rdata1)};
								idx_next                    = idx_data + 3;
							end
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_CORRELATION: begin
							// TCODE 33, emitted only as the "Program Trace Disabled"
							// event on trace-off. Layout per IEEE-ISTO 5001 §4.3.16:
							// EVCODE, CDF, ICNT, [CDATA=HIST when CDF>=1]. HIST is
							// included only when branch history is pending
							// (rdata0 > stop-bit); otherwise CDF=0 and it is omitted.
							NexusMsg.fields[idx_data+0] <= '{ETYPE, VENDOR_FIXED, NEXUS_EVCODE_PROGRAM_TRACE_DISABLED, NEXUS_MSG_EVCODE_WIDTH};
							if (cf.rdata0 > 'b1) begin
								NexusMsg.fields[idx_data+1] <= '{ECODE,  VENDOR_FIXED,    2'b01,     2};
								NexusMsg.fields[idx_data+2] <= '{ICNT,   VARIABLE,        cf.icnt,   LengthWoLeadingZeros(cf.icnt)};
								NexusMsg.fields[idx_data+3] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
								idx_next                    = idx_data + 4;
							end else begin
								NexusMsg.fields[idx_data+1] <= '{ECODE,  VENDOR_FIXED,    2'b00,     2};
								NexusMsg.fields[idx_data+2] <= '{ICNT,   VARIABLE,        cf.icnt,   LengthWoLeadingZeros(cf.icnt)};
								idx_next                    = idx_data + 3;
							end
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY: begin
							NexusMsg.fields[idx_data+0] <= '{BTYPE, VENDOR_FIXED, cf.btype, $size(nexus_btype_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{UADDR, VARIABLE, uaddr, LengthWoLeadingZeros(uaddr)};
							NexusMsg.fields[idx_data+3] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
							idx_next                    = idx_data + 4;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_DATA_TRACE_READ, NEXUS_MSG_DATA_TRACE_WRITE: begin
							NexusMsg.fields[idx_data+0] <= '{DSZ,       VENDOR_FIXED,    df_daq.dsz,        $size(nexus_dsz_e)};
							NexusMsg.fields[idx_data+1] <= '{ELSZ,      VENDOR_FIXED,    df_daq.elsz,       $size(nexus_elsz_e)};
							NexusMsg.fields[idx_data+2] <= '{UADDR,     VARIABLE,        df_daq.addr_idtag, LengthWoLeadingZeros(df_daq.addr_idtag)};
							NexusMsg.fields[idx_data+3] <= '{DQDATA,    VARIABLE,        df_daq.data,       LengthWoLeadingZeros(df_daq.data)};
							idx_next                    = idx_data + 4;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
					NEXUS_MSG_DATA_ACQUISITION: begin
						NexusMsg.fields[idx_data+0] <= '{IDTAG,     VENDOR_FIXED,    df_daq.addr_idtag, NEXUS_IDTAG_WIDTH};
						NexusMsg.fields[idx_data+1] <= '{DQDATA,    VENDOR_VARIABLE, df_daq.data,       LengthWoLeadingZeros(df_daq.data)};
						idx_next                    = idx_data + 2;
						// pragma translate_off
							$display("*** INFO (nexus_formatter, line %0d): (Msg %0d) DAQ idtag=%0h dqdata=%0h",
								`__LINE__, MsgNum, df_daq.addr_idtag, df_daq.data);
						// pragma translate_on
						SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
					end

					NEXUS_MSG_FLUSH: begin
						// TCODE only required, no other fields
						idx_next = IDX_SRC;
					end
						NEXUS_MSG_ERROR: begin
						NexusMsg.fields[idx_data+0] <= '{ETYPE,     FIXED,              err.etype,      $size(nexus_etype_e)};
						NexusMsg.fields[idx_data+1] <= '{ECODE,     VENDOR_FIXED,       err.ecode,      NEXUS_MSG_ECODE_WIDTH};
						idx_next                    = idx_data + 2;
						SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
					end

					default: begin
						// TBD: error unexpected trace_msg.tcode
					end
				endcase

				// add optional timestamp. Sync messages carry the absolute
				// timestamp; all other messages carry a delta relative to the
				// previously emitted TSTAMP. Always update the baseline on a
				// TSTAMP emission so the next delta is computed against the
				// actual emitted (absolute or delta-base) value.
				if (cs_proc.trTsEnable && trace_msg.tcode != NEXUS_MSG_FLUSH) begin
					NexusMsg.fields[idx_next]   <= '{TSTAMP, VENDOR_VARIABLE, ts_field, LengthWoLeadingZeros(ts_field)};
					TsLastEmitted               <= trace_msg.ts;
				end

			end
		end
	end

	assign nexus_msg = NexusMsg;

endmodule

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
