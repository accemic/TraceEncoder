// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Albert Schulz <aschulz@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder timestamp unit.
 *
 * @details
 *   Provides the selected timestamp value based on the trTsControl CSR.
 *   - TR_TS_NONE:   outputs zero
 *   - TR_TS_SYSTEM: free-running internal counter (tip_clk, prescaled)
 *   - TR_TS_CORE:   pass-through of tip._time from the CPU
 *
 *   Controlled by:
 *     trTsActive   - primary enable for the counter
 *     trTsCount    - counter run/stop
 *     trTsReset    - synchronous reset of the counter
 *     trTsPrescale - prescale by 2^(2n): 1, 4, 16, 64
 */

import counter_pkg::*;
import tip_pkg::*;
import ct_pkg::*;
import ct_cs_cpuif_pkg::*;

module ct_L23_preproc_ts (
	input  uwire logic      clk,
	input  uwire logic      rst,
	ct_cs_tipclk_if.slave   cs_tip,
	input  uwire tip_time_t tip_time,
	output tip_time_t       ts_value
);

	// ----------------------------------------------------------------
	// Internal timestamp counter (free-running, MODE_OVERFLOW)
	// ----------------------------------------------------------------
	counter_if #(.T(tip_time_t)) cnt_ts ();
	counter    #(.T(tip_time_t), .MODE(MODE_OVERFLOW)) cnt_ts_inst (.clk, .rst, .cnt(cnt_ts));

	// Prescaler: generate tick every 2^(2*prescale) cycles
	logic [5:0] PrescaleCnt;

	always_ff @(posedge clk) begin
		if (rst || cs_tip.trTsReset)
			PrescaleCnt <= '0;
		else if (cs_tip.trTsActive && cs_tip.trTsCount)
			PrescaleCnt <= PrescaleCnt + 1;
	end

	logic prescale_tick;
	always_comb begin
		case (cs_tip.trTsPrescale)
			2'd0: prescale_tick = 1'b1;
			2'd1: prescale_tick = (PrescaleCnt[1:0] == '0);
			2'd2: prescale_tick = (PrescaleCnt[3:0] == '0);
			2'd3: prescale_tick = (PrescaleCnt[5:0] == '0);
		endcase
	end

	assign cnt_ts.inc            = cs_tip.trTsActive && cs_tip.trTsCount && prescale_tick;
	assign cnt_ts.dec            = '0;
	assign cnt_ts.add            = '0;
	assign cnt_ts.clr            = cs_tip.trTsReset;
	assign cnt_ts.overflow_value = '1;

	// ----------------------------------------------------------------
	// Timestamp source selection
	// ----------------------------------------------------------------
	always_comb begin
		case (cs_tip.trTsType)
			ct_cs_cpuif__te__trTsControl__trTsType_e__TR_TS_SYSTEM: ts_value = cnt_ts.value;
			ct_cs_cpuif__te__trTsControl__trTsType_e__TR_TS_CORE:   ts_value = tip_time;
			default:                                              ts_value = '0;
		endcase
	end

endmodule

`default_nettype wire
