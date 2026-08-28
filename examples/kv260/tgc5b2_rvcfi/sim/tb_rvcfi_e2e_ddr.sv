// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
`default_nettype none
// N3 leg: MODE 0 with the records routed into the two DDR ring sinks
// instead of the AXIS/FIFO path. Same programs, same tables, and the bench
// requires the ring registers (wptr/beats/drops/stat) and the captured ring
// contents to agree word for word -- the transports must be
// indistinguishable to everything downstream. Scenario: tb_rvcfi_e2e.sv.
module tb_rvcfi_e2e_ddr;
	tb_rvcfi_e2e #(.MODE(0), .CAPEVERY(0), .ROUTE_DDR(1'b1), .OUT0("rvcfi_e2e_ddr_core0.hex"), .OUT1("rvcfi_e2e_ddr_core1.hex")) t ();
endmodule : tb_rvcfi_e2e_ddr
`default_nettype wire
