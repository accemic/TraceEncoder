// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    RepeatBranch compression test (Phase 2c, TCODE 30).
 *
 * @details
 *   Exercises the RepeatBranch compression: with
 *   trTeInstFeatures.InstEnRepeatBranch set, an IndirectBranchHistory that is
 *   identical to the LAST EMITTED one (same HIST, same ICNT, same target) is
 *   suppressed and counted; the run is closed by a RepeatBranch message
 *   (TCODE 30) carrying the suppression count. NexRv replays its saved
 *   previous message count times (no decoder change needed).
 *
 *   Scenario: a tight dispatch-style loop whose only control flow is an
 *   UNINFERABLE jump back to the loop head -- every iteration produces a
 *   byte-identical IBH (empty HIST, ICNT=6 halfwords, same target). This is
 *   the interpreter/vtable-dispatch pattern. The final iteration jumps to a
 *   coda instead (same jump PC, different runtime target -- legal for an
 *   indirect jump), which mismatches and forces the drain-then-emit path.
 *
 *   Periodic sync uses the long 2048-cycle period; each sync drains the
 *   pending count (drain-before-any-emission rule) and invalidates the
 *   remembered IBH, so every sync window restarts with one full IBH.
 *
 *   Run twice from the same binary:
 *     - default (no plusarg)  -> RepeatBranch OFF (IBH per iteration)
 *     - +REPEAT_BRANCH        -> RepeatBranch ON  (1 IBH + TCODE30 per window)
 *   The decoded PC prefix must be IDENTICAL OFF vs ON (lossless), and ON must
 *   produce a much smaller ATB.
 */

