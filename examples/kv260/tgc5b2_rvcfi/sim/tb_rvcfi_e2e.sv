// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`timescale 1ns / 1ps
`default_nettype none

/**
 * @brief    End-to-end bench: both cores run the real programs, the real
 *           watchpoint tables are loaded through the real register protocol,
 *           and the captured records are written out for the REAL analyser.
 *
 * @details
 *   This is the step that makes the later board run a confirmation instead
 *   of a first attempt. The same `rvmon` binary that will judge the board
 *   capture judges this dump, so the difference between "green in
 *   simulation" and "green on the board" is reduced to the hardware -- not
 *   to two different analyses that happen to agree.
 *
 *   What is real here and what is not:
 *
 *     REAL  the two program images (loaded via MEM_INIT_FILE, byte-identical
 *           to what the board loads through the RAM window)
 *     REAL  the watchpoint tables, read from the same files the host uses and
 *           written through the same indirect register protocol
 *     REAL  the encoders, the ACT-ST search tree, the AXIS shims, the shared
 *           memory, the ACT-CAP doorbell path
 *     NOT   the FIFO and the PS drain -- the shim's AXI-Stream is captured
 *           directly here. That path is what the board adds, and it is the
 *           one thing this bench deliberately does not claim to have tested.
 *
 *   MODE is a parameter, so the same bench produces the five scenarios; each
 *   leg has its own two-line wrapper (the repository's idiom for parameters,
 *   since `abc -sim` cannot pass them).
 */

module tb_rvcfi_e2e #(
	parameter string PROG0 = "../../examples/kv260/tgc5b2_rvcfi/sw/rvcfi_core0.hex",
	parameter string PROG1 = "../../examples/kv260/tgc5b2_rvcfi/sw/rvcfi_core1.hex",
	parameter string WP0   = "../../examples/kv260/tgc5b2_rvcfi/sw/wp_table_core0_full.txt",
	parameter string WP1   = "../../examples/kv260/tgc5b2_rvcfi/sw/wp_table_core1_full.txt",
	parameter string OUT0  = "rvcfi_e2e_core0.hex",
	parameter string OUT1  = "rvcfi_e2e_core1.hex",
	parameter int unsigned MODE   = 0,
	parameter int unsigned ITERS  = 60,
	parameter int unsigned PACE   = 0,
	parameter int unsigned SEED   = 32'h1234,
	parameter int unsigned CFIOFF = 7,
	parameter int unsigned CAPEVERY = 4,   // 0 = software instrumentation OFF
	parameter int unsigned SHARED_KIB = 8,
	parameter bit          EN_ACTCAP  = 1'b1,
	// N3: 1 routes both record streams into the DDR ring sinks (own AXI
	// write-slave models below) instead of the AXIS/FIFO path -- same
	// programs, same records, different transport. The record files and
	// every downstream check are produced identically in both modes.
	parameter bit          ROUTE_DDR  = 1'b0,
	parameter int unsigned MAX_CYCLES = 4_000_000
);

	// PS aperture offsets (see the SoC top's header)
	localparam logic [21:0] W_CTRL   = 22'h00_0000;
	localparam logic [21:0] W_ENC0   = 22'h01_0000;
	localparam logic [21:0] W_ENC1   = 22'h02_0000;
	localparam logic [21:0] W_SHARED = 22'h04_0000;
	localparam logic [15:0] E_WP_IDX = 16'h400C;
	localparam logic [15:0] E_WP_LO  = 16'h4010;
	localparam logic [15:0] E_WP_HI  = 16'h4014;
	localparam logic [15:0] E_WP_CAP = 16'h4020;

	localparam logic [31:0] RV_MAGIC      = 32'h52565348;
	localparam logic [31:0] RV_DONE_MAGIC = 32'h0E0DDA7A;

	logic clk = 1'b0;
	logic resetn = 1'b0;
	always #5 clk = ~clk;

	logic [21:0] awaddr, araddr;
	logic        awvalid, awready, wvalid, wready, bvalid, bready;
	logic [31:0] wdata, rdata;
	logic [3:0]  wstrb;
	logic [1:0]  bresp, rresp;
	logic        arvalid, arready, rvalid, rready;

	logic        m0_tvalid, m1_tvalid, m0_tlast, m1_tlast;
	logic [31:0] m0_tdata, m1_tdata;
	logic [3:0]  m0_tkeep, m1_tkeep;
	logic [31:0] shim0_drops, shim1_drops, shim0_fill, shim1_fill;
	logic        shim0_ovf, shim1_ovf;

	logic [31:0] m_awaddr, m_wdata;
	logic [7:0]  m_awlen;
	logic [2:0]  m_awsize;
	logic [1:0]  m_awburst;
	logic        m_awvalid, m_wlast, m_wvalid, m_bready;
	logic [3:0]  m_wstrb;
	logic [31:0] n_awaddr, n_wdata;
	logic [7:0]  n_awlen;
	logic [2:0]  n_awsize;
	logic [1:0]  n_awburst;
	logic        n_awvalid, n_wlast, n_wvalid, n_bready;
	logic [3:0]  n_wstrb;
	logic        pib_clk_o;
	logic [3:0]  pib_data_o;

	int fd0, fd1;
	int n0 = 0, n1 = 0;
	int w0 = 0, w1 = 0;   // effective word counts (AXIS or ring, set at harvest)
	int cycles = 0;

	/* The program images are NOT passed as MEM_INIT_FILE. They are written
	 * through the PS RAM windows, exactly as `rvmon load` does on the board,
	 * so this bench exercises the real loading path instead of a simulation
	 * shortcut.
	 *
	 * There is a second reason, found the hard way: two different
	 * MEM_INIT_FILE values make Verilator emit two parameterizations of the
	 * wrapper, and its C++ generation then loses the RDL struct types of the
	 * peripheral block ("does not name a type"). Loading through the bus
	 * leaves one parameterization -- and is the more faithful bench anyway. */
	tgc5b2_rvcfi_soc_top #(
		.SHARED_KIB    (SHARED_KIB),
		.EN_ACTCAP     (EN_ACTCAP)
	) dut (
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
		.m_axi_bresp (2'b00), .m_axi_bvalid (m_bvalid), .m_axi_bready (m_bready),
		.m1_axi_awaddr (n_awaddr), .m1_axi_awlen (n_awlen), .m1_axi_awsize (n_awsize),
		.m1_axi_awburst (n_awburst), .m1_axi_awvalid (n_awvalid), .m1_axi_awready (1'b1),
		.m1_axi_wdata (n_wdata), .m1_axi_wstrb (n_wstrb), .m1_axi_wlast (n_wlast),
		.m1_axi_wvalid (n_wvalid), .m1_axi_wready (1'b1),
		.m1_axi_bresp (2'b00), .m1_axi_bvalid (n_bvalid), .m1_axi_bready (n_bready),
		.pib_clk (pib_clk_o), .pib_data (pib_data_o)
	);

	// -- N3: two AXI write slaves with memory, one per record ring ----------
	// 64-KiB capture arrays (the rings are programmed to 64 KiB below --
	// WARL-legal, and every leg's record total stays well under it, so the
	// simulation never wraps and the array IS the ring content). The write
	// address decodes relative to the per-ring base; a beat outside the
	// programmed window would be the U6 escape and is fatal immediately.
	localparam logic [31:0] TB_RING0_BASE = 32'h5000_0000;
	localparam logic [31:0] TB_RING1_BASE = 32'h5800_0000;
	localparam int unsigned TB_RING_SIZE  = 32'h0001_0000;   // 64 KiB

	logic [31:0] ring_mem0 [0:TB_RING_SIZE/4-1];
	logic [31:0] ring_mem1 [0:TB_RING_SIZE/4-1];
	logic        m_bvalid = 1'b0, n_bvalid = 1'b0;
	logic [31:0] wr_off0 = '0, wr_off1 = '0;   // running beat address per burst
	int          cap0 = 0, cap1 = 0;           // words captured (quiescence signal)

	// AW and the first W beat may land in the same cycle (both ready lines
	// are constant 1), so the effective offset is computed combinationally
	// from AW when present -- two schedule-ordered non-blocking writes to
	// wr_off would otherwise race, and the winner is a tool detail.
	always_ff @(posedge clk) begin
		logic [31:0] eff0;
		if (m_bvalid && m_bready) m_bvalid <= 1'b0;
		eff0 = wr_off0;
		if (m_awvalid) begin
			if (m_awaddr < TB_RING0_BASE
			    || (m_awaddr - TB_RING0_BASE) + ((32'(m_awlen) + 1) << 2) > TB_RING_SIZE)
				$fatal(1, "ring0 AW outside the window: 0x%08x", m_awaddr);
			eff0 = m_awaddr - TB_RING0_BASE;
		end
		if (m_wvalid) begin
			ring_mem0[eff0 >> 2] <= m_wdata;
			eff0 = eff0 + 4;
			cap0 <= cap0 + 1;
			if (m_wlast) m_bvalid <= 1'b1;
		end
		wr_off0 <= eff0;
	end

	always_ff @(posedge clk) begin
		logic [31:0] eff1;
		if (n_bvalid && n_bready) n_bvalid <= 1'b0;
		eff1 = wr_off1;
		if (n_awvalid) begin
			if (n_awaddr < TB_RING1_BASE
			    || (n_awaddr - TB_RING1_BASE) + ((32'(n_awlen) + 1) << 2) > TB_RING_SIZE)
				$fatal(1, "ring1 AW outside the window: 0x%08x", n_awaddr);
			eff1 = n_awaddr - TB_RING1_BASE;
		end
		if (n_wvalid) begin
			ring_mem1[eff1 >> 2] <= n_wdata;
			eff1 = eff1 + 4;
			cap1 <= cap1 + 1;
			if (n_wlast) n_bvalid <= 1'b1;
		end
		wr_off1 <= eff1;
	end

	// -- PS bus driver (completion detected in RTL semantics; see tb_shared_mem)
	logic        w_done, r_done;
	logic [31:0] r_cap;
	always_ff @(posedge clk) begin
		w_done <= bvalid && bready;
		r_done <= rvalid && rready;
		if (rvalid && rready) r_cap <= rdata;
	end

	task automatic ps_write(input logic [21:0] a, input logic [31:0] d);
		awaddr = a; wdata = d; wstrb = 4'hF;
		awvalid = 1'b1; wvalid = 1'b1; bready = 1'b1;
		do begin @(posedge clk); #1; end while (!w_done);
		awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0;
	endtask

	task automatic ps_read(input logic [21:0] a, output logic [31:0] d);
		araddr = a; arvalid = 1'b1; rready = 1'b1;
		do begin @(posedge clk); #1; end while (!r_done);
		arvalid = 1'b0; rready = 1'b0;
		d = r_cap;
	endtask

	// -- capture both shim streams -----------------------------------------
	// Written as text, one 32-bit word per line: `rvmon analyze` accepts that
	// directly, so no conversion step stands between this bench and the real
	// analyser.
	always_ff @(posedge clk) begin
		if (resetn) begin
			if (m0_tvalid) begin $fdisplay(fd0, "%08x", m0_tdata); n0 <= n0 + 1; end
			if (m1_tvalid) begin $fdisplay(fd1, "%08x", m1_tdata); n1 <= n1 + 1; end
		end
	end

	// -- load one watchpoint table through the indirect protocol ------------
	task automatic load_table(input logic [21:0] enc, input string path,
	                          output int slots);
		int    fh, code, n;
		string line;
		logic [31:0] a, c, cap, idx;
		fh = $fopen(path, "r");
		if (fh == 0) $fatal(1, "cannot open %s", path);
		ps_read(enc + 22'(E_WP_CAP), cap);
		n = 0;
		ps_write(enc + 22'(E_WP_IDX), 32'h0);
		while (!$feof(fh)) begin
			code = $fgets(line, fh);
			if (code <= 0) break;
			if (line.substr(0, 0) == "#") continue;
			code = $sscanf(line, "%h %h", a, c);
			if (code == 2) begin
				ps_write(enc + 22'(E_WP_LO), a);
				ps_write(enc + 22'(E_WP_HI), c);   // the High write commits
				n = n + 1;
			end
		end
		$fclose(fh);
		// n commits from 0 must wrap the index back to 0 -- the cheapest
		// possible proof that every single write was accepted.
		ps_read(enc + 22'(E_WP_IDX), idx);
		if (cap != n)
			$fatal(1, "trWpCap=%0d but the table has %0d entries", cap, n);
		if (idx != 0)
			$fatal(1, "index did not wrap after %0d commits (reads %0d)", n, idx);
		slots = n;
	endtask

	/* Write one $readmemh-style image through a PS RAM window, one word per
	 * line, while the core is held. Same path the host uses. */
	task automatic load_image(input logic [21:0] win, input string path,
	                          output int words);
		int    fh, code;
		string line;
		logic [31:0] w;
		fh = $fopen(path, "r");
		if (fh == 0) $fatal(1, "cannot open %s", path);
		words = 0;
		while (!$feof(fh)) begin
			code = $fgets(line, fh);
			if (code <= 0) break;
			code = $sscanf(line, "%h", w);
			if (code == 1) begin
				ps_write(win + 22'(words * 4), w);
				words = words + 1;
			end
		end
		$fclose(fh);
	endtask

	initial begin : main
		logic [31:0] v, done0, done1;
		int slots0, slots1, words0, words1;

		awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
		awaddr = 0; araddr = 0; wdata = 0; wstrb = 4'hF;

		fd0 = $fopen(OUT0, "w");
		fd1 = $fopen(OUT1, "w");
		if (fd0 == 0 || fd1 == 0) $fatal(1, "cannot open the capture files");

		repeat (10) @(posedge clk);
		resetn <= 1'b1;
		repeat (10) @(posedge clk);

		// sanity: the right design
		ps_read(W_CTRL + 22'h5C, v);
		if (v !== 32'h5256_4349) $fatal(1, "MAGIC reads %h", v);

		// program images through the RAM windows (cores are held)
		load_image(22'h10_0000, PROG0, words0);
		load_image(22'h08_0000, PROG1, words1);
		$display("TB images loaded              : core0=%0d words core1=%0d words",
		         words0, words1);

		/* Start the timestamp unit. Without this every record carries ts = 0,
		 * and a constant timestamp destroys the one property the whole race
		 * analysis rests on: cross-core ordering. It fails silently -- the
		 * records look perfectly well-formed.
		 *
		 * trTsControl (0x040): Active[0], Count[1], Type[6:4], Enable[15].
		 * Type = TR_TS_CORE (3), because the SoC feeds the shared fabric
		 * counter into tip._time, which is what TR_TS_CORE selects. */
		ps_write(W_ENC0 + 22'h0040, 32'h0000_8033);
		ps_write(W_ENC1 + 22'h0040, 32'h0000_8033);
		ps_read (W_ENC0 + 22'h0040, v);
		$display("TB timestamp unit             : trTsControl reads %08h", v);

		// tables through the real protocol, verified by readback
		load_table(W_ENC0, WP0, slots0);
		load_table(W_ENC1, WP1, slots1);
		$display("TB tables loaded              : core0=%0d core1=%0d slots", slots0, slots1);

		// control area, then read it back
		ps_write(W_SHARED + 22'h10, 32'h0);          // go = 0
		ps_write(W_SHARED + 22'h04, 32'(MODE));
		ps_write(W_SHARED + 22'h08, 32'(ITERS));
		ps_write(W_SHARED + 22'h0C, 32'(PACE));
		ps_write(W_SHARED + 22'h14, 32'(SEED));
		ps_write(W_SHARED + 22'h18, 32'(CFIOFF));
		ps_write(W_SHARED + 22'h1C, 32'(CAPEVERY));
		ps_write(W_SHARED + 22'h60, 32'h0);          // balance
		ps_write(W_SHARED + 22'h64, 32'h0);          // count
		ps_write(W_SHARED + 22'h68, 32'h0);          // checksum
		ps_write(W_SHARED + 22'h80, 32'h0);          // ring head
		ps_write(W_SHARED + 22'h84, 32'h0);          // ring tail
		ps_write(W_SHARED + 22'h180, 32'h0);         // result0.done
		ps_write(W_SHARED + 22'h1A0, 32'h0);         // result1.done
		ps_write(W_SHARED + 22'h00, RV_MAGIC);
		ps_read (W_SHARED + 22'h00, v);
		if (v !== RV_MAGIC) $fatal(1, "shared control did not read back (%h)", v);
		$display("TB control area published     : mode=%0d iters=%0d pace=%0d", MODE, ITERS, PACE);

		/* Open the barrier FIRST, then release. The other order deadlocks,
		 * and the reason is the shared memory's own contract: the PS window
		 * onto it is muxed away as soon as either core runs (`ps_owns_shared`
		 * in the SoC top), so a write to `go` after the release never gets
		 * ready and the AXI transaction hangs forever.
		 *
		 * Nothing is lost by doing it this way: both run bits are set by ONE
		 * register write, so the release itself is the barrier. `go` stays in
		 * the design for a host that wants to arm everything and start later
		 * -- it just has to be written while the cores are still held. */
		if (ROUTE_DDR) begin
			// N3 ring setup, in the documented order: cores are still held,
			// so route/clear/enable cannot tear a record. 64-KiB rings (the
			// slave models above are sized to that); default bases kept and
			// verified by readback -- a WARL that silently rejected the size
			// would otherwise let the run write 128 MiB into a 64-KiB model.
			ps_write(W_CTRL + 22'h88, TB_RING_SIZE);              // ring0 SIZE
			ps_write(W_CTRL + 22'hA8, TB_RING_SIZE);              // ring1 SIZE
			ps_read (W_CTRL + 22'h88, v);
			if (v !== TB_RING_SIZE) $fatal(1, "ring0 SIZE did not take: %08h", v);
			ps_read (W_CTRL + 22'h84, v);
			if (v !== TB_RING0_BASE) $fatal(1, "ring0 BASE default wrong: %08h", v);
			ps_read (W_CTRL + 22'hA4, v);
			if (v !== TB_RING1_BASE) $fatal(1, "ring1 BASE default wrong: %08h", v);
			ps_write(W_CTRL + 22'h80, 32'h0000_000E);  // route|circ|clear, en=0
			ps_write(W_CTRL + 22'hA0, 32'h0000_000E);
			ps_write(W_CTRL + 22'h80, 32'h0000_000D);  // route|circ|en
			ps_write(W_CTRL + 22'hA0, 32'h0000_000D);
			ps_read (W_CTRL + 22'h80, v);
			if (v !== 32'h0000_000D) $fatal(1, "ring0 CTRL reads %08h", v);
			$display("TB rings armed                : 2 x %0d B, route=ddr", TB_RING_SIZE);
		end

		// Console RX proof: queue "PING" for both cores BEFORE the release;
		// the programs echo their RX right after the greeting, so one run
		// demonstrates the channel in both directions with no interactivity.
		begin
			string ping = "PING";
			int pi;
			for (pi = 0; pi < ping.len(); pi++) begin
				ps_write(W_CTRL + 22'h68, 32'(ping.getc(pi)));
				ps_write(W_CTRL + 22'h78, 32'(ping.getc(pi)));
			end
		end

		ps_write(W_SHARED + 22'h10, 32'h1);          // go = 1, cores still held
		ps_write(W_CTRL   + 22'h00, 32'h0000_0300);  // b8|b9: release both
		$display("TB cores released             : waiting for both to finish");

		/* Wait for the record stream to dry up, NOT for the result mailbox.
		 *
		 * The mailbox lives in shared memory, and shared memory is exactly
		 * what the PS cannot reach while a core runs -- polling it here would
		 * hang the bench the same way the barrier did. Watching the capture
		 * counters costs no bus access at all and says the same thing: when
		 * neither core has produced a record for a while, both have reached
		 * their halt loop.
		 *
		 * On the board the host has the same restriction and the same way
		 * out: `rvmon` watches the FIFO/doorbell counters in the CTRL bank,
		 * which are readable at any time, and reads the mailbox only after
		 * stopping the cores. */
		begin
			int quiet, prev0, prev1, cur0, cur1;
			quiet = 0; prev0 = -1; prev1 = -1;
			while (cycles < MAX_CYCLES && quiet < 8) begin
				repeat (2000) @(posedge clk);
				cycles = cycles + 2000;
				// In ring mode the AXIS stays silent by design; the slave
				// models' beat counters are the equivalent liveness signal.
				cur0 = ROUTE_DDR ? cap0 : n0;
				cur1 = ROUTE_DDR ? cap1 : n1;
				if (cur0 == prev0 && cur1 == prev1) quiet = quiet + 1;
				else                                quiet = 0;
				prev0 = cur0; prev1 = cur1;
			end
		end

		repeat (2000) @(posedge clk);                 // let the tail drain
		ps_write(W_CTRL + 22'h00, 32'h0);             // stop both cores
		repeat (50) @(posedge clk);                   // cores in reset again
		ps_read(W_SHARED + 22'h180, done0);           // mailbox readable now
		ps_read(W_SHARED + 22'h1A0, done1);

		if (ROUTE_DDR) begin : ddr_harvest
			// Judge the rings by their own registers, then produce the SAME
			// record files the AXIS path produces -- everything downstream
			// (verdict runner included) must not be able to tell the
			// transports apart.
			logic [31:0] wp0, wp1, st0, st1, dr0, dr1, bt0, bt1;
			ps_read(W_CTRL + 22'h8C, wp0);  ps_read(W_CTRL + 22'hAC, wp1);
			ps_read(W_CTRL + 22'h90, st0);  ps_read(W_CTRL + 22'hB0, st1);
			ps_read(W_CTRL + 22'h94, dr0);  ps_read(W_CTRL + 22'hB4, dr1);
			ps_read(W_CTRL + 22'h98, bt0);  ps_read(W_CTRL + 22'hB8, bt1);
			$display("TB ring0                      : wptr=%0d B beats=%0d stat=%01h drops=%0d",
			         wp0, bt0, st0[3:0], dr0);
			$display("TB ring1                      : wptr=%0d B beats=%0d stat=%01h drops=%0d",
			         wp1, bt1, st1[3:0], dr1);
			if (dr0 != 0 || dr1 != 0)
				$fatal(1, "ring sink drops (%0d/%0d) at record rates -- that must never happen", dr0, dr1);
			if (st0[1] || st1[1] || st0[3] || st1[3])
				$fatal(1, "ring stat reports axi_err/cfg_rej (%01h/%01h)", st0[3:0], st1[3:0]);
			if (wp0 != (bt0 << 2) || wp1 != (bt1 << 2))
				$fatal(1, "wptr != 4*beats (%0d/%0d vs %0d/%0d) -- the sink lost words on the way", wp0, wp1, bt0, bt1);
			if (wp0 != 32'(cap0) << 2 || wp1 != 32'(cap1) << 2)
				$fatal(1, "wptr disagrees with the slave capture (%0d/%0d vs %0d/%0d words)", wp0 >> 2, wp1 >> 2, cap0, cap1);
			if ((wp0 & 32'hF) != 0 || (wp1 & 32'hF) != 0)
				$fatal(1, "ring holds a torn record (wptr %0d/%0d not a record multiple)", wp0, wp1);
			for (int i = 0; i < 32'(wp0) / 4; i++) $fdisplay(fd0, "%08x", ring_mem0[i]);
			for (int i = 0; i < 32'(wp1) / 4; i++) $fdisplay(fd1, "%08x", ring_mem1[i]);
			w0 = int'(wp0) / 4;
			w1 = int'(wp1) / 4;
		end
		else begin
			w0 = n0;
			w1 = n1;
		end

		$fclose(fd0);
		$fclose(fd1);

		ps_read(W_SHARED + 22'h60, v);
		$display("TB account balance            : %0d", v);
		ps_read(W_SHARED + 22'h64, v);
		$display("TB account count              : %0d", v);
		/* Three counters at three points on the same path. If hits rose and
		 * conversions did not, the doorbell address is wrong; if both rose
		 * and records are missing, they were dropped downstream; if hits
		 * stopped mid-block, the core is stuck ON a doorbell store. */
		// Drain both consoles and gate on the expected text. The greeting
		// proves core->PS, the echoed PING proves PS->core -- and a channel
		// that only half-works fails here, not on the board.
		begin
			string con0 = "", con1 = "";
			logic [31:0] cv;
			int guard;
			for (guard = 0; guard < 64; guard++) begin
				ps_read(W_CTRL + 22'h64, cv);
				if (!cv[31]) break;
				con0 = {con0, $sformatf("%c", cv[7:0])};
			end
			for (guard = 0; guard < 64; guard++) begin
				ps_read(W_CTRL + 22'h74, cv);
				if (!cv[31]) break;
				con1 = {con1, $sformatf("%c", cv[7:0])};
			end
			$display("TB console core0              : %s", con0);
			$display("TB console core1              : %s", con1);
			if (con0.substr(0, 11) != "hello core 0")
				$fatal(1, "console core0 greeting wrong: '%s'", con0);
			if (con1.substr(0, 11) != "hello core 1")
				$fatal(1, "console core1 greeting wrong: '%s'", con1);
			if (con0.len() < 17 || con0.substr(13, 16) != "PING")
				$fatal(1, "console core0 did not echo PING: '%s'", con0);
			if (con1.len() < 17 || con1.substr(13, 16) != "PING")
				$fatal(1, "console core1 did not echo PING: '%s'", con1);
			$display("TB console both directions    : OK");
		end

		ps_read(W_CTRL + 22'h40, v); $display("TB doorbell hits core0        : %0d", v);
		ps_read(W_CTRL + 22'h48, v); $display("TB doorbell hits core1        : %0d", v);
		ps_read(W_CTRL + 22'h50, v); $display("TB act-cap conv  core0        : %0d", v);
		ps_read(W_CTRL + 22'h54, v); $display("TB act-cap conv  core1        : %0d", v);
		$display("TB records captured           : core0=%0d core1=%0d", w0 / 4, w1 / 4);

		/* SystemVerilog has no adjacent-string concatenation: one string each. */
		if (done0 != RV_DONE_MAGIC || done1 != RV_DONE_MAGIC)
			$fatal(1, "cores did not finish within %0d cycles (done0=%h done1=%h) -- raise MAX_CYCLES or lower ITERS", MAX_CYCLES, done0, done1);
		if (shim0_drops != 0 || shim1_drops != 0)
			$fatal(1, "shim drops in simulation (%0d/%0d) -- the capture is not loss-free and no verdict may be drawn from it", shim0_drops, shim1_drops);

		$display("TB_PASS (tb_rvcfi_e2e MODE=%0d%s): records core0=%0d core1=%0d drops=0/0",
		         MODE, ROUTE_DDR ? " ring" : "", w0 / 4, w1 / 4);
		$finish;
	end

	initial begin : watchdog
		#200_000_000;
		$fatal(1, "tb_rvcfi_e2e: watchdog");
	end

endmodule

`default_nettype wire
