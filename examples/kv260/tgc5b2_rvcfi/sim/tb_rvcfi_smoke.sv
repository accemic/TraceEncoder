// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`timescale 1ns / 1ps
`default_nettype none

/**
 * @brief    Integration smoke test for tgc5b2_rvcfi_soc_top: does the PS
 *           reach the new shared-memory window, and does the SoC still
 *           behave when it does?
 *
 * @details
 *   This is deliberately NOT the end-to-end demo bench (that one needs the
 *   two programs and their oracle). It gates exactly what the RV/CFI
 *   integration added, with both cores held in reset so nothing else moves:
 *
 *     (a) the top elaborates and the CTRL window answers (MAGIC-free sanity:
 *         CONTROL is written and reads back)
 *     (b) the SHARED window at 0x04_0000 accepts a write and returns it --
 *         the whole point of the new segment. If the segment decode were
 *         wrong, this read would return the CTRL or RAM1 window instead of
 *         what was written, so the check is the decode's proof, not decor.
 *     (c) byte strobes survive the path PS -> segment decode -> mux -> URAM
 *     (d) several addresses across the window, including one beyond the
 *         array, to show the documented aliasing rather than a fault
 *     (e) reads of an untouched location are stable (URAM has no bitstream
 *         initialization -- the value is whatever it is, but it must not
 *         change by itself, and it must not be X once written)
 *     (f) no X on the top's outward-facing status outputs
 *
 *   Deliberately out of scope here: anything that needs a running core. With
 *   `core_run = 0` the shared memory belongs to the PS by construction (see
 *   `ps_owns_shared` in the top), which is exactly the state this bench
 *   wants -- the core-side path is covered by the end-to-end bench once the
 *   programs exist.
 */

module tb_rvcfi_smoke;

	localparam int unsigned SHARED_KIB = 4;      // small: fast elaboration
	localparam logic [21:0] W_CTRL     = 22'h00_0000;
	localparam logic [21:0] W_SHARED   = 22'h04_0000;

	logic clk = 1'b0;
	logic resetn = 1'b0;
	always #5 clk = ~clk;

	// -- PS AXI4-Lite ------------------------------------------------------
	logic [21:0] awaddr, araddr;
	logic        awvalid, awready, wvalid, wready, bvalid, bready;
	logic [31:0] wdata, rdata;
	logic [3:0]  wstrb;
	logic [1:0]  bresp, rresp;
	logic        arvalid, arready, rvalid, rready;

	// -- shim streams (drained, not checked here) --------------------------
	logic        m0_tvalid, m1_tvalid, m0_tlast, m1_tlast;
	logic [31:0] m0_tdata, m1_tdata;
	logic [3:0]  m0_tkeep, m1_tkeep;
	logic [31:0] shim0_drops, shim1_drops, shim0_fill, shim1_fill;
	logic        shim0_ovf, shim1_ovf;

	// -- DDR master (tied off) ---------------------------------------------
	logic [31:0] m_awaddr, m_wdata;
	logic [7:0]  m_awlen;
	logic [2:0]  m_awsize;
	logic [1:0]  m_awburst;
	logic        m_awvalid, m_wlast, m_wvalid, m_bready;
	logic [3:0]  m_wstrb;
	logic        pib_clk_o;
	logic [3:0]  pib_data_o;

	int checks;

	tgc5b2_rvcfi_soc_top #(.SHARED_KIB(SHARED_KIB)) dut (
		.clk (clk), .resetn (resetn),
		.s_axi_awaddr (awaddr), .s_axi_awprot (3'b000), .s_axi_awvalid (awvalid),
		.s_axi_awready (awready),
		.s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid),
		.s_axi_wready (wready),
		.s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
		.s_axi_araddr (araddr), .s_axi_arprot (3'b000), .s_axi_arvalid (arvalid),
		.s_axi_arready (arready),
		.s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid),
		.s_axi_rready (rready),
		.m0_axis_tvalid (m0_tvalid), .m0_axis_tready (1'b1), .m0_axis_tdata (m0_tdata),
		.m0_axis_tkeep (m0_tkeep), .m0_axis_tlast (m0_tlast),
		.shim0_drop_count (shim0_drops), .shim0_overflow_sticky (shim0_ovf),
		.shim0_fill_level (shim0_fill),
		.m1_axis_tvalid (m1_tvalid), .m1_axis_tready (1'b1), .m1_axis_tdata (m1_tdata),
		.m1_axis_tkeep (m1_tkeep), .m1_axis_tlast (m1_tlast),
		.shim1_drop_count (shim1_drops), .shim1_overflow_sticky (shim1_ovf),
		.shim1_fill_level (shim1_fill),
		.m_axi_awaddr (m_awaddr), .m_axi_awlen (m_awlen), .m_axi_awsize (m_awsize),
		.m_axi_awburst (m_awburst), .m_axi_awvalid (m_awvalid), .m_axi_awready (1'b1),
		.m_axi_wdata (m_wdata), .m_axi_wstrb (m_wstrb), .m_axi_wlast (m_wlast),
		.m_axi_wvalid (m_wvalid), .m_axi_wready (1'b1),
		.m_axi_bresp (2'b00), .m_axi_bvalid (1'b0), .m_axi_bready (m_bready),
		// N3 ring 1 master: idle here -- the smoke bench only exercises the
		// register bank, never an enabled sink.
		.m1_axi_awaddr (), .m1_axi_awlen (), .m1_axi_awsize (),
		.m1_axi_awburst (), .m1_axi_awvalid (), .m1_axi_awready (1'b1),
		.m1_axi_wdata (), .m1_axi_wstrb (), .m1_axi_wlast (),
		.m1_axi_wvalid (), .m1_axi_wready (1'b1),
		.m1_axi_bresp (2'b00), .m1_axi_bvalid (1'b0), .m1_axi_bready (),
		.pib_clk (pib_clk_o), .pib_data (pib_data_o)
	);

	// Handshake completion in RTL semantics (see tb_shared_mem's note on why
	// polling from a task is unsafe under Verilator --timing).
	logic        w_done, r_done;
	logic [31:0] r_cap;
	logic [1:0]  b_cap, r_resp_cap;
	always_ff @(posedge clk) begin
		w_done <= bvalid && bready;
		r_done <= rvalid && rready;
		if (bvalid && bready) b_cap <= bresp;
		if (rvalid && rready) begin r_cap <= rdata; r_resp_cap <= rresp; end
	end

	task automatic ps_write(input logic [21:0] a, input logic [31:0] d,
	                        input logic [3:0] s = 4'hF);
		awaddr = a; wdata = d; wstrb = s;
		awvalid = 1'b1; wvalid = 1'b1; bready = 1'b1;
		do begin @(posedge clk); #1; end while (!w_done);
		awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0;
		if (b_cap !== 2'b00) $fatal(1, "PS write bresp=%b @%h", b_cap, a);
	endtask

	task automatic ps_read(input logic [21:0] a, output logic [31:0] d);
		araddr = a; arvalid = 1'b1; rready = 1'b1;
		do begin @(posedge clk); #1; end while (!r_done);
		arvalid = 1'b0; rready = 1'b0;
		d = r_cap;
		if (r_resp_cap !== 2'b00) $fatal(1, "PS read rresp=%b @%h", r_resp_cap, a);
	endtask

	task automatic expect_at(input logic [21:0] a, input logic [31:0] want,
	                      input string what);
		logic [31:0] got;
		ps_read(a, got);
		if (got !== want) $fatal(1, "%s: @%h got %h want %h", what, a, got, want);
		checks++;
	endtask

	initial begin : main
		logic [31:0] got, again;

		awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
		awaddr = 0; araddr = 0; wdata = 0; wstrb = 4'hF;
		checks = 0;

		repeat (10) @(posedge clk);
		resetn <= 1'b1;
		repeat (10) @(posedge clk);

		// ---- (a) CTRL window answers -------------------------------------
		// Both cores stay held: bits 0/8/9 remain 0, only trace_clear moves.
		ps_write(W_CTRL, 32'h0000_0002);      // trace_clear pulse
		ps_write(W_CTRL, 32'h0000_0000);
		ps_read (W_CTRL + 22'h4, got);        // STATUS: must not be X
		if ($isunknown(got)) $fatal(1, "(a) STATUS reads X: %h", got);
		checks++;
		$display("TB (a) CTRL window            : OK (STATUS=%h)", got);

		// ---- (b) SHARED window round trip --------------------------------
		ps_write(W_SHARED + 22'h0, 32'hC0FF_EE00);
		expect_at(W_SHARED + 22'h0, 32'hC0FF_EE00, "(b) shared word 0");
		ps_write(W_SHARED + 22'h4, 32'h1234_5678);
		expect_at(W_SHARED + 22'h4, 32'h1234_5678, "(b) shared word 1");
		expect_at(W_SHARED + 22'h0, 32'hC0FF_EE00, "(b) word 0 undisturbed");
		$display("TB (b) SHARED window          : OK");

		// ---- (c) partial strobe must not change the word ------------------
		// The shared memory is UltraRAM and has no byte-write enables, so a
		// partial strobe is a refused operation (SLVERR at the block; the SoC
		// front end does not forward the response code, which is why the
		// check here is on the DATA, not on bresp -- and the data check is
		// the one that matters: silently writing part of a word would be the
		// damaging outcome).
		ps_write(W_SHARED + 22'h8, 32'hA5A5_1234);
		ps_write(W_SHARED + 22'h8, 32'hAABB_CCDD, 4'b0100);
		expect_at(W_SHARED + 22'h8, 32'hA5A5_1234, "(c) partial strobe must not write");
		$display("TB (c) partial strobe refused : OK");

		// ---- (d) spread + documented aliasing -----------------------------
		for (int i = 0; i < 8; i++) begin
			ps_write(W_SHARED + 22'(i*64), 32'hA000_0000 + i);
		end
		for (int i = 0; i < 8; i++) begin
			expect_at(W_SHARED + 22'(i*64), 32'hA000_0000 + i, "(d) spread");
		end
		// one array length further along must alias back onto word 0
		expect_at(W_SHARED + 22'(SHARED_KIB*1024), 32'hA000_0000, "(d) alias");
		$display("TB (d) spread + aliasing      : OK");

		// ---- (e) stability -------------------------------------------------
		ps_read(W_SHARED + 22'h100, got);
		repeat (20) @(posedge clk);
		ps_read(W_SHARED + 22'h100, again);
		if (got !== again) $fatal(1, "(e) untouched location changed: %h -> %h", got, again);
		checks++;
		$display("TB (e) stability              : OK");

		// ---- (g) RV/CFI observation bank -----------------------------------
		expect_at(W_CTRL + 22'h5C, 32'h5256_4349, "(g) MAGIC");
		expect_at(W_CTRL + 22'h58, 32'(SHARED_KIB*1024), "(g) SHARED_SZ");
		// Both cores are held, so nothing has instrumented anything yet.
		expect_at(W_CTRL + 22'h40, 32'h0, "(g) DB0_HITS");
		expect_at(W_CTRL + 22'h48, 32'h0, "(g) DB1_HITS");
		expect_at(W_CTRL + 22'h50, 32'h0, "(g) ACTCAP0");
		expect_at(W_CTRL + 22'h54, 32'h0, "(g) ACTCAP1");
		// A write into the read-only bank must be inert -- in particular it
		// must NOT alias onto CONTROL (offset 0x40 vs 0x00 differ in bit 6
		// only), which would start both cores by accident.
		ps_write(W_CTRL + 22'h40, 32'hFFFF_FFFF);
		expect_at(W_CTRL + 22'h0,  32'h0, "(g) CONTROL untouched by bank write");
		expect_at(W_CTRL + 22'h40, 32'h0, "(g) bank still read-only");
		$display("TB (g) observation bank       : OK");

		// ---- (i) console bank, as far as held cores allow ------------------
		// TX can only be fed by a running core, so here: STAT resets sane,
		// an RX push is accepted and counted, and a POP of the empty TX says
		// so via the valid bit instead of returning stale data.
		expect_at(W_CTRL + 22'h60, 32'h0000_0800, "(i) CON0_STAT reset (tx=0, rx_free=2048)");
		expect_at(W_CTRL + 22'h70, 32'h0000_0800, "(i) CON1_STAT reset");
		ps_write(W_CTRL + 22'h68, 32'h41);          // push 'A' into core0 RX
		ps_write(W_CTRL + 22'h68, 32'h42);          // push 'B'
		expect_at(W_CTRL + 22'h60, 32'h0000_07FE, "(i) CON0 rx_free dropped by 2");
		expect_at(W_CTRL + 22'h70, 32'h0000_0800, "(i) CON1 untouched by CON0 pushes");
		ps_read(W_CTRL + 22'h64, got);
		if (got[31]) $fatal(1, "(i) CON0_POP claims data on an empty TX");
		checks++;
		expect_at(W_CTRL + 22'h68, 32'h0, "(i) CON0 rx_drops still 0");
		$display("TB (i) console bank           : OK");

		// ---- (j) N3 ring bank: defaults, WARL, aliases ---------------------
		// Defaults after reset: both rings disabled, circular, FIFO route,
		// 128 MiB each, split of the 256-MiB window.
		expect_at(W_CTRL + 22'h80, 32'h0000_0004, "(j) RING0_CTRL reset (circ only)");
		expect_at(W_CTRL + 22'h84, 32'h5000_0000, "(j) RING0_BASE reset");
		expect_at(W_CTRL + 22'h88, 32'h0800_0000, "(j) RING0_SIZE reset (128 MiB)");
		expect_at(W_CTRL + 22'hA4, 32'h5800_0000, "(j) RING1_BASE reset");
		expect_at(W_CTRL + 22'hA8, 32'h0800_0000, "(j) RING1_SIZE reset");
		expect_at(W_CTRL + 22'h8C, 32'h0, "(j) RING0_WPTR reset");
		expect_at(W_CTRL + 22'h90, 32'h0, "(j) RING0_STAT reset");
		// WARL: everything below must be REJECTED and leave base/size alone,
		// with cfg_rej going sticky -- an address outside the resmem window
		// on S_AXI_HP does not error on the board, it wedges the PS.
		ps_write(W_CTRL + 22'h84, 32'h4000_0000);   // below the window
		ps_write(W_CTRL + 22'h84, 32'h6000_0000);   // at the exclusive end
		ps_write(W_CTRL + 22'h84, 32'h5000_0010);   // misaligned (16 B)
		ps_write(W_CTRL + 22'h88, 32'h1000_0020);   // base+size beyond the window
		ps_write(W_CTRL + 22'h88, 32'h0000_0014);   // not a multiple of 32
		ps_write(W_CTRL + 22'h88, 32'h0);           // zero
		expect_at(W_CTRL + 22'h84, 32'h5000_0000, "(j) BASE survives illegal writes");
		expect_at(W_CTRL + 22'h88, 32'h0800_0000, "(j) SIZE survives illegal writes");
		expect_at(W_CTRL + 22'h90, 32'h0000_0008, "(j) cfg_rej sticky after rejects");
		// The exact fit is LEGAL: 256 MiB from the window base end exactly at
		// the exclusive limit. The first version of this bench called it
		// illegal and the WARL rightly disagreed.
		ps_write(W_CTRL + 22'h88, 32'h1000_0000);
		expect_at(W_CTRL + 22'h88, 32'h1000_0000, "(j) exact-fit SIZE is legal");
		ps_write(W_CTRL + 22'h88, 32'h0800_0000);
		// Legal reconfiguration while disabled, then rejection while enabled.
		ps_write(W_CTRL + 22'h84, 32'h5010_0000);
		ps_write(W_CTRL + 22'h88, 32'h0001_0000);
		expect_at(W_CTRL + 22'h84, 32'h5010_0000, "(j) legal BASE accepted");
		expect_at(W_CTRL + 22'h88, 32'h0001_0000, "(j) legal SIZE accepted");
		ps_write(W_CTRL + 22'h80, 32'h0000_0002);   // clear pulse: cfg_rej gone
		expect_at(W_CTRL + 22'h90, 32'h0, "(j) clear resets cfg_rej");
		ps_write(W_CTRL + 22'h80, 32'h0000_000D);   // en|circ|route
		expect_at(W_CTRL + 22'h80, 32'h0000_000D, "(j) CTRL readback en|circ|route");
		ps_write(W_CTRL + 22'h84, 32'h5000_0000);   // legal value, but en=1
		expect_at(W_CTRL + 22'h84, 32'h5010_0000, "(j) BASE locked while enabled");
		expect_at(W_CTRL + 22'h90, 32'h0000_0008, "(j) cfg_rej set by locked write");
		ps_write(W_CTRL + 22'h80, 32'h0000_0006);   // disable + clear + circ
		ps_write(W_CTRL + 22'h84, 32'h5000_0000);   // restore defaults
		ps_write(W_CTRL + 22'h88, 32'h0800_0000);
		ps_write(W_CTRL + 22'h80, 32'h0000_0004);
		// Core-1 bank is its own registers, not an alias of core 0.
		ps_write(W_CTRL + 22'hA4, 32'h5900_0000);
		expect_at(W_CTRL + 22'hA4, 32'h5900_0000, "(j) RING1_BASE independent");
		expect_at(W_CTRL + 22'h84, 32'h5000_0000, "(j) RING0_BASE untouched by it");
		ps_write(W_CTRL + 22'hA4, 32'h5800_0000);
		// Alias guards: a ring-bank write must not reach CONTROL, and the
		// unused 0xC0.. quadrant must neither read data nor pop a console.
		ps_write(W_CTRL + 22'h80, 32'h0000_0004);   // [5:2]=0 like CONTROL
		expect_at(W_CTRL + 22'h00, 32'h0, "(j) CONTROL untouched by ring write");
		expect_at(W_CTRL + 22'hE4, 32'h0, "(j) 0xE4 reads zero");
		expect_at(W_CTRL + 22'h60, 32'h0000_07FE, "(j) console untouched by 0xE4 read");
		$display("TB (j) ring bank              : OK");

		// ---- (f) no X on the status outputs -------------------------------
		if ($isunknown({shim0_drops, shim1_drops, shim0_fill, shim1_fill,
		                shim0_ovf, shim1_ovf}))
			$fatal(1, "(f) shim status carries X");
		checks++;
		$display("TB (f) no X on status         : OK");

		$display("TB_PASS (tb_rvcfi_smoke SHARED_KIB=%0d): checks=%0d", SHARED_KIB, checks);
		$finish;
	end

	initial begin : watchdog
		#5_000_000;
		$fatal(1, "tb_rvcfi_smoke: watchdog -- an AXI4-Lite handshake never completed");
	end

endmodule

`default_nettype wire
