// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @brief   Asynchronous assert, synchronous deassert reset synchronizer (wr_clk -> rd_clk)
 */

module reset_cdc #(
  parameter bit ACTIVE_HIGH = 1'b1  // 1: reset is active-high; 0: active-low
)(
	input  uwire clk,    // destination clock domain
	input  uwire rst_in, // reset from source domain (asynchronous to clk)
	output logic rst_out // reset synchronized to clk (same polarity as input)
);

	// Two-stage synchronizer; mark as CDC registers
	(* ASYNC_REG = "TRUE" *)(* SHREG_EXTRACT = "NO" *)
	logic [1:0] sync_ff;

	// Asynchronous assertion, synchronous deassertion
	generate
		if (ACTIVE_HIGH) begin : g_ah
			// Async assert on POSedge of wr_rst_in; release synchronously on clk
			always_ff @(posedge clk or posedge rst_in) begin
				if (rst_in) begin
					sync_ff <= 2'b11;               // hold asserted (high)
				end else begin
					sync_ff <= {1'b0, sync_ff[1]};  // shift toward deassertion
				end
			end
			assign rst_out = sync_ff[0];
		end else begin : g_al
			// Async assert on NEGedge of wr_rst_in; release synchronously on clk
			always_ff @(posedge clk or negedge rst_in) begin
				if (!rst_in) begin
					sync_ff <= 2'b00;               // hold asserted (low)
				end else begin
					sync_ff <= {1'b1, sync_ff[1]};  // shift toward deassertion (high)
				end
			end
			assign rst_out = sync_ff[0];
		end
	endgenerate
endmodule
