// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
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
*   Verification (offline, from the Makefile — one sim, three checks):
*     - scripts/decode_and_check.sh       : decoded PC stream matches the
*                                           cpu_model's executed PCs.
*     - scripts/decode_and_check_data.sh  : decoded DataRead/DataWrite
*                                           sequence matches the loads/stores.
*     - scripts/decode_and_check_sync.sh  : >= 2 synchronization messages
*                                           (startup + the CF_SYNC one;
*                                           the final drain adds more).
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

	ctrace_env #(
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
		env.csr.Set_te_trTeControl_Enable          (1'b1);
		env.csr.Set_te_trTeControl_InstTracing     (1'b1);
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.csr.Set_te_trTsControl_Active          (1'b0);   // timestamps OFF
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

		env.cpu.exit_trace();

		// ---- Full drain (sync request + flush) so the whole PC and data
		//      stream is emitted for the offline decode. ----
		env.csr.Set_te_trTeControl_InstSyncReq (1'b1);
		env.wait_cycles(200);
		env.atb_force_sync  = 1'b1;
		env.atb_force_flush = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_sync  = 1'b0;
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
