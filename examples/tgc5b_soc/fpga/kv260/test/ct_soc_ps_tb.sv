// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    devmem-flow testbench for the PS-facing SoC (ct_soc_top).
 *
 * @details
 *   Drives the AXI4-Lite slave exactly as Linux `devmem` would on the KV260,
 *   proving the whole on-hardware flow in simulation:
 *     1. hold the core, load the program into RAM (RAM region writes),
 *     2. configure + enable CEDARtools.TraceEncoder (ENC region write to trTeControl),
 *     3. clear + start the core (CTRL region),
 *     4. let it run, disable tracing + flush,
 *     5. read the counters + STATUS and the captured ATB back (CTRL + TRACE
 *        regions), write it to ct_soc_ps_tb.atb.bin for NexRv to decode,
 *     6. read the AXIS DAQ capture back (CTRL + AXIS regions) and check that
 *        record 0 is the watchpoint hit on compute().
 *
 *   This is the software sequence the on-board devmem cheatsheet mirrors.
 */

module ct_soc_ps_tb;

	// Region bases within the AXI4-Lite aperture (see ct_soc_top).
	localparam logic [21:0] CTRL_BASE  = 22'h00_0000;
	localparam logic [21:0] ENC_BASE   = 22'h01_0000;
	localparam logic [21:0] RAM_BASE   = 22'h10_0000;
	localparam logic [21:0] TRACE_BASE = 22'h20_0000;
	localparam logic [21:0] AXIS_BASE  = 22'h30_0000;
	localparam string       PROG_HEX   = "../../examples/tgc5b_soc/prog/prog.hex";

	// Capture-buffer capacities (ct_soc_top TRACE_DEPTH / AXIS_DEPTH). Reads
	// past them alias back to word 0, so the readback below clamps to them.
	localparam int TRACE_WORDS     = 4096;   // 16 KiB of ATB
	localparam int AXIS_BEATS_MAX  = 256;    // 4 KiB of DAQ records

	logic clk = 0;
	logic resetn = 0;
	always #5ns clk = ~clk;

	// AXI4-Lite master side (tb drives).
	logic [21:0] awaddr;  logic awvalid;  uwire awready;
	logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid; uwire wready;
	uwire [1:0]  bresp;   uwire bvalid;    logic bready;
	logic [21:0] araddr;  logic arvalid;   uwire arready;
	uwire [31:0] rdata;   uwire [1:0] rresp; uwire rvalid; logic rready;

	ct_soc_top #(.MEM_WORDS(16384)) dut (
		.clk (clk), .resetn (resetn),
		.s_axi_awaddr (awaddr), .s_axi_awprot (3'b0), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
		.s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid), .s_axi_wready (wready),
		.s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
		.s_axi_araddr (araddr), .s_axi_arprot (3'b0), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
		.s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid), .s_axi_rready (rready)
	);

	// Hold the address/data channels asserted and complete on the *registered*
	// response channel (bvalid / rvalid). This is robust under Verilator, where
	// a combinational *ready that self-deasserts on accept cannot be sampled
	// post-edge. The slave latches at accept and ignores the held valids until
	// it returns to idle, by which point the response has deasserted them.
	// bready / rready are held high for the whole run (see the initial block), so
	// the slave's response always retires the cycle it is presented — avoiding a
	// race where the tb would drop *ready before the slave sampled it.
	task automatic axi_write(input logic [21:0] a, input logic [31:0] d);
		@(posedge clk);
		awaddr <= a; awvalid <= 1'b1; wdata <= d; wstrb <= 4'hF; wvalid <= 1'b1;
		do @(posedge clk); while (!bvalid);
		awvalid <= 1'b0; wvalid <= 1'b0;
	endtask

	task automatic axi_read(input logic [21:0] a, output logic [31:0] d);
		@(posedge clk);
		araddr <= a; arvalid <= 1'b1;
		do @(posedge clk); while (!rvalid);
		d = rdata; arvalid <= 1'b0;
	endtask

	logic [31:0] img [0:1023];
	int fd, i, nbytes, nwords;
	logic [31:0] rd, w;

	initial begin
		awvalid = 0; wvalid = 0; bready = 1; arvalid = 0; rready = 1;
		wstrb = 4'hF; awaddr = 0; araddr = 0; wdata = 0;
		for (i = 0; i < 1024; i++) img[i] = 'x;
		$readmemh(PROG_HEX, img);
		$system("cp ../../examples/tgc5b_soc/prog/prog.pcinfo ct_soc_ps_tb.nexrv.info");

		repeat (10) @(posedge clk);
		resetn <= 1'b1;
		repeat (5) @(posedge clk);
		$display("[ps_tb] reset released, starting devmem sequence");

		// 1. Hold core + clear trace buffer.
		axi_write(CTRL_BASE, 32'h0000_0002);   // trace_clear=1, core_run=0
		axi_write(CTRL_BASE, 32'h0000_0000);   // release clear, still held

		// 2. Load the program image into RAM (contiguous words).
		for (i = 0; i < 1024; i++) begin
			if (img[i] !== 32'hxxxxxxxx) begin
				axi_write(RAM_BASE + 22'(i*4), img[i]);
			end
		end
		$display("[ps_tb] program loaded");

		// 3. Configure + enable CEDARtools.TraceEncoder: trTeControl @ ENC+0x0 =
		//    Format(1)<<24 | InstSyncMode(6)<<16 | InhibitSrc(1)<<15 |
		//    InstMode(6)<<4 | Active|Enable|InstTracing.
		//    CAUTION: a full-word write must preserve the reset-default fields
		//    (InstMode=6, InhibitSrc=1, Format=1): InstMode=0 silently drops
		//    every control-flow message; InhibitSrc=0 inserts a SRC field the
		//    plain NexRv invocation misparses.
		// 3b. ACT-ST watchpoints (encoder CSR space, watchpoints @ +0x4100):
		//     when a retired PC matches an entry, its DAQ command (Cmd |
		//     Sink<<6 | DirectData<<8) is dispatched — here to the AXIS
		//     sink (1), the instrumentation stream the SoC captures into the
		//     AXIS BRAM (readable at 0xA030_0000; beats at CTRL+0x10).
		//     The table is written as a plain SORTED, ascending, unique key
		//     array at entries 0..14 (the module maps flat entry -> tree
		//     level internally and matches on every level); unused entries
		//     are filled with ascending unreachable addresses. Three
		//     watchpoints: compute() entry (PC_CURR), the instruction after
		//     the SCRATCH[0] store (DATA_DADDR — captures data/addr of the
		//     PREVIOUS access), and timer_tick() entry (PC_CURR_LAST).
		begin
			automatic logic [31:0] keys [15] = '{32'h24,32'h40,32'h174,
				32'hFFFF_F030,32'hFFFF_F040,32'hFFFF_F050,32'hFFFF_F060,
				32'hFFFF_F070,32'hFFFF_F080,32'hFFFF_F090,32'hFFFF_F0A0,
				32'hFFFF_F0B0,32'hFFFF_F0C0,32'hFFFF_F0D0,32'hFFFF_F0E0};
			automatic logic [31:0] cmds [15] = '{32'h33333342,32'h11111141,32'h22222246,
				0,0,0,0,0,0,0,0,0,0,0,0};
			for (i = 0; i < 15; i++) begin
				axi_write(ENC_BASE + 22'h4100 + 22'(i*8), keys[i]);
				axi_write(ENC_BASE + 22'h4104 + 22'(i*8), cmds[i]);
			end
		end

		axi_write(ENC_BASE + 22'h0, 32'h0106_8067);

		// 4. Start the core.
		axi_write(CTRL_BASE, 32'h0000_0001);   // core_run=1
		$display("[ps_tb] core started");

		// 5. Let it run.
		repeat (2000) @(posedge clk);
		$display("[ps_tb] ran 2000 cycles");

		// 6. Disable instruction tracing (-> correlation) + flush.
		axi_write(ENC_BASE + 22'h0, 32'h0106_8063);  // clear InstTracing, keep the rest
		$display("[ps_tb] tracing disabled");
		repeat (100) @(posedge clk);
		axi_write(CTRL_BASE, 32'h0000_0005);         // core_run=1 | trace_flush
		repeat (2000) @(posedge clk);
		axi_write(CTRL_BASE, 32'h0000_0001);         // stop flush
		$display("[ps_tb] flushed");

		// 7. Read back the capture. STATUS tells whether either buffer filled
		//    up (then the capture is truncated and the readback must stop at
		//    the buffer depth — further words alias back to word 0).
		axi_read(CTRL_BASE + 22'hC, rd);  nbytes = rd;         // TRACE_BYTES
		axi_read(CTRL_BASE + 22'h8, rd);                       // TRACE_BEATS
		$display("[ps_tb] captured %0d ATB bytes, %0d beats", nbytes, rd);
		axi_read(CTRL_BASE + 22'h4, rd);                       // STATUS
		if (rd[0]) $display("[ps_tb] NOTE: trace_overflow — ATB buffer full (%0d words), trace truncated",
			TRACE_WORDS);
		if (rd[1]) $display("[ps_tb] NOTE: axis_overflow — AXIS buffer full (%0d beats), DAQ beats dropped",
			AXIS_BEATS_MAX);

		fd = $fopen("ct_soc_ps_tb.atb.bin", "wb");
		nwords = (nbytes + 3) / 4;
		if (nwords > TRACE_WORDS) begin
			nwords = TRACE_WORDS;
			nbytes = 4 * TRACE_WORDS;
		end
		for (i = 0; i < nwords; i++) begin
			axi_read(TRACE_BASE + 22'(i*4), w);
			for (int b = 0; b < 4; b++) begin
				if (i*4 + b < nbytes) $fwrite(fd, "%c", w[b*8 +: 8]);
			end
		end
		$fclose(fd);

		if (nbytes == 0) $error("[ps_tb] no ATB bytes captured");
		else             $display("[ps_tb] PASS — wrote ct_soc_ps_tb.atb.bin (%0d bytes)", nbytes);

		// 8. AXIS instrumentation capture: the watchpoints fire compute()
		//    twice, DATA_DADDR once and timer_tick once (4 beats); record 0
		//    is the first compute() PC_CURR — check it round-trips.
		axi_read(CTRL_BASE + 22'h10, rd);
		$display("[ps_tb] AXIS beats captured: %0d (buffer holds %0d)", rd, AXIS_BEATS_MAX);
		if (rd != 4) $error("[ps_tb] expected 4 AXIS beats, got %0d", rd);
		axi_read(AXIS_BASE + 22'h0, w);          // record 0, tdata[31:0] = elem0
		if (w != 32'h0000_0040)
			$error("[ps_tb] AXIS elem0 mismatch: got 0x%08x, want 0x40 (compute PC)", w);
		// Record 0 word 3 = {11'b0, tlast, tid[7:0], tkeep[11:0]}. Only tid is
		// checked: the encoder qualifies elements with tstrb and never asserts
		// tlast, so the captured tkeep/tlast fields are undriven (read 0).
		axi_read(AXIS_BASE + 22'hC, w);
		if (w[17:12] != 6'd1)
			$error("[ps_tb] AXIS tid/cmd mismatch: got %0d, want 1 (DAQ_PC_CURR)", w[17:12]);
		else
			$display("[ps_tb] PASS — AXIS DAQ record 0 ok (cmd=%0d, PC_CURR of compute)", w[17:12]);
		$system("realpath ct_soc_ps_tb.atb.bin");
		$finish;
	end

	initial begin
		#5ms;
		$error("[ps_tb] TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
