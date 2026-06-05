// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 * Copyright (c) 2025 Accemic Technologies GmbH
 * Address: Kiefersfelden, Germany
 *
 * @file        counter.sv
 * @brief       Parameterized synchronous up/down counter with saturation and overflow modes.
 *
 * @description
 *   Universal synchronous counter supporting increment, decrement, and arbitrary addition.
 *   Provides two operation modes: saturation (clamping) and overflow (wrapping).
 *   Configurable counter width via type parameter and customizable overflow threshold.
 *
 *   Operation Priority (highest to lowest):
 *     1. Clear (cnt.clr)      - Resets counter and all flags to zero
 *     2. Add (cnt.add != 0)   - Adds arbitrary value to counter
 *     3. Inc/Dec (cnt.inc/dec)- Increments or decrements by one
 *
 * @tparam T         Data type for counter value (determines bit width)
 * @tparam mode      Operating mode: MODE_SATURATION or MODE_OVERFLOW
 *
 * @ports
 *   clk                Clock input (synchronous operation)
 *   rst                Synchronous reset (active high)
 *   cnt.clr            Synchronous clear (resets counter and flags)
 *   cnt.inc            Increment enable (+1)
 *   cnt.dec            Decrement enable (-1)
 *   cnt.add            Addition value (ignored when zero; overrides inc/dec)
 *   cnt.overflow_value Upper threshold for saturation mode
 *   cnt.value          Current counter value (output)
 *   cnt.overflow       Overflow flag (output, saturation mode only)
 *   cnt.underflow      Underflow flag (output, saturation mode only)
 *
 * @behavior
 *   MODE_SATURATION:
 *     - Counter clamps at overflow_value when exceeded (overflow flag set)
 *     - Counter clamps at 0 when decremented below zero (underflow flag set)
 *     - Once saturated, counter remains frozen until cleared/reset
 *     - Flags remain sticky until cleared/reset
 *
 *   MODE_OVERFLOW:
 *     - Counter wraps around at type width boundaries
 *     - Overflow/underflow flags remain inactive (always 0)
 *     - Supports full modulo arithmetic
 *
 * @examples
 *   // 8-bit counter with saturation at 200
 *   counter #(.T(logic[7:0]), .MODE(MODE_SATURATION)) cnt_sat (
 *     .clk(clk), .rst(rst), .cnt(cnt_if)
 *   );
 *
 *   // 16-bit counter with wraparound
 *   counter #(.T(logic[15:0]), .MODE(MODE_OVERFLOW)) cnt_ovr (
 *     .clk(clk), .rst(rst), .cnt(cnt_if)
 *   );
 */

`default_nettype none

//------------------------------------------------------------------------------
// Counter Package
//------------------------------------------------------------------------------

package counter_pkg;

	typedef enum logic {
		MODE_SATURATION    = 0,  // Clamp at min/max with flags
		MODE_OVERFLOW      = 1   // Wrap around at boundaries
	}mode_e;

endpackage // counter_pkg

//------------------------------------------------------------------------------
// Counter Interface
//------------------------------------------------------------------------------
interface counter_if #(
	parameter type T = logic[7:0]) ();

	// Control inputs
	logic   clr;             // Synchronous clear
	logic   inc;             // Increment enable
	logic   dec;             // Decrement enable
	T   	add;             // Addition value
	T   	overflow_value;  // Upper threshold (saturation mode)

	// Status outputs
	T   	value;           // Current counter value
	logic   overflow;        // Overflow flag (saturation mode only)
	logic   underflow;       // Underflow flag (saturation mode only)

	modport master (
		input clr, inc, dec, add, overflow_value,
		output value, overflow, underflow
	);

	modport slave (
		output clr, inc, dec, add, overflow_value,
		output value, overflow, underflow
	);
endinterface

//------------------------------------------------------------------------------
// Counter Module
//------------------------------------------------------------------------------

import counter_pkg::*;

module counter #(
	type    T    = logic [7:0],        // Counter data type
	mode_e  MODE = MODE_SATURATION     // Operation mode
)(
	input uwire logic  clk,     	// System clock
	input uwire logic  rst,     	// Synchronous reset
	counter_if.master  cnt      	// Counter interface
);

	localparam int W = $bits(T);	// Bit width of counter type

	// Registered state variables (capitalized)
	T 		Count;              // Counter value
	logic 	Overflow;           // Overflow flag
	logic 	Underflow;          // Underflow flag

	// Next-state
	T 		CountN;
	logic 	OverflowN;
	logic 	UnderflowN;

	// Combinational next-state logic (lint friendly)
	always_comb begin
		CountN     = Count;
		OverflowN  = Overflow;
		UnderflowN = Underflow;

		// Priority 1: Clear operation
		if (cnt.clr) begin
			CountN     = '0;
			OverflowN  = '0;
			UnderflowN = '0;
		end else begin
			// Priority 2: Add operation (overrides inc/dec)
			if (cnt.add != '0) begin
				case (MODE)
				MODE_OVERFLOW: begin
					CountN = T'(CountN + cnt.add);
				end
				MODE_SATURATION: begin
					if (!(OverflowN || UnderflowN)) begin
						logic [W:0] wide;
						wide = {1'b0, CountN} + {1'b0, cnt.add};
						if (wide > {1'b0, cnt.overflow_value}) begin
							CountN    = cnt.overflow_value;
							OverflowN = 1'b1;
						end else begin
							CountN = T'(wide[W-1:0]);
						end
					end
				end
				endcase
			end else begin
				// Priority 3: Inc/Dec
				if (cnt.inc) begin
					case (MODE)
					MODE_OVERFLOW: begin
						CountN = T'(CountN + T'(1));
					end
					MODE_SATURATION: begin
						if (!(OverflowN || UnderflowN)) begin
							if ((CountN + T'(1)) == cnt.overflow_value) begin
								CountN    = cnt.overflow_value;
								OverflowN = 1'b1;
							end else begin
								CountN = T'(CountN + T'(1));
							end
						end
					end
					endcase
				end

				if (cnt.dec) begin
					case (MODE)
					MODE_OVERFLOW: begin
						CountN = T'(CountN - T'(1));
					end
					MODE_SATURATION: begin
						if (!(OverflowN || UnderflowN)) begin
							if (CountN == '0) begin
								UnderflowN = 1'b1;
							end else begin
								CountN = T'(CountN - T'(1));
							end
						end
					end
					endcase
				end
			end
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			Count     <= '0;
			Overflow  <= '0;
			Underflow <= '0;
		end else begin
			Count     <= CountN;
			Overflow  <= OverflowN;
			Underflow <= UnderflowN;
		end
	end

	// Outputs
	assign cnt.value     = Count;
	assign cnt.overflow  = Overflow;
	assign cnt.underflow = Underflow;

endmodule

`default_nettype wire
