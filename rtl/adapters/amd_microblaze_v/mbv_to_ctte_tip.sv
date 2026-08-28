// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    mbv_to_ctte_tip.sv
 * @brief   AMD MicroBlaze V `TRACE` bus -> CTTE TIP (adapter top, core logic).
 *
 * @details
 *   Combines `mbv_riscv_itype_decoder` (G2) and `mbv_trap_mapper` (G3) and
 *   drives `tip_if.master`. Every rule is G1-confirmed
 *   (doc/adapters/microblaze_v_trace_semantics.adoc, rounds 1-7) -- no
 *   documentation assumption.
 *
 *   itype priority (§5.1), as it follows from measurement:
 *     1 reset/idle -> 2 trap entry (`Exception_Taken`) -> 3 trap return
 *     (mret/sret, instruction decode) -> 4 cond. branch -> 5 JAL -> 6 JALR
 *     -> 7 OTHER
 *   Round 6 showed: `Exception_Taken=1` and `Jump_Taken=1` NEVER occur
 *   together (0/69) -- a preempted branch never resolves. The priority is
 *   therefore defensive, but uncontested on the HW side.
 *
 *   Observer character (integration report §14.2): NO backpressure to the
 *   core -- the adapter never stalls; every valid TRACE cycle is accepted.
 *   Overflow must be made visible by the CTTE error/resync path.
 *
 *   MVP fixed values (Appendix A, each justified):
 *     tval      = 0            -- not exposed on the MBV (AD-04); `impdef[7]` reports this.
 *     priv      = constant M-mode -- `Trace_Privilege_Mode` does NOT exist on
 *                 this IP version (G0 port list).
 *     _context  = 0, ctype=UNREPORTED -- `Trace_PID_Reg` is likewise not exposed.
 *     _time     = free-running 64-bit core cycle counter (AD-06), reproducible in `tip_clk`.
 *     Data flow = off (SUPPORT_DATA_TRACE=0, P2/G8).
 */

module mbv_to_ctte_tip
	import tip_pkg::*;
	import mbv_trace_pkg::*;
