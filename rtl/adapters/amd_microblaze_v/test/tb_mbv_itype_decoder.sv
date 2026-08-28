// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author  Alexander Weiss <aweiss@accemic.com>
 *
 * @file    tb_mbv_itype_decoder.sv
 * @brief   Unit testbench for the instruction decoder (Gate G2).
 * @details Reads `itype_vectors.vec` (a static snapshot from the same
 *   generator as doc/adapters/itype_decoder_vectors.csv, so no drift)
 *   and checks EVERY
 *   vector:
 *       <instr_hex8> <jump_taken 0|1> <expected itype code 0..15>
 *   The instruction words are cross-verified against the real toolchain via
 *   objdump.
 * @checking Acceptance (G2): 100% of the vectors pass AND every expected
 *   itype value is covered at least once. Failure signals via $fatal so
 *   xsim reports it and the harness can detect it.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module tb_mbv_itype_decoder;

	import tip_pkg::*;

	localparam string VEC_FILE = "itype_vectors.vec";

	logic [31:0] instr;
	logic        jump_taken;
	tip_itype_e  itype;
	logic        is_trap_return;
	logic [1:0]  ilastsize;

	mbv_riscv_itype_decoder #(.SUPPORT_RVC(1'b0)) dut (
		.instr(instr), .jump_taken(jump_taken),
		.itype(itype), .is_trap_return(is_trap_return), .ilastsize(ilastsize)
	);

	int fd, n_ok, n_fail, n_total;
	int cov [0:15];                      // coverage per itype code

	// Parse one line: returns 1 when a vector was read.
	int  code, jt, r;
	logic [31:0] iw;
	string line;

	initial begin
		n_ok = 0; n_fail = 0; n_total = 0;
		for (int i = 0; i < 16; i++) cov[i] = 0;

		fd = $fopen(VEC_FILE, "r");
		if (fd == 0) $fatal(1, "[tb_itype] vector file '%s' not found", VEC_FILE);

		while (!$feof(fd)) begin
			line = "";
			void'($fgets(line, fd));
			if (line.len() == 0) continue;
			if (line.substr(0, 1) == "//") continue;          // comment line
			r = $sscanf(line, "%h %d %d", iw, jt, code);
			if (r != 3) continue;                              // blank/trailing line

			instr      = iw;
			jump_taken = jt[0];
			#1;                                                // let combinational logic settle

			n_total++;
			if (int'(itype) === code) begin
				n_ok++;
				cov[code]++;
			end else begin
				n_fail++;
				$display("[tb_itype] FAIL instr=%08h jt=%0d : expected %0d (%s), got %0d (%s)",
				         iw, jt, code, itype_name(code), int'(itype), itype.name());
			end

			// Additional check: ilastsize from the length encoding (round 7 / R3)
			if (ilastsize !== ((iw[1:0] == 2'b11) ? 2'd1 : 2'd0)) begin
				n_fail++;
				$display("[tb_itype] FAIL instr=%08h : unexpected ilastsize=%0d", iw, ilastsize);
			end
		end
		$fclose(fd);

		// --- Coverage: every itype expected by the vector set hit at least once ---
		$display("[tb_itype] vectors: %0d  ok=%0d  fail=%0d", n_total, n_ok, n_fail);
		$write("[tb_itype] itype coverage:");
		for (int i = 0; i < 16; i++) if (cov[i] > 0) $write(" %0d(x%0d)", i, cov[i]);
		$display("");

		if (n_total == 0) $fatal(1, "[tb_itype] NO vectors read -- test setup broken");
		if (n_fail != 0)  $fatal(1, "[tb_itype] %0d vector(s) FAILED", n_fail);
		$display("[tb_itype] PASS -- all %0d vectors classified correctly", n_total);
		$finish;
	end

	// Helper: code -> name (for readable error messages)
	function automatic string itype_name(int c);
		tip_itype_e e;
		e = tip_itype_e'(c);
		return e.name();
	endfunction

endmodule : tb_mbv_itype_decoder

`default_nettype wire
