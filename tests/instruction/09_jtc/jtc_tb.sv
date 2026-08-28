// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Jump-target-cache compression test (vendor TCODE 57).
 *
 * @details
 *   Exercises the jump-target cache: with
 *   trTeInstFeatures.InstEnJumpTargetCache set, a plain (BTYPE=IBRANCH)
 *   IndirectBranchHist whose target is already installed in the 64-entry
 *   cache goes out as VendorJTC (TCODE 57) carrying the 6-bit cache index
 *   instead of the differential UADDR. The cache installs on every emitted
 *   plain IBH; NexRv mirrors the model bit-identically (learn on BTYPE=0
 *   IBH, read-only on TCODE 57; XOR-fold index).
 *
 *   Scenario: an indirect dispatch cycle over three FAR-APART code blocks
 *   (0x0000_1000 / 0x0010_0000 / 0x0800_0000) -- exactly the case where the
 *   differential UADDR is expensive (large XOR distances, 4-5 MDO bytes per
 *   message) and a 1-byte index wins most. First lap: three cache misses
 *   (full IBH, installs); every following lap: three TCODE-57 hits. The
 *   last lap exits to a coda (same jump PC, different runtime target =
 *   final miss-IBH via the drain-tested path).
 *
 *   Run twice from the same binary:
 *     - default (no plusarg)  -> JTC OFF (IBH with UADDR per dispatch)
 *     - +JTC                  -> JTC ON  (TCODE 57 per cached dispatch)
 *   The decoded PC prefix must be IDENTICAL OFF vs ON (lossless), and ON
 *   must produce a smaller ATB.
 */

module jtc_tb;

	import cpu_model_pkg::*;

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd7;   // 2048-cycle periodic sync
	localparam int         N_LAPS              = 200;

	localparam logic [31:0] BLK_A = 32'h0000_1000;
	localparam logic [31:0] BLK_B = 32'h0010_0000;
	localparam logic [31:0] BLK_C = 32'h0800_0000;
	localparam logic [31:0] CODA  = 32'h0000_100c;

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("jtc_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("jtc_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("jtc_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("jtc_tb.expected.pcs")
	) env ();

	initial begin
		env.wait_for_reset_release();
		env.csr.clear();

		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		if ($test$plusargs("JTC_RET")) begin
			// Coverage leg for a JTC hit on an UNPREDICTED RETURN, the second
			// emission site in msg_gen: return targets repeat while implicit
			// return stays OFF. SyncMode must go to 0 BEFORE Enable -- it is
			// not writable at Enable=1, and with 64-cycle syncs nearly every
			// indirect CF would carry a sync and bypass the RETURN arm.
			env.csr.Set_te_trTeControl_InstSyncMode (4'd0);
			$display("[jtc_tb] %0t: JTC_RET leg (return-target hits)", $time);
		end
		// BEFORE Enable, exactly like SyncMode above: trTeInstFeatures is
		// swwel-gated too (U10 F-1) -- a write after arming is void.
		if ($test$plusargs("JTC")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache(1'b1);
			$display("[jtc_tb] %0t: InstEnJumpTargetCache=1 (JTC ON)", $time);
		end else begin
			$display("[jtc_tb] %0t: JTC OFF (baseline)", $time);
		end
		if ($test$plusargs("JTC_RET")) begin
			env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache(1'b1);
		end

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);

		env.wait_cycles(20);

		// ---- Scenario --------------------------------------------------
		// Dispatch cycle A -> B -> C -> A (12-byte blocks, indirect jumps):
		//   A+0/A+4: L, L      A+8: JR -> B
		//   B+0/B+4: L, L      B+8: JR -> C
		//   C+0/C+4: L, L      C+8: JR -> A   (last lap: -> CODA)
		env.cpu.enter(.start_pc(BLK_A));
		for (int i = 0; i < N_LAPS; i++) begin
			env.cpu.run(8);
			env.cpu.uninferable_jump(.target(BLK_B));
			env.cpu.run(8);
			env.cpu.uninferable_jump(.target(BLK_C));
			env.cpu.run(8);
			if (i < N_LAPS - 1)
				env.cpu.uninferable_jump(.target(BLK_A));
			else
				env.cpu.uninferable_jump(.target(CODA));
		end

		// Coda @ 0x100c
		env.cpu.run(8);

		// ---- +JTC_RET: return-target hits @0x6000 ----------------------
		// Loop L: run / call SUB / SUB: run, ret (target = the instruction
		// after the call, identical every lap) / run / branch back to L.
		// From lap 2 the return target is in the JTC, so the encoder emits
		// VendorJTC instead of IBH (jtc_hit branch of the msg_gen RETURN
		// arm).
		if ($test$plusargs("JTC_RET")) begin
			env.cpu.uninferable_jump(.target(32'h0000_6000));
			for (int i = 0; i < 12; i++) begin
				env.cpu.run(8);                              // 6000..6008
				env.cpu.call_to(.target(32'h0000_6800));     // 6008
				env.cpu.run(8);                              // 6800..6808
				env.cpu.ret();                               // 6808 -> 600C
				env.cpu.run(8);                              // 600C..6014
				if (i < 11)
					env.cpu.branch_taken(.target(32'h0000_6000)); // 6014
				else
					env.cpu.branch_not_taken();
			end
			env.cpu.run(8);
		end

		env.cpu.exit_trace();

		// ---- End drain (mirrors 07/08) ---------------------------------
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
			$error("[jtc_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)
			$error("[jtc_tb] no ATB bytes observed");

		$display("[jtc_tb] PASS (scenario driven, %0d events)", env.cpu.event_count());
		$finish;
	end

	// Global timeout
	initial begin
		#400_000_000; // 400 us -- 40 us silently cut the coverage legs short ($finish, rc=0)
		$error("[jtc_tb] TIMEOUT");
		$finish;
	end

endmodule

`default_nettype wire
