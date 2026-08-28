// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_sync_req_pacer_tb.sv
 * @brief   The explicit sync request across a reset of the CONSUMER's domain
 *          alone (P8 closing audit B-N1), at two unrelated clocks.
 * @details The two halves of one request live in two reset domains -- the
 *   pacing in wb_rst, the pending latch in tip_rst -- and ct_encoder carries
 *   both as independent inputs. A core reset that leaves the CSR domain
 *   running therefore clears the consumer's state without an acknowledgement.
 *
 *   The formal target P-SYNC-12 (formal/preproc_sync, task tereqrst) proves
 *   the answer at ONE clock, because that is the assumption the whole formal
 *   wrapper carries (ASM-SYNC-3). This testbench is the other half: two
 *   unrelated clocks, the real ct_sync_req_pacer, the real signal_cdc
 *   crossings, and a consumer that behaves exactly like the arm in
 *   ct_L23_preproc_sync (arm while the request level stands unacknowledged,
 *   acknowledge when served, drop the acknowledgement when the request goes
 *   away).
 *
 * @environment wb_clk and tip_clk at an irrational-ish ratio so the crossings
 *   are exercised in every phase relationship the scenario sweep produces.
 * @stimulus A matrix over: how many requests have already gone through when
 *   the reset lands (the toggle-parity dimension the retired strobe design
 *   was sensitive to), how long the reset lasts, whether a second write is
 *   queued, and whether a write lands DURING the reset.
 * @checking Per scenario: every write is answered (no request dropped on the
 *   floor), and the mechanism is still alive afterwards. `+strobe` rebuilds
 *   the request as a ONE-CYCLE pulse -- the retired design -- and is the red
 *   control: it must fail.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

`default_nettype none

module ct_sync_req_pacer_tb;

	import tt::*;

	// Deliberately unrelated periods (no integer ratio): the crossings see
	// every phase relationship over a scenario sweep.
	localparam realtime WB_HALF  = 5.0;
	localparam realtime TIP_HALF = 3.7;
	// How long the consumer holds a request before it serves it (a real arm
	// waits for a qualifying retired instruction). Long enough that a reset
	// can be placed INSIDE the outstanding window.
	localparam int      SERVE_HOLD = 12;

	logic wb_clk  = 0; always #WB_HALF  wb_clk  = ~wb_clk;
	logic tip_clk = 0; always #TIP_HALF tip_clk = ~tip_clk;

	logic wb_rst  = 1;
	logic tip_rst = 1;

	// Red control: rebuild the request as a one-cycle pulse (the retired
	// strobe design) instead of the held level.
	bit strobe_mode = 0;

	logic       write = 0;
	uwire logic req_wb, ack_wb, req_tip, ack_tip_lvl;

	ct_sync_req_pacer dut (
		.clk   (wb_clk),
		.rst   (wb_rst),
		.write (write),
		.ack   (ack_wb),
		.req   (req_wb)
	);

	logic req_wb_q = 0;
	always_ff @(posedge wb_clk) req_wb_q <= wb_rst ? 1'b0 : req_wb;
	uwire logic req_to_cdc = strobe_mode ? (req_wb && !req_wb_q) : req_wb;

	signal_cdc cdc_req (.clk (tip_clk), .rst (tip_rst), .in (req_to_cdc), .out (req_tip));
	signal_cdc cdc_ack (.clk (wb_clk),  .rst (wb_rst),  .in (ack_tip_lvl), .out (ack_wb));

	// The consumer, shaped exactly like the TE arm in ct_L23_preproc_sync.
	logic       Pending = 0;
	logic       Ack     = 0;
	int         hold    = 0;
	int         served  = 0;
	assign ack_tip_lvl = Ack;
	always_ff @(posedge tip_clk) begin
		if (tip_rst) begin
			// The reset clears the consumer's state WITHOUT acknowledging --
			// this is the whole point of the exercise.
			Pending <= 1'b0;
			Ack     <= 1'b0;
			hold    <= 0;
		end
		else begin
			if (req_tip && !Ack) Pending <= 1'b1;
			if (!req_tip)        Ack     <= 1'b0;
			if (Pending) begin
				if (hold < SERVE_HOLD) hold <= hold + 1;
				else begin
					// Served: one synchronization message, and the
					// acknowledgement phase goes up. Textually last, so it
					// wins over the re-arm above in the same cycle.
					hold    <= 0;
					Pending <= 1'b0;
					Ack     <= 1'b1;
					served  <= served + 1;
				end
			end
			else hold <= 0;
		end
	end

	int writes = 0;
	task automatic sw_write();
		@(negedge wb_clk); write = 1'b1; writes = writes + 1;
		@(negedge wb_clk); write = 1'b0;
	endtask

	task automatic settle(input int n);
		repeat (n) @(negedge wb_clk);
	endtask

	// One scenario. `pre` requests are pushed through cleanly first (that is
	// the parity dimension), then one is left outstanding while the consumer
	// is reset for `rlen` tip cycles; `during` optionally writes while the
	// consumer is down, `queued` writes a second one back to back.
	task automatic scenario(input int pre, input int rlen,
	                        input bit queued, input bit during);
		automatic int w0, s0;
		wb_rst = 1; tip_rst = 1; settle(4);
		wb_rst = 0; tip_rst = 0; settle(6);
		writes = 0; served = 0;
		w0 = 0; s0 = 0;

		for (int i = 0; i < pre; i++) begin
			sw_write();
			settle(40);
		end

		sw_write();
		if (queued) sw_write();
		settle(3);                       // the request is in the crossing
		tip_rst = 1;
		repeat (rlen) @(negedge tip_clk);
		if (during) sw_write();
		tip_rst = 0;
		settle(80);

		// Alive? Three more requests, each must produce its message.
		s0 = served; w0 = writes;
		for (int i = 0; i < 3; i++) begin
			sw_write();
			settle(60);
		end
		void'(tt_assert((served - s0) >= 3, $sformatf(
			"Line %0d: pre=%0d rlen=%0d queued=%0d during=%0d: only %0d of 3 later requests were served -- the path is dead",
			`__LINE__, pre, rlen, queued, during, served - s0)));
		// Nothing dropped on the floor: every write got an answer. More
		// answers than writes is allowed -- a request whose acknowledgement
		// the reset destroyed is asked for again, and one extra anchor is
		// harmless (documented in ct_sync_req_pacer.sv).
		void'(tt_assert(served >= writes, $sformatf(
			"Line %0d: pre=%0d rlen=%0d queued=%0d during=%0d: %0d writes, only %0d served -- a request was lost",
			`__LINE__, pre, rlen, queued, during, writes, served)));
		$display("SCEN pre=%0d rlen=%2d queued=%0d during=%0d : writes=%0d served=%0d later=%0d/3",
		         pre, rlen, queued, during, writes, served, served - s0);
	endtask

	initial begin
		if ($test$plusargs("strobe")) begin
			strobe_mode = 1;
			$display("MODE: strobe (RED CONTROL -- the retired one-cycle request)");
		end
		else $display("MODE: level (the four-phase handshake)");

		for (int pre = 0; pre < 4; pre++)
			foreach_rlen: for (int r = 0; r < 3; r++) begin
				automatic int rlen = (r == 0) ? 1 : ((r == 1) ? 3 : 9);
				scenario(pre, rlen, 1'b0, 1'b0);
				scenario(pre, rlen, 1'b1, 1'b0);
				scenario(pre, rlen, 1'b0, 1'b1);
			end

		tt_evaluate();
		$finish();
	end

endmodule

`default_nettype wire
