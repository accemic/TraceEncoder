// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @file    ct_L23_preproc_df.sv
 * @brief   Preprocessing stage for data-flow hit consolidation and pipeline alignment.
 *
 * @description
 *   This stage combines data-retire TIP events with data filter and data-address range
 *   search results to produce a consolidated data-flow hit signal. It provides a selectable
 *   extra pipeline delay for downstream synchronization with peer preprocessing stages.
 *
 *   Data qualification:
 *     - daddr_valid qualifies data-flow events as tip.dretire && trTeDataTracing enabled
 *       && (dtype == LOAD || STORE)
 *     - Consolidates df_filter_hit and df_range_hit into a unified df_hit output
 *
 *   Pipeline architecture:
 *     - Implements a shift register of depth EXTRA_DELAY_MAX+1
 *     - Output is tapped at configurable extra_delay index for alignment
 *     - All stages cleared synchronously on reset
 *
 * @ports
 *   clk                  Trace clock (TIP domain).
 *   rst                  Synchronous reset.
 *   tip                  TIP ingress interface (tip_if) providing dretire, dtype, daddr.
 *   df_filter_hit_valid  Filter result valid flag.
 *   df_filter_hit        Filter match result.
 *   df_range_hit_valid   Range search result valid flag.
 *   df_range_hit         Range search match result.
 *   df_hit               Consolidated data-flow hit output (after extra_delay stages).
 *   cs_tip               Control/status interface (ct_cs_tipclk_if, TIP clock domain).
 *   internal_delay       Reported intrinsic latency (fixed at 1 cycle).
 *   extra_delay          External pipeline alignment to match peer preproc stages.
 *
 * @notes
 *   - internal_delay is hardcoded to 1, representing the single pipeline stage before
 *     the configurable delay tap.
 *   - df_hit combines both filter and range results with daddr_valid qualification.
 *   - trTeDataTracing control bit gates all data-flow hit generation.
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import tip_pkg::*;
import ct_cs_cpuif_pkg::*;
import ct_pkg::*;

module ct_L23_preproc_df #(
	// DIM currently unused (kept for backwards compatibility / symmetry with other preproc blocks)
	int DIM = 4,
	// Keep integration/TB compatibility: other preproc modules use ct_pkg::EXTRA_DELAY_MAX.
	int EXTRA_DELAY_MAX = ct_pkg::EXTRA_DELAY_MAX,
	// When 1: LOADs emit df_qualifier.hit at lresp time (not dretire); STOREs unchanged.
	// Compatible with the split-load interface (sdata/lresp/ldata).
	bit SPLIT_DATA_ACCESS = 0
)(
	input uwire logic           clk,                    // trace input clock
	input uwire logic           rst,                    // reset
	tip_if.slave                tip,                    // TIP from CPU
	ct_hit_if.slave             df_filter,              // input from comp_filters
	ct_hit_if.slave             df_range,               // input from df_range
	ct_hit_if.master            df_qualifier,           // consolidated output to etip composer
	ct_cs_tipclk_if.slave       cs_tip,                 // control / status interface
	output delay_t              internal_delay,         // delay of this component including all submodules
	input uwire delay_t         extra_delay             // extra delay to be added for syncronizing preproc modules
);

	logic  valid;
	assign valid =     tip.dretire
					&& cs_tip.trTeDataTracing
					&& ((tip.dtype == LOAD) || (tip.dtype == STORE));

	// split-load qualifiers (active only when SPLIT_DATA_ACCESS=1)
	logic load_dretire;
	logic store_dretire;
	logic lresp_valid;
	assign load_dretire  = tip.dretire && cs_tip.trTeDataTracing && (tip.dtype == LOAD);
	assign store_dretire = tip.dretire && cs_tip.trTeDataTracing && (tip.dtype == STORE);
	assign lresp_valid   = tip.lresp[1]; // bit[1]=1: lresp=2 (OK) or 3 (error)

	// pending load filter result — captured at load dretire, emitted at lresp (split mode)
	logic PendingLoadHit;
	logic PendingLoadHitValid;

	typedef struct packed {
		logic                           hit_valid;
		logic                           hit;
	} hit_struct_t;

	hit_struct_t [EXTRA_DELAY_MAX:0] HitPipe ;

	always_ff @(posedge clk) begin
		if (rst) begin
			HitPipe             <= '0;
			PendingLoadHit      <= '0;
			PendingLoadHitValid <= '0;
		end
		else begin
			if (SPLIT_DATA_ACCESS) begin
				// LOAD: capture filter result at dretire; emit into HitPipe at lresp
				// STORE: emit directly at dretire (same as non-split mode)
				if (load_dretire) begin
					PendingLoadHit      <= (df_filter.hit_valid && df_filter.hit)
					                     || (df_range.hit_valid  && df_range.hit);
					PendingLoadHitValid <= df_filter.hit_valid || df_range.hit_valid;
				end
				if (lresp_valid) begin
					PendingLoadHit      <= '0;
					PendingLoadHitValid <= '0;
				end
				HitPipe[0].hit       <= (store_dretire && (  (df_filter.hit_valid && df_filter.hit)
				                                           || (df_range.hit_valid  && df_range.hit)))
				                      | (lresp_valid   && PendingLoadHit);
				HitPipe[0].hit_valid <= (store_dretire && (df_filter.hit_valid || df_range.hit_valid))
				                      | (lresp_valid   && PendingLoadHitValid);
			end else begin
				HitPipe[0].hit       <= valid && (  (df_filter.hit_valid && df_filter.hit)
				                                  || (df_range.hit_valid  && df_range.hit));
				HitPipe[0].hit_valid <= df_filter.hit_valid || df_range.hit_valid;
			end

			// shift through remaining stages
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				HitPipe[idx] <= HitPipe[idx-1];
			end
		end
	end

	assign df_qualifier.hit             = HitPipe[extra_delay].hit;
	assign df_qualifier.hit_valid       = HitPipe[extra_delay].hit_valid;
	assign internal_delay   = 1;

endmodule // ct_L23_preproc_df

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
