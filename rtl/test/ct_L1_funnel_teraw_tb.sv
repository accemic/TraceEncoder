// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @file    ct_L1_funnel_teraw_tb.sv
 * @brief   Directed testbench for ct_L1_funnel in the dual-framing
 *          configuration (EN_TE_RAW=1): E-Trace reference-raw te_inst
 *          channels merged into ONE self-describing byte container (CTMX),
 *          optionally mixed with Nexus MSEO channels.
 * @description Exercises length-prefixed packet parsing (header byte
 *   {1'b0, msg_type, payload_len}), source-tag insertion on source change
 *   and in tag-always mode, zero-length packets, packet atomicity across
 *   sources, tag beats under backpressure (input must NOT be consumed and
 *   the tag must not be duplicated), and mixed MSEO/te_raw operation with
 *   per-beat ATBYTES.
 *
 */
`default_nettype none

module ct_L1_funnel_teraw_tb;

	import tt::*;
	import atb_pkg::*;
	import nexus::*;

	localparam int N_STREAMS = 3;
	localparam int MAX_PRIO = 3;
	localparam int CLK_PERIOD = 2;
	localparam int TIMEOUT_CYCLES = 2000;
	localparam logic [ATBYTES_WIDTH-1:0] FULL_ATBYTES = ATBYTES_WIDTH'(3);
	localparam logic [ATBYTES_WIDTH-1:0] BYTE_ATBYTES = ATBYTES_WIDTH'(0);

	logic atclk = 1'b0;
	logic atresetn;
	logic global_flush_req;
	logic [$clog2(MAX_PRIO+1)-1:0] chan_prio [N_STREAMS];
	logic chan_flush_participate [N_STREAMS];
	logic chan_flush_req [N_STREAMS];
	logic chan_te_raw [N_STREAMS];
	logic te_tag_always;
	logic te_tag_resync;
	logic chan_flush_done [N_STREAMS];
	logic global_flush_done;
	logic [ATDATA_WIDTH-1:0] drv_atdata [N_STREAMS];
	logic [ATBYTES_WIDTH-1:0] drv_atbytes [N_STREAMS];
	logic [ATID_WIDTH-1:0] drv_atid [N_STREAMS];
	logic drv_atvalid [N_STREAMS];
	logic drv_afready [N_STREAMS];
	logic mon_atready [N_STREAMS];

	atb_if atb_in [N_STREAMS] ();
	atb_if atb_out ();

	typedef struct {
		logic [ATDATA_WIDTH-1:0] data;
		logic [ATBYTES_WIDTH-1:0] bytes;
		string desc;
	} beat_item_t;

	beat_item_t expected_beats[$];
	string active_test_desc;

	ct_L1_funnel #(
		.N_STREAMS(N_STREAMS),
		.MAX_PRIO(MAX_PRIO),
		.MDO_WIDTH(6),
		.EN_TE_RAW(1)
	) dut (
		.atclk,
		.atresetn,
		.chan_prio,
		.chan_flush_participate,
		.chan_flush_req,
		.chan_te_raw,
		.te_tag_always,
		.te_tag_resync,
		.global_flush_req,
		.chan_flush_done,
		.global_flush_done,
		.atb_in,
		.atb_out
	);

	always #(CLK_PERIOD/2.0) atclk = ~atclk;

	generate
		for (genvar gi = 0; gi < N_STREAMS; gi++) begin : g_tb_if_map
			assign atb_in[gi].atdata = drv_atdata[gi];
			assign atb_in[gi].atbytes = drv_atbytes[gi];
			assign atb_in[gi].atid = drv_atid[gi];
			assign atb_in[gi].atvalid = drv_atvalid[gi];
			assign atb_in[gi].afready = drv_afready[gi];
			assign mon_atready[gi] = atb_in[gi].atready;
		end
	endgenerate

	// --- helpers -------------------------------------------------------
	// The packetizer drives one byte in the low lane, all other lanes 1.
	function automatic logic [ATDATA_WIDTH-1:0] te_beat(input logic [7:0] b);
		return {{(ATDATA_WIDTH-8){1'b1}}, b};
	endfunction

	// header byte: {1'b0, msg_type[1:0], payload_len[4:0]}; TE_INST = 2.
	function automatic logic [7:0] te_hdr(input int len);
		return {1'b0, 2'd2, 5'(len)};
	endfunction

	function automatic logic [7:0] tag_byte(input int src);
		return {1'b1, 7'(src)};
	endfunction

	function automatic logic [7:0] mk_chunk(
		input logic [5:0] mdo,
		input nexus_mseo_e mseo
	);
		return {mdo, mseo};
	endfunction

	function automatic logic [ATDATA_WIDTH-1:0] mk_beat(
		input logic [7:0] c0, input logic [7:0] c1,
		input logic [7:0] c2, input logic [7:0] c3
	);
		return {c3, c2, c1, c0};
	endfunction

	localparam logic [7:0] PAD_CHUNK = 8'hFF; // {6'h3F, END_IDLE}

	task automatic clear_all_channels();
		int i;
		for (i = 0; i < N_STREAMS; i = i + 1) begin
			drv_atdata[i] = '0;
			drv_atbytes[i] = BYTE_ATBYTES;
			drv_atid[i] = ATID_WIDTH'(i + 1);
			drv_atvalid[i] = 1'b0;
			drv_afready[i] = 1'b0;
		end
	endtask

	task automatic reset_dut(input bit tag_always = 1'b0);
		int i;
		atresetn = 1'b0;
		global_flush_req = 1'b0;
		te_tag_always = tag_always;
		te_tag_resync = 1'b0;
		atb_out.atready = 1'b1;
		atb_out.afvalid = 1'b0;
		atb_out.syncreq = 1'b0;
		for (i = 0; i < N_STREAMS; i = i + 1) begin
			chan_prio[i] = 1;
			chan_flush_participate[i] = 1'b1;
			chan_flush_req[i] = 1'b0;
			chan_te_raw[i] = 1'b1;
		end
		clear_all_channels();
		repeat (3) @(posedge atclk);
		atresetn = 1'b1;
		repeat (2) @(posedge atclk);
	endtask

	task automatic expect_beat(
		input logic [ATDATA_WIDTH-1:0] data,
		input logic [ATBYTES_WIDTH-1:0] bytes,
		input string desc
	);
		beat_item_t item;
		item.data = data;
		item.bytes = bytes;
		item.desc = desc;
		expected_beats.push_back(item);
	endtask

	task automatic expect_te_byte(input logic [7:0] b, input string desc);
		expect_beat(te_beat(b), BYTE_ATBYTES, desc);
	endtask

	task automatic wait_handshake(input int ch);
		int cycles;
		cycles = 0;
		while (1) begin
			@(posedge atclk);
			cycles = cycles + 1;
			if (drv_atvalid[ch] && mon_atready[ch]) begin
				@(negedge atclk);
				break;
			end
			if (cycles > TIMEOUT_CYCLES) begin
				void'(tt_assert(1'b0, $sformatf(
					"%0t: timeout waiting for handshake on channel %0d during %s",
					$time, ch, active_test_desc)));
				break;
			end
		end
	endtask

	task automatic send_te_byte(input int ch, input logic [7:0] b);
		drv_atdata[ch] = te_beat(b);
		drv_atbytes[ch] = BYTE_ATBYTES;
		drv_atvalid[ch] = 1'b1;
		wait_handshake(ch);
		drv_atvalid[ch] = 1'b0;
	endtask

	task automatic send_mseo_beat(input int ch, input logic [ATDATA_WIDTH-1:0] data);
		drv_atdata[ch] = data;
		drv_atbytes[ch] = FULL_ATBYTES;
		drv_atvalid[ch] = 1'b1;
		wait_handshake(ch);
		drv_atvalid[ch] = 1'b0;
	endtask

	// One te_inst packet: header + `len` payload bytes (0x10+i pattern).
	task automatic send_te_packet(input int ch, input int len, input logic [7:0] seed);
		int i;
		send_te_byte(ch, te_hdr(len));
		for (i = 0; i < len; i = i + 1) begin
			send_te_byte(ch, seed + 8'(i));
		end
	endtask

	task automatic expect_te_packet(input int len, input logic [7:0] seed, input string desc);
		int i;
		expect_te_byte(te_hdr(len), {desc, " header"});
		for (i = 0; i < len; i = i + 1) begin
			expect_te_byte(seed + 8'(i), $sformatf("%s payload %0d", desc, i));
		end
	endtask

	task automatic drain_expected(input string desc);
		int cycles;
		cycles = 0;
		while (expected_beats.size() > 0) begin
			@(posedge atclk);
			cycles = cycles + 1;
			if (cycles > TIMEOUT_CYCLES) begin
				void'(tt_assert(1'b0, $sformatf(
					"%0t: timeout draining expected beats for %s, remaining=%0d",
					$time, desc, expected_beats.size())));
				expected_beats.delete();
				break;
			end
		end
	endtask

	// Test 1: single te_raw source -- exactly ONE tag, then the packets
	// byte-identically (payload bytes with bit 7 set must NOT be mistaken
	// for tags).
	task automatic test_single_source_tag_once();
		tt_testcase tc;
		tc = create_testcase("TeRaw_SingleSourceTagOnce");
		active_test_desc = tc.name;
		reset_dut();

		expect_te_byte(tag_byte(0), "tag src0");
		expect_te_packet(3, 8'h80, "pkt A");   // payload bytes 0x80..0x82: bit7 set
		expect_te_packet(2, 8'h11, "pkt B");
		send_te_packet(0, 3, 8'h80);
		send_te_packet(0, 2, 8'h11);
		drain_expected(tc.name);
		void'(tc.tt_assert(dut.InPacketQ[0] == 1'b0, "channel must leave packet state after last payload byte"));
		void'(tc.tt_assert(dut.LastSrcValidQ == 1'b1, "source tag state must be armed"));
	endtask

	// Test 2: alternating sources -- one tag per source change, packets
	// never interleaved.
	task automatic test_source_change_tag();
		tt_testcase tc;
		tc = create_testcase("TeRaw_TagOnSourceChange");
		active_test_desc = tc.name;
		reset_dut();

		// Only channel 0 has data first, then only channel 2, then 0 again.
		expect_te_byte(tag_byte(0), "tag src0");
		expect_te_packet(2, 8'h20, "src0 pkt");
		send_te_packet(0, 2, 8'h20);
		drain_expected("src0");

		expect_te_byte(tag_byte(2), "tag src2");
		expect_te_packet(4, 8'h30, "src2 pkt");
		send_te_packet(2, 4, 8'h30);
		drain_expected("src2");

		expect_te_byte(tag_byte(0), "tag src0 again");
		expect_te_packet(1, 8'h40, "src0 pkt2");
		send_te_packet(0, 1, 8'h40);
		drain_expected(tc.name);
	endtask

	// Test 3: tag-always mode -- a tag ahead of EVERY packet, same source.
	task automatic test_tag_always();
		tt_testcase tc;
		tc = create_testcase("TeRaw_TagAlways");
		active_test_desc = tc.name;
		reset_dut(1'b1);

		expect_te_byte(tag_byte(1), "tag #1");
		expect_te_packet(2, 8'h50, "pkt 1");
		expect_te_byte(tag_byte(1), "tag #2");
		expect_te_packet(2, 8'h60, "pkt 2");
		send_te_packet(1, 2, 8'h50);
		send_te_packet(1, 2, 8'h60);
		drain_expected(tc.name);
	endtask

	// Test 4: zero-length payload packet (header only) is a complete packet.
	task automatic test_zero_length_packet();
		tt_testcase tc;
		tc = create_testcase("TeRaw_ZeroLengthPacket");
		active_test_desc = tc.name;
		reset_dut(1'b1);

		expect_te_byte(tag_byte(0), "tag");
		expect_te_byte(te_hdr(0), "zero-length header");
		expect_te_byte(tag_byte(0), "tag after zero-length");
		expect_te_packet(1, 8'h77, "next pkt");
		send_te_byte(0, te_hdr(0));
		send_te_packet(0, 1, 8'h77);
		drain_expected(tc.name);
		void'(tc.tt_assert(dut.InPacketQ[0] == 1'b0, "zero-length packet must not leave the channel in-packet"));
	endtask

	// Test 5: backpressure exactly on the tag beat -- the input byte must
	// not be consumed and the tag must appear exactly once.
	task automatic test_tag_under_backpressure();
		tt_testcase tc;
		int i;
		tc = create_testcase("TeRaw_TagUnderBackpressure");
		active_test_desc = tc.name;
		reset_dut();

		atb_out.atready = 1'b0;
		drv_atdata[0] = te_beat(te_hdr(2));
		drv_atbytes[0] = BYTE_ATBYTES;
		drv_atvalid[0] = 1'b1;
		for (i = 0; i < 5; i = i + 1) begin
			@(posedge atclk);
			void'(tc.tt_assert(mon_atready[0] == 1'b0,
				"input must not be consumed while the tag beat is stalled"));
		end
		expect_te_byte(tag_byte(0), "tag after stall");
		expect_te_byte(te_hdr(2), "header after stall");
		expect_te_byte(8'hA1, "payload 0");
		expect_te_byte(8'hA2, "payload 1");
		@(negedge atclk);
		atb_out.atready = 1'b1;
		wait_handshake(0);
		drv_atvalid[0] = 1'b0;
		send_te_byte(0, 8'hA1);
		send_te_byte(0, 8'hA2);
		drain_expected(tc.name);
	endtask

	// Test 6: mixed framing -- channel 0 te_raw, channel 1 Nexus MSEO.
	// Both are merged; ATBYTES follows the selected channel's framing.
	task automatic test_mixed_framing();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] m1;
		tc = create_testcase("TeRaw_MixedWithMseo");
		active_test_desc = tc.name;
		reset_dut();
		chan_te_raw[1] = 1'b0;          // channel 1 stays Nexus/MSEO
		chan_prio[2] = 0;               // channel 2 off for this test

		m1 = mk_beat(mk_chunk(6'h08, START_TRANSMISSION),
		             mk_chunk(6'h0B, END_IDLE), PAD_CHUNK, PAD_CHUNK);

		expect_te_byte(tag_byte(0), "tag src0");
		expect_te_packet(2, 8'hB0, "te pkt");
		send_te_packet(0, 2, 8'hB0);
		drain_expected("te part");

		expect_beat(m1, FULL_ATBYTES, "mseo message");
		send_mseo_beat(1, m1);
		drain_expected(tc.name);
	endtask

	// Test 7: te_tag_resync -- after re-arming the capture the next packet
	// must carry a tag again, even though the source did not change.
	task automatic test_tag_resync();
		tt_testcase tc;
		tc = create_testcase("TeRaw_TagResync");
		active_test_desc = tc.name;
		reset_dut();

		expect_te_byte(tag_byte(0), "tag src0");
		expect_te_packet(1, 8'hC0, "pkt before resync");
		send_te_packet(0, 1, 8'hC0);
		drain_expected("before resync");

		te_tag_resync = 1'b1;
		repeat (2) @(posedge atclk);
		@(negedge atclk);
		te_tag_resync = 1'b0;
		void'(tc.tt_assert(dut.LastSrcValidQ == 1'b0, "resync must clear the last-source memory"));

		expect_te_byte(tag_byte(0), "tag again after resync");
		expect_te_packet(1, 8'hC1, "pkt after resync");
		send_te_packet(0, 1, 8'hC1);
		drain_expected(tc.name);
	endtask

	// --- output monitor ------------------------------------------------
	initial begin
		beat_item_t exp;
		forever begin
			@(posedge atclk);
			if (atb_out.atvalid && atb_out.atready) begin
				void'(tt_assert(expected_beats.size() > 0, $sformatf(
					"%0t: unexpected output beat during %s: data=0x%0h bytes=%0d",
					$time, active_test_desc, atb_out.atdata, atb_out.atbytes)));
				if (expected_beats.size() > 0) begin
					exp = expected_beats.pop_front();
					void'(tt_assert(atb_out.atdata == exp.data, $sformatf(
						"%0t: ATDATA mismatch (%s): actual=0x%0h expected=0x%0h",
						$time, exp.desc, atb_out.atdata, exp.data)));
					void'(tt_assert(atb_out.atbytes == exp.bytes, $sformatf(
						"%0t: ATBYTES mismatch (%s): actual=%0d expected=%0d",
						$time, exp.desc, atb_out.atbytes, exp.bytes)));
				end
			end
		end
	end

	initial begin
		active_test_desc = "idle";

		test_single_source_tag_once();
		test_source_change_tag();
		test_tag_always();
		test_zero_length_packet();
		test_tag_under_backpressure();
		test_mixed_framing();
		test_tag_resync();

		repeat (10) @(posedge atclk);
		void'(tt_assert(expected_beats.size() == 0, $sformatf(
			"%0t: expected queue not empty at end: %0d",
			$time, expected_beats.size())));
		tt_evaluate();
		$finish();
	end

	initial begin
		repeat (TIMEOUT_CYCLES * 8) @(posedge atclk);
		void'(tt_assert(1'b0, "global testbench timeout"));
		tt_evaluate();
		$finish();
	end

endmodule

`default_nettype wire
