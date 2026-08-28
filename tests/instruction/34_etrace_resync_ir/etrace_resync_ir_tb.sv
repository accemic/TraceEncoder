// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  E-Trace resync x implicit-return braid (cli_etrace_test.sh resyncir).
 *
 * @details
 *   Regression guard for the P10 soak findings S-1/S-2 (both pre-existing
 *   defects of the 2026-07-25 E-Trace implementation, closed in the
 *   P10a E-Trace fix series):
 *
 *   (1) a periodic sync anchoring ON a RETURN retire forced an explicit
 *       report of a stack-predicted return (return_is_predicted required
 *       sync_reason == NONE) -- the decoder mirror folds in lockstep and
 *       mis-binds the address to the next discontinuity;
 *   (2) a target report whose address is also LINEARLY reachable (here: a
 *       call to the immediately following address, so the return target
 *       equals the callee entry) stopped the reference walk at the first
 *       arrival; the model's inferred_address healing dies at every
 *       mid-stream F3.0 -- the encoder must set the updiscon flag on
 *       target reports.
 *
 *   The braid repeats twelve rounds of far-call/return + call-to-next-
 *   address/double-return with drifting linear padding, under a tight
 *   periodic sync window (2^(2+4) = 64 halfwords = 32 instructions), so the
 *   periodic anchors sweep across return retires and the ambiguous shapes.
 *   The cli leg runs the scenario with implicit-return OFF and ON from one
 *   build; both must decode PC-lossless, and the ON stream must contain
 *   mid-trace F3.0 anchors (the braid really crossed resyncs).
 */

module etrace_resync_ir_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("etrace_resync_ir_tb.atb.bin"),
		.NEXRV_INFO_PATH     ("etrace_resync_ir_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("etrace_resync_ir_tb.expected.pcs")
	) env ();

	// Periodic window: count halfwords (mode 3), max 2 -> 64 halfwords.
	localparam logic [3:0] ITR_SYNC_HALFWORDS = 4'd3;
	localparam logic [3:0] INST_SYNC_MAX      = 4'd2;

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		if ($test$plusargs("IMPLICIT_RETURN")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn(1'b1);
			$display("[etrace_resync_ir_tb] implicit-return ON");
		end
		else begin
			$display("[etrace_resync_ir_tb] implicit-return OFF (baseline)");
		end

		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_HALFWORDS);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(32'h0000_1000));
		env.cpu.run(32);                              // 8 linear instructions

		for (int i = 0; i < 12; i++) begin
			// Phase drift: the periodic anchor sweeps across the braid.
			env.cpu.run(4 * (i % 7));
			// Far call/return pair: the return folds when IR is on; with
			// the drifting phase some periodic sync lands ON this return
			// retire (defect 1: it must STAY folded).
			env.cpu.call_to(.target(32'h0000_4000 + 32'h100 * i));
			env.cpu.run(8 + 4 * (i % 5));
			env.cpu.ret();
			// A not-taken branch keeps map bits in the Pu reports (the
			// F1-with-address trailer carries the updiscon flag).
			env.cpu.run(8);
			env.cpu.branch_not_taken();
			env.cpu.run(4 * (i % 3));
			// Call to the NEXT address: return target == callee entry ==
			// linearly reachable through the silent inferable call
			// (defect 2 shape, the cal5-idx6 form). The callee entry and
			// the return execute twice -- second return pops the far
			// call's frame only when... it pops the enclosing frame from
			// the braid call below.
			env.cpu.call_to(.target(32'h0000_5000 + 32'h100 * i)); // enclosing frame
			// braid block at 0x5000+i*0x100:
			env.cpu.run(8);
			env.cpu.call_to(.target(env.cpu.cur_pc + 4));  // call-to-next
			env.cpu.run(4);                                // callee entry (1st visit)
			env.cpu.ret();                                 // -> callee entry (ambiguous target)
			env.cpu.run(4);                                // callee entry (2nd visit)
			env.cpu.ret();                                 // same RETURN pc, pops enclosing frame
			env.cpu.run(8);
			// Address-reported jump into the next round's main block: the
			// Pu report flushes the accumulated map, so the deferred
			// periodic anchor (RsyncPend needs an empty map) gets a pocket
			// to fire in -- an all-folded braid would starve it and the
			// guard's F3.0 requirement would measure nothing.
			env.cpu.uninferable_jump(.target(32'h0000_1100 + 32'h80 * i));
			env.cpu.run(16);
		end

		env.cpu.idle(50);                              // drain composer

		env.cpu.exit_trace();
		env.csr.Set_te_trTeControl_Enable(1'b0);       // correlation + final flush
		env.cpu.idle(400);

		$display("[etrace_resync_ir_tb] done");
		$finish;
	end

endmodule

`default_nettype wire
