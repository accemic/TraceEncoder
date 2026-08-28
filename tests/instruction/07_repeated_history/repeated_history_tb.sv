// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Repeated-history compression test (Phase 2).
 *
 * @details
 *   Exercises the repeated-history compression: with
 *   trTeInstFeatures.InstEnRepeatedHistory set, a full HIST pattern that
 *   would emit ResourceFull(RCODE=1) is buffered; identical follow-up
 *   patterns only increment a counter and the run is emitted as ONE
 *   ResourceFull(RCODE=2, rdata0=pattern, rdata1=count). NexRv replays the
 *   pattern rdata1 times (no decoder change needed).
 *
 *   The HIST window is NEXUS_MSG_RDATA_WIDTH-1 = 29 data bits -- a prime.
 *   The MVP detector matches EXACT full patterns only (no NexRvEnco-style
 *   30/28-bit partial trim), so only phase-invariant (uniform) patterns
 *   compress:
 *     - Segment A: tight all-taken counting loop (1 taken bit/iteration)
 *       -> every full pattern is all-ones -> long RCODE=2 runs. This is the
 *       common real-world case (for-loop back edge).
 *     - Segment B: loop with an embedded not-taken branch (2 bits/iteration)
 *       -> patterns phase-drift across the 29-bit window and never match
 *       -> exercises the emit-on-mismatch path (RCODE=1 per pattern, byte
 *       parity with OFF). Documents the exact-match limitation honestly.
 *   A trailing uninferable jump forces a genuine IndirectBranchHist after a
 *   pending repeat run (drain-before-IBH path).
 *
 *   Periodic instruction sync uses a LONG period (2048 tip-clk cycles) so
 *   several full patterns accumulate between syncs (each sync drains the
 *   repeat buffer); the end-of-test force-sync/flush drains the residual.
 *
 *   Run twice from the same binary:
 *     - default (no plusarg)   -> repeated-history OFF (RCODE=1 per pattern)
 *     - +REPEATED_HISTORY      -> repeated-history ON  (runs folded, RCODE=2)
 *   The decoded PC prefix must be IDENTICAL OFF vs ON (lossless), and ON must
 *   produce a strictly smaller ATB.
 */

