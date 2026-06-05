// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 * Copyright (c) 2025 Accemic Technologies GmbH, Kiefersfelden, Germany
 *
 * @file    vector_range_checker.sv
 * @author  Alexander Weiss <aweiss@accemic.com>
 * @author  Albert Schulz <aschulz@accemic.com>
 *
 * @brief   Compare input against list of inclusive ranges and report hit/index with programmed delay.
 *
 * @description
 *   The vector_range_checker module implements a fully parameterized comparator engine for matching
 *   a given input value against a configurable list of inclusive ranges [refs_low..refs_high].
 *   For each clock cycle, valid input is broadcasted to all range comparators and evaluated in parallel.
 *   The module applies pipelined registers to accommodate extra output latency, providing synchronous outputs
 *   reporting whether a match was found, the absence of a match, and the index of the first matching range.
 *   A priority encode mechanism ensures deterministic selection of the lowest index on multiple matches.
 *   Typical use-cases include address filtering, access control, or region-based signaling in CPUs or peripherals.
 *
 *   Comparator engine:
 *     - Evaluates N parallel inclusive ranges (data_in in [refs_low[i], refs_high[i]]).
 *     - Implements priority selection for lowest matching index.
 *     - Pipeline supports programmable output delay for synchronization (EXTRA_DELAY).
 *
 *   Selection and result:
 *     - Outputs pipeline-registered hit, no_hit, and hit_index.
 *     - Registers shift through the pipeline stages.
 *     - Latency is 1 + EXTRA_DELAY cycles from valid input to valid output.
 *
 * @ports
 *   clk          Trace clock.
 *   rst          Synchronous, active-high reset.
 *   valid        Asserted when input value is valid.
 *   data_in      Input value to match.
 *   refs_low     Array of lower bounds for each range comparator.
 *   refs_high    Array of upper bounds for each range comparator.
 *   hit          Asserted when at least one range matches input.
 *   no_hit       Asserted when no range matches input.
 *   hit_index    Index of first matching range (priority-encoded).
 *
 * @notes
 *   - Parameter T sets the bit-width of input and bounds (e.g. logic[31:0] for 32 bits).
 *   - Parameter N defines number of parallel comparators (default: 8).
 *   - Parameter EXTRA_DELAY defines extra pipeline output delay (default: 0).
 *   - INTERNAL_DELAY reports total pipeline delay (1 + EXTRA_DELAY).
 *   - Priority is given to the lowest index on multiple matches.
 */

module vector_range_checker #(
	parameter int N             	= 8,
	parameter type T            	= logic[7:0],
	localparam int INTERNAL_DELAY 	= 1,                  // externally readable latency of this module
	parameter  int EXTRA_DELAY    	= 0
) (
	input  uwire                   		clk,
	input  uwire                   		rst,            // synchronous active-high reset
	input  uwire                   		valid,
	input  T                       		data_in,
	input  T [N-1:0]               		refs_low,
	input  T [N-1:0]               		refs_high,
	output uwire logic                  hit,
	output uwire logic				   	no_hit,
	output uwire logic [$clog2(N)-1:0]  hit_index
);

	// Stage 0: combinational range match
	uwire logic [N-1:0] is_match;
	generate
		for (genvar i = 0; i < N; i++) begin : RANGE_COMPARE
			assign is_match[i] = valid && ((data_in >= refs_low[i]) && (data_in <= refs_high[i]));
		end
	endgenerate

	// Priority encode combinationally
	logic                        comb_hit;
	logic					     comb_no_hit;
	logic [$clog2(N)-1:0]        comb_index;
	always_comb begin
		comb_hit    = |is_match;
		comb_no_hit = valid && !comb_hit;
		comb_index = '0;
		for (int j = 0; j < N; j++) begin
			if (is_match[j]) begin
				comb_index = j;
				break;
			end
		end
	end

	// Pipeline registers for delay

	typedef struct packed {
		logic           		hit;
		logic					no_hit;
		logic[$clog2(N)-1:0]   	hit_index;
	} pipe_t;

	pipe_t  [EXTRA_DELAY:0] vrc_pipe;

	always_ff @(posedge clk) begin
		if (rst) begin
			vrc_pipe <= '0;
		end else begin
			// stage 0 capture
			vrc_pipe[0].hit           <= comb_hit;
			vrc_pipe[0].no_hit		  <= comb_no_hit;
			vrc_pipe[0].hit_index     <= comb_index;
			// shift through remaining stages
			for (int idx = 1; idx <= EXTRA_DELAY; idx++) begin
				vrc_pipe[idx]       <= vrc_pipe[idx-1];
			end
		end
	end

	// Output is at the tail of the pipeline
	assign hit       	= vrc_pipe[EXTRA_DELAY].hit;
	assign no_hit		= vrc_pipe[EXTRA_DELAY].no_hit;
	assign hit_index 	= vrc_pipe[EXTRA_DELAY].hit_index;

endmodule
`default_nettype wire