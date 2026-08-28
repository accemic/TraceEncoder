// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  E-Trace jump-target-cache leg (cli_etrace_test.sh jtc).
 *
 * @details
 *   A fixed dispatcher round executed three times (every PC keeps one
 *   instruction kind across rounds): main -> JI A -> JI back -> JI B ->
 *   JI back -> JI loop-top. Round 1 installs the five jump targets
 *   (reported by address), rounds 2..3 hit the 64-entry cache and go out
 *   as Format 0.1 (6-bit index instead of the differential address).
 *   +JTC sets trTeInstFeatures.InstEnJumpTargetCache; the cli leg runs
 *   OFF and ON from one build: both lossless, ON smaller, >= 2 F0.1.
 */

module etrace_jtc_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("etrace_jtc_tb.atb.bin"),
		.NEXRV_INFO_PATH     ("etrace_jtc_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("etrace_jtc_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		if ($test$plusargs("JTC")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache(1'b1);
			$display("[etrace_jtc_tb] jump-target-cache ON");
		end
		else begin
			$display("[etrace_jtc_tb] jump-target-cache OFF (baseline)");
		end

		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(32'h0000_1000));
		// One dispatcher round (identical PCs every round):
		//   0x1000..0x100c L    | 0x1010 JI -> 0x9000
		//   0x9000..0x300c L    | 0x3010 JI -> 0x1014
		//   0x1014..0x1020 L    | 0x1024 JI -> 0xB000
		//   0xB000..0x380c L    | 0x3810 JI -> 0x1028
		//   0x1028..0x1034 L    | 0x1038 JI -> 0x1000 (loop)
		for (int r = 0; r < 3; r++) begin
			env.cpu.run(16);                                   // 0x1000..0x100c
			env.cpu.uninferable_jump(.target(32'h0000_9000));  // @0x1010
			env.cpu.run(16);                                   // 0x9000..0x300c
			env.cpu.uninferable_jump(.target(32'h0000_1014));  // @0x3010
			env.cpu.run(16);                                   // 0x1014..0x1020
			env.cpu.uninferable_jump(.target(32'h0000_B000));  // @0x1024
			env.cpu.run(16);                                   // 0xB000..0x380c
			env.cpu.uninferable_jump(.target(32'h0000_1028));  // @0x3810
			env.cpu.run(16);                                   // 0x1028..0x1034
			if (r < 2)
				env.cpu.uninferable_jump(.target(32'h0000_1000)); // @0x1038 loop
			else
				env.cpu.uninferable_jump(.target(32'h0000_5000)); // @0x1038 exit
		end
		env.cpu.run(16);                                       // 0x5000..0x500c
		// Coverage phase (+JTCX): revisit a cached jump target with a
		// PENDING branch bit -- the F0.1-vs-F1 size decision then runs its
		// with-map arms (f01_bytes/flush_bytes brcnt != 0).
		if ($test$plusargs("JTCX")) begin
			for (int r = 0; r < 2; r++) begin
				env.cpu.run(8);
				env.cpu.branch_taken(.target(32'h0000_5100));
				env.cpu.run(8);
				env.cpu.uninferable_jump(.target(32'h0000_9000)); // cached
				env.cpu.run(16);
				env.cpu.uninferable_jump(.target(32'h0000_5010));
			end
		end
		env.cpu.idle(50);

		env.cpu.exit_trace();
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.cpu.idle(400);

		$display("[etrace_jtc_tb] done");
		$finish;
	end

endmodule

`default_nettype wire
