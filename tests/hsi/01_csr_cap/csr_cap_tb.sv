// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    ACT-CAP (CSR-based instrumentation) test — every command, AXIS + ATB.
 *
 * @details
 *   Exercises the full ACT-CAP command set. The CPU issues writes to the
 *   ACT-CAP command CSR (RISC-V CSR 0x0B10) as functional NOPs; the encoder
 *   observes them on the TIP data channel and turns each into the matching
 *   instrumentation output — without any CPU/bus side effect. See
 *   rdl/ct_cs_cpuif.rdl `trActCapStCmd_e`.
 *
 *   Commands fired (all of them that produce output):
 *     - Every DAQ_* command, routed to BOTH sinks (ACT_CAP_ST_SINK_AXIS_NEXUS):
 *         DAQ_PC_CURR, DAQ_PC_CURR_LAST, DAQ_DIRECT_DATA, DAQ_DATA, DAQ_DADDR,
 *         DAQ_DATA_DADDR, DAQ_DATA_RD, DAQ_DATA_WR, DAQ_IFETCH_TH, DAQ_DATA_RD_TH.
 *       Each emits one AXIS beat (TID = command) AND a Nexus DataAcquisition
 *       message (vendor TCODE 7, IDTAG + DQDATA) on the ATB. Some commands
 *       capture context the encoder tracks from the TIP stream — a preceding
 *       load/store feeds DAQ_DATA/DADDR/DATA_DADDR; the threshold/counter
 *       commands read per-region perf counters (region 0).
 *     - ACT_CAP_ST_CF_SYNC, routed to the Nexus sink only: emits an
 *       instruction synchronization message (NEXUS_SYNC_REQ_CSR), NOT a DAQ
 *       message and no AXIS beat. Issued early, right after the startup sync,
 *       so the two are the first messages in the stream. (This subsumes the
 *       former standalone 02_csr_sync test.)
 *
 *   Verification:
 *     - In-sim (env ENABLE_DECODERS / ct_axis_decoder): the DAQ_DIRECT_DATA
 *       beat is matched on the AXIS sink (command + payload); the total AXIS
 *       beat count is reported. The AXIS beat is identical whether the sink is
 *       AXIS or AXIS_NEXUS.
 *     - Offline (Makefile): the ATB capture (csr_cap_tb.atb.bin) is checked
 *       non-empty, and the NexRv reference decoder counts synchronization
 *       messages and requires >= 2 (startup + the CF_SYNC). A full DAQ
 *       comparison waits on NexRv gaining DAQ-to-CTXP export; until then the
 *       formatter's per-message `DAQ idtag=.. dqdata=..` INFO line in the sim
 *       log corroborates that each DAQ message reached the ATB path. (The
 *       in-sim Nexus decoder is not built here — it depends on mseo2_decoder,
 *       which has not been ported.)
 *
 *   Configuration: instruction trace ON (so the encoder runs in normal trace
 *   mode alongside the instrumentation), data trace OFF (the DAQ context is
 *   captured from the TIP retire stream regardless), periodic sync OFF,
 *   timestamps OFF.
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
		.TIP_DUMP_TXT_PATH   ("csr_cap_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("csr_cap_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("csr_cap_tb.expected.pcs"),
		.EXPECTED_CTXP_PATH  ("csr_cap_tb.expected.ctxp")
	) env ();

	localparam logic [31:0]  MAIN_PC          = 32'h0000_1000;
	localparam logic [1:0]   SINK_AXIS_NEXUS  = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS;
	localparam logic [1:0]   SINK_NEXUS       = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;

	// Every command that emits output (the DAQ_* set goes to AXIS_NEXUS).
	localparam logic [5:0] CMD_PC_CURR      = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR;
	localparam logic [5:0] CMD_PC_CURR_LAST = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR_LAST;
	localparam logic [5:0] CMD_DIRECT_DATA  = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA;
	localparam logic [5:0] CMD_DATA         = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA;
	localparam logic [5:0] CMD_DADDR        = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR;
	localparam logic [5:0] CMD_DATA_DADDR   = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR;
	localparam logic [5:0] CMD_IFETCH_TH    = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_IFETCH_TH;
	localparam logic [5:0] CMD_DATA_RD_TH   = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD_TH;
	localparam logic [5:0] CMD_DATA_WR      = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_WR;
	localparam logic [5:0] CMD_DATA_RD      = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD;
	localparam logic [5:0] CMD_CF_SYNC      = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC;

	localparam logic [23:0] DIRECT_DATA = 24'hA_BCDE;   // tag for DAQ_DIRECT_DATA

	// Data buffers for the load/store that feeds the DAQ data-context commands.
	localparam logic [31:0] BUF_W = 32'h0002_0000;
	localparam logic [31:0] BUF_D = 32'h0002_0008;
	localparam int          DSIZE_W = 2;
	localparam int          DSIZE_D = 3;

	// ------------------------------------------------------------------
	// Watch the env's in-sim AXIS decoder. Each accepted beat advances
	// dec_axis_msg.id; count beats and latch a match against the
	// DAQ_DIRECT_DATA command + payload (no queue, to stay verilator-friendly).
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

		// Data tracing is OFF: the load/store below only feed the DAQ
		// data-context commands, they are not standalone DataRead/Write
		// messages. Mirror that so the CTXP reference omits their MEM records.
		env.cpu.set_data_traced(1'b0);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(8);                                          // linear

		// ------------------------------------------------------------
		// CF_SYNC first (Nexus only): emits an instruction sync message.
		// With periodic sync off, the only syncs are the startup one and
		// this — both land before any DAQ message, so the offline >= 2
		// sync gate is independent of how NexRv treats the DAQ messages.
		// ------------------------------------------------------------
		env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC), .sink(SINK_NEXUS), .direct_data(24'h0));
		env.cpu.run(8);

		// ------------------------------------------------------------
		// Every DAQ_* command, routed to AXIS + ATB. A load and a store
		// first so the data-context commands capture real values.
		// ------------------------------------------------------------
		env.cpu.act_cap_cmd(.cmd(CMD_PC_CURR),      .sink(SINK_AXIS_NEXUS), .direct_data(24'h11_1111));
		env.cpu.act_cap_cmd(.cmd(CMD_DIRECT_DATA),  .sink(SINK_AXIS_NEXUS), .direct_data(DIRECT_DATA));

		env.cpu.load_data (.addr(BUF_W), .size(DSIZE_W));
		env.cpu.store_data(.addr(BUF_D), .size(DSIZE_D), .data(64'hDEAD_BEEF_BAAD_F00D));
		env.cpu.act_cap_cmd(.cmd(CMD_DATA),         .sink(SINK_AXIS_NEXUS), .direct_data(24'h22_2222));
		env.cpu.act_cap_cmd(.cmd(CMD_DADDR),        .sink(SINK_AXIS_NEXUS), .direct_data(24'h33_3333));
		env.cpu.act_cap_cmd(.cmd(CMD_DATA_DADDR),   .sink(SINK_AXIS_NEXUS), .direct_data(24'h44_4444));

		env.cpu.act_cap_cmd(.cmd(CMD_PC_CURR_LAST), .sink(SINK_AXIS_NEXUS), .direct_data(24'h55_5555));

		// Perf-counter / threshold readouts, region 0 (direct_data[7:0]).
		env.cpu.act_cap_cmd(.cmd(CMD_DATA_RD),      .sink(SINK_AXIS_NEXUS), .direct_data(24'h0));
		env.cpu.act_cap_cmd(.cmd(CMD_DATA_WR),      .sink(SINK_AXIS_NEXUS), .direct_data(24'h0));
		env.cpu.act_cap_cmd(.cmd(CMD_IFETCH_TH),    .sink(SINK_AXIS_NEXUS), .direct_data(24'h0));
		env.cpu.act_cap_cmd(.cmd(CMD_DATA_RD_TH),   .sink(SINK_AXIS_NEXUS), .direct_data(24'h0));

		env.cpu.run(8);
		env.cpu.exit_trace();

		// ---- Trace-off ----
		// Disabling instruction tracing emits a Program Trace Correlation
		// Message on the Nexus sink. Enable=0 then only flushes queued trace
		// data; atb_force_flush pushes the last ATB bytes to the sink. A short
		// drain first lets the trace tail propagate through the pipeline-delayed
		// composer while instruction tracing is still effectively on.
		env.wait_cycles(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.wait_cycles(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		// ============================================================
		// In-sim check: the DAQ_DIRECT_DATA command must appear on AXIS;
		// report the total beat count (one per DAQ_* command).
		// ============================================================
		$display("[csr_cap_tb] decoded %0d AXIS beat(s)", axis_beats);
		if (!found_axis) begin
			$error("[csr_cap_tb] FAIL: no AXIS DAQ beat with tid=%0d elem0=0x%0h",
			       CMD_DIRECT_DATA, DIRECT_DATA);
			$fatal(1);
		end

		$display("[csr_cap_tb] PASS: ACT-CAP DAQ commands observed on AXIS sink");
		$display("[csr_cap_tb] sim done; ATB non-empty + sync-count gates run from the Makefile");
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