module repeated_history_tb;

	import cpu_model_pkg::*;

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd7;   // 1<<(7+4) = 2048-cycle periodic sync
	localparam int         N_ITERS_A           = 29 * 35; // all-taken loop: 35 full 29-bit patterns
	localparam int         N_ITERS_B           = 100;     // alternating loop: mismatch path

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("repeated_history_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("repeated_history_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("repeated_history_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("repeated_history_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		if ($test$plusargs("RH_PARTIAL")) begin
			// Conversion leg: periodic syncs OFF (they flush HIST mid-window
			// and re-align the run — the trimmed-match arm never fires), RH ON.
			env.csr.Set_te_trTeControl_InstSyncMode (4'd0);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory(1'b1);
		end
		// BEFORE Enable: trTeInstFeatures is swwel-gated like the rest of the
		// configuration (U10 F-1) -- a write after arming is silently void.
		if ($test$plusargs("REPEATED_HISTORY")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory(1'b1);
			$display("[rh_tb] %0t: InstEnRepeatedHistory=1 (repeated-history ON)", $time);
		end else begin
			$display("[rh_tb] %0t: repeated-history OFF (baseline)", $time);
		end

		if ($test$plusargs("WIDE_ICNT")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt(1'b1);
			$display("[rh_tb] %0t: InstEnWideIcnt=1 (16-bit ICNT cap, fewer RCODE0 drains)", $time);
		end

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);

		env.wait_cycles(20);

		// ---- Scenario --------------------------------------------------
		// Every iteration is byte-identical (same PCs, same instruction
		// kinds) so the program image stays consistent for NexRv's PCInfo
		// walk. A conditional branch PC may be taken in one iteration and
		// not taken in another (same instruction kind).
		//
		// Segment A @ 0x1000 (12-byte body, 1 HIST bit/iter, all taken):
		//   0x1000: L        (run 4)
		//   0x1004: L        (run 4)
		//   0x1008: BD taken -> 0x1000   (last iteration: not taken)
		env.cpu.enter(.start_pc(32'h0000_1000));
		for (int i = 0; i < N_ITERS_A; i++) begin
			env.cpu.run(8);
			if (i < N_ITERS_A - 1)
				env.cpu.branch_taken(.target(32'h0000_1000));
			else
				env.cpu.branch_not_taken();          // fall through to segment B
		end

		// Segment B @ 0x100c (24-byte body, 2 HIST bits/iter: nt, t):
		//   0x100c: L        (run 4)
		//   0x1010: L        (run 4)
		//   0x1014: BD not taken (HIST 0)
		//   0x1018: L        (run 4)
		//   0x101c: L        (run 4)
		//   0x1020: BD taken -> 0x100c   (last iteration: not taken)
		for (int i = 0; i < N_ITERS_B; i++) begin
			env.cpu.run(8);
			env.cpu.branch_not_taken();
			env.cpu.run(8);
			if (i < N_ITERS_B - 1)
				env.cpu.branch_taken(.target(32'h0000_100c));
			else
				env.cpu.branch_not_taken();          // fall through to coda
		end

		// Coda: a genuine uninferable jump right after the loops so a real
		// IndirectBranchHist must drain any pending repeat buffer first.
		env.cpu.run(8);                                  // 0x1024, 0x1028
		env.cpu.uninferable_jump(.target(32'h0000_3000)); // 0x102c
		env.cpu.run(8);                                  // 0x3000, 0x3004

		// ---- +RH_PARTIAL: trimmed-match conversion (coverage leg T1/W) --
		// The periodic-sync-interleaved legs above never hit the CONVERSION
		// arm (hist_partial_match_shift s=1/s=2) under Verilator: syncs
		// flush HIST mid-window and re-align the run. This leg drives clean
		// pattern periods with syncs already idle: whatever the effective
		// window width W_eff is, one of the periods {2,3,5,7} yields a
		// window-to-window drift of 1 resp. 2 (the two implemented shifts);
		// the non-matching periods exercise the changed-pattern emission
		// (send_hist_repeat_msg on mismatch). Same 12/24-byte body
		// discipline as segments A/B (consistent PC image per segment).
		if ($test$plusargs("RH_PARTIAL")) begin
			$display("[rh_tb] %0t: RH_PARTIAL conversion leg", $time);
			// Seg1 @0x4000: warm up a period-1 run (buffer the run, cnt>1);
			// the exiting NT falls CONTIGUOUSLY -- no drain -- into an all-NT
			// chain, so the pattern changes at the next window boundary with
			// cnt != 0, which is the changed-pattern emission
			// (send_hist_repeat).
			for (int i = 0; i < 40; i++) begin
				env.cpu.run(8);
				if (i < 39)
					env.cpu.branch_taken(.target(32'h0000_4000));
				else
					env.cpu.branch_not_taken();          // falls through to 0x400C
			end
			for (int i = 0; i < 30; i++) begin           // all-NT chain (linear)
				env.cpu.run(8);
				env.cpu.branch_not_taken();
			end
			env.cpu.run(8);
			env.cpu.uninferable_jump(.target(32'h0000_4400)); // drain
			// Seg2-5: segment-B shape -- a PC-periodic loop head with the
			// loop-back TAKEN in a fixed slot and the pattern slots ahead of
			// it. Prefix bits before loop entry shift the pattern phase
			// against the window boundaries, which exercises the conversion
			// arm for s=1 and s=2 (the loop-entry case).
			// Seg2 @0x4400: entry T + alternating loop (drift parity A).
			env.cpu.run(8);
			env.cpu.branch_taken(.target(32'h0000_440C)); // entry bit '1'
			for (int i = 0; i < 30; i++) begin
				env.cpu.run(8);
				env.cpu.branch_not_taken();               // 4414
				env.cpu.run(8);
				if (i < 29)
					env.cpu.branch_taken(.target(32'h0000_440C)); // 4420
				else
					env.cpu.branch_not_taken();           // exit, falls through to 4424
			end
			env.cpu.run(8);
			env.cpu.uninferable_jump(.target(32'h0000_4800));
			// Seg3 @0x4800: 1 NT prefix + entry T + alternating (parity B).
			env.cpu.run(8);
			env.cpu.branch_not_taken();
			env.cpu.run(8);
			env.cpu.branch_taken(.target(32'h0000_4818));
			for (int i = 0; i < 30; i++) begin
				env.cpu.run(8);
				env.cpu.branch_not_taken();
				env.cpu.run(8);
				if (i < 29)
					env.cpu.branch_taken(.target(32'h0000_4818));
				else
					env.cpu.branch_not_taken();
			end
			env.cpu.run(8);
			env.cpu.uninferable_jump(.target(32'h0000_4C00));
			// Seg4 @0x4C00: Entry-T + Periode-3-Loop (nt,nt,t).
			env.cpu.run(8);
			env.cpu.branch_taken(.target(32'h0000_4C0C));
			for (int i = 0; i < 24; i++) begin
				env.cpu.run(8);
				env.cpu.branch_not_taken();
				env.cpu.run(8);
				env.cpu.branch_not_taken();
				env.cpu.run(8);
				if (i < 23)
					env.cpu.branch_taken(.target(32'h0000_4C0C));
				else
					env.cpu.branch_not_taken();
			end
			env.cpu.run(8);
			env.cpu.uninferable_jump(.target(32'h0000_5000));
			// Seg5 @0x5000: 1 NT prefix + entry T + period-3 loop.
			env.cpu.run(8);
			env.cpu.branch_not_taken();
			env.cpu.run(8);
			env.cpu.branch_taken(.target(32'h0000_5018));
			for (int i = 0; i < 24; i++) begin
				env.cpu.run(8);
				env.cpu.branch_not_taken();
				env.cpu.run(8);
				env.cpu.branch_not_taken();
				env.cpu.run(8);
				if (i < 23)
					env.cpu.branch_taken(.target(32'h0000_5018));
				else
					env.cpu.branch_not_taken();
			end
			env.cpu.run(8);
			env.cpu.uninferable_jump(.target(32'h0000_5400)); // final drain
			env.cpu.run(8);
		end

		env.cpu.exit_trace();

		// ---- End drain (mirrors 06_implicit_return) --------------------
		// Force sync+flush WHILE TRACE IS STILL ACTIVE so msg_gen's residual
		// (including a pending repeat buffer) is emitted before trace-off.
		env.wait_cycles(50);
		env.atb_force_flush = 1'b1;
		env.atb_force_sync  = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.atb_force_sync  = 1'b0;
		env.wait_cycles(500);

		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(2000);

		if (env.cpu.event_count() == 0)
			$error("[rh_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)
			$error("[rh_tb] no ATB bytes observed");

		$display("[rh_tb] PASS (scenario driven, %0d events)", env.cpu.event_count());
		$finish;
	end

	// Global timeout
	initial begin
		#400_000_000; // 400 us -- 40 us silently cut the coverage legs short ($finish, rc=0)
		$error("[rh_tb] TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
