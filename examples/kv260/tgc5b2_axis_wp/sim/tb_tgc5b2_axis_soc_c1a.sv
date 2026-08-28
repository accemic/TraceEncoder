// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

// C1a leg of the dual-TGC5b AXIS watchpoint chain simulation: testbench
// defaults -- 13 real watchpoint addresses, no timestamp checks (trTsControl
// stays at its reset value TR_TS_NONE). Scenario: tb_tgc5b2_axis_soc.sv.
// Marker: C1A_ALL_PASS.
module tb_tgc5b2_axis_soc_c1a;
	tb_tgc5b2_axis_soc t ();
endmodule : tb_tgc5b2_axis_soc_c1a

`default_nettype wire
