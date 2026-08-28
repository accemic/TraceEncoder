// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

// C1b leg of the dual-TGC5b AXIS watchpoint chain simulation: full oracle
// (every distinct expected_hits address loaded, 851 hits per core checked in
// order) plus the timestamp legs (trTsControl.Type = TR_TS_CORE, W2 strictly
// monotonic per core, cross-core bounded) and the negative probe (a commit
// attempt while trTeControl.Enable=1 must move nothing).
// Scenario: tb_tgc5b2_axis_soc.sv. Marker: C1B_ALL_PASS.
module tb_tgc5b2_axis_soc_c1b;
	tb_tgc5b2_axis_soc #(
		.FULL_WP  (1'b1),
		.CHECK_TS (1'b1),
		.N_SLOTS  (1023)
	) t ();
endmodule : tb_tgc5b2_axis_soc_c1b

`default_nettype wire
