// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
//
// malloc leg of the end-to-end bench: the newlib malloc demo
// (sw/malloc/) on both cores, no ACT-ST sites (empty table), every record
// an ACT-CAP beat from the demo's own instrumentation. Scenario:
// tb_rvcfi_e2e.sv; the records are judged by sw/malloc/decode_malloc.py.
module tb_rvcfi_e2e_malloc;
	tb_rvcfi_e2e #(
		.PROG0("../../examples/kv260/tgc5b2_rvcfi/sw/malloc/malloc_core0.hex"),
		.PROG1("../../examples/kv260/tgc5b2_rvcfi/sw/malloc/malloc_core1.hex"),
		.WP0  ("../../examples/kv260/tgc5b2_rvcfi/sw/malloc/wp_table_none.txt"),
		.WP1  ("../../examples/kv260/tgc5b2_rvcfi/sw/malloc/wp_table_none.txt"),
		.MODE(0), .ITERS(1), .CAPEVERY(0),
		.OUT0("rvcfi_e2e_malloc_core0.hex"), .OUT1("rvcfi_e2e_malloc_core1.hex")
	) t ();
endmodule
