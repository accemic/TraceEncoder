// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

// POSITIVE leg of the P0-02 sync-cadence gate: periodic sync switched on,
// InstSyncMax left at its RESET value (scenario: sync_cadence_core.sv;
// gate: scripts/cli_synccadence_test.sh).
module sync_default_tb;
	sync_cadence_core #(
		.WRITE_MAX (1'b0),
		.PFX       ("sync_default_tb")
	) core ();
endmodule : sync_default_tb

`default_nettype wire
