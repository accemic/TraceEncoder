// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author   Albert Schulz <aschulz@accemic.com>
* @author   Alexander Lange <alange@accemic.com>
*
* @brief    CEDARtrace implementation (layer 2/3):
*			- TIP preprocessing with trace filter
*			- Determining next IADDR
*			- Periodic synchronization
*			- FIFO buffered
*			- @ atb_afvalid (flush request from ATB)
*			  - TIP output to tip_fifo is stopped
*			  - a TIP side channel signal (TipToFifo.ctrl.do_flush) is set which causes a flush message through the next stages
*
*			TODO: handle do_flush if there is no new tip.iretire
*/

`undef	MY_DEBUG
`ifdef	MY_DEBUG
`define	MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define	MY_MARK_DEBUG
`endif

import ct_pkg::*;
import tip_pkg::*;

module ct_L23_preproc #(
	parameter bit SPLIT_DATA_ACCESS = 0  // propagated to df and composer_etip
) (
	// Global control (used as formal interface ports)
	input uwire logic 								tip_clk, 				// trace input clock
	input uwire logic 								tip_rst,				// reset
	input uwire logic                               wall_clk,
	input uwire logic                               wall_clk_rst,

	// Input / Output
	tip_if.slave									tip,					// TIP from CPU
	axis_if.master									axis, 					// (wide) AXI Stream to watchdog CPU
	source_if.impl  					            etip_q,                 // etip from preproc stage to processing stages
	source_if.impl  					            next_iaddr_q,           // next_iaddr from preproc stage to processing stages
	input uwire logic                               atb_afvalid,
	input uwire logic                               atb_syncreq,

	input uwire logic                               synq_req_trace_byte_count,

	// Local control
	ct_cs_tipclk_if.slave							cs_tip,					// control / status interface
	input uwire logic                               wext_clk,
	ocram_write_if.impl                             act_st_wext,            // act_st vector_binary_search memory config
	ocram_write_if.impl                             df_range_wext,          // data flow qualifier vector_binary_search memory config
	output delay_t                                  internal_delay
);

	ct_perfcnt_if   perfcnt             ();
	ct_act_cap_if   act_cap             ();
	ct_act_cap_if   act_st              ();
	ct_act_cap_if   act_cap_st          ();
	tip_if          tip_delayed_composer();    // delayed tip for axis/etip composer
	tip_if          tip_delayed_cfdf    ();    // delayed tip for cf and df
	ct_hit_if       cf_filter           ();
	ct_hit_if       df_filter           ();
	ct_hit_if       df_range            ();
	ct_hit_if       cf_qualifier        ();
	ct_hit_if       df_qualifier        ();
	ct_sync_if      sync                ();

	uwire tip_iaddr_t		next_iaddr;
	uwire                   synq_req_trace_msg_count;

	delay_t     idelay_sync_gen;
	delay_t     idelay_perfcnt;
	delay_t     idelay_act_st;
	delay_t     idelay_act_cap;
	delay_t     idelay_act_proc;
	delay_t     idelay_tip_delay;
	delay_t     idelay_comp_filters;
	delay_t     idelay_df_range;
	delay_t     idelay_df;
	delay_t     idelay_cf;
	delay_t     idelay_composer_axis;
	delay_t     idelay_composer_etip;

	int unsigned max_delay;

	delay_t     extra_delay_sync_gen;
	delay_t     extra_delay_act_st;
	delay_t     extra_delay_act_cap;
	delay_t     extra_delay_act_proc;
	delay_t     extra_delay_tip_delay_composer;
	delay_t     extra_delay_tip_delay_cfdf;
	delay_t     extra_delay_comp_filters;
	delay_t     extra_delay_df_range;
	delay_t     extra_delay_df;
	delay_t     extra_delay_cf;

	always_comb begin
		// Compute max pipeline delay across all paths without dynamic arrays / array_math.
		// Use widened arithmetic to avoid truncation when summing delay_t values.
		int unsigned d_sync;
		int unsigned d_perfcnt;
		int unsigned d_act_st;
		int unsigned d_act_cap;
		int unsigned d_tip;
		int unsigned d_comp_df;
		int unsigned d_df_range;
		int unsigned d_comp_cf;

		d_sync     = $unsigned(idelay_sync_gen);
		d_perfcnt  = $unsigned(idelay_perfcnt);
		d_act_st   = $unsigned(idelay_act_st) + $unsigned(idelay_act_proc);
		d_act_cap  = $unsigned(idelay_act_cap) + $unsigned(idelay_act_proc);
		d_tip      = $unsigned(idelay_tip_delay);
		d_comp_df  = $unsigned(idelay_comp_filters) + $unsigned(idelay_df);
		d_df_range = $unsigned(idelay_df_range) + $unsigned(idelay_df);
		d_comp_cf  = $unsigned(idelay_comp_filters) + $unsigned(idelay_cf);

		max_delay = d_sync;
		if (d_perfcnt  > max_delay) max_delay = d_perfcnt;
		if (d_act_st   > max_delay) max_delay = d_act_st;
		if (d_act_cap  > max_delay) max_delay = d_act_cap;
		if (d_tip      > max_delay) max_delay = d_tip;
		if (d_comp_df  > max_delay) max_delay = d_comp_df;
		if (d_df_range > max_delay) max_delay = d_df_range;
		if (d_comp_cf  > max_delay) max_delay = d_comp_cf;

