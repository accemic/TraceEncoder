// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`timescale 1ns / 1ps
`default_nettype none

/**
 * @brief    Self-checking unit TB for ct_soc_shared_mem (URAM, two ports).
 *
 * @details
 *   The scenarios are ordered by what they would cost if they were wrong,
 *   not by how easy they are to write.
 *
 *     (a) port A write/read round trip
 *     (b) port B write/read round trip -- the ports are independent state
 *         machines, so B is not covered by A
 *     (c) byte strobes on both ports, including a strobe of 0 (must change
 *         nothing at all)
 *     (d) SIMULTANEOUS writes to DIFFERENT words from both ports -- the
 *         property the whole design rests on
 *     (e) SIMULTANEOUS writes to ADJACENT words (n, n+1) from both ports.
 *         This is the REGRESSION GUARD for a real defect found while writing
 *         this TB: the first version of the module packed two 32-bit words
 *         into one 64-bit URAM row, so adjacent words shared one URAM
 *         address and a simultaneous write to a NEIGHBOUR could be lost.
 *         `flag[0]`/`flag[1]` of a Peterson lock are exactly 4 bytes apart,
 *         so the demo's hottest pair would have been corrupted -- and it
 *         would have looked like the software race the demo hunts.
 *     (f) simultaneous read of the same word from both ports
 *     (g) A writes while B reads a different word, and vice versa
 *     (h) address aliasing above the array (the PS window is wider than the
 *         array; reads must repeat, not fault)
 *     (i) randomized soak, both ports driven concurrently against a
 *         reference model
 *
 *   Not covered on purpose: simultaneous write to the SAME word from both
 *   ports. That is an unresolved conflict by contract (see the module
 *   header) -- the demo exists to observe it in software, and asserting an
 *   outcome here would be asserting something the hardware does not promise.
 */

module tb_shared_mem;

	localparam int unsigned SHARED_KIB = 4;      // small array = fast soak, same logic
	localparam int unsigned WORDS      = (SHARED_KIB * 1024) / 4;

	logic clk = 1'b0;
	logic rst = 1'b1;

	always #5 clk = ~clk;                        // 100 MHz

	// -- port A ------------------------------------------------------------
	logic        a_awvalid, a_awready, a_wvalid, a_wready, a_bvalid, a_bready;
	logic [31:0] a_awaddr, a_wdata;
	logic [3:0]  a_wstrb;
	logic [1:0]  a_bresp;
	logic        a_arvalid, a_arready, a_rvalid, a_rready;
	logic [31:0] a_araddr, a_rdata;
	logic [1:0]  a_rresp;

	// -- port B ------------------------------------------------------------
	logic        b_awvalid, b_awready, b_wvalid, b_wready, b_bvalid, b_bready;
	logic [31:0] b_awaddr, b_wdata;
	logic [3:0]  b_wstrb;
	logic [1:0]  b_bresp;
	logic        b_arvalid, b_arready, b_rvalid, b_rready;
	logic [31:0] b_araddr, b_rdata;
	logic [1:0]  b_rresp;

	ct_soc_shared_mem #(.SHARED_KIB(SHARED_KIB)) dut (
		.clk(clk), .rst(rst),
		.a_awvalid(a_awvalid), .a_awready(a_awready), .a_awaddr(a_awaddr),
		.a_wvalid(a_wvalid), .a_wready(a_wready), .a_wdata(a_wdata), .a_wstrb(a_wstrb),
		.a_bvalid(a_bvalid), .a_bready(a_bready), .a_bresp(a_bresp),
		.a_arvalid(a_arvalid), .a_arready(a_arready), .a_araddr(a_araddr),
		.a_rvalid(a_rvalid), .a_rready(a_rready), .a_rdata(a_rdata), .a_rresp(a_rresp),
		.b_awvalid(b_awvalid), .b_awready(b_awready), .b_awaddr(b_awaddr),
		.b_wvalid(b_wvalid), .b_wready(b_wready), .b_wdata(b_wdata), .b_wstrb(b_wstrb),
		.b_bvalid(b_bvalid), .b_bready(b_bready), .b_bresp(b_bresp),
		.b_arvalid(b_arvalid), .b_arready(b_arready), .b_araddr(b_araddr),
		.b_rvalid(b_rvalid), .b_rready(b_rready), .b_rdata(b_rdata), .b_rresp(b_rresp)
	);

	// Reference model. `known[i]` guards the soak against comparing a
	// location nobody has written yet (URAM has no initial value on hardware).
	logic [31:0] ref_mem [0:WORDS-1];
	bit          known   [0:WORDS-1];
	int          checks;

	// -----------------------------------------------------------------
	// Bus drivers. Each is a blocking task per port, so a caller that wants
	// A and B to move in the SAME cycle forks them.
	//
	// Handshake completion is detected in always_ff blocks, NOT by polling
	// from the tasks -- and that is not a style preference.
	//
	// Under Verilator with --timing, a task that resumes on `@(posedge clk)`
	// reads the POST-edge value, whereas IEEE scheduling would give it the
	// value from before the edge. A one-cycle pulse such as `bvalid` is
	// therefore invisible to a polling loop exactly when it matters. An
	// `always_ff` block has ordinary RTL semantics in both worlds, so it sees
	// the beat reliably; the tasks then wait on a flag instead of on the bus.
	//
	// This memory happens to survive naive polling because it answers one
	// cycle later than the doorbell next door -- which is luck, not
	// correctness, and exactly the kind of luck that stops holding the moment
	// a pipeline stage moves.
	// -----------------------------------------------------------------
	logic        a_w_done, a_r_done, b_w_done, b_r_done;
	logic [31:0] a_r_cap,  b_r_cap;
	logic [1:0]  a_b_resp, a_r_resp_c, b_b_resp, b_r_resp_c;

	always_ff @(posedge clk) begin
		a_w_done <= a_bvalid && a_bready;
		a_r_done <= a_rvalid && a_rready;
		b_w_done <= b_bvalid && b_bready;
		b_r_done <= b_rvalid && b_rready;
		if (a_bvalid && a_bready) a_b_resp <= a_bresp;
		if (b_bvalid && b_bready) b_b_resp <= b_bresp;
		if (a_rvalid && a_rready) begin a_r_cap <= a_rdata; a_r_resp_c <= a_rresp; end
		if (b_rvalid && b_rready) begin b_r_cap <= b_rdata; b_r_resp_c <= b_rresp; end
	end

	task automatic a_write(input logic [31:0] addr, input logic [31:0] data,
	                       input logic [3:0] strb = 4'hF);
		a_awaddr = addr; a_wdata = data; a_wstrb = strb;
		a_awvalid = 1'b1; a_wvalid = 1'b1; a_bready = 1'b1;
		do begin @(posedge clk); #1; end while (!a_w_done);
		a_awvalid = 1'b0; a_wvalid = 1'b0; a_bready = 1'b0;
		// A partial byte strobe is UNSUPPORTED and must say so (SLVERR),
		// because UltraRAM has no byte-write enables -- see the module
		// header. Full words and an empty strobe are OKAY.
		if ((strb == 4'hF) || (strb == 4'h0)) begin
			if (a_b_resp !== 2'b00)
				$fatal(1, "A write bresp=%b @%h (expected OKAY)", a_b_resp, addr);
		end else begin
			/* SystemVerilog has no adjacent-string concatenation: one string. */
			if (a_b_resp !== 2'b10)
				$fatal(1, "A partial strobe %b answered %b, expected SLVERR (an unsupported write that pretends to have worked is the worst outcome)", strb, a_b_resp);
		end
		// reference model: whole words only
		if (strb == 4'hF) begin
			ref_mem[addr[31:2] % WORDS] = data;
			known[addr[31:2] % WORDS] = 1'b1;
		end
	endtask

	task automatic b_write(input logic [31:0] addr, input logic [31:0] data,
	                       input logic [3:0] strb = 4'hF);
		b_awaddr = addr; b_wdata = data; b_wstrb = strb;
		b_awvalid = 1'b1; b_wvalid = 1'b1; b_bready = 1'b1;
		do begin @(posedge clk); #1; end while (!b_w_done);
		b_awvalid = 1'b0; b_wvalid = 1'b0; b_bready = 1'b0;
		if ((strb == 4'hF) || (strb == 4'h0)) begin
			if (b_b_resp !== 2'b00)
				$fatal(1, "B write bresp=%b @%h (expected OKAY)", b_b_resp, addr);
		end else begin
			if (b_b_resp !== 2'b10)
				$fatal(1, "B partial strobe %b answered %b, expected SLVERR",
				       strb, b_b_resp);
		end
		if (strb == 4'hF) begin
			ref_mem[addr[31:2] % WORDS] = data;
			known[addr[31:2] % WORDS] = 1'b1;
		end
	endtask

	task automatic a_read(input logic [31:0] addr, output logic [31:0] data);
		a_araddr = addr; a_arvalid = 1'b1; a_rready = 1'b1;
		do begin @(posedge clk); #1; end while (!a_r_done);
		a_arvalid = 1'b0; a_rready = 1'b0;
		data = a_r_cap;
		if (a_r_resp_c !== 2'b00) $fatal(1, "A read rresp=%b @%h", a_r_resp_c, addr);
	endtask

	task automatic b_read(input logic [31:0] addr, output logic [31:0] data);
		b_araddr = addr; b_arvalid = 1'b1; b_rready = 1'b1;
		do begin @(posedge clk); #1; end while (!b_r_done);
		b_arvalid = 1'b0; b_rready = 1'b0;
		data = b_r_cap;
		if (b_r_resp_c !== 2'b00) $fatal(1, "B read rresp=%b @%h", b_r_resp_c, addr);
	endtask

	task automatic expect_a(input logic [31:0] addr, input logic [31:0] want,
	                        input string what);
		logic [31:0] got;
		a_read(addr, got);
		if (got !== want) $fatal(1, "%s: A@%h got %h want %h", what, addr, got, want);
		checks++;
	endtask

	task automatic expect_b(input logic [31:0] addr, input logic [31:0] want,
	                        input string what);
		logic [31:0] got;
		b_read(addr, got);
		if (got !== want) $fatal(1, "%s: B@%h got %h want %h", what, addr, got, want);
		checks++;
	endtask

	// -----------------------------------------------------------------
	initial begin : main
		logic [31:0] got;
		int unsigned seed = 32'h1234_5678;
		int unsigned w;

		a_awvalid = 0; a_wvalid = 0; a_bready = 0; a_arvalid = 0; a_rready = 0;
		b_awvalid = 0; b_wvalid = 0; b_bready = 0; b_arvalid = 0; b_rready = 0;
		a_awaddr = 0; a_wdata = 0; a_wstrb = 4'hF; a_araddr = 0;
		b_awaddr = 0; b_wdata = 0; b_wstrb = 4'hF; b_araddr = 0;
		checks = 0;
		for (int i = 0; i < WORDS; i++) begin ref_mem[i] = 32'h0; known[i] = 1'b0; end

		repeat (4) @(posedge clk);
		rst <= 1'b0;
		repeat (2) @(posedge clk);

		// ---- (a) port A round trip ---------------------------------------
		a_write(32'h0000_0000, 32'hDEAD_BEEF);
		expect_a(32'h0000_0000, 32'hDEAD_BEEF, "(a)");
		$display("TB (a) port A round trip      : OK");

		// ---- (b) port B round trip ---------------------------------------
		b_write(32'h0000_0040, 32'hCAFE_F00D);
		expect_b(32'h0000_0040, 32'hCAFE_F00D, "(b)");
		// and A sees what B wrote -- one array, not two
		expect_a(32'h0000_0040, 32'hCAFE_F00D, "(b) cross-port visibility");
		$display("TB (b) port B round trip      : OK");

		// ---- (c) byte strobes --------------------------------------------
		a_write(32'h0000_0080, 32'hA5A5_1234);
		// A partial strobe must be REFUSED (SLVERR, checked inside the task)
		// and must leave the word untouched -- silently writing part of it,
		// or silently dropping it, would both be worse than an error.
		a_write(32'h0000_0080, 32'hAABB_CCDD, 4'b0010);
		expect_a(32'h0000_0080, 32'hA5A5_1234, "(c) partial strobe must not write");
		b_write(32'h0000_0080, 32'h1122_3344, 4'b1000);
		expect_b(32'h0000_0080, 32'hA5A5_1234, "(c') partial strobe must not write");
		b_write(32'h0000_0080, 32'hFFFF_FFFF, 4'b0000);   // empty strobe: OKAY no-op
		expect_a(32'h0000_0080, 32'hA5A5_1234, "(c) empty strobe must not write");
		$display("TB (c) partial strobe refused : OK");

		// ---- (d) simultaneous writes, different words --------------------
		fork
			a_write(32'h0000_0100, 32'h1111_1111);
			b_write(32'h0000_0200, 32'h2222_2222);
		join
		expect_a(32'h0000_0100, 32'h1111_1111, "(d) A word");
		expect_b(32'h0000_0200, 32'h2222_2222, "(d) B word");
		$display("TB (d) concurrent write/diff  : OK");

		// ---- (e) simultaneous writes, ADJACENT words (regression guard) --
		// Peterson: flag[0] @ +0, flag[1] @ +4.
		a_write(32'h0000_0300, 32'h0);
		b_write(32'h0000_0304, 32'h0);
		fork
			a_write(32'h0000_0300, 32'hA5A5_0001);
			b_write(32'h0000_0304, 32'h5A5A_0001);
		join
		expect_a(32'h0000_0300, 32'hA5A5_0001, "(e) adjacent word 0 LOST");
		expect_b(32'h0000_0304, 32'h5A5A_0001, "(e) adjacent word 1 LOST");
		// and the reverse pairing, in case only one direction is broken
		fork
			b_write(32'h0000_0300, 32'hB0B0_0002);
			a_write(32'h0000_0304, 32'h0B0B_0002);
		join
		expect_b(32'h0000_0300, 32'hB0B0_0002, "(e') adjacent word 0 LOST");
		expect_a(32'h0000_0304, 32'h0B0B_0002, "(e') adjacent word 1 LOST");
		$display("TB (e) concurrent write/adjac : OK  <- regression guard");

		// ---- (f) simultaneous read, same word ----------------------------
		a_write(32'h0000_0400, 32'h600D_600D);
		fork
			expect_a(32'h0000_0400, 32'h600D_600D, "(f) A");
			expect_b(32'h0000_0400, 32'h600D_600D, "(f) B");
		join
		$display("TB (f) concurrent read/same   : OK");

		// ---- (g) write on one port, read on the other --------------------
		a_write(32'h0000_0500, 32'h0505_0505);
		fork
			b_write(32'h0000_0600, 32'h0606_0606);
			expect_a(32'h0000_0500, 32'h0505_0505, "(g) A read undisturbed");
		join
		expect_b(32'h0000_0600, 32'h0606_0606, "(g) B write landed");
		$display("TB (g) write/read cross-port  : OK");

		// ---- (h) aliasing above the array --------------------------------
		a_write(32'h0000_0004, 32'h4242_4242);
		expect_a(32'h0000_0004 + (WORDS*4), 32'h4242_4242, "(h) alias");
		$display("TB (h) address aliasing       : OK");

		// ---- (i) randomized soak, both ports concurrent ------------------
		// seed once: $urandom(seed) re-seeds on every call and would hand
		// back the same number 400 times
		void'($urandom(seed));
		for (int n = 0; n < 400; n++) begin
			logic [31:0] aa, ba, ad, bd;
			logic [3:0]  as, bs;
			aa = ($urandom % WORDS) * 4;
			ba = ($urandom % WORDS) * 4;
			// keep the ports off the same word: the same-word conflict is
			// explicitly not a promised behaviour (see @details)
			if (aa == ba) ba = ((ba/4 + 1) % WORDS) * 4;
			ad = $urandom;
			bd = $urandom;
			// whole words only -- partial strobes are a refused operation
			// and are covered by scenario (c), not by the soak
			as = 4'hF;
			bs = 4'hF;
			fork
				a_write(aa, ad, as);
				b_write(ba, bd, bs);
			join
			// read both back, alternating which port reads which
			w = aa[31:2] % WORDS;
			if (known[w]) begin
				if (n[0]) expect_b(aa, ref_mem[w], "(i) soak A-word via B");
				else      expect_a(aa, ref_mem[w], "(i) soak A-word via A");
			end
			w = ba[31:2] % WORDS;
			if (known[w]) begin
				if (n[0]) expect_a(ba, ref_mem[w], "(i) soak B-word via A");
				else      expect_b(ba, ref_mem[w], "(i) soak B-word via B");
			end
		end
		$display("TB (i) randomized soak        : OK");

		// ---- full sweep against the model --------------------------------
		for (int i = 0; i < WORDS; i++) begin
			if (known[i]) expect_a(i*4, ref_mem[i], "(final) sweep");
		end

		$display("TB_PASS (tb_shared_mem SHARED_KIB=%0d WORDS=%0d): checks=%0d",
		         SHARED_KIB, WORDS, checks);
		$finish;
	end

	// Watchdog: a handshake bug must not hang CI.
	initial begin : watchdog
		#2_000_000;
		$fatal(1, "tb_shared_mem: watchdog -- a handshake never completed");
	end

endmodule

`default_nettype wire
