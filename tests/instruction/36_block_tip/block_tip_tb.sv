// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Block ingress (R1.3, ct_pkg::CT_EN_BLOCK_TIP): several retired
 *           instructions per TIP beat.
 *
 * @details
 *   ONE scenario, TWO ways of presenting it to the encoder:
 *
 *     default        every segment is driven as a BLOCK -- one tip beat
 *                    carrying 1, 2, 3 or 4 instructions, terminated by
 *                    OTHER / branch / call / return / indirect jump.
 *     +SERIAL        the identical instruction sequence driven one
 *                    instruction per beat (the historical shape).
 *
 *   The instruction sequence is written ONCE (the seg_* wrappers below), so
 *   the two legs cannot drift apart. Both legs log the same per-instruction
 *   oracle events, so `block_tip_tb.expected.pcs` and
 *   `block_tip_tb.nexrv.info` are identical for both -- and the claim under
 *   test is exactly that:
 *
 *       Reporting in blocks does not change the reconstructed flow,
 *       only its packaging.
 *
 *   i.e. NexRv must reconstruct the same PC sequence from both ATB streams,
 *   and that sequence must be the per-instruction oracle -- an oracle that
 *   never saw a block. Comparing the encoder's halfword count against the
 *   encoder's own halfword count would prove nothing; this compares against
 *   the instructions.
 *
 *   Driven by scripts/r13_block_tip_test.sh, which builds the encoder with
 *   CT_EN_BLOCK_TIP = 1 in a detached worktree, runs both legs and diffs
 *   the decoded sequences.
 *
 *   Configuration: instruction trace ON, timestamps ON, data trace OFF.
 */

