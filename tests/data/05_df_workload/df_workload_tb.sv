// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

// XOR leg of the P3 DF-bandwidth workload (scenario: df_workload_core.sv;
// gate: scripts/cli_dfworkload_test.sh).
module df_workload_tb;
	df_workload_core #(
		.USE_XOR (1'b1),
		.PFX     ("df_workload_tb")
	) core ();
endmodule : df_workload_tb

`default_nettype wire
