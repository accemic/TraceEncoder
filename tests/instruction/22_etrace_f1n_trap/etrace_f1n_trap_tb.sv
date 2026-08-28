// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  E-Trace F1N+trap corner leg (cli_etrace_test.sh f1ntrap).
 *
 * @details
 *   Regression guard for the "trap right after a full 31-bit branch map"
 *   corner: after a Format-1-without-address packet the DECODER's position
 *   is the 31st branch (it stops there holding one pending bit), NOT the
 *   last address-packet target -- position gates keyed on the differential
 *   address base mis-fire here. Two sub-cases:
 *
 *     (a) async interrupt with icnt==0 directly after branch #31
 *     (b) interrupt a few linear instructions after branch #31
 *
 *   plus a clean trace-off ending. All branches NOT taken (linear fall-
 *   through) so the PC path is trivially checkable.
 */

module etrace_f1n_trap_tb;

	import cpu_model_pkg::*;
	import tip_pkg::*;   // ILLEGAL_INSTR (coverage phase)

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("etrace_f1n_trap_tb.atb.bin"),
		.NEXRV_INFO_PATH     ("etrace_f1n_trap_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("etrace_f1n_trap_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(32'h0000_1000));
		env.cpu.run(8);                                   // 0x1000,0x1004

		// (a) exactly 31 back-to-back not-taken branches -> F1N fires on
		// bit #31; the async interrupt hits BEFORE the next instruction
		// retires (icnt==0 at the trap beat).
		for (int i = 0; i < 31; i++)
			env.cpu.branch_not_taken();                   // 0x1008 .. 0x1080
		env.cpu.interrupt(.cause(7), .handler(32'h0000_3000), .async(1));
		env.cpu.run(8);                                   // 0x3000,0x3004 (ISR)
		env.cpu.mret();                                   // @0x3008 -> resume 0x1084
		env.cpu.run(8);                                   // 0x1084,0x1088

		// (b) again 31 not-taken branches, then TWO linear instructions
		// retire before the interrupt (icnt>0 at the trap beat).
		for (int i = 0; i < 31; i++)
			env.cpu.branch_not_taken();                   // 0x108c .. 0x1104
		env.cpu.run(8);                                   // 0x1108,0x110c
		env.cpu.interrupt(.cause(11), .handler(32'h0000_3100), .async(1));
		env.cpu.run(8);                                   // 0x3100,0x3104 (ISR)
		env.cpu.mret();                                   // @0x3108 -> resume 0x1110
		env.cpu.run(8);                                   // 0x1110,0x1114
		// Coverage phase (+TH0): uninferable jump, then an inferable jal
		// (retires, resolves the deferred report to the TARGET address),
		// then a no-retire trap with icnt==0 -- nothing retired since the
		// address packet, map empty: the F3.1 thaddr=0 arm fires.
		if ($test$plusargs("TH0")) begin
			env.cpu.uninferable_jump(.target(32'h0000_4000));
			env.cpu.jump_to(.target(32'h0000_4800));
			env.cpu.exception_trap(.cause(ILLEGAL_INSTR),
			                       .handler(32'h0000_5000),
			                       .no_retire(1));
			env.cpu.run(16);
			env.cpu.mret();
			env.cpu.run(16);
		end
		env.cpu.idle(50);

		env.cpu.exit_trace();
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.cpu.idle(400);

		$display("[etrace_f1n_trap_tb] done");
		$finish;
	end

endmodule

`default_nettype wire
