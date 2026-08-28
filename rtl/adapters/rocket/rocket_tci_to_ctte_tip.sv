// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    rocket_tci_to_ctte_tip.sv
 * @brief   R3.1a: Rocket TraceCoreInterface (flat, nGroups=1) ->
 *          CTTE `tip_if.master`.
 *
 * @details
 *   INTERFACE-DRIVEN, built WITHOUT a Rocket generated netlist (the netlist
 *   was produced in parallel, package R3.0): field set = the
 *   TraceCoreInterface fields as characterized in package R0-A3 §3.3
 *   (rocket-chip trace/TraceCoreInterface.scala, TraceCoreParams nGroups=1,
 *   iretireWidth=1, xlen=iaddrWidth=64; connection RocketCore.scala:834-854).
 *
 *   G1 STATUS (R3.2a, 2026-08-04): the R3.1a `G1-PENDING:` markers have been
 *   resolved by measurement against the generated netlist
 *   (doc/adapters/rocket_tci_semantics.adoc, tb_rocket_char +
 *   rocket_tci_check.py, TB_PASS 432 cycles + checker PASS) -- resolved
 *   points below carry `G1-CONFIRMED (R3.2a)`, real remaining gaps (only
 *   the debug-mode priv encoding) still carry `G1-PENDING:`. NEW from the
 *   measurement: upstream defect U3 -- the trace cause is
 *   `wb_reg_xcpt ? wb_reg_cause : <mem-stage cause mux, default 4>`
 *   (netlist :79663); for traps raised internally by the CSR (ecall/ebreak,
 *   wb_xcpt=0) the EXC beat carries cause=4 (data-path leftover) instead of
 *   mcause 11/3. Pipeline exceptions (illegal: cause 2, tval=instruction
 *   word) and interrupts (cause MSB bit 63) are correct. tip.ecause is
 *   therefore NOT trustworthy for ecall/ebreak -- the shim cannot fix this
 *   (no discriminating information at the interface); downstream
 *   consequence + upstream PR candidate documented in the truth table.
 *
 *   itype mapping Rocket TraceItype (4 bit) -> tip_itype_e (tip_pkg.sv):
 *   the TIP enum already carries the FULL 4-bit E-Trace vocabulary ("RISC-V
 *   Processor Trace Spec V1.0"), which Rocket's TraceItype also follows
 *   (R0-A3 §3.3) -- the mapping is 1:1 (identity). The 3-bit down-mapping
 *   from R0-A3 §3.5 path A ("codes >=8 onto the 3-bit budget, ITInJump/
 *   ITUnJump -> UNINF_JMP") does not apply: it targeted the 3-bit ITI
 *   vocabulary, not the 4-bit TIP. The only active remapping is clamp 2
 *   (13 -> 3, parameter below).
 *
 *   | Code | Rocket TraceItype (R0-A3 §3.3)     | tip_itype_e            | Emitted by the ingress? (priority chain R0-A3 §3.3) |
 *   |------|------------------------------------|------------------------|------------------------------------------------------|
 *   |  0   | ITNothing                          | OTHER                  | yes (no event / default)                            |
 *   |  1   | ITException                        | EXCEPTION_TRAP         | yes (exception)      -> clamp 1 (iretire=0)         |
 *   |  2   | ITInterrupt                         | INTERRUPT              | yes (interrupt)      -> clamp 1 (iretire=0)         |
 *   |  3   | ITExcReturn                         | EXCEPTION_IR           | NO -- trap_return goes out as 13 (suspected         |
 *   |      |                                     |                        | upstream defect, R0-A3 §3.5 defect 1)               |
 *   |  4   | ITBrNTaken                          | NOT_TAKEN_BRANCH       | yes (branch, !taken)                                |
 *   |  5   | ITBrTaken                           | TAKEN_BRANCH           | yes (branch, taken)                                 |
 *   |  6   | (reserved at itype_width_p=4)      | UNINFERABLE_JUMP       | no (E-Trace: only populated at itype_width_p=3)     |
 *   |  7   | (reserved)                         | RESERVED               | no                                                   |
 *   |  8   | Uninferable call   (ITUnCall)      | UNINFERABLE_CALL       | no (the chain classifies no calls)                  |
 *   |  9   | Inferable call     (ITInCall)      | INFERRABLE_CALL        | no                                                   |
 *   | 10   | Uninf. tail-call   (ITUnTail)      | UNINFERABLE_TAIL_CALL  | no                                                   |
 *   | 11   | Inf. tail-call     (ITInTail)      | INFERRABLE_TAIL_CALL   | no                                                   |
 *   | 12   | Co-routine swap    (ITCoSwap)      | CO_ROUTINE_SWAP        | no                                                   |
 *   | 13   | ITReturn                           | RETURN  (clamp 2!)     | yes -- but ONLY for trap_return (mret/sret)         |
 *   | 14   | ITUnJump                           | OTHER_UNINFERABLE_JUMP | yes (jalr; also a function return = jalr!)          |
 *   | 15   | ITInJump                           | OTHER_INFERABLE_JUMP   | yes (jal)                                           |
 *
 *   G1-CONFIRMED (R3.2a): the emission set observed on the generated
 *   netlist = {0,1,2,4,5,13,14,15}; codes 3/6/7/8..12 were never observed
 *   in any beat, 13 EXCLUSIVELY at mret PCs (4/4), function returns ran as
 *   14 (truth table, checker gates "unexpected itype"/"13 only at xRET").
 *   Exact Scala identifiers of codes 8..12 remain a [B]-source, R0-A3 §3.3
 *   (not visible in the Verilog netlist; TraceCoreIngress :76861-76886
 *   simply never emits them). Codes that are never emitted are still
 *   passed through 1:1 (robustness against upstream changes; the encoder
 *   handles them E-Trace-conformantly, GetPCInfoType).
 *
 *   Convention adjustments (CTTE contract, cf. cva6_iti_to_ctte_tip +
 *   mbv_to_ctte_tip + composer):
 *    1. CLAMP 1 -- trap beats drive iretire=0: Rocket sets
 *       `iretire := valid` with `valid = wb_valid || wb_xcpt` (R0-A3
 *       §3.3/§3.5 defect 2), i.e. trap beats carry iretire=1. The composer
 *       counts ICNT at iretire=1 (`count_halfwords`) -- the faulting
 *       instruction must not count as retired (the AMD 1:1 fix, the same
 *       clamp as in the CVA6 shim cva6_iti_to_ctte_tip.sv convention 1).
 *       iaddr of the trap beat = PC of the faulting/interrupted instruction
 *       (wb_reg_pc).
 *       G1-CONFIRMED (R3.2a): all 4 trap beats (ecall/illegal/ebreak/
 *       MSIP IRQ) carried iretire=1 and iaddr=PC of the faulting/
 *       interrupted instruction -- clamp 1 is NECESSARY and correct.
 *    2. CLAMP 2 -- trap_return remapping 13 -> 3: Rocket's
 *       TraceCoreIngress maps `trap_return -> ITReturn (13)` instead of
 *       `ITExcReturn (3)` (suspected upstream defect, R0-A3 §3.5 defect 1;
 *       E-Trace semantics + iti_pkg::ERET=3 argue for 3). Parameter
 *       MAP_TRAP_RETURN_TO_ERET (default 1) remaps 13 to EXCEPTION_IR. The
 *       default follows E-Trace semantics and is unambiguous BECAUSE
 *       today's ingress chain produces 13 exclusively for trap_return
 *       (function returns run as jalr -> ITUnJump=14).
 *       G1-CONFIRMED (R3.2a) -- default FIXED at 1: code 13 appeared in
 *       the measured run at ALL 4 mret PCs and nowhere else; jalr returns
 *       came in as 14. The 13->3 remap is therefore unambiguous and
 *       lossless. (Statically also: trap_return = the CSR insn_ret decode,
 *       which also covers sret/dret -- dynamically only mret was exercised.)
 *    3. Idle cycles (tci_iretire_i=0) drive itype=OTHER + iretire=0 -- the
 *       encoder evaluates itype for control flow WITHOUT an iretire gate
 *       (the MBV lesson in mbv_to_ctte_tip "drive TIP"); a stuck TAKEN_BR
 *       from the WB stage's combinational ingress view would be fatal.
 *       G1-CONFIRMED (R3.2a): in the 432-cycle run, 161 idle-cycle rows
 *       carried stuck classifications (37x TAKEN_BR, 71x ITUnJump, 53x
 *       ITInJump at iretire=0 -- wb_ctrl holds the decode of the last
 *       instruction) -- this clamp is therefore MANDATORY. And: NOT ONE
 *       "iretire=0 + itype=EXC/INT" beat was observed -- the clamp does
 *       not swallow any trap.
 *    4. priv = Cat(reg_debug, prv) (R0-A3 §3.5): bit 2 = debug-mode flag,
 *       bits 1:0 = privilege. Passed through 1:1 into tip.priv (3 bit);
 *       tip.debug_mode deliberately stays 0 -- the tip_if contract
 *       (tip_if.sv) requires level semantics ("rises AFTER the last
 *       pre-debug retire", trace suppression) that a per-beat flag cannot
 *       satisfy.
 *       G1-CONFIRMED (R3.2a, partial): M-mode beats carried a constant
 *       priv=0x3; structurally the top port is 4 bit with a constant 0 as
 *       the MSB (`{1'd0, Cat(reg_debug, prv)}`, netlist :79630) -- the
 *       wrapper binds [2:0] to tci_priv_i (see the D12 note below).
 *       G1-PENDING: the real priv encoding in debug mode (no debugger was
 *       attached in the characterization sim; R0-A3 §3.5 [B]).
 *    5. Every unused tip_if signal is explicitly tied off, INCLUDING
 *       tip.trigger (finding A1: the CVA6 shim had forgotten trigger --
 *       integrator contract tip_if.sv "adapters without the signal tie 0").
 *
 *   Widths: ALL adjustments derive from `$bits(...)` on tip_pkg types --
 *   after the X2 parameterization (TIP_IADDRESS_WIDTH 32->64, R1.1) the
 *   truncations disappear automatically, without touching this shim.
 *
 *   CONTEXT (M3, 2026-08-08): optional, off by default. `TCI_CONTEXT_WIDTH
 *   = 0` (default) is bit-for-bit the state before M3 -- `_context` and
 *   `ctype` stay fixed at 0, the encoder sees no context and emits no
 *   FORMAT-2 ownership. That is the operating mode of today's
 *   instantiations (the Rocket SoC synthesis wrapper binds `tci_ctx_i`
 *   to 0).
 *
 *   When the width is named, `tci_ctx_i` carries the core's satp image
 *   ({MODE[63:60], ASID[59:44], PPN[43:0]}, M2 sideband) and the shim
 *   produces what the CTTE contract expects (the identical mechanism as
 *   cva6_iti_to_ctte_tip §Context, W2 -- deliberately not reinvented):
 *
 *     - `_context` is a LEVEL (the currently valid identifier). The
 *       comparator in ct_L23_preproc_comp_filters compares it on EVERY beat.
 *     - `ctype` is the PULSE "report this context now": PRECISELY (2) on
 *       the first qualifying beat after a change AND once on the very
 *       first beat after reset (otherwise a decoder never learns the
 *       INITIAL context: the composer does report an ownership at a sync,
 *       but with FORMAT=CONTEXT_V_PRV, i.e. WITHOUT a context value --
 *       ct_L23_preproc_composer_etip.sv:855-863).
 *
 *   D-R-8 (coordinator, 2026-08-08): the ownership KEY on Rocket is
 *   `satp.PPN` = `tci_ctx_i[43:0]`, NOT the ASID. The ASID is structurally
 *   dead on this netlist (the `ASIdBits` default is 0 ->
 *   CSR.scala:1581-1583 clamps `reg_satp.asid` to 0; the netlist carries
 *   the literal `16'h0` at that position, M2 handoff §1). The PPN is also
 *   the better key: it is the physical address of the page-table root,
 *   hence HART-INDEPENDENT.
 *
 *   G1-CONFIRMED (M3, doc/adapters/rocket_tci_semantics.adoc §Context): of
 *   the 44 PPN bits, only the lower 22 are live on THIS netlist --
 *   `reg_satp_ppn <= {{22'd0}, new_satp_ppn[21:0]}` (netlist rocket64t2
 *   :77358, CSR.scala 1359; paddrBits 34 - pgIdxBits 12 = 22). Hence the
 *   SATP_PPN_LIVE_WIDTH parameter: it is CONFIGURATION-DEPENDENT, not
 *   universally 44. The key is unambiguous only from
 *   TIP_CONTEXT_WIDTH >= SATP_PPN_LIVE_WIDTH (here: 22); below that,
 *   page tables that differ only in higher PPN bits collide. The
 *   elaboration block below says so out loud (and with
 *   CTX_REQUIRE_UNIQUE_KEY=1 aborts on it) -- there must be no SILENT
 *   narrowing here, because the ownership filter would then demonstrably
 *   filter the wrong process.
 *
 *   G1-CONFIRMED (M3, context edge): the context port carries the
 *   REGISTER STATE of satp. The beat of the `csrw satp` instruction still
 *   carries the OLD value, the new one appears from the following cycle
 *   (measurement: doc/adapters/rocket_tci_semantics.adoc §Context, table
 *   "context edge"). That is the RIGHT placement: the writing instruction
 *   still belongs to the old address space (it is part of the
 *   predecessor's switch code), the first instruction after it belongs to
 *   the new one -- the shim needs to compensate for NOTHING.
 */
module rocket_tci_to_ctte_tip
	import tip_pkg::*;
#(
	// Clamp 2 (header comment point 2): the default follows E-Trace
	// semantics; FIXED per the R3.2a G1 truth table (13 measured only at
	// mret PCs).
	parameter bit MAP_TRAP_RETURN_TO_ERET = 1'b1,
	// Sim-only: $warning on 64->32 truncation loss (testbench-switchable).
	parameter bit TRUNC_WARN_EN           = 1'b1,
	// --- Context (M3) -------------------------------------------------
	// Width of the exported context key. 0 (default) = NO context, exactly
	// the state before M3. Otherwise it MUST equal TIP_CONTEXT_WIDTH
	// (clamp below) -- otherwise the key would be silently narrowed.
	parameter int unsigned TCI_CONTEXT_WIDTH     = 0,
	// Live width of satp.PPN on THIS Rocket netlist. MEASURED 22
	// (rocket64t2 :77358, see header); a configuration with a larger
	// paddrBits names its own value here. Diagnostics/contract only, not a
	// data path.
	parameter int unsigned SATP_PPN_LIVE_WIDTH   = 22,
	// 1 = elaboration aborts when the key CANNOT be unique
	// (TCI_CONTEXT_WIDTH < SATP_PPN_LIVE_WIDTH). Default 0: the case is
	// allowed but named out loud (a demonstrator may run with a
	// collision-prone key, a production build must not do so unnoticed).
	parameter bit          CTX_REQUIRE_UNIQUE_KEY = 1'b0
) (
	input uwire logic clk_i,   // assertions only
	input uwire logic rst_ni,

	// TraceCoreInterface, nGroups=1 (R0-A3 §3.3): group fields ...
	// Port widths cross-checked against the R3.0 netlist (D12 resolution,
	// R3.2a): iretire/ilastsize 1, iaddr/tval/cause/time 64 (iaddr+tval
	// only 40 bit driven: {24'd0, wb_reg_pc} resp. {24'd0, csr_io_tval},
	// netlist :79775/:79631); priv at the top is 4 bit with a constant 0
	// MSB -> the wrapper binds [2:0].
	// CONTEXT ADDENDUM (M3, 2026-08-08): the R3.1a/R3.2a statement "a ctx
	// port does NOT EXIST on the netlist (0 hits in the 8.8 MB netlist)"
	// was correct for that state and is NOT ANY MORE. M2 patched the
	// generator (`enableTraceCoreContext`, TraceCoreInterface +=
	// context) and `Rocket64t2` produces: `output [63:0]
	// trace_core_0_context` (:101303) and `trace_core_1_context`
	// (:101312), actively driven from
	// `{csr_io_ptbr_mode, 16'h0, csr_io_ptbr_ppn}` (:81054/:81645).
	// `Rocket64t1` (1 hart, pinned) still lacks the port -- binding it to
	// '0 there remains correct.
	input uwire logic        tci_iretire_i,   // iretireWidth=1 (TraceCoreParams)
	input uwire logic [63:0] tci_iaddr_i,     // xlen=iaddrWidth=64
	input uwire logic [3:0]  tci_itype_i,     // TraceItype, 16 values (table above)
	input uwire logic        tci_ilastsize_i, // G1-CONFIRMED (R3.2a): 0=16 bit, 1=32 bit,
	                                    // measured over 10 compressed + 94
	                                    // 32-bit retires; the source is also
	                                    // valid-gated (valid & ~compressed)
	// ... + interface fields outside the group (R0-A3 §3.3):
	input uwire logic [2:0]  tci_priv_i,      // G1-CONFIRMED (R3.2a): Cat(reg_debug, prv),
	                                    // constant 3 in M-mode; the debug leg is open (point 4)
	input uwire logic [63:0] tci_ctx_i,       // satp image {MODE[63:60], ASID[59:44],
	                                    // PPN[43:0]} (M2 sideband, Rocket64t2).
	                                    // Only PPN is used (D-R-8); at
	                                    // TCI_CONTEXT_WIDTH=0 completely ignored.
	                                    // Instances without context bind '0.
	input uwire logic [63:0] tci_tval_i,
	input uwire logic [63:0] tci_cause_i,     // G1-CONFIRMED (R3.2a): MSB (bit 63) =
	                                    // interrupt flag (INT beat 0x8000..0003);
	                                    // BUT the U3 defect on ecall/ebreak (header)
	input uwire logic [63:0] tci_time_i,      // G1-CONFIRMED (R3.2a): free-running
	                                    // CYCLE COUNTER of the CSR (WideCounter,
	                                    // delta==1/cycle measured) -- NOT mtime

	tip_if.master tip
);

	// TODO X2: 64->32 truncation. Once TIP_IADDRESS_WIDTH is parameterized
	// to 64 (R1.1, gap X2), $bits(tip_iaddr_t)=64 and the function becomes
	// the identity -- this shim then needs no change.
	function automatic tip_iaddr_t trunc_addr(input logic [63:0] a64);
		return tip_iaddr_t'(a64[$bits(tip_iaddr_t)-1:0]);
	endfunction

	// Clamp 2 (header comment point 2)
	uwire logic [3:0] itype_mapped = (MAP_TRAP_RETURN_TO_ERET && tci_itype_i == 4'(RETURN))
	                                 ? 4'(EXCEPTION_IR) : tci_itype_i;

	// Beat/trap classification. beat_valid = iretire (Rocket: iretire :=
	// valid, R0-A3 §3.3) -- the TraceCoreInterface has no separate valid signal.
	uwire logic beat_valid = tci_iretire_i;
	uwire logic is_trap    = beat_valid && (itype_mapped == 4'(EXCEPTION_TRAP)
	                                     || itype_mapped == 4'(INTERRUPT));
	uwire logic is_exc     = beat_valid && (itype_mapped == 4'(EXCEPTION_TRAP));

	// --- Context (M3) ----------------------------------------------------
	localparam int unsigned SATP_PPN_WIDTH = 44;   // satp.PPN field width (RV64)
	localparam bit          CTX_EN         = (TCI_CONTEXT_WIDTH > 0);

	// The key is named, not hidden as a part-select in the data path:
	// satp.PPN (D-R-8). MODE [63:60] and the dead ASID [59:44]
	// deliberately do NOT participate -- a MODE change (Bare <-> Sv39) is
	// not a process change, and the ASID is constant 0 on this core.
	uwire logic [SATP_PPN_WIDTH-1:0] ctx_key = tci_ctx_i[SATP_PPN_WIDTH-1:0];

	// Cast instead of a fixed part-select: at TCI_CONTEXT_WIDTH ==
	// TIP_CONTEXT_WIDTH (enforced below when CTX_EN) the width follows the
	// encoder netlist; at CTX_EN=0 it is the constant 0. The cast sits in
	// its own net, not in the argument (XSIM 2026.1 finding L2, carried
	// over from cva6_iti_to_ctte_tip).
	uwire tip_context_t ctx_now = CTX_EN ? tip_context_t'(ctx_key) : '0;

	// Qualifying beat = every ingress beat with iretire=1. This INCLUDES
	// trap beats (which the shim forces to tip.iretire=0 via clamp 1) --
	// deliberately: the composer processes a beat when
	// `process_now = inst_trace_active && !dbg_suppress && !resume_suppress
	//   && ((tip.iretire && cf_qualifier.hit) || is_trap_event)`
	// (ct_L23_preproc_composer_etip.sv:459-463), and the ownership emission
	// in it is gated on `tip.ctype != 0`, NOT on tip.iretire (:855). A
	// pulse on a trap beat is therefore not lost; a pulse on an IDLE cycle
	// (iretire=0, no trap) would be invisible, though. Identical to
	// cva6_iti_to_ctte_tip (`ctx_beat`), for the same reason there.
	uwire logic ctx_beat = beat_valid;

	tip_context_t CtxSeen    = '0;
	logic         CtxHasSeen = 1'b0;   // first beat after reset still open

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

	// Contract core <-> encoder netlist, the same construction as in
	// cva6_iti_to_ctte_tip.sv and for the same reason: xelab reports a
	// port width difference only as a WARNING, and the trace would look
	// fully plausible afterwards -- it would just name the wrong process.
	// This block deliberately sits OUTSIDE translate_off (the CVA6 twin is
	// already elaborated this way in the board build).
	initial begin
		if (CTX_EN && (TCI_CONTEXT_WIDTH != TIP_CONTEXT_WIDTH))
			$fatal(1, "rocket_tci_to_ctte_tip: TCI_CONTEXT_WIDTH=%0d != TIP_CONTEXT_WIDTH=%0d (encoder built with CT_CONTEXT_WIDTH=%0d) -- the context identifier would be silently truncated and the stream would name the wrong process.",
			       TCI_CONTEXT_WIDTH, TIP_CONTEXT_WIDTH, TIP_CONTEXT_WIDTH);
		// Uniqueness of the KEY (not just width equality): below
		// SATP_PPN_LIVE_WIDTH, page-table roots that differ only in higher
		// PPN bits collide. For the full 44-bit key a build needs
		// CT_CONTEXT_WIDTH = 44 (the composer's maximum,
		// NEXUS_MSG_PROCESS_WIDTH); for this core 22 is enough.
		if (CTX_EN && (TCI_CONTEXT_WIDTH < SATP_PPN_LIVE_WIDTH)) begin
			if (CTX_REQUIRE_UNIQUE_KEY)
				$fatal(1, "rocket_tci_to_ctte_tip: TCI_CONTEXT_WIDTH=%0d < SATP_PPN_LIVE_WIDTH=%0d -- the ownership key (satp.PPN) is NOT unique (CTX_REQUIRE_UNIQUE_KEY=1).",
				       TCI_CONTEXT_WIDTH, SATP_PPN_LIVE_WIDTH);
			else
				$warning("rocket_tci_to_ctte_tip: context key NOT unique -- exporting the lower %0d of %0d live satp.PPN bits (field width %0d). Two address spaces with the same lower %0d PPN bits are indistinguishable in the trace; unique from CT_CONTEXT_WIDTH=%0d.",
				         TCI_CONTEXT_WIDTH, SATP_PPN_LIVE_WIDTH, SATP_PPN_WIDTH,
				         TCI_CONTEXT_WIDTH, SATP_PPN_LIVE_WIDTH);
		end
	end

	always_comb begin
		// Control flow
		tip.itype     = beat_valid ? tip_itype_e'(itype_mapped) : OTHER;  // idle-cycle rule (point 3)
		tip.iretire   = (beat_valid && !is_trap) ? tip_iretire_t'(1) : '0; // clamp 1 (point 1)
		tip.ilastsize = tip_ilastsize_t'(tci_ilastsize_i);
		tip.iaddr     = trunc_addr(tci_iaddr_i);                           // TODO X2 (see above)
		// ecause: the MSB (interrupt flag) is deliberately dropped -- EXC/INT
		// is already encoded in itype; the rest is truncated to
		// $bits(tip_ecause_t). X8 (R1.1/E-R-5) raises TIP_ECAUSE_WIDTH to
		// 6 bit -- the $bits derivation then follows automatically.
		tip.ecause    = is_trap ? tip_ecause_e'(tci_cause_i[$bits(tip_ecause_t)-1:0]) : ECAUSE_NONE;
		tip.tval      = is_exc ? trunc_addr(tci_tval_i) : '0;              // tval only on EXC; TODO X2
		tip.priv      = tip_priv_t'(tci_priv_i);                           // incl. the debug bit (point 4)
		tip._time     = tip_time_t'(tci_time_i);                           // 1:1, both 64 bit

		// Context (M3): level + report pulse. At TCI_CONTEXT_WIDTH=0 both
		// are constant 0 -- exactly the state before M3, and the encoder
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
		// contract, tip_if.sv); trigger NOT forgotten (finding A1, point 5).
		tip.debug_mode = 1'b0;
		tip.evti       = 1'b0;
		tip.power_down = 1'b0;
		tip.trigger    = 1'b0;
	end

	// pragma translate_off
	// Sim-only counters for truncation losses (referenceable by the
	// testbench); the comparisons are width-neutral (a round-trip check
	// rather than a fixed high-bit slice) so they become constant-0 without
	// modification after X2.
	int unsigned sim_trunc_iaddr_cnt = 0;
	int unsigned sim_trunc_tval_cnt  = 0;
	int unsigned sim_trunc_cause_cnt = 0;
	// M3: counted report pulses (PRECISELY). The testbench compares against
	// its own, literally maintained expectation -- a shim whose ctype never
	// or always fires fails here.
	int unsigned sim_ctx_report_cnt  = 0;

	always_ff @(posedge clk_i) begin
		if (rst_ni) begin
			if (ctx_report) sim_ctx_report_cnt <= sim_ctx_report_cnt + 1;
			// Verification table §2: no X/Z on TIP outputs after reset.
			assert (!$isunknown(tip.itype))   else $error("rocket_tci_to_ctte_tip: X on tip.itype");
			assert (!$isunknown(tip.iretire)) else $error("rocket_tci_to_ctte_tip: X on tip.iretire");
			if (beat_valid)
				assert (!$isunknown(tci_iaddr_i)) else $error("rocket_tci_to_ctte_tip: X on iaddr while iretire");

			// Truncation detectors (TODO X2: fall silent constant-0 after
			// the 64-bit parameterization).
			if (beat_valid && 64'(trunc_addr(tci_iaddr_i)) != tci_iaddr_i) begin
				sim_trunc_iaddr_cnt <= sim_trunc_iaddr_cnt + 1;
				if (TRUNC_WARN_EN)
					$warning("rocket_tci_to_ctte_tip: iaddr 64->%0d truncation loses bits (iaddr=%h)",
					         $bits(tip_iaddr_t), tci_iaddr_i);
			end
			if (is_exc && 64'(trunc_addr(tci_tval_i)) != tci_tval_i) begin
				sim_trunc_tval_cnt <= sim_trunc_tval_cnt + 1;
				if (TRUNC_WARN_EN)
					$warning("rocket_tci_to_ctte_tip: tval 64->%0d truncation loses bits (tval=%h)",
					         $bits(tip_iaddr_t), tci_tval_i);
			end
			// cause: bits 62..$bits(tip_ecause_t) are lost (MSB=interrupt
			// flag deliberately dropped). Sv39 causes (12/13/15) fit into 4
			// bit, RVH causes (20..23) do not -- X8 raises this to 6 bit.
			if (is_trap && 63'(tci_cause_i[$bits(tip_ecause_t)-1:0]) != tci_cause_i[62:0]) begin
				sim_trunc_cause_cnt <= sim_trunc_cause_cnt + 1;
				if (TRUNC_WARN_EN)
					$warning("rocket_tci_to_ctte_tip: ecause truncation to %0d bit loses bits (cause=%h)",
					         $bits(tip_ecause_t), tci_cause_i);
			end
		end
	end

	initial begin
		// Elaboration sanity: TraceItype (4 bit) and tip_itype_e must carry
		// the same code width, otherwise the 1:1 mapping is invalid.
		assert ($bits(tip_itype_e) == 4)
			else $fatal(1, "rocket_tci_to_ctte_tip: tip_itype_e is not 4 bit wide");
	end
	// pragma translate_on

endmodule

`default_nettype wire
