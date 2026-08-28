// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    cva6_riscv_itype_refine.sv
 * @brief   Refines the CVA6 ITI's 3-bit `itype` into the 4-bit E-Trace codes
 *          the encoder's folding path needs (package I1).
 *
 * @details
 *   WHY THIS MODULE EXISTS
 *   -----------------------
 *   The CVA6 ITI is fixed at `iti_pkg::ITYPE_LEN = 3` and cannot express
 *   CALL/RETURN at all: `itype_detector.sv` only sees `ariane_pkg::fu_op`,
 *   `branch_taken`, `exception`, `interrupt` -- no `rd`, no `rs1`, no
 *   instruction word. So it is not just the code width that is missing, it
 *   is the INFORMATION (finding I1, from N1/B-W4-1). Consequence in the
 *   stream: the encoder's `ret_sp` never leaves 0, the folding decision is
 *   constantly 0, and a board window with 18206 returns contains 0 folded
 *   ones.
 *
 *   The information is already available, though: `cva6_rvfi.sv` registers
 *   `rvfi_instr_o[i].insn` in the SAME `always_ff` as `rvfi_to_iti_o.*` and
 *   from the same `mem_q[commit_pointer[i]]` entry (`cva6_rvfi.sv:508`
 *   against `:554-559`). The instruction word is therefore cycle-exact with
 *   the ITI beat and needs NO delta in the vendored CVA6 tree -- only a
 *   port that `cva6_trace_wrap` already exposes anyway.
 *
 *   `insn` carries the RAW encoding: `cva6_rvfi.sv:376` builds
 *   `truncated = is_compressed ? {16'b0, instruction[15:0]} : instruction`,
 *   so the RVC encoding is preserved (and self-identifying via
 *   `insn[1:0] != 2'b11`). Exactly the property that
 *   `mbv_riscv_itype_decoder` empirically confirmed for the MicroBlaze V
 *   (G1 round 7).
 *
 *   CLASSIFICATION (E-Trace v2.0.2 ch. 4, JALR table; identical to
 *   `mbv_riscv_itype_decoder.sv` -- no second source of truth)
 *     jal   rd in {x1,x5}                      -> INFERRABLE_CALL   (9)
 *     jalr  rd in {x1,x5}, rs1 not a link       -> UNINFERABLE_CALL  (8)
 *     jalr  rd,rs1 both links, rd == rs1        -> UNINFERABLE_CALL  (8)
 *     jalr  rd,rs1 both links, rd != rs1        -> CO_ROUTINE_SWAP  (12)
 *     jalr  rd = x0, rs1 in {x1,x5}             -> RETURN           (13)
 *     otherwise                                 -> unchanged
 *
 *   MINIMAL-DELTA PRINCIPLE (deliberate, not for convenience)
 *   -----------------------------------------------------------
 *   Only the two ITI codes that admit refinement at all are refined:
 *    - `STANDARD` (0) -- this is where `jal` hides, because
 *      `decoder.sv:1700` gives it no `fu_op` of its own (`ariane_pkg`
 *      only knows `JALR`);
 *    - `UNINF_JMP` (6) -- the catch-all code for EVERY `jalr`.
 *   Everything else (EXC/INT/ERET/branches) passes through unchanged.
 *
 *   In particular, a `jal x0` (i.e. `j`) stays `OTHER` and is NOT promoted
 *   to `OTHER_INFERABLE_JUMP`, and a `jalr` without a link-register
 *   relationship stays `UNINFERABLE_JUMP` (6). Both would be closer to
 *   spec (code 6 is "reserved" at itype_width_p=4), but neither affects
 *   folding and would needlessly change the stream relative to the today
 *   verified state. The encoder consistently treats 6 as uninferable
 *   (`tip_pkg::GetPCInfoType` -> JI, and 6 appears in every uninferable set
 *   of `ct_L2_msg_gen`), so this is not a special case, it is the baseline.
 *
 *   COST IN THE STREAM: none for calls. `ct_L2_msg_gen.sv` routes
 *   `INFERRABLE_CALL` through `cf_inferable_silent` -- an inferable call
 *   produces NO message, it only pushes the return address onto the
 *   encoder's stack. `UNINFERABLE_CALL`/`CO_ROUTINE_SWAP` sit in the same
 *   plain-IBH set as today's `UNINFERABLE_JUMP`, so they cost the same.
 *   The saving is on `RETURN`: a predicted return is elided.
 *
 *   LINK-REGISTER SET: parameterizable, default {x1, x5} per E-Trace. The
 *   reference decoder NexRv classifies its PCINFO differently
 *   (`NexRvConv.c:225`: return only when the base == x1; `:238`: call for
 *   any rd != x0) -- encoder and decoder stack must MATCH, or decode
 *   breaks. That is why this is a parameter and not a constant; see
 *   handoff I1, finding B-I1-1.
 */

