// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Periodic-sync / IBH ICNT-collapse regression test.
*
* @details
*   Reproduces, deterministically, the ICNT-accounting bug that fires
*   when an **indirect** branch lands inside a periodic-sync window
*   immediately after a branch-history (HIST) overflow flush.
*
*   tests/instruction/03_stress_sync_resourcefull already stresses
*   HIST-overflow + periodic sync, but only with DIRECT (conditional)
*   branches. The direct-only case is forgiving: every retired
*   instruction contributes a HIST bit, so the encoder can get away
*   with zeroing the ICNT accumulator on a HIST flush. This test adds
*   the missing ingredient — an uninferable jump (BTYPE=IBRANCH, the
*   IndirectBranchHistory-emitting event) right after the flush — which
*   is NOT HIST-covered, so naive accumulator handling drops its
*   half-words and the decoded ICNT collapses (undercount).
*
*   Scenario: a loop of M conditional (not-taken) branches that drives
*   HIST to overflow, terminated by an uninferable jump back to the
*   loop top. Repeated K times. M is chosen just above the HIST-overflow
*   period (~29 branches) so the overflow flush fires a couple of
*   branches before each jump, and the periodic-sync period is
*   deliberately NOT a multiple of the loop length so the sync phase
*   sweeps across the jump over successive iterations — guaranteeing
*   that at some iteration a periodic sync lands in the
*   [HIST-flush .. uninferable-jump] window. Because the cpu_model and
*   half-word-counted sync are fully behavioural and deterministic, the
*   alignment is bit-exact reproducible (no netlist X-init lottery).
*
*   Verification is the external NexRv decode + address compare wired
*   into the Makefile (scripts/decode_and_check.sh, HARD): the decoded
*   PC stream must match the cpu_model's executed PCs exactly (modulo
*   the benign undrained pipeline tail).
*
*   The bug it caught (now fixed): the EXIT_FROM_SYS_RST sync is
*   attached to the FIRST retired instruction, which here is a
*   conditional branch. The sync path emitted a ProgTraceSync and reset
*   the branch history WITHOUT recording that branch's direction, so:
*     - Loop 0   IndirectBranchHist : ICNT=6, HIST=0x4 (2 bits)  <-- WRONG
*     - Loop 1+  IndirectBranchHist : ICNT=8, HIST=0x8 (3 bits)  <-- correct
*   i.e. the first HIST overflow flushed one extra branch (branch 1's
*   lost bit shifted the count), leaving the following uninferable
*   jump's IndirectBranchHistory short by one instruction — the jump PC
*   collapsed out of the decode and the whole first loop misaligned.
*   (Reproduces with periodic sync on OR off; a periodic sync only
*   shifts where the symptom lands.)
*
*   Fix (two coordinated parts):
*     - ct_L2_msg_gen.sv: when a sync coincides with a conditional
*       branch, SEED the post-sync history with that branch's direction
*       instead of discarding it.
*     - ct_L23_preproc_composer_etip.sv: a not-taken-branch sync takes
*       the EXCLUSIVE ICNT path (keyed on HasChangedControlFlow), so the
*       branch's half-words are counted in the next segment exactly once
*       — matching the seeded history (no double count).
*   The direct-only test 03 cannot distinguish this; this test is the
*   regression gate for it.
*
*   Configuration: instruction trace ON (BRANCH_HIST mode), data OFF.
*/

module sync_indirect_collapse_tb;

	import cpu_model_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("sync_indirect_collapse_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("sync_indirect_collapse_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("sync_indirect_collapse_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("sync_indirect_collapse_tb.expected.pcs")
	) env ();

	// Periodic instruction-sync configuration.
	localparam logic [3:0] ITR_SYNC_HALFWORDS = 4'd3;   // count instruction half-words
	// 2^(InstSyncMax+4) half-words between syncs. With ilastsize=1 the
	// half-word counter advances 1 per instruction, so this is also the
	// sync period in instructions: InstSyncMax=1 -> 32. Loop length is
	// M+1 (=33), deliberately not a multiple of 32, so the sync phase
	// sweeps ~1 instruction per iteration across the loop and eventually
	// falls in the [HIST-flush .. jump] window.
	localparam logic [3:0] INST_SYNC_MAX      = 4'd1;

	localparam logic [31:0] MAIN_PC = 32'h0000_1000;  // = loop top
	localparam int          M       = 32;             // conditional branches per loop (> ~29 HIST period)
	localparam int          K       = 48;             // loop iterations (enough for a full phase sweep)

	logic [31:0] pc;

	initial begin
		$display("[sync_ind_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[sync_ind_tb] %0t: reset released", $time);

		// Sync fields are write-locked while Enable=1: program before enabling.
		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_HALFWORDS);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.wait_cycles(20);
		$display("[sync_ind_tb] %0t: starting %0d x (%0d branches + indirect jump)", $time, K, M);

		// ============================================================
		// Scenario: K loop iterations, each = M not-taken conditional
		// branches (HIST builds + overflows) then an uninferable jump
		// back to the loop top (the indirect / IBH event).
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));

		for (int k = 0; k < K; k++) begin
			pc = MAIN_PC;
			for (int j = 0; j < M; j++) begin
				env.cpu.branch_not_taken(.target(pc + 32'd64));   // HIST bit, falls through
				pc = pc + 32'd4;
			end
			// Indirect branch (BTYPE=IBRANCH) terminates the loop body and
			// emits an IndirectBranchHistory message, flushing the pending
			// HIST plus a full target address. Every iteration but the last
			// jumps back to the loop top; the last jumps to a distinct drain
			// address so the model's final PC is not the loop-top BD slot
			// (which would clash on PCInfo type).
			if (k < K - 1)
				env.cpu.uninferable_jump(.target(MAIN_PC));        // JI @ pc, loop back
			else
				env.cpu.uninferable_jump(.target(32'h0000_2000));  // JI @ pc, drain
		end

		env.cpu.exit_trace();

		// ---- Trace-off (same recipe as test 03) ----
		// Disabling instruction tracing emits a Program Trace Correlation
		// Message (EVCODE=Program Trace Disabled) that flushes the residual
		// ICNT/HIST, so the offline decode resolves the final instructions.
		// Enable=0 then only flushes queued trace data; atb_force_flush
		// pushes the last ATB bytes to the sink.
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.wait_cycles(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(20000);

		// ---- Placeholder liveness checks (the real gate is the NexRv
		//      decode + address compare run from the Makefile) ----
		if (env.cpu.event_count() == 0)
			$error("[sync_ind_tb] cpu_model event log empty");
		else
			$display("[sync_ind_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[sync_ind_tb] no ATB bytes observed");
		else
			$display("[sync_ind_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[sync_ind_tb] PASS (sim); decode verified by scripts/decode_and_check.sh");
		$display("[sync_ind_tb] ATB binary trace:");
		$system("realpath sync_indirect_collapse_tb.atb.bin");
		$display("[sync_ind_tb] NexRv PCInfo:");
		$system("realpath sync_indirect_collapse_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[sync_ind_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : sync_indirect_collapse_tb

`default_nettype wire
