// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
`default_nettype none
// MODE 0 with the SOFTWARE instrumentation ON (cap_every = 4). This is the
// leg that proves the ACT-CAP doorbell path works end to end.
module tb_rvcfi_e2e_cap;
	tb_rvcfi_e2e #(.MODE(0), .CAPEVERY(4), .OUT0("rvcfi_e2e_cap_core0.hex"), .OUT1("rvcfi_e2e_cap_core1.hex")) t ();
endmodule : tb_rvcfi_e2e_cap
`default_nettype wire