module repeat_branch_tb;

	import cpu_model_pkg::*;

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd7;   // 1<<(7+4) = 2048-cycle periodic sync
	localparam int         N_ITERS             = 600;

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("repeat_branch_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("repeat_branch_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("repeat_branch_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("repeat_branch_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		if ($test$plusargs("RB_TIGHT")) begin
			// Coverage leg with periodic syncs OFF: a sync between two laps
			// invalidates LastIbh*, so the identical-IBH match
			// (repeat_branch_match in the RETURN arm) would never fire.
			// IMPORTANT: write this BEFORE Enable -- SyncMode is not writable
			// while Enable=1, and an override afterwards has no effect.
			env.csr.Set_te_trTeControl_InstSyncMode (4'd0);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch(1'b1);
			$display("[rb_tb] %0t: RB_TIGHT leg (syncs off, RepeatBranch ON)", $time);
		end
		if ($test$plusargs("RB_ALIAS")) begin
			// S-7 guard leg: RepeatBranch ON with the normal periodic sync --
			// the discriminating collapse happens inside the alias block
			// itself (drained by the bridge's target mismatch), and the
			// periodic syncs keep the dispatch-loop tail decodable (with
			// syncs off the WHOLE loop rides in the end drain, which this
			// TB loses to host ATB truncation).
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch(1'b1);
			$display("[rb_tb] %0t: RB_ALIAS leg (periodic syncs on, RepeatBranch ON)", $time);
		end
		// BEFORE Enable, for the same reason the RB_TIGHT leg above already
		// states for SyncMode: trTeInstFeatures is swwel-gated too (U10 F-1).
		if ($test$plusargs("REPEAT_BRANCH")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch(1'b1);
			$display("[rb_tb] %0t: InstEnRepeatBranch=1 (RepeatBranch ON)", $time);
		end else begin
			$display("[rb_tb] %0t: RepeatBranch OFF (baseline)", $time);
		end
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);

		env.wait_cycles(20);

		// ---- Scenario --------------------------------------------------
		// +RB_ALIAS runs FIRST (its own entry block, then a bridge into the
		// dispatch loop): the leg's discriminating messages must not sit in
		// the drain tail, which this TB loses to host ATB truncation.
		//
		// S-7 regression guard (P10 soak, seed 1317011359 run 930): TWO
		// DIFFERENT indirect jumps with the SAME target, span length and
		// (empty) history. The HEAD message of the would-be repeat run then
		// carries UADDR != 0, and NexRv's verbatim TCODE-30 replay re-applies
		// that delta against the moved reference: the decode walks a stale
		// 0x7000/0x7100 oscillation the CPU never executed. Only
		// byte-identical messages may collapse -- the fixed match
		// (LastIbhReplayable, msg_gen) EMITS the second occurrence (its
		// UADDR is 0) and collapses from the third on, so the leg still
		// produces a TCODE 30 (checked by the runner along with the
		// positional PC compare that goes red on the stale walk).
		if ($test$plusargs("RB_ALIAS")) begin
			env.cpu.enter(.start_pc(32'h0000_6F00));
			env.cpu.run(8);                                   // 0x6f00, 0x6f04
			env.cpu.uninferable_jump(.target(32'h0000_7000)); // 0x6f08
			env.cpu.run(8);                                   // 0x7000, 0x7004
			// Head: 0x7008 -> 0x7100; previous transmitted address is
			// 0x7000, so this message's UADDR != 0.
			env.cpu.uninferable_jump(.target(32'h0000_7100));
			for (int i = 0; i < 8; i++) begin
				env.cpu.run(8);                               // 0x7100, 0x7104
				// Laps: 0x7108 -> 0x7100 -- same target, same 6-halfword
				// span, empty history: identical to the head in everything
				// EXCEPT its wire UADDR.
				env.cpu.uninferable_jump(.target(32'h0000_7100));
			end
			env.cpu.run(8);                                   // final lap body
			// Bridge into the dispatch loop (multi-target indirect jump at
			// 0x7108 -- legal; it closes the repeat run by target mismatch).
			env.cpu.uninferable_jump(.target(32'h0000_1000));
		end
		else begin
			env.cpu.enter(.start_pc(32'h0000_1000));
		end
		// Dispatch loop @ 0x1000 (12-byte body, indirect back edge):
		//   0x1000: L                       (run 4)
		//   0x1004: L                       (run 4)
		//   0x1008: JR -> 0x1000            (uninferable_jump; last iter -> 0x100c)
		for (int i = 0; i < N_ITERS; i++) begin
			env.cpu.run(8);
			if (i < N_ITERS - 1)
				env.cpu.uninferable_jump(.target(32'h0000_1000));
			else
				env.cpu.uninferable_jump(.target(32'h0000_100c)); // coda
		end

		// Coda with a direct branch so trailing HIST state is exercised too.
		env.cpu.run(8);                                  // 0x100c, 0x1010
		env.cpu.branch_not_taken();                      // 0x1014
		env.cpu.run(8);                                  // 0x1018, 0x101c

		// ---- +RB_TIGHT: RETURN repeat @0x6000 --------------------------
		// repeat_branch_match sits in the RETURN arm of msg_gen. The jump
		// loop above goes through the plain-IBH group, which is a separate
		// repeat arm and already covered. Identical call/ret laps -- same
		// source, same target, same ICNT, same history shape -- trigger the
		// RETURN repeat from lap 2 onwards. Implicit return stays OFF.
		if ($test$plusargs("RB_TIGHT")) begin
			env.cpu.uninferable_jump(.target(32'h0000_6000));
			for (int i = 0; i < 12; i++) begin
				env.cpu.run(8);                              // 6000..6008
				env.cpu.call_to(.target(32'h0000_6800));     // 6008
				env.cpu.run(8);                              // 6800..6808
				env.cpu.ret();                               // 6808 -> 600C
				env.cpu.run(8);                              // 600C..6014
				if (i < 11)
					env.cpu.branch_taken(.target(32'h0000_6000)); // 6014
				else
					env.cpu.branch_not_taken();
			end
			env.cpu.run(8);
		end

		env.cpu.exit_trace();

		// ---- End drain (mirrors 07_repeated_history) -------------------
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
			$error("[rb_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)
			$error("[rb_tb] no ATB bytes observed");

		$display("[rb_tb] PASS (scenario driven, %0d events)", env.cpu.event_count());
		$finish;
	end

	// Global timeout
	initial begin
		#400_000_000; // 400 us -- 40 us silently cut the coverage legs short ($finish, rc=0)
		$error("[rb_tb] TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
