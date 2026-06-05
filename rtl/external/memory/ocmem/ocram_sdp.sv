// -*- indent-tabs-mode:t; tab-width:4
// vim: tabstop=4:noexpandtab
`default_nettype none
/**
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 * Copyright (c) 2018-2025 by Accemic Technologies GmbH Kiefersfelden Germany
 *
 * @author   Thomas B. Preußer <tpreusser@accemic.com>,
 *           Albert Schulz <aschulz@accemic.com>,
 *           Alexander Weiss <aweiss@accemic.com>
 *
 * @file    ocram_sdp.sv
 * @brief   Simple dual-port on-chip RAM with a write and a read interface (SDP).
 *
 * Synthesizable SDP RAM wrapper with one synchronous write port and one synchronous
 * read port. Read latency is one cycle by default and two cycles when
 * `USE_ADDITIONAL_OUTPUT_REG` is enabled.
 *
 * Memory contents may be initialized in simulation through packed `INIT` data when
 * `ENABLE_INIT == 1`. Hardware power-up contents remain tool- and flow-dependent.
 * RAM inference is steered via `RAM_STYLE`.
 *
 * @param A_BITS Number of address bits. Memory depth is `2**A_BITS`.
 * @tparam T Stored data type. Memory width is `$bits(T)`.
 * @param INIT Packed initialization payload with entry 0 in the least-significant `$bits(T)` bits.
 * @param RAM_STYLE Inference hint such as `"block"`, `"distributed"`, `"registers"`, `"ultra"`, or `"auto"`.
 * @param USE_ADDITIONAL_OUTPUT_REG Adds an extra read-side output register, increasing read latency to 2 cycles.
 * @param ENABLE_SEPARATED_CE_FOR_OUTPUT_REG Uses `read_port.regce` for the extra output register when enabled.
 * @param ENABLE_INIT When 1, applies `INIT` in simulation. When 0, skips the init block entirely.
 *
 * @version
 *   - 2.1.1 (2026-03-24)
 *       • Made initialization explicit through `ENABLE_INIT`, defaulting to off.
 *       • Removed the large default `INIT` value to avoid pathological simulator elaboration.
 *   - 2.1.0 (2026-03-23)
 *       • Restored `INIT` parameter and updated documentation.
 *       • Shortened the module overview and removed verbose port documentation.
 */

module ocram_sdp #(
	/// Number of Address Bits
	parameter int A_BITS,

	/// Data Type stored in the OCRAM
	type T = logic [7:0],

	/// Optional packed initial memory contents used when ENABLE_INIT is set.
	parameter logic [(2**A_BITS)*$bits(T)-1:0] INIT = '0,

	/// Enable initialization from INIT in simulation. Default off.
	bit ENABLE_INIT = 1'b0,

	/// Desired RAM Implementation Style
	parameter RAM_STYLE = "block", // alternatives: distributed, registers, ultra, auto

	/// Adds additional output register for data from memory.
	bit USE_ADDITIONAL_OUTPUT_REG = 1'b0,

	/// If set, Clock Enable for the Output Register is controlled by the read_if.regce signal.
	bit ENABLE_SEPARATED_CE_FOR_OUTPUT_REG = 1'b0)
(
  ocram_write_if.impl  write_port,
  ocram_read_if.impl   read_port
);
	initial begin
		if (write_port.A_BITS != A_BITS) begin
			$error("%m Parameter Mismatch: A_BITS specified in write_port (%0d) not equal to A_BITS specified in ocram module (%0d)", write_port.A_BITS, A_BITS);
			$finish();
		end
		if ($bits(write_port.d) != $bits(T)) begin
			$error("%m Parameter Mismatch: Bit Length of Data port `d` specified in write_port (%0d) not equal to bit length of type `T` specified in ocram module (%0d)", $bits(write_port.d), $bits(T));
			$finish();
		end
		if (read_port.A_BITS != A_BITS) begin
			$error("%m Parameter Mismatch: A_BITS specified in read_port (%0d) not equal to A_BITS specified in ocram module (%0d)", read_port.A_BITS, A_BITS);
			$finish();
		end
		if ($bits(read_port.q) != $bits(T)) begin
			$error("%m Parameter Mismatch: Bit Length of Data port `q` specified in read_port (%0d) not equal to bit length of type `T` specified in ocram module (%0d)", $bits(read_port.q), $bits(T));
			$finish();
		end
	end

	(* RAM_STYLE = RAM_STYLE *)
	/*
	 * Note: Memory Entries should not be defined with type T like `T mem[2**A_BITS]`
	 * If the type would be a struct, this results in one RAM module for every field of the struct in synthesis
	 * Synthesized with Vivado 2018.1
	 */

	// Memory array is declared unconditionally and exactly once
	logic [$bits(T)-1:0] mem [0:(2**A_BITS)-1];

	`ifndef SYNTHESIS
		initial if (ENABLE_INIT) begin
			for (int i = 0; i < 2**A_BITS; i++) mem[i] = INIT[i*$bits(T) +: $bits(T)];
		end
	`endif

	// Output Register of the value read
	logic [$bits(T)-1:0] ReadDataReg;

	always_ff @(posedge write_port.clk)
		if (write_port.ce && write_port.we)
			mem[write_port.addr] <= write_port.d;

	always_ff @(posedge read_port.clk)
		if (read_port.ce)
			ReadDataReg <= mem[read_port.addr];

	if (USE_ADDITIONAL_OUTPUT_REG) begin
		logic [$bits(T)-1:0] AdditionalDataReg;
		uwire logic ce = ENABLE_SEPARATED_CE_FOR_OUTPUT_REG ? read_port.regce : read_port.ce;
		always_ff @(posedge read_port.clk) if (ce) AdditionalDataReg <= ReadDataReg;
		assign read_port.q = AdditionalDataReg;
	end
	else begin
		assign read_port.q = ReadDataReg;
	end


endmodule
`default_nettype wire
