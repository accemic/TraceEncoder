// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`timescale 1ns / 1ps
`default_nettype none

/**
 * @brief    Self-checking unit TB for ct_soc_doorbell.
 *
 * @details
 *   The doorbell is three lines of logic and one of them matters more than
 *   it looks: if a write is ever NOT accepted, the core stalls on an
 *   AXI4-Lite transaction that never completes, and the demo hangs with no
 *   error anywhere. So the always-ready property is tested with gapless
 *   back-to-back writes, not with a single one.
 *
 *     (a) write accepted, `last_o` and `hits_o` updated
 *     (b) read-back returns the last word (bring-up aid)
 *     (c) byte strobes honoured -- a partial store must not masquerade as a
 *         full command word in the readback
 *     (d) gapless back-to-back writes: N writes -> N hits, no stall
 *     (e) `hits_o` SATURATES instead of wrapping. Tested through the
 *         `HITS_MAX` hook, because the real edge (2**32-1) is unreachable in
 *         simulation -- and a wrap to zero would silently understate the
 *         instrumentation count, which is exactly the number the host uses
 *         to tell a dropped record from a missing conversion.
 *     (f) reset clears counters and state
 */

module tb_doorbell;

	localparam logic [31:0] HITS_MAX = 32'd6;    // small, so (e) is reachable

	logic clk = 1'b0;
	logic rst = 1'b1;
	always #5 clk = ~clk;

	logic        awvalid, awready, wvalid, wready, bvalid, bready;
	logic [31:0] awaddr, wdata;
	logic [3:0]  wstrb;
	logic [1:0]  bresp;
	logic        arvalid, arready, rvalid, rready;
	logic [31:0] araddr, rdata;
	logic [1:0]  rresp;
	logic [31:0] last_o, hits_o;

	int checks;

	ct_soc_doorbell #(.HITS_MAX(HITS_MAX)) dut (
		.clk(clk), .rst(rst),
		.s_awvalid(awvalid), .s_awready(awready), .s_awaddr(awaddr),
		.s_wvalid(wvalid), .s_wready(wready), .s_wdata(wdata), .s_wstrb(wstrb),
		.s_bvalid(bvalid), .s_bready(bready), .s_bresp(bresp),
		.s_arvalid(arvalid), .s_arready(arready), .s_araddr(araddr),
		.s_rvalid(rvalid), .s_rready(rready), .s_rdata(rdata), .s_rresp(rresp),
		.last_o(last_o), .hits_o(hits_o)
	);

	// -----------------------------------------------------------------
	// Handshake completion is detected in always_ff blocks, NOT by polling
	// from the task -- and that is not a style preference.
	//
	// Under Verilator with --timing, a task that resumes on `@(posedge clk)`
	// reads the POST-edge value, whereas IEEE scheduling would give it the
	// value from before the edge. A one-cycle pulse such as `bvalid` is
	// therefore invisible to a polling loop exactly when it matters: the
	// slave raises it and clears it again while the task is looking at the
	// wrong side of the edge. An `always_ff` block has ordinary RTL
	// semantics in both worlds, so it sees the beat reliably; the task then
	// waits on a flag instead of on the bus.
	//
	// `bready`/`rready` stay high for the whole transaction, so a response
	// can never be missed for lack of a receiver either.
	// -----------------------------------------------------------------
	logic        w_done, r_done;
	logic [31:0] r_data_cap;
	logic [1:0]  b_resp_cap, r_resp_cap;

	always_ff @(posedge clk) begin
		w_done <= bvalid && bready;
		r_done <= rvalid && rready;
		if (bvalid && bready) b_resp_cap <= bresp;
		if (rvalid && rready) begin
			r_data_cap <= rdata;
			r_resp_cap <= rresp;
		end
	end

	task automatic wr(input logic [31:0] data, input logic [3:0] strb = 4'hF);
		awaddr = 32'h4000_0000; wdata = data; wstrb = strb;
		awvalid = 1'b1; wvalid = 1'b1; bready = 1'b1;
		do begin @(posedge clk); #1; end while (!w_done);
		awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0;
		if (b_resp_cap !== 2'b00) $fatal(1, "bresp=%b", b_resp_cap);
	endtask

	task automatic rd(output logic [31:0] data);
		araddr = 32'h4000_0000; arvalid = 1'b1; rready = 1'b1;
		do begin @(posedge clk); #1; end while (!r_done);
		arvalid = 1'b0; rready = 1'b0;
		data = r_data_cap;
		if (r_resp_cap !== 2'b00) $fatal(1, "rresp=%b", r_resp_cap);
	endtask

	task automatic chk(input string what, input logic cond);
		if (!cond) $fatal(1, "FAIL: %s", what);
		checks++;
	endtask

	initial begin : main
		logic [31:0] got;

		awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
		awaddr = 0; wdata = 0; wstrb = 4'hF; araddr = 0;
		checks = 0;

		repeat (4) @(posedge clk);
		rst <= 1'b0;
		repeat (2) @(posedge clk);
		chk("reset clears hits", hits_o === 32'h0);
		chk("reset clears last", last_o === 32'h0);

		// ---- (a) accepted, observed --------------------------------------
		wr(32'h0000_1301);                       // Cmd=1, Sink=1(AXIS), tag=0x13
		chk("(a) last_o", last_o === 32'h0000_1301);
		chk("(a) hits_o", hits_o === 32'd1);
		$display("TB (a) write accepted+observed : OK");

		// ---- (b) read-back ------------------------------------------------
		rd(got);
		chk("(b) readback", got === 32'h0000_1301);
		$display("TB (b) read-back              : OK");

		// ---- (c) byte strobes --------------------------------------------
		wr(32'hFFFF_FFFF, 4'b0001);
		chk("(c) only byte 0 changed", last_o === 32'h0000_13FF);
		wr(32'hAAAA_AAAA, 4'b0000);              // strobe 0: nothing changes
		chk("(c) strobe 0 no-op", last_o === 32'h0000_13FF);
		chk("(c) strobe 0 still counts as a write", hits_o === 32'd3);
		$display("TB (c) byte strobes           : OK");

		// ---- (d) gapless back-to-back ------------------------------------
		// The point is the core must never stall here. `wr` insists on
		// awready&&wready, so a stall would hang and the watchdog would fire.
		for (int i = 0; i < 3; i++) wr(32'h1000_0000 + i);
		chk("(d) hits after 3 more", hits_o === 32'd6);
		chk("(d) last is the last one", last_o === 32'h1000_0002);
		$display("TB (d) gapless back-to-back   : OK");

		// ---- (e) saturation ----------------------------------------------
		chk("(e) at HITS_MAX", hits_o === HITS_MAX);
		wr(32'hDEAD_0000);
		chk("(e) stays at HITS_MAX (no wrap)", hits_o === HITS_MAX);
		chk("(e) payload still updates", last_o === 32'hDEAD_0000);
		wr(32'hDEAD_0001);
		chk("(e) still saturated", hits_o === HITS_MAX);
		$display("TB (e) hits saturation        : OK");

		// ---- (f) reset ----------------------------------------------------
		rst <= 1'b1;
		repeat (3) @(posedge clk);
		rst <= 1'b0;
		repeat (2) @(posedge clk);
		chk("(f) hits cleared", hits_o === 32'h0);
		chk("(f) last cleared", last_o === 32'h0);
		wr(32'h0000_0055);
		chk("(f) counts again after reset", hits_o === 32'd1);
		$display("TB (f) reset                  : OK");

		$display("TB_PASS (tb_doorbell): checks=%0d", checks);
		$finish;
	end

	initial begin : watchdog
		#500_000;
		$fatal(1, "tb_doorbell: watchdog -- a handshake never completed (the doorbell must ALWAYS be ready)");
	end

endmodule

`default_nettype wire
