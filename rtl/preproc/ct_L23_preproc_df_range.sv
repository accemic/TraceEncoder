// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * Address: Kiefersfelden, Germany
 *
 * @file    ct_L23_preproc_df_range.sv
 * @brief   Data flow preprocessing stage for range-based address filtering.
 * @date    2025-11-01
 * @author   Alexander Weiss
 *
 * @description
 *   This module performs hardware-accelerated range-based filtering of retired
 *   *data addresses* from the TIP stream.
 *
 *   It evaluates `tip.daddr` only on cycles where `tip.dretire` is asserted and
 *   uses a binary search tree to efficiently check whether the address falls
 *   within any configured address range.
 *
 *   Key features:
 *     - Fast address range matching via vector_binary_search_2clk (RANGE mode)
 *     - Configurable pipeline depth for synchronization with other preprocessing stages
 *     - External memory initialization via write interface
 *     - Single-cycle throughput after pipeline fill
 *
 *   Use cases:
 *     - Filtering DF trace generation to specific *data* regions
 *     - Selective triggering based on retired data address ranges
 *     - Data flow analysis within specified address boundaries
 *
 *   Architecture:
 *     1. TIP interface monitors retired data addresses (tip.daddr)
 *     2. vector_binary_search_2clk performs range lookup (RANGE mode, no return value)
 *     3. Hit results propagate through configurable delay pipeline (DfRangePipe)
 *     4. Final hit_valid/hit signals indicate range match after extra_delay cycles
 *
 * @parameters
 *   DIM                Tree depth for binary search (default: 4)
 *                      Supports up to 2^DIM - 1 address ranges (15 ranges for DIM=4).
 *
 * @ports
 *   clk                Trace input clock (read clock domain)
 *   rst                Synchronous reset (active high)
 *   tip                TIP slave interface - retired data stream from CPU
 *                      .dretire: indicates valid retired data access
 *                      .daddr:   retired data address (tip_daddr_t)
 *   wext_clk           Write clock for external memory initialization
 *   wext               OCRAM write interface for configuring address ranges
 *                      Used to populate the binary search tree with [addr_low, addr_high] ranges
 *   hit_valid          Output: 1 when hit signal is valid (after pipeline delay)
 *   hit                Output: 1 when tip.daddr falls within any configured range
 *   internal_delay     Output: Total internal latency (1 + vbs_delay)
 *                      Reports the fixed delay of this module including vector_binary_search
 *   extra_delay        Input: Additional pipeline stages to apply (0 to EXTRA_DELAY_MAX)
 *                      Allows runtime synchronization with other preprocessing paths
 *
 * @timing
 *   Pipeline latency:
 *     - vector_binary_search_2clk: vbs_delay cycles (depends on DIM)
 *     - This module overhead:      1 cycle
 *     - Configurable extra delay:  extra_delay cycles
 *     - Total output delay:        1 + vbs_delay + extra_delay
 *
 *   Throughput: 1 address lookup per cycle after pipeline fill
 *
 * @memory_configuration
 *   The wext interface is used to initialize the binary search memory with address ranges.
 *   Memory format (RANGE mode, RETURN_VALUE=0):
 *     Each entry contains two keys: [addr_high | addr_low]
 *     Packed struct layout: { tip_daddr_t key[2]; }
 *     Bit layout: [key[1] | key[0]]
 *       - key[0] (addr_low):  bits [0 +: $bits(tip_daddr_t)]
 *       - key[1] (addr_high): bits [$bits(tip_daddr_t) +: $bits(tip_daddr_t)]
 *
 *   Range matching: hit = (addr_low <= tip.daddr <= addr_high)
 *
 * @example_usage
 *   // Filter data trace to tip.daddr range 0x1000-0x1FFF and 0x3000-0x3FFF
 *   // Initialize via wext interface:
 *   //   Entry 0: key[0] = 0x1000, key[1] = 0x1FFF
 *   //   Entry 1: key[0] = 0x3000, key[1] = 0x3FFF
 *
 * @notes
 *   - Address ranges must be sorted and non-overlapping for correct operation
 *   - Reset clears all pipeline stages to zero
 *   - The DfRangePipe shift register allows flexible output timing alignment
 *   - Debug macros MY_DEBUG/MY_MARK_DEBUG can be used for signal visibility
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import tip_pkg::*;
import ct_pkg::*;

module ct_L23_preproc_df_range #(
	int DIM               = 4,
	// Keep integration/TB compatibility: other preproc modules use ct_pkg::EXTRA_DELAY_MAX.
	int EXTRA_DELAY_MAX   = ct_pkg::EXTRA_DELAY_MAX
)(
	input uwire logic           clk,                    // trace input clock
	input uwire logic           rst,                    // reset
	tip_if.slave                tip,                    // TIP from CPU
	input uwire logic           wext_clk,
	ocram_write_if.impl         wext,                   // vector_binary_search memory config
	ct_hit_if.master            df_range,
	output delay_t              internal_delay,         // delay of this component including all submodules
	input uwire delay_t         extra_delay             // extra delay to be added for syncronizing preproc modules
);

	localparam type   P             = logic [0:0];

	typedef struct packed {
		logic                           hit_valid;
		logic                           hit;
	} df_range_struct_t;

	df_range_struct_t                   DfRangePipe [EXTRA_DELAY_MAX:0];
	delay_t                             vbs_delay;
	logic                               vbs_hit_valid;
	logic                               vbs_hit;

	// Instantiate binary search (range mode)
	vector_binary_search_2clk #(
		.K              (tip_daddr_t),
		.DIM            (DIM),
		.SEARCH_MODE    ("RANGE"),
		.RETURN_VALUE   (0),
		.INTERNAL_DELAY_WIDTH($bits(delay_t)))
	vbs_inst (
		.wr_clk         (wext_clk),
		.rd_clk         (clk),
		.rst,
		.valid          (tip.dretire),
		.data_in        (tip.daddr),
		.wext,
		.hit_valid      (vbs_hit_valid),
		.hit            (vbs_hit),
		.internal_delay (vbs_delay)
	);

	always_ff @(posedge clk)begin
		if (rst) begin
			// Clear pipe
			for (int i = 0; i <= EXTRA_DELAY_MAX; i++) begin
				DfRangePipe[i] <= '0;
			end
		end
		else begin
			DfRangePipe[0] <= '0;
			if (vbs_hit_valid) begin
				DfRangePipe[0].hit_valid <= '1;
				DfRangePipe[0].hit       <= vbs_hit;
			end
			// shift through remaining stages
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				DfRangePipe[idx] <= DfRangePipe[idx-1];
			end
		end
	end

	assign df_range.hit_valid   = DfRangePipe[extra_delay].hit_valid;
	assign df_range.hit         = DfRangePipe[extra_delay].hit;
	assign internal_delay       = delay_t'(vbs_delay + 1);

endmodule // ct_L23_preproc_df_range

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
