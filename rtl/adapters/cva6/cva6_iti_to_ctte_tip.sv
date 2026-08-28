// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    cva6_iti_to_ctte_tip.sv
 * @brief   Gate C2: CVA6 ITI struct (flat, from cva6_trace_wrap) ->
 *          CTTE `tip_if.master`.
 *
 * @details
 *   Thin shim: the ITI vocabulary IS the E-Trace chapter-4 vocabulary that
 *   `tip_pkg` also speaks -- the 3-bit codes 0..6 (STANDARD/EXC/INT/ERET/
 *   NONTAKEN/TAKEN/UNINF_JMP) are value-identical to the lower `tip_itype_e`
 *   codes; zero extension is the correct mapping (UNINFERABLE_JUMP=6 is
 *   treated as uninferable by the encoder: ct_L2_msg_gen JI path,
 *   GetPCInfoType=JI).
 *
 *   Convention adjustments (CTTE contract, cf. mbv_to_ctte_tip + composer):
 *    1. Trap beats (EXC/INT) drive iretire=0 -- the composer only counts
 *       ICNT when iretire=1 (`count_halfwords`), so the faulting
 *       instruction must not count as retired (the AMD 1:1 fix, matching
 *       mbv_to_ctte_tip). The CVA6 ITI delivers trap beats with
 *       iretire=1 (single_retirement.sv sets it constant 1) -> forced to 0
 *       here. iaddr of the EXC beat = the faulting PC (as delivered by the ITI).
 *    2. Idle cycles (iti_valid=0) drive itype=OTHER + iretire=0 -- the
 *       encoder evaluates itype for control flow WITHOUT an iretire gate
 *       (the MBV lesson in mbv_to_ctte_tip "drive TIP"); a stuck TAKEN_BR
 *       on an idle cycle would be fatal.
 *    3. ecause carries the exception cause on EXC, the interrupt cause on
 *       INT (mcause without the MSB; tip_icause_e/tip_ecause_e both follow
 *       the RISC-V mcause codes). Otherwise ECAUSE_NONE.
 *    4. Every unused tip_if signal is explicitly tied off (the X-poisoning
 *       lesson from tgc5b `tip.debug_mode` in the dual-core funnel
 *       bring-up).
 *
 *   iretire is a one-instruction-per-beat flag in the CTTE contract (ICNT
 *   progress = `1 << ilastsize` halfwords per iretire=1 beat) -- exactly the
 *   single-retirement form of the ITI (NrCommitPorts==1, cv32a60x/cv64a6).
 *
 *   WIDTH (R2.1): the address ports are no longer fixed at 32 bit, they
 *   follow the encoder netlist (tip_pkg::TIP_IADDRESS_WIDTH ==
 *   ct_pkg::CT_XLEN). At CT_XLEN=32 every expression is exactly the
 *   previous 32-bit expression; at 64 the same shim carries the RV64 core
 *   (cv64a6, XLEN=VLEN=64). The ITI_XLEN parameter names the width of the
 *   CORE side: it must match the encoder side, or the shim would silently
 *   truncate an address -- exactly what the elaboration contract below
 *   checks (a 64-bit core against a 32-bit netlist is the most expensive
 *   silent failure imaginable, because the result looks like a plausible
 *   low address).
 *
 *   CONTEXT (W2): optional. `ITI_CONTEXT_WIDTH = 0` (default) is exactly
 *   the previous state -- `_context` and `ctype` stay fixed at 0, the
 *   encoder sees no context and emits no FORMAT-2 ownership. When the
 *   width is named, `iti_context_i` carries the core's context identifier
 *   (for RISC-V: `satp.ASID`) and the shim produces what the CTTE contract
 *   expects:
 *
 *     - `_context` is a LEVEL (the currently valid identifier). The
 *       comparator in ct_L23_preproc_comp_filters compares it on EVERY
 *       beat -- a pulse there would be a filter that hits for exactly one
 *       instruction.
 *     - `ctype` is the PULSE "report this context now": PRECISELY (2) on
 *       the first qualifying retire after a change, and once on the very
 *       first retire after reset (otherwise a decoder never learns the
 *       INITIAL context -- the composer does report an ownership at a
 *       sync, but with FORMAT=0, i.e. without a context value).
 *
 *   The port has a default (`'0`) so existing instantiations without
 *   context (the rtl/board_kv260 board wrappers, RV32 sim) stay unchanged:
 *   they do not name the port and get the zeros they would already have
 *   tied off today. The width, however, MUST be named when context is
 *   wanted, and it must match the encoder width -- the same clamp as
 *   ITI_XLEN, for the same reason: an identifier that is too wide would be
 *   silently truncated and the stream would name the wrong process.
 *
 *   ITYPE REFINEMENT (I1): optional, `ITI_ITYPE_REFINE = 0` (default) is
 *   exactly the previous state -- the 3-bit ITI code is zero-extended, and
 *   every existing branch (RV32 board, MicroBlaze V neighborhood, every
 *   green run today) stays bit-for-bit unchanged. With 1,
 *   `cva6_riscv_itype_refine` reconstructs the CALL/RETURN/CO_ROUTINE_SWAP
 *   codes from `iti_insn_i` that the ITI CANNOT express (ITYPE_LEN=3, and
 *   the `itype_detector` does not even see rd/rs1) -- without it the
 *   encoder's implicit-return folding path is unreachable and `ret_sp`
 *   never leaves 0 (finding B-W4-1/N1).
 *
 *   `iti_insn_i` has a default ('0) so existing instantiations can omit
 *   the port. An unconnected port with refinement turned on would,
 *   however, be a silent misclassifier (every instruction would look like
 *   a 16-bit `c.addi4spn` with rd=x0), hence the runtime assertion below:
 *   at REFINE=1, a valid beat must eventually see a nonzero word.
 *
 *   ITI_XLEN has NO default (R2.1c, audit requirement B-2). The original
 *   default `TIP_IADDRESS_WIDTH` made the contract below tautological: an
 *   instantiation that passes nothing inherits the encoder width by
 *   definition and can never violate the check -- and it was exactly the
 *   parameter-less instantiations (the RV32 board leg) that were left
 *   unprotected. Without a default there are TWO clamps instead of one:
 *     1. "you must name the core width" -- an instantiation that omits the
 *        parameter fails elaboration hard and tool-independently
 *        ("parameter 'ITI_XLEN' has no actual or default value", an LRM
 *        rule, not a $fatal in an initial block that a synthesis run could
 *        skip over). A 32-bit core can no longer silently slip onto a
 *        64-bit netlist.
 *     2. "what you name must match" -- the $fatal below, now reachable.
 */
module cva6_iti_to_ctte_tip
	import tip_pkg::*;
#(
	// Address width of the ITI/core side (== CVA6Cfg.XLEN). NO default, see
	// header comment: every instantiation must name its core's width.
	parameter int unsigned ITI_XLEN,
	// Width of the core side's context identifier. 0 = no context (the
	// previous state); otherwise it must equal TIP_CONTEXT_WIDTH.
	parameter int unsigned ITI_CONTEXT_WIDTH = 0,
	// itype refinement from the instruction word (I1). 0 = the previous
	// state (pure zero extension of the 3-bit ITI code).
	parameter bit          ITI_ITYPE_REFINE  = 1'b0,
	// Link-register set and RV32C `c.jal` detection for the refinement;
	// meaning documented in cva6_riscv_itype_refine.sv.
	parameter logic [31:0] ITI_LINK_REG_MASK = 32'h0000_0022,
	parameter bit          ITI_SUPPORT_C_JAL = 1'b0
) (
	input uwire logic clk_i,   // assertions only
	input uwire logic rst_ni,

	input uwire logic                 iti_valid_i,
	input uwire logic [31:0]          iti_iretire_i,
	input uwire logic                 iti_ilastsize_i,
	input uwire logic [2:0]           iti_itype_i,
	// ITI cause is 5 bit (iti_pkg::CAUSE_LEN) and therefore WIDER than the
	// TIP field (TIP_ECAUSE_WIDTH, 4 today). That is the core side, not the
	// encoder side -- its width stays fixed here, the narrowing happens
	// visibly (and guarded) below.
	input uwire logic [4:0]           iti_cause_i,
	input uwire logic [ITI_XLEN-1:0]  iti_tval_i,
	input uwire logic [1:0]           iti_priv_i,
	input uwire logic [ITI_XLEN-1:0]  iti_iaddr_i,
	input uwire logic [63:0]          iti_cycles_i,
	// Context identifier (RISC-V: satp.ASID). Default '0 so instantiations
	// without context can omit the port; the width is at least 1 because a
	// 0-wide port does not elaborate.
	input uwire logic [((ITI_CONTEXT_WIDTH > 0) ? ITI_CONTEXT_WIDTH : 1)-1:0] iti_context_i = '0,
	// Raw instruction word of the BEAT (cva6_trace_wrap.rvfi_insn_o). Only
	// evaluated at ITI_ITYPE_REFINE=1; default '0 keeps existing
	// instantiations unchanged.
	input uwire logic [31:0]          iti_insn_i = '0,

	tip_if.master tip
);

	localparam logic [2:0] ITI_EXC = 3'd1;
	localparam logic [2:0] ITI_INT = 3'd2;
	localparam bit         CTX_EN  = (ITI_CONTEXT_WIDTH > 0);

	// Contract core <-> encoder netlist. A mismatch is not a warning-level
	// event: xelab reports a port width difference only as a warning, and
	// the trace would look fully plausible afterwards. Reachable only since
	// ITI_XLEN lost its default and the instantiations spell out their core
	// width (R2.1c/B-2); the counter-check runs in the RV64 unit testbench
	// with an XLEN probe.
	initial begin
		if (ITI_XLEN != TIP_IADDRESS_WIDTH)
			$fatal(1, "cva6_iti_to_ctte_tip: ITI_XLEN=%0d != TIP_IADDRESS_WIDTH=%0d (encoder built with CT_XLEN=%0d) -- addresses would be silently truncated.",
			       ITI_XLEN, TIP_IADDRESS_WIDTH, TIP_IADDRESS_WIDTH);
		// The same clamp for context (W2). Only when a width is named:
		// ITI_CONTEXT_WIDTH=0 means "no context" and is allowed against any
		// encoder width.
		if (CTX_EN && (ITI_CONTEXT_WIDTH != TIP_CONTEXT_WIDTH))
			$fatal(1, "cva6_iti_to_ctte_tip: ITI_CONTEXT_WIDTH=%0d != TIP_CONTEXT_WIDTH=%0d (encoder built with CT_CONTEXT_WIDTH=%0d) -- the context identifier would be silently truncated and the stream would name the wrong process.",
			       ITI_CONTEXT_WIDTH, TIP_CONTEXT_WIDTH, TIP_CONTEXT_WIDTH);
	end

	uwire logic is_trap = iti_valid_i && (iti_itype_i == ITI_EXC || iti_itype_i == ITI_INT);

	// ecause narrowing 5 -> TIP_ECAUSE_WIDTH bit, named once instead of as a
	// part-select in the data path: at TIP_ECAUSE_WIDTH=4 this is exactly
	// the previous iti_cause_i[3:0], at the 6-bit variant (X8b) it would be
	// a zero extension -- and a fixed index [3:0] would then be wrong.
	// The assignment sits deliberately in its own net rather than as a cast
	// in the expression (XSIM 2026.1 finding L2: a cast directly in an
	// argument is mistranslated with -debug off).
	uwire tip_ecause_t ecause_narrow = tip_ecause_t'(iti_cause_i);

	// --- itype (I1) ------------------------------------------------------
	// At REFINE=0 exactly the previous expression (zero extension), so the
	// default build stays bit-for-bit unchanged; at 1 the 4-bit
	// classification reconstructed from the instruction word.
	uwire [TIP_ITYPE_WIDTH-1:0] itype_eff;

	// The refine instance sits at MODULE scope, not inside a generate branch,
	// and drives a variable, not a uwire. Both are deliberate detours around
	// one xelab --debug off elaboration defect (probed 2026-08-17, same
	// family as XSIM finding L2 in this file's history):
	//   - output port -> uwire inside a generate branch reads constant X
	//     (the instance's own out was 1001 while the net read X);
	//   - output port -> variable inside a generate branch lags one clock
	//     (the unit bench then sees vector n-1's answer for vector n).
	// At module scope with a variable sink -- the exact connection style the
	// unit bench uses for its sibling instance -- the value is correct.
	// --debug typical makes both symptoms vanish, which is how they are
	// pinned on the tool, not the RTL.
	//
	// At REFINE=0 the instance is elaborated but its output is unused: the
	// select below folds to the pure zero extension at elaboration time, so
	// the DEFAULT BUILD'S BEHAVIOUR is exactly the previous expression and
	// synthesis prunes the dead instance. (The earlier wording promised a
	// bit-for-bit identical netlist; after pruning that still holds for
	// everything reachable from the outputs.)
	logic [TIP_ITYPE_WIDTH-1:0] itype_refined;
	cva6_riscv_itype_refine #(
		.LINK_REG_MASK (ITI_LINK_REG_MASK),
		.SUPPORT_C_JAL (ITI_SUPPORT_C_JAL)
	) u_itype_refine (
		.insn      (iti_insn_i),
		.iti_itype (iti_itype_i),
		.itype     (itype_refined)
	);

	// Idle beats fall back to the passthru value: the refinement is a
	// function of iti_insn_i, and between retires that wire may carry
	// anything (in this unit bench: X). The TIP contract (verification
	// table 2) promises no X/Z on TIP outputs after reset, and the
	// unconditional X guard below enforces it. Consumers only read itype on
	// retire beats (iti_valid_i=1), so no consumed value changes; idle
	// behaves exactly like the REFINE=0 build.
	assign itype_eff = (ITI_ITYPE_REFINE && iti_valid_i)
	                 ? itype_refined
	                 : {1'b0, iti_itype_i};

	// itype_eff cast to the enum, named once instead of inline in the
	// ternary below -- the same L2 clamp as ecause_narrow above. Measured
	// while wiring up the migrated unit testbenches (2026-08-17,
	// TraceEncoder consolidation): with the cast left inline
	// (`tip.itype = iti_valid_i ? tip_itype_e'(itype_eff) : OTHER;`), xelab
	// --debug off (this repo's standard cli-gate invocation) made the
	// verification-table-2 X-guard below fire on every REFINE=1 valid beat
	// (180/180 in tb_itype_refine_unit) even though the value read back
	// correct one time step later and every functional check passed --
	// exactly the L2 signature. --debug typical does not reproduce it,
	// confirming the compile mode as the trigger. Named net: 0/180.
	uwire tip_itype_e itype_now = tip_itype_e'(itype_eff);

	// --- Context (W2) ------------------------------------------------------
	// Qualifying beat = a RETIRE. The context change is reported on this
	// edge, not on the CSR write edge: the encoder hangs its ownership on a
	// processed retire, a pulse on an idle cycle (iti_valid=0) would be lost.
	uwire logic ctx_beat = iti_valid_i && (iti_iretire_i != '0);

	tip_context_t CtxSeen    = '0;
	logic         CtxHasSeen = 1'b0;   // first retire after reset still open

	// tip_context_t'(...) instead of a part-select: at ITI_CONTEXT_WIDTH ==
	// TIP_CONTEXT_WIDTH (enforced by the clamp above when CTX_EN) this is
	// the identity, at CTX_EN=0 the 1-bit zero. The cast sits in its own
	// net, not in the argument (XSIM 2026.1 finding L2).
	uwire tip_context_t ctx_now = CTX_EN ? tip_context_t'(iti_context_i) : '0;
	uwire logic ctx_report = CTX_EN && ctx_beat
	                      && (!CtxHasSeen || (ctx_now != CtxSeen));

	always_ff @(posedge clk_i) begin
		if (!rst_ni) begin
			CtxSeen    <= '0;
			CtxHasSeen <= 1'b0;
		end else if (CTX_EN && ctx_beat) begin
			CtxSeen    <= ctx_now;
			CtxHasSeen <= 1'b1;
		end
	end

	always_comb begin
		// Control flow
		tip.itype     = iti_valid_i ? itype_now : OTHER;
		tip.iretire   = (iti_valid_i && !is_trap) ? tip_iretire_t'(1) : '0;
		tip.ilastsize = tip_ilastsize_t'(iti_ilastsize_i);
		tip.iaddr     = iti_iaddr_i;
		tip.ecause    = is_trap ? tip_ecause_e'(ecause_narrow) : ECAUSE_NONE;
		tip.tval      = (iti_valid_i && iti_itype_i == ITI_EXC) ? iti_tval_i : '0;
		tip.priv      = tip_priv_t'(iti_priv_i);
		tip._time     = tip_time_t'(iti_cycles_i);

		// Context: level + report pulse (W2). At ITI_CONTEXT_WIDTH=0 both
		// are constant 0 -- exactly the state before W2, and the encoder
		// never emits a single FORMAT-2 ownership.
		tip._context  = ctx_now;
		tip.ctype     = ctx_report ? tip_ctype_t'(2)     // PRECISELY
		                            : tip_ctype_t'(0);   // UNREPORTED
		tip.impdef    = '0;

		// Data trace unused (MVP: program flow only)
		tip.dretire   = 1'b0;
		tip.dtype     = tip_dtype_e'(0);
		tip.daddr     = '0;
		tip.dsize     = '0;
		tip.data      = '0;
		tip.sdata     = '0;
		tip.lresp     = '0;
		tip.ldata     = '0;

		// Event sideband: the core delivers none of this -> 0 (integrator
		// contract). `trigger` belongs here and was missing until R2.1 --
		// the CVA6 has no trigger/watchpoint unit at this port, so 0 is
		// correct; undriven would be X and (with InstTrigEnable set) a
		// random SYNC=6 marker in the stream.
		tip.debug_mode = 1'b0;
		tip.evti       = 1'b0;
		tip.power_down = 1'b0;
		tip.trigger    = 1'b0;
	end

	// pragma translate_off
	// Verification table §2: no X/Z on TIP outputs after reset.
	always_ff @(posedge clk_i) begin
		if (rst_ni) begin
			assert (!$isunknown(tip.itype))   else $error("cva6_iti_to_ctte_tip: X on tip.itype (itype=%b eff=%b valid=%b iti_itype=%b insn=%h)", tip.itype, itype_eff, iti_valid_i, iti_itype_i, iti_insn_i);
			assert (!$isunknown(tip.iretire)) else $error("cva6_iti_to_ctte_tip: X on tip.iretire");
			assert (!$isunknown({tip.debug_mode, tip.evti, tip.power_down, tip.trigger}))
				else $error("cva6_iti_to_ctte_tip: X on the event sideband");
			// The context is a LEVEL and is compared on every beat -- an X
			// in it is not cosmetic, it is a filter whose hit is undefined.
			assert (!$isunknown({tip._context, tip.ctype}))
				else $error("cva6_iti_to_ctte_tip: X on tip._context/ctype");
			if (iti_valid_i)
				assert (!$isunknown(iti_iaddr_i)) else $error("cva6_iti_to_ctte_tip: X on iaddr while valid");
			// ITI contract (C1): single-retirement delivers iretire==1 per beat
			if (iti_valid_i && !is_trap)
				assert (iti_iretire_i == 32'd1)
					else $error("cva6_iti_to_ctte_tip: ITI iretire=%0d != 1", iti_iretire_i);
			// No SILENT narrowing of the cause: the TIP field is narrower
			// than the ITI cause. Under RV64/Sv39 all observed codes stay
			// <= 15 (mcause exceptions 0..15, interrupt codes 0..15), so the
			// narrowing is lossless -- but confirmed, not assumed.
			// (The sentinel value ECAUSE_NONE itself is NOT checked here:
			// where it sits in the real cause space is a property of the
			// connected tip_pkg build, not of the adapter -- X8a placed it
			// on an architecturally reserved code in the current encoder,
			// older netlists still carry the collision.)
			// I1: with refinement turned on, the instruction word MUST
			// actually be present. A forgotten port would otherwise be the
			// most expensive silent failure of this package: '0 is an
			// ILLEGAL RISC-V encoding but looks like a 16-bit instruction
			// with rd=x0 -- no call would ever be pushed, the stream would
			// stay decodable, and the measurement "IR does nothing" would
			// be a wiring artifact. A retiring beat always has an encoding
			// != 0 (neither 16'h0000 nor 32'h00000000 is legal); trap beats
			// are exempt, their word is a don't-care.
			if (ITI_ITYPE_REFINE && iti_valid_i && !is_trap)
				assert (iti_insn_i != 32'd0)
					else $error("cva6_iti_to_ctte_tip: ITI_ITYPE_REFINE=1, but iti_insn_i=0 at iaddr=%h -- port not connected?", iti_iaddr_i);
			if (is_trap)
				assert (ecause_narrow == iti_cause_i)
					else $error("cva6_iti_to_ctte_tip: ITI cause=%0d does not fit in %0d-bit ecause",
					            iti_cause_i, TIP_ECAUSE_WIDTH);
		end
	end
	// pragma translate_on

endmodule

`default_nettype wire
