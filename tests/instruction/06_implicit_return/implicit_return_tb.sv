// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Implicit-return compression test (Phase 1).
 *
 * @details
 *   Exercises the return-address-stack compression: with
 *   trTeInstFeatures.InstEnImplicitReturn set, a RETURN whose target the
 *   composer predicted (== call PC + instr size) is folded like an inferable
 *   branch — no IndirectBranchHist is emitted; the decoder recovers the target
 *   from its own call stack (NexRv Path B). Without the bit the same scenario
 *   emits an IndirectBranchHist per return.
 *
 *   The scenario is a long loop of call/return pairs (plus a taken/not-taken
 *   branch each iteration and a couple of nested calls) so there are MANY
 *   returns. Periodic instruction sync (InstSyncMax=1) is enabled so the
 *   accumulated ICNT/HIST — and hence the folded-return spans — are flushed
 *   into ProgTraceSync messages regularly instead of being held to the end
 *   (this bring-up host loses the last held message; a long trace makes that
 *   tail a negligible fraction and keeps every return inside the captured
 *   prefix).
 *
 *   Run twice from the same binary:
 *     - default (no plusarg)  -> implicit-return OFF (IBH per return)
 *     - +IMPLICIT_RETURN      -> implicit-return ON  (returns folded)
 *   The decoded PC prefix must be IDENTICAL OFF vs ON (lossless), and ON must
 *   produce a strictly smaller ATB.
 */

module implicit_return_tb;

	import cpu_model_pkg::*;

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd1;   // 32-cycle periodic sync
	localparam int         N_ITERS             = 60;

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("implicit_return_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("implicit_return_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("implicit_return_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("implicit_return_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);

		// Optional timestamp leg (+TIMESTAMPS): free-running SYSTEM counter,
		// same single configuration write as combined_tb. Must precede
		// trTeControl.Enable (Type/Prescale/Width are swwel-gated). Gives the
		// instruction-only suite a TSTAMP-carrying stream — used to compare
		// the formatter/slicer chain against the compact packer pairwise
		// (absolute-on-sync / delta-elsewhere encoding, TCODE-30 exemption).
		if ($test$plusargs("TIMESTAMPS")) begin
			env.csr.Write_te_trTsControl (32'h3F00_8023);
			$display("[ir_tb] %0t: trTsControl enabled (+TIMESTAMPS leg)", $time);
		end

		// Optional no-timestamp leg (+NO_TSTAMP): clear trTsControl.Enable
		// (resets to 1!) BEFORE tracing starts -- the TSTAMP fields vanish
		// from every message. This stream is the REFERENCE for the
		// CT_EN_TIMESTAMP=0 hardware byte proof (O3): the historical netlist
		// with Enable=0 must be byte-identical to the TS-less netlist.
		if ($test$plusargs("NO_TSTAMP")) begin
			env.csr.Write_te_trTsControl (32'h0000_0000);
			$display("[ir_tb] %0t: trTsControl disabled (+NO_TSTAMP leg)", $time);
		end

		// BEFORE Enable: trTeInstFeatures is swwel-gated like the rest of the
		// configuration (U10 F-1) -- a write after arming is silently void.
		if ($test$plusargs("IMPLICIT_RETURN")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn(1'b1);
			$display("[ir_tb] %0t: InstEnImplicitReturn=1 (implicit-return ON)", $time);
		end else begin
			$display("[ir_tb] %0t: implicit-return OFF (baseline)", $time);
		end

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);

		env.wait_cycles(20);

		// ---- Scenario --------------------------------------------------
		// EVERY iteration is byte-identical so the re-executed leaf/nested
		// bodies never alias a PC to two different instruction kinds (a
		// return landing on a former branch PC would make the program image
		// inconsistent and only the OFF baseline — where the return is a
		// real IBH — would then fail to decode). Main advances by 8/iter.
		//
		//   main_pc  : L                 (run 4)
		//   main_pc+4: CD  -> leaf 2000  (call_to)   push main_pc+8
		//     2000   : L                 (run 4)
		//     2004   : BD not taken      (branch_not_taken)   HIST bit
		//     2008   : CD  -> nested 2100 (call_to)  push 200c
		//       2100 : L                 (run 4)
		//       2104 : R   -> 200c       (ret)       [nested return, depth 2]
		//     200c   : L                 (run 4)
		//     2010   : R   -> main_pc+8  (ret)       [leaf return,   depth 1]
		env.cpu.enter(.start_pc(32'h0000_1000));
		for (int i = 0; i < N_ITERS; i++) begin
			env.cpu.run(4);                                  // main_pc  (L)
			env.cpu.call_to(.target(32'h0000_2000));         // main_pc+4 call leaf
			env.cpu.run(4);                                  // 2000 (L)
			env.cpu.branch_not_taken();                      // 2004 BD nt (HIST)
			env.cpu.call_to(.target(32'h0000_2100));         // 2008 call nested
			env.cpu.run(4);                                  // 2100 (L)
			env.cpu.ret();                                   // 2104 ret -> 200c (nested)
			env.cpu.run(4);                                  // 200c (L)
			env.cpu.ret();                                   // 2010 ret -> main_pc+8 (leaf)
		end

		// A real uninferable jump so a genuine IndirectBranchHist coexists
		// with the folded returns, then a couple of trailing instructions.
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(32'h0000_3000));
		env.cpu.run(8);

		env.cpu.exit_trace();

		// ---- End drain (mirrors the G5 dual-encoder) -------------------
		// Force sync+flush WHILE TRACE IS STILL ACTIVE so msg_gen's residual
		// is emitted as a ProgTraceSync (a syncreq after Enable=0 is ignored).
		env.wait_cycles(50);
		env.atb_force_flush = 1'b1;
		env.atb_force_sync  = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.atb_force_sync  = 1'b0;
		env.wait_cycles(500);

		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(2000);

		if (env.cpu.event_count() == 0)
			$error("[ir_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)
			$error("[ir_tb] no ATB bytes observed");

		$display("[ir_tb] PASS (scenario driven, %0d events)", env.cpu.event_count());
		$finish;
	end

	// Global timeout
	initial begin
		#20_000_000;
		$display("[ir_tb] TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
