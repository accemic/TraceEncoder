// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Minimal ATB sink with deterministic stalls (test infrastructure).
 *
 * @details
 *   ATB consumer for unit testbenches. It releases atready after
 *   STARTUP_STALL_CYCLES and then injects stall windows of 0..
 *   MAX_STALL_CYCLES cycles. The windows are drawn from an LFSR rather than
 *   $random, which keeps a run reproducible under Verilator and across a
 *   simulation resume. Flush requests are acknowledged immediately; afvalid
 *   and syncreq stay inactive.
 *
 *   The behaviour is derived from how ct_L2_mseo_mdo_formatter_tb uses the
 *   model: the testbench referenced it before the model itself existed in
 *   this tree.
 */
module atb_sink_model #(
	int STARTUP_STALL_CYCLES = 0,
	int MAX_STALL_CYCLES     = 0
) (
	input uwire logic atb_atclk,
	input uwire logic atb_atresetn,
	atb_if.slave      atb
);

	int          startup = STARTUP_STALL_CYCLES;
	int          stall   = 0;
	logic [15:0] lfsr    = 16'hACE1;

	assign atb.afvalid = 1'b0;
	assign atb.syncreq = 1'b0;

	always_ff @(posedge atb_atclk or negedge atb_atresetn) begin
		if (!atb_atresetn) begin
			startup     <= STARTUP_STALL_CYCLES;
			stall       <= 0;
			lfsr        <= 16'hACE1;
			atb.atready <= 1'b0;
		end
		else begin
			lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
			if (startup > 0) begin
				startup     <= startup - 1;
				atb.atready <= 1'b0;
			end
			else if (stall > 0) begin
				stall       <= stall - 1;
				atb.atready <= 1'b0;
			end
			else begin
				atb.atready <= 1'b1;
				// After an accepted beat, occasionally open a new stall
				// window -- deterministically derived from the LFSR.
				if (atb.atvalid && (MAX_STALL_CYCLES > 0) && (lfsr[1:0] == 2'b01))
					stall <= int'(lfsr[7:4]) % (MAX_STALL_CYCLES + 1);
			end
		end
	end

endmodule : atb_sink_model

`default_nettype wire
