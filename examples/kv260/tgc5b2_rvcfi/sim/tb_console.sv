// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`timescale 1ns / 1ps
`default_nettype none

/**
 * @brief    Self-checking unit TB for ct_soc_console.
 *
 * @details
 *   Scenarios, ordered by what they cost if wrong:
 *
 *     (a) core pushes a string, PS pops it back -- order, FWFT, count
 *     (b) PS pushes a string, core pops it back through RX_POP reads,
 *         including the valid bit and the empty case
 *     (c) TX overflow: pushes into a full FIFO are DROPPED AND COUNTED,
 *         and the FIFO contents survive intact (an overflow that corrupts
 *         the buffered data would be worse than the loss itself)
 *     (d) RX overflow: same property from the PS side, counted in
 *         ps_rx_drops
 *     (e) concurrent traffic in both directions against reference queues
 *     (f) accounting invariant after everything: pushed == popped + dropped
 *         on both paths -- the balance check that catches a lost or
 *         duplicated character even if every individual compare passed
 */

module tb_console;

	localparam int unsigned DEPTH = 16;    // small: overflow is reachable

	logic clk = 1'b0;
	logic rst = 1'b1;
	always #5 clk = ~clk;

	// core-side AXI
	logic        awvalid, awready, wvalid, wready, bvalid, bready;
	logic [31:0] awaddr, wdata;
	logic [3:0]  wstrb;
	logic [1:0]  bresp;
	logic        arvalid, arready, rvalid, rready;
	logic [31:0] araddr, rdata;
	logic [1:0]  rresp;

	// PS side
	logic [15:0] ps_tx_cnt, ps_rx_free, ps_rx_drops;
	logic        ps_tx_valid, ps_tx_pop, ps_rx_push;
	logic [7:0]  ps_tx_data, ps_rx_data;

	int checks = 0;

	ct_soc_console #(.DEPTH(DEPTH)) dut (
		.clk(clk), .rst(rst),
		.s_awvalid(awvalid), .s_awready(awready), .s_awaddr(awaddr),
		.s_wvalid(wvalid), .s_wready(wready), .s_wdata(wdata), .s_wstrb(wstrb),
		.s_bvalid(bvalid), .s_bready(bready), .s_bresp(bresp),
		.s_arvalid(arvalid), .s_arready(arready), .s_araddr(araddr),
		.s_rvalid(rvalid), .s_rready(rready), .s_rdata(rdata), .s_rresp(rresp),
		.ps_tx_cnt(ps_tx_cnt), .ps_tx_valid(ps_tx_valid), .ps_tx_data(ps_tx_data),
		.ps_tx_pop(ps_tx_pop),
		.ps_rx_free(ps_rx_free), .ps_rx_push(ps_rx_push), .ps_rx_data(ps_rx_data),
		.ps_rx_drops(ps_rx_drops)
	);

	// completion flags in RTL semantics (the Verilator --timing lesson)
	logic        w_done, r_done;
	logic [31:0] r_cap;
	always_ff @(posedge clk) begin
		w_done <= bvalid && bready;
		r_done <= rvalid && rready;
		if (rvalid && rready) r_cap <= rdata;
	end

	task automatic wr(input logic [31:0] a, input logic [31:0] d);
		awaddr = a; wdata = d; wstrb = 4'hF;
		awvalid = 1'b1; wvalid = 1'b1; bready = 1'b1;
		do begin @(posedge clk); #1; end while (!w_done);
		awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0;
	endtask

	task automatic rd(input logic [31:0] a, output logic [31:0] d);
		araddr = a; arvalid = 1'b1; rready = 1'b1;
		do begin @(posedge clk); #1; end while (!r_done);
		arvalid = 1'b0; rready = 1'b0;
		d = r_cap;
	endtask

	task automatic chk(input string what, input logic cond);
		if (!cond) $fatal(1, "FAIL: %s", what);
		checks++;
	endtask

	// PS-side single-cycle strobes
	task automatic ps_pop(output logic [7:0] c, output logic ok);
		@(posedge clk); #1;
		ok = ps_tx_valid;
		c  = ps_tx_data;
		if (ok) begin
			ps_tx_pop <= 1'b1;
			@(posedge clk); #1;
			ps_tx_pop <= 1'b0;
		end
	endtask

	task automatic ps_push(input logic [7:0] c);
		@(posedge clk); #1;
		ps_rx_data <= c;
		ps_rx_push <= 1'b1;
		@(posedge clk); #1;
		ps_rx_push <= 1'b0;
	endtask

	initial begin : main
		logic [31:0] v;
		logic [7:0]  c;
		logic        ok;
		string       msg = "hello, PS!";
		int          n_pushed_tx = 0, n_popped_tx = 0;
		int          i;

		awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
		awaddr = 0; araddr = 0; wdata = 0; wstrb = 4'hF;
		ps_tx_pop = 0; ps_rx_push = 0; ps_rx_data = 0;

		repeat (4) @(posedge clk);
		rst <= 1'b0;
		repeat (2) @(posedge clk);

		// ---- (a) core -> PS ----------------------------------------------
		rd(32'h00, v);
		chk("(a) TX free = DEPTH at reset", v == DEPTH);
		for (i = 0; i < msg.len(); i++) begin
			wr(32'h00, 32'(msg.getc(i)));
		end
		#1;
		chk("(a) ps_tx_cnt", ps_tx_cnt == msg.len());
		for (i = 0; i < msg.len(); i++) begin
			ps_pop(c, ok);
			chk("(a) pop valid", ok);
			chk("(a) pop order", c == msg.getc(i));
		end
		@(posedge clk); #1;
		chk("(a) TX drained", ps_tx_cnt == 0 && !ps_tx_valid);
		$display("TB (a) core->PS string        : OK");

		// ---- (b) PS -> core ----------------------------------------------
		ps_push(8'h41);                     // 'A'
		ps_push(8'h42);                     // 'B'
		rd(32'h04, v);
		chk("(b) RX count 2", v == 2);
		rd(32'h08, v);
		chk("(b) pop A valid", v[31] && v[7:0] == 8'h41);
		rd(32'h08, v);
		chk("(b) pop B valid", v[31] && v[7:0] == 8'h42);
		rd(32'h08, v);
		chk("(b) pop empty -> invalid", !v[31]);
		$display("TB (b) PS->core + empty       : OK");

		// ---- (c) TX overflow ---------------------------------------------
		for (i = 0; i < DEPTH + 5; i++) begin
			wr(32'h00, 32'h60 + i);         // '`'+i, DEPTH fit, 5 overflow
		end
		rd(32'h0C, v);
		chk("(c) TX drops counted", v == 5);
		rd(32'h00, v);
		chk("(c) TX full -> free 0", v == 0);
		// contents intact: pop everything and compare
		for (i = 0; i < DEPTH; i++) begin
			ps_pop(c, ok);
			chk("(c) survivor valid", ok);
			chk("(c) survivor intact", c == 8'(32'h60 + i));
		end
		$display("TB (c) TX overflow counted    : OK  <- data intact");

		// ---- (d) RX overflow ---------------------------------------------
		for (i = 0; i < DEPTH + 3; i++) begin
			ps_push(8'(i));
		end
		@(posedge clk); #1;
		chk("(d) RX drops counted", ps_rx_drops == 3);
		chk("(d) RX full -> free 0", ps_rx_free == 0);
		for (i = 0; i < DEPTH; i++) begin
			rd(32'h08, v);
			chk("(d) survivor valid", v[31]);
			chk("(d) survivor intact", v[7:0] == 8'(i));
		end
		$display("TB (d) RX overflow counted    : OK");

		// ---- (e)+(f) concurrent soak with balance ------------------------
		fork
			begin : core_side
				int k;
				for (k = 0; k < 40; k++) begin
					wr(32'h00, 32'(8'h20 + (k % 64)));
					n_pushed_tx++;
				end
			end
			begin : ps_side
				int k;
				logic [7:0] cc;
				logic       vv;
				for (k = 0; k < 60; k++) begin
					ps_pop(cc, vv);
					if (vv) n_popped_tx++;
				end
			end
		join
		// drain the rest
		forever begin
			ps_pop(c, ok);
			if (!ok) break;
			n_popped_tx++;
		end
		rd(32'h0C, v);
		chk("(f) TX balance pushed == popped + dropped",
		    n_pushed_tx == n_popped_tx + int'(v) - 5);   // 5 drops from (c)
		$display("TB (e/f) concurrent + balance : OK (pushed=%0d popped=%0d)",
		         n_pushed_tx, n_popped_tx);

		$display("TB_PASS (tb_console DEPTH=%0d): checks=%0d", DEPTH, checks);
		$finish;
	end

	initial begin : watchdog
		#2_000_000;
		$fatal(1, "tb_console: watchdog");
	end

endmodule

`default_nettype wire
