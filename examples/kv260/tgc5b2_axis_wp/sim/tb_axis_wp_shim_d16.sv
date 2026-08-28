// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

// FIFO_DEPTH=16 leg of the ct_axis_wp_shim unit bench (scenario:
// tb_axis_wp_shim.sv; both legs run in `make sim-axis-wp-shim`).
module tb_axis_wp_shim_d16;
	tb_axis_wp_shim #(.DEPTH(16)) t ();
endmodule : tb_axis_wp_shim_d16

`default_nettype wire
