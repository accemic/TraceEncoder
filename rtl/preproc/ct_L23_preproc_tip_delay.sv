// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @file    ct_L23_preproc_tip_delay.sv
 * @brief   TIP pipeline delay stage for multi-delay alignment.
 *
 * @details
 *   Implements a configurable pipeline for TIP events, providing delayed TIP outputs
 *   selectable per consumer. This enables flexible synchronization and alignment of
 *   TIP data across different analysis and filter modules downstream.
 *
 *   On each cycle, the incoming TIP event structure (tip_if) is transferred into a
 *   shift register; delay selection is handled via indexed outputs, enabling up to
 *   two independently delayed TIP signals. Reset logic clears all pipeline stages.
 *
 * @ports
 *   clk              Trace clock (TIP domain).
 *   rst              Synchronous reset.
 *   tip              TIP ingress interface (tip_if) carrying all event fields.
 *   tip_delayed0     Delayed TIP event (selectable delay via extra_delay0).
 *   tip_delayed1     Delayed TIP event (selectable delay via extra_delay1).
 *   internal_delay   Fixed pipeline length (nominally 1).
 *   extra_delay0     External pipeline offset for delayed TIP output 0.
 *   extra_delay1     External pipeline offset for delayed TIP output 1.
 *
 * @notes
 *   - All delayed outputs are derived from a shared shift register instance.
 *   - Delays are indexed via provided extra_delay input ports.
 *   - TIP event format and conversion handled via imported tip_pkg utilities.
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import tip_pkg::*;
import ct_pkg::*;

module ct_L23_preproc_tip_delay #(
	// Keep integration/TB compatibility: other preproc modules use ct_pkg::EXTRA_DELAY_MAX.
	int EXTRA_DELAY_MAX = ct_pkg::EXTRA_DELAY_MAX
) (
	input uwire logic   clk,            // trace input clock
	input uwire logic   rst,            // reset
	// Input / Output
	tip_if.slave        tip,            // TIP from CPU
	tip_if.master       tip_delayed0,
	tip_if.master       tip_delayed1,
	output delay_t      internal_delay, // delay of this component including all submodules
	input uwire delay_t extra_delay0,   // extra delay for tip_delayed0 to be added for syncronizing preproc modules
	input uwire delay_t extra_delay1    // extra delay for tip_delayed1 to be added for syncronizing preproc modules
);

	tip_t [EXTRA_DELAY_MAX:0]  TipPipe;
	tip_t                      tip_in;
	tip_t                      tip_out0;
	tip_t                      tip_out1;

	always_comb begin
		tip_in._time     = tip._time;
		tip_in.itype     = tip.itype;
		tip_in.ecause    = tip.ecause;
		tip_in.tval      = tip.tval;
		tip_in.priv      = tip.priv;
		tip_in.iaddr     = tip.iaddr;
		tip_in._context  = tip._context;
		tip_in.ctype     = tip.ctype;
		tip_in.iretire   = tip.iretire;
		tip_in.ilastsize = tip.ilastsize;
		tip_in.dretire   = tip.dretire;
		tip_in.dtype     = tip.dtype;
		tip_in.daddr     = tip.daddr;
		tip_in.dsize     = tip.dsize;
		tip_in.data      = tip.data;
		tip_in.sdata     = tip.sdata;
		tip_in.lresp     = tip.lresp;
		tip_in.ldata     = tip.ldata;
		// Event sideband: gated at the pipe INPUT so a profile with the
		// event group compiled out folds the pipeline bits to constants.
		tip_in.debug_mode = CT_EN_DEBUG_EVENTS ? tip.debug_mode : 1'b0;
		tip_in.evti       = CT_EN_EVTI         ? tip.evti       : 1'b0;
		tip_in.power_down = CT_EN_POWER_EVENTS ? tip.power_down : 1'b0;
		tip_in.trigger    = CT_EN_TRIG_SYNC    ? tip.trigger    : 1'b0;
		tip_in.impdef    = tip.impdef;
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			// Clear pipe
			for (int idx = 0; idx <= EXTRA_DELAY_MAX; idx++) begin
				TipPipe[idx]     <= '0;
			end
		end
		else begin
			TipPipe[0] <= tip_in;
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				TipPipe[idx]  <= TipPipe[idx-1];    // shift through remaining stages
			end
		end
	end

	// Output is at the tail of the pipeline
	always_comb begin
		tip_out0 = TipPipe[extra_delay0];
		tip_out1 = TipPipe[extra_delay1];

		tip_delayed0._time     = tip_out0._time;
		tip_delayed0.itype     = tip_out0.itype;
		tip_delayed0.ecause    = tip_out0.ecause;
		tip_delayed0.tval      = tip_out0.tval;
		tip_delayed0.priv      = tip_out0.priv;
		tip_delayed0.iaddr     = tip_out0.iaddr;
		tip_delayed0._context  = tip_out0._context;
		tip_delayed0.ctype     = tip_out0.ctype;
		tip_delayed0.iretire   = tip_out0.iretire;
		tip_delayed0.ilastsize = tip_out0.ilastsize;
		tip_delayed0.dretire   = tip_out0.dretire;
		tip_delayed0.dtype     = tip_out0.dtype;
		tip_delayed0.daddr     = tip_out0.daddr;
		tip_delayed0.dsize     = tip_out0.dsize;
		tip_delayed0.data      = tip_out0.data;
		tip_delayed0.sdata     = tip_out0.sdata;
		tip_delayed0.lresp     = tip_out0.lresp;
		tip_delayed0.ldata     = tip_out0.ldata;
		tip_delayed0.debug_mode = tip_out0.debug_mode;
		tip_delayed0.evti       = tip_out0.evti;
		tip_delayed0.power_down = tip_out0.power_down;
		tip_delayed0.trigger    = tip_out0.trigger;
		tip_delayed0.impdef    = tip_out0.impdef;

		tip_delayed1._time     = tip_out1._time;
		tip_delayed1.itype     = tip_out1.itype;
		tip_delayed1.ecause    = tip_out1.ecause;
		tip_delayed1.tval      = tip_out1.tval;
		tip_delayed1.priv      = tip_out1.priv;
		tip_delayed1.iaddr     = tip_out1.iaddr;
		tip_delayed1._context  = tip_out1._context;
		tip_delayed1.ctype     = tip_out1.ctype;
		tip_delayed1.iretire   = tip_out1.iretire;
		tip_delayed1.ilastsize = tip_out1.ilastsize;
		tip_delayed1.dretire   = tip_out1.dretire;
		tip_delayed1.dtype     = tip_out1.dtype;
		tip_delayed1.daddr     = tip_out1.daddr;
		tip_delayed1.dsize     = tip_out1.dsize;
		tip_delayed1.data      = tip_out1.data;
		tip_delayed1.sdata     = tip_out1.sdata;
		tip_delayed1.lresp     = tip_out1.lresp;
		tip_delayed1.ldata     = tip_out1.ldata;
		tip_delayed1.debug_mode = tip_out1.debug_mode;
		tip_delayed1.evti       = tip_out1.evti;
		tip_delayed1.power_down = tip_out1.power_down;
		tip_delayed1.trigger    = tip_out1.trigger;
		tip_delayed1.impdef    = tip_out1.impdef;

		internal_delay = 1;
	end

endmodule // ct_L23_preproc_tip_delay

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
