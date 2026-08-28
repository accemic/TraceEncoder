// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Byte-quota sync (InstSyncMode=4, TRACE_BYTES): bounded re-anchor
 *           distance measured on the wire (P2 stage 4, plan test 29).
 *
 * @details
 *   The trace-output byte quota is the live-processing promise: with
 *   InstSyncMode = ITR_SYNC_TRACE_BYTES the maximum distance between two
 *   synchronization messages is a PROGRAMMED number of on-wire bytes
 *   (2^(InstSyncMax+4), plus a bounded CDC/anchor slack), independent of
 *   the workload's compressibility. Instruction-count sync (mode 6) is
 *   only a proxy: a compressible code region emits far fewer bytes per
 *   instruction than a jump-dense one, so the byte distance between
 *   mode-6 anchors varies wildly. This test drives exactly that
 *   adversarial shape -- ALTERNATING compressibility -- against the byte
 *   quota:
 *
 *     - phase L (compressible): a long linear run (50 retires) emits
 *       almost nothing (ICNT accumulation only);
 *     - phase J (incompressible): a storm of 20 uninferable jumps (JI),
 *       each forcing an IndirectBranchHist message with a full UADDR
 *       (~5-7 B on the wire), with a 2-retire linear stint at each
 *       target so every PC keeps a single per-PC type for PCInfo.
 *
 *   Six L/J phase pairs. Configuration (programmed BEFORE Enable --
 *   the sync fields are swwel-locked while Enable=1):
 *     InstSyncMode = 4 (ITR_SYNC_TRACE_BYTES)
 *     InstSyncMax  = 2  -> quota window 2^(2+4) = 64 B
 *
 *   The egress byte counter (ct_L2_mseo_mdo_formatter, packer_wr, step
 *   ATB_BEAT_BYTES=4) crosses its held overflow level into tip_clk
 *   (vector_cdc2 pair in ct_L23_preproc_sync); the periodic arm emits
 *   SYNC=2 (PERIODIC, D4) and SyncCntClr rearms the counter through the
 *   reverse crossing.
 *
 *   Verification (Makefile / cli_syncquota_test.sh):
 *     - scripts/decode_and_check.sh --pc --sync 7 : PC-lossless decode
 *       AND at least 7 synchronization messages. Derivation of N=7
 *       (workload, not empirical): each of the 6 JI storms emits >= 20
 *       IndirectBranchHist messages x >= 4 B = 80 B > the 64-B quota
 *       window, so EVERY J phase forces >= 1 quota sync; plus the
 *       startup sync = 7 guaranteed. Measured 2026-08-04 (raw-byte
 *       scale): 1100 raw ATB bytes (133 messages, 335 idle/pad bytes),
 *       12 sync messages (startup + 11 periodic), max consecutive
 *       distance 96 B. A dead quota (the pre-P2 state: counters hard 0)
 *       yields exactly 1 sync and fails hard.
 *     - scripts/check_sync_window.py : frames the RAW ATB dump
 *       (MDO/MSEO), extracts the raw byte offset of every
 *       synchronization message and HARD-checks max consecutive
 *       distance <= 2^(Max+4) + Delta, with the Delta derivation
 *       documented in the script (D2/D7). Raw bytes are the scale the
 *       quota is defined on (whole output beats incl. alignment pad and
 *       flush idle); the NexRv -full log must NOT be used as the byte
 *       scale -- it collapses a run of idle bytes into ONE echo line
 *       (proof in the script header). Prints the measured maximum (the
 *       number that goes into the docs; 2026-08-04 run: 96 B against
 *       the 64+324=388 B bound).
 *
 *   Deterministic (behavioural cpu_model; no netlist X-init). Instruction
 *   trace ON (BRANCH_HIST mode), data OFF, timestamps at reset default.
 */

module sync_quota_bytes_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("sync_quota_bytes_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("sync_quota_bytes_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("sync_quota_bytes_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("sync_quota_bytes_tb.expected.pcs")
	) env ();

	// Byte quota: window = 2^(2+4) = 64 B of accepted ATB output.
	localparam logic [3:0] ITR_SYNC_TRACE_BYTES = 4'd4;
	localparam logic [3:0] INST_SYNC_MAX        = 4'd2;

	localparam logic [31:0] BASE_PC = 32'h0000_1000;
	localparam logic [31:0] JI_BASE = 32'h0004_0000;
	localparam int          N_PHASE = 6;   // L/J phase pairs
	localparam int          N_JI    = 20;  // JI storm length per phase

	initial begin
		$display("[sync_quota_bytes_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[sync_quota_bytes_tb] %0t: reset released", $time);

		// Sync fields are write-locked while Enable=1: program before enabling.
		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_TRACE_BYTES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[sync_quota_bytes_tb] %0t: driving %0d L/J phase pairs (JI storm len %0d)",
			$time, N_PHASE, N_JI);

		env.cpu.enter(.start_pc(BASE_PC));
		for (int ph = 0; ph < N_PHASE; ph++) begin
			// -- phase L: compressible -- one long linear run, near-zero
			//    trace bytes (ICNT accumulation only).
			env.cpu.run(200);                                   // 50 L retires
			// -- phase J: incompressible -- JI storm; every jump emits an
			//    IndirectBranchHist with a full UADDR. Fresh target PCs per
			//    phase/jump keep every PC single-typed for PCInfo.
			for (int j = 0; j < N_JI; j++) begin
				env.cpu.uninferable_jump(
					.target(JI_BASE + 32'h1000 * ph + 32'h40 * j));
				env.cpu.run(8);                                 // 2 L retires
			end
		end

		// CF-quiet linear tail so trace-off lands on a non-CF instruction.
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

		// ---- Liveness checks (the real gate is decode_and_check.sh + window) ----
		if (env.cpu.event_count() == 0)
			$error("[sync_quota_bytes_tb] cpu_model event log empty");
		else
			$display("[sync_quota_bytes_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[sync_quota_bytes_tb] no ATB bytes observed");
		else
			$display("[sync_quota_bytes_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[sync_quota_bytes_tb] PASS (sim); decode + window verified offline");
		$display("[sync_quota_bytes_tb] ATB binary trace:");
		$system("realpath sync_quota_bytes_tb.atb.bin");
		$display("[sync_quota_bytes_tb] NexRv PCInfo:");
		$system("realpath sync_quota_bytes_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[sync_quota_bytes_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : sync_quota_bytes_tb

`default_nettype wire
