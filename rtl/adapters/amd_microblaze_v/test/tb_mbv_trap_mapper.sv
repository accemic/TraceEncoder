// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author  Alexander Weiss <aweiss@accemic.com>
 *
 * @file    tb_mbv_trap_mapper.sv
 * @brief   Unit testbench for the trap mapper (Gate G3).
 * @details IMPORTANT: the vectors are NOT invented expectations, but the
 *   REAL MEASURED G1 values from the AMD `TRACE` bus (see
 *   doc/adapters/microblaze_v_trace_semantics.adoc, rounds 1-6, Vivado
 *   2026.1 / microblaze_riscv:1.0). Every line references its measurement
 *   program + PC.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module tb_mbv_trap_mapper;

	import tip_pkg::*;

	logic        valid_instr, exception_taken;
	logic [5:0]  exception_kind;
	logic        iretire, is_trap_entry, is_interrupt;
	tip_itype_e  trap_itype;
	tip_ecause_e ecause;
	tip_impdef_t impdef;

	mbv_trap_mapper dut (
		.valid_instr(valid_instr), .exception_taken(exception_taken),
		.exception_kind(exception_kind),
		.iretire(iretire), .is_trap_entry(is_trap_entry), .is_interrupt(is_interrupt),
		.trap_itype(trap_itype), .ecause(ecause), .impdef(impdef)
	);

	int n_ok, n_fail;

	// Check one measured event.
	// NOTE: never call `.name()` inside a ternary or directly as a $display
	// argument -- xsim 2026.1 crashes on that (FATAL_ERROR in the process).
	// Always assign to a local `string` first.
	task automatic chk(string what, logic v, logic e, logic [5:0] k,
	                    logic exp_iretire, logic exp_int, int exp_itype, int exp_ecause);
		string s_itype, s_ecause;
		valid_instr = v; exception_taken = e; exception_kind = k;
		#1;
		s_itype  = trap_itype.name();
		s_ecause = ecause.name();
		if (iretire !== exp_iretire) begin
			n_fail++;
			$display("[tb_trap] FAIL %s: iretire=%0b expected %0b", what, iretire, exp_iretire);
		end else if (e && (is_interrupt !== exp_int)) begin
			n_fail++;
			$display("[tb_trap] FAIL %s: is_interrupt=%0b expected %0b", what, is_interrupt, exp_int);
		end else if (e && (int'(trap_itype) !== exp_itype)) begin
			n_fail++;
			$display("[tb_trap] FAIL %s: itype=%0d (%s) expected %0d", what, int'(trap_itype), s_itype, exp_itype);
		end else if (e && (int'(ecause) !== exp_ecause)) begin
			n_fail++;
			$display("[tb_trap] FAIL %s: ecause=%0d (%s) expected %0d", what, int'(ecause), s_ecause, exp_ecause);
		end else begin
			n_ok++;
			$display("[tb_trap] ok   %-34s -> iretire=%0b itype=%s ecause=%s", what, iretire, s_itype, s_ecause);
		end
	endtask

	int it_sync, it_int;

	initial begin
		n_ok = 0; n_fail = 0;

		// ---- Rule 2: normal operation (round 4: Valid_Instr = 1 pulse per retiring instr) ----
		chk("normal retire (trace_test)",           1'b1, 1'b0, 6'h00, 1'b1, 1'b0, int'(OTHER), int'(ECAUSE_NONE));
		chk("stall cycle (OF_PipeRun=0, round 4)",  1'b0, 1'b0, 6'h00, 1'b0, 1'b0, int'(OTHER), int'(ECAUSE_NONE));

		// ---- Round 1: requested traps (trap_test) ----
		// ecall @0xfc : valid=1 exc=1 kind=0x0b -> EXCEPTION_TRAP, ecause=ECALL_FROM_M(11), iretire=0
		chk("ecall M-mode (trap_test @0xfc)",       1'b1, 1'b1, 6'h0b, 1'b0, 1'b0, int'(EXCEPTION_TRAP), int'(ECALL_FROM_M));
		// ebreak @0x104: kind=0x03 -> BREAKPOINT(3)
		chk("ebreak (trap_test @0x104)",            1'b1, 1'b1, 6'h03, 1'b0, 1'b0, int'(EXCEPTION_TRAP), int'(BREAKPOINT));

		// ---- Round 3: fault class (illegal_test) ----
		chk("illegal instr (illegal_test @0x104)",  1'b1, 1'b1, 6'h02, 1'b0, 1'b0, int'(EXCEPTION_TRAP), int'(ILLEGAL_INSTR));

		// ---- Round 5: data-access faults (misaligned_test) ----
		chk("misaligned load (misal. @0x104)",      1'b1, 1'b1, 6'h04, 1'b0, 1'b0, int'(EXCEPTION_TRAP), int'(MISALIGNED_LOAD));
		chk("misaligned store (misal. @0x114)",     1'b1, 1'b1, 6'h06, 1'b0, 1'b0, int'(EXCEPTION_TRAP), int'(MISALIGNED_STORE));

		// ---- Rounds 2+6: external interrupt (interrupt_test), 69 events, kind uniformly 0x2b ----
		// Bit5=1 -> INTERRUPT; [4:0]=11 (MEXT). Without bit 5, indistinguishable from ecall!
		chk("external IRQ / MEXT (@0x16c)",         1'b1, 1'b1, 6'h2b, 1'b0, 1'b1, int'(INTERRUPT), int'(ECALL_FROM_M));
		chk("external IRQ on a branch (@0x178)",    1'b1, 1'b1, 6'h2b, 1'b0, 1'b1, int'(INTERRUPT), int'(ECALL_FROM_M));

		// ---- Discriminator core probe: same cause 11, only bit 5 differs ----
		valid_instr = 1'b1; exception_taken = 1'b1;
		exception_kind = 6'h0b; #1; it_sync = int'(trap_itype);
		exception_kind = 6'h2b; #1; it_int  = int'(trap_itype);
		if (it_sync == int'(EXCEPTION_TRAP) && it_int == int'(INTERRUPT)) begin
			n_ok++;
			$display("[tb_trap] ok   discriminator: 0x0b->EXCEPTION_TRAP, 0x2b->INTERRUPT (same cause 11)");
		end else begin
			n_fail++;
			$display("[tb_trap] FAIL discriminator Exc_Kind[5]: sync=%0d int=%0d", it_sync, it_int);
		end

		// ---- Special cause >15 (§5.3 DESIGN, UNTESTED in HW -- ports not exposed) ----
		// cause=24 (AXI4-Stream exc) fits in [4:0]; ecause falls back, impdef carries the code.
		valid_instr = 1'b1; exception_taken = 1'b1; exception_kind = 6'h18; #1;   // 0x18 = 24, bit5=0
		if (impdef[6] === 1'b1 && impdef[5:0] === 6'h18 && int'(ecause) === int'(ECAUSE_NONE)) begin
			n_ok++; $display("[tb_trap] ok   special cause 24: impdef[6]=1, impdef[5:0]=0x18, ecause=fallback (DESIGN, not HW-confirmed)");
		end else begin
			n_fail++; $display("[tb_trap] FAIL special-cause path: impdef=%02h ecause=%0d", impdef, int'(ecause));
		end

		// ---- tval is not exposed on the MBV -> impdef[7] always 1 (AD-04) ----
		if (impdef[7] === 1'b1) begin n_ok++; $display("[tb_trap] ok   impdef[7] (tval_unavailable) = 1"); end
		else begin n_fail++; $display("[tb_trap] FAIL impdef[7] != 1"); end

		$display("[tb_trap] result: ok=%0d fail=%0d", n_ok, n_fail);
		if (n_fail != 0) $fatal(1, "[tb_trap] %0d check(s) FAILED", n_fail);
		$display("[tb_trap] PASS -- all %0d checks correct against the G1 measured values", n_ok);
		$finish;
	end

endmodule : tb_mbv_trap_mapper

`default_nettype wire
