// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  E-Trace data-trace leg (cli_etrace_test.sh df).
 *
 * @details
 *   Interleaves CF activity (branches) with unified loads/stores of all
 *   four sizes, aligned and unaligned, with values exercising the
 *   data_len sign strip (leading zeros, all-ones, sign-boundary bytes).
 *   The TB writes an oracle line per access; the cli leg decodes the ATB
 *   stream (te_data packets, msg_type 3) with etrace_data_check.py and
 *   additionally proves the interleaved PC trace stays lossless.
 */

module etrace_df_tb;

	import cpu_model_pkg::*;
	import tip_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("etrace_df_tb.atb.bin"),
		.NEXRV_INFO_PATH     ("etrace_df_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("etrace_df_tb.expected.pcs")
	) env ();

	int df_fd;

	task automatic exp_store(input tip_iaddr_t a, input int sz,
	                         input tip_data_t d);
		automatic tip_data_t mask = (sz >= 3) ? '1
		                            : ((tip_data_t'(1) << (8 * (1 << sz))) - 1);
		env.cpu.store_data(a, sz, d);
		$fwrite(df_fd, "S %08x %0d %0x\n", a, sz, d & mask);
	endtask

	task automatic exp_load(input tip_iaddr_t a, input int sz,
	                        input tip_data_t d);
		automatic tip_data_t mask = (sz >= 3) ? '1
		                            : ((tip_data_t'(1) << (8 * (1 << sz))) - 1);
		env.cpu.load_data(a, sz, d);
		$fwrite(df_fd, "L %08x %0d %0x\n", a, sz, d & mask);
	endtask

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		df_fd = $fopen("etrace_df_tb.expected.df", "w");

		env.csr.Set_te_trTeDataControl_DataTracing(1'b1);
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(32'h0000_1000));
		env.cpu.run(16);

		// all four sizes, aligned, values with strip-relevant shapes
		exp_store(32'h0000_2000, 0, 64'h0000_0000_0000_00A5); // byte
		exp_store(32'h0000_2002, 1, 64'h0000_0000_0000_80FF); // half, MSB set
		exp_store(32'h0000_2004, 2, 64'h0000_0000_0000_00FF); // word, strip to 2B
		exp_store(32'h0000_2008, 3, 64'hFFFF_FFFF_FFFF_FFFF); // dword all-ones
		env.cpu.branch_taken(.target(32'h0000_1100));
		env.cpu.run(8);

		// unaligned addresses
		exp_store(32'h0000_2401, 1, 64'h0000_0000_0000_1234); // half @ odd
		exp_store(32'h0000_2803, 2, 64'h0000_0000_DEAD_BEEF); // word @ +3
		exp_load (32'h0000_2C02, 3, 64'h0000_0000_CAFE_F00D); // dword @ +2

		env.cpu.branch_not_taken();
		env.cpu.run(8);

		// loads, aligned, incl. zero and sign-boundary values
		exp_load(32'h0000_3000, 0, 64'h0000_0000_0000_0000);
		exp_load(32'h0000_3004, 2, 64'h0000_0000_8000_0000); // MSB of word
		exp_load(32'h0000_3008, 3, 64'h0123_4567_89AB_CDEF);

		env.cpu.run(8);
		env.cpu.idle(50);

		env.cpu.exit_trace();
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.cpu.idle(400);

		$fclose(df_fd);
		$display("[etrace_df_tb] done");
		$finish;
	end

endmodule

`default_nettype wire
