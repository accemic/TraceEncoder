// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    mbv_trace_pkg.sv
 * @brief   AMD MicroBlaze V `TRACE` bus adapter: constants + version fingerprint.
 *
 * @details
 *   Declarations only (constants/widths/ISA-decode parameters) -- NO behavior.
 *   The TIP target side (tip_itype_e/tip_ecause_e/...) comes from the pinned
 *   CTTE `tip_pkg` and is NOT duplicated here (AD-01). The adapter behavior
 *   modules import both packages.
 *
 *   Basis (empirical @ Vivado 2026.1, IP xilinx.com:ip:microblaze_riscv:1.0,
 *   C_TRACE=1): trace-bus ports confirmed via block-design introspection
 *   (Gate G0). All AMD TRACE buses are VHDL
 *   `(0 to N)` ascending (bit 0 = MSB) -- the normalizer mirrors them (R4).
 *
 *   Lint: elaborates standalone with `xvlog -sv` (no external imports).
 */

package mbv_trace_pkg;

	// -------------------------------------------------------------------
	// Version fingerprint (R1/AD-07 -- version-bound support, no silent pass).
	// -------------------------------------------------------------------
	localparam int unsigned MBV_ADAPTER_VER_MAJOR = 0;
	localparam int unsigned MBV_ADAPTER_VER_MINOR = 1;
	localparam int unsigned MBV_ADAPTER_VER_PATCH = 0;   // 0.1.0-dev (phase 0)
	localparam string       MBV_TESTED_VIVADO     = "2026.1";
	localparam string       MBV_TESTED_IP_VLNV    = "xilinx.com:ip:microblaze_riscv:1.0";
	localparam string       MBV_CTTE_PIN        = "3a74ea5939841451f6bacd8aa828c52d80b77aa0";
	// 32-bit fingerprint for a runtime/elaboration register (packed Vivado major.minor):
	localparam logic [31:0] MBV_FINGERPRINT = 32'h2026_0100;  // 2026.1, adapter 0.1.0

	// -------------------------------------------------------------------
	// AMD `TRACE` bus field widths (confirmed @ microblaze_riscv:1.0, C_TRACE=1).
	// -------------------------------------------------------------------
	localparam int TRACE_PC_W          = 32;  // Trace_PC          (0 to 31)
	localparam int TRACE_INSTR_W       = 32;  // Trace_Instruction (0 to 31)
	localparam int TRACE_EXC_KIND_W    =  6;  // Trace_Exception_Kind (0 to 5)
	localparam int TRACE_DATA_ADDR_W   = 32;  // Trace_Data_Address (0 to 31)
	localparam int TRACE_DATA_W        = 32;  // Trace_Data_Write_Value / Trace_New_Reg_Value
	localparam int TRACE_BE_W          =  4;  // Trace_Data_Byte_Enable (0 to 3)
	localparam int TRACE_REG_ADDR_W    =  5;  // Trace_Reg_Addr (0 to 4)
	// Note: Trace_Privilege_Mode / Trace_PID_Reg are NOT exposed on this IP
	// version (the original integration report assumed them). MVP: priv is a
	// constant Machine-Mode, _context = 0.

	// -------------------------------------------------------------------
	// MVP adapter parameters (Appendix A) -- unsupported combinations fail
	// via an elaboration assertion.
	// -------------------------------------------------------------------
	localparam int  MVP_IADDR_WIDTH      = 32;
	localparam int  MVP_DATA_WIDTH       = 32;
	localparam bit  MVP_SUPPORT_RVC      = 1'b0;   // Gate G7
	localparam bit  MVP_SUPPORT_DATA_TR  = 1'b0;   // Gate G8
	localparam int  MVP_ILASTSIZE_RV32   = 1;      // log2(halfwords): RV32-without-C = 1 (4 bytes)

	// -------------------------------------------------------------------
	// RISC-V ISA decode constants (pure spec; feed mbv_riscv_itype_decoder,
	// Gate G2). NO trap/retirement behavior -- that is G1/trap_mapper.
	// -------------------------------------------------------------------
	localparam logic [6:0] OPC_BRANCH = 7'b110_0011; // B-type
	localparam logic [6:0] OPC_JAL    = 7'b110_1111; // J-type
	localparam logic [6:0] OPC_JALR   = 7'b110_0111; // I-type, indirect
	localparam logic [6:0] OPC_SYSTEM = 7'b111_0011; // ecall/ebreak/mret/sret/csr
	localparam logic [6:0] OPC_AUIPC  = 7'b001_0111; // U-type (sijump pair source)
	localparam logic [6:0] OPC_LUI    = 7'b011_0111; // U-type (sijump pair source)

	// SYSTEM funct12 (instr[31:20]) for trap/return instructions
	localparam logic [11:0] SYS_ECALL  = 12'h000;
	localparam logic [11:0] SYS_EBREAK = 12'h001;
	localparam logic [11:0] SYS_MRET   = 12'h302;
	localparam logic [11:0] SYS_SRET   = 12'h102;

	// N-Trace link registers x1, x5 (§5.1). Pure combinational helper.
	function automatic logic is_link_reg(input logic [4:0] r);
		return (r == 5'd1) || (r == 5'd5);
	endfunction

	// Instruction field extraction (standard RISC-V layout).
	function automatic logic [6:0] instr_opcode(input logic [31:0] instr); return instr[6:0];   endfunction
	function automatic logic [4:0] instr_rd    (input logic [31:0] instr); return instr[11:7];  endfunction
	function automatic logic [4:0] instr_rs1   (input logic [31:0] instr); return instr[19:15]; endfunction
	function automatic logic [2:0] instr_funct3(input logic [31:0] instr); return instr[14:12]; endfunction
	function automatic logic [11:0] instr_funct12(input logic [31:0] instr); return instr[31:20]; endfunction

endpackage : mbv_trace_pkg

`default_nettype wire
