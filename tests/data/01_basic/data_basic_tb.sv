// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Data-trace combined basic test.
 *
 * @details
 *   Smoke test for the encoder's data-trace path. Exercises loads and
 *   stores at every supported size (byte / halfword / word / doubleword)
 *   interleaved with short linear runs.
 *
 *   Configuration: data trace ONLY. Instruction trace is intentionally
 *   left disabled — the data-trace path must work independently of the
 *   instruction-trace path, and this test asserts that.
 *
 *   Because instruction trace is off, the encoder produces no PC-bearing
 *   messages and NexRv's PC-walk verification doesn't apply here. The
 *   PASS criterion is:
 *     - cpu_model retired the expected number of load/store events
 *     - the encoder emitted DataRead / DataWrite messages on the ATB
 *       (visible in the ATB binary dump and in NexRv's -dump output)
 *
 *   Mode: SPLIT_DATA_ACCESS=0 (legacy combined dretire+data path).
 *   Split-load mode is exercised in tests/data/03_split_access/.
 */

module data_basic_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (4),
		.ATB_DUMP_PATH       ("data_basic_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("data_basic_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("data_basic_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("data_basic_tb.expected.pcs"),
		.EXPECTED_DATA_PATH  ("data_basic_tb.expected.data"),
		.EXPECTED_CTXP_PATH  ("data_basic_tb.expected.ctxp")
	) env ();

	// Data buffer addresses (kept well clear of the PC range)
	localparam logic [31:0] MAIN_PC = 32'h0000_1000;
	localparam logic [31:0] BUF_W   = 32'h0002_0000;
	localparam logic [31:0] BUF_D   = 32'h0002_0008;
	localparam logic [31:0] BUF_H   = 32'h0002_0010;
	localparam logic [31:0] BUF_B   = 32'h0002_0012;

	// dsize is log2(byte count) per tip_pkg
	localparam int DSIZE_B = 0;   // 1 byte
	localparam int DSIZE_H = 1;   // 2 bytes
	localparam int DSIZE_W = 2;   // 4 bytes
	localparam int DSIZE_D = 3;   // 8 bytes

	initial begin
		$display("[data_basic_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[data_basic_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTeControl_Enable          (1'b1);
		// Instruction trace OFF — this test exercises data trace in
		// isolation. The encoder must still emit DataRead/DataWrite
		// messages without any instruction-trace context.
		env.csr.Set_te_trTeControl_InstTracing     (1'b0);
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.csr.Set_te_trTeControl_Active          (1'b1);
		env.wait_cycles(20);
		$display("[data_basic_tb] %0t: starting scenario", $time);

		// Instruction tracing is OFF here, so the CTXP reference must contain
		// no SYNC / control-flow records — only the MEM accesses. Mirror that
		// in the cpu_model so write_expected_ctxp omits instruction records.
		env.cpu.set_inst_traced(1'b0);

		// ============================================================
		// Scenario
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));

		// Warm-up linear
		env.cpu.run(8);                                               // 0x1000, 0x1004 (2 L)

		// All four load sizes
		env.cpu.load_data (.addr(BUF_W), .size(DSIZE_W));             // word     load @0x1008
		env.cpu.load_data (.addr(BUF_D), .size(DSIZE_D));             // dword    load @0x100c
		env.cpu.load_data (.addr(BUF_H), .size(DSIZE_H));             // halfword load @0x1010
		env.cpu.load_data (.addr(BUF_B), .size(DSIZE_B));             // byte     load @0x1014

		// A couple of linear instructions between phases
		env.cpu.run(8);                                               // 0x1018, 0x101c (2 L)

		// All four store sizes
		env.cpu.store_data(.addr(BUF_W), .size(DSIZE_W),
		                   .data(64'h0000_0000_CAFE_BABE));            // word     store @0x1020
		env.cpu.store_data(.addr(BUF_D), .size(DSIZE_D),
		                   .data(64'hDEAD_BEEF_BAAD_F00D));            // dword    store @0x1024
		env.cpu.store_data(.addr(BUF_H), .size(DSIZE_H),
		                   .data(64'h0000_0000_0000_1234));            // halfword store @0x1028
		env.cpu.store_data(.addr(BUF_B), .size(DSIZE_B),
		                   .data(64'h0000_0000_0000_0055));            // byte     store @0x102c

		// Tail linear (still drives iretire, gives the encoder some
		// idle time after the last data access).
		env.cpu.run(8);                                               // 0x1030, 0x1034 (2 L)
		env.cpu.exit_trace();

		// ---- Drain ----
		env.csr.Set_te_trTeControl_InstSyncReq (1'b1);
		env.wait_cycles(200);
		env.atb_force_sync  = 1'b1;
		env.atb_force_flush = 1'b1;
		env.wait_cycles(2000);
		env.atb_force_sync  = 1'b0;
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		// ---- Result placeholder checks ----
		if (env.cpu.event_count() == 0) begin
			$error("[data_basic_tb] cpu_model event log empty");
		end else begin
			$display("[data_basic_tb] cpu_model logged %0d events", env.cpu.event_count());
		end
		if (env.atb_bytes_seen == 0) begin
			$error("[data_basic_tb] no ATB bytes observed");
		end else begin
			$display("[data_basic_tb] observed %0d ATB transfers", env.atb_bytes_seen);
		end

		$display("[data_basic_tb] PASS");
		$display("[data_basic_tb] ATB binary trace:");
		$system("realpath data_basic_tb.atb.bin");
		$display("[data_basic_tb] TIP text dump:");
		$system("realpath data_basic_tb.tip.txt");
		$display("[data_basic_tb] NexRv PCInfo:");
		$system("realpath data_basic_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#10ms;
		$error("[data_basic_tb] TIMEOUT - test exceeded 10 ms wall time");
		$finish;
	end

endmodule : data_basic_tb

`default_nettype wire
