// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Data sync (TCODE 13/14): re-anchors at CF syncs and after an
 *           overflow ERROR, with timestamps on.
 *
 * @details
 *   System test for the P3 re-anchor contract T2 in a combined
 *   instruction+data stream with trTeDataAddrCompress = XOR:
 *     (a) every synchronizing CF message re-arms the DF re-anchor -- the
 *         first data message after the mid-stream ACT-CAP CF_SYNC (and
 *         after every periodic sync) must be the 13/14 form;
 *     (c) every emitted ERROR (TCODE 8, QueueOverrun) re-arms it -- the
 *         decoder invalidates its DF XOR reference on ERROR (R8
 *         symmetry), so the first data message after the overflow episode
 *         MUST carry the full address again or every later data address
 *         would be garbage.
 *
 *   Phases (overflow recipe from tests/overflow/01_overrun_recovery):
 *     A: clean baseline -- CF + XOR-compressed data accesses decode
 *        cleanly; mid-stream ACT-CAP CF_SYNC followed by a data access
 *        (the T2(a) probe).
 *     B: ATB stall + JI storm with interleaved data accesses -> the
 *        ovf_injector fires ERROR (QueueOverrun) + SYNC(FIFO_OVERRUN).
 *     C: release stall, drain.
 *     D: post-recovery clean data accesses -- the T2(c) probe: the first
 *        DF after the ERROR must be TCODE 13/14.
 *
 *   Timestamps ON (SYSTEM, prescale 0): 13/14 are synchronizing messages
 *   and carry an ABSOLUTE timestamp (D-P3-5 / N-Trace 8.5); the decoder
 *   re-bases on it. A delta mis-booked as absolute (or vice versa) shows
 *   up as a backwards jump in --tsmono.
 *
 *   Verification (scripts/cli_dfcompress_test.sh):
 *     decode_and_check.sh --soft --pc --data --overflow  (losses are
 *       intended in the storm; --overflow stays HARD)
 *     decode_and_check.sh --tsmono --sync 4              (hard, separate
 *       invocation: --soft must not soften the timestamp gate)
 *     + hard structural checks in the cli script: first DF after every
 *       ERROR is 13/14; decoded data events form an order-preserving
 *       subsequence of the oracle (XOR reconstruction never invents an
 *       address, even across the loss episode).
 */

