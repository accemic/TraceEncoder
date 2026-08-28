// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
`default_nettype none
// Diagnostic leg: MODE 0 with the software instrumentation switched OFF in
// the PROGRAM (cap_every = 0). Isolates the ACT-CAP doorbell ACCESS -- not
// just its conversion -- from everything else in one run.
module tb_rvcfi_e2e_nocap;
	tb_rvcfi_e2e #(.MODE(0), .CAPEVERY(0), .OUT0("rvcfi_e2e_nocap_core0.hex"), .OUT1("rvcfi_e2e_nocap_core1.hex")) t ();
endmodule : tb_rvcfi_e2e_nocap
`default_nettype wire
