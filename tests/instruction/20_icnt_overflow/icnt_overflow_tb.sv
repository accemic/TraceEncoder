// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Test 20 -- ICNT-overflow drain family (coverage gap T1).
 *
 * @details
 *   With the NARROW ICNT cap (trTeInstEnWideIcnt=0, reset default) the Nexus
 *   I-CNT field holds at most 2^8-1 = 255 halfwords. Any straight-line block
 *   longer than that must drain via ResourceFull(RCODE=ICNT_OVERFLOW) before
 *   the closing CF message -- a path NO other test exercises (worklist T1:
 *   `grep icnt_overflow tests/` was empty). One long-block workload, three
 *   CSR legs over the same stimulus shape:
 *
 *     (default) HTM: indirect-hold drains -- HistCount==1 (RCODE=0 ICNT) and
 *               HistCount>1 (RCODE=1 HIST) -- plus the inline inferable-arm
 *               guard (single block > cap) and the predicted-return inline
 *               guard (implicit-return leg section). Ends with a mid-trace
 *               ATB flush + CSR sync request (SyncReqSource ATB / register).
 *     +BTMLEG   BTM (InstMode=3): cf_btm_icnt_overflow_hold before TCODE 3/4,
 *               inline guards of the silent arms (not-taken / inferable),
 *               and an async interrupt -> IndirectBranch BTYPE=INTERRUPT.
 *     +BPLEG    HTM + branch prediction: cf_bp_icnt_drain_hold (ICNT drain
 *               before a TCODE 56 mispredict message).
 *
 *   Pass criterion here: clean run, tt-assertion-free, ATB bytes produced
 *   (rc=0) -- plus, since 2026-08-12, the standing a_i12_* assertions in
 *   ct_L2_msg_gen, which check every emitted instruction count against the
 *   I-CNT cap. Field-VALUE and decode verification runs via
 *   scripts/cli_i20_test.sh (three CSR legs decoded with NexRv, every ICNT /
 *   RCODE=0 RDATA within the 8-bit cap, plus a mutation leg that must go red).
 *
 *   Historical note, because it is the lesson of this test rather than a
 *   footnote: for months this testbench PRODUCED an over-cap ICNT and reported
 *   PASS. Its criterion looked at the run, not at a field value, and the
 *   cli_i20_test.sh it deferred the field check to did not exist. The N-Trace
 *   I-CNT field is MSEO-variable-length, so the over-cap drains decoded
 *   perfectly and no PC or byte gate could see them (measured: RCODE=0 RDATA
 *   256/260 in this test's own artefact). A stimulus without a verdict on the
 *   quantity under test is not a test of it.
 *
 *   Timestamps OFF, drains via env.cpu.idle() (wait_cycles XSIM anomaly).
 */

module icnt_overflow_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("icnt_overflow_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("icnt_overflow_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("icnt_overflow_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("icnt_overflow_tb.expected.pcs")
	) env ();

	// Strictly DISJOINT per-phase address blocks (NexRv pcinfo: one type per
	// PC — run() ranges must never cross a later jump/branch instruction PC).
	localparam logic [31:0] P0_PC   = 32'h0000_9000;
	localparam logic [31:0] P1_PC   = 32'h0000_A000;
	localparam logic [31:0] P2_PC   = 32'h0000_B000;
	localparam logic [31:0] P3_PC   = 32'h0000_C000;
	localparam logic [31:0] P45_PC  = 32'h0000_D000;
	localparam logic [31:0] SUB4_PC = 32'h0000_E000;
	localparam logic [31:0] P68_PC  = 32'h0000_F000;
	localparam logic [31:0] IRQ_PC  = 32'h0001_1000;
	// Narrow Nexus I-CNT cap is 255 halfwords; one cpu_model run() byte is
	// half a halfword, i.e. run(600) = 300 halfwords > cap.
	localparam int OVER_CAP_BYTES  = 600;
	localparam int UNDER_CAP_BYTES = 320;   // 160 halfwords, no overflow alone

	initial begin
		$display("[i20_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		// Periodic sync OFF (SyncMax=0 window would interleave syncs into the
		// long blocks); the drain paths under test are sync-independent.
		env.csr.Set_te_trTeControl_InstSyncMode (4'd0);
		env.csr.Set_te_trTeControl_SendConfig   (2'd0);
		if ($test$plusargs("BTMLEG")) begin
			env.csr.Set_te_trTeControl_InstMode (3'd3);
			$display("[i20_tb] leg: BTM");
		end
		if ($test$plusargs("BPLEG")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			$display("[i20_tb] leg: BP");
		end
		// Implicit return BEFORE enable (quasi-static feature field) — for
		// the predicted-return fold guard in Ph.H (all legs).
		env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn(1'b1);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[i20_tb] %0t: scenario start", $time);

		// Long LINEAR blocks are already drained by the COMPOSER on the tip
		// side (8-bit icnt_cum, forwarded as RCODE=0 through the send_cf_msg
		// short cut). The msg_gen hold and inline arms only fire when
		// CurrICnt accumulates over MANY SILENT CF EVENTS -- not-taken
		// chains, inferable-jump chains, folded returns -- where each event
		// is small but the sum exceeds the cap. Every block below is
		// {run(16); CF} = 20 B = 10 half-words.
		env.cpu.enter(.start_pc(P0_PC));
		// -- Ph.0 @9008: a linear run of more than 255 half-words with no CF.
		// The composer-side icnt_cum drain (tip clock, 8 bit) fires and
		// msg_gen forwards it as a wire RCODE=0 through the send_cf_msg
		// short cut.
		env.cpu.run(600);
		env.cpu.run(8);
		// Drain jump: resets CurrICnt and Hist so the Ph.A accounting -- the
		// cap crossing landing exactly on the closing jump -- stays intact.
		env.cpu.uninferable_jump(.target(P1_PC));

		// -- Ph.A @A000: a chain of 23 not-taken branches (230 half-words,
		// silent) plus a run-out; the closing uninferable_jump crosses the
		// cap at 256 half-words:
		//   HTM -> cf_indirect_hist_overflow_hold with HistCount>1
		//   BTM -> cf_btm_icnt_overflow_hold ahead of the TCODE 4
		for (int i = 0; i < 23; i++) begin
			env.cpu.run(16);
			env.cpu.branch_not_taken();
		end
		env.cpu.run(40);
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(P2_PC));

		// -- Ph.B @B000: a chain of 27 inferable jumps (jump_to is silent).
		// The crossing happens around block 26 and exercises the HTM/BTM
		// inline guard of the inferable arm ((CurrICnt+icnt) > cap, reset
		// inline).
		for (int i = 0; i < 27; i++) begin
			env.cpu.run(16);
			if (i < 26)
				env.cpu.jump_to(.target(P2_PC + 32'h14 * (i + 1)));
			else
				env.cpu.jump_to(.target(P3_PC));
		end

		// -- Ph.C @C000: a chain of 24 jumps (240 half-words plus 10 carried
		// over from Ph.B, with NO branch bits since the last message) and the
		// crossing on the uninferable_jump at 256 half-words:
		//   HTM -> hold with HistCount==1 -> RCODE=0 arm (send_icnt)
		//   BTM -> Hold vor TCODE 4
		for (int i = 0; i < 24; i++) begin
			env.cpu.run(16);
			env.cpu.jump_to(.target(P3_PC + 32'h14 * (i + 1)));
		end
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(P45_PC));

		// -- Ph.D/E/F @D000 (linear): a chain of 26 not-taken branches hits
		// the BTM not-taken inline guard around block 26; then a taken branch
		// and an uninferable jump (HTM: another HistCount>1 hold).
		for (int i = 0; i < 26; i++) begin
			env.cpu.run(16);
			env.cpu.branch_not_taken();
		end
		env.cpu.run(8);
		env.cpu.branch_taken(.target(P45_PC + 32'h300));
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(P68_PC));

		// -- Ph.G @F000 (branch-prediction leg): a chain of 25 not-taken
		// branches trains the predictor to not-taken and stays silent; the
		// mispredicted TAKEN branch then reaches cf_bp_icnt_drain_hold ahead
		// of the TCODE 56.
		for (int i = 0; i < 25; i++) begin
			env.cpu.run(16);
			env.cpu.branch_not_taken();
		end
		env.cpu.run(8);
		env.cpu.branch_taken(.target(P68_PC + 32'h300));

		// -- Ph.H @F300: the predicted-return fold guard (implicit return has
		// been on since setup). A chain of 25 not-taken branches (~250
		// half-words), then call + short body + ret; the predicted, silent
		// return crosses the cap inside the fold arm.
		for (int i = 0; i < 25; i++) begin
			env.cpu.run(16);
			env.cpu.branch_not_taken();
		end
		env.cpu.call_to(.target(SUB4_PC));
		env.cpu.run(8);
		env.cpu.ret();
		env.cpu.run(8);

		// -- Ph.I: (BTM) async interrupt -> IndirectBranch BTYPE=INTERRUPT
		// (msg_gen BTM INTERRUPT arm). Under HTM: the IBH path.
		if ($test$plusargs("BTMLEG")) begin
			env.cpu.interrupt(.cause(11), .handler(IRQ_PC), .async(1));
			env.cpu.run(16);
			env.cpu.mret();
			env.cpu.run(8);
			// EXCEPTION_TRAP -> IndirectBranch BTYPE=EXCEPTION (BTM-Arm)
			env.cpu.exception_trap(.cause(tip_ecause_e'(2)), .handler(IRQ_PC + 32'h100));
			env.cpu.run(16);
			env.cpu.mret();
			env.cpu.run(8);
		end

		// -- Phase 8: sync-request sources while TRACING (SyncReqSource):
		// CSR-requested sync + ATB-flush-requested sync (sync_req_src_atb).
		env.csr.Set_te_trTeControl_InstSyncReq(1'b1);
		env.cpu.run(24);
		env.atb_force_flush = 1'b1;
		env.cpu.run(24);
		env.atb_force_flush = 1'b0;
		env.cpu.run(16);

		env.cpu.exit_trace();

		// ---- Trace-off drain (cpu.idle -- wait_cycles XSIM anomaly) ----
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(2000);

		if (env.cpu.event_count() == 0)
			$error("[i20_tb] cpu_model event log empty");
		else
			$display("[i20_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[i20_tb] no ATB bytes observed");
		else
			$display("[i20_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[i20_tb] PASS (sim); decode verified by scripts/cli_i20_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#60ms;
		$error("[i20_tb] TIMEOUT - test exceeded 60 ms wall time");
		$finish;
	end

endmodule : icnt_overflow_tb

`default_nettype wire
