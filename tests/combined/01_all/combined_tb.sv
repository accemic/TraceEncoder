// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Combined test — instruction trace + data trace + ACT-CAP sync.
 *
 * @details
 *   End-to-end mixed workload that runs the instruction-trace,
 *   data-trace and ACT-CAP (CSR-based instrumentation) paths together,
 *   to catch interactions the per-feature tests miss in isolation:
 *     - linear code, a taken branch, a call and a return (instruction
 *       control flow),
 *     - varied-size loads and stores interleaved with the code (data
 *       trace),
 *     - one ACT_CAP_ST_CF_SYNC issued via the ACT-CAP CSR (0x0B10)
 *       mid-stream, which makes the encoder transmit an instruction
 *       synchronization message.
 *
 *   Verification (offline, from the Makefile — one sim, three checks, all
 *   driven by the NexRv reference decoder on the ATB dump):
 *     - scripts/decode_and_check.sh       : NexRv -deco reconstructs the
 *                                           PC stream from the trace and it
 *                                           matches the cpu_model's executed
 *                                           PCs (proves the combined
 *                                           instruction trace decodes).
 *     - scripts/decode_and_check_data.sh  : decoded DataRead/DataWrite
 *                                           sequence matches the loads/stores.
 *     - scripts/decode_and_check_sync.sh  : >= 3 synchronization messages
 *                                           (startup + the mid-stream
 *                                           CF_SYNC + the final flush CF_SYNC).
 *
 *   Two CF_SYNCs are issued: one mid-stream (the feature under test, shown
 *   working amid a real instruction+data mix) and one just before exit.
 *   The latter flushes the trailing instructions into a real ProgTraceSync
 *   so NexRv -deco sees the whole functional workload — necessary here
 *   because, with periodic sync off, there is no other in-band flush (the
 *   ATB syncreq is only honoured in ITR_SYNC_ATB mode). Only the final
 *   flushing csrw itself is left undecoded (exclusive-ICNT sync semantics).
 *
 *   Configuration: instruction trace ON, data trace ON, periodic sync
 *   OFF, timestamps OFF (deterministic, minimal byte stream for the
 *   offline NexRv decode). Timestamp interleaving is intentionally left
 *   out here; it belongs to a dedicated follow-up.
 */

module combined_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (4),
		.ATB_DUMP_PATH       ("combined_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("combined_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("combined_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("combined_tb.expected.pcs"),
		.EXPECTED_DATA_PATH  ("combined_tb.expected.data")
	) env ();

	localparam logic [31:0] MAIN_PC = 32'h0000_1000;
	localparam logic [31:0] BRANCH  = 32'h0000_1100;
	localparam logic [31:0] FUNC    = 32'h0000_2000;

	// Data buffers, well clear of the PC range.
	localparam logic [31:0] BUF_W = 32'h0002_0000;
	localparam logic [31:0] BUF_D = 32'h0002_0008;
	localparam logic [31:0] BUF_H = 32'h0002_0010;
	localparam logic [31:0] BUF_B = 32'h0002_0012;

	localparam int DSIZE_B = 0;
	localparam int DSIZE_H = 1;
	localparam int DSIZE_W = 2;
	localparam int DSIZE_D = 3;

	localparam logic [5:0] CMD_CF_SYNC = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC;
	localparam logic [1:0] SINK_NEXUS  = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;

	initial begin
		$display("[combined_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[combined_tb] %0t: reset released", $time);

		env.csr.clear();
		// Timestamps ON: free-running SYSTEM counter, every tip_clk cycle
		// (prescale 0). Sync messages carry the absolute timestamp; non-sync
		// messages carry a delta. The decoder reconstructs absolute times,
		// which must be monotonic (non-decreasing) across the message stream
		// — a wrong CSR-induced (ACT-CAP) sync timestamp would break that.
		// (--tsmono in decode_and_check.sh enforces this.)
		// trTsControl.Type/Prescale/Width are swwel-gated by trTeControl.Enable
		// (only writable while Enable=0), so configure the TS unit FIRST.
		// Single write (Active|Count|Type=SYSTEM|Prescale=0|Enable|Width=63):
		//   Active[0]=1, Count[1]=1, Type[6:4]=2, Enable[15]=1, Width[29:24]=63
		env.csr.Write_te_trTsControl (32'h3F00_8023);   // timestamps ON, SYSTEM
		env.csr.Set_te_trTeControl_Enable          (1'b1);
		env.csr.Set_te_trTeControl_InstTracing     (1'b1);
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.csr.Set_te_trTeControl_Active          (1'b1);
		env.wait_cycles(20);
		$display("[combined_tb] %0t: starting scenario", $time);

		// ============================================================
		// Mixed workload: linear + data + branch + CF_SYNC + call/ret.
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));

		env.cpu.run(8);                                          // 0x1000, 0x1004 linear
		env.cpu.load_data (.addr(BUF_W), .size(DSIZE_W));        // word  load  @0x1008
		env.cpu.store_data(.addr(BUF_D), .size(DSIZE_D),
		                   .data(64'hDEAD_BEEF_BAAD_F00D));       // dword store @0x100c

		env.cpu.branch_taken(.target(BRANCH));                   // @0x1010 -> 0x1100
		env.cpu.run(8);                                          // 0x1100, 0x1104

		// CSR-CAP initiated instruction synchronization, mid-stream.
		env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC),
		                    .sink(SINK_NEXUS),
		                    .direct_data(24'h0));                // csrw 0xB10 @0x1108

		env.cpu.load_data (.addr(BUF_H), .size(DSIZE_H));        // halfword load @0x110c
		env.cpu.call_to(.target(FUNC));                          // @0x1110 -> 0x2000
		env.cpu.run(8);                                          // 0x2000, 0x2004
		env.cpu.store_data(.addr(BUF_B), .size(DSIZE_B),
		                   .data(64'h0000_0000_0000_0055));       // byte store @0x2008
		env.cpu.ret();                                           // @0x200c -> ret addr
		env.cpu.run(8);                                          // tail linear
		// A final CF_SYNC flushes the trailing linear run into a real
		// ProgTraceSync message, so the offline NexRv decode sees the
		// whole functional scenario instead of an undrained tail.
		env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC),
		                    .sink(SINK_NEXUS),
		                    .direct_data(24'h0));

		env.cpu.exit_trace();

		// ---- Trace-off ----
		// Disabling instruction tracing emits a Program Trace Correlation
		// Message (EVCODE=Program Trace Disabled) that flushes the residual
		// ICNT/HIST so the whole PC stream is emitted for the offline decode.
		// Enable=0 then only flushes queued trace data; atb_force_flush pushes
		// the last ATB bytes to the sink. A short drain first lets the trace
		// tail propagate through the pipeline-delayed composer while instruction
		// tracing is still effectively on (the InstTracing gate is on the
		// undelayed control signal).
		env.wait_cycles(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.wait_cycles(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		if (env.cpu.event_count() == 0)
			$error("[combined_tb] cpu_model event log empty");
		else
			$display("[combined_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[combined_tb] no ATB bytes observed");
		else
			$display("[combined_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[combined_tb] sim done; PC/data/sync gates run from the Makefile");
		$display("[combined_tb] ATB binary trace:");
		$system("realpath combined_tb.atb.bin");
		$finish;
	end

	// Hard timeout
	initial begin
		#15ms;
		$error("[combined_tb] TIMEOUT - test exceeded 15 ms wall time");
		$finish;
	end

endmodule : combined_tb

`default_nettype wire
