// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Sync-carried branch combined with branch prediction: forces the
 *           collision behind the sync-boundary defect family.
 *
 * @details
 *   Fingerprint taken from a hardware-versus-replay message diff: the
 *   hardware emits its periodic syncs as IBHS (TCODE 29) with HIST=2, meaning
 *   the sync lands on a BRANCH retire whose outcome rides along as a
 *   sync-carried one-bit HIST seed. The replay simulation, with its own phase
 *   alignment, only ever hit non-branches (TCODE 9, no HIST). Exactly the
 *   colliding runs lose two half-words per VendorBP at the next ICNT carrier
 *   ("ICNT adjust: 40 to -6").
 *
 *   This leg FORCES the collision: a four-instruction loop (three-instruction
 *   body plus a back-edge branch) under a 16-instruction sync period, which
 *   is a multiple of the loop length. All four phase alignments are run
 *   (prologue of 0..3 instructions), so in at least one cell the periodic
 *   sync deterministically lands on the branch retire. Branch prediction is
 *   the single factor turned on: the trained back edge gives silent laps and
 *   the exit mispredict produces a TCODE 56.
 *
 *   Gates: scripts/cli_bpsyncbr_test.sh
 *     B0  >=1 IBHS/DBS carrying HIST (a sync-carried branch) -> collision hit
 *     B1  >=1 VendorBP (TCODE 56)                            -> BP path active
 *     B2  NexRv "Decoded OK" (-bp)                           -> the regression guard
 */
module bp_syncbranch_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (5),
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("bp_syncbranch_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("bp_syncbranch_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("bp_syncbranch_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("bp_syncbranch_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC   = 32'h0000_7000;
	localparam logic [31:0] CELL_BASE = 32'h0010_0000;
	localparam logic [31:0] CALM_PC   = 32'h0030_0000;
	localparam int unsigned LAPS      = 24;   // enough sync periods per cell

	initial begin
		$display("[bp_syncbranch_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (4'd6);   // count instructions
		env.csr.Set_te_trTeControl_InstSyncMax  (4'd0);   // 2^4 = 16
		env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
		// The ingredient that reproduces the hardware fingerprint: with IBHS
		// enabled the sync-carried branch seed bit turns the sync into an
		// IBHS (TCODE 29) message with HIST instead of a DBS (TCODE 11).
		env.csr.Set_te_trTeInstFeatures_InstEnIbhs             (1'b1);
		$display("[bp_syncbranch_tb] BP on, sync every 16 instructions; 4-instruction loop, phase sweep 0..3");
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);

		// Four cells with prologue length = phase 0..3: in exactly one phase
		// the periodic 16-instruction sync lands on the back-edge branch
		// retire.
		for (int ph = 0; ph < 4; ph++) begin
			logic [31:0] cell_pc = CELL_BASE + 32'(ph) * 32'h400;
			env.cpu.uninferable_jump(.target(cell_pc));
			if (ph > 0) env.cpu.run(4 * ph);                 // prologue (phase)
			// Loop shape copied from the BSS-clear loop in the hardware
			// workload's crt0: a not-taken conditional branch at the head, a
			// two-instruction body, and a DIRECT jal back. A sync landing on
			// the not-taken branch cannot be sent as DBS (TCODE 11), so it
			// becomes IBHS (TCODE 29) with HIST seed 0b10 -- exactly the
			// hardware fingerprint.
			for (int lap = 0; lap < LAPS; lap++) begin
				if (lap != LAPS - 1) begin
					// Testbench pitfall: branch_not_taken() WITHOUT a target
					// writes cur_pc+8 as the BD target into the pcinfo, which
					// silently collides with the real exit target of the same
					// address. Rule: ONE target per branch address, always
					// stated explicitly.
					env.cpu.branch_not_taken(.target(cell_pc + 32'(ph) * 4 + 32'h10)); // head: bgeu, not taken
					env.cpu.run(8);                          // body, 2 linear
					env.cpu.jump_to(.target(cell_pc + 32'(ph) * 4)); // jal back
				end
				else begin
					env.cpu.branch_taken(.target(cell_pc + 32'(ph) * 4 + 32'h10)); // exit (mispredict)
				end
			end
			env.cpu.run(8);                                  // cell run-out
		end

		env.cpu.uninferable_jump(.target(CALM_PC));
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

		if (env.cpu.event_count() == 0) $error("[bp_syncbranch_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[bp_syncbranch_tb] no ATB bytes observed");
		$display("[bp_syncbranch_tb] PASS (sim); decode gates in scripts/cli_bpsyncbr_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[bp_syncbranch_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule
