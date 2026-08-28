// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
`default_nettype none
// MODE 3 leg of the end-to-end bench. Scenario: tb_rvcfi_e2e.sv.
// CAPEVERY=0: the software (ACT-CAP) instrumentation is OFF in these legs --
// see docs, the doorbell store currently wedges the core (named defect).
module tb_rvcfi_e2e_m3;
	tb_rvcfi_e2e #(.MODE(3), .CAPEVERY(0), .OUT0("rvcfi_e2e_m3_core0.hex"), .OUT1("rvcfi_e2e_m3_core1.hex")) t ();
endmodule : tb_rvcfi_e2e_m3
`default_nettype wire
