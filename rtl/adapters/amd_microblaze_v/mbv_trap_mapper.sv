// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    mbv_trap_mapper.sv
 * @brief   AMD `TRACE` trap signals -> TIP retirement/trap semantics (Gate G3).
 *
 * @details
 *   Purely COMBINATIONAL. Every rule here is EMPIRICALLY CONFIRMED (G1 rounds
 *   1-6, Vivado 2026.1 / microblaze_riscv:1.0) -- see
 *   doc/adapters/microblaze_v_trace_semantics.adoc. No rule here is a
 *   documentation assumption.
 *
 *    Rule 1 (round 2): `Trace_Exception_Kind[5]` = interrupt flag, `[4:0]` =
 *                       RISC-V cause. Measured: ecall 0x0b, ebreak 0x03,
 *                       illegal 0x02, misaligned load/store 0x04/0x06,
 *                       external IRQ (MEXT) 0x2b. Without bit 5, ecall
 *                       (cause 11) and MEXT (11) would be indistinguishable.
 *    Rule 2 (rounds 1-6, 69 interrupt + 6 sync events, 0 counterexamples):
 *                       `Trace_Valid_Instr` is NOT retirement -- on both a
 *                       trap and an interrupt it is 1, yet the instruction
 *                       does not retire (sync: the faulting instruction;
 *                       async: the preempted instruction, mepc = that
 *                       instruction). => `iretire = Valid_Instr && !Exception_Taken`.
 *    Rule 3:            `itype = Exc_Kind[5] ? INTERRUPT : EXCEPTION_TRAP`,
 *                       `iretire=0`, `iaddr=Trace_PC`.
 *
 *   REFINEMENT vs. the original integration report §5.3 (from measurement):
 *   the field is `{bit5=interrupt, [4:0]=cause}`, so the cause is limited to
 *   0..31. The special causes 32 (NMI) and 48 (external break) assumed there
 *   are NOT representable in this encoding (they would alias into the
 *   interrupt flag); 24 (AXI4-Stream exception) does fit into [4:0]. Table 4
 *   is unmeasured (those ports are not exposed on this IP config) -> the
 *   special-cause path below is DESIGN per §5.3, NOT empirically confirmed.
 *
 *   `tip_itype_e`/`tip_ecause_e` come from the pinned CTTE `tip_pkg`
 *   (AD-01: not duplicated). Verification:
 *   rtl/adapters/amd_microblaze_v/test/tb_mbv_trap_mapper.sv (vectors = the
 *   G1 measured values).
 */

module mbv_trap_mapper
	import tip_pkg::*;
	import mbv_trace_pkg::*;
(
	input  var logic                        valid_instr,      // Trace_Valid_Instr
	input  var logic                        exception_taken,  // Trace_Exception_Taken
	input  var logic [TRACE_EXC_KIND_W-1:0] exception_kind,   // Trace_Exception_Kind[5:0]

	output var logic         iretire,          // rule 2
	output var logic         is_trap_entry,    // = exception_taken
	output var logic         is_interrupt,     // rule 1: Exc_Kind[5]
	output var tip_itype_e   trap_itype,       // valid when is_trap_entry
	output var tip_ecause_e  ecause,
	output var tip_impdef_t  impdef
);

	logic [4:0] cause;          // RISC-V cause from Exc_Kind[4:0] (rule 1)
	logic       special_cause;  // cause > 15 -> does not fit the 4-bit tip_ecause

	always_comb begin
		// --- Rule 1: discriminator + cause ---
		is_interrupt  = exception_kind[5];
		cause         = exception_kind[4:0];
		special_cause = (cause > 5'd15);

		// --- Rule 2: the core of it. Valid_Instr is NOT iretire. ---
		iretire = valid_instr && !exception_taken;

		// --- Rule 3: trap-entry classification ---
		is_trap_entry = exception_taken;
		trap_itype    = is_interrupt ? INTERRUPT : EXCEPTION_TRAP;

		// --- ecause: 0..15 direct (confirmed over 6 causes); >15 -> fallback
		//     + impdef (§5.3, UNTESTED) ---
		if (!exception_taken)      ecause = ECAUSE_NONE;
		else if (!special_cause)   ecause = tip_ecause_e'(cause[3:0]);
		else                       ecause = ECAUSE_NONE;   // fallback; the real code lives in impdef

		// --- impdef (§5.3 special-cause procedure) ---
		// [5:0] raw Exc_Kind (incl. interrupt flag) · [6] special_cause · [7] tval_unavailable
		// tval is not exposed on the MicroBlaze V -> always 1 in the MVP (AD-04).
		impdef        = '0;
		impdef[5:0]   = exception_kind;
		impdef[6]     = exception_taken && special_cause;
		impdef[7]     = 1'b1;
	end

endmodule : mbv_trap_mapper

`default_nettype wire
