// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Reproducer: branch prediction combined with half-word periodic sync.
 *
 * @details
 *   Found on hardware: with InstEnBranchPrediction=1 and
 *   InstSyncMode=HALFWORDS the decode aborts WITHOUT any overflow:
 *
 *     ERROR: VendorBP (TCODE 56) walk ended after 1 of 2 branches
 *            (hit an indirect control transfer at PC ...).
 *
 *   Working hypothesis: a branch retire in the same beat as the periodic sync
 *   emission is attributed differently on the two sides -- the encoder counts
 *   it AFTER the PredCnt reset, into the post-sync window, while the decoder
 *   already resolves it inside the sync's ICNT walk.
 *
 *   Setup: a dense, branch-heavy jalr ring with no storm and no stall, so
 *   there is no overflow and the leg isolates the sync boundary. The
 *   iteration length is COPRIME to the sync period (2^10 half-words at
 *   SYNC_MAX=6) so that the period boundary walks through every offset in the
 *   ring across the run and the branch-retire / sync-beat coincidence is hit
 *   reliably.
 *
 *   Gates: scripts/cli_bphws_test.sh
 *     H0  >=1 periodic sync in the stream -> the axis was active at all
 *     H1  >=1 VendorBP (TCODE 56)         -> the BP path was active
 *     H2  NexRv "Decoded OK"              -> the actual guard. The defect is
 *                                            fixed; this leg is the standing
 *                                            regression guard for it.
 */
module bp_hwsync_tb #(parameter logic [3:0] SYNC_MODE = 4'd3,  // ITR_SYNC_HALFWORDS
					  parameter logic [3:0] SYNC_MAX  = 4'd6); // 2^(6+4) half-words

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (5),
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("bp_hwsync_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("bp_hwsync_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("bp_hwsync_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("bp_hwsync_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC      = 32'h0000_7000;
	localparam int unsigned RING_TARGETS = 14;
	localparam logic [31:0] RING_BASE    = 32'h0020_0000;
	localparam logic [31:0] RING_STRIDE  = 32'h400;
	// 40 periods of 1024 half-words each = about 20k instructions of ring traffic.
	localparam int unsigned RING_LAPS    = 3000;
	// Periodic asynchronous IRQs, mirroring the hardware IRQ generator. The
	// cadence is measured in laps and coprime to both the ring length and the
	// sync period, so the IRQ beats walk through every phase relative to the
	// half-word period boundary. The handler lives in its OWN region and has a
	// fixed shape (one instruction + mret), keeping one role per address.
	localparam int unsigned IRQ_EVERY    = 89;
	localparam logic [31:0] ISR_PC       = 32'h0002_8000;

	initial begin
		$display("[bp_hwsync_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (SYNC_MODE);
		env.csr.Set_te_trTeControl_InstSyncMax  (SYNC_MAX);
		// Single factor: ONLY branch prediction on (no JTC, IR, RH or RB).
		env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
		$display("[bp_hwsync_tb] InstEnBranchPrediction=1, SyncMode=%0d Max=%0d",
		         SYNC_MODE, SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);
		env.cpu.uninferable_jump(.target(RING_BASE + RING_STRIDE));

		// Ring: each lap is one block plus two branches (a taken/not-taken
		// pattern) plus a jalr to the next target. The lap length in
		// half-words is not a divisor of 2^10, so the sync boundary walks
		// through every ring offset.
		for (int i = 0; i < RING_LAPS; i++) begin
			logic [31:0] here = RING_BASE + 32'((i % RING_TARGETS) + 1) * RING_STRIDE;
			logic [31:0] nxt  = RING_BASE + 32'(((i + 1) % RING_TARGETS) + 1) * RING_STRIDE;
			if ((i % IRQ_EVERY) == (IRQ_EVERY - 1)) begin
				// Asynchronous: the ring target address does NOT retire here;
				// after the mret it runs normally (pattern from
				// 02_interrupts).
				env.cpu.interrupt(.cause(11), .handler(ISR_PC), .async(1));
				env.cpu.run(4);                               // ISR body (1 instruction)
				env.cpu.mret();                               // ISR_PC+4 -> resume
			end
			env.cpu.run(8);                                   // 2 instructions of block body
			// A data-dependent pattern that still gives each address exactly
			// ONE role: the branch at here+8 is sometimes taken (skipping one
			// instruction) and sometimes not taken -- which is what trains and
			// then measures the predictor.
			if (((i >> 2) ^ i) & 1)
				env.cpu.branch_taken(.target(here + 32'h10)); // skips here+0xc
			else begin
				env.cpu.branch_not_taken();
				env.cpu.run(4);                               // here+0xc (L)
			end
			env.cpu.run(4);                                   // here+0x10 (L)
			env.cpu.branch_not_taken();                       // here+0x14, second branch
			// Last lap: the ring's own jalr is the exit into the calm region
			// (the pattern from 03). A separate escape jump would give a ring
			// or block address a second role.
			env.cpu.uninferable_jump(.target((i == RING_LAPS - 1)
			                                 ? 32'h0030_0000 : nxt)); // here+0x18 jalr
		end

		// Closing calm phase in its OWN region (rule inherited from 03).
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

		if (env.cpu.event_count() == 0) $error("[bp_hwsync_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[bp_hwsync_tb] no ATB bytes observed");
		$display("[bp_hwsync_tb] PASS (sim); decode gates in scripts/cli_bphws_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[bp_hwsync_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule
