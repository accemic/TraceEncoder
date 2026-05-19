// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_nexus_decoder_tb.sv
 * @brief   Standalone replay test for ct_nexus_decoder against NexRv output.
 * @description Replays a captured ATB binary stream directly into
 *   `ct_nexus_decoder`, parses a checked-in NexRv `-dump` text file, and
 *   compares the decoded message sequence plus key fields.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

`default_nettype none

module ct_nexus_decoder_tb;

	timeunit 1ns;
	timeprecision 1ps;

	import tt::*;
	import string_pkg::*;
	import nexus_vendor::*;
	import nexus::*;
	import atb_pkg::*;
	import file_pkg::*;

	localparam int ATB_CLK_PERIOD = 5;
	localparam int DEFAULT_DRAIN_CYCLES = 128;
	localparam string DEFAULT_ATB_BIN =
		"../../../../../../modules/ctrace/test/fixtures/ct_nexus_decoder_tb/atb.bin";
	localparam string DEFAULT_NEXRV_DUMP =
		"../../../../../../modules/ctrace/test/fixtures/ct_nexus_decoder_tb/nexrv.dump.txt";

	typedef struct {
		int msg_idx;
		nexus_tcode_e tcode;
		bit has_sync;
		logic [63:0] sync;
		bit has_icnt;
		logic [63:0] icnt;
		bit has_pc_faddr;
		logic [63:0] pc_faddr;
		bit has_dsz;
		logic [63:0] dsz;
		bit has_elsz;
		logic [63:0] elsz;
		bit has_uaddr;
		logic [63:0] uaddr;
		bit has_idtag;
		logic [63:0] idtag;
		bit has_dqdata;
		logic [63:0] dqdata;
		bit has_tstamp;
		logic [63:0] tstamp;
	} expected_msg_t;

	logic atb_atclk = 1'b0;
	logic atb_atresetn;

	uwire dec_msg_valid;
	uwire dec_msg_error;
	nexus_message_t dec_msg;

	atb_if atb ();
	assign atb.afvalid = 1'b0;
	assign atb.syncreq = 1'b0;

	expected_msg_t expected_msgs[$];
	nexus_message_t actual_msgs[$];
	int actual_error_count = 0;
	int prev_dec_id = -1;

	always #ATB_CLK_PERIOD atb_atclk = ~atb_atclk;

	ct_nexus_decoder #(
		.INCLUDE_SRC    (1'b0),
		.INCLUDE_TSTAMP (1'b1)
	) dut (
		.atb_atclk,
		.atb_atresetn,
		.atb,
		.dec_msg_valid,
		.dec_msg_error,
		.dec_msg
	);

	task automatic clear_expected_msg(ref expected_msg_t msg);
		msg.msg_idx = 0;
		msg.tcode = nexus_tcode_e'(6'd0);
		msg.has_sync = 1'b0;
		msg.sync = '0;
		msg.has_icnt = 1'b0;
		msg.icnt = '0;
		msg.has_pc_faddr = 1'b0;
		msg.pc_faddr = '0;
		msg.has_dsz = 1'b0;
		msg.dsz = '0;
		msg.has_elsz = 1'b0;
		msg.elsz = '0;
		msg.has_uaddr = 1'b0;
		msg.uaddr = '0;
		msg.has_idtag = 1'b0;
		msg.idtag = '0;
		msg.has_dqdata = 1'b0;
		msg.dqdata = '0;
		msg.has_tstamp = 1'b0;
		msg.tstamp = '0;
	endtask

	task automatic parse_expected_field(ref expected_msg_t curr, input string payload);
		int lbrack_idx;
		int field_bits;
		logic [63:0] field_value;
		string field_name;
		string field_tail;

		lbrack_idx = index_of_char(payload, 8'd91);
		if (lbrack_idx <= 0) begin
			return;
		end

		field_name = payload.substr(0, lbrack_idx - 1);
		field_tail = payload.substr(lbrack_idx + 1, payload.len() - 1);
		if ($sscanf(field_tail, "%d]=0x%h", field_bits, field_value) < 2) begin
			void'(tt_assert(0,
				$sformatf("%0.2f: failed to parse NexRv field payload '%s'", $realtime, payload)));
			return;
		end

		if (field_name == "SYNC") begin
			curr.has_sync = 1'b1;
			curr.sync = field_value;
		end
		else if (field_name == "ICNT") begin
			curr.has_icnt = 1'b1;
			curr.icnt = field_value;
		end
		else if (field_name == "FADDR") begin
			curr.has_pc_faddr = 1'b1;
			curr.pc_faddr = field_value;
		end
		else if (field_name == "DSZ") begin
			curr.has_dsz = 1'b1;
			curr.dsz = field_value;
		end
		else if (field_name == "ELSZ") begin
			curr.has_elsz = 1'b1;
			curr.elsz = field_value;
		end
		else if (field_name == "DADDR") begin
			curr.has_uaddr = 1'b1;
			curr.uaddr = field_value;
		end
		else if (field_name == "IDTAG") begin
			curr.has_idtag = 1'b1;
			curr.idtag = field_value;
		end
		else if ((field_name == "DATA") || (field_name == "DQDATA")) begin
			curr.has_dqdata = 1'b1;
			curr.dqdata = field_value;
		end
		else if (field_name == "TSTAMP") begin
			curr.has_tstamp = 1'b1;
			curr.tstamp = field_value;
		end
	endtask

	task automatic parse_nexrv_dump(input string filepath);
		int fd;
		int line_num;
		int bits;
		int tcode_int;
		int msg_idx;
		string line;
		string payload;
		string msg_name;
		expected_msg_t curr;
		bit have_curr;

		check_file_exists(filepath);
		fd = $fopen(filepath, "r");
		void'(tt_assert(fd != 0,
			$sformatf("%0.2f: failed to open NexRv dump '%s'", $realtime, filepath)));
		if (fd == 0) begin
			return;
		end

		expected_msgs.delete();
		clear_expected_msg(curr);
		have_curr = 1'b0;
		line_num = 0;

		while ($fgets(line, fd)) begin
			line_num++;
			payload = payload_from_line(line);

			if ((payload == "") || starts_with(payload, "IDLE") || starts_with(payload, "INFO:")) begin
				continue;
			end
			if (!contains_char(payload, 8'd61)) begin
				continue;
			end

			if (starts_with(payload, "TCODE[")) begin
				if (have_curr) begin
					expected_msgs.push_back(curr);
				end
				clear_expected_msg(curr);
				if ($sscanf(payload, "TCODE[%d]=%d (MSG #%d) - %s", bits, tcode_int, msg_idx, msg_name) < 4) begin
					void'(tt_assert(0,
						$sformatf("%0.2f: line %0d: failed to parse NexRv TCODE line '%s'",
							$realtime, line_num, payload)));
					continue;
				end
				curr.msg_idx = msg_idx;
				curr.tcode = nexus_tcode_e'(tcode_int[5:0]);
				have_curr = 1'b1;
				continue;
			end

			if (have_curr) begin
				parse_expected_field(curr, payload);
			end
		end

		if (have_curr) begin
			expected_msgs.push_back(curr);
		end

		$fclose(fd);
		void'(tt_assert(expected_msgs.size() > 0,
			$sformatf("%0.2f: no expected messages parsed from '%s'", $realtime, filepath)));
	endtask

	task automatic load_atb_bytes(input string filepath, ref byte unsigned bytes[$]);
		int fd;
		int c;

		check_file_exists(filepath);
		fd = $fopen(filepath, "rb");
		void'(tt_assert(fd != 0,
			$sformatf("%0.2f: failed to open ATB binary '%s'", $realtime, filepath)));
		if (fd == 0) begin
			return;
		end

		bytes.delete();
		while (1) begin
			c = $fgetc(fd);
			if (c < 0) begin
				break;
			end
			bytes.push_back(byte'(c[7:0]));
		end
		$fclose(fd);

		void'(tt_assert(bytes.size() > 0,
			$sformatf("%0.2f: ATB binary '%s' is empty", $realtime, filepath)));
		void'(tt_assert((bytes.size() % 4) == 0,
			$sformatf("%0.2f: ATB binary '%s' size=%0d is not a multiple of 4 bytes",
				$realtime, filepath, bytes.size())));
	endtask

	task automatic replay_atb_bytes(input byte unsigned bytes[$]);
		logic [ATDATA_WIDTH-1:0] beat_data;

		for (int i = 0; i < bytes.size(); i += 4) begin
			beat_data = '0;
			beat_data[7:0]   = bytes[i + 0];
			beat_data[15:8]  = bytes[i + 1];
			beat_data[23:16] = bytes[i + 2];
			beat_data[31:24] = bytes[i + 3];

			@(posedge atb_atclk);
			atb.atvalid <= 1'b1;
			atb.atbytes <= ATBYTES_WIDTH'(3);
			atb.atdata  <= beat_data;
			atb.atid    <= '0;
			atb.afready <= 1'b0;
			while (!atb.atready) @(posedge atb_atclk);
		end

		@(posedge atb_atclk);
		atb.atvalid <= 1'b0;
		atb.atdata  <= {ATDATA_WIDTH{1'b1}};
	endtask

	function automatic bit actual_field_present(
		input nexus_message_t msg,
		input nexus_field_name_e name
	);
		actual_field_present = 1'b0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			if (msg.fields[i].name == name) begin
				actual_field_present = 1'b1;
			end
		end
	endfunction

	function automatic logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] actual_field_data(
		input nexus_message_t msg,
		input nexus_field_name_e name,
		output int width,
		output bit found
	);
		actual_field_data = '0;
		width = 0;
		found = 1'b0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			if (msg.fields[i].name == name) begin
				actual_field_data = msg.fields[i].data;
				width = msg.fields[i].data_width;
				found = 1'b1;
			end
		end
	endfunction

	task automatic compare_field(
		input nexus_message_t actual_msg,
		input int msg_pos,
		input string label,
		input nexus_field_name_e field_name,
		input bit expected_present,
		input logic [63:0] expected_value
	);
		int width;
		bit found;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] actual_value;

		if (!expected_present) begin
			return;
		end

		actual_value = actual_field_data(actual_msg, field_name, width, found);
		void'(tt_assert(found,
			$sformatf("%0.2f: msg[%0d] missing field %s", $realtime, msg_pos, label)));
		if (found) begin
			void'(tt_assert(actual_value[63:0] == expected_value,
				$sformatf("%0.2f: msg[%0d] field %s mismatch exp=0x%0h got=0x%0h",
					$realtime, msg_pos, label, expected_value, actual_value[63:0])));
		end
	endtask

	task automatic compare_messages();
		int compare_count;
		nexus_tcode_e actual_tcode;

		void'(tt_assert(actual_error_count == 0,
			$sformatf("%0.2f: decoder reported %0d decode errors", $realtime, actual_error_count)));
		void'(tt_assert(actual_msgs.size() == expected_msgs.size(),
			$sformatf("%0.2f: decoded message count mismatch exp=%0d got=%0d",
				$realtime, expected_msgs.size(), actual_msgs.size())));

		compare_count = (actual_msgs.size() < expected_msgs.size()) ? actual_msgs.size() : expected_msgs.size();
		for (int i = 0; i < compare_count; i++) begin
			actual_tcode = nexus_tcode_e'(actual_msgs[i].fields[0].data[5:0]);
			void'(tt_assert(actual_tcode == expected_msgs[i].tcode,
				$sformatf("%0.2f: msg[%0d] tcode mismatch exp=%0d (%s) got=%0d (%s)",
					$realtime, i, expected_msgs[i].tcode, expected_msgs[i].tcode.name(),
					actual_tcode, actual_tcode.name())));

			compare_field(actual_msgs[i], i, "SYNC",     SYNC,     expected_msgs[i].has_sync,     expected_msgs[i].sync);
			compare_field(actual_msgs[i], i, "ICNT",     ICNT,     expected_msgs[i].has_icnt,     expected_msgs[i].icnt);
			compare_field(actual_msgs[i], i, "PC_FADDR", PC_FADDR, expected_msgs[i].has_pc_faddr, expected_msgs[i].pc_faddr);
			compare_field(actual_msgs[i], i, "DSZ",      DSZ,      expected_msgs[i].has_dsz,      expected_msgs[i].dsz);
			compare_field(actual_msgs[i], i, "ELSZ",     ELSZ,     expected_msgs[i].has_elsz,     expected_msgs[i].elsz);
			compare_field(actual_msgs[i], i, "UADDR",    UADDR,    expected_msgs[i].has_uaddr,    expected_msgs[i].uaddr);
			compare_field(actual_msgs[i], i, "IDTAG",    IDTAG,    expected_msgs[i].has_idtag,    expected_msgs[i].idtag);
			compare_field(actual_msgs[i], i, "DQDATA",   DQDATA,   expected_msgs[i].has_dqdata,   expected_msgs[i].dqdata);
			compare_field(actual_msgs[i], i, "TSTAMP",   TSTAMP,   expected_msgs[i].has_tstamp,   expected_msgs[i].tstamp);
		end
	endtask

	always_ff @(posedge atb_atclk) begin
		nexus_tcode_e tcode_dbg;
		if (!atb_atresetn) begin
			prev_dec_id <= -1;
			actual_error_count <= 0;
			actual_msgs.delete();
		end
		else if (dec_msg_valid && (dec_msg.fields[0].name == TCODE) && (dec_msg.id != prev_dec_id)) begin
			prev_dec_id <= dec_msg.id;
			actual_msgs.push_back(dec_msg);
			if (dec_msg_error) begin
				actual_error_count <= actual_error_count + 1;
			end
			tcode_dbg = nexus_tcode_e'(dec_msg.fields[0].data[5:0]);
			$display("%0.2f: ACTUAL msg[%0d] tcode=%0d (%s)",
				$realtime, actual_msgs.size(), dec_msg.fields[0].data[5:0],
				tcode_dbg.name());
		end
	end

	initial begin
		string atb_bin_path;
		string nexrv_dump_path;
		int drain_cycles;
		byte unsigned atb_bytes[$];
		bit plusarg_seen;

		atb_atresetn = 1'b0;
		atb.atvalid  = 1'b0;
		atb.atbytes  = '0;
		atb.atdata   = {ATDATA_WIDTH{1'b1}};
		atb.atid     = '0;
		atb.afready  = 1'b0;

		atb_bin_path = DEFAULT_ATB_BIN;
		nexrv_dump_path = DEFAULT_NEXRV_DUMP;
		drain_cycles = DEFAULT_DRAIN_CYCLES;
		plusarg_seen = $value$plusargs("CT_ATB_BIN=%s", atb_bin_path);
		plusarg_seen = $value$plusargs("CT_NEXRV_DUMP=%s", nexrv_dump_path);
		plusarg_seen = $value$plusargs("CT_DRAIN_CYCLES=%d", drain_cycles);

		$display("%0.2f: nexus decoder replay: ATB='%s' NEXRV='%s' DRAIN=%0d",
			$realtime, atb_bin_path, nexrv_dump_path, drain_cycles);

		parse_nexrv_dump(nexrv_dump_path);
		load_atb_bytes(atb_bin_path, atb_bytes);

		repeat (4) @(posedge atb_atclk);
		atb_atresetn = 1'b1;
		repeat (2) @(posedge atb_atclk);

		replay_atb_bytes(atb_bytes);
		repeat (drain_cycles) @(posedge atb_atclk);

		compare_messages();
		tt_evaluate();
		$finish();
	end

endmodule

`default_nettype wire
