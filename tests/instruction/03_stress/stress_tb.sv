// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Instruction-trace stress test: HIST-overflow ICNT under-count
 *           across a scheduler-style dispatch loop (regression gate).
 *
 * @details
 *   Reproduces, deterministically and minimally, the encoder bug that
 *   makes the absint / roberts workloads undecodable: on a branch-history
 *   (HIST) overflow the encoder zeroes its instruction-count accumulator
 *   (CurrICnt), assuming the decoder re-walks the flushed span via the
 *   HIST bits. That holds only if every retired instruction in the span
 *   carries a HIST bit. It does NOT for inferable/linear instructions, so
 *   their half-words are dropped and the next ICNT-bearing message is
 *   severely under-counted.
 *
 *   The scenario mirrors absint's `scheduler_run` dispatch loop, which is
 *   what this bug actually trips on in the field:
 *     (a) HEAD: a march of conditional branches that builds and overflows
 *         HIST (ResourceFull RCODE=1), with periodic sync running.
 *     (b) an INDIRECT dispatch (uninferable jump, jalr-like) into a task.
 *     (c) TASK: a long run of non-HIST-covered linear instructions whose
 *         half-words are dropped by the CurrICnt reset -> SEVERE under-count.
 *     (d) a DIRECT (taken-conditional) loop-back. This is the crucial
 *         ingredient: a direct branch is followed inline by the decoder
 *         WITHOUT re-anchoring (no IndirectBranchHistory), so when the
 *         decoder tries to recover the under-counted ICNT and walks
 *         forward, it crosses the loop-back into the NEXT iteration and
 *         runs into that iteration's indirect dispatch -> unrecoverable.
 *
 *   With the canonical decoder this fails as:
 *       "ICNT adjust: <small> -> <large>"            (recovery attempt)
 *       "ERROR: indirect address encountered in ICNT" (walk hits the jalr)
 *   exactly as observed on hardware and in the EMSA5-netlist integration
 *   sim for absint (`scheduler_run`, PC 0xa1040808). An earlier all-direct
 *   or indirect-loop-back variant did NOT reproduce it: the decoder's
 *   ICNT-adjust heuristic recovers those; only the direct-loop-back +
 *   indirect-dispatch + dropped-linear-span combination defeats it.
 *
 *   FIXED: the encoder no longer zeroes CurrICnt on a HIST_OVERFLOW — ICNT
 *   keeps accumulating across the flush and the next history-bearing message
 *   reports the full span, while the decoder subtracts the half-words it walks
 *   while resolving the flushed HIST (matching the reference encoder
 *   NexRvEnco). See the HIST_OVERFLOW paths in rtl/ct_L2_msg_gen.sv. This test
 *   is the passing regression gate for that fix.
 *
 *   Verification: scripts/decode_and_check.sh --pc (HARD).
 *   Deterministic (behavioural cpu_model; no netlist X-init). Instruction
 *   trace ON (BRANCH_HIST mode), data OFF.
 */

module stress_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("stress_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("stress_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("stress_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("stress_tb.expected.pcs")
	) env ();

	// Periodic instruction-sync (count half-words). InstSyncMax=4 -> a long
	// 2^(4+4)=256-half-word window, so a HIST overflow inside the task body
	// leaves the next ICNT-bearing message severely under-counted (mirrors
	// absint's InstSyncMax=8 long windows; a short window would only produce a
	// mild under-count that the decoder's ICNT-adjust heuristic recovers).
	localparam logic [3:0] ITR_SYNC_HALFWORDS = 4'd3;
	localparam logic [3:0] INST_SYNC_MAX      = 4'd4;

	localparam logic [31:0] MAIN_PC  = 32'h0000_1000;   // loop top
	localparam logic [31:0] TASK_PC  = 32'h0000_8000;   // indirect dispatch target
	localparam int          M_DIRECT = 40;              // head branches per iter (> ~29 HIST period)
	localparam int          K        = 6;               // iterations (fails in the first)

	logic [31:0] pc;

	initial begin
		$display("[stress_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[stress_tb] %0t: reset released", $time);

		// Sync fields are write-locked while Enable=1: program before enabling.
		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_HALFWORDS);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[stress_tb] %0t: starting %0d scheduler-loop iterations", $time, K);

		// ============================================================
		// scheduler_run-shaped loop: HIST-overflowing head, indirect
		// dispatch, long linear task body, DIRECT loop-back.
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));
		for (int k = 0; k < K; k++) begin
			// (a) head: conditional branches build + overflow HIST.
			pc = MAIN_PC;
			for (int j = 0; j < M_DIRECT; j++) begin
				env.cpu.branch_not_taken(.target(pc + 32'd64));
				pc = pc + 32'd4;
			end

			// (b) INDIRECT dispatch (jalr-like) into the task.
			env.cpu.uninferable_jump(.target(TASK_PC));

			// (c) task body: long non-HIST-covered linear run -> its half-words
			//     are dropped on the CurrICnt reset -> severe under-count.
			env.cpu.run(600);

			// (d) DIRECT loop-back (conditional). Followed inline by the decoder
			//     (no IBH / no re-anchor), so a forward recovery walk crosses
			//     into the next iteration's indirect dispatch. It is the SAME
			//     branch site every iteration, so it has ONE static target
			//     (MAIN_PC): iterations loop back by TAKING it; the final
			//     iteration drains by NOT taking it (falling through to the
			//     CF-quiet tail below). A taken branch to a *different* target
			//     here would be unrepresentable for a direct branch — the
			//     decoder resolves the static target from the program image.
			if (k < K - 1)
				env.cpu.branch_taken(.target(MAIN_PC));
			else
				env.cpu.branch_not_taken(.target(MAIN_PC));   // drain: fall through
		end

		// CF-quiet linear tail so trace-off lands after a non-control-flow instr.
		env.cpu.run(8);
		env.cpu.exit_trace();

		// ---- Trace-off drain (flush residual ICNT/HIST, push last ATB bytes). ----
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(20000);

		// ---- Liveness checks (the real gate is decode_and_check.sh) ----
		if (env.cpu.event_count() == 0)
			$error("[stress_tb] cpu_model event log empty");
		else
			$display("[stress_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[stress_tb] no ATB bytes observed");
		else
			$display("[stress_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[stress_tb] PASS (sim); decode verified by scripts/decode_and_check.sh");
		$display("[stress_tb] ATB binary trace:");
		$system("realpath stress_tb.atb.bin");
		$display("[stress_tb] NexRv PCInfo:");
		$system("realpath stress_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[stress_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : stress_tb

`default_nettype wire
