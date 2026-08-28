// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author  Alexander Weiss <aweiss@accemic.com>
 *
 * @file    tb_iti2tip_unit.sv
 * @brief   Gate C2: unit testbench for cva6_iti_to_ctte_tip.
 * @details 100% of the itype vectors (0..6, valid/idle each) + trap
 *   convention (EXC/INT -> iretire=0, ecause/tval gating) + idle-cycle
 *   contract (itype=OTHER, iretire=0) + tie-off check (no X on tip.*).
 *   Self-checking, $fatal on violation, "### TB_PASS" at the end.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module tb_iti2tip_unit;
	import tip_pkg::*;

	logic clk = 0;
	logic rst_n = 0;
	always #5 clk = ~clk;

	logic        v;
	logic [31:0] iretire;
	logic        ilastsize;
	logic [2:0]  itype;
	logic [4:0]  cause;
	logic [31:0] tval;
	logic [1:0]  priv;
	logic [31:0] iaddr;
	logic [63:0] cycles;

	tip_if tip ();

	// ITI_XLEN names the width of the CORE side (here: the 32-bit stimuli
	// above), NOT the encoder's -- only that way does the elaboration
	// contract in the shim trigger when this testbench is run against a
	// CT_XLEN=64 netlist (R2.1c/B-2: the previously used default was equal
	// by definition).
	cva6_iti_to_ctte_tip #(.ITI_XLEN(32)) dut (
		.clk_i(clk), .rst_ni(rst_n),
		.iti_valid_i(v), .iti_iretire_i(iretire), .iti_ilastsize_i(ilastsize),
		.iti_itype_i(itype), .iti_cause_i(cause), .iti_tval_i(tval),
		.iti_priv_i(priv), .iti_iaddr_i(iaddr), .iti_cycles_i(cycles),
		.tip(tip)
	);

	int errors = 0;

	task check(string what, logic cond);
		if (!cond) begin
			errors++;
			$display("### FAIL: %s (itype=%0d valid=%0d)", what, itype, v);
		end
	endtask

	task drive(logic dv, logic [2:0] dt, logic [4:0] dc, logic [31:0] dtval);
		v = dv; itype = dt; cause = dc; tval = dtval;
		iretire = dv ? 32'd1 : '0; ilastsize = 1'b1;
		iaddr = 32'h7C00_1000 + 32'(dt) * 4; cycles = 64'd1000 + 64'(dt); priv = 2'b11;
		@(posedge clk); #1;
	endtask

	initial begin
		v = 0; iretire = '0; ilastsize = 0; itype = '0; cause = '0;
		tval = '0; priv = '0; iaddr = '0; cycles = '0;
		repeat (3) @(posedge clk);
		rst_n = 1;
		@(posedge clk); #1;

		// Idle cycle: OTHER + iretire=0 + no X
		drive(0, 3'd5, 5'd0, 32'h0);
		check("idle itype==OTHER", tip.itype == OTHER);
		check("idle iretire==0", tip.iretire == '0);
		check("idle ecause==NONE", tip.ecause == ECAUSE_NONE);
		check("idle no X", !$isunknown({tip.itype, tip.iretire, tip.ilastsize,
		                                tip.dretire, tip.debug_mode, tip.evti,
		                                tip.power_down}));

		// Retire classes 0/3/4/5/6: 1:1 zero extension, iretire=1
		drive(1, 3'd0, 5'd0, 32'h0);
		check("STANDARD->OTHER", tip.itype == OTHER && tip.iretire == 1);
		drive(1, 3'd3, 5'd0, 32'h0);
		check("ERET->EXCEPTION_IR", tip.itype == EXCEPTION_IR && tip.iretire == 1);
		drive(1, 3'd4, 5'd0, 32'h0);
		check("NONTAKEN", tip.itype == NOT_TAKEN_BRANCH && tip.iretire == 1);
		drive(1, 3'd5, 5'd0, 32'h0);
		check("TAKEN", tip.itype == TAKEN_BRANCH && tip.iretire == 1);
		drive(1, 3'd6, 5'd0, 32'h0);
		check("UNINF_JMP->UNINFERABLE_JUMP", tip.itype == UNINFERABLE_JUMP && tip.iretire == 1);
		check("retire ecause==NONE", tip.ecause == ECAUSE_NONE);
		check("retire tval==0", tip.tval == '0);
		check("ilastsize passed through", tip.ilastsize == 1);
		check("iaddr passed through", tip.iaddr == 32'h7C00_1018);
		check("_time passed through", tip._time == 64'd1006);

		// EXC: iretire FORCED 0, ecause+tval active
		drive(1, 3'd1, 5'd2, 32'hFFFF_FFFF);   // illegal instruction
		check("EXC itype", tip.itype == EXCEPTION_TRAP);
		check("EXC iretire==0 (forced)", tip.iretire == '0);
		check("EXC ecause==2", tip.ecause == tip_ecause_e'(4'd2));
		check("EXC tval", tip.tval == 32'hFFFF_FFFF);
		drive(1, 3'd1, 5'd11, 32'h0);          // ecall M
		check("EXC ecall ecause==11", tip.ecause == tip_ecause_e'(4'd11));

		// INT: iretire 0, ecause=interrupt code, tval 0
		drive(1, 3'd2, 5'd7, 32'hDEAD_BEEF);   // timer
		check("INT itype", tip.itype == INTERRUPT);
		check("INT iretire==0 (forced)", tip.iretire == '0);
		check("INT ecause==7", tip.ecause == tip_ecause_e'(4'd7));
		check("INT tval==0 (gate)", tip.tval == '0);

		// Data trace / sideband stay tied off
		check("dretire tie", tip.dretire == 1'b0);
		check("sideband tie", {tip.debug_mode, tip.evti, tip.power_down} == '0);

		if (errors == 0) $display("### TB_PASS (all itype/trap/tie-off vectors)");
		else begin $display("### TB_FAIL (%0d error(s))", errors); $fatal(1); end
		$finish;
	end

endmodule

`default_nettype wire
