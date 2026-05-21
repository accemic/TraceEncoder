// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    ACT-CAP (CSR-based instrumentation) test — AXIS sink.
*
* @details
*   Exercises the ACT-CAP path: the CPU issues a write to the ACT-CAP
*   command CSR (RISC-V CSR 0x0B10) as a functional NOP, and the encoder
*   observes that write on the TIP data channel and turns it into a DAQ
*   (data-acquisition) instrumentation message — without any CPU/bus
*   side effect. See rdl/ct_cs_cpuif.rdl `trActCapStCmd_e`.
*
*   Command under test: ACT_CAP_ST_DAQ_DIRECT_DATA with a known 24-bit
*   DirectData payload, routed to the AXIS sink (ACT_CAP_ST_SINK_AXIS).
*   The encoder emits one AXIS beat: TID = command, element[0] =
*   DirectData (strobe valid).
*
*   Verification is IN-SIM via the env's ENABLE_DECODERS hook, which taps
*   the AXIS sink with ct_axis_decoder; this testbench reads
*   env.dec_axis_msg and asserts the decoded command + payload.
*
*   NOTE — Nexus sink (deferred): the same command can also be routed to
*   the Nexus trace (a DATA_ACQUISITION message, vendor TCODE 7). The
*   external NexRv reference decoder does not understand that vendor
*   message, and the in-sim Nexus decoder (tests/lib/ct_nexus_decoder)
*   cannot be built in this repo because it depends on mseo2_decoder,
*   which has not been ported here. Nexus-side DAQ verification is
*   therefore deferred until that decoder dependency lands; this test
*   covers the AXIS sink.
*
*   Configuration: instruction trace ON (so the encoder runs in normal
*   trace mode alongside the instrumentation), data trace OFF, periodic
*   sync OFF, timestamps OFF.
*/

module csr_cap_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (4),
		.ENABLE_DECODERS     (1),
		.ATB_DUMP_PATH       ("csr_cap_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("csr_cap_tb.tip.txt")
	) env ();

	localparam logic [31:0]  MAIN_PC         = 32'h0000_1000;
	localparam logic [5:0]   CMD_DIRECT_DATA = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA;
	localparam logic [1:0]   SINK_AXIS       = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS;
	localparam logic [23:0]  DIRECT_DATA     = 24'hA_BCDE;

	// ------------------------------------------------------------------
	// Watch the env's in-sim AXIS decoder. Each accepted beat advances
	// dec_axis_msg.id; latch a match against the programmed command +
	// payload (no queue, to stay verilator-friendly).
	// ------------------------------------------------------------------
	int  last_axis_id  = -1;
	int  axis_beats    = 0;
	bit  found_axis    = 0;

	always_ff @(posedge env.wb_clk) begin
		if (!env.wb_rst && env.dec_axis_valid
		    && (env.dec_axis_msg.id != last_axis_id)) begin
			last_axis_id <= env.dec_axis_msg.id;
			axis_beats   <= axis_beats + 1;
			$display("[csr_cap_tb] %0t: axis beat id=%0d tid=0x%0h elem0=0x%0h valid=%b",
			         $time, env.dec_axis_msg.id, env.dec_axis_msg.raw_tid,
			         env.dec_axis_msg.elem[0], env.dec_axis_msg.elem_valid[0]);
			if ((env.dec_axis_msg.raw_tid[5:0] == CMD_DIRECT_DATA)
			    && env.dec_axis_msg.elem_valid[0]
			    && (env.dec_axis_msg.elem[0] == {8'h0, DIRECT_DATA}))
				found_axis <= 1;
		end
	end

	initial begin
		$display("[csr_cap_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[csr_cap_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTsControl_Active      (1'b0);   // timestamps OFF
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.wait_cycles(20);
		$display("[csr_cap_tb] %0t: starting scenario", $time);

		// ============================================================
		// Scenario: a few linear instructions, then the ACT-CAP CSR
		// write (DAQ_DIRECT_DATA -> AXIS sink), then a few more.
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(8);                                          // 0x1000, 0x1004

		env.cpu.act_cap_cmd(.cmd(CMD_DIRECT_DATA),
		                    .sink(SINK_AXIS),
		                    .direct_data(DIRECT_DATA));          // csrw 0xB10 @ 0x1008

		env.cpu.run(8);                                          // 0x100c, 0x1010
		env.cpu.exit_trace();

		// ---- Trace-off ----
		// Disabling instruction tracing emits a Program Trace Correlation
		// Message on the Nexus sink (does not affect the AXIS DAQ check).
		// Enable=0 then only flushes queued trace data; atb_force_flush pushes
		// the last ATB bytes to the sink.
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.wait_cycles(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		// ============================================================
		// Check: the programmed DAQ command must appear on AXIS.
		// ============================================================
		$display("[csr_cap_tb] decoded %0d AXIS beat(s)", axis_beats);
		if (!found_axis) begin
			$error("[csr_cap_tb] FAIL: no AXIS DAQ beat with tid=%0d elem0=0x%0h",
			       CMD_DIRECT_DATA, DIRECT_DATA);
			$fatal(1);
		end

		$display("[csr_cap_tb] PASS: ACT-CAP DAQ_DIRECT_DATA observed on AXIS sink");
		$display("[csr_cap_tb] ATB binary trace:");
		$system("realpath csr_cap_tb.atb.bin");
		$finish;
	end

	// Hard timeout
	initial begin
		#10ms;
		$error("[csr_cap_tb] TIMEOUT - test exceeded 10 ms wall time");
		$fatal(1);
	end

endmodule : csr_cap_tb

`default_nettype wire
