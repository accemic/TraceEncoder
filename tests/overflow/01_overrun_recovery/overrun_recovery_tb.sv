// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    FIFO-overrun: composability + recovery + soft-reset.
 *
 * @details
 *   Cross-cutting overflow test. Merges the former
 *   tests/overflow/01_run_overflow_reset (the "ATB stall -> ERROR ->
 *   soft-reset -> recover" path) and tests/instruction/05_overrun_recovery
 *   (the "ATB stall -> ERROR + SYNC(FIFO_OVERRUN) -> post-recovery IBH
 *   decodes cleanly" path) into a single end-to-end scenario, with
 *   instruction AND data tracing both ON so the workload exercises every
 *   message family the composer can drop:
 *
 *     phase A: clean baseline                 — instruction CFs + data
 *                                                accesses retire and decode
 *                                                cleanly, establishes the
 *                                                pre-overrun anchor.
 *     phase B: ATB stall + dense CF storm     — back-to-back TAKEN_BRANCH
 *       (with interleaved data accesses)        pairs saturate the
 *                                                composer's next_iaddr +
 *                                                ETIP CDC FIFOs; the
 *                                                ovf_injector fires ERROR
 *                                                (QueueOverrun) + SYNC
 *                                                (FIFO_OVERRUN).
 *     phase C: release stall, NO reset        — drain the queue and let the
 *                                                injected ERROR + SYNC reach
 *                                                the formatter.
 *     phase D: post-recovery hot check        — clean CF activity with one
 *                                                uninferable indirect jump
 *                                                (forces an IBH) and a few
 *                                                data accesses. The IBH's
 *                                                ICNT must land the decoder
 *                                                on the indirect-jump source
 *                                                in the program image; if
 *                                                the composer's FIFO_OVERRUN
 *                                                FADDR or msg_gen's
 *                                                CurrICnt/Hist were off,
 *                                                this IBH desyncs the
 *                                                decoder (the failure mode
 *                                                seen in scenarios_a3 HW
 *                                                captures).
 *     phase E: soft reset + final clean run   — ct_cs_rst toggled to model a
 *                                                CSR shim reset, encoder
 *                                                re-programmed, fresh CF +
 *                                                data activity. Verifies the
 *                                                reset path still works
 *                                                after the encoder has been
 *                                                through an overrun.
 *
 *   Verification: scripts/decode_and_check.sh
 *     --soft       : PC + data divergence is reported but not failed (a
 *                    heavy overrun cascade intentionally loses bytes; we
 *                    can't expect every cpu_model retire to appear in the
 *                    decoded stream).
 *     --pc         : the surviving decoded PC stream is a strict prefix of
 *                    cpu_model's expected.pcs through phase A; phase D's
 *                    post-recovery IBH must NOT desync the decoder
 *                    (the scenarios_a3 fault signature).
 *     --data       : DataRead/DataWrite addresses match cpu_model's
 *                    expected.data where the stream survives.
 *     --overflow   : HARD — the encoder MUST emit a NEXUS_MSG_ERROR with
 *                    ETYPE=QueueOverrun during phase B (otherwise the
 *                    ovf_injector path never fired and the test is
 *                    meaningless). Greps the tee'd sim log because a heavy
 *                    overrun cascade can desync NexRv at the ATB framing
 *                    layer.
 *     --disabled   : the trace-off Program Trace Correlation Message
 *                    (TCODE 33) lands cleanly at the end (encoder is
 *                    healthy on exit).
 */

module overrun_recovery_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("overrun_recovery_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("overrun_recovery_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("overrun_recovery_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("overrun_recovery_tb.expected.pcs"),
		.EXPECTED_DATA_PATH ("overrun_recovery_tb.expected.data")
	) env ();

	// Periodic sync ON, modest window — matches the HW config (sync mode
	// = ITR_SYNC_CLK_CYCLES, max=8 -> 4096-cycle period). Short enough to
	// fire across the test but long enough not to dominate.
	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd4;

	// PC ranges chosen so each phase uses distinct addresses; gap-fill
	// L sentinels in PCInfo between them stay benign.
	localparam logic [31:0] PHASE_A_PC = 32'h0000_1000;
	localparam logic [31:0] PHASE_B_PC = 32'h0000_2000;
	localparam logic [31:0] PHASE_D_PC = 32'h0000_3000;
	localparam logic [31:0] PHASE_E_PC = 32'h0000_4000;
	localparam logic [31:0] PHASE_D_INDIRECT_TARGET = 32'h0000_3200;

	// Data buffers, well clear of the PC range.
	localparam logic [31:0] BUF_W = 32'h0008_0000;
	localparam logic [31:0] BUF_D = 32'h0008_0008;
	localparam logic [31:0] BUF_H = 32'h0008_0010;
	localparam logic [31:0] BUF_B = 32'h0008_0012;

	localparam int DSIZE_B = 0;
	localparam int DSIZE_H = 1;
	localparam int DSIZE_W = 2;
	localparam int DSIZE_D = 3;

	int bytes_after_A;
	int bytes_after_C;
	int bytes_after_D;
	int bytes_after_E;

	initial begin
		$display("[overrun_recovery_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[overrun_recovery_tb] %0t: reset released", $time);

		// ---- Configure encoder ------------------------------------
		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode    (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax     (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable          (1'b1);
		env.csr.Set_te_trTeControl_InstTracing     (1'b1);
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.csr.Set_te_trTeControl_Active          (1'b1);
		env.cpu.idle(20);

		// ============================================================
		// Phase A: clean baseline (CF + data, no stall).
		// ============================================================
		$display("[overrun_recovery_tb] %0t: phase A — clean baseline", $time);
		env.cpu.enter(.start_pc(PHASE_A_PC));
		env.cpu.run(.n_bytes(32));                                          // 8 L
		env.cpu.load_data (.addr(BUF_W), .size(DSIZE_W));                   // word load
		env.cpu.store_data(.addr(BUF_D), .size(DSIZE_D),
		                   .data(64'hDEAD_BEEF_BAAD_F00D));                 // dword store
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.branch_not_taken();                                         // BD fall-through
		env.cpu.load_data (.addr(BUF_H), .size(DSIZE_H));                   // halfword load
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.idle(500);
		bytes_after_A = env.atb_bytes_seen;
		$display("[overrun_recovery_tb] phase A bytes = %0d", bytes_after_A);
		if (bytes_after_A == 0)
			$error("[overrun_recovery_tb] phase A produced no ATB output");

		// ============================================================
		// Phase B: bridge to PHASE_B_PC with a CF event, then ATB stall +
		// CF storm interleaved with data accesses -> ovf_injector fires.
		//
		// We MUST bridge phase A -> phase B with a real iretire-driving CF
		// event (uninferable_jump). cpu_model.enter() updates cur_pc /
		// r_iaddr but drives zero TIP cycles and no iretire pulse — the
		// encoder would see phase A's tail OTHERs then phase B's first
		// TAKEN_BRANCH with NO CF event between them, and the NexRv
		// decoder would walk the gap-fill L4 sentinels between the two
		// regions until the ICNT walk exhausts (~1000 phantom PCs). Phase
		// D bridges its own gap correctly via jump_to(); the
		// uninferable_jump here is the symmetric fix.
		//
		// Order matters: emit the bridge BEFORE asserting ATB stall so
		// the IBH and its next_iaddr capture (at phase B's first retire)
		// flow cleanly through the encoder before the storm starts
		// filling FIFOs.
		// ============================================================
		$display("[overrun_recovery_tb] %0t: phase B — bridge + ATB stall + CF storm", $time);
		env.cpu.uninferable_jump(.target(PHASE_B_PC));
		env.atb_force_stall = 1'b1;
		// Storm events must be INDIRECT jumps: since the composer-side
		// HIST accumulation (compression suite) direct TAKEN branches
		// compact ~32:1 into ResourceFull slots and can no longer
		// saturate the eTIP path (measured: a 2400-branch storm raised
		// only 372 slots, max fill 125/128, zero drops). Every
		// uninferable_jump raises one CF slot PLUS one next_iaddr
		// sideband entry, so the storm saturates the sideband FIFO under
		// ATB backpressure — the QueueOverrun injection path this test
		// exists to exercise. 300 pairs = 600 JI events cover the
		// sideband depth (256) plus consumption with clear margin in
		// every full profile.
		// The storm ping-pongs on a dedicated pad (+0x4000/+0x4400) whose
		// addresses carry ONLY JI pcinfo: reusing PHASE_B_PC (also the
		// drain's branch_taken site) or any phase address would create the
		// L/BD/JI pcinfo conflicts this TB's comments warn about.
		env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4000)); // enter pad
		repeat (300) begin
			env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4400));
			env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_4000));
		end
		env.cpu.uninferable_jump(.target(PHASE_B_PC + 32'h0000_0040)); // leave pad
		// Drain to a fresh PC so phase D's jump_to source is not a BD site
		// (avoids an L/BD/JD pcinfo conflict at PHASE_B_PC).
		env.cpu.branch_taken(.target(PHASE_B_PC + 32'h0000_0080));
		env.cpu.branch_not_taken();   // BD at PHASE_B_PC+0x80, falls through to +0x84
		// Hold stall briefly so the injector definitely fires.
		env.cpu.idle(200);

		// ============================================================
		// Phase C: release stall, let the recovery sync emit, NO reset.
		// ============================================================
		$display("[overrun_recovery_tb] %0t: phase C — release stall, recovery sync emits", $time);
		env.atb_force_stall = 1'b0;
		env.cpu.idle(15000);  // generous drain window so phase D's CFs
		                          // enter a settled (Forwarding) composer.
		                          // A heavy storm (600 CFs + data) takes
		                          // longer to drain than the smaller
		                          // version.
		bytes_after_C = env.atb_bytes_seen;
		$display("[overrun_recovery_tb] phase C bytes = %0d (delta = %0d)",
			bytes_after_C, bytes_after_C - bytes_after_A);

		// ============================================================
		// Phase D: clean post-recovery activity — the hot check.
		//
		// The encoder's state after the FIFO_OVERRUN sync must be
		// consistent enough for an indirect-jump IBH's ICNT to land the
		// decoder on the actual indirect-jump source in the program
		// image. This is the scenarios_a3 HW failure signature.
		// ============================================================
		$display("[overrun_recovery_tb] %0t: phase D — post-recovery clean run (no reset)", $time);
		env.cpu.jump_to(.target(PHASE_D_PC));                               // JD
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.load_data (.addr(BUF_W), .size(DSIZE_W));                   // word load
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.branch_not_taken();                                         // BD fall-through
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.store_data(.addr(BUF_B), .size(DSIZE_B), .data(64'hA5));    // byte store
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.uninferable_jump(.target(PHASE_D_INDIRECT_TARGET));         // JI — the hot check
		env.cpu.run(.n_bytes(32));                                          // 8 L at indirect target

		env.cpu.idle(500);
		bytes_after_D = env.atb_bytes_seen;
		$display("[overrun_recovery_tb] phase D bytes = %0d (delta = %0d)",
			bytes_after_D, bytes_after_D - bytes_after_C);
		if (bytes_after_D <= bytes_after_C)
			$error("[overrun_recovery_tb] phase D produced no additional ATB output — encoder did not recover");

		// ============================================================
		// Phase E: soft reset + final clean run.
		//
		// Toggle ct_cs_rst to model a CSR shim reset (one of the
		// recovery options the SW driver has after an overrun). The
		// encoder configuration is lost across the reset so re-program
		// it, then run a fresh clean workload to confirm the encoder
		// resumes producing trace.
		// ============================================================
		$display("[overrun_recovery_tb] %0t: phase E — soft reset + clean run", $time);
		env.cpu.exit_trace();
		env.cpu.idle(200);

		env.ct_cs_rst = 1'b1;
		env.cpu.idle(20);
		env.ct_cs_rst = 1'b0;
		env.cpu.idle(20);

		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode    (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax     (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable          (1'b1);
		env.csr.Set_te_trTeControl_InstTracing     (1'b1);
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.csr.Set_te_trTeControl_Active          (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(PHASE_E_PC));
		env.cpu.run(.n_bytes(32));                                          // 8 L
		env.cpu.load_data (.addr(BUF_H), .size(DSIZE_H));                   // halfword load
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.branch_taken(.target(PHASE_E_PC + 32'h0000_0100));          // taken branch
		env.cpu.store_data(.addr(BUF_W), .size(DSIZE_W),
		                   .data(64'h1234_5678));                           // word store
		env.cpu.run(.n_bytes(16));                                          // 4 L
		env.cpu.exit_trace();
		env.cpu.idle(500);
		bytes_after_E = env.atb_bytes_seen;
		$display("[overrun_recovery_tb] phase E bytes = %0d (delta = %0d)",
			bytes_after_E, bytes_after_E - bytes_after_D);
		if (bytes_after_E <= bytes_after_D)
			$error("[overrun_recovery_tb] phase E produced no additional ATB output — encoder did not recover from soft reset");

		// ---- Trace-off drain ----
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active      (1'b0);
		env.cpu.idle(5000);

		if (env.cpu.event_count() == 0)
			$error("[overrun_recovery_tb] cpu_model event log empty");
		else
			$display("[overrun_recovery_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[overrun_recovery_tb] no ATB bytes observed");
		else
			$display("[overrun_recovery_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[overrun_recovery_tb] PASS (sim); decode verified by scripts/decode_and_check.sh");
		$display("[overrun_recovery_tb] ATB binary trace:");
		$system("realpath overrun_recovery_tb.atb.bin");
		$display("[overrun_recovery_tb] NexRv PCInfo:");
		$system("realpath overrun_recovery_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#80ms;
		$error("[overrun_recovery_tb] TIMEOUT - test exceeded 80 ms wall time");
		$finish;
	end

endmodule : overrun_recovery_tb

`default_nettype wire
