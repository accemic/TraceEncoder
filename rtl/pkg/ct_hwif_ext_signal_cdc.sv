// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CDC helper for a RDL hwif hwclr/hwset/value triple.
 *
 * @details
 *   Crosses a hwclr/hwset/value triple between a RDL hwif clock domain and an
 *   external clock domain: hwclr/hwset are strobes (ext -> hwif), value is a
 *   level (hwif -> ext).
 */

module ct_hwif_ext_signal_cdc (
	input  uwire hwif_clk,
	input  uwire hwif_rst,
	output uwire hwif_hwclr,
	output uwire hwif_hwset,
	input  uwire hwif_value,
	input  uwire ext_clk,
	input  uwire ext_rst,
	input  uwire ext_hwclr,
	input  uwire ext_hwset,
	output uwire ext_value
);

	// CDC for hwclr (ext_clk -> hwif_clk)
	strobe_cdc hwclr_cdc_inst (
		.clk1 (ext_clk),
		.rst1 (ext_rst),
		.stb1 (ext_hwclr),
		.clk2 (hwif_clk),
		.rst2 (hwif_rst),
		.stb2 (hwif_hwclr)
	);

	// CDC for hwset (ext_clk -> hwif_clk)
	strobe_cdc hwset_cdc_inst (
		.clk1 (ext_clk),
		.rst1 (ext_rst),
		.stb1 (ext_hwset),
		.clk2 (hwif_clk),
		.rst2 (hwif_rst),
		.stb2 (hwif_hwset)
	);

	// CDC for value (hwif_clk -> ext_clk)
	signal_cdc value_cdc (
		.clk (ext_clk),
		.rst (ext_rst),
		.in  (hwif_value),
		.out (ext_value)
	);

endmodule // ct_hwif_ext_signal_cdc

`default_nettype wire
