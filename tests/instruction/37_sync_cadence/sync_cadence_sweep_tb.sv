// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

// PROGRAMMED-period leg of the P0-02 sync-cadence gate: same workload, but
// InstSyncMax written explicitly from +SYNCMAX=<n> (default 0). +SYNCMAX=0 is
// the NEGATIVE counter-proof (minimum period -> the stress case must still
// reproduce); the other values are the bandwidth sweep behind the reset-value
// choice. Scenario: sync_cadence_core.sv; gate:
// scripts/cli_synccadence_test.sh.
module sync_cadence_sweep_tb;
	sync_cadence_core #(
		.WRITE_MAX (1'b1),
		.PFX       ("sync_cadence_sweep_tb")
	) core ();
endmodule : sync_cadence_sweep_tb

`default_nettype wire