#(
	parameter int IADDR_WIDTH        = MVP_IADDR_WIDTH,
	parameter int DATA_WIDTH         = MVP_DATA_WIDTH,
	parameter bit SUPPORT_RVC        = MVP_SUPPORT_RVC,
	parameter bit SUPPORT_DATA_TRACE = MVP_SUPPORT_DATA_TR
) (
	input var logic clk,
	input var logic rst,          // synchronous, active high

	// Sequentially-inferable-jump classification (the E-Trace `sijump` idea
	// carried into the N-Trace path): a JALR whose rs1 was written by the
	// instruction retired IMMEDIATELY BEFORE it (an auipc/lui) has a
	// statically computable target -> classify as INFERRABLE; msg_gen then
	// folds it (no IndirectBranchHist, no UADDR). The decoder needs a PCInfo
	// with static targets for exactly these pairs (NexRv -conv -objd ...
	// -sijump). Default 0 = the previous behavior (byte-identical, 1:1 to AMD).
	input var logic sijump_en,

	mbv_trace_if.sink mbv,        // AMD TRACE bus (input)
	tip_if.master     tip         // CTTE ingress (output)
);

	// --- Elaboration guards (§17.2): unsupported combinations MUST fail ---
	initial begin
		if (IADDR_WIDTH != 32)
			$fatal(1, "mbv_to_ctte_tip: only IADDR_WIDTH=32 supported (MVP, Appendix A).");
		if (DATA_WIDTH != 32)
			$fatal(1, "mbv_to_ctte_tip: only DATA_WIDTH=32 supported (MVP, Appendix A).");
		if (SUPPORT_RVC)
			$fatal(1, "mbv_to_ctte_tip: SUPPORT_RVC=1 not implemented (Gate G7).");
		if (SUPPORT_DATA_TRACE)
			$fatal(1, "mbv_to_ctte_tip: SUPPORT_DATA_TRACE=1 not implemented (Gate G8/P2).");
	end

	// --- G2: instruction decode ---
	tip_itype_e dec_itype;
	logic       dec_is_trap_return;
	logic [1:0] dec_ilastsize;

	mbv_riscv_itype_decoder #(.SUPPORT_RVC(SUPPORT_RVC)) u_itype (
		.instr          (mbv.trace_instruction),
		.jump_taken     (mbv.trace_jump_taken),
		.itype          (dec_itype),
		.is_trap_return (dec_is_trap_return),
		.ilastsize      (dec_ilastsize)
	);

	// --- G3: trap/retirement semantics ---
	logic        trp_iretire, trp_is_trap_entry, trp_is_interrupt;
	tip_itype_e  trp_itype;
	tip_ecause_e trp_ecause;
	tip_impdef_t trp_impdef;

	mbv_trap_mapper u_trap (
		.valid_instr     (mbv.trace_valid_instr),
		.exception_taken (mbv.trace_exception_taken),
		.exception_kind  (mbv.trace_exception_kind),
		.iretire         (trp_iretire),
		.is_trap_entry   (trp_is_trap_entry),
		.is_interrupt    (trp_is_interrupt),
		.trap_itype      (trp_itype),
		.ecause          (trp_ecause),
		.impdef          (trp_impdef)
	);

	// --- _time: free-running core cycle counter (AD-06) ---
	tip_time_t cycle_cnt;
	always_ff @(posedge clk) begin
		if (rst) cycle_cnt <= '0;
		else     cycle_cnt <= cycle_cnt + 1'b1;
	end

	// --- sijump: pair detector (dynamic adjacency in the retire stream) ---
	// Remembers whether the LAST RETIRED instruction was an auipc/lui with
	// rd != x0. Any other retirement AND any trap entry clears the flag
	// (executed handler code or an intervening control-flow transfer between
	// the two pair halves breaks inferability; the encoder then falls back
	// to the normal IndirectBranchHist -- lossless, just without the
	// savings). The static PCInfo side (NexRv -sijump) pairs in program
	// order; dynamically broken pairs arrive as IBH with UADDR and are
	// accepted by the decoder.
	logic       PrevWasAuipcLui;
	logic [4:0] PrevUTypeRd;
	always_ff @(posedge clk) begin
		if (rst) begin
			PrevWasAuipcLui <= 1'b0;
			PrevUTypeRd     <= '0;
		end
		else if (mbv.trace_exception_taken) begin
			PrevWasAuipcLui <= 1'b0;      // trap entry breaks the pair
		end
		else if (mbv.trace_valid_instr) begin
			PrevWasAuipcLui <=
				((instr_opcode(mbv.trace_instruction) == OPC_AUIPC) ||
				 (instr_opcode(mbv.trace_instruction) == OPC_LUI)) &&
				(instr_rd(mbv.trace_instruction) != 5'd0);
			PrevUTypeRd     <= instr_rd(mbv.trace_instruction);
		end
	end

	// A JALR is inferable if (a) rs1 was written by an immediately preceding
	// auipc/lui (pair rule) OR (b) rs1 = x0 (constant base -- linker
	// relaxation produces this form for absolute low targets).
	uwire sijump_pair =
		sijump_en &&
		(instr_opcode(mbv.trace_instruction) == OPC_JALR) &&
		( (PrevWasAuipcLui && (instr_rs1(mbv.trace_instruction) == PrevUTypeRd))
		  || (instr_rs1(mbv.trace_instruction) == 5'd0) );

	// --- drive TIP ---
	always_comb begin
		// Default: idle. Reset has the highest priority (§5.1 stage 1).
		tip.itype     = OTHER;
		tip.iretire   = '0;
		tip.ecause    = ECAUSE_NONE;
		tip.iaddr     = mbv.trace_pc;
		tip.ilastsize = tip_ilastsize_t'(dec_ilastsize);
		tip.impdef    = trp_impdef;

		if (!rst) begin
			// Stage 2: trap entry dominates (INTERRUPT | EXCEPTION_TRAP, iretire=0).
			// Stages 3-7 come from the decoder (mret/sret -> EXCEPTION_IR,
			// branch/JAL/JALR/OTHER).
			//
			// MANDATORY gate on `trace_valid_instr` (measured 2026-07-16,
			// G5 bring-up): the AMD TRACE bus holds `Trace_Instruction`
			// stable for TWO MORE CYCLES after a retire, while
			// `Trace_Valid_Instr=0` -- confirmed on the mret in trap_test:
			// the word 0x30200073 stood at cycles 191/192/193, `Valid_Instr`
			// pulsed only at 191. Without this gate we keep decoding the
			// DEAD word and report the encoder THREE mret events.
			//
			// That is fatal because the encoder evaluates `itype` for
			// control flow WITHOUT an iretire gate
			// (ct_L23_preproc_composer_etip: `IsControlFlowInstruction(tip.itype)`;
			// iretire only steers the halfword count). The ghost events
			// produce extra indirect-branch messages -> the message stream
			// derails, NexRv aborts decoding.
			//
			// `iretire=0` on a SINGLE real event is, in contrast, entirely
			// legitimate: that is exactly how a trapping instruction is
			// reported (upstream cpu_model `exception_trap(no_retire=1)`).
			// So the point is NOT to suppress iretire=0 cycles, but cycles
			// WITHOUT an event.
			if (trp_is_trap_entry)          tip.itype = trp_itype;      // trap: iretire=0, but valid
			else if (mbv.trace_valid_instr) begin
				tip.itype = dec_itype;                                  // a real retiring instruction
				// sijump promotion: a statically inferable JALR is folded
				// like a direct jump/call. ONLY the call/jump forms --
				// RETURN and CO_ROUTINE_SWAP keep their stack semantics.
				if (sijump_pair) begin
					if      (dec_itype == UNINFERABLE_CALL)      tip.itype = INFERRABLE_CALL;
					else if (dec_itype == OTHER_UNINFERABLE_JUMP) tip.itype = OTHER_INFERABLE_JUMP;
				end
			end
			else                            tip.itype = OTHER;          // idle cycle: the instr word is dead

			tip.iretire = trp_iretire;                    // = Valid_Instr && !Exception_Taken
			tip.ecause  = trp_ecause;
		end

		// --- MVP constants (see header comment) ---
		tip.tval     = '0;                                // AD-04; impdef[7] reports "not available"
		tip.priv     = 3'd3;                              // RISC-V machine mode; no Trace_Privilege_Mode
		tip._context = '0;
		tip.ctype    = tip_ctype_t'(UNREPORTED);
		tip._time    = cycle_cnt;

		// --- Data flow: disabled in the MVP (P2/G8) ---
		tip.dretire = 1'b0;
		tip.dtype   = LOAD;
		tip.daddr   = '0;
		tip.dsize   = '0;
		tip.data    = '0;
		tip.sdata   = '0;
		tip.lresp   = '0;
		tip.ldata   = '0;

		// Generic event sideband (seq 24, B1): the AMD `TRACE` bus (UG1629,
		// Vivado 2025.x) provides NO debug-mode/EVTI/power signal -> tie 0
		// (integration requirement: a core-side debug_mode signal is needed
		// so that SYNC=3 / correlation EVCODE=0 can occur; see
		// doc/adapters/microblaze_v_supported_configurations.adoc).
		tip.debug_mode = 1'b0;
		tip.evti       = 1'b0;
		tip.power_down = 1'b0;
		tip.trigger    = 1'b0;
	end

	// --- Assertions from the confirmed invariants (integration report §18.9, G1 rounds 1-6) ---
`ifndef SYNTHESIS
	// Trap entry NEVER retires (rule 2; confirmed over 6 sync causes + 69 interrupts).
	a_trap_no_retire: assert property (@(posedge clk) disable iff (rst)
		mbv.trace_exception_taken |-> (tip.iretire == 1'b0))
		else $error("mbv_to_ctte_tip: iretire!=0 on Exception_Taken");

	// Without Valid_Instr and without a trap, nothing may retire.
	a_idle_no_retire: assert property (@(posedge clk) disable iff (rst)
		(!mbv.trace_valid_instr && !mbv.trace_exception_taken) |-> (tip.iretire == 1'b0))
		else $error("mbv_to_ctte_tip: iretire!=0 without Valid_Instr/trap");

	// Round 6: Exception_Taken and Jump_Taken never occurred together (0/69) --
	// tracked as a cover, not an assertion: a counterexample would be a NEW
	// G1 finding, not a bug.
	c_trap_and_jump: cover property (@(posedge clk) disable iff (rst)
		mbv.trace_exception_taken && mbv.trace_jump_taken);
`endif

endmodule : mbv_to_ctte_tip

`default_nettype wire
