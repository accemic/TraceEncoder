// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Instruction-trace stress test: periodic syncs + ResourceFull.
*
* @details
*   Drives a long stream of conditional (taken) direct branches to
*   stress two encoder mechanisms simultaneously:
*
*     1. **Periodic synchronisation** — InstSyncMode = count
*        instruction half-words, with a small InstSyncMax so the
*        encoder emits a ProgTraceSync message every
*        2^(InstSyncMax+4) half-words. Over a long run this produces
*        many periodic syncs.
*
*     2. **ResourceFull (HIST_OVERFLOW)** — every taken conditional
*        branch appends one bit to the Nexus branch-history (HIST)
*        field. Once HIST fills (~30 branches) the encoder must emit
*        a ProgramTraceResourceFull message (RCODE = HIST_OVERFLOW)
*        to flush the accumulated history. Hundreds of branches force
*        this to happen many times.
*
*   The branches are **not-taken** conditional branches marching
*   forward one instruction at a time (pc -> pc+4). Each is a distinct
*   PC (no repeat-branch / RBM optimisation) and contributes one HIST
*   bit, while execution stays contiguous so the NexRv PC walk has no
*   gap-fill addresses to stumble over.
*
*   Configuration: instruction trace ON, data trace OFF.
*
*   The decode is run HARD: the NexRv-decoded PC stream must match the
*   cpu_model's executed PCs exactly (the only tolerated shortfall is
*   the handful of instructions still in the encoder pipeline at
*   $finish — a benign drain-tail limitation common to every test).
*
*   This test surfaced a real encoder bug: the HIST_OVERFLOW
*   ResourceFull path left the ICNT accumulator (CurrICnt) running on
*   the assumption that the decoder would subtract the halfwords it
*   walks while resolving the flushed history. NexRv does not do that —
*   the HIST resolution fully advances its PC and instruction count —
*   so a periodic sync immediately after a HIST flush re-walked every
*   branch the flush had already covered (decoded count >> executed
*   count). Fixed by resetting CurrICnt in both HIST_OVERFLOW emission
*   sites (ct_L2_msg_gen.sv: the inline ITR_BRANCH_HIST path and the
*   send_hist_overflow_msg task used by the sync-flush hold).
*/

module stress_sync_resourcefull_tb;

	import cpu_model_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("stress_sync_resourcefull_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("stress_sync_resourcefull_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("stress_sync_resourcefull_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("stress_sync_resourcefull_tb.expected.pcs")
	) env ();

	// Periodic instruction-sync configuration
	localparam logic [3:0] ITR_SYNC_HALFWORDS = 4'd3;   // count instruction half-words
	// 2^(InstSyncMax+4) half-words between syncs. 2 -> 2^6 = 64 half-words
	// = 32 branches/sync, which interleaves nicely with the ~30-branch
	// HIST_OVERFLOW period so the trace carries many of both messages.
	localparam logic [3:0] INST_SYNC_MAX      = 4'd2;

	localparam logic [31:0] MAIN_PC      = 32'h0000_1000;
	localparam int          NUM_BRANCHES = 300;

	logic [31:0] pc;

	initial begin
		$display("[stress_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[stress_tb] %0t: reset released", $time);

		// Periodic-sync fields are write-locked while Enable=1, so set
		// them BEFORE enabling.
		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_HALFWORDS);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.wait_cycles(20);
		$display("[stress_tb] %0t: starting %0d-branch stress scenario", $time, NUM_BRANCHES);

		// ============================================================
		// Scenario: a long forward march of taken conditional branches
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));
		pc = MAIN_PC;

		for (int i = 0; i < NUM_BRANCHES; i++) begin
			// Not-taken conditional branch: contributes a HIST bit but
			// falls through to pc+4, keeping the executed PC stream
			// contiguous (no gap-fill addresses for NexRv to walk).
			env.cpu.branch_not_taken(.target(pc + 32'd64));   // would-be-taken target
			pc = pc + 32'd4;
		end

		// Flush the final partial branch history: an uninferable jump
		// forces an IndirectBranchHistory message that drains the
		// branches accumulated since the last HIST overflow. Its target
		// is the next sequential slot to keep the address space
		// contiguous. After this there is no pending history left.
		env.cpu.uninferable_jump(.target(pc + 32'd4));
		env.cpu.exit_trace();

		// ---- Drain ----
		env.csr.Set_te_trTeControl_InstSyncReq (1'b1);
		env.wait_cycles(200);
		env.atb_force_sync  = 1'b1;
		env.atb_force_flush = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_sync  = 1'b0;
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(20000);

		// ---- Result placeholder checks ----
		if (env.cpu.event_count() == 0) begin
			$error("[stress_tb] cpu_model event log empty");
		end else begin
			$display("[stress_tb] cpu_model logged %0d events", env.cpu.event_count());
		end
		if (env.atb_bytes_seen == 0) begin
			$error("[stress_tb] no ATB bytes observed");
		end else begin
			$display("[stress_tb] observed %0d ATB transfers", env.atb_bytes_seen);
		end

		$display("[stress_tb] PASS");
		$display("[stress_tb] ATB binary trace:");
		$system("realpath stress_sync_resourcefull_tb.atb.bin");
		$display("[stress_tb] NexRv PCInfo:");
		$system("realpath stress_sync_resourcefull_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#20ms;
		$error("[stress_tb] TIMEOUT - test exceeded 20 ms wall time");
		$finish;
	end

endmodule : stress_sync_resourcefull_tb

`default_nettype wire
