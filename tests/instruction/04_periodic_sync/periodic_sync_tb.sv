// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Periodic-sync HIST loss: ProgTraceSync must pre-flush pending HIST.
 *
 * @details
 *   Regression gate for the cf_sync_hist_flush_hold path in
 *   rtl/ct_L2_msg_gen.sv (lines 87-99, 165-172). The
 *   NEXUS_MSG_PROGRAM_TRACE_SYNC (TCODE 9, "ProgTraceSync") wire format
 *   carries SYNC reason + ICNT + FADDR only -- there is NO HIST field. So
 *   if a periodic sync emits while the encoder's Hist register holds
 *   pending branch-direction bits, the bare sync-reset path (Hist <= 1,
 *   HistCount <= 1, CurrICnt <= 0 -- in send_cf_msg) would silently drop
 *   those bits. The decoder, walking forward from FADDR with HIST=0, would
 *   take the not-taken path at every conditional branch in the span and
 *   land at the wrong PC; NexRv's ICNT-adjust heuristic would then
 *   underflow ("ICNT adjust: N -> -K, ERROR: ICNT adjustment ERROR").
 *
 *   The encoder avoids this by HOLDING the sync eTIP back one cycle and
 *   emitting a ResourceFull (RCODE=1) HIST-flush first whenever a
 *   non-EXIT_FROM_SYS_RST sync fires in BRANCH_HIST mode with
 *   HistCount > 1. After the flush, Hist is clean; the sync's reset path
 *   then has nothing to drop.
 *
 *   This test drives a self-loop sized to fire the buggy regime, and
 *   relies on decode_and_check.sh --pc to verify the encoder still emits
 *   the pre-flush:
 *     (a) BRANCH_HIST mode with InstSyncMax=1 -> a 32-cycle periodic
 *         window (16 retires at CPI=2), much shorter than the ~30-bit
 *         HIST-overflow period -- syncs always fire with Hist populated
 *         (1..15 pending bits).
 *     (b) loop body = 2 L retires at BODY_PC + 1 BD at BRANCH_PC. 3
 *         retires per iter does NOT divide the 16-cycle sync window
 *         evenly, so periodic syncs land on an L retire, not a BD --
 *         that matters because the encoder defers a sync that lands on
 *         a TAKEN_BRANCH and emits DirectBranchSync (TCODE 11, which
 *         carries HIST natively). Only ProgTraceSync (TCODE 9) exhibits
 *         the bug-trigger pattern, and the only ProgTraceSync path in
 *         BRANCH_HIST mode is one that lands on a linear retire.
 *
 *   Observed message stream on a clean run (every ProgTraceSync preceded
 *   by a ResourceFull RCODE=1 -- this is the pre-flush firing):
 *       ... ResourceFull RCODE=1 (Hist payload)
 *       ... ProgTraceSync SYNC=PERIODIC ICNT=... FADDR=...
 *       ... ResourceFull RCODE=1
 *       ... ProgTraceSync ...
 *   The matching scenarios_a3 / roberts captures from a HW bitfile built
 *   from the trace_fs-vendored encoder snapshot (pre-cf_sync_hist_flush
 *   _hold) exhibit ProgTraceSync without the leading RCODE=1, and decode
 *   fails at the first walked conditional branch.
 *
 *   Verification: scripts/decode_and_check.sh --pc (HARD).
 *   Deterministic (behavioural cpu_model; no netlist X-init). Instruction
 *   trace ON (BRANCH_HIST mode), data OFF.
 */

