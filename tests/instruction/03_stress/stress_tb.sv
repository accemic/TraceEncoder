// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Instruction-trace stress test: periodic sync + ResourceFull +
*           HIST-overflow / indirect-branch ICNT accounting.
*
* @details
*   Merge of the former 03 (periodic sync + HIST_OVERFLOW with direct
*   branches) and 04 (indirect branch right after a HIST flush) tests
*   into one comprehensive instruction-trace stress scenario that also
*   exercises the control-flow MIX a real workload has — and which the
*   two split tests did NOT: inferable CALLs (ICNT, no HIST bit) and
*   RETURNs (indirect IBH) interleaved with a HIST overflow.
*
*   Each of K iterations drives, with periodic sync running throughout:
*     (a) a march of NOT-taken conditional branches  -> builds + overflows
*         HIST (ResourceFull RCODE=1); with periodic sync this is the old
*         test-03 stress and the test-04 "sync lands in the flush window".
*     (b) an inferable CALL into a per-iteration callee -> contributes
*         ICNT but no HIST bit and no IBH (the ingredient the old tests
*         lacked).
*     (c) a callee body of TAKEN conditional branches  -> another HIST
*         overflow, this time of all-ones history.
*     (d) a RETURN (indirect, IndirectBranchHistory) immediately after the
*         HIST flush -> the half-words since the flush are NOT HIST-covered.
*     (e) an uninferable JUMP back to the loop top (the old test-04
*         indirect-branch-after-flush event).
*
*   Why this triggers the bug: on a HIST_OVERFLOW (RCODE=1) flush the
*   encoder resets the ICNT accumulator (CurrICnt) on the assumption that
*   the decoder re-walks the flushed span while resolving the history.
*   That holds only when every retired instruction in the span carries a
*   HIST bit (the old direct-only tests). Here the inferable call and the
*   straight-line callee instructions are NOT HIST-covered, so zeroing
*   CurrICnt drops their half-words and the following RETURN / JUMP
*   IndirectBranchHistory under-counts -> NexRv stops with
*   "ICNT adjustment ERROR" (or, with a different sync phase,
*   "hist bits pending"). This is the same failure observed on hardware
*   and in the EMSA5-netlist integration sim for the absint / roberts
*   workloads.
*
*   Until the encoder's HIST_OVERFLOW handling is fixed (subtract only the
*   HIST-covered half-words instead of zeroing CurrICnt), this test is
*   EXPECTED TO FAIL the decode/PC-compare gate — it is the regression
*   gate for that fix.
*
*   Verification: scripts/decode_and_check.sh --pc (HARD) — the NexRv
*   decoded PC stream must match the cpu_model's executed PCs exactly.
*
*   Deterministic: the cpu_model and half-word-counted sync are fully
*   behavioural, so the failing alignment is bit-exact reproducible (no
*   netlist X-init lottery). Configuration: instruction trace ON
*   (BRANCH_HIST mode), data OFF.
*/

module stress_tb;

	import cpu_model_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("stress_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("stress_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("stress_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("stress_tb.expected.pcs")
	) env ();

	// Periodic instruction-sync: count instruction half-words, fire often.
	// 2^(InstSyncMax+4) half-words between syncs; InstSyncMax=1 -> ~32, a
	// non-multiple of the loop length so the sync phase sweeps across the
	// HIST-flush / indirect-branch windows over successive iterations.
	localparam logic [3:0] ITR_SYNC_HALFWORDS = 4'd3;
	localparam logic [3:0] INST_SYNC_MAX      = 4'd1;

	localparam logic [31:0] MAIN_PC  = 32'h0000_1000;   // loop top
	localparam int          M_DIRECT = 40;              // not-taken branches per iter (> ~29 HIST period)
	localparam int          M_TAKEN  = 40;              // taken branches in callee  (> ~29 HIST period)
	localparam int          K        = 16;              // iterations

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
		env.wait_cycles(20);
		$display("[stress_tb] %0t: starting %0d iterations", $time, K);

		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));

		for (int k = 0; k < K; k++) begin
			// (a) not-taken march from the loop top -> HIST overflow + the
			//     periodic-sync-in-flush-window stress (old tests 03/04).
			pc = MAIN_PC;
			for (int j = 0; j < M_DIRECT; j++) begin
				env.cpu.branch_not_taken(.target(pc + 32'd64));
				pc = pc + 32'd4;
			end

			// (b) inferable CALL into a per-iteration callee: contributes
			//     ICNT, no HIST bit, no IBH.
			env.cpu.call_to(.target(32'h0000_8000 + (k * 32'h400)));
			pc = 32'h0000_8000 + (k * 32'h400);

			// (c) callee body: TAKEN branches -> a second HIST overflow.
			for (int j = 0; j < M_TAKEN; j++) begin
				env.cpu.branch_taken(.target(pc + 32'd4));
				pc = pc + 32'd4;
			end

			// (d) a couple of straight-line (non-HIST-covered) instructions,
			//     then RETURN: the indirect IBH right after the HIST flush
			//     whose half-words the buggy accumulator drops.
			env.cpu.run(8);
			env.cpu.ret();

			// (e) uninferable JUMP back to the loop top (old test-04 indirect
			//     branch); last iteration jumps to a distinct drain address so
			//     the model's final PC is not the loop-top BD slot.
			if (k < K - 1)
				env.cpu.uninferable_jump(.target(MAIN_PC));
			else
				env.cpu.uninferable_jump(.target(32'h0000_2000));
		end

		// CF-quiet linear tail so trace-off lands after a non-control-flow
		// instruction (see the trace-off recipe below).
		env.cpu.run(8);
		env.cpu.exit_trace();

		// ---- Trace-off drain (flushes residual ICNT/HIST via a Program
		//      Trace Correlation message, then pushes the last ATB bytes). ----
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
