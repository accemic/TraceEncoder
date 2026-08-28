// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
//
// Diagnostic twin of the malloc leg: samples each core's retired PC through
// the hierarchy and prints it every 20 000 cycles, so a program that stops
// issuing records can be located without a trace decoder. Short MAX_CYCLES.
module tb_rvcfi_e2e_malloc_dbg;
	tb_rvcfi_e2e #(
		.PROG0("../../examples/kv260/tgc5b2_rvcfi/sw/malloc/malloc_core0.hex"),
		.PROG1("../../examples/kv260/tgc5b2_rvcfi/sw/malloc/malloc_core1.hex"),
		.WP0  ("../../examples/kv260/tgc5b2_rvcfi/sw/malloc/wp_table_none.txt"),
		.WP1  ("../../examples/kv260/tgc5b2_rvcfi/sw/malloc/wp_table_none.txt"),
		.MODE(0), .ITERS(1), .CAPEVERY(0), .MAX_CYCLES(400_000),
		.OUT0("rvcfi_e2e_malloc_dbg_core0.hex"), .OUT1("rvcfi_e2e_malloc_dbg_core1.hex")
	) t ();

	logic [31:0] pc0 = '0, pc1 = '0, prev0 = '0, prev1 = '0;
	int unsigned n0 = 0, n1 = 0, cyc = 0;
	always @(posedge t.clk) begin
		cyc <= cyc + 1;
		if (t.dut.soc0.h2e_inst_iretire) begin pc0 <= t.dut.soc0.h2e_inst_iaddr; n0 <= n0 + 1; end
		if (t.dut.soc1.h2e_inst_iretire) begin pc1 <= t.dut.soc1.h2e_inst_iaddr; n1 <= n1 + 1; end
		if (cyc % 20000 == 0) begin
			$display("DBG cyc=%0d core0 pc=%08h retired=%0d (%s) | core1 pc=%08h retired=%0d (%s)",
			         cyc, pc0, n0, (pc0 == prev0) ? "STUCK" : "moving", pc1, n1, (pc1 == prev1) ? "STUCK" : "moving");
			prev0 <= pc0; prev1 <= pc1;
		end
	end
endmodule
