// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  E-Trace mid-trace periodic-resync leg (cli_etrace_test.sh resync).
 *
 * @details
 *   Composer periodic syncs (trTeInstSyncMode counting halfwords, small
 *   window) fire several times mid-trace; the E-Trace generator must
 *   re-anchor via deferred Format 3.0 packets (RsyncPend) instead of
 *   dropping them. Scenario mixes linear stretches, taken/not-taken
 *   branches, a call/return pair and an uninferable jump so anchors land on
 *   OTHER beats as well as CF beats; clean Enable-off ending. The cli leg
 *   additionally requires >= 2 mid-trace F3.0 anchors in the stream.
 */

module etrace_resync_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("etrace_resync_tb.atb.bin"),
		.NEXRV_INFO_PATH     ("etrace_resync_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("etrace_resync_tb.expected.pcs")
	) env ();

	// Small periodic window: count halfwords, max 2 -> 2^(2+4) = 64
	// halfwords = 32 four-byte instructions per sync.
	localparam logic [3:0] ITR_SYNC_HALFWORDS = 4'd3;
	localparam logic [3:0] INST_SYNC_MAX      = 4'd2;

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_HALFWORDS);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(32'h0000_1000));
		// Coverage prefix (+ANCHORJUMP): the very FIRST CF beat (carrying
		// the TRACE_ENABLE sync, Started still 0) is an uninferable jump --
		// the hard anchor lands ON the updiscon and a follow-up F2 reports
		// its target.
		if ($test$plusargs("ANCHORJUMP")) begin
			env.cpu.uninferable_jump(.target(32'h0000_A000));
		end
		env.cpu.run(120);                                 // 30 linear instr
		env.cpu.branch_taken(.target(32'h0000_1200));
		env.cpu.run(120);                                 // 30 linear
		env.cpu.branch_not_taken();
		env.cpu.run(60);                                  // 15 linear
		env.cpu.call_to(.target(32'h0000_2000));
		env.cpu.run(120);                                 // 30 linear (callee)
		env.cpu.ret();
		env.cpu.run(60);                                  // 15 linear
		env.cpu.uninferable_jump(.target(32'h0000_1800));
		env.cpu.run(120);                                 // 30 linear
		env.cpu.branch_taken(.target(32'h0000_1a00));
		env.cpu.run(60);                                  // 15 linear
		env.cpu.idle(50);

		env.cpu.exit_trace();
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.cpu.idle(400);

		$display("[etrace_resync_tb] done");
		$finish;
	end

endmodule

`default_nettype wire
