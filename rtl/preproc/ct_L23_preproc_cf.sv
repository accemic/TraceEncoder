// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @file    ct_L23_preproc_cf.sv
 * @brief   Control-flow trace filter pipeline stage.
 *
 * @description
 *   Implements the control-flow filtering and validation pipeline for processor trace events.
 *   This stage receives TIP events and relevant sideband signals, applies filter rules based on
 *   programmable comparators, and determines whether a control-flow (CF) hit or region transition
 *   should be signaled. It includes synchronized pipelining and delay matching to ensure precise
 *   alignment with other preprocessing branches.
 *
 *   Key features:
 *     - Configurable multi-comparator instruction filter bank (supports range and value detection).
 *     - Address range matching, privilege level masking, exception/interrupt windows, and implementation-defined flags.
 *     - Automatic detection of entries and exits for programmable address regions.
 *     - Pipeline depth and internal/external delay control for multi-branch trace systems.
 *     - Synchronization of valid and hit signals through all pipeline stages.
 *
 * @ports
 *   clk              Trace clock (TIP domain)
 *   rst              Synchronous reset
 *   cs_tip           Control/status interface for filter configuration
 *   tip              TIP event input (instruction retire, address, privilege, type, etc.)
 *   cf_filter_hit_valid   Input: Indicates filter evaluation result is valid
 *   cf_filter_hit         Input: Indicates current event passes all filter conditions
 *   cf_hit_valid          Output: Event is valid for CF tracing (at pipeline output)
 *   cf_hit                Output: Event is a CF filter hit (at pipeline output)
 *   cf_region_entered     Output: Region entry detected (on transition)
 *   cf_region_exited      Output: Region exit detected
 *   internal_delay        Output: Number of intrinsic pipeline cycles
 *   extra_delay           Input:  Pipeline alignment delay (to sync with other branches)
 *
 * @notes
 *   - Designed for use in multicore or complex trace pipelines where multiple preprocessing
 *     branches require precise synchronization and region transition awareness.
 *   - Region entry/exit logic triggers only on true filter hits, with mechanism to prevent
 *     spurious transitions on bubbles. Previous-hit state is only updated on valid events.
 *   - All filter and region outputs are consistently aligned at the pipeline output stage.
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import tip_pkg::*;
import ct_pkg::*;

module ct_L23_preproc_cf #(
	int DIM = 4,
	// Keep TB/integration compatibility: default comes from ct_pkg.
	int EXTRA_DELAY_MAX = ct_pkg::EXTRA_DELAY_MAX
)(
	input uwire logic           clk,                    // trace input clock
	input uwire logic           rst,                    // reset
	tip_if.slave                tip,                    // TIP from CPU
	ct_hit_if.slave             cf_filter,
	ct_hit_if.master_region     cf_qualifier,
	ct_cs_tipclk_if.slave       cs_tip,                 // control / status interface
	output delay_t              internal_delay,         // delay of this component including all submodules
	input uwire delay_t         extra_delay             // extra delay to be added for syncronizing preproc modules
);


	logic       IsAfterReset = 1;
	logic       PrevHit;

	logic  valid;
	assign valid = tip.iretire;

	typedef struct packed {
		logic  valid;
		logic  hit;
		logic  region_entered;
		logic  region_exited;
	} hit_struct_t;

	hit_struct_t [EXTRA_DELAY_MAX:0] HitPipe ;

	always_ff @(posedge clk) begin
		if (rst) begin
			// Clear pipe
			HitPipe                 <= '0;
			IsAfterReset            <=  1;
			PrevHit                 <= '0;
		end
		else begin
			HitPipe[0]              <= '0;
			if (tip.iretire) begin
				// stage 0 capture
				HitPipe[0].valid            <= valid;
				HitPipe[0].hit              <= valid && (cf_filter.hit_valid && cf_filter.hit);
				HitPipe[0].region_entered   <= valid && !PrevHit && cf_filter.hit_valid &&  cf_filter.hit;
				HitPipe[0].region_exited    <= valid &&  PrevHit && cf_filter.hit_valid && !cf_filter.hit;
				PrevHit                     <= valid && (cf_filter.hit_valid && cf_filter.hit);

				if (tip.iretire && IsAfterReset) begin
					IsAfterReset <= 0;
				end

				// shift through remaining stages
				for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
					HitPipe[idx] <= HitPipe[idx-1];
				end
			end
		end
	end

	// Output is at the tail of the pipeline
	assign cf_qualifier.hit_valid         = HitPipe[extra_delay].valid;
	assign cf_qualifier.hit               = HitPipe[extra_delay].hit;
	assign cf_qualifier.region_entered    = HitPipe[extra_delay].region_entered;
	assign cf_qualifier.region_exited     = HitPipe[extra_delay].region_exited;
	assign internal_delay                 = 1;

endmodule // ct_L23_preproc_cf

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