`ifndef SYNTHESIS
		if (max_delay > EXTRA_DELAY_MAX) begin
			$error("%m: max_delay(%0d) > EXTRA_DELAY_MAX(%0d)", max_delay, EXTRA_DELAY_MAX);
		end
		if (idelay_df != idelay_cf) begin
			$error("%m: idelay_df(%0d) != idelay_cf(%0d)", idelay_df, idelay_cf);
		end
`endif

		extra_delay_sync_gen            = delay_t'(max_delay - d_sync);
		extra_delay_act_st              = delay_t'(max_delay - d_act_st);
		extra_delay_act_cap             = delay_t'(max_delay - d_act_cap);
		extra_delay_act_proc            = '0;
		extra_delay_cf                  = '0;
		extra_delay_df                  = '0;
		extra_delay_df_range            = delay_t'(max_delay - d_df_range);
		extra_delay_comp_filters        = delay_t'(max_delay - d_comp_df);
		extra_delay_tip_delay_composer  = delay_t'(max_delay - d_tip);
		extra_delay_tip_delay_cfdf      = delay_t'(max_delay - (d_tip + $unsigned(idelay_df)));
	end

	// Instantiate timestamp unit
	uwire tip_pkg::tip_time_t ts_value;
	ct_L23_preproc_ts ts_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.cs_tip,
		.tip_time           (tip._time),
		.ts_value
	);

	// Publish the current (tip-clk-domain) timestamp so the CSR shim can expose it
	// via trTsCounterHigh/Low after a safe wb_clk-side resynchronisation.
	assign cs_tip.trTeTs = ts_value;

	// Instantiate sync_gen
	ct_L23_preproc_sync sync_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip,
		.wall_clk,   .wall_clk_rst,
		.sync_req_atb_synq  (atb_syncreq),
		.synq_req_trace_byte_count,
		.synq_req_trace_msg_count,
		.sync,
		.cs_tip,
		.internal_delay     (idelay_sync_gen),
		.extra_delay        (extra_delay_sync_gen)
	);

	ct_L23_preproc_perfcnt #(
		.IADDR_RANGES       (4),
		.DADDR_RANGES       (4))
	perfcnt_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip,
		.cs_tip,
		.perfcnt,
		.internal_delay     (idelay_perfcnt)
	);

	// Instantiate act_st
	ct_L23_preproc_act_st #(
		.DIM                (M0_DIM))
	act_st_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip,
		.act_st,
		.cs_tip,
		.wext_clk,
		.wext               (act_st_wext),
		.internal_delay     (idelay_act_st),
		.extra_delay        (extra_delay_act_st)
	);

	// Instantiate act_cap
	ct_L23_preproc_act_cap act_cap_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip,
		.act_cap,
		.cs_tip,
		.internal_delay     (idelay_act_cap),
		.extra_delay        (extra_delay_act_cap)
	);

	// Instantiate act_proc
	ct_L23_preproc_act_proc act_proc_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.act_cap,
		.act_st,
		.act_cap_st,
		.cs_tip,
		.internal_delay     (idelay_act_proc),
		.extra_delay        (extra_delay_act_proc)
	);

	ct_L23_preproc_tip_delay tip_delay_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip,
		.tip_delayed0       (tip_delayed_composer),
		.tip_delayed1       (tip_delayed_cfdf),
		.internal_delay     (idelay_tip_delay),
		.extra_delay0       (extra_delay_tip_delay_composer),
		.extra_delay1       (extra_delay_tip_delay_cfdf)
	);

	ct_L23_preproc_df_range #(
		.DIM                (M1_DIM))
	df_range_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip,
		.wext_clk,
		.wext               (df_range_wext),
		.df_range,
		.internal_delay     (idelay_df_range),
		.extra_delay        (extra_delay_df_range)
	);

	ct_L23_preproc_comp_filters comp_filters_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip,
		.cs_tip,
		.cf_filter,
		.df_filter,
		.internal_delay     (idelay_comp_filters),
		.extra_delay        (extra_delay_comp_filters)
	);

	ct_L23_preproc_df #(.SPLIT_DATA_ACCESS(SPLIT_DATA_ACCESS)) df_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip                (tip_delayed_cfdf),
		.df_filter,
		.df_range,
		.df_qualifier,
		.cs_tip,
		.internal_delay     (idelay_df),
		.extra_delay        (extra_delay_df)
	);

	ct_L23_preproc_cf cf_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip                (tip_delayed_cfdf),
		.cf_filter,
		.cf_qualifier,
		.cs_tip,
		.internal_delay     (idelay_cf),
		.extra_delay        (extra_delay_cf)
	);

	// Instantiate composer_axis
	ct_L23_preproc_composer_axis composer_axis_inst(
		.clk                (tip_clk),
		.rst                (tip_rst),
		.perfcnt,
		.act_cap_st,
		.tip                (tip_delayed_composer),
		.axis,
		.internal_delay     (idelay_composer_axis)
	);


	// Instantiate composer_etip
	ct_L23_preproc_composer_etip #(.SPLIT_DATA_ACCESS(SPLIT_DATA_ACCESS)) composer_etip_inst(
		.clk                (tip_clk),
		.rst                (tip_rst),
		.ts_value,
		.act_cap_st,
		.tip                (tip_delayed_composer),
		.atb_afvalid        (atb_afvalid),
		.sync,
		.cf_qualifier,
		.df_qualifier,
		.perfcnt,
		.etip_q,
		.next_iaddr_q,
		.cs_tip,
		.synq_req_trace_msg_count,
		.internal_delay     (idelay_composer_etip)
	);

	assign internal_delay = idelay_tip_delay + extra_delay_tip_delay_composer + 1;

endmodule // ct_L23

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
