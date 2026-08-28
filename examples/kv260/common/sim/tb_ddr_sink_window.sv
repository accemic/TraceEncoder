// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
`timescale 1ns/1ps

/**
 * @brief    Unit gate for the DDR sink's window guard (defect class B-C1-1).
 *
 * @details
 *   Ported from the archive tree (package U6);
 *   the body is unchanged in substance, only the build wiring is new -- see
 *   `tb_ddr_sink_window.abc` and `make sim-ddr-sink-window`. The German
 *   `$display` texts are the archive gate's verbatim wording, so a run here
 *   and the recorded U6 evidence read identically; the machine-checkable
 *   marker is `U6_WINDOW_UNIT_PASS`.
 *
 *   The scenario a byte-exact measurement established (the predecessor repository
 *   `docs/handoffs/C1_sink_overrun.md` section 5): DDR_SIZE is shrunk BELOW the
 *   current write offset while the sink runs. `bytes_left = size_i - off_q`
 *   is unsigned and used to underflow; the consequence was exactly ONE
 *   transfer outside [base, base+size) -- on the board a DMA write into
 *   memory the sink does not own.
 *
 *   This bench drives the sink DIRECTLY (not through ct_trace_sinks, whose
 *   register interlock has refused that write since U6): only then is the
 *   guard inside the module itself testable -- and this is exactly the
 *   instantiation form used by the tops that wire the sink themselves
 *   (rocket*, cva6_2, cva6_linux*), which do not have that interlock.
 *
 *   Expectation (guard present): NO burst outside the window, the engine
 *   stops, the beats are counted as drops (no silent loss). Counter-probe
 *   (guard removed): the AXI model sees an address >= base+size and the run
 *   fails.
 */
module tb_ddr_sink_window;

	localparam logic [31:0] BASE      = 32'h1000_0000;
	localparam logic [31:0] SIZE_BIG  = 32'h0000_0400;   // 1 KiB
	localparam logic [31:0] SIZE_TINY = 32'h0000_0100;   // 256 B (< off_q)

	logic clk = 1'b0;
	always #5 clk = ~clk;
	logic rst = 1'b1;

	logic        enable_i = 1'b0, clear_i = 1'b0, circ_i = 1'b0;
	logic [31:0] size_i = SIZE_BIG;
	logic        beat_valid = 1'b0;
	logic [31:0] beat_data  = 32'h0;

	uwire logic [31:0] wptr, drops;
	uwire logic        full, wrapped, axi_err;

	uwire logic [31:0] awaddr;  uwire logic [7:0] awlen;  uwire logic [2:0] awsize;
	uwire logic [1:0]  awburst; uwire logic awvalid;
	uwire logic [31:0] wdata;   uwire logic [3:0] wstrb;
	uwire logic        wlast, wvalid, bready;
	logic              awready = 1'b1, wready = 1'b1, bvalid = 1'b0;

	int unsigned n_bursts = 0, n_outside = 0, n_wbeats = 0;

	ct_soc_ddr_sink #(.FIFO_WORDS(64)) dut (
		.clk (clk), .rst (rst),
		.enable_i (enable_i), .clear_i (clear_i),
		.base_i (BASE), .size_i (size_i), .circ_i (circ_i),
		.beat_valid_i (beat_valid), .beat_data_i (beat_data),
		.wptr_o (wptr), .full_o (full), .wrapped_o (wrapped),
		.axi_err_o (axi_err), .drops_o (drops),
		.m_axi_awaddr (awaddr), .m_axi_awlen (awlen), .m_axi_awsize (awsize),
		.m_axi_awburst (awburst), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
		.m_axi_wdata (wdata), .m_axi_wstrb (wstrb), .m_axi_wlast (wlast),
		.m_axi_wvalid (wvalid), .m_axi_wready (wready),
		.m_axi_bresp (2'b00), .m_axi_bvalid (bvalid), .m_axi_bready (bready)
	);

	// --- AXI write slave: always ready, counts bursts and reports every
	//     address that leaves the CURRENT window (including the end of the
	//     burst -- an 8-beat burst writes 32 bytes).
	always_ff @(posedge clk) begin
		if (rst) begin
			bvalid <= 1'b0;
		end
		else begin
			if (bvalid && bready) bvalid <= 1'b0;
			if (awvalid && awready) begin
				n_bursts <= n_bursts + 1;
				if (awaddr < BASE ||
				    (awaddr - BASE) + ((32'(awlen) + 32'd1) << 2) > size_i) begin
					n_outside <= n_outside + 1;
					$display("[u6_unit] OUT-OF-WINDOW: AW 0x%08x + %0d B, window 0x%08x + 0x%08x",
					         awaddr, (32'(awlen) + 32'd1) << 2, BASE, size_i);
				end
			end
			if (wvalid && wready) begin
				n_wbeats <= n_wbeats + 1;
				if (wlast) bvalid <= 1'b1;
			end
		end
	end

	// --- Beat source: one beat every other cycle, a running pattern.
	int unsigned beat_ctr = 0;
	task automatic feed(input int unsigned n);
		for (int i = 0; i < n; i++) begin
			@(posedge clk);
			beat_valid <= 1'b1;
			beat_data  <= 32'hC0DE_0000 + 32'(beat_ctr);
			beat_ctr    = beat_ctr + 1;
			@(posedge clk);
			beat_valid <= 1'b0;
		end
	endtask

	initial begin
		repeat (5) @(posedge clk);
		rst <= 1'b0;
		repeat (5) @(posedge clk);

		// 1. Regular operation inside the large window.
		enable_i <= 1'b1;
		feed(128);                       // 512 B -> off_q = 512 > SIZE_TINY
		repeat (200) @(posedge clk);
		if (n_outside != 0)
			$fatal(1, "[u6_unit] already %0d bursts outside during regular operation", n_outside);
		if (wptr != 32'd512)
			$fatal(1, "[u6_unit] WPTR %0d != 512 B after 128 beats", wptr);
		$display("[u6_unit] phase 1 OK -- %0d bursts, WPTR=%0d B, 0 drops (%0d), off_q=%0d",
		         n_bursts, wptr, drops, dut.off_q);

		// 2. Defect class B-C1-1: shrink the window below the offset WHILE RUNNING.
		//    (ct_trace_sinks no longer allows this since the fix -- a top with
		//    its own wiring still does.)
		size_i <= SIZE_TINY;
		@(posedge clk);
		feed(128);
		repeat (400) @(posedge clk);

		if (n_outside != 0)
			$fatal(1, "[u6_unit] WINDOW GUARD VIOLATED -- %0d bursts outside [0x%08x, +0x%08x)",
			       n_outside, BASE, SIZE_TINY);
		if (drops == 0)
			$fatal(1, "[u6_unit] no beat counted as dropped -- the loss would have been silent");
		$display("[u6_unit] phase 2 OK -- engine stops: WPTR stays %0d B, %0d drops counted, 0 bursts outside",
		         wptr, drops);

		// 3. Clean up as per the contract: disable -> clear -> resize -> enable.
		enable_i <= 1'b0;
		@(posedge clk);
		clear_i <= 1'b1; @(posedge clk); clear_i <= 1'b0;
		repeat (4) @(posedge clk);
		if (wptr != 0 || drops != 0)
			$fatal(1, "[u6_unit] clear does not clear (wptr=%0d drops=%0d)", wptr, drops);
		size_i <= SIZE_BIG;
		enable_i <= 1'b1;
		feed(32);
		repeat (200) @(posedge clk);
		if (n_outside != 0)
			$fatal(1, "[u6_unit] %0d bursts outside after the contract path", n_outside);
		if (wptr != 32'd128)
			$fatal(1, "[u6_unit] after clear/new window WPTR %0d != 128 B", wptr);
		$display("[u6_unit] phase 3 OK -- after disable/clear/resize/enable the sink runs again (WPTR=%0d B)", wptr);

		$display("[u6_unit] DDR WINDOW GUARD PASS -- shrinking while running stays inside the window (%0d bursts total, %0d W beats, %0d drops counted)",
		         n_bursts, n_wbeats, drops);
		$display("U6_WINDOW_UNIT_PASS");
		$finish;
	end

	// Emergency brake against a hanging run.
	initial begin
		#500000;
		$fatal(1, "[u6_unit] Timeout");
	end

endmodule

`default_nettype wire
