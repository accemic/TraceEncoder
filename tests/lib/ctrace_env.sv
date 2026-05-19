// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    C-Trace test environment (sketch).
*
* @details
*   Single-instance harness around `ct_encoder`. Provides:
*     - Clock and reset generation for the encoder's 5 clock domains.
*     - The DUT (`ct_encoder`).
*     - `cpu_model` stimulus driver on the TIP side.
*     - `ct_cs_cpuif_wb_helper` for programming the encoder's CSRs.
*     - An ATB stall-injector + always-ready sink, so tests can force
*       backpressure to provoke overflow.
*     - An AXIS always-ready sink + dumper.
*     - An ATB dumper (`atb_dump`) for debug.
*
*   Testbenches typically instantiate this module ONCE and drive the
*   exposed `cpu` and `csr` instances. See tests/instruction/01_basic/
*   for a worked example.
*
*   This is a *sketch* — scoreboarding is intentionally minimal (counts
*   + $display). A proper N-Trace decode-vs-event-log scoreboard is a
*   follow-up; for the moment tests assert "encoder emitted some bytes
*   after enabling tracing", which is enough to validate the harness.
*/

module ctrace_env #(
	bit    SPLIT_DATA_ACCESS = 0,
	int    CYCLES_PER_INSTR  = 4,
	// REQUIRED: binary ATB trace output. This is the primary artifact
	// of every test — the actual N-Trace byte stream produced by the
	// encoder. Tests pass an explicit filename; the file lands in the
	// simulator's CWD and the test prints the absolute path via
	// $system("realpath ...").
	string ATB_DUMP_PATH     = "",
	// Optional: per-instruction TIP text dump (one CSV-ish line per
	// retired control-flow event, source PC + type + target). Useful
	// for cross-checking the cpu_model's drive against what the
	// encoder ingested. Empty = no dump.
	string TIP_DUMP_TXT_PATH = "",
	// Optional: NexRv PCInfo file derived from the cpu_model event
	// log. Same address-by-address format the original tip_generator
	// emitted; suitable as input to the NexRv reference decoder.
	// Empty = no file.
	string NEXRV_INFO_PATH   = "",
	// Optional: execution-ordered list of PCs the cpu_model retired,
	// one per line. Used as the reference by the NexRv decode-check
	// script (the decoded .pcout should match this line-for-line).
	string EXPECTED_PCS_PATH = ""
) ();

	// ------------------------------------------------------------------
	// Clock generation
	//   tip_clk @ 100 MHz, atb/proc @ 250 MHz (>= 2x / 3x tip), wb/wall @ 100 MHz
	// ------------------------------------------------------------------
	logic tip_clk     = 0;
	logic atb_atclk   = 0;
	logic proc_clk    = 0;
	logic wb_clk      = 0;
	logic wall_clk    = 0;

	initial forever #5ns  tip_clk   = ~tip_clk;
	initial forever #2ns  atb_atclk = ~atb_atclk;
	initial forever #2ns  proc_clk  = ~proc_clk;
	initial forever #5ns  wb_clk    = ~wb_clk;
	initial forever #5ns  wall_clk  = ~wall_clk;

	// ------------------------------------------------------------------
	// Reset sequencer
	// ------------------------------------------------------------------
	logic tip_rst       = 1;
	logic atb_atresetn  = 0;
	logic proc_rst      = 1;
	logic wb_rst        = 1;
	logic ct_cs_rst     = 1;
	logic wall_clk_rst  = 1;

	initial begin
		#80ns;
		@(posedge tip_clk);   tip_rst       <= 0;
		@(posedge atb_atclk); atb_atresetn  <= 1;
		@(posedge proc_clk);  proc_rst      <= 0;
		@(posedge wb_clk);    wb_rst        <= 0;
		@(posedge wb_clk);    ct_cs_rst     <= 0;
		@(posedge wall_clk);  wall_clk_rst  <= 0;
	end

	// ------------------------------------------------------------------
	// Interfaces
	// ------------------------------------------------------------------
	localparam int WB_DATA_WIDTH = 32;
	localparam int WB_ADDR_WIDTH = 32;

	tip_if  tip();
	wb_if  #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_ADDR_WIDTH)) wb();
	axis_if axis(.aclk(wb_clk), .aresetn(~wb_rst));
	atb_if  atb_up();    // between DUT and stall injector
	atb_if  atb_dn();    // between stall injector and sink

	// ------------------------------------------------------------------
	// DUT
	// ------------------------------------------------------------------
	ct_encoder #(.SPLIT_DATA_ACCESS(SPLIT_DATA_ACCESS)) dut (
		.tip_clk,      .tip_rst,       .tip,
		.wb_clk,       .wb_rst,        .wb,    .ct_cs_rst,
		.axis,
		.atb_atclk,    .atb_atresetn,  .atb (atb_up),
		.proc_clk,     .proc_rst,
		.wall_clk,     .wall_clk_rst
	);

	// ------------------------------------------------------------------
	// TIP stimulus — scripted CPU model
	// ------------------------------------------------------------------
	cpu_model #(
		.CYCLES_PER_INSTR   (CYCLES_PER_INSTR),
		.NEXRV_INFO_PATH    (NEXRV_INFO_PATH),
		.EXPECTED_PCS_PATH  (EXPECTED_PCS_PATH)
	) cpu (
		.clk (tip_clk),
		.rst (tip_rst),
		.tip (tip.master)
	);

	// ------------------------------------------------------------------
	// CSR programming helper
	// ------------------------------------------------------------------
	ct_cs_cpuif_wb_helper csr (
		.clk (wb_clk),
		.wb  (wb.master)
	);

	// ------------------------------------------------------------------
	// ATB stall injector + always-ready sink
	//
	// Tests toggle `atb_force_stall` to provoke backpressure-induced
	// overflow. Default is no stalling.
	// ------------------------------------------------------------------
	logic atb_stall_enable = 0;
	logic atb_force_stall  = 0;

	atb_stall_injector #(
		.STALL_PERIOD     (32),
		.STALL_LENGTH_MAX (16)
	) atb_inj (
		.atb_atclk,
		.atb_atresetn,
		.stall_enable_i (atb_stall_enable),
		.force_stall_i  (atb_force_stall),
		.atb_up         (atb_up),
		.atb_dn         (atb_dn)
	);

	// Always-ready ATB sink. atb_if's slave-driven signals (atready,
	// afready) are tied high so the sink unconditionally accepts.
	//
	// `atb_force_flush` (-> afvalid) and `atb_force_sync` (-> syncreq)
	// give tests an end-of-scenario hook to force the encoder to drain
	// its pipeline, so the offline NexRv decode sees a complete trace.
	// Both default to 0 and are forwarded back through the stall
	// injector to ct_encoder's ATB master-side inputs.
	logic atb_force_flush = 0;
	logic atb_force_sync  = 0;
	assign atb_dn.atready = 1'b1;
	assign atb_dn.afready = 1'b1;
	assign atb_dn.afvalid = atb_force_flush;
	assign atb_dn.syncreq = atb_force_sync;

	// ------------------------------------------------------------------
	// AXIS always-ready slave
	// ------------------------------------------------------------------
	assign axis.tready = 1'b1;

	// ------------------------------------------------------------------
	// Observers
	//
	//   atb_recorder : ATB binary dump (REQUIRED — this is the actual
	//                  N-Trace byte stream and the primary test output)
	//   tip_recorder : TIP per-instruction text dump (optional)
	//
	// `atb_dump` unconditionally calls file_open on the supplied path,
	// so the env refuses to elaborate without an ATB_DUMP_PATH set.
	// ------------------------------------------------------------------
	initial begin
		if (ATB_DUMP_PATH == "") begin
			$display("FATAL: ctrace_env requires ATB_DUMP_PATH parameter to be set.");
			$display("       The ATB binary trace is the primary output of every test.");
			$fatal(1);
		end
	end

	atb_dump #(.FILEPATH(ATB_DUMP_PATH)) atb_recorder (
		.atb_atclk,
		.atb_atresetn,
		.atb (atb_dn.monitor)
	);

	tip_dump #(
		.FILEPATH_TIP_DUMP_DETAILS (TIP_DUMP_TXT_PATH),
		.DUMP_COUNT_MAX            (4096)
	) tip_recorder (
		.clk (tip_clk),
		.rst (tip_rst),
		.tip (tip.slave)
	);

	// ------------------------------------------------------------------
	// Minimal activity monitors / counters (scoreboard placeholder)
	// ------------------------------------------------------------------
	int atb_bytes_seen = 0;
	int axis_xfers_seen = 0;

	always_ff @(posedge atb_atclk) begin
		if (atb_atresetn && atb_dn.atvalid && atb_dn.atready) begin
			atb_bytes_seen <= atb_bytes_seen + 1;
		end
	end

	always_ff @(posedge wb_clk) begin
		if (!wb_rst && axis.tvalid && axis.tready) begin
			axis_xfers_seen <= axis_xfers_seen + 1;
		end
	end

	// ------------------------------------------------------------------
	// Wait helpers for test code
	// ------------------------------------------------------------------
	task automatic wait_for_reset_release();
		// Level-based to be order-insensitive: works whether the caller
		// invokes us before or after the reset sequencer fires.
		wait (tip_rst       == 1'b0);
		wait (proc_rst      == 1'b0);
		wait (atb_atresetn  == 1'b1);
		wait (wb_rst        == 1'b0);
		wait (ct_cs_rst     == 1'b0);
		wait (wall_clk_rst  == 1'b0);
		repeat (4) @(posedge tip_clk);
	endtask

	task automatic wait_cycles(int n, input string domain = "tip");
		case (domain)
			"tip":  repeat (n) @(posedge tip_clk);
			"atb":  repeat (n) @(posedge atb_atclk);
			"proc": repeat (n) @(posedge proc_clk);
			"wb":   repeat (n) @(posedge wb_clk);
			default: repeat (n) @(posedge tip_clk);
		endcase
	endtask

endmodule : ctrace_env

`default_nettype wire
