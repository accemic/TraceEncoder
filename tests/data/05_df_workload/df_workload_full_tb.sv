// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

// FULL-mode (DataAddrCompress = reset) baseline leg of the P3 DF-bandwidth
// workload -- identical access sequence, uncompressed DF addresses
// (scenario: df_workload_core.sv; gate: scripts/cli_dfworkload_test.sh).
module df_workload_full_tb;
	df_workload_core #(
		.USE_XOR (1'b0),
		.PFX     ("df_workload_full_tb")
	) core ();
endmodule : df_workload_full_tb

`default_nettype wire