module periodic_sync_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("periodic_sync_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("periodic_sync_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("periodic_sync_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("periodic_sync_tb.expected.pcs")
	) env ();

	// Periodic instruction-sync (count hart clock cycles). InstSyncMax=1 ->
	// a 2^(1+4)=32-cycle window = 16 retires (CPI=2), well below the ~30-bit
	// HIST overflow threshold, so the sync fires repeatedly with pending
	// HIST bits in the register. This is exactly the regime that triggers
	// the bug on hardware (scenarios_a3 with InstSyncMax=2 -> 64-cycle
	// windows, 32 retires per sync).
	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd1;

	// Loop body shape: 2 linear retires (L) at BODY_PC, BODY_PC+4 -> 1 taken
	// conditional branch (BD) at BRANCH_PC=BODY_PC+8 -> back to BODY_PC.
	// 3 retires per iter is deliberate: it does NOT divide evenly into the
	// 8-retires-per-sync period (CPI=2, InstSyncMax=1 -> 16-cycle window),
	// so periodic syncs fall on an L retire in the body — not on the
	// branch. That matters because the encoder defers a periodic sync that
	// lands on a TAKEN_BRANCH and emits DirectBranchSync (TCODE 11, which
	// DOES carry HIST). The bug we want to trigger is the ProgTraceSync
	// (TCODE 9, no HIST) path: sync on a linear instruction with HIST
	// already populated by prior loop iters' branches.
	// Per-PC types stay single: BODY_PC and BODY_PC+4 are always L,
	// BRANCH_PC always BD; the taken target loops back to BODY_PC; the
	// final-iter NOT_TAKEN drains to BRANCH_PC+4 (a fresh L tail PC).
	localparam logic [31:0] BODY_PC   = 32'h0000_1000;
	localparam logic [31:0] BRANCH_PC = BODY_PC + 32'd8;
	localparam int          N         = 100;   // 100 iters = 300 retires

	initial begin
		$display("[periodic_sync_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[periodic_sync_tb] %0t: reset released", $time);

		// Sync fields are write-locked while Enable=1: program before enabling.
		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.wait_cycles(20);
		$display("[periodic_sync_tb] %0t: driving %0d loop iters (body 0x%08h, branch 0x%08h)",
			$time, N, BODY_PC, BRANCH_PC);

		// ============================================================
		// Two-PC self-loop: BODY_PC (L) -> BRANCH_PC (BD, taken -> BODY_PC).
		// Each iter retires 2 instructions and contributes 1 HIST bit.
		// Periodic sync fires every ~16 retires while HIST holds 0..7
		// pending bits -> exposes the dropped-HIST bug.
		// ============================================================
		env.cpu.enter(.start_pc(BODY_PC));
		for (int i = 0; i < N; i++) begin
			env.cpu.run(.n_bytes(8));                       // 2 L retires at BODY_PC, +4
			if (i < N - 1)
				env.cpu.branch_taken(.target(BODY_PC));     // BD at BRANCH_PC, taken -> BODY_PC
			else
				env.cpu.branch_not_taken();                 // BD at BRANCH_PC, fall through
		end

		// After the loop drains via not-taken, cur_pc lands at BRANCH_PC+4 — a
		// fresh PC range. A CF-quiet linear tail there ensures trace-off lands
		// on a non-control-flow instr.
		env.cpu.run(8);
		env.cpu.exit_trace();

		// ---- Trace-off drain (flush residual ICNT/HIST, push last ATB bytes). ----
		env.wait_cycles(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.wait_cycles(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(20000);

		// ---- Liveness checks (the real gate is decode_and_check.sh) ----
		if (env.cpu.event_count() == 0)
			$error("[periodic_sync_tb] cpu_model event log empty");
		else
			$display("[periodic_sync_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[periodic_sync_tb] no ATB bytes observed");
		else
			$display("[periodic_sync_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[periodic_sync_tb] PASS (sim); decode verified by scripts/decode_and_check.sh");
		$display("[periodic_sync_tb] ATB binary trace:");
		$system("realpath periodic_sync_tb.atb.bin");
		$display("[periodic_sync_tb] NexRv PCInfo:");
		$system("realpath periodic_sync_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[periodic_sync_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : periodic_sync_tb

`default_nettype wire