module block_tip_tb;

	import cpu_model_pkg::*;
	import tip_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("block_tip_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("block_tip_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("block_tip_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("block_tip_tb.expected.pcs")
	) env ();

	// 1 = drive blocks (default), 0 = drive one instruction per beat.
	bit serial_mode = 1'b0;

	// ------------------------------------------------------------------
	// Anti-vacuity witness, measured AT THE PORT.
	//
	// The two legs emit nearly the same bytes by construction -- the
	// halfword distance between two control-flow events does not depend on
	// how the beats were cut, which is exactly the property under test. A
	// byte-size comparison is therefore a weak witness that the block leg
	// really packed anything. This counts the beats instead: same halfword
	// total, but the block leg must need strictly FEWER beats to deliver
	// it. If the block tasks ever degenerate to single retirements, this
	// goes red while every PC comparison would still pass.
	// ------------------------------------------------------------------
	int unsigned beats_retiring = 0;
	int unsigned halfwords_seen = 0;
	int unsigned max_beat_hw    = 0;
	always @(posedge env.tip_clk) begin
		if (!env.tip_rst && (env.tip.iretire != '0)) begin
			beats_retiring += 1;
			halfwords_seen += int'(env.tip.iretire);
			if (int'(env.tip.iretire) > max_beat_hw) max_beat_hw = int'(env.tip.iretire);
		end
	end

	// ------------------------------------------------------------------
	// Segment wrappers: ONE scenario description, two ingress shapes.
	// `n_lead` linear instructions, then the terminator.
	// ------------------------------------------------------------------
	task automatic seg_run(input int n_instr);
		if (serial_mode) env.cpu.run(4 * n_instr);
		else             env.cpu.run_block(n_instr);
	endtask

	task automatic seg_branch_taken(input int n_lead, input tip_iaddr_t target);
		if (serial_mode) begin
			if (n_lead > 0) env.cpu.run(4 * n_lead);
			env.cpu.branch_taken(target);
		end else begin
			env.cpu.block_branch_taken(n_lead, target);
		end
	endtask

	task automatic seg_branch_not_taken(input int n_lead);
		if (serial_mode) begin
			if (n_lead > 0) env.cpu.run(4 * n_lead);
			env.cpu.branch_not_taken();
		end else begin
			env.cpu.block_branch_not_taken(n_lead);
		end
	endtask

	task automatic seg_call_to(input int n_lead, input tip_iaddr_t target);
		if (serial_mode) begin
			if (n_lead > 0) env.cpu.run(4 * n_lead);
			env.cpu.call_to(target);
		end else begin
			env.cpu.block_call_to(n_lead, target);
		end
	endtask

	task automatic seg_ret(input int n_lead);
		if (serial_mode) begin
			if (n_lead > 0) env.cpu.run(4 * n_lead);
			env.cpu.ret();
		end else begin
			env.cpu.block_ret(n_lead);
		end
	endtask

	task automatic seg_uninferable_jump(input int n_lead, input tip_iaddr_t target);
		if (serial_mode) begin
			if (n_lead > 0) env.cpu.run(4 * n_lead);
			env.cpu.uninferable_jump(target);
		end else begin
			env.cpu.block_uninferable_jump(n_lead, target);
		end
	endtask

	initial begin
		if ($test$plusargs("SERIAL")) serial_mode = 1'b1;
		$display("[block_tip_tb] mode = %s", serial_mode ? "SERIAL (1 instr/beat)"
		                                                 : "BLOCK (n instr/beat)");
		$display("[block_tip_tb] CT_EN_BLOCK_TIP=%0d TIP_IRETIRE_WIDTH=%0d",
		         ct_pkg::CT_EN_BLOCK_TIP, tip_pkg::TIP_IRETIRE_WIDTH);
		if (!ct_pkg::CT_EN_BLOCK_TIP) begin
			$error("[block_tip_tb] BUILD-MISMATCH: this testbench needs ct_pkg::CT_EN_BLOCK_TIP=1");
			$finish;
		end

		env.wait_for_reset_release();
		env.csr.clear();
		// RepeatInstruction ON, and not for coverage's sake: it is the one
		// runtime feature that consumes etip_cf.iaddr as the SOURCE address
		// of the control-flow event rather than as an anchor
		// (ct_L2_msg_gen.sv RptAddr / the `next_iaddr == etip_cf.iaddr`
		// self-loop test). Without it the whole gate is BLIND to
		// TipLastIaddr: mutation M2 -- "the CF source is the block start" --
		// passed every check on 2026-08-09 08:13 because no consumer looked.
		// With it, the loop segment below is decisive: a block whose
		// terminating branch jumps back to the START of its own block would
		// then look like a branch onto itself, and the decoder would
		// reconstruct a one-instruction spin loop instead of the real body.
		// (written BEFORE Enable -- trTeInstFeatures is swwel-gated, U10 F-1)
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatInstr(1'b1);
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		// ---- Scenario -----------------------------------------------
		// Block sizes deliberately mixed 1/2/3/4 so a "block size is
		// always 2" shortcut cannot pass, and every terminator kind is
		// exercised at least once with a non-empty lead (that is the case
		// where iaddr != the CF source PC).
		//
		//  1000: 4 linear                      (block of 4, OTHER)
		//  1010: 2 linear + taken branch -> 1100   (block of 3, TAKEN_BRANCH)
		//  1100: 1 linear + not-taken branch       (block of 2)
		//  110C: 3 linear + call -> 2000           (block of 4, return = 111C)
		//  2000: 2 linear                          (block of 2, OTHER)
		//  2008: 1 linear                          (block of 1  -- the
		//                                           degenerate case must
		//                                           still work)
		//  200C: 2 linear + ret -> 111C            (block of 3, RETURN)
		//  111C: 1 linear + indirect jump -> 1200  (block of 2)
		//  1200: 3 linear + taken branch -> 1300   (block of 4)
		//  1300: 2 linear
		// -------------------------------------------------------------
		env.cpu.enter(.start_pc(32'h0000_1000));

		seg_run(4);                                          // -> 0x1010
		seg_branch_taken(2, 32'h0000_1100);                  // CF at 0x1018
		seg_branch_not_taken(1);                             // CF at 0x1104 -> 0x1108
		seg_call_to(3, 32'h0000_2000);                       // CF at 0x1114, ret = 0x1118
		seg_run(2);                                          // -> 0x2008
		seg_run(1);                                          // -> 0x200C
		seg_ret(2);                                          // CF at 0x2014 -> 0x1118
		seg_uninferable_jump(1, 32'h0000_1200);              // CF at 0x111C
		seg_branch_taken(3, 32'h0000_1300);                  // CF at 0x120C
		seg_run(2);                                          // -> 0x1308

		// ---- The loop, and why it is here -------------------------
		// A block whose terminating branch jumps back to the START of its
		// own block. This is what EVERY loop looks like on a block ingress,
		// and it is the case that separates "iaddr is the block start" from
		// "iaddr is the branch": with RepeatInstruction enabled, an encoder
		// that reports the block start as the branch's source sees
		// source == target, calls it a one-instruction spin loop and emits
		// TCODE 31/32 -- and the decoder then reconstructs one instruction
		// per iteration instead of three. Mutation M2 does exactly that.
		//   0x1308, 0x130C linear
		//   0x1310        branch taken -> 0x1308
		repeat (3) seg_branch_taken(2, 32'h0000_1308);
		seg_run(2);                                          // loop exit body

		env.cpu.idle(50);
		env.cpu.exit_trace();

		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(10000);

		if (env.cpu.event_count() == 0)
			$error("[block_tip_tb] cpu_model event log is empty");
		else
			$display("[block_tip_tb] cpu_model logged %0d events", env.cpu.event_count());

		if (env.atb_bytes_seen == 0)
			$error("[block_tip_tb] no ATB bytes observed - encoder produced nothing");
		else
			$display("[block_tip_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		env.cpu.dump_events();
		// Machine-read by scripts/cli_blocktip_test.sh -- one line, fixed shape.
		$display("[block_tip_tb] WITNESS beats=%0d halfwords=%0d max_beat_hw=%0d events=%0d",
		         beats_retiring, halfwords_seen, max_beat_hw, env.cpu.event_count());
		$display("[block_tip_tb] PASS");
		$finish;
	end

	initial begin
		#5ms;
		$error("[block_tip_tb] TIMEOUT - test exceeded 5 ms wall time");
		$finish;
	end

endmodule : block_tip_tb

`default_nettype wire
