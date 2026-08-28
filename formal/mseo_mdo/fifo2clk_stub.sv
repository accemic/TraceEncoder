// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

//
// FORMAL HARNESS STUB (mseo_mdo gate only — never synthesized):
// replaces the gray-pointer CDC library FIFO fifo2clk_fwft with an ideal
// single-clock FWFT queue of the same depth and interface contract.
// Rationale (ASM-MDO-4 in formal/README.md): the library FIFO is a
// separately reused and sim-hardened component outside this gate's scope
// (MDO/MSEO GENERATION), and its source carries sim-only constructs
// ($typename, warning tasks) that the sv2v route cannot convert. The stub
// preserves exactly the contract the formatter relies on: FWFT visibility,
// full backpressure at capacity, no reorder, no loss below capacity.

module fifo2clk_fwft #(
	type      T                 = logic [7:0],
	int       MIN_DEPTH,
	bit       SAFE_RESETS       = 0,
	bit       EXTRA_FABRIC_REGS = 0,
	parameter FIFO_STYLE        = "block",
	parameter NAME              = ""
)(
	sink_if.impl   d,
	source_if.impl q
);
	localparam int unsigned DEPTH = MIN_DEPTH;
	localparam int unsigned CW = $clog2(DEPTH + 1);
	localparam int unsigned AW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

	T mem [DEPTH];
	logic [CW-1:0] Cnt = '0;
	logic [AW-1:0] Rd = '0;
	logic [AW-1:0] Wr = '0;

	assign d.full      = (Cnt == CW'(DEPTH));
	assign d.cnt_avail = 32'(CW'(DEPTH) - Cnt);
	assign q.valid     = (Cnt != '0);
	assign q.q         = mem[Rd];
	assign q.cnt_avail = 32'(Cnt);

	uwire do_wr = d.wr && (Cnt != CW'(DEPTH));
	uwire do_rd = q.ack && (Cnt != '0);

	always_ff @(posedge d.clk) begin
		if (d.rst) begin
			Cnt <= '0;
			Rd  <= '0;
			Wr  <= '0;
		end
		else begin
			if (do_wr) begin
				mem[Wr] <= d.d;
				Wr <= (Wr == AW'(DEPTH - 1)) ? '0 : Wr + 1'b1;
			end
			if (do_rd)
				Rd <= (Rd == AW'(DEPTH - 1)) ? '0 : Rd + 1'b1;
			Cnt <= Cnt + CW'(do_wr) - CW'(do_rd);
		end
	end

endmodule
