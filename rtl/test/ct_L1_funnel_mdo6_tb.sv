// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @file    ct_L1_funnel_mdo6_tb.sv
 * @brief   Directed testbench for ct_L1_funnel in the MDO_WIDTH=6 (byte
 *          chunk) configuration -- the wire format the MSEO/MDO formatter
 *          emits with NEXUS_MDO_WIDTH=6 (four 8-bit chunks per 32-bit beat).
 * @description Exercises multi-chunk beat parsing (mid-beat end-of-message
 *   with alignment padding), message-atomic round-robin switching, idle-beat
 *   drop (flush padding must be consumed, not forwarded), and switch locking
 *   under backpressure.
 *
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */
`default_nettype none

module ct_L1_funnel_mdo6_tb;

	import tt::*;
	import atb_pkg::*;
	import nexus::*;

	localparam int N_STREAMS = 2;
	localparam int MAX_PRIO = 3;
	localparam int CLK_PERIOD = 2;
	localparam int TIMEOUT_CYCLES = 2000;
	localparam logic [ATBYTES_WIDTH-1:0] FULL_ATBYTES = ATBYTES_WIDTH'(3);
	localparam logic [ATDATA_WIDTH-1:0] IDLE_BEAT = {ATDATA_WIDTH{1'b1}};

	logic atclk = 1'b0;
	logic atresetn;
	logic global_flush_req;
	logic [$clog2(MAX_PRIO+1)-1:0] chan_prio [N_STREAMS];
	logic chan_flush_participate [N_STREAMS];
	logic chan_flush_req [N_STREAMS];
	logic chan_flush_done [N_STREAMS];
	logic global_flush_done;
	logic [ATDATA_WIDTH-1:0] drv_atdata [N_STREAMS];
	logic [ATBYTES_WIDTH-1:0] drv_atbytes [N_STREAMS];
	logic [ATID_WIDTH-1:0] drv_atid [N_STREAMS];
	logic drv_atvalid [N_STREAMS];
	logic drv_afready [N_STREAMS];
	logic mon_atready [N_STREAMS];
	logic mon_afvalid [N_STREAMS];
	logic mon_syncreq [N_STREAMS];

	atb_if atb_in [N_STREAMS] ();
	atb_if atb_out ();

	typedef struct {
		logic [ATDATA_WIDTH-1:0] data;
		logic [ATID_WIDTH-1:0] id;
		int src;
		string desc;
	} beat_item_t;

	beat_item_t expected_beats[$];
	int observed_beats;
	string active_test_desc;

	ct_L1_funnel #(
		.N_STREAMS(N_STREAMS),
		.MAX_PRIO(MAX_PRIO),
		.MDO_WIDTH(6)
	) dut (
		.atclk,
		.atresetn,
		.chan_prio,
		.chan_flush_participate,
		.chan_flush_req,
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
			assign mon_afvalid[gi] = atb_in[gi].afvalid;
			assign mon_syncreq[gi] = atb_in[gi].syncreq;
		end
	endgenerate

	// Chunk 0 (first chunk on the wire) sits in beat bits [7:0].
	function automatic logic [7:0] mk_chunk(
		input logic [5:0] mdo,
		input nexus_mseo_e mseo
	);
		return {mdo, mseo};
	endfunction

	function automatic logic [ATDATA_WIDTH-1:0] mk_beat(
		input logic [7:0] c0,
		input logic [7:0] c1,
		input logic [7:0] c2,
		input logic [7:0] c3
	);
		return {c3, c2, c1, c0};
	endfunction

	localparam logic [7:0] PAD_CHUNK = 8'hFF; // {6'h3F, END_IDLE}

	task automatic clear_all_channels();
		int i;
		for (i = 0; i < N_STREAMS; i = i + 1) begin
			drv_atdata[i] = '0;
			drv_atbytes[i] = FULL_ATBYTES;
			drv_atid[i] = ATID_WIDTH'(i + 1);
			drv_atvalid[i] = 1'b0;
			drv_afready[i] = 1'b0;
		end
	endtask

	task automatic reset_dut();
		int i;
		atresetn = 1'b0;
		global_flush_req = 1'b0;
		atb_out.atready = 1'b1;
		atb_out.afvalid = 1'b0;
		atb_out.syncreq = 1'b0;
		for (i = 0; i < N_STREAMS; i = i + 1) begin
			chan_prio[i] = 1;
			chan_flush_participate[i] = 1'b1;
			chan_flush_req[i] = 1'b0;
		end
		clear_all_channels();
		repeat (3) @(posedge atclk);
		atresetn = 1'b1;
		repeat (2) @(posedge atclk);
	endtask

	task automatic expect_beat(
		input int src,
		input logic [ATDATA_WIDTH-1:0] data,
		input logic [ATID_WIDTH-1:0] id,
		input string desc
	);
		beat_item_t item;
		item.src = src;
		item.data = data;
		item.id = id;
		item.desc = desc;
		expected_beats.push_back(item);
	endtask

	task automatic start_beat(
		input int ch,
		input logic [ATDATA_WIDTH-1:0] data,
		input logic [ATID_WIDTH-1:0] id
	);
		drv_atdata[ch] = data;
		drv_atbytes[ch] = FULL_ATBYTES;
		drv_atid[ch] = id;
		drv_atvalid[ch] = 1'b1;
	endtask

	task automatic stop_beat(input int ch);
		drv_atvalid[ch] = 1'b0;
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
					$time, ch, active_test_desc
				)));
				break;
			end
		end
	endtask

	task automatic send_beat(
		input int ch,
		input logic [ATDATA_WIDTH-1:0] data,
		input logic [ATID_WIDTH-1:0] id
	);
		start_beat(ch, data, id);
		wait_handshake(ch);
		stop_beat(ch);
	endtask

	task automatic send_beats(
		input int ch,
		input logic [ATDATA_WIDTH-1:0] beats[$],
		input logic [ATID_WIDTH-1:0] id
	);
		foreach (beats[k]) begin
			send_beat(ch, beats[k], id);
		end
	endtask

	task automatic wait_no_output(input int cycles, input string desc);
		int i;
		for (i = 0; i < cycles; i = i + 1) begin
			@(posedge atclk);
			void'(tt_assert(atb_out.atvalid == 1'b0, $sformatf(
				"%0t: unexpected output during %s in %s",
				$time, desc, active_test_desc
			)));
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
					$time, desc, expected_beats.size()
				)));
				expected_beats.delete();
				break;
			end
		end
	endtask

	// Test 1: one message spanning two beats with mid-beat end-of-message
	// and alignment padding -- forwarded byte-identically, in order.
	task automatic test_midbeat_eom();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] beat_a;
		logic [ATDATA_WIDTH-1:0] beat_b;

		tc = create_testcase("Mdo6_MidBeatEomAlignmentPadding");
		active_test_desc = tc.name;
		reset_dut();

		beat_a = mk_beat(
			mk_chunk(6'h04, START_TRANSMISSION),
			mk_chunk(6'h11, START_TRANSMISSION),
			mk_chunk(6'h22, START_TRANSMISSION),
			mk_chunk(6'h33, VAR)
		);
		beat_b = mk_beat(
			mk_chunk(6'h05, START_TRANSMISSION),
			mk_chunk(6'h2A, END_IDLE),
			PAD_CHUNK,
			PAD_CHUNK
		);

		expect_beat(0, beat_a, 7'h21, "mid-beat EOM: first beat");
		expect_beat(0, beat_b, 7'h21, "mid-beat EOM: final beat with padding");
		send_beat(0, beat_a, 7'h21);
		send_beat(0, beat_b, 7'h21);
		drain_expected(tc.name);
		void'(tc.tt_assert(dut.InPacketQ[0] == 1'b0, "channel must leave packet state after padded EOM beat"));
	endtask

	// Test 2: two channels with two-beat messages pending concurrently --
	// forwarding is message-atomic (no interleave), round-robin across
	// message boundaries.
	task automatic test_message_atomic_rr();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] m0a, m0b, m1a, m1b;

		tc = create_testcase("Mdo6_MessageAtomicRoundRobin");
		active_test_desc = tc.name;
		reset_dut();

		m0a = mk_beat(
			mk_chunk(6'h04, START_TRANSMISSION),
			mk_chunk(6'h01, START_TRANSMISSION),
			mk_chunk(6'h02, START_TRANSMISSION),
			mk_chunk(6'h03, START_TRANSMISSION)
		);
		m0b = mk_beat(mk_chunk(6'h0A, END_IDLE), PAD_CHUNK, PAD_CHUNK, PAD_CHUNK);
		m1a = mk_beat(
			mk_chunk(6'h08, START_TRANSMISSION),
			mk_chunk(6'h31, START_TRANSMISSION),
			mk_chunk(6'h32, START_TRANSMISSION),
			mk_chunk(6'h33, START_TRANSMISSION)
		);
		m1b = mk_beat(mk_chunk(6'h0B, END_IDLE), PAD_CHUNK, PAD_CHUNK, PAD_CHUNK);

		expect_beat(0, m0a, 7'h31, "RR: message 0 beat A");
		expect_beat(0, m0b, 7'h31, "RR: message 0 beat B");
		expect_beat(1, m1a, 7'h32, "RR: message 1 beat A");
		expect_beat(1, m1b, 7'h32, "RR: message 1 beat B");

		fork
			send_beats(0, '{m0a, m0b}, 7'h31);
			send_beats(1, '{m1a, m1b}, 7'h32);
		join
		drain_expected(tc.name);
	endtask

	// Test 3: pure-idle beats (flush padding) are consumed on the input
	// side but never forwarded.
	task automatic test_idle_drop();
		tt_testcase tc;
		int beat_mark;

		tc = create_testcase("Mdo6_IdleBeatDrop");
		active_test_desc = tc.name;
		reset_dut();
		beat_mark = observed_beats;

		// send_beat waits for the input handshake: passing proves the
		// funnel consumes the idle beat even though nothing is forwarded.
		send_beat(0, IDLE_BEAT, 7'h41);
		send_beat(0, IDLE_BEAT, 7'h41);
		wait_no_output(5, "idle beats must not be forwarded");
		void'(tc.tt_assert(observed_beats == beat_mark, "idle beats must not appear on the output"));
	endtask

	// Test 4: backpressure while channel 0 is mid-message -- channel 1 must
	// not preempt before channel 0's padded EOM beat has been forwarded.
	task automatic test_no_preempt_under_backpressure();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] m0a, m0b, m1a;

		tc = create_testcase("Mdo6_NoPreemptUnderBackpressure");
		active_test_desc = tc.name;
		reset_dut();

		m0a = mk_beat(
			mk_chunk(6'h04, START_TRANSMISSION),
			mk_chunk(6'h05, START_TRANSMISSION),
			mk_chunk(6'h06, START_TRANSMISSION),
			mk_chunk(6'h07, START_TRANSMISSION)
		);
		m0b = mk_beat(mk_chunk(6'h1F, END_IDLE), PAD_CHUNK, PAD_CHUNK, PAD_CHUNK);
		m1a = mk_beat(
			mk_chunk(6'h08, START_TRANSMISSION),
			mk_chunk(6'h09, END_IDLE),
			PAD_CHUNK,
			PAD_CHUNK
		);

		expect_beat(0, m0a, 7'h51, "backpressure: message 0 beat A");
		expect_beat(0, m0b, 7'h51, "backpressure: message 0 beat B");
		expect_beat(1, m1a, 7'h52, "backpressure: message 1 after message 0 completes");

		send_beat(0, m0a, 7'h51);
		start_beat(1, m1a, 7'h52);
		atb_out.atready = 1'b0;
		start_beat(0, m0b, 7'h51);
		repeat (4) @(posedge atclk);
		void'(tc.tt_assert(dut.dbg_selected_idx == 0, "channel 1 must not preempt mid-message under backpressure"));
		// Release backpressure at the negedge -- toggling atready right after
		// a posedge races the output monitor within the same time step.
		@(negedge atclk);
		atb_out.atready = 1'b1;
		wait_handshake(0);
		stop_beat(0);
		wait_handshake(1);
		stop_beat(1);
		drain_expected(tc.name);
	endtask

	initial begin
		int i;
		beat_item_t exp;

		observed_beats = 0;
		forever begin
			@(posedge atclk);
			if (atresetn) begin
				for (i = 0; i < N_STREAMS; i = i + 1) begin
					if (!dut.SelectedValidQ || (dut.SelectedIdxQ != i)) begin
						void'(tt_assert(mon_atready[i] == 1'b0
						     || (drv_atvalid[i] && !dut.preview_parse[i].has_data), $sformatf(
							"%0t: non-selected channel %0d must see ready=0 during %s",
							$time, i, active_test_desc
						)));
					end
				end
			end

			if (atb_out.atvalid && atb_out.atready) begin
				observed_beats = observed_beats + 1;
				void'(tt_assert(expected_beats.size() > 0, $sformatf(
					"%0t: unexpected output beat during %s: data=0x%0h id=0x%0h",
					$time, active_test_desc, atb_out.atdata, atb_out.atid
				)));
				void'(tt_assert(atb_out.atbytes == FULL_ATBYTES, $sformatf(
					"%0t: ATBYTES must always indicate four valid bytes during %s",
					$time, active_test_desc
				)));
				if (expected_beats.size() > 0) begin
					exp = expected_beats.pop_front();
					void'(tt_assert(atb_out.atdata == exp.data, $sformatf(
						"%0t: ATDATA mismatch during %s, src=%0d actual=0x%0h expected=0x%0h",
						$time, exp.desc, exp.src, atb_out.atdata, exp.data
					)));
					void'(tt_assert(atb_out.atid == exp.id, $sformatf(
						"%0t: ATID mismatch during %s, src=%0d actual=0x%0h expected=0x%0h",
						$time, exp.desc, exp.src, atb_out.atid, exp.id
					)));
				end
			end
		end
	end

	initial begin
		active_test_desc = "idle";

		test_midbeat_eom();
		test_message_atomic_rr();
		test_idle_drop();
		test_no_preempt_under_backpressure();

		repeat (10) @(posedge atclk);
		void'(tt_assert(expected_beats.size() == 0, $sformatf(
			"%0t: expected queue not empty at end: %0d",
			$time, expected_beats.size()
		)));
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
