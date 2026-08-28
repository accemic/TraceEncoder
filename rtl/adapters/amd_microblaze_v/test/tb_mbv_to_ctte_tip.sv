// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author  Alexander Weiss <aweiss@accemic.com>
 *
 * @file    tb_mbv_to_ctte_tip.sv
 * @brief   Integration testbench for the adapter top.
 * @details Drives the AMD `TRACE` bus with REAL MEASURED G1 scenarios
 *   (rounds 1-6) via `mbv_trace_if` and checks the resulting TIP output
 *   (itype/iretire/ecause/iaddr/ilastsize). This exercises the §5.1
 *   priority (trap entry before decoder classification) end to end.
 *
 * NOTE: never call `.name()` inside a ternary or directly as a $display
 * argument (xsim 2026.1 -> kernel FATAL).
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module tb_mbv_to_ctte_tip;

	import tip_pkg::*;

	logic clk = 1'b0;
	logic rst;

	mbv_trace_if mbv ();
	tip_if       tip ();

	mbv_to_ctte_tip dut (.clk(clk), .rst(rst), .sijump_en(1'b0), .mbv(mbv.sink), .tip(tip.master));

	always #5 clk = ~clk;

	int n_ok, n_fail;

	// Drive one TRACE cycle and check the TIP output.
	task automatic drive_chk(string what,
	                         logic [31:0] pc, logic [31:0] instr,
	                         logic valid, logic exc, logic [5:0] kind, logic jt,
	                         int exp_itype, logic exp_iretire, int exp_ecause);
		string s_itype;
		@(negedge clk);
		mbv.trace_pc              = pc;
		mbv.trace_instruction     = instr;
		mbv.trace_valid_instr     = valid;
		mbv.trace_exception_taken = exc;
		mbv.trace_exception_kind  = kind;
		mbv.trace_jump_taken      = jt;
		#1;
		s_itype = tip.itype.name();
		if (int'(tip.itype) !== exp_itype) begin
			n_fail++;
			$display("[tb_tip] FAIL %s: itype=%0d (%s) expected %0d", what, int'(tip.itype), s_itype, exp_itype);
		end else if (tip.iretire !== exp_iretire) begin
			n_fail++;
			$display("[tb_tip] FAIL %s: iretire=%0b expected %0b", what, tip.iretire, exp_iretire);
		end else if (exc && (int'(tip.ecause) !== exp_ecause)) begin
			n_fail++;
			$display("[tb_tip] FAIL %s: ecause=%0d expected %0d", what, int'(tip.ecause), exp_ecause);
		end else if (tip.iaddr !== pc) begin
			n_fail++;
			$display("[tb_tip] FAIL %s: iaddr=%08h expected %08h", what, tip.iaddr, pc);
		end else begin
			n_ok++;
			$display("[tb_tip] ok   %-38s -> itype=%-15s iretire=%0b iaddr=%08h", what, s_itype, tip.iretire, tip.iaddr);
		end
	endtask

	initial begin
		n_ok = 0; n_fail = 0;
		rst = 1'b1;
		mbv.trace_pc = '0; mbv.trace_instruction = '0; mbv.trace_valid_instr = 1'b0;
		mbv.trace_exception_taken = 1'b0; mbv.trace_exception_kind = '0; mbv.trace_jump_taken = 1'b0;
		mbv.trace_of_piperun = 1'b1; mbv.trace_ex_piperun = 1'b1; mbv.trace_mem_piperun = 1'b1;
		mbv.trace_halted = 1'b0;
		mbv.trace_data_access = 1'b0; mbv.trace_data_address = '0; mbv.trace_data_read = 1'b0;
		mbv.trace_data_write = 1'b0; mbv.trace_data_write_value = '0; mbv.trace_data_byte_enable = '0;
		mbv.trace_reg_write = 1'b0; mbv.trace_reg_addr = '0; mbv.trace_new_reg_value = '0;
		repeat (3) @(posedge clk);
		rst = 1'b0;

		// ---- Program flow (G0-verified real instructions) ----
		// trace_test @0x10: bgeu taken -> TAKEN_BRANCH, retires
		drive_chk("taken branch (trace_test @0x10)", 32'h10, 32'h0062f863, 1'b1, 1'b0, 6'h00, 1'b1,
		          int'(TAKEN_BRANCH), 1'b1, int'(ECAUSE_NONE));
		// not taken -> NOT_TAKEN_BRANCH
		drive_chk("not-taken branch",                32'h14, 32'h0062f863, 1'b1, 1'b0, 6'h00, 1'b0,
		          int'(NOT_TAKEN_BRANCH), 1'b1, int'(ECAUSE_NONE));
		// branch_test @0x34: jal x1 -> INFERRABLE_CALL
		drive_chk("direct call (branch_test @0x34)", 32'h34, 32'h0dc000ef, 1'b1, 1'b0, 6'h00, 1'b1,
		          int'(INFERRABLE_CALL), 1'b1, int'(ECAUSE_NONE));
		// branch_test @0x150: jalr x1,0(x15) -> UNINFERABLE_CALL (indirect call)
		drive_chk("indirect call (branch_test @0x150)", 32'h150, 32'h000780e7, 1'b1, 1'b0, 6'h00, 1'b1,
		          int'(UNINFERABLE_CALL), 1'b1, int'(ECAUSE_NONE));
		// Return: jalr x0,0(x1)
		drive_chk("return (jalr x0,0(x1))",          32'he8, 32'h00008067, 1'b1, 1'b0, 6'h00, 1'b1,
		          int'(RETURN), 1'b1, int'(ECAUSE_NONE));

		// ---- Trap return (round 1: mret retires, AMD sets Jump_Taken=1) ----
		drive_chk("mret (trap_test @0xe4)",          32'he4, 32'h30200073, 1'b1, 1'b0, 6'h00, 1'b1,
		          int'(EXCEPTION_IR), 1'b1, int'(ECAUSE_NONE));

		// ---- Trap entry: dominates the decoder (§5.1 stage 2), iretire=0 ----
		drive_chk("ecall (trap_test @0xfc)",         32'hfc, 32'h00000073, 1'b1, 1'b1, 6'h0b, 1'b0,
		          int'(EXCEPTION_TRAP), 1'b0, int'(ECALL_FROM_M));
		drive_chk("ebreak (trap_test @0x104)",       32'h104, 32'h00100073, 1'b1, 1'b1, 6'h03, 1'b0,
		          int'(EXCEPTION_TRAP), 1'b0, int'(BREAKPOINT));
		drive_chk("illegal (illegal_test @0x104)",   32'h104, 32'h00000000, 1'b1, 1'b1, 6'h02, 1'b0,
		          int'(EXCEPTION_TRAP), 1'b0, int'(ILLEGAL_INSTR));
		drive_chk("misaligned load (@0x104)",        32'h104, 32'h0002a303, 1'b1, 1'b1, 6'h04, 1'b0,
		          int'(EXCEPTION_TRAP), 1'b0, int'(MISALIGNED_LOAD));

		// ---- Interrupt: on an ALU instruction and on a branch (round 6) ----
		drive_chk("ext IRQ on add (@0x16c)",         32'h16c, 32'h00b70733, 1'b1, 1'b1, 6'h2b, 1'b0,
		          int'(INTERRUPT), 1'b0, int'(ECALL_FROM_M));
		// Round 6: on the preempted branch, Jump_Taken=0 -- the trap still dominates.
		drive_chk("ext IRQ on a branch (@0x178)",    32'h178, 32'hfec794e3, 1'b1, 1'b1, 6'h2b, 1'b0,
		          int'(INTERRUPT), 1'b0, int'(ECALL_FROM_M));

		// ---- §5.1 priority core probe: HYPOTHETICAL exc AND jt at once.
		// Never observed in HW (0/69, round 6) -- the adapter must still let the trap win.
		drive_chk("PRIO: exc+jump simultaneously (hypothetical)", 32'h178, 32'hfec794e3, 1'b1, 1'b1, 6'h2b, 1'b1,
		          int'(INTERRUPT), 1'b0, int'(ECALL_FROM_M));

		// ---- Stall/idle cycles: the instruction word is DEAD, NOTHING may be reported ----
		//
		// These vectors are the actual point of this block. The first attempt used a
		// `nop` (0x00000013) here -- which decodes to OTHER anyway, so the test was
		// green without checking anything. The real bus holds the LAST word stable for
		// two more cycles after a retire (G1/G5 measurement) -- if a control-flow word
		// sits there, we would report ghost events to the encoder (which evaluates
		// itype without an iretire gate) and crash NexRv. Hence: exercise idle cycles
		// WITH a control-flow word on the bus.
		drive_chk("idle cycle, stale mret on the bus",  32'he4, 32'h30200073, 1'b0, 1'b0, 6'h00, 1'b0,
		          int'(OTHER), 1'b0, int'(ECAUSE_NONE));
		drive_chk("idle cycle, stale jalr on the bus",  32'h150, 32'h000780e7, 1'b0, 1'b0, 6'h00, 1'b0,
		          int'(OTHER), 1'b0, int'(ECAUSE_NONE));
		// Even with Jump_Taken set (stuck on the dead word), nothing may be reported:
		drive_chk("idle cycle, stale jal + Jump_Taken",  32'h34, 32'h0dc000ef, 1'b0, 1'b0, 6'h00, 1'b1,
		          int'(OTHER), 1'b0, int'(ECAUSE_NONE));
		drive_chk("stall cycle (nop on the bus)",      32'h180, 32'h00000013, 1'b0, 1'b0, 6'h00, 1'b0,
		          int'(OTHER), 1'b0, int'(ECAUSE_NONE));

		// ---- ilastsize (round 7 / R3): 32 bit -> 1 ----
		if (tip.ilastsize !== 2'd1) begin
			n_fail++; $display("[tb_tip] FAIL ilastsize=%0d expected 1 (32-bit instr)", tip.ilastsize);
		end else begin
			n_ok++; $display("[tb_tip] ok   ilastsize=1 for a 32-bit instr (RV32 without C)");
		end

		// ---- MVP constants (AD-04 / G0 port list) ----
		if (tip.tval === '0 && tip._context === '0 && tip.priv === 3'd3 && tip.dretire === 1'b0) begin
			n_ok++; $display("[tb_tip] ok   MVP constants: tval=0, _context=0, priv=M, dretire=0");
		end else begin
			n_fail++; $display("[tb_tip] FAIL MVP constants");
		end

		$display("[tb_tip] result: ok=%0d fail=%0d", n_ok, n_fail);
		if (n_fail != 0) $fatal(1, "[tb_tip] %0d check(s) FAILED", n_fail);
		$display("[tb_tip] PASS -- all %0d checks correct", n_ok);
		$finish;
	end

endmodule : tb_mbv_to_ctte_tip

`default_nettype wire
