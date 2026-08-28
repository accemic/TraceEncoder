// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Compression-suite robustness test (feature matrix on one workload).
 *
 * @details
 *   One rich control-flow workload, run under four CSR configurations from
 *   the same binary (runner: scripts/cli_robust_test.sh):
 *     - (none)       compression OFF          -> reference baseline
 *     - +ROBUST_HIST IR+RH+RB+WideICNT+JTC    -> full HIST-family stack
 *     - +ROBUST_BP   IR+BP+WideICNT+JTC       -> full BP-family stack
 *     - +ROBUST_ALL  all six bits             -> deliberate misprogramming:
 *                    BP excludes RH/RB in hardware, so the ATB must be
 *                    BYTE-IDENTICAL to +ROBUST_BP (md5-checked by the runner)
 *   Every decode (NexRv, -bp for the BP-family streams) must reproduce the
 *   same PC prefix as the cpu_model reference. The runner additionally
 *   checks the negative path: a BP stream decoded WITHOUT -bp must fail
 *   hard (TCODE 56 guard).
 *
 *   Workload segments (each stressing a specific robustness corner):
 *     S1 @0x1000/0x2000: call chain of depth 20 -- DEEPER than the
 *        composer's 16-entry return stack. The stack saturates, the deep
 *        pops mispredict in cascade, so with IR enabled every return must
 *        fall back to a full IBH: zero compression, but lossless.
 *     S2 @0x3000: branch-pattern zoo at fixed PCs: (a) all-taken x60,
 *        (b) alternating x25 (RH partial-match / BP worst case),
 *        (c) pseudo-random 32-bit pattern (defeats RH exact+partial match;
 *        mixed BP hit rate).
 *     S3 @0x4000: jump-target-cache collision thrash: T1=0x0001_0000 and
 *        T2=0x0001_4100 share XOR-fold index 4 (delta 0x4100 folds to 0) ->
 *        alternating T1/T2 evicts every time (all misses); then far target
 *        T3=0x0800_0000 x3 and near T4=0x0000_4800 x2 (hits after install).
 *     S4 @0x5000/0x5800: BP predictor ALIASING: branches at 0x5008 and
 *        0x5808 share table index (distance 0x800 = 2^11); their opposite
 *        behaviors (mostly-taken vs never-taken) interfere -> extra
 *        mispredicts, must stay lossless. The identical inner loops also
 *        give RepeatBranch + JTC composition work in the HIST config.
 *     S5 @0x6000: traps INSIDE branch runs: co-reported exception + mret,
 *        async interrupt + mret (BTYPE!=0 IBHs must not touch the JTC
 *        cache; the BP predictor runs across handler code).
 *     S6 @0x8000: 300-instruction linear stretch (ICNT drains: RCODE0
 *        without WideICNT, none with).
 *     S7      : disruption phase: (a) PAUSE via InstTracing=0 with the CPU
 *        RUNNING untraced (falling-edge correlation; both vendor models
 *        clear -- the first post-resume dispatch to the previously-hot T3
 *        MUST be a full IBH again), (b) trace OFF via Enable=0 with the
 *        CPU running (same checks on the second control path), (c) long
 *        CPU stall (~3 sync periods, zero retirement) with trace ON,
 *        (d) ATB flush (afvalid) asserted across live traffic plus an ATB
 *        syncreq burst, (e) fresh-predictor loop after all disruptions.
 *        Transition discipline (found by this test): idle BEFORE each
 *        enable-ish CSR write so in-flight TIP/CDC events drain (else the
 *        last ~3 instructions vanish from the correlation ICNT), idle
 *        AFTER it so Wishbone latency cannot mis-align traced/untraced.
 *        (trTeControl.Active and trCPU0Reset have no datapath in this
 *        tree -- commercial placeholders, documented, not exercisable.)
 *     S8 @0x9000: all-taken tail loop absorbing the host-ATB truncation.
 *
 *   PCInfo discipline (hard-learned): a branch PC driven not-taken ANYWHERE
 *   while taken elsewhere must pass its real would-be target explicitly
 *   (first-observation-wins; the default is cur_pc+8).
 */

module robustness_tb;

	import cpu_model_pkg::*;
	import tip_pkg::*;   // ILLEGAL_INSTR (tip_ecause_e) for exception_trap

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd5;   // 512-cycle periodic sync

	localparam int N_A       = 60;   // S2a all-taken
	localparam int N_B       = 25;   // S2b alternating (odd: exit via even path)
	localparam int N_RND     = 32;   // S2c pseudo-random iterations
	localparam logic [31:0] RND = 32'h37A9_5E3C; // bit31=0: last iter exits long path
	localparam int N_ALIAS   = 12;   // S4 outer rounds
	localparam int N_TRAPLOOP= 10;   // S5 pre-trap branch run
	localparam int N_TAIL    = 120;  // S8 absorber

	localparam int CALL_DEPTH = 20;  // S1: composer return stack holds 16

	// S3 targets: T1/T2 collide in the 6-bit XOR fold (delta 0x4100:
	// (>>2)^( >>8)^(>>14)^(>>20) folds to 0 under the 0x3F mask).
	localparam logic [31:0] T1 = 32'h0001_0000;
	localparam logic [31:0] T2 = 32'h0001_4100;
	localparam logic [31:0] T3 = 32'h0800_0000;
	localparam logic [31:0] T4 = 32'h0000_4800;

	localparam logic [31:0] ISR_EXC = 32'h0000_6100;
	localparam logic [31:0] ISR_IRQ = 32'h0000_6120;

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("robustness_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("robustness_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("robustness_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("robustness_tb.expected.pcs")
	) env ();

	function automatic logic [31:0] fn_addr(input int i);
		return 32'h0000_2000 + 32'(i) * 32'h10;
	endfunction

	// One indirect dispatch bounce: JI @ (current PC) -> block at `tgt`
	// {L, L, JI back to `ret_to`}.
	task automatic dispatch(input logic [31:0] tgt, input logic [31:0] ret_to);
		env.cpu.uninferable_jump(.target(tgt));
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(ret_to));
	endtask

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		// BEFORE Enable: trTeInstFeatures is swwel-gated like the rest of the
		// configuration (U10 F-1) -- a write after arming is silently void.
		if ($test$plusargs("ROBUST_HIST")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory(1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch   (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt       (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache(1'b1);
			$display("[robust_tb] %0t: config HIST (IR+RH+RB+WideICNT+JTC)", $time);
		end
		else if ($test$plusargs("ROBUST_BP")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt       (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache(1'b1);
			$display("[robust_tb] %0t: config BP (IR+BP+WideICNT+JTC)", $time);
		end
		else if ($test$plusargs("ROBUST_ALL")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory(1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch   (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt       (1'b1);
			env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache(1'b1);
			$display("[robust_tb] %0t: config ALL (misprogramming: BP+RH+RB together)", $time);
		end
		else begin
			$display("[robust_tb] %0t: config OFF (baseline)", $time);
		end

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);

		env.wait_cycles(20);

		// ============================================================
		// S1: call chain depth 20 (> 16-entry composer return stack)
		//   main @0x1000: L L, CD @0x1008 -> F0
		//   F_i  @0x2000+i*16: L @+0, CD @+4 -> F_{i+1}; L @+8, R @+12
		//   F19  @0x2130: L L, R @0x2138
		// ============================================================
		env.cpu.enter(.start_pc(32'h0000_1000));
		env.cpu.run(8);
		env.cpu.call_to(.target(fn_addr(0)));
		for (int i = 0; i < CALL_DEPTH - 1; i++) begin
			env.cpu.run(4);
			env.cpu.call_to(.target(fn_addr(i + 1)));
		end
		env.cpu.run(8);
		env.cpu.ret();                       // F19 @+8: R
		for (int i = CALL_DEPTH - 2; i >= 0; i--) begin
			env.cpu.run(4);                  // F_i @+8
			env.cpu.ret();                   // F_i @+12
		end
		env.cpu.run(4);                      // main 0x100c
		env.cpu.jump_to(.target(32'h0000_3000)); // JD @0x1010 (folds)

		// ============================================================
		// S2: branch-pattern zoo
		// ============================================================
		// (a) all-taken x N_A @0x3000 (BD @0x3008)
		for (int i = 0; i < N_A; i++) begin
			env.cpu.run(8);
			if (i < N_A - 1) env.cpu.branch_taken(.target(32'h0000_3000));
			else             env.cpu.branch_not_taken(.target(32'h0000_3000));
		end
		// (b) alternating @0x300c (BD @0x3014 alternates; BD @0x3020 taken)
		for (int i = 0; i < N_B; i++) begin
			env.cpu.run(8);
			if (i[0]) begin
				env.cpu.branch_taken(.target(32'h0000_300c));
			end
			else begin
				env.cpu.branch_not_taken(.target(32'h0000_300c));
				env.cpu.run(8);
				if (i < N_B - 1) env.cpu.branch_taken(.target(32'h0000_300c));
				else             env.cpu.branch_not_taken(.target(32'h0000_300c));
			end
		end
		// (c) pseudo-random pattern @0x3024 (BD @0x302c per RND bit;
		//     BD @0x3038 loops back, last iteration falls through)
		for (int i = 0; i < N_RND; i++) begin
			env.cpu.run(8);
			if (RND[i] && (i < N_RND - 1)) begin
				env.cpu.branch_taken(.target(32'h0000_3024));
			end
			else begin
				env.cpu.branch_not_taken(.target(32'h0000_3024));
				env.cpu.run(8);
				if (i < N_RND - 1) env.cpu.branch_taken(.target(32'h0000_3024));
				else               env.cpu.branch_not_taken(.target(32'h0000_3024));
			end
		end
		env.cpu.jump_to(.target(32'h0000_4000)); // JD @0x303c

		// ============================================================
		// S3: JTC collision thrash + far/near dispatch
		//   kernel @0x4000: L L, JI @0x4008 -> X; X: L L, JI @X+8 -> 0x4000
		// ============================================================
		begin : s3_thrash
			logic [31:0] seq [9];
			seq = '{T1, T2, T1, T2, T3, T3, T3, T4, T4};
			for (int i = 0; i < 9; i++) begin
				env.cpu.run(8);
				dispatch(seq[i], (i < 8) ? 32'h0000_4000 : 32'h0000_400c);
			end
		end
		env.cpu.jump_to(.target(32'h0000_4100)); // JD @0x400c

		// S3b: SELF-dispatch loop @0x4100 -- the ONE shape that produces
		// IDENTICAL back-to-back IBHs (same empty HIST, same ICNT, same
		// target): in the HIST config this exercises RepeatBranch (and,
		// composed with JTC, TCODE 30 replaying a TCODE 57) under the
		// dense-sync robustness regime; in the BP config it is plain
		// JTC-hit traffic.
		//   0x4100: L, 0x4104: L, 0x4108: JI -> 0x4100 (last pass: -> 0x410c)
		for (int i = 0; i < 15; i++) begin
			env.cpu.run(8);
			env.cpu.uninferable_jump(
				.target((i < 14) ? 32'h0000_4100 : 32'h0000_410c));
		end
		env.cpu.jump_to(.target(32'h0000_5000)); // JD @0x410c

		// ============================================================
		// S4: BP alias pair (0x5008 vs 0x5808 share iaddr[10:2]) + RB/JTC
		//   loop1 @0x5000: L L, BD @0x5008 (taken x3, then not) ; JI @0x500c
		//   loop2 @0x5800: L L, BD @0x5808 (never taken)        ; JI @0x580c
		// ============================================================
		for (int r = 0; r < N_ALIAS; r++) begin
			for (int i = 0; i < 3; i++) begin
				env.cpu.run(8);
				env.cpu.branch_taken(.target(32'h0000_5000));
			end
			env.cpu.run(8);
			env.cpu.branch_not_taken(.target(32'h0000_5000));
			env.cpu.uninferable_jump(.target(32'h0000_5800)); // JI @0x500c
			env.cpu.run(8);
			env.cpu.branch_not_taken(.target(32'h0000_5800)); // BD @0x5808, never taken
			if (r < N_ALIAS - 1)
				env.cpu.uninferable_jump(.target(32'h0000_5000)); // JI @0x580c
			else
				env.cpu.uninferable_jump(.target(32'h0000_5810)); // JI @0x580c, exit
		end
		env.cpu.jump_to(.target(32'h0000_6000)); // JD @0x5810

		// ============================================================
		// S5: traps inside branch runs
		// ============================================================
		for (int i = 0; i < N_TRAPLOOP; i++) begin
			env.cpu.run(8);
			if (i < N_TRAPLOOP - 1) env.cpu.branch_taken(.target(32'h0000_6000));
			else                    env.cpu.branch_not_taken(.target(32'h0000_6000));
		end
		// co-reported exception @0x600c -> ISR_EXC, mret resumes @0x6010
		env.cpu.exception_trap(.cause(ILLEGAL_INSTR), .handler(ISR_EXC));
		env.cpu.run(8);                      // ISR_EXC: 0x6100 0x6104
		env.cpu.mret();                      // R't @0x6108
		env.cpu.run(8);                      // 0x6010 0x6014
		// async interrupt @0x6018 (no retire) -> ISR_IRQ, mret re-runs 0x6018
		env.cpu.interrupt(.cause(7), .handler(ISR_IRQ), .async(1));
		env.cpu.run(4);                      // ISR_IRQ: 0x6120
		env.cpu.mret();                      // @0x6124
		env.cpu.run(8);                      // 0x6018 0x601c
		for (int i = 0; i < 6; i++) begin    // post-trap branch run @0x6020
			env.cpu.run(8);
			if (i < 5) env.cpu.branch_taken(.target(32'h0000_6020));
			else       env.cpu.branch_not_taken(.target(32'h0000_6020));
		end
		env.cpu.jump_to(.target(32'h0000_8000)); // JD @0x602c

		// ============================================================
		// S6: 300-instruction linear stretch (ICNT drain behavior)
		// ============================================================
		env.cpu.run(1200);                   // 0x8000 .. 0x84ac

		// ============================================================
		// S7: disruption phase -- session/pipeline robustness
		//   Discipline for every enable-ish transition (BOTH directions,
		//   both found by this very test): idle BEFORE the disable write
		//   so in-flight TRACED events drain (else the last ~3 retired
		//   instructions are dropped from the correlation ICNT), idle
		//   BEFORE the re-enable write so in-flight UNTRACED events drain
		//   (else the TIP/CDC tail is counted into the resume sync's ICNT
		//   and the decoder walks ghost PCs), and idle AFTER each write
		//   for the Wishbone latency.
		// ============================================================

		// --- S7a: PAUSE via InstTracing=0 (Enable stays 1) -----------
		// Distinct control path: inst_trace_active = Enable && InstTracing;
		// the falling edge emits the same trace-off correlation. The CPU
		// keeps RUNNING while paused (untraced -> excluded from the
		// reference via set_inst_traced).
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing(1'b0);
		env.cpu.idle(20);
		env.cpu.set_inst_traced(0);
		env.cpu.run(80);                     // 0x84b0..0x84fc untraced
		env.cpu.idle(50);                    // drain in-flight UNTRACED events
		                                     // while still paused -- else the
		                                     // TIP/CDC tail gets counted into
		                                     // the resume sync's ICNT (found
		                                     // by this test: 3 ghost PCs)
		env.cpu.set_inst_traced(1);
		env.csr.Set_te_trTeControl_InstTracing(1'b1);
		env.cpu.idle(20);
		env.cpu.run(8);                      // 0x8500 0x8504 (resume sync)
		dispatch(T3, 32'h0000_850c);         // JI @0x8508: T3 MUST re-miss
		                                     // (models cleared at pause corr.)

		// --- S7b: trace OFF via Enable=0, CPU keeps running ----------
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.cpu.idle(20);
		env.cpu.set_inst_traced(0);
		env.cpu.run(40);                     // 0x850c..0x8530 untraced
		env.cpu.idle(50);                    // drain untraced in-flight tail
		env.cpu.set_inst_traced(1);
		env.csr.Set_te_trTeControl_Enable(1'b1);
		env.cpu.idle(20);
		env.cpu.run(8);                      // 0x8534 0x8538 (re-enable sync)
		dispatch(T3, 32'h0000_8540);         // JI @0x853c: T3 re-miss again

		// --- S7c: long CPU stall with trace ON -----------------------
		// ~3 periodic-sync periods with zero retirement (sync generation
		// with nothing to attach to; ATB idles).
		env.cpu.idle(1500);
		env.cpu.run(8);                      // 0x8540 0x8544

		// --- S7d: ATB flush + sync requests MID-TRAFFIC --------------
		// afvalid asserted across live traffic (flush messages interleave
		// with real ones), then an ATB syncreq burst (extra syncs).
		env.atb_force_flush = 1'b1;
		env.cpu.run(24);                     // 0x8548..0x855c under flush
		env.atb_force_flush = 1'b0;
		env.cpu.run(8);                      // 0x8560 0x8564
		env.atb_force_sync = 1'b1;
		env.cpu.run(16);                     // 0x8568..0x8574 under syncreq
		env.atb_force_sync = 1'b0;
		env.cpu.jump_to(.target(32'h0000_8600)); // JD @0x8578

		// --- S7e: fresh-predictor loop after all disruptions ---------
		for (int i = 0; i < 20; i++) begin   // all-taken loop @0x8600
			env.cpu.run(8);
			if (i < 19) env.cpu.branch_taken(.target(32'h0000_8600));
			else        env.cpu.branch_not_taken(.target(32'h0000_8600));
		end
		env.cpu.jump_to(.target(32'h0000_9000)); // JD @0x860c

		// ============================================================
		// S8: all-taken tail loop (truncation absorber)
		// ============================================================
		for (int i = 0; i < N_TAIL; i++) begin
			env.cpu.run(8);
			if (i < N_TAIL - 1) env.cpu.branch_taken(.target(32'h0000_9000));
			else                env.cpu.branch_not_taken(.target(32'h0000_9000));
		end
		env.cpu.run(8);

		env.cpu.exit_trace();

		// ---- End drain (mirrors 07..10) --------------------------------
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
			$error("[robust_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)
			$error("[robust_tb] no ATB bytes observed");

		$display("[robust_tb] PASS (scenario driven, %0d events)", env.cpu.event_count());
		$finish;
	end

	// Global timeout
	initial begin
		#60_000_000;
		$display("[robust_tb] TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
