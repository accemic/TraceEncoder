// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @file    mbv_trace_if.sv
 * @brief   AMD MicroBlaze V `TRACE` bus (adapter INPUT). Counterpart to the
 *          CTTE `tip_if` (adapter OUTPUT).
 *
 * @details
 *   Signal names/widths confirmed empirically @ Vivado 2026.1,
 *   xilinx.com:ip:microblaze_riscv:1.0, C_TRACE=1 (block-design
 *   introspection, Gate G0).
 *
 *   BIT ORDER (R4): the MicroBlaze V ports are VHDL `(0 to N)` ascending
 *   (bit 0 = MSB). This SV declaration uses `[N-1:0]` (bit N-1 = MSB). The
 *   mapping between the MBV net and this interface must be established
 *   bit-exact by `mbv_trace_normalizer` (verified against the object dump,
 *   G0 criterion). This interface carries the raw signals as they appear at
 *   the IP boundary; normalization happens IN the adapter, not here.
 *
 *   STROBE-ONLY / OBSERVER: the `TRACE` bus is an observation interface --
 *   no backpressure to the core (integration report §14.2). The interface
 *   therefore has no ready/stall signaling.
 *
 *   Behavior (which cycle means what for retirement/trap coupling) is NOT
 *   fixed here -- see Gate G1 (doc/adapters/microblaze_v_trace_semantics.adoc).
 */

interface mbv_trace_if
	import mbv_trace_pkg::*;
();
	// --- Program flow (MVP-carrying) ---
	logic                        trace_valid_instr;     // Trace_Valid_Instr  (retirement semantics: G1)
	logic [TRACE_INSTR_W-1:0]    trace_instruction;      // Trace_Instruction
	logic [TRACE_PC_W-1:0]       trace_pc;               // Trace_PC
	logic                        trace_jump_taken;       // Trace_Jump_Taken
	logic                        trace_exception_taken;  // Trace_Exception_Taken
	logic [TRACE_EXC_KIND_W-1:0] trace_exception_kind;   // Trace_Exception_Kind (6 bit)

	// --- Pipeline run/stall + halt (new vs. the integration report; G1 retirement aid) ---
	logic                        trace_of_piperun;      // Trace_OF_PipeRun  (operand fetch)
	logic                        trace_ex_piperun;      // Trace_EX_PipeRun  (execute)
	logic                        trace_mem_piperun;     // Trace_MEM_PipeRun (memory)
	logic                        trace_halted;          // Trace_Halted

	// --- Data flow (P2/P3 -- not MVP; §4.2) ---
	logic                          trace_data_access;      // Trace_Data_Access
	logic [TRACE_DATA_ADDR_W-1:0]  trace_data_address;     // Trace_Data_Address
	logic                          trace_data_read;        // Trace_Data_Read
	logic                          trace_data_write;       // Trace_Data_Write
	logic [TRACE_DATA_W-1:0]       trace_data_write_value; // Trace_Data_Write_Value
	logic [TRACE_BE_W-1:0]         trace_data_byte_enable; // Trace_Data_Byte_Enable
	logic                          trace_reg_write;        // Trace_Reg_Write
	logic [TRACE_REG_ADDR_W-1:0]   trace_reg_addr;         // Trace_Reg_Addr
	logic [TRACE_DATA_W-1:0]       trace_new_reg_value;    // Trace_New_Reg_Value (load value ambiguous: §4.2)

	// MBV core drives (source); adapter observes (sink). No ready/backpressure (observer).
	modport source (
		output trace_valid_instr, trace_instruction, trace_pc, trace_jump_taken,
		       trace_exception_taken, trace_exception_kind,
		       trace_of_piperun, trace_ex_piperun, trace_mem_piperun, trace_halted,
		       trace_data_access, trace_data_address, trace_data_read, trace_data_write,
		       trace_data_write_value, trace_data_byte_enable,
		       trace_reg_write, trace_reg_addr, trace_new_reg_value
	);

	modport sink (
		input  trace_valid_instr, trace_instruction, trace_pc, trace_jump_taken,
		       trace_exception_taken, trace_exception_kind,
		       trace_of_piperun, trace_ex_piperun, trace_mem_piperun, trace_halted,
		       trace_data_access, trace_data_address, trace_data_read, trace_data_write,
		       trace_data_write_value, trace_data_byte_enable,
		       trace_reg_write, trace_reg_addr, trace_new_reg_value
	);

endinterface : mbv_trace_if

`default_nettype wire