module data_sync_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("data_sync_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("data_sync_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("data_sync_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("data_sync_tb.expected.pcs"),
		.EXPECTED_DATA_PATH ("data_sync_tb.expected.data")
	) env ();

	// Periodic sync ON (overrun_recovery config): the recovery path needs
	// a sync to re-anchor the PC after the overflow, and every periodic
	// sync doubles as a T2(a) DF re-anchor.
	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd4;

	localparam logic [31:0] PHASE_A_PC = 32'h0000_1000;
	localparam logic [31:0] PHASE_B_PC = 32'h0000_2000;
	localparam logic [31:0] PHASE_D_PC = 32'h0000_3000;

	// Data buffers, well clear of the PC range.
	localparam logic [31:0] BUF_W = 32'h0008_0000;
	localparam logic [31:0] BUF_D = 32'h0008_0008;
	localparam logic [31:0] BUF_H = 32'h0008_0010;
	localparam logic [31:0] BUF_B = 32'h0008_0012;

	localparam int DSIZE_B = 0;
	localparam int DSIZE_H = 1;
	localparam int DSIZE_W = 2;
	localparam int DSIZE_D = 3;

	localparam logic [1:0] MODE_XOR = ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e__DTR_ADDR_XOR;

	localparam logic [5:0] CMD_CF_SYNC = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC;
	localparam logic [1:0] SINK_NEXUS  = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;

	int bytes_after_A;
	int bytes_after_C;
	int bytes_after_D;

	initial begin
		$display("[data_sync_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[data_sync_tb] %0t: reset released", $time);

		// ---- Configure encoder ------------------------------------
		env.csr.clear();
		// Timestamps ON: free-running SYSTEM counter, prescale 0 (see the
		// combined_tb note; trTsControl is swwel-gated by Enable, so first).
		env.csr.Write_te_trTsControl (32'h3F00_8023);
		env.csr.Set_te_trTeControl_InstSyncMode    (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax     (INST_SYNC_MAX);
		env.csr.Set_te_trTeDataControl_DataAddrCompress (MODE_XOR);
		env.csr.Set_te_trTeControl_Enable          (1'b1);
		env.csr.Set_te_trTeControl_InstTracing     (1'b1);
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.csr.Set_te_trTeControl_Active          (1'b1);
		env.cpu.idle(20);

		// ============================================================
		// Phase A: clean baseline + T2(a) probe (CF_SYNC -> 13/14).
		// ============================================================
		$display("[data_sync_tb] %0t: phase A -- clean baseline + CF_SYNC re-anchor", $time);
		env.cpu.enter(.start_pc(PHASE_A_PC));
		env.cpu.run(.n_bytes(32));                                          // 8 L
		env.cpu.load_data (.addr(BUF_W), .size(DSIZE_W));                   // word load  (13/14: stream head)
		env.cpu.store_data(.addr(BUF_D), .size(DSIZE_D),
		                   .data(64'hDEAD_BEEF_BAAD_F00D));                 // dword store (XOR)
		env.cpu.run(.n_bytes(16));                                          // 4 L
		// Mid-stream CF sync via ACT-CAP, then a data access: T2(a) probe.
		env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC),
		                    .sink(SINK_NEXUS),
		                    .direct_data(24'h0));
		env.cpu.load_data (.addr(BUF_H), .size(DSIZE_H));                   // halfword load (13/14 again)
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.idle(500);
		bytes_after_A = env.atb_bytes_seen;
		$display("[data_sync_tb] phase A bytes = %0d", bytes_after_A);
		if (bytes_after_A == 0)
			$error("[data_sync_tb] phase A produced no ATB output");

		// ============================================================
		// Phase B: bridge + ATB stall + JI storm with interleaved data
		// accesses -> ovf_injector fires ERROR + SYNC(FIFO_OVERRUN).
		// (Recipe and pad-address rationale: tests/overflow/01.)
		// ============================================================
		$display("[data_sync_tb] %0t: phase B -- bridge + ATB stall + storm", $time);
		env.cpu.uninferable_jump(.target(PHASE_B_PC));
		env.atb_force_stall = 1'b1;
		env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4000)); // enter pad
		repeat (150) begin
			env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4400));
			env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4000));
		end
		// Interleaved data accesses inside the storm: their DF messages
		// (and/or their XOR references) fall into the drop window. They run
		// on their OWN pad address: NexRv's pcinfo needs exactly one type
		// per PC, and the storm PCs are already typed JI -- retiring a
		// linear load/store at one of them makes cpu_model's nexrv_info
		// writer $error ("conflicting types 'JI' and 'L'").
		env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4800)); // data pad
		env.cpu.store_data(.addr(BUF_W), .size(DSIZE_W), .data(64'h1111));
		env.cpu.load_data (.addr(BUF_D), .size(DSIZE_D));
		env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4000)); // back to storm
		repeat (150) begin
			env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4400));
			env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4000));
		end
		env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_0040)); // leave pad
		env.cpu.branch_taken(.target(PHASE_B_PC + 32'h0000_0080));
		env.cpu.branch_not_taken();
		env.cpu.idle(200);

		// ============================================================
		// Phase C: release stall, let ERROR + recovery sync emit.
		// ============================================================
		$display("[data_sync_tb] %0t: phase C -- release stall, drain", $time);
		env.atb_force_stall = 1'b0;
		env.cpu.idle(15000);
		bytes_after_C = env.atb_bytes_seen;
		$display("[data_sync_tb] phase C bytes = %0d (delta = %0d)",
			bytes_after_C, bytes_after_C - bytes_after_A);

		// ============================================================
		// Phase D: post-recovery data accesses -- T2(c) probe: the first
		// DF after the ERROR must be the 13/14 full-address form.
		// ============================================================
		$display("[data_sync_tb] %0t: phase D -- post-recovery data re-anchor", $time);
		env.cpu.jump_to(.target(PHASE_D_PC));                               // JD
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.load_data (.addr(BUF_W), .size(DSIZE_W));                   // first DF after ERROR
		env.cpu.store_data(.addr(BUF_B), .size(DSIZE_B), .data(64'hA5));
		env.cpu.load_data (.addr(BUF_H), .size(DSIZE_H));
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.idle(500);
		bytes_after_D = env.atb_bytes_seen;
		$display("[data_sync_tb] phase D bytes = %0d (delta = %0d)",
			bytes_after_D, bytes_after_D - bytes_after_C);
		if (bytes_after_D <= bytes_after_C)
			$error("[data_sync_tb] phase D produced no additional ATB output -- encoder did not recover");

		env.cpu.exit_trace();

		// ---- Trace-off drain (combined_tb pattern) ----
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active      (1'b0);
		env.cpu.idle(10000);

		// ---- Liveness checks ----
		if (env.cpu.event_count() == 0)
			$error("[data_sync_tb] cpu_model event log empty");
		else
			$display("[data_sync_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[data_sync_tb] no ATB bytes observed");
		else
			$display("[data_sync_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[data_sync_tb] PASS (sim); decode gates run from cli_dfcompress_test.sh");
		$display("[data_sync_tb] ATB binary trace:");
		$system("realpath data_sync_tb.atb.bin");
		$finish;
	end

	// Hard timeout
	initial begin
		#80ms;
		$error("[data_sync_tb] TIMEOUT - test exceeded 80 ms wall time");
		$finish;
	end

endmodule : data_sync_tb

`default_nettype wire
