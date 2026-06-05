// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>
 *
 * @brief   Testbench helper: provides tasks to construct and initialize a nexus_message_t instance.
 *
 * This module encapsulates common routines for creating and clearing fields of a
 * `nexus_message_t` in a structured, readable manner. It offers:
 *   - `clear_message(nexus_msg, reset_id)`: reset all fields to defaults, if reset_id == 1, the message ID is set to "0"
 *   - `compose_xxx_msg(...)`: populate msg with given parameters.
 *
 * Usage example in a testbench:
 *
 *   import nexus_msg_helper_pkg::*;
 *
 *   nexus_message_t     nexus_msg;
 *
 *   initial begin
 *     clear_msg(nexus_msg,1);
 *     ...
 *     compose_sync_msg(nexus_msg, NEXUS_MSG_PROGRAM_TRACE_SYNC, NEXUS_SYNC_EXIT_FROM_SYS_RST, 1, 32'hFAAA);
 *     ...
 */

package nexus_msg_helper_pkg;

import nexus_vendor::*;
import nexus::*;

task automatic init_field(
		ref   nexus_message_t                               msg,
		input integer                                       id,
		input nexus_field_name_e                            name,
		input nexus_field_type_e                            field_type,
		input logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0]        data,
		input logic [$clog2(NEXUS_MAX_FIELD_DATA_WIDTH):0]  data_width
	);
		msg.fields[id].name       = name;
		msg.fields[id].field_type = field_type;
		msg.fields[id].data       = data;
		msg.fields[id].data_width = data_width;
	endtask : init_field

	task automatic clear_msg(
		ref nexus_message_t  msg,
		input logic reset_id
	);
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			init_field(msg, i, INVALID, FIELD_INVALID, 0, 0);
		end
		if (reset_id) begin
			msg.id = 0;
		end
	endtask

	task automatic send_sync_msg(
		ref   logic                  clk,
		ref   nexus_message_t        msg,
		input nexus_tcode_e          tcode,
		input nexus_src_t            source_id,
		input nexus_sync_reason_e    sync_reason,
		input nexus_icnt_t           icnt,
		input nexus_addr_t           faddr,
		input nexus_ts_t             ts
	);
		clear_msg(msg,0);
		init_field(msg, 0, TCODE,    FIXED,     tcode,         $bits(nexus_tcode_e));
		init_field(msg, 1, SRC,      FIXED,     source_id,     NEXUS_MSG_SOURCE_WIDTH);
		init_field(msg, 2, SYNC,     FIXED,     sync_reason,   $bits(nexus_sync_reason_e));
		init_field(msg, 3, ICNT,     VARIABLE,  icnt,          LengthWoLeadingZeros(icnt));
		init_field(msg, 4, PC_FADDR, VARIABLE,  faddr,         LengthWoLeadingZeros(faddr));
		init_field(msg, 5, TSTAMP,   VARIABLE,  ts,            LengthWoLeadingZeros(ts));
		msg.id = msg.id+1;
		@(posedge clk);
		clear_msg(msg,0);
	endtask


	task automatic send_flush_msg(
		ref   logic clk,
		ref   nexus_message_t                                  msg
	);
		clear_msg(msg,0);
		init_field(msg, 0, TCODE, FIXED, NEXUS_MSG_FLUSH, 6);
		msg.id = msg.id+1;
		@(posedge clk);
		clear_msg(msg,0);
	endtask

	// ------------------------------------------------------------------
	// NEXRv message catalog — `compose_*` tasks
	//
	// These mirror the message shapes listed in the NexRv reference
	// decoder's NexRvMsg.h, producing a fully
	// populated `nexus_message_t` without touching the clock. Intended for
	// testbenches that enqueue `nexus_message_t` items and drive them later
	// (e.g. the MSEO/MDO formatter TB).
	//
	// Layout convention (matches ct_L2_nexus_formatter.sv):
	//   [0] TCODE                (FIXED, 6 bits)
	//   [1] SRC (optional)       (VENDOR_FIXED, NEXUS_MSG_SOURCE_WIDTH)
	//   [..] message-specific middle fields
	//   [last] TSTAMP            (VENDOR_VARIABLE, width = LengthWoLeadingZeros)
	//
	// Variable-field widths are minimised via LengthWoLeadingZeros to
	// replicate what the real L2 formatter emits at runtime. Caller passes
	// raw integer payloads; the helper trims leading zeros.
	// ------------------------------------------------------------------

	// Internal helper: put TCODE (and optional SRC) at the start of the
	// message. `next_idx` returns the first free field index after the
	// prefix so message-specific compose tasks can populate the middle.
	// Uses direct struct-member writes rather than calling init_field —
	// SystemVerilog functions may not enable tasks, and this construct is
	// reused by function-based callers.
	task automatic prepend_header(
			ref   nexus_message_t  msg,
			input nexus_tcode_e    tcode,
			input nexus_src_t      src,
			input bit              include_src,
			output int             next_idx
		);
			clear_msg(msg, 0);
			msg.fields[0].name       = TCODE;
			msg.fields[0].field_type = FIXED;
			msg.fields[0].data       = tcode;
			msg.fields[0].data_width = 6;
			if (include_src) begin
				msg.fields[1].name       = SRC;
				msg.fields[1].field_type = VENDOR_FIXED;
				msg.fields[1].data       = src;
				msg.fields[1].data_width = NEXUS_MSG_SOURCE_WIDTH;
				next_idx = 2;
			end else begin
				next_idx = 1;
			end
		endtask : prepend_header

	// #1 Ownership (TCODE=2): TCODE, [SRC], PROCESS(VAR), TSTAMP(VAR)
	task automatic compose_ownership_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input logic [NEXUS_MSG_PROCESS_WIDTH-1:0] process_id,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_OWNERSHIP_TRACE, src, include_src, i);
			init_field(msg, i,   PROCESS, VENDOR_VARIABLE, process_id, LengthWoLeadingZeros(process_id));
			init_field(msg, i+1, TSTAMP,  VENDOR_VARIABLE, tstamp,     LengthWoLeadingZeros(tstamp));
		endtask

	// #2 DirectBranch (TCODE=3): TCODE, [SRC], ICNT(VAR), TSTAMP(VAR)
	task automatic compose_direct_branch_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input nexus_icnt_t     icnt,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH, src, include_src, i);
			init_field(msg, i,   ICNT,   VARIABLE,        icnt,   LengthWoLeadingZeros(icnt));
			init_field(msg, i+1, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
		endtask

	// #3 IndirectBranch (TCODE=4): TCODE, [SRC], BTYPE(FIXED,2), ICNT(VAR), UADDR(VAR), TSTAMP(VAR)
	task automatic compose_indirect_branch_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input nexus_btype_e    btype,
			input nexus_icnt_t     icnt,
			input nexus_addr_t     uaddr,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH, src, include_src, i);
			init_field(msg, i,   BTYPE,  VENDOR_FIXED,    btype,  $bits(nexus_btype_e));
			init_field(msg, i+1, ICNT,   VARIABLE,        icnt,   LengthWoLeadingZeros(icnt));
			init_field(msg, i+2, UADDR,  VARIABLE,        uaddr,  LengthWoLeadingZeros(uaddr));
			init_field(msg, i+3, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
		endtask

	// #4/#5 DataWrite/DataRead (TCODE=5/6): TCODE, [SRC], DSZ(F,4), ELSZ(F,3), DADDR(V), DATA(V), TSTAMP(V)
	task automatic compose_data_trace_msg(
			ref   nexus_message_t  msg,
			input nexus_tcode_e    tcode,       // must be DATA_TRACE_WRITE or DATA_TRACE_READ
			input nexus_src_t      src,
			input bit              include_src,
			input nexus_dsz_e      dsz,
			input nexus_elsz_e     elsz,
			input nexus_addr_t     daddr,
			input logic [NEXUS_MSG_DATA_WIDTH-1:0] data,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, tcode, src, include_src, i);
			init_field(msg, i,   DSZ,    VENDOR_FIXED,    dsz,    $bits(nexus_dsz_e));
			init_field(msg, i+1, ELSZ,   VENDOR_FIXED,    elsz,   $bits(nexus_elsz_e));
			init_field(msg, i+2, UADDR,  VARIABLE,        daddr,  LengthWoLeadingZeros(daddr));
			init_field(msg, i+3, DATA,   VARIABLE,        data,   LengthWoLeadingZeros(data));
			init_field(msg, i+4, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
		endtask

	// #6 DataAcquisition (TCODE=7): TCODE, [SRC], IDTAG(F,12), DQDATA(VAR), TSTAMP(VAR)
	task automatic compose_daq_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input nexus_idtag_t    idtag,
			input logic [NEXUS_DQDATA_WIDTH-1:0] dqdata,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_DATA_ACQUISITION, src, include_src, i);
			init_field(msg, i,   IDTAG,  VENDOR_FIXED,    idtag,  NEXUS_IDTAG_WIDTH);
			init_field(msg, i+1, DQDATA, VENDOR_VARIABLE, dqdata, LengthWoLeadingZeros(dqdata));
			init_field(msg, i+2, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
		endtask

	// #7 Error (TCODE=8): TCODE, [SRC], ETYPE(F,4), ECODE(F,8), TSTAMP(VAR)
	task automatic compose_error_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input logic [3:0]      etype,
			input logic [7:0]      ecode,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_ERROR, src, include_src, i);
			init_field(msg, i,   ETYPE,  FIXED,           etype,  4);
			init_field(msg, i+1, ECODE,  VENDOR_FIXED,    ecode,  NEXUS_MSG_ECODE_WIDTH);
			init_field(msg, i+2, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
		endtask

	// #8/#9 ProgTraceSync / DirectBranchSync (TCODE=9/11): TCODE, [SRC], SYNC(F,4), ICNT(V), FADDR(V), TSTAMP(V)
	task automatic compose_prog_trace_sync_msg(
			ref   nexus_message_t     msg,
			input nexus_tcode_e       tcode,     // NEXUS_MSG_PROGRAM_TRACE_SYNC or ..._DIRECT_BRANCH_SYNC
			input nexus_src_t         src,
			input bit                 include_src,
			input nexus_sync_reason_e sync_reason,
			input nexus_icnt_t        icnt,
			input nexus_addr_t        faddr,
			input nexus_ts_t          tstamp
		);
			int i;
			prepend_header(msg, tcode, src, include_src, i);
			init_field(msg, i,   SYNC,     VENDOR_FIXED,    sync_reason, $bits(nexus_sync_reason_e));
			init_field(msg, i+1, ICNT,     VARIABLE,        icnt,        LengthWoLeadingZeros(icnt));
			init_field(msg, i+2, PC_FADDR, VARIABLE,        faddr,       LengthWoLeadingZeros(faddr));
			init_field(msg, i+3, TSTAMP,   VENDOR_VARIABLE, tstamp,      LengthWoLeadingZeros(tstamp));
		endtask

	// #10 IndirectBranchSync (TCODE=12): TCODE, [SRC], SYNC(F,4), BTYPE(F,2), ICNT(V), FADDR(V), TSTAMP(V)
	task automatic compose_indirect_branch_sync_msg(
			ref   nexus_message_t     msg,
			input nexus_src_t         src,
			input bit                 include_src,
			input nexus_sync_reason_e sync_reason,
			input nexus_btype_e       btype,
			input nexus_icnt_t        icnt,
			input nexus_addr_t        faddr,
			input nexus_ts_t          tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC, src, include_src, i);
			init_field(msg, i,   SYNC,     VENDOR_FIXED,    sync_reason, $bits(nexus_sync_reason_e));
			init_field(msg, i+1, BTYPE,    VENDOR_FIXED,    btype,       $bits(nexus_btype_e));
			init_field(msg, i+2, ICNT,     VARIABLE,        icnt,        LengthWoLeadingZeros(icnt));
			init_field(msg, i+3, PC_FADDR, VARIABLE,        faddr,       LengthWoLeadingZeros(faddr));
			init_field(msg, i+4, TSTAMP,   VENDOR_VARIABLE, tstamp,      LengthWoLeadingZeros(tstamp));
		endtask

	// #11 ResourceFull (TCODE=27): TCODE, [SRC], RCODE(F,4), RDATA(V), TSTAMP(V)
	task automatic compose_resource_full_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input nexus_rcode_e    rcode,
			input nexus_rdata_t    rdata,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL, src, include_src, i);
			init_field(msg, i,   RCODE,  VENDOR_FIXED,    rcode,  $bits(nexus_rcode_e));
			init_field(msg, i+1, RDATA0, VENDOR_VARIABLE, rdata,  LengthWoLeadingZeros(rdata));
			init_field(msg, i+2, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
		endtask

	// #12 IndirectBranchHist (TCODE=28): TCODE, [SRC], BTYPE(F,2), ICNT(V), UADDR(V), HIST(V), TSTAMP(V)
	// Note: HIST is carried in the RDATA0 field slot in our package.
	task automatic compose_indirect_branch_hist_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input nexus_btype_e    btype,
			input nexus_icnt_t     icnt,
			input nexus_addr_t     uaddr,
			input logic [NEXUS_MSG_HIST_WIDTH-1:0] hist,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, src, include_src, i);
			init_field(msg, i,   BTYPE,  VENDOR_FIXED,    btype,  $bits(nexus_btype_e));
			init_field(msg, i+1, ICNT,   VARIABLE,        icnt,   LengthWoLeadingZeros(icnt));
			init_field(msg, i+2, UADDR,  VARIABLE,        uaddr,  LengthWoLeadingZeros(uaddr));
			init_field(msg, i+3, RDATA0, VENDOR_VARIABLE, hist,   LengthWoLeadingZeros(hist));
			init_field(msg, i+4, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
		endtask

	// #13 IndirectBranchHistSync (TCODE=29): TCODE, [SRC], SYNC(F), BTYPE(F), ICNT(V), FADDR(V), HIST(V), TSTAMP(V)
	task automatic compose_indirect_branch_hist_sync_msg(
			ref   nexus_message_t     msg,
			input nexus_src_t         src,
			input bit                 include_src,
			input nexus_sync_reason_e sync_reason,
			input nexus_btype_e       btype,
			input nexus_icnt_t        icnt,
			input nexus_addr_t        faddr,
			input logic [NEXUS_MSG_HIST_WIDTH-1:0] hist,
			input nexus_ts_t          tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC, src, include_src, i);
			init_field(msg, i,   SYNC,     VENDOR_FIXED,    sync_reason, $bits(nexus_sync_reason_e));
			init_field(msg, i+1, BTYPE,    VENDOR_FIXED,    btype,       $bits(nexus_btype_e));
			init_field(msg, i+2, ICNT,     VARIABLE,        icnt,        LengthWoLeadingZeros(icnt));
			init_field(msg, i+3, PC_FADDR, VARIABLE,        faddr,       LengthWoLeadingZeros(faddr));
			init_field(msg, i+4, RDATA0,   VENDOR_VARIABLE, hist,        LengthWoLeadingZeros(hist));
			init_field(msg, i+5, TSTAMP,   VENDOR_VARIABLE, tstamp,      LengthWoLeadingZeros(tstamp));
		endtask

	// #14 RepeatBranch (TCODE=30): TCODE, [SRC], BCNT(V), TSTAMP(V)
	// Note: BCNT reuses the ICNT field-name slot for labelling.
	task automatic compose_repeat_branch_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input logic [NEXUS_MSG_I_CNT_WIDTH-1:0] bcnt,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_PROGRAM_TRACE_REPEAT_BRANCH, src, include_src, i);
			init_field(msg, i,   ICNT,   VARIABLE,        bcnt,   LengthWoLeadingZeros(bcnt));
			init_field(msg, i+1, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
		endtask

	// #15 ProgTraceCorrelation (TCODE=33): TCODE, [SRC], EVCODE(F,4), CDF(F,2), ICNT(V), [HIST(V) if CDF=1], TSTAMP(V)
	task automatic compose_prog_trace_correlation_msg(
			ref   nexus_message_t  msg,
			input nexus_src_t      src,
			input bit              include_src,
			input logic [NEXUS_MSG_EVCODE_WIDTH-1:0] evcode,
			input logic [1:0]      cdf,
			input nexus_icnt_t     icnt,
			input logic [NEXUS_MSG_HIST_WIDTH-1:0] hist,
			input bit              include_hist,
			input nexus_ts_t       tstamp
		);
			int i;
			prepend_header(msg, NEXUS_MSG_PROGRAM_TRACE_CORRELATION, src, include_src, i);
			init_field(msg, i,   ETYPE,  VENDOR_FIXED,    evcode, NEXUS_MSG_EVCODE_WIDTH);
			init_field(msg, i+1, ECODE,  VENDOR_FIXED,    cdf,    2);
			init_field(msg, i+2, ICNT,   VARIABLE,        icnt,   LengthWoLeadingZeros(icnt));
			if (include_hist) begin
				init_field(msg, i+3, RDATA0, VENDOR_VARIABLE, hist,   LengthWoLeadingZeros(hist));
				init_field(msg, i+4, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
			end else begin
				init_field(msg, i+3, TSTAMP, VENDOR_VARIABLE, tstamp, LengthWoLeadingZeros(tstamp));
			end
		endtask

	// Flush (TCODE=36): TCODE only, no other fields. No TSTAMP.
	task automatic compose_flush_msg(
			ref   nexus_message_t  msg
		);
			clear_msg(msg, 0);
			init_field(msg, 0, TCODE, FIXED, NEXUS_MSG_FLUSH, 6);
		endtask

endpackage : nexus_msg_helper_pkg
`default_nettype wire