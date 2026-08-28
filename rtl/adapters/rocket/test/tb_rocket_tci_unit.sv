// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author  Alexander Weiss <aweiss@accemic.com>
 *
 * @file    tb_rocket_tci_unit.sv
 * @brief   R3.1a: unit testbench for rocket_tci_to_ctte_tip.
 * @details Interface-driven (no Rocket generated netlist, which was built
 *   in parallel package R3.0): vectors follow the TraceCoreInterface field
 *   set as characterized in package R0-A3 §3.3. Covered:
 *    - all 16 TraceItype codes (incl. reserved 6/7) against a testbench-own
 *      expectation table (double bookkeeping of the R0-A3 table),
 *    - clamp 1 (trap beats EXC and INT -> iretire=0, ecause/tval gating),
 *    - clamp 2 on both sides in ONE elaboration: dut_a default
 *      (MAP_TRAP_RETURN_TO_ERET=1, 13->EXCEPTION_IR) vs. dut_b override
 *      (=0, 13->RETURN),
 *    - taken/not-taken, compressed/non-compressed ilastsize, idle cycles
 *      (including directly after a trap), high 64-bit addresses/tval/cause
 *      (truncation counters sim_trunc_*_cnt of both DUTs; warnings only on
 *      dut_a -- dut_b shows TRUNC_WARN_EN=0),
 *    - ctx/priv (incl. the debug bit)/time pass-through, full tie-off incl.
 *      tip.trigger (finding A1), X-freedom after reset.
 *   Self-checking, counters + failing-vector printout, "### TB_PASS" at the end.
 *
 *   M3 (2026-08-08) -- CONTEXT PATH. A third instance dut_c with
 *   TCI_CONTEXT_WIDTH = TIP_CONTEXT_WIDTH (context ON) next to dut_a/dut_b,
 *   which keep the default 0 and thereby PROVE that the default is
 *   bit-for-bit the previous state. What is checked is what an ownership
 *   filter needs:
 *    - the key is satp.PPN [43:0] and NOT MODE/ASID (vector Vc3 changes
 *      only MODE+ASID -> neither the value nor the pulse may move),
 *    - `_context` is a LEVEL (follows even on an idle cycle),
 *    - `ctype` is a PULSE on the first qualifying beat after reset and
 *      after every change -- and ONLY there (vector Vc6: an idle cycle with
 *      a changed context must NOT report),
 *    - anti-constancy guard: at least 2 DIFFERENT values must have been
 *      observed on tip_c._context. A shim whose context is in truth
 *      constant would otherwise pass every single check that only asks
 *      "value == expectation" as long as the expectation itself is 0.
 *   Written width-neutrally: the same testbench runs against a pinned
 *   2-bit encoder build and against a 44-bit build (`CtxWidth = 44`).
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module tb_rocket_tci_unit;
	import tip_pkg::*;

	logic clk = 0;
	logic rst_n = 0;
	always #5 clk = ~clk;

	logic        iretire;
	logic [63:0] iaddr;
	logic [3:0]  itype;
	logic        ilastsize;
	logic [2:0]  priv;
	logic [63:0] ctx;
	logic [63:0] tval;
	logic [63:0] cause;
	logic [63:0] ttime;   // 'time' is an SV keyword

	tip_if tip_a ();
	tip_if tip_b ();
	tip_if tip_c ();

	// dut_a: parameter default (clamp 2 active, truncation warnings on)
	rocket_tci_to_ctte_tip dut_a (
		.clk_i(clk), .rst_ni(rst_n),
		.tci_iretire_i(iretire), .tci_iaddr_i(iaddr), .tci_itype_i(itype),
		.tci_ilastsize_i(ilastsize), .tci_priv_i(priv), .tci_ctx_i(ctx),
		.tci_tval_i(tval), .tci_cause_i(cause), .tci_time_i(ttime),
		.tip(tip_a)
	);

	// dut_b: override -- 13 stays RETURN, warnings off (the counter still
	// counts, which proves the warning/detector split)
	rocket_tci_to_ctte_tip #(
		.MAP_TRAP_RETURN_TO_ERET(1'b0),
		.TRUNC_WARN_EN(1'b0)
	) dut_b (
		.clk_i(clk), .rst_ni(rst_n),
		.tci_iretire_i(iretire), .tci_iaddr_i(iaddr), .tci_itype_i(itype),
		.tci_ilastsize_i(ilastsize), .tci_priv_i(priv), .tci_ctx_i(ctx),
		.tci_tval_i(tval), .tci_cause_i(cause), .tci_time_i(ttime),
		.tip(tip_b)
	);

	// dut_c (M3): context ON. The width comes from the encoder netlist, not
	// a literal -- the same testbench therefore runs against 2 bit and
	// against 44 bit. SATP_PPN_LIVE_WIDTH stays at the measured default 22;
	// at 2-bit encoder width the shim correspondingly emits its
	// non-uniqueness warning (expected, not a failure).
	rocket_tci_to_ctte_tip #(
		.TCI_CONTEXT_WIDTH(TIP_CONTEXT_WIDTH)
	) dut_c (
		.clk_i(clk), .rst_ni(rst_n),
		.tci_iretire_i(iretire), .tci_iaddr_i(iaddr), .tci_itype_i(itype),
		.tci_ilastsize_i(ilastsize), .tci_priv_i(priv), .tci_ctx_i(ctx),
		.tci_tval_i(tval), .tci_cause_i(cause), .tci_time_i(ttime),
		.tip(tip_c)
	);

	int errors  = 0;
	int checks  = 0;
	int vectors = 0;

	task check(string what, logic cond);
		checks++;
		if (cond !== 1'b1) begin   // !== also catches X comparisons as a FAIL
			errors++;
			$display("### FAIL [V%0d]: %s (itype=%0d iretire=%0d)", vectors, what, itype, iretire);
		end
	endtask

	// M3: `ctype` is a pulse that collapses again on the clock edge (CtxSeen
	// takes on the new value there). What matters is the value the encoder
	// latches AT the edge -- i.e. the state BEFORE it. The testbench
	// therefore samples it before @(posedge) and checks the sampled
	// quantities, not the ones visible after the edge. (The rest of the
	// shim is purely combinational from held inputs and may still be read
	// after the edge.)
	tip_ctype_t   ctype_c_e;
	tip_context_t ctx_c_e;
	tip_ctype_t   ctype_a_e, ctype_b_e;

	task drive(logic dv, logic [3:0] dt, logic [63:0] dc, logic [63:0] dtv, logic [63:0] da);
		iretire = dv; itype = dt; cause = dc; tval = dtv; iaddr = da;
		#1;                       // let combinational logic settle
		ctype_c_e = tip_c.ctype;  // the state at the coming edge
		ctx_c_e   = tip_c._context;
		ctype_a_e = tip_a.ctype;
		ctype_b_e = tip_b.ctype;
		@(posedge clk); #1;
		vectors++;
	endtask

	// Double bookkeeping of the mapping table (R0-A3 §3.3 TraceItype ->
	// tip_itype_e, source: the shim's header table) -- deliberately
	// literal, not derived via a cast.
	function tip_itype_e exp_map(input logic [3:0] c);
		case (c)
			4'd0:  exp_map = OTHER;                  // ITNothing
			4'd1:  exp_map = EXCEPTION_TRAP;         // ITException
			4'd2:  exp_map = INTERRUPT;              // ITInterrupt
			4'd3:  exp_map = EXCEPTION_IR;           // ITExcReturn
			4'd4:  exp_map = NOT_TAKEN_BRANCH;       // ITBrNTaken
			4'd5:  exp_map = TAKEN_BRANCH;           // ITBrTaken
			4'd6:  exp_map = UNINFERABLE_JUMP;       // reserved @4-bit
			4'd7:  exp_map = RESERVED;               // reserved
			4'd8:  exp_map = UNINFERABLE_CALL;       // ITUnCall
			4'd9:  exp_map = INFERRABLE_CALL;        // ITInCall
			4'd10: exp_map = UNINFERABLE_TAIL_CALL;  // ITUnTail
			4'd11: exp_map = INFERRABLE_TAIL_CALL;   // ITInTail
			4'd12: exp_map = CO_ROUTINE_SWAP;        // ITCoSwap
			4'd13: exp_map = RETURN;                 // ITReturn (clamp 2: dut_a -> EXCEPTION_IR)
			4'd14: exp_map = OTHER_UNINFERABLE_JUMP; // ITUnJump (jalr)
			4'd15: exp_map = OTHER_INFERABLE_JUMP;   // ITInJump (jal)
		endcase
	endfunction

	tip_itype_e exp_a, exp_b;
	logic       exp_ir;

	// --- M3 context helpers ----------------------------------------------
	// Double bookkeeping of D-R-8: the key is satp.PPN = bits [43:0] of the
	// satp image, of which the lower TIP_CONTEXT_WIDTH bits. MODE [63:60]
	// and ASID [59:44] do NOT participate.
	function automatic tip_context_t exp_ctx(input logic [63:0] satp);
		return tip_context_t'(satp[43:0]);
	endfunction

	// Anti-constancy guard: which DIFFERENT values did tip_c._context
	// actually carry in this run? A constant context (the error a plain
	// "value == expectation" test with expectation 0 would not catch) ends
	// up at 1 here.
	tip_context_t ctx_vals [$];
	task automatic note_ctx();
		foreach (ctx_vals[i]) if (ctx_vals[i] === tip_c._context) return;
		ctx_vals.push_back(tip_c._context);
	endtask

	// satp images {MODE[63:60], ASID[59:44], PPN[43:0]}. The PPN values are
	// chosen to already differ in the LOWER two bits -- otherwise the
	// changes would be invisible on a 2-bit encoder and the test would
	// prove nothing (except Vc5, whose whole point is exactly that).
	localparam logic [63:0] CTX_A = 64'h8000_0000_0000_1235; // Sv39, PPN 0x1235
	// ASID sits at [59:44], NOT at [47:32]: 0xBEEF << 44 = 0x0BEE_F000_0000_0000.
	// (The first version of this vector had the ASID shifted by 12 bits and
	// thereby wrote into the PPN -- unnoticed at 2 bit, immediately red at
	// the 44-bit run. That is exactly why the second width exists.)
	localparam logic [63:0] CTX_B = 64'h0BEE_F000_0000_1235; // ONLY MODE+ASID differ
	localparam logic [63:0] CTX_C = 64'h8000_0000_0000_1236; // PPN 0x1236
	localparam logic [63:0] CTX_D = 64'h8000_0000_0040_1236; // + PPN bit 22 (> live)
	localparam logic [63:0] CTX_E = 64'h8000_0000_0000_1239; // PPN 0x1239
	localparam logic [63:0] CTX_F = 64'h8000_0000_0000_123A; // PPN 0x123A
	// Vc5 is the only width-dependent expectation: PPN bit 22 lies above
	// the measured live width (22) and therefore above any encoder with
	// CT_CONTEXT_WIDTH <= 22 -- invisible at 2 bit, a change at 44 bit.
	// This line makes exactly that narrowing VISIBLE.
	localparam bit CTX_D_VISIBLE = (TIP_CONTEXT_WIDTH > 22);
	int unsigned exp_reports;

	// Truncation expectations are width-dependent (X2/X8): a 64-bit build
	// has no address loss any more, a 6-bit ecause no cause loss. The
	// vectors themselves stay unchanged.
	localparam int unsigned EXP_TRUNC_ADDR  = (TIP_IADDRESS_WIDTH < 64) ? 1 : 0;
	localparam int unsigned EXP_TRUNC_CAUSE = (TIP_ECAUSE_WIDTH   <  5) ? 1 : 0;

	initial begin
		iretire = 0; iaddr = '0; itype = '0; ilastsize = 0;
		priv = '0; ctx = '0; tval = '0; cause = '0; ttime = '0;
		repeat (3) @(posedge clk);
		rst_n = 1;
		@(posedge clk); #1;

		// X-freedom after reset (both DUTs, incl. sideband + trigger)
		check("reset no X (a)", !$isunknown({tip_a.itype, tip_a.iretire, tip_a.ilastsize,
		                                     tip_a.iaddr, tip_a.dretire, tip_a.debug_mode,
		                                     tip_a.evti, tip_a.power_down, tip_a.trigger}));
		check("reset no X (b)", !$isunknown({tip_b.itype, tip_b.iretire, tip_b.iaddr,
		                                     tip_b.trigger}));
		check("reset no X (c, incl. context)",
		      !$isunknown({tip_c.itype, tip_c.iretire, tip_c._context, tip_c.ctype}));
		$display("### CFG TIP_CONTEXT_WIDTH=%0d TIP_IADDRESS_WIDTH=%0d TIP_ECAUSE_WIDTH=%0d",
		         TIP_CONTEXT_WIDTH, TIP_IADDRESS_WIDTH, TIP_ECAUSE_WIDTH);

		// V1 -- idle cycle with a stuck itype: OTHER + iretire=0
		drive(0, 4'd5, '0, '0, 64'h0000_0000_8000_0100);
		check("idle itype==OTHER (a)", tip_a.itype == OTHER);
		check("idle itype==OTHER (b)", tip_b.itype == OTHER);
		check("idle iretire==0", tip_a.iretire == '0 && tip_b.iretire == '0);
		check("idle ecause==NONE", tip_a.ecause == ECAUSE_NONE);

		// V2..V17 -- all 16 TraceItype codes, valid, against the
		// expectation table; clamp 2 on both sides; iaddr pass-through
		ilastsize = 1'b1; priv = 3'b011;
		for (int i = 0; i < 16; i++) begin
			drive(1, 4'(i), '0, '0, 64'h0000_0000_8000_0000 + 64'(i) * 4);
			exp_b  = exp_map(4'(i));
			exp_a  = (i == 13) ? EXCEPTION_IR : exp_map(4'(i));
			exp_ir = !(i == 1 || i == 2);   // clamp 1
			check($sformatf("code %0d itype (a, remap on)", i),  tip_a.itype == exp_a);
			check($sformatf("code %0d itype (b, remap off)", i), tip_b.itype == exp_b);
			check($sformatf("code %0d iretire (a)", i), tip_a.iretire == tip_iretire_t'(exp_ir));
			check($sformatf("code %0d iretire (b)", i), tip_b.iretire == tip_iretire_t'(exp_ir));
			check($sformatf("code %0d iaddr", i),
			      tip_a.iaddr == tip_iaddr_t'(64'h0000_0000_8000_0000 + 64'(i) * 4));
			// M3: the FIRST qualifying beat after reset reports the initial
			// context (otherwise a decoder never learns it); every
			// following beat with an unchanged ctx must NOT report.
			if (i == 0) check("first beat after reset reports context (dut_c)",
			                  ctype_c_e == tip_ctype_t'(2));
			else        check($sformatf("code %0d no pulse without a change (dut_c)", i),
			                  ctype_c_e == tip_ctype_t'(0));
			check($sformatf("code %0d dut_a without context (default off)", i),
			      tip_a._context == '0 && ctype_a_e == tip_ctype_t'(0));
			if (i != 1 && i != 2) begin
				check($sformatf("code %0d ecause==NONE", i), tip_a.ecause == ECAUSE_NONE);
				check($sformatf("code %0d tval==0", i), tip_a.tval == '0);
			end
		end

		// EXC detail: ecause/tval active, iretire forcing
		drive(1, 4'd1, 64'd2, 64'h0000_0000_FFFF_FFFF, 64'h0000_0000_8000_0040); // illegal instr
		check("EXC itype", tip_a.itype == EXCEPTION_TRAP);
		check("EXC iretire==0 (clamp 1)", tip_a.iretire == '0 && tip_b.iretire == '0);
		check("EXC ecause==2", tip_a.ecause == tip_ecause_e'(4'd2));
		check("EXC tval", tip_a.tval == tip_iaddr_t'(64'h0000_0000_FFFF_FFFF));
		drive(1, 4'd1, 64'd11, '0, 64'h0000_0000_8000_0044);                     // ecall M
		check("EXC ecall ecause==11", tip_a.ecause == tip_ecause_e'(4'd11));

		// INT detail: MSB (interrupt flag) is dropped, tval gate
		drive(1, 4'd2, 64'h8000_0000_0000_0007, 64'hDEAD_BEEF_DEAD_BEEF, 64'h0000_0000_8000_0048);
		check("INT itype", tip_a.itype == INTERRUPT);
		check("INT iretire==0 (clamp 1)", tip_a.iretire == '0 && tip_b.iretire == '0);
		check("INT ecause==7 (MSB drop)", tip_a.ecause == tip_ecause_e'(4'd7));
		check("INT tval==0 (gate)", tip_a.tval == '0);
		drive(1, 4'd2, 64'h8000_0000_0000_000B, '0, 64'h0000_0000_8000_004C);
		check("INT ext ecause==11", tip_a.ecause == tip_ecause_e'(4'd11));

		// Truncation: high 64-bit address (a warning from dut_a is
		// expected, dut_b stays silent -- TRUNC_WARN_EN=0), counter on both
		drive(1, 4'd5, '0, '0, 64'hFFFF_FFFF_8000_1000);
		check("iaddr truncation value", tip_a.iaddr == tip_iaddr_t'(64'hFFFF_FFFF_8000_1000));
		// Truncation: high tval on EXC
		drive(1, 4'd1, 64'd5, 64'hFFFF_FFFF_0000_0800, 64'h0000_0000_8000_0050);
		check("tval truncation value", tip_a.tval == tip_iaddr_t'(64'hFFFF_FFFF_0000_0800));
		// Truncation: cause > 15 (RVH guest page fault 20 -- does not fit in 4 bit)
		drive(1, 4'd1, 64'd20, '0, 64'h0000_0000_8000_0054);
		check("cause truncation value", tip_a.ecause == tip_ecause_e'(tip_ecause_t'(64'd20)));

		// ilastsize: compressed (0) / non-compressed (1)
		ilastsize = 1'b0;
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0058);
		check("ilastsize compressed", tip_a.ilastsize == tip_ilastsize_t'(0));
		ilastsize = 1'b1;
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_005A);
		check("ilastsize non-compressed", tip_a.ilastsize == tip_ilastsize_t'(1));

		// ================= M3: context path (dut_c) =======================
		// Precondition, literal: up to here ctx was constant 0, so dut_c's
		// pulse counter stands at EXACTLY 1 (the initial pulse from the
		// code loop). At 0 the shim never reports; higher, it reports
		// without a change.
		check("dut_c: exactly 1 pulse before the context section",
		      dut_c.sim_ctx_report_cnt == 1);
		note_ctx();

		// Vc1 -- first real change (PPN 0 -> 0x1235): the level follows, a pulse
		ctx = CTX_A;
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0080);
		check("Vc1 level == PPN key",  ctx_c_e == exp_ctx(CTX_A));
		check("Vc1 pulse PRECISELY",   ctype_c_e == tip_ctype_t'(2));
		check("Vc1 dut_a/b stay context-free",
		      tip_a._context == '0 && ctype_a_e == tip_ctype_t'(0)
		   && tip_b._context == '0 && ctype_b_e == tip_ctype_t'(0));
		note_ctx();

		// Vc2 -- the same context once more: NO second pulse
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0084);
		check("Vc2 level unchanged", ctx_c_e == exp_ctx(CTX_A));
		check("Vc2 no pulse",        ctype_c_e == tip_ctype_t'(0));

		// Vc3 -- ONLY MODE (8->0) and ASID (0->0xBEEF) change, PPN stays.
		// This is the probe on D-R-8: the key is the PPN. If the shim took
		// the whole satp word or the ASID, it would report here.
		ctx = CTX_B;
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0088);
		check("Vc3 MODE/ASID do NOT change the key",
		      ctx_c_e == exp_ctx(CTX_A));
		check("Vc3 no pulse (MODE/ASID only)", ctype_c_e == tip_ctype_t'(0));

		// Vc4 -- PPN 0x1235 -> 0x1236: a change, a pulse
		ctx = CTX_C;
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_008C);
		check("Vc4 level follows",  ctx_c_e == exp_ctx(CTX_C));
		check("Vc4 pulse",          ctype_c_e == tip_ctype_t'(2));
		note_ctx();

		// Vc5 -- the difference lies ONLY in PPN bit 22 (above this core's
		// live width). Invisible on a 2-bit encoder (no pulse), a change
		// on a 44-bit encoder. The SILENT narrowing becomes audible here:
		// at CTX_D_VISIBLE=0, two different address spaces are
		// indistinguishable in the trace.
		ctx = CTX_D;
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0090);
		check($sformatf("Vc5 pulse == %0d (TIP_CONTEXT_WIDTH=%0d)",
		                CTX_D_VISIBLE, TIP_CONTEXT_WIDTH),
		      ctype_c_e == (CTX_D_VISIBLE ? tip_ctype_t'(2) : tip_ctype_t'(0)));
		check("Vc5 level == key", ctx_c_e == exp_ctx(CTX_D));
		note_ctx();

		// Vc6 -- IDLE CYCLE with a new context: the level follows (the
		// filter compares on every beat), but NOT the pulse -- on an idle
		// cycle the composer processes nothing, the report would be lost.
		// It is deferred to the next beat (Vc7).
		ctx = CTX_E;
		drive(0, 4'd0, '0, '0, 64'h0000_0000_8000_0094);
		check("Vc6 level follows even on an idle cycle", ctx_c_e == exp_ctx(CTX_E));
		check("Vc6 NO pulse on an idle cycle",           ctype_c_e == tip_ctype_t'(0));

		// Vc7 -- the following beat catches up the report
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0098);
		check("Vc7 deferred pulse", ctype_c_e == tip_ctype_t'(2));
		note_ctx();

		// Vc8 -- a change ON a TRAP beat: tip.iretire is 0 per clamp 1, the
		// pulse still comes. Proven at the encoder side: process_now has an
		// is_trap_event arm and the ownership emission hangs off
		// tip.ctype, not tip.iretire
		// (ct_L23_preproc_composer_etip.sv:459-463 / :855).
		ctx = CTX_F;
		drive(1, 4'd1, 64'd2, 64'h0000_0000_DEAD_0000, 64'h0000_0000_8000_009C);
		check("Vc8 pulse on a trap beat", ctype_c_e == tip_ctype_t'(2));
		check("Vc8 trap beat carries iretire=0 (clamp 1)", tip_c.iretire == '0);
		check("Vc8 level follows", ctx_c_e == exp_ctx(CTX_F));
		note_ctx();

		// Total pulse count, added up literally:
		//   1 (initial) + Vc1 + Vc4 + Vc5(only if visible) + Vc7 + Vc8
		exp_reports = 5 + (CTX_D_VISIBLE ? 1 : 0);
		check($sformatf("dut_c total pulse count == %0d", exp_reports),
		      dut_c.sim_ctx_report_cnt == exp_reports);
		// Anti-constancy: a constant context would have exactly 1 value here.
		check($sformatf("anti-constancy: %0d different context values (>= 2)",
		                ctx_vals.size()), ctx_vals.size() >= 2);
		// ctx stays at CTX_F from here on (no further change -> no further
		// pulse; the count below stays exact).

		// priv pass-through incl. the debug bit (Cat(reg_debug, prv))
		priv = 3'b011;
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0060);
		check("priv M-mode", tip_a.priv == tip_priv_t'(3'b011));
		priv = 3'b100;   // reg_debug=1, prv=00
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0064);
		check("priv debug bit passed through", tip_a.priv == tip_priv_t'(3'b100));
		check("debug_mode stays 0 (contract)", tip_a.debug_mode == 1'b0);
		priv = 3'b011;

		// time pass-through 1:1 (64 bit)
		ttime = 64'hDEAD_BEEF_0123_4567;
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_0068);
		check("_time 64-bit 1:1", tip_a._time == 64'hDEAD_BEEF_0123_4567);

		// Full tie-off (incl. trigger -- finding A1) + data trace
		drive(1, 4'd0, '0, '0, 64'h0000_0000_8000_006C);
		check("dretire tie", tip_a.dretire == 1'b0);
		check("dtype/daddr/dsize/data tie", {tip_a.daddr, tip_a.dsize, tip_a.data} == '0
		                                    && tip_a.dtype == tip_dtype_e'(0));
		check("sdata/lresp/ldata tie", {tip_a.sdata, tip_a.lresp, tip_a.ldata} == '0);
		check("sideband tie incl. trigger", {tip_a.debug_mode, tip_a.evti,
		                                     tip_a.power_down, tip_a.trigger} == '0);
		check("impdef tie", tip_a.impdef == '0);
		check("sideband tie (b)", {tip_b.debug_mode, tip_b.evti,
		                           tip_b.power_down, tip_b.trigger} == '0);

		// Idle cycle directly after trap-carrying traffic
		drive(0, 4'd1, '0, '0, 64'h0000_0000_8000_0070);
		check("idle after trap itype==OTHER", tip_a.itype == OTHER);
		check("idle after trap iretire==0", tip_a.iretire == '0);

		// Truncation counters: exactly 1 iaddr/tval/cause event each,
		// PROVIDED the encoder netlist is narrower than the source. On a
		// 64-bit/6-bit build (X2/X8) the losses disappear -- the
		// expectation therefore hangs off the width, not a fixed 1.
		// dut_b counts identically (TRUNC_WARN_EN only gates the warning).
		check("counter iaddr (a)", dut_a.sim_trunc_iaddr_cnt == EXP_TRUNC_ADDR);
		check("counter tval (a)",  dut_a.sim_trunc_tval_cnt  == EXP_TRUNC_ADDR);
		check("counter cause (a)", dut_a.sim_trunc_cause_cnt == EXP_TRUNC_CAUSE);
		check("counter iaddr (b)", dut_b.sim_trunc_iaddr_cnt == EXP_TRUNC_ADDR);
		check("counter tval (b)",  dut_b.sim_trunc_tval_cnt  == EXP_TRUNC_ADDR);
		check("counter cause (b)", dut_b.sim_trunc_cause_cnt == EXP_TRUNC_CAUSE);

		// M3: the context-free instances NEVER reported -- the default
		// TCI_CONTEXT_WIDTH=0 is bit-for-bit the previous state.
		check("dut_a without context: 0 pulses", dut_a.sim_ctx_report_cnt == 0);
		check("dut_b without context: 0 pulses", dut_b.sim_ctx_report_cnt == 0);
		check("dut_a/_b _context constant 0",
		      tip_a._context == '0 && tip_b._context == '0);

		if (errors == 0)
			$display("### TB_PASS (%0d vectors, %0d checks -- itype/clamps/truncation/tie-off + context: %0d pulses, %0d different values @ %0d bit)",
			         vectors, checks, dut_c.sim_ctx_report_cnt, ctx_vals.size(),
			         TIP_CONTEXT_WIDTH);
		else begin
			$display("### TB_FAIL (%0d error(s) of %0d checks, %0d vectors)", errors, checks, vectors);
			$fatal(1);
		end
		$finish;
	end

endmodule

`default_nettype wire
