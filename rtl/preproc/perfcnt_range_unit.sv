// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Range-membership wrapper around vector_range_checker.
 *
 * @details
 *   Thin parameterizable wrapper that reports whether `data_in` falls within
 *   any of the N [refs_low, refs_high] ranges, exposing hit / no_hit and the
 *   matching range index. Used by ct_L23_preproc_perfcnt to qualify the
 *   per-range performance counters.
 */

module perfcnt_range_unit #(
	type T           = logic [31:0],
	int  N           = 1,
	int  EXTRA_DELAY = 0
) (
	input  uwire logic                 clk,
	input  uwire logic                 rst,
	input  uwire logic                 valid,
	input  uwire T                     data_in,
	input  uwire T [N-1:0]             refs_low,
	input  uwire T [N-1:0]             refs_high,
	output uwire logic                 hit,
	output uwire logic                 no_hit,
	output uwire logic [$clog2(N)-1:0] hit_index
);
	vector_range_checker #(
		.T(T), .N(N), .EXTRA_DELAY(EXTRA_DELAY)
	) u_vrc (
		.clk,
		.rst,
		.valid,
		.data_in,
		.refs_low,
		.refs_high,
		.hit,
		.no_hit,
		.hit_index
	);
endmodule // perfcnt_range_unit

`default_nettype wire
