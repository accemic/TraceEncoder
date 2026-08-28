// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author  Alexander Weiss <aweiss@accemic.com>
 *
 * @file    tb_itype_refine_unit.sv
 * @brief   Package I1 gate 1: the itype refinement against an INDEPENDENT oracle.
 * @details The vector file is a static snapshot from an external
 *   generator: the ENCODING comes from the real
 *   assembler (riscv64-unknown-elf-as, rv64imac) and was read back via
 *   objdump; the EXPECTATION comes from a purely textual E-Trace rule table
 *   keyed on the mnemonic. The oracle knows not a single bit of the
 *   encoding -- an oracle that evaluates the same bit fields as the design
 *   under test only tests itself (see the workspace methodology on
 *   measurement discipline).
 *
 *   Two things are checked:
 *    (a) cva6_riscv_itype_refine alone (purely combinational);
 *    (b) the same vector through cva6_iti_to_ctte_tip with
 *        ITI_ITYPE_REFINE=1, i.e. including the wiring, the idle-cycle
 *        contract (valid=0 -> OTHER) and the trap convention;
 *    (c) the same vector through a SECOND shim with ITI_ITYPE_REFINE=0:
 *        its tip.itype MUST stay a pure zero extension. That is backward
 *        compatibility as a measurement, not a claim.
 *
 * @environment Static vector replay; no clocked DUT state beyond the
 *   two-shim comparison.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module tb_itype_refine_unit;
	import tip_pkg::*;

	// The shim's width contract is NOT the subject of this testbench (the
	// RV64 unit testbench drives that with an XLEN probe). Only itype
	// matters here, so the core width follows whatever netlist was built.
	localparam int unsigned CORE_XLEN = TIP_IADDRESS_WIDTH;

	logic clk = 0;
	logic rst_n = 0;
	always #5 clk = ~clk;

	logic [31:0]                insn;
	logic [2:0]                 iti_itype;
	logic [TIP_ITYPE_WIDTH-1:0] refined;

	logic                  v;
	logic [31:0]           iretire;
	logic                  ilastsize;
	logic [4:0]            cause;
	logic [CORE_XLEN-1:0]  tval, iaddr;
	logic [1:0]            priv;
	logic [63:0]           cycles;

	// (a) The refiner alone
	cva6_riscv_itype_refine u_refine (
		.insn(insn), .iti_itype(iti_itype), .itype(refined)
	);

	// (b)/(c) Two shims, same stimuli, only the parameter differs
	tip_if tip_on ();
	tip_if tip_off ();

	cva6_iti_to_ctte_tip #(.ITI_XLEN(CORE_XLEN), .ITI_ITYPE_REFINE(1'b1)) dut_on (
		.clk_i(clk), .rst_ni(rst_n),
		.iti_valid_i(v), .iti_iretire_i(iretire), .iti_ilastsize_i(ilastsize),
		.iti_itype_i(iti_itype), .iti_cause_i(cause), .iti_tval_i(tval),
		.iti_priv_i(priv), .iti_iaddr_i(iaddr), .iti_cycles_i(cycles),
		.iti_insn_i(insn),
		.tip(tip_on.master)
	);

	cva6_iti_to_ctte_tip #(.ITI_XLEN(CORE_XLEN)) dut_off (
		.clk_i(clk), .rst_ni(rst_n),
		.iti_valid_i(v), .iti_iretire_i(iretire), .iti_ilastsize_i(ilastsize),
		.iti_itype_i(iti_itype), .iti_cause_i(cause), .iti_tval_i(tval),
		.iti_priv_i(priv), .iti_iaddr_i(iaddr), .iti_cycles_i(cycles),
		.tip(tip_off.master)
	);

	int errors = 0;
	int checked = 0;
	int n_call = 0, n_ret = 0, n_swap = 0, n_pass = 0;

	task automatic check(string what, logic cond, int got, int want);
		if (!cond) begin
			errors++;
			if (errors <= 20)
				$display("### FAIL: %s (insn=%08h iti=%0d got=%0d want=%0d)",
				         what, insn, iti_itype, got, want);
		end
	endtask

	string  line;
	integer fd, code;
	int     vi, ve;
	logic [31:0] vinsn;

	initial begin
		string vecfile;
		v = 0; iretire = '0; ilastsize = 1'b1; cause = '0; tval = '0;
		priv = 2'b11; iaddr = '0; cycles = '0; insn = '0; iti_itype = '0;
		repeat (4) @(posedge clk);
		rst_n = 1;
		repeat (2) @(posedge clk);

		if (!$value$plusargs("VEC=%s", vecfile))
			vecfile = "itype_vectors.vec";
		fd = $fopen(vecfile, "r");
		if (fd == 0) begin
			$display("### TB_FAIL: vector file '%s' not readable", vecfile);
			$finish;
		end

		while ($fgets(line, fd) != 0) begin
			if (line.len() < 3) continue;
			if (line[0] == "#") continue;
			code = $sscanf(line, "%h %d %d", vinsn, vi, ve);
			if (code != 3) continue;

			// --- (a) purely combinational
			insn      = vinsn;
			iti_itype = vi[2:0];
			v         = 1'b1;
			iretire   = 32'd1;
			iaddr     = CORE_XLEN'(64'h0000_1000);
			#1;
			checked++;
			check("refine", refined == ve[TIP_ITYPE_WIDTH-1:0], int'(refined), ve);

			// --- (b) through the shim with refinement
			@(posedge clk); #1;
			check("shim_on.itype", tip_on.itype == tip_itype_e'(ve[TIP_ITYPE_WIDTH-1:0]),
			      int'(tip_on.itype), ve);
			// --- (c) backward compatibility: pure zero extension without refinement
			check("shim_off.itype", tip_off.itype == tip_itype_e'({1'b0, vi[2:0]}),
			      int'(tip_off.itype), int'({1'b0, vi[2:0]}));

			case (ve)
				8, 9:  n_call++;
				13:    n_ret++;
				12:    n_swap++;
				default: n_pass++;
			endcase

			// --- Idle-cycle contract: valid=0 -> OTHER, even with refinement
			v = 1'b0; iretire = '0;
			@(posedge clk); #1;
			check("shim_on.idle", tip_on.itype == OTHER, int'(tip_on.itype), 0);
			check("shim_off.idle", tip_off.itype == OTHER, int'(tip_off.itype), 0);
		end
		$fclose(fd);

		// Coverage clamp: a run that classified not a single return and not
		// a single call proves nothing -- even if it is error-free (an
		// empty vector file would otherwise be "green").
		if (n_call < 4 || n_ret < 3 || n_swap < 2) begin
			$display("### TB_FAIL: vector coverage too thin (call=%0d ret=%0d swap=%0d)",
			         n_call, n_ret, n_swap);
			$finish;
		end

		$display("### vectors: %0d checked (call=%0d ret=%0d swap=%0d unchanged=%0d)",
		         checked, n_call, n_ret, n_swap, n_pass);
		if (errors == 0) $display("### TB_PASS");
		else             $display("### TB_FAIL: %0d deviation(s)", errors);
		$finish;
	end

endmodule

`default_nettype wire
