// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    mbv_riscv_itype_decoder.sv
 * @brief   RISC-V instruction decode -> 4-bit N-Trace `itype` (Gate G2).
 *
 * @details
 *   Purely COMBINATIONAL and purely ISA-based: classifies the instruction
 *   presented on the AMD `TRACE` bus (+ `Trace_Jump_Taken`) per the MicroBlaze
 *   V implementation concept §5.1. Contains NO trap semantics -- trap entry
 *   (EXCEPTION_TRAP/INTERRUPT) is handled by `mbv_trap_mapper`; the "trap
 *   before branch" priority is enforced by `mbv_to_ctte_tip` (§5.1).
 *   `tip_itype_e` comes from the pinned CTTE `tip_pkg` -- NOT duplicated
 *   (AD-01).
 *
 *   Empirically confirmed (G1, Vivado 2026.1 / microblaze_riscv:1.0):
 *    - `ilastsize = (instr[1:0]==2'b11) ? 1 : 0` -- `Trace_Instruction`
 *      carries the ORIGINAL encoding for RVC, the length bits stay visible
 *      (round 7 -> risk R3 disproved).
 *    - The HW produces `Jump_Taken=0` on a preempted branch (round 6, 0/69
 *      collisions) -- the decoder needs no special case against trap cycles.
 *    - Real execution matches this classification (G0: branch_test,
 *      call/return/indirect call).
 *
 *   Verification: rtl/adapters/amd_microblaze_v/test/tb_mbv_itype_decoder.sv
 *   against itype_vectors.vec (generated from the same source as
 *   doc/adapters/itype_decoder_vectors.csv -- no drift).
 */

module mbv_riscv_itype_decoder
	import tip_pkg::*;
	import mbv_trace_pkg::*;
#(
	parameter bit SUPPORT_RVC = MVP_SUPPORT_RVC   // MVP: 0 (C-ext off, Appendix A). RVC decode = Gate G7.
) (
	input  var logic [31:0] instr,            // Trace_Instruction (normalized)
	input  var logic        jump_taken,       // Trace_Jump_Taken
	output var tip_itype_e  itype,            // non-trap classification
	output var logic        is_trap_return,   // mret/sret detected (-> EXCEPTION_IR)
	output var logic [1:0]  ilastsize         // log2(halfwords): 1 = 32 bit, 0 = RVC
);

	// Elaboration guard: an unsupported combination MUST fail, not silently
	// misbehave (integration report §17.2). RVC decode (c.jr/c.jal/c.beqz/...)
	// is Gate G7, not covered here.
	initial begin
		if (SUPPORT_RVC)
			$fatal(1, "mbv_riscv_itype_decoder: SUPPORT_RVC=1 not implemented (Gate G7).");
	end

	logic [6:0]  opcode;
	logic [4:0]  rd, rs1;
	logic [11:0] funct12;
	logic        rd_link, rs1_link;

	always_comb begin
		opcode   = instr_opcode(instr);
		rd       = instr_rd(instr);
		rs1      = instr_rs1(instr);
		funct12  = instr_funct12(instr);
		rd_link  = is_link_reg(rd);
		rs1_link = is_link_reg(rs1);

		// Length from the RISC-V length encoding (round 7: stays visible in
		// the trace even for RVC).
		ilastsize      = (instr[1:0] == 2'b11) ? 2'd1 : 2'd0;
		is_trap_return = 1'b0;
		itype          = OTHER;

		unique case (opcode)
			OPC_SYSTEM: begin
				// mret/sret: decoder-side indirect branch, not a fresh trap
				// entry (§5.1).
				if (funct12 == SYS_MRET || funct12 == SYS_SRET) begin
					itype          = EXCEPTION_IR;
					is_trap_return = 1'b1;
				end
				// ecall/ebreak/csr* -> OTHER; trap entry comes via
				// Trace_Exception_Taken from mbv_trap_mapper (G1-confirmed),
				// not from instruction decode.
			end

			OPC_BRANCH:
				itype = jump_taken ? TAKEN_BRANCH : NOT_TAKEN_BRANCH;

			OPC_JAL:
				// rd in {x1,x5} -> call; otherwise (including rd=x0) a direct jump.
				itype = rd_link ? INFERRABLE_CALL : OTHER_INFERABLE_JUMP;

			OPC_JALR:
				// Link-register relationship rd/rs1 (§5.1 / E-Trace JALR table).
				if (rd_link && !rs1_link)                    itype = UNINFERABLE_CALL;
				else if (rd_link && rs1_link && (rd == rs1)) itype = UNINFERABLE_CALL;
				else if (rd_link && rs1_link)                itype = CO_ROUTINE_SWAP;
				else if (!rd_link && rs1_link)               itype = RETURN;
				else                                         itype = OTHER_UNINFERABLE_JUMP;

			default:
				itype = OTHER;
		endcase
	end

endmodule : mbv_riscv_itype_decoder

`default_nettype wire
