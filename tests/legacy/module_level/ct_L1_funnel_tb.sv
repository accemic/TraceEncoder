// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @file    ct_L1_funnel_tb.sv
 * @brief   Directed fixed-width reference testbench for ct_L1_funnel.
 * @description Exercises packet switching, strict priority, round-robin,
 *   ATID/ATBYTES propagation, backpressure handling, repeated END_IDLE ignore
 *   behavior, and flush handling for the fixed 32-bit reference funnel.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */
`default_nettype none

module ct_L1_funnel_tb;

	import tt::*;
	import atb_pkg::*;
	import nexus::*;

	localparam int N_STREAMS = 4;
	localparam int MAX_PRIO = 3;
	localparam int CLK_PERIOD = 2;
	localparam int TIMEOUT_CYCLES = 2000;
	localparam logic [ATBYTES_WIDTH-1:0] FULL_ATBYTES = ATBYTES_WIDTH'(3);

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
		logic [ATBYTES_WIDTH-1:0] bytes;
		logic [ATID_WIDTH-1:0] id;
		int src;
		string desc;
	} beat_item_t;

	beat_item_t expected_beats[$];
	int observed_beats;
	int active_test_id;
	string active_test_desc;
	logic allow_unexpected_output;

	ct_L1_funnel #(
		.N_STREAMS(N_STREAMS),
		.MAX_PRIO(MAX_PRIO)
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

	function automatic logic [ATDATA_WIDTH-1:0] mk_beat(
		input logic [29:0] payload,
		input nexus_mseo_e mseo
	);
		return {payload, mseo};
	endfunction

	function automatic logic [ATDATA_WIDTH-1:0] beat_start(input logic [29:0] payload);
		return mk_beat(payload, START_TRANSMISSION);
	endfunction

	function automatic logic [ATDATA_WIDTH-1:0] beat_var(input logic [29:0] payload);
		return mk_beat(payload, VAR);
	endfunction

	function automatic logic [ATDATA_WIDTH-1:0] beat_end(input logic [29:0] payload);
		return mk_beat(payload, END_IDLE);
	endfunction

	task automatic clear_channel(input int ch);
		drv_atdata[ch] = '0;
		drv_atbytes[ch] = FULL_ATBYTES;
		drv_atid[ch] = ATID_WIDTH'(ch + 1);
		drv_atvalid[ch] = 1'b0;
		drv_afready[ch] = 1'b0;
	endtask

	task automatic clear_all_channels();
		int i;
		for (i = 0; i < N_STREAMS; i = i + 1) begin
			clear_channel(i);
		end
	endtask

	task automatic default_config();
		int i;

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
	endtask

	task automatic reset_dut();
		atresetn = 1'b0;
		default_config();
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
		item.bytes = FULL_ATBYTES;
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

	task automatic submit_beat(
		input int ch,
		input logic [ATDATA_WIDTH-1:0] data,
		input logic [ATID_WIDTH-1:0] id
	);
		fork
			begin
				send_beat(ch, data, id);
			end
		join_none
	endtask

	task automatic send_packet_two_beat(
		input int ch,
		input logic [ATDATA_WIDTH-1:0] start_data,
		input logic [ATDATA_WIDTH-1:0] end_data,
		input logic [ATID_WIDTH-1:0] id
	);
		send_beat(ch, start_data, id);
		send_beat(ch, end_data, id);
	endtask

	task automatic pulse_afready(input int ch, input int repeat_count = 1);
		int r;

		for (r = 0; r < repeat_count; r = r + 1) begin
			@(negedge atclk);
			drv_afready[ch] = 1'b1;
			@(posedge atclk);
			@(negedge atclk);
			drv_afready[ch] = 1'b0;
		end
	endtask

	task automatic wait_observed_beats_at_least(input int target_count, input string desc);
		int cycles;

		cycles = 0;
		while (observed_beats < target_count) begin
			@(posedge atclk);
			cycles = cycles + 1;
			if (cycles > TIMEOUT_CYCLES) begin
				void'(tt_assert(1'b0, $sformatf(
					"%0t: timeout waiting for observed beats >= %0d during %s (got %0d)",
					$time, target_count, desc, observed_beats
				)));
				break;
			end
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

	task automatic wait_flush_done(input string desc);
		int cycles;

		cycles = 0;
		while (!global_flush_done) begin
			@(posedge atclk);
			cycles = cycles + 1;
			if (cycles > TIMEOUT_CYCLES) begin
				void'(tt_assert(1'b0, $sformatf(
					"%0t: timeout waiting for global flush done during %s",
					$time, desc
				)));
				break;
			end
		end
	endtask

	task automatic test_ignore_repeated_end_idle_and_prio_zero();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] s0;
		logic [ATDATA_WIDTH-1:0] e0;

		tc = create_testcase("IgnoreRepeatedEndIdle_DisabledPriorityZero");
		active_test_id = 0;
		active_test_desc = tc.name;
		reset_dut();

		chan_prio[1] = 0;
		start_beat(0, beat_end(30'h3a), 7'h40);
		start_beat(1, beat_start(30'h155), 7'h41);
		wait_no_output(5, tc.name);
		stop_beat(0);
		stop_beat(1);

		s0 = beat_start(30'h10);
		e0 = beat_end(30'h11);
		expect_beat(0, s0, 7'h42, "valid packet start after ignored END_IDLE");
		expect_beat(0, e0, 7'h42, "valid packet end after ignored END_IDLE");
		send_packet_two_beat(0, s0, e0, 7'h42);
		drain_expected(tc.name);
		void'(tc.tt_assert(chan_prio[1] == 0, "priority-zero channel remained disabled"));
	endtask

	task automatic test_round_robin_and_metadata();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] s0;
		logic [ATDATA_WIDTH-1:0] e0;
		logic [ATDATA_WIDTH-1:0] s1;
		logic [ATDATA_WIDTH-1:0] e1;

		tc = create_testcase("RoundRobin_ATID_ATBYTES");
		active_test_id = 1;
		active_test_desc = tc.name;
		reset_dut();

		s0 = beat_start(30'h20);
		e0 = beat_end(30'h21);
		s1 = beat_start(30'h30);
		e1 = beat_end(30'h31);

		expect_beat(0, s0, 7'h11, "round-robin channel 0 start");
		expect_beat(0, e0, 7'h11, "round-robin channel 0 end");
		expect_beat(1, s1, 7'h22, "round-robin channel 1 start");
		expect_beat(1, e1, 7'h22, "round-robin channel 1 end");

		fork
			begin
				send_packet_two_beat(0, s0, e0, 7'h11);
			end
			begin
				send_packet_two_beat(1, s1, e1, 7'h22);
			end
		join

		drain_expected(tc.name);
		void'(tc.tt_assert(observed_beats >= 4, "expected at least four observed beats"));
	endtask

	task automatic test_switch_only_after_end_idle_with_backpressure();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] s0;
		logic [ATDATA_WIDTH-1:0] e0;
		logic [ATDATA_WIDTH-1:0] s1;
		logic [ATDATA_WIDTH-1:0] e1;
		int beat_mark;

		tc = create_testcase("SwitchOnlyAfterEndIdle_Backpressure");
		active_test_id = 2;
		active_test_desc = tc.name;
		reset_dut();
		beat_mark = observed_beats;
		allow_unexpected_output = 1'b1;

		s0 = beat_start(30'h100);
		e0 = beat_end(30'h101);
		s1 = beat_start(30'h110);
		e1 = beat_end(30'h111);

		start_beat(0, s0, 7'h31);
		wait_handshake(0);
		stop_beat(0);
		wait_observed_beats_at_least(beat_mark + 1, {tc.name, " first packet beat"});
		void'(tc.tt_assert(dut.dbg_selected_idx == 0, "channel 0 should remain selected inside packet"));

		start_beat(1, s1, 7'h32);
		start_beat(0, e0, 7'h31);
		atb_out.atready = 1'b0;
		repeat (4) @(posedge atclk);
		void'(tc.tt_assert(dut.dbg_selected_idx == 0, "no switch allowed before END_IDLE handshake"));
		stop_beat(1);
		atb_out.atready = 1'b1;
		wait_handshake(0);
		stop_beat(0);
		wait_observed_beats_at_least(beat_mark + 2, {tc.name, " packet completion beat"});
		repeat (2) @(posedge atclk);
		void'(tc.tt_assert(dut.dbg_selected_valid == 1'b0 || dut.dbg_selected_idx != 0,
			"selection should no longer be locked to channel 0 after END_IDLE handshake"));

		send_beat(1, s1, 7'h32);
		send_beat(1, e1, 7'h32);
		allow_unexpected_output = 1'b0;
	endtask

	task automatic test_strict_priority_and_round_robin();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] s0;
		logic [ATDATA_WIDTH-1:0] e0;
		logic [ATDATA_WIDTH-1:0] s1;
		logic [ATDATA_WIDTH-1:0] e1;
		logic [ATDATA_WIDTH-1:0] s2;
		logic [ATDATA_WIDTH-1:0] e2;

		tc = create_testcase("StrictPriority_RoundRobin");
		active_test_id = 3;
		active_test_desc = tc.name;
		reset_dut();

		chan_prio[0] = 1;
		chan_prio[1] = 3;
		chan_prio[2] = 3;

		s0 = beat_start(30'h200);
		e0 = beat_end(30'h201);
		s1 = beat_start(30'h210);
		e1 = beat_end(30'h211);
		s2 = beat_start(30'h220);
		e2 = beat_end(30'h221);

		expect_beat(1, s1, 7'h51, "highest priority first start");
		expect_beat(1, e1, 7'h51, "highest priority first end");
		expect_beat(2, s2, 7'h52, "round-robin within highest priority start");
		expect_beat(2, e2, 7'h52, "round-robin within highest priority end");
		expect_beat(0, s0, 7'h50, "lower priority start last");
		expect_beat(0, e0, 7'h50, "lower priority end last");

		fork
			begin
				send_packet_two_beat(0, s0, e0, 7'h50);
			end
			begin
				send_packet_two_beat(1, s1, e1, 7'h51);
			end
			begin
				send_packet_two_beat(2, s2, e2, 7'h52);
			end
		join

		drain_expected(tc.name);
		void'(tc.tt_assert((chan_prio[1] == 3) && (chan_prio[2] == 3), "priority setup applied"));
	endtask

	task automatic test_flush_handling();
		tt_testcase tc;
		logic [ATDATA_WIDTH-1:0] s0;
		logic [ATDATA_WIDTH-1:0] e0;
		logic [ATDATA_WIDTH-1:0] s1;
		logic [ATDATA_WIDTH-1:0] e1;
		int beat_mark;

		tc = create_testcase("FlushHandling_Backpressure");
		active_test_id = 4;
		active_test_desc = tc.name;
		reset_dut();
		beat_mark = observed_beats;
		allow_unexpected_output = 1'b1;

		s0 = beat_start(30'h300);
		e0 = beat_end(30'h301);
		s1 = beat_start(30'h310);
		e1 = beat_end(30'h311);

		chan_prio[2] = 0;
		chan_flush_req[1] = 1'b1;

		start_beat(0, s0, 7'h61);
		wait_handshake(0);
		stop_beat(0);
		wait_observed_beats_at_least(beat_mark + 1, {tc.name, " first flush beat"});
		repeat (1) @(posedge atclk);
		void'(tc.tt_assert(mon_afvalid[1] == 1'b1, "per-channel flush request must propagate"));

		start_beat(1, s1, 7'h62);
		start_beat(0, e0, 7'h61);
		atb_out.atready = 1'b0;
		repeat (2) @(posedge atclk);
		void'(tc.tt_assert(dut.dbg_selected_idx == 0, "flush must not preempt mid-packet under backpressure"));
		stop_beat(1);
		atb_out.atready = 1'b1;
		wait_handshake(0);
		stop_beat(0);
		wait_observed_beats_at_least(beat_mark + 2, {tc.name, " second flush beat"});

		send_beat(1, s1, 7'h62);
		send_beat(1, e1, 7'h62);
		wait_observed_beats_at_least(beat_mark + 4, {tc.name, " flush scenario packet 1 complete"});

		void'(tc.tt_assert(chan_flush_done[1] == 1'b0, "flush done must stay low before ack"));
		pulse_afready(1, 1);
		repeat (1) @(posedge atclk);
		void'(tc.tt_assert(chan_flush_done[1] == 1'b1, "flush done must assert after ack"));

		chan_flush_req[1] = 1'b0;
		global_flush_req = 1'b1;
		repeat (2) @(posedge atclk);
		void'(tc.tt_assert(mon_afvalid[0] == 1'b1, "global flush must request active participant 0"));
		void'(tc.tt_assert(mon_afvalid[1] == 1'b1, "global flush must request active participant 1"));
		void'(tc.tt_assert(mon_afvalid[3] == 1'b1, "global flush must request empty participating source 3"));
		void'(tc.tt_assert(global_flush_done == 1'b0, "global flush must wait for all participants"));

		pulse_afready(0, 2);
		repeat (1) @(posedge atclk);
		void'(tc.tt_assert(dut.global_ack_seen_q[0] == 1'b1, "global ack sticky must set for channel 0"));
		void'(tc.tt_assert(global_flush_done == 1'b0, "global flush must still wait for remaining participants"));

		pulse_afready(1, 2);
		repeat (1) @(posedge atclk);
		void'(tc.tt_assert(dut.global_ack_seen_q[1] == 1'b1, "global ack sticky must set for channel 1"));
		void'(tc.tt_assert(global_flush_done == 1'b0, "global flush must still wait for empty participant"));

		pulse_afready(3, 2);
		repeat (1) @(posedge atclk);
		void'(tc.tt_assert(dut.global_ack_seen_q[3] == 1'b1, "global ack sticky must set for channel 3"));
		wait_flush_done(tc.name);
		void'(tc.tt_assert(global_flush_done == 1'b1, "global flush should complete after all participants ack"));

		global_flush_req = 1'b0;
		allow_unexpected_output = 1'b0;
	endtask

	initial begin
		int i;
		beat_item_t exp;

		observed_beats = 0;
		allow_unexpected_output = 1'b0;
		forever begin
			@(posedge atclk);
			if (atresetn) begin
				for (i = 0; i < N_STREAMS; i = i + 1) begin
					if (!dut.selected_valid_q || (dut.selected_idx_q != i)) begin
						void'(tt_assert(mon_atready[i] == 1'b0, $sformatf(
							"%0t: non-selected channel %0d must see ready=0 during %s",
							$time, i, active_test_desc
						)));
					end
				end
			end

			if (atb_out.atvalid && atb_out.atready) begin
				observed_beats = observed_beats + 1;
				void'(tt_assert((expected_beats.size() > 0) || allow_unexpected_output, $sformatf(
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
					void'(tt_assert(atb_out.atbytes == exp.bytes, $sformatf(
						"%0t: ATBYTES mismatch during %s, src=%0d actual=0x%0h expected=0x%0h",
						$time, exp.desc, exp.src, atb_out.atbytes, exp.bytes
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
		active_test_id = -1;
		active_test_desc = "idle";

		test_ignore_repeated_end_idle_and_prio_zero();
		test_round_robin_and_metadata();
		test_switch_only_after_end_idle_with_backpressure();
		test_strict_priority_and_round_robin();
		test_flush_handling();

		repeat (10) @(posedge atclk);
		void'(tt_assert(expected_beats.size() == 0, $sformatf(
			"%0t: expected queue not empty at end: %0d",
			$time, expected_beats.size()
		)));
		tt_evaluate();
		$finish();
	end

	initial begin
		repeat (TIMEOUT_CYCLES * 4) @(posedge atclk);
		void'(tt_assert(1'b0, "global watchdog timeout in ct_L1_funnel_tb"));
		tt_evaluate();
		$finish();
	end

endmodule

`default_nettype wire