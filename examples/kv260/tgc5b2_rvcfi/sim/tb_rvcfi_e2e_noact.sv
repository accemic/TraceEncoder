// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
`default_nettype none
// Diagnostic leg: MODE 0 with the ACT-CAP doorbell conversion OFF. Isolates
// the software-instrumentation path from everything else in ONE run.
module tb_rvcfi_e2e_noact;
	tb_rvcfi_e2e #(.MODE(0), .EN_ACTCAP(1'b0), .OUT0("rvcfi_e2e_noact_core0.hex"), .OUT1("rvcfi_e2e_noact_core1.hex")) t ();
endmodule : tb_rvcfi_e2e_noact
`default_nettype wire