module cva6_riscv_itype_refine
	import tip_pkg::*;
#(
	// Bit n set = xN is a link register. Default: x1 and x5.
	parameter logic [31:0] LINK_REG_MASK = 32'h0000_0022,
	// Recognize RV32C `c.jal` (funct3=001, op=01). On RV64 the same encoding
	// is `c.addiw` -- a wrong default would be a silent mis-push there.
	// Hence off by default, and the RV32 leg deliberately turns it on.
	parameter bit SUPPORT_C_JAL = 1'b0
) (
	input  var logic [31:0]                 insn,       // raw instruction word
	input  var logic [2:0]                  iti_itype,  // iti_pkg::itype_t
	output var logic [TIP_ITYPE_WIDTH-1:0]  itype
);

	localparam logic [2:0] ITI_STANDARD  = 3'd0;
	localparam logic [2:0] ITI_UNINF_JMP = 3'd6;

	localparam logic [6:0] OPC_JAL  = 7'b110_1111;
	localparam logic [6:0] OPC_JALR = 7'b110_0111;

	function automatic logic is_link(input logic [4:0] r);
		is_link = LINK_REG_MASK[r];
	endfunction

	logic        is_rvc;
	logic        is_jal, is_jalr;
	logic [4:0]  rd, rs1;
	logic        rd_link, rs1_link;

	always_comb begin
		// RVC is identifiable from the length encoding itself; `insn` carries
		// the original encoding in [15:0] with zeros above for compressed
		// instructions (cva6_rvfi.sv:376).
		is_rvc = (insn[1:0] != 2'b11);

		is_jal  = 1'b0;
		is_jalr = 1'b0;
		rd      = 5'd0;
		rs1     = 5'd0;

		if (!is_rvc) begin
			unique case (insn[6:0])
				OPC_JAL: begin
					is_jal = 1'b1;
					rd     = insn[11:7];
				end
				OPC_JALR: begin
					is_jalr = 1'b1;
					rd      = insn[11:7];
					rs1     = insn[19:15];
				end
				default: ;
			endcase
		end else begin
			// c.jr   rs1 : funct4=1000, rs1!=0, rs2=0, op=10  -> jalr x0,0(rs1)
			// c.jalr rs1 : funct4=1001, rs1!=0, rs2=0, op=10  -> jalr x1,0(rs1)
			//   (rs1==0 would be c.ebreak or reserved -- hence the test)
			// c.j        : funct3=101,  op=01                 -> jal  x0,imm
			// c.jal      : funct3=001,  op=01, RV32 ONLY       -> jal  x1,imm
			if ((insn[1:0] == 2'b10) && (insn[6:2] == 5'd0) && (insn[11:7] != 5'd0)
				&& (insn[15:13] == 3'b100)) begin
				is_jalr = 1'b1;
				rs1     = insn[11:7];
				rd      = insn[12] ? 5'd1 : 5'd0;   // [12]=1 -> c.jalr, else c.jr
			end else if (insn[1:0] == 2'b01) begin
				if (insn[15:13] == 3'b101) begin
					is_jal = 1'b1;
					rd     = 5'd0;                  // c.j
				end else if (SUPPORT_C_JAL && (insn[15:13] == 3'b001)) begin
					is_jal = 1'b1;
					rd     = 5'd1;                  // c.jal (RV32)
				end
			end
		end

		rd_link  = is_link(rd);
		rs1_link = is_link(rs1);

		// Default: pass through unchanged (zero extension, as before).
		itype = {1'b0, iti_itype};

		if (iti_itype == ITI_STANDARD) begin
			// `jal` hides here -- the ITI gives it no code of its own.
			if (is_jal && rd_link) itype = INFERRABLE_CALL;
		end else if (iti_itype == ITI_UNINF_JMP) begin
			// Catch-all code for EVERY jalr. If the pattern does not match
			// (e.g. an RVC encoding this module does not know), it stays
			// UNINFERABLE_JUMP -- conservative, never a guessed push.
			if (is_jalr) begin
				if      (rd_link && !rs1_link)               itype = UNINFERABLE_CALL;
				else if (rd_link &&  rs1_link && (rd == rs1)) itype = UNINFERABLE_CALL;
				else if (rd_link &&  rs1_link)                itype = CO_ROUTINE_SWAP;
				else if (!rd_link && rs1_link)                itype = RETURN;
			end
		end
	end

endmodule : cva6_riscv_itype_refine

`default_nettype wire
