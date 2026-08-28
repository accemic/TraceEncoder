// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  E-Trace branch-prediction leg (cli_etrace_test.sh bp).
 *
 * @details
 *   An 80-iteration self-loop with a highly predictable taken branch:
 *   the first map fill (31 bits, containing the 1-2 initial mispredicts)
 *   still goes out as Format 1; the second fill is all-correct and
 *   switches the encoder to COUNT mode (no packet); the loop exit
 *   (not-taken = mispredict) closes the run as Format 0.0 without
 *   address. +BP sets trTeInstFeatures.InstEnBranchPrediction; the cli
 *   leg runs OFF and ON from one build: both lossless, ON smaller,
 *   >= 1 F0.0 packet.
 */

module etrace_bp_tb;

	import cpu_model_pkg::*;
	import tip_pkg::*;   // ILLEGAL_INSTR (coverage phase)

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("etrace_bp_tb.atb.bin"),
		.NEXRV_INFO_PATH     ("etrace_bp_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("etrace_bp_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		if ($test$plusargs("BP")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
			$display("[etrace_bp_tb] branch-prediction ON");
		end
		if ($test$plusargs("JTC")) begin
			// coverage: BP COUNT interrupted by an updiscon INSTALLS the
			// jump target (te_inst_gen PuBpVal arm) -- only reachable with
			// both features on.
			env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache(1'b1);
			$display("[etrace_bp_tb] jump-target-cache ON");
		end
		else begin
			$display("[etrace_bp_tb] branch-prediction OFF (baseline)");
		end

		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(32'h0000_1000));
		// loop body: 0x1000..0x1008 L, 0x100c BD (taken -> 0x1000)
		for (int i = 0; i < 80; i++) begin
			env.cpu.run(12);                              // 0x1000..0x1008
			env.cpu.branch_taken(.target(32'h0000_1000)); // @0x100c
		end
		env.cpu.run(12);                                  // final pass body
		env.cpu.branch_not_taken();                       // @0x100c exit (mispredict)
		env.cpu.run(16);                                  // 0x1010..0x101c
		// Coverage phase (+BPX, coverage_etrace.sh only): exercise the
		// F0.0-with-address arms -- an updiscon and a trap interrupting an
		// active COUNT run (PuBpVal deferral / desc_flush_v COUNT arm).
		if ($test$plusargs("BPX")) begin
			// re-enter COUNT at a fresh branch PC (2 map windows)
			for (int i = 0; i < 70; i++) begin
				env.cpu.run(12);
				env.cpu.branch_taken(
					.target(i == 69 ? 32'h0000_2200 : 32'h0000_2000));
			end
			env.cpu.uninferable_jump(.target(32'h0000_6000)); // F0.0 addr via Pu
			env.cpu.run(16);
			for (int i = 0; i < 70; i++) begin
				env.cpu.run(12);
				env.cpu.branch_taken(
					.target(i == 69 ? 32'h0000_6200 : 32'h0000_6100));
			end
			env.cpu.exception_trap(.cause(ILLEGAL_INSTR),
			                       .handler(32'h0000_7000)); // flush F0.0 addr
			env.cpu.run(16);
			env.cpu.mret();
			env.cpu.run(16);
		end
		env.cpu.idle(50);

		env.cpu.exit_trace();
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.cpu.idle(400);

		$display("[etrace_bp_tb] done");
		$finish;
	end

endmodule

`default_nettype wire
