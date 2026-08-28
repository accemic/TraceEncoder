// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Jump-target-cache state across a NATURAL overflow recovery.
 *
 * @details
 *   Regression guard for a defect first seen on hardware: after a
 *   FIFO_OVERRUN recovery the encoder kept referencing JTC entries whose
 *   INSTALL message fell inside the discarded window. The decoder never saw
 *   the entry and aborts with
 *
 *     ERROR: VendorJTC (TCODE 57) references jump-target-cache index N which
 *            is not yet installed.
 *
 *   Why no existing test finds it: 02_natural_overflow produces its overflow
 *   from ALL-FRESH jump targets (base + i*0x40) and runs with the JTC off, so
 *   there are neither installs nor hits. Exactly one factor is turned here,
 *   in two places:
 *     (a) InstEnJumpTargetCache = 1
 *     (b) the storm targets form a RING of RING_TARGETS addresses that keep
 *         repeating -- only then do cache HITS occur, and specifically hits on
 *         entries whose install may lie inside the drop window.
 *   That is the structure of the real workload this was found in (a ring of
 *   jalr hops).
 *
 *   Testbench pitfalls, all four of which produced a decode abort WITHOUT any
 *   overflow and are avoided by the construction below:
 *     (1) Back-to-back jumps with no block body. The passing 09_jtc test puts
 *         real instructions between two indirect jumps; without them the
 *         decoder aborts as soon as the JTC is active.
 *     (2) A calm phase continuing LINEARLY from the last ring target, so the
 *         same address is once a linear instruction and once a jump. The
 *         pcinfo model allows only ONE kind per address, hence "resolved
 *         source PC ... to a non-indirect instruction".
 *     (3) A storm starting with run(8) at the CURRENT PC -- inside the calm
 *         region -- leaving a jump there that a later calm phase walks
 *         through linearly: "indirect address encountered in ICNT".
 *     (4) REUSING a calm region: the storm's leading block (run(8) + jump)
 *         sits at the END of the first calm window. If a later calm phase
 *         returns to the same region and runs FURTHER than the first window
 *         did, it walks linearly through that jump -- again "indirect address
 *         encountered in ICNT".
 *   RULE: **every address keeps exactly one role** (linear instruction OR
 *   jump), and **a calm region that has been left is never re-entered** --
 *   each phase gets its own region (CALM_PC / +0x1_0000 / +0x2_0000).
 *
 *   Note on sizing: with the JTC active the hit messages are so compact that
 *   700 ring jumps do NOT overflow the FIFO (measured: zero error messages),
 *   so STORM_JUMPS has to be considerably larger for gate J1 to engage.
 *
 *   Gates: scripts/cli_jtcovf_test.sh
 *     J0  Control run (CALM_ONLY=1): without an overflow the stream decodes
 *         cleanly. HARD -- if it is red the storm leg proves nothing.
 *     J1  >=1 Nexus error message   -> a natural overflow was actually reached
 *     J2  >=1 VendorJTC (TCODE 57)  -> the cache path was active at all
 *     J3  NexRv "Decoded OK"        -> the actual regression guard: the
 *                                      encoder clears JtcValid and the decoder
 *                                      re-initializes its JTC on the
 *                                      FIFO_OVERRUN recovery sync
 */

// CALM_ONLY=1 runs the CONTROL leg: ring traffic without an overflow. It is a
// top-level parameter rather than a plusarg because this testbench runs via
// `xelab -R` (the separate xsim snapshot load hangs in 2022.1) and xelab does
// not accept plusargs. Invoke as:  xelab ... -generic_top CALM_ONLY=1
module jtc_ovf_tb #(parameter bit         CALM_ONLY = 1'b0,
					parameter logic [3:0] SYNC_MODE = 4'd2, // 2 = clk cycles (as in 09_jtc)
					parameter logic [3:0] SYNC_MAX  = 4'd7);

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (5),      // == tip half period, so the drain cannot outrun the source
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("jtc_ovf_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("jtc_ovf_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("jtc_ovf_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("jtc_ovf_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC      = 32'h0000_7000;
	// 700 was NOT enough: JTC hit messages are compact enough for the FIFO to
	// keep up. 4000 forces the natural overflow with margin.
	localparam int unsigned STORM_JUMPS  = 4000;
	localparam int unsigned RING_TARGETS = 14;     // matches the observed hop ring
	localparam logic [31:0] RING_STRIDE  = 32'h400;
	// Separate addresses for the calm phases. If a calm phase continued
	// linearly from the LAST ring target, the same address would be executed
	// once as a linear instruction and once as an indirect jump. The pcinfo
	// model allows only ONE kind per address, so the decoder reports "resolved
	// source PC ... to a non-indirect instruction" and aborts -- without any
	// overflow having occurred.
	localparam logic [31:0] CALM_PC      = 32'h0030_0000;

	// Ring storm: the same RING_TARGETS targets in a continuous loop, so each
	// is installed on first appearance and hit from then on.
	//
	// IMPORTANT: there MUST be real instructions between two jumps
	// (env.cpu.run). Back-to-back jumps with no block in between -- as in
	// 02_natural_overflow, which runs without the JTC -- make the decoder abort
	// with the JTC active even WITHOUT an overflow ("resolved source PC ... to
	// a non-indirect instruction"). The passing tests/instruction/09_jtc does
	// the same thing: a block of a few instructions, then the indirect jump.
	//
	// `exit_target` is the target of the LAST jump. Jumping out separately
	// afterwards would put a linear instruction and a jump at the address of
	// the first block instruction -- the same trap as with CALM_PC. Here every
	// address keeps EXACTLY ONE role; only the jump target changes, which is
	// entirely normal for an indirect jump (09_jtc does the same in its
	// coda).
	task automatic ring_storm(input logic [31:0] base, input int unsigned n,
	                          input logic [31:0] exit_target);
		for (int i = 0; i < n; i++) begin
			env.cpu.run(8);   // two instructions of block body, then the jump
			if (i == n - 1)
				env.cpu.uninferable_jump(.target(exit_target));
			else
				env.cpu.uninferable_jump(.target(base + 32'((i % RING_TARGETS) + 1) * RING_STRIDE));
		end
	endtask

	initial begin
		$display("[jtc_ovf_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active                    (1'b0);
		// Single-factor knob: periodic sync on or off. The passing
		// tests/instruction/09_jtc runs ITR_SYNC_CLK_CYCLES with Max=7;
		// SYNC_MODE=2 / SYNC_MAX=7 selects the same here.
		if (SYNC_MODE != 0) begin
			env.csr.Set_te_trTeControl_InstSyncMode (SYNC_MODE);
			env.csr.Set_te_trTeControl_InstSyncMax  (SYNC_MAX);
		end
		// (a) The one difference from 02_natural_overflow that carries the finding.
		env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache (1'b1);
		env.csr.Set_te_trTeControl_Enable                    (1'b1);
		env.csr.Set_te_trTeControl_InstTracing               (1'b1);
		env.csr.Set_te_trTeControl_Active                    (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);

		// Quiet warm-up lap: the ring is installed while nothing is being
		// dropped yet, so encoder and decoder are guaranteed to agree here.
		ring_storm(MAIN_PC + 32'h0001_0000, RING_TARGETS, CALM_PC);
		env.cpu.run(400);

		// CONTROL leg: ring traffic WITHOUT an overflow. It MUST decode
		// cleanly -- only then does the storm leg say anything about the
		// recovery (gate J0).
		if (CALM_ONLY) begin
			// Fresh calm region (+0x2_0000) -- see pitfall (4): CALM_PC is never
			// re-entered, the ring's leading-block jump sits at its window end.
			ring_storm(MAIN_PC + 32'h0001_0000, 3 * RING_TARGETS, CALM_PC + 32'h2_0000);
			env.cpu.run(400);
			env.cpu.exit_trace();
			env.cpu.idle(50);
			env.csr.Set_te_trTeControl_InstTracing (1'b0);
			env.cpu.idle(200);
			env.csr.Set_te_trTeControl_Enable      (1'b0);
			env.atb_force_flush = 1'b1;
			env.cpu.idle(4000);
			env.atb_force_flush = 1'b0;
			env.cpu.idle(500);
			env.csr.Set_te_trTeControl_Active(1'b0);
			env.cpu.idle(1000);
			$display("[jtc_ovf_tb] calm control leg finished");
			$finish;
		end

		// Storm 1: a natural overflow IN THE MIDDLE of ring traffic, so installs
		// and hits of the same ring now partly fall into the drop window.
		// Exit into a FRESH calm region (+0x2_0000) -- see pitfall (4): CALM_PC
		// is never re-entered, the storm's leading-block jump sits at its
		// window end.
		ring_storm(MAIN_PC + 32'h0001_0000, STORM_JUMPS, CALM_PC + 32'h2_0000);
		env.cpu.run(1600);      // calm phase: a healthy encoder drains here

		// Storm 2 on a SECOND ring, followed by a clean tail.
		ring_storm(MAIN_PC + 32'h0004_0000, STORM_JUMPS, CALM_PC + 32'h1_0000);
		env.cpu.run(1600);

		env.cpu.exit_trace();
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);

		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(1000);

		if (env.cpu.event_count() == 0) $error("[jtc_ovf_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[jtc_ovf_tb] no ATB bytes observed");
		$display("[jtc_ovf_tb] PASS (sim); decode gates in scripts/cli_jtcovf_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[jtc_ovf_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule
