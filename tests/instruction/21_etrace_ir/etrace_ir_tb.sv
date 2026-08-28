// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  E-Trace implicit-return leg (cli_etrace_test.sh ir).
 *
 * @details
 *   Dedicated scenario for the CT_EN_ETRACE backend's implicit-return mode:
 *   nested calls with stack-predicted returns (folded when the mode is on),
 *   a taken/not-taken branch pair and an uninferable jump around them, and a
 *   CLEAN trace-off ending (exit_trace + Enable=0 -> correlation beat) so the
 *   generator's final flush closes the stream. The existing
 *   06_implicit_return donor ends WITHOUT Enable=0 (it drains via forced
 *   mid-trace syncs, which the E-Trace MVP intentionally drops), so its tail
 *   never reaches the wire there -- hence this separate leg.
 *
 *   +IMPLICIT_RETURN sets trTeInstFeatures.InstEnImplicitReturn; the
 *   cli_etrace_test ir scenario runs OFF and ON from one build and requires
 *   both to be PC-lossless with the ON stream strictly smaller.
 */

module etrace_ir_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("etrace_ir_tb.atb.bin"),
		.NEXRV_INFO_PATH     ("etrace_ir_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("etrace_ir_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		if ($test$plusargs("IMPLICIT_RETURN")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn(1'b1);
			$display("[etrace_ir_tb] implicit-return ON");
		end
		else begin
			$display("[etrace_ir_tb] implicit-return OFF (baseline)");
		end

		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(32'h0000_1000));
		env.cpu.run(16);                                  // 0x1000..0x100c
		env.cpu.branch_taken(.target(32'h0000_1100));     // @0x1010
		env.cpu.run(8);                                   // 0x1100,0x1104
		env.cpu.call_to(.target(32'h0000_2000));          // @0x1108, ra=0x110c
		env.cpu.run(8);                                   // 0x2000,0x2004
		env.cpu.call_to(.target(32'h0000_2100));          // @0x2008, ra=0x200c
		env.cpu.run(8);                                   // 0x2100,0x2104
		env.cpu.ret();                                    // @0x2108 -> 0x200c (folds when IR on)
		env.cpu.run(4);                                   // 0x200c
		env.cpu.ret();                                    // @0x2010 -> 0x110c (folds when IR on)
		env.cpu.run(8);                                   // 0x110c,0x1110
		env.cpu.branch_not_taken();                       // @0x1114
		env.cpu.run(8);                                   // 0x1118,0x111c
		env.cpu.uninferable_jump(.target(32'h0000_1200)); // @0x1120
		env.cpu.run(8);                                   // 0x1200,0x1204
		env.cpu.idle(50);                                 // drain composer

		env.cpu.exit_trace();
		env.csr.Set_te_trTeControl_Enable(1'b0);          // -> correlation + final flush
		env.cpu.idle(400);

		$display("[etrace_ir_tb] done");
		$finish;
	end

endmodule

`default_nettype wire
