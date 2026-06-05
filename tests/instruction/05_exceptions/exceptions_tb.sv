// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Instruction-trace test for synchronous exceptions (incl. iretire=0).
 *
 * @details
 *   Focuses on the EXCEPTION_TRAP path, in particular the illegal-instruction
 *   shape where the faulting instruction is fetched but NEVER retires
 *   (iretire=0) while its iaddr/ilastsize are still communicated — exactly as a
 *   real RISC-V core drives an illegal-instruction trap. The encoder's
 *   `count_halfwords` includes EXCEPTION_TRAP regardless of iretire (see
 *   ct_L23_preproc_composer_etip.sv), so the decoder still reconstructs the
 *   faulting PC (mepc). This group exercises that iretire=0 EXCEPTION_TRAP
 *   branch, which the 02_interrupts exception scenario (iretire=1) does not.
 *
 *   Scenarios:
 *     1) illegal-instruction exception, faulting PC NEVER retired (iretire=0)
 *     2) co-reported exception (iretire=1) for contrast
 *     3) illegal-instruction exception (iretire=0) right after a taken branch
 *
 *   Configuration: instruction trace ON. Data trace, HSI, filters all OFF.
 */

module exceptions_tb;

	import cpu_model_pkg::*;
	import tip_pkg::*;   // ILLEGAL_INSTR / LOAD_FAULT (tip_ecause_e)

	ctrace_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("exceptions_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("exceptions_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("exceptions_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("exceptions_tb.expected.pcs")
	) env ();

	// Contiguous PC layout (NexRv PCInfo wants a packed address space).
	//   0x1000 .. 0x100c : main (4 L), illegal @0x1010
	//   0x1014 .. 0x1024 : main resume / linear
	//   0x1028           : taken direct branch (BD) -> 0x1060 (scenario 3)
	//   0x1040 ..        : ISR_A (3 L + R)   handler for scenario 1
	//   0x1050 ..        : ISR_B (2 L + R)   handler for scenario 2
	//   0x1060           : illegal @branch target (scenario 3, faulting, never retired)
	//   0x1070 ..        : ISR_C (1 L + R)   handler for scenario 3
	localparam logic [31:0] MAIN_PC = 32'h0000_1000;
	localparam logic [31:0] ISR_A   = 32'h0000_1040;
	localparam logic [31:0] ISR_B   = 32'h0000_1050;
	localparam logic [31:0] BR_TGT  = 32'h0000_1060;
	localparam logic [31:0] ISR_C   = 32'h0000_1070;

	initial begin
		$display("[exceptions_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[exceptions_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.wait_cycles(20);
		$display("[exceptions_tb] %0t: starting scenario", $time);

		env.cpu.enter(.start_pc(MAIN_PC));

		// --- 1) illegal-instruction exception, faulting PC NEVER retired ----
		//   The instruction at 0x1010 is fetched, found illegal, and does NOT
		//   retire (iretire=0). Its iaddr (0x1010) is still driven on the trap
		//   beat. The encoder counts its halfwords (EXCEPTION_TRAP) so the
		//   decoder reconstructs 0x1010 as the faulting PC even though it never
		//   retired; the handler then runs and mret resumes at 0x1014.
		env.cpu.run(16);                                                         // 0x1000..0x100c (4 L)
		env.cpu.exception_trap(.cause(ILLEGAL_INSTR), .handler(ISR_A), .no_retire(1)); // illegal @0x1010 (iretire=0)
		env.cpu.run(12);                                                         // ISR_A body: 0x1040..0x1048 (3 L)
		env.cpu.mret();                                                          // R @0x104c -> resume at 0x1014

		// --- 2) co-reported exception (iretire=1), for contrast -------------
		env.cpu.run(8);                                                          // 0x1014, 0x1018 (2 L)
		env.cpu.exception_trap(.cause(LOAD_FAULT), .handler(ISR_B));       // retired E @0x101c (iretire=1)
		env.cpu.run(8);                                                          // ISR_B body: 0x1050, 0x1054 (2 L)
		env.cpu.mret();                                                          // R @0x1058 -> resume at 0x1020

		// --- 3) illegal-instruction exception right after a taken branch ----
		//   Exercises the pending_cf_next_iaddr carry-over with an iretire=0
		//   exception: the prior taken branch's target (0x1060) is supplied by
		//   this trap beat's iaddr; the faulting instruction at 0x1060 never
		//   retires; mret resumes at 0x1064.
		env.cpu.run(8);                                                          // 0x1020, 0x1024 (2 L)
		env.cpu.branch_taken(.target(BR_TGT));                                   // BD @0x1028 -> 0x1060 (taken)
		env.cpu.exception_trap(.cause(ILLEGAL_INSTR), .handler(ISR_C), .no_retire(1)); // illegal @0x1060 (iretire=0)
		env.cpu.run(4);                                                          // ISR_C body: 0x1070 (1 L)
		env.cpu.mret();                                                          // R @0x1074 -> resume at 0x1064
		env.cpu.run(4);                                                          // 0x1064 retires (L)

		env.cpu.exit_trace();

		// ---- Trace-off (drain + Program Trace Correlation message) ----
		env.wait_cycles(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.wait_cycles(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		if (env.cpu.event_count() == 0) begin
			$error("[exceptions_tb] cpu_model event log empty");
		end else begin
			$display("[exceptions_tb] cpu_model logged %0d events", env.cpu.event_count());
		end
		if (env.atb_bytes_seen == 0) begin
			$error("[exceptions_tb] no ATB bytes observed");
		end else begin
			$display("[exceptions_tb] observed %0d ATB transfers", env.atb_bytes_seen);
		end

		$display("[exceptions_tb] PASS");
		$finish;
	end

	// Hard timeout
	initial begin
		#10ms;
		$error("[exceptions_tb] TIMEOUT - test exceeded 10 ms wall time");
		$finish;
	end

endmodule

`default_nettype wire
