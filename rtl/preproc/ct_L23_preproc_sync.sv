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
* @brief    Accemic C-Trace periodic / one-shot synchronization generator.
*
* @details
*   Generates a `nexus_sync_reason_e` in the TIP clock domain which is later
*   consumed by the eTIP composer. Sync events are retire-qualified (emitted
*   only when `tip.iretire` is asserted) so that synchronization aligns with
*   architectural boundaries.
*
*   Supported sources:
*   - periodic sync based on programmable counters (cycles / instructions /
*     retired half-words / wall clock)
*   - one-shot sync on exit from reset (first retired instruction)
*   - external sync requests (with lock/ack handshake)
*
*   The module exposes a selectable `extra_delay` pipeline tap to time-align
*   the sync reason with other preprocessing paths.
*/

`undef	MY_DEBUG
`ifdef	MY_DEBUG
`define	MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define	MY_MARK_DEBUG
`endif

import nexus::*;
import nexus_vendor::*;
import counter_pkg::*;
import tip_pkg::*;
import ct_cs_cpuif_pkg::*;
import ct_pkg::*;

module ct_L23_preproc_sync (
	input uwire logic 			clk, 			    	    // trace input clock
	input uwire logic 			rst,		    		    // reset
	tip_if.slave				tip,    				    // TIP from CPU
	input uwire logic           wall_clk_rst,
	input uwire logic           wall_clk,
	input uwire logic           sync_req_atb_synq,          // CDC required
	input uwire logic           synq_req_trace_byte_count,  // CDC required
	input uwire logic           synq_req_trace_msg_count,   // CDC required
	ct_sync_if.master           sync,
	ct_cs_tipclk_if.slave       cs_tip,					    // control / status interface
	output delay_t              internal_delay,             // delay of this component including all submodules
	input uwire delay_t         extra_delay                 // extra delay to be added for syncronizing preproc modules
);

	logic                      SyncCntClr = 1;
	uwire ct_synccnt_counter_t sync_count_max = 1 << (cs_tip.trTeInstSyncMax+4);

	//----------------------------------------------------------------------------
	// Count tip cycles
	//----------------------------------------------------------------------------
	counter_if #(.T(ct_synccnt_counter_t))                         cnt_tipcycles ();
	counter    #(.T(ct_synccnt_counter_t), .MODE(MODE_SATURATION)) cnt_tipcycles_inst (.clk, .rst, .cnt (cnt_tipcycles));
	assign cnt_tipcycles.overflow_value = sync_count_max;
	assign cnt_tipcycles.inc            = '1;
	assign cnt_tipcycles.dec            = '0;
	assign cnt_tipcycles.clr            = SyncCntClr;

	//----------------------------------------------------------------------------
	// Count tip instructions
	//----------------------------------------------------------------------------
	counter_if #(.T(ct_synccnt_counter_t))                         cnt_tipinstructions ();
	counter    #(.T(ct_synccnt_counter_t), .MODE(MODE_SATURATION)) cnt_tipinstructions_inst (.clk, .rst, .cnt (cnt_tipinstructions));
	assign cnt_tipinstructions.overflow_value   = sync_count_max;
	assign cnt_tipinstructions.inc              = tip.iretire; // $countones(tip.iretire);
	assign cnt_tipinstructions.dec              = '0;
	assign cnt_tipinstructions.clr              = SyncCntClr;

	//----------------------------------------------------------------------------
	// Count tip halfwords
	//----------------------------------------------------------------------------
	counter_if #(.T(ct_synccnt_counter_t))                         cnt_tiphalfword ();
	counter    #(.T(ct_synccnt_counter_t), .MODE(MODE_SATURATION)) cnt_tiphalfword_inst (.clk, .rst, .cnt (cnt_tiphalfword));
	assign cnt_tiphalfword.overflow_value   = sync_count_max;
	assign cnt_tiphalfword.inc              = tip.iretire ? tip.ilastsize : '0;
	assign cnt_tiphalfword.dec              = '0;
	assign cnt_tiphalfword.clr              = SyncCntClr;

	//----------------------------------------------------------------------------
	// Count wallclock (with cdc to tip_clk)
	//----------------------------------------------------------------------------
	counter_if #(.T(ct_synccnt_counter_t)) cnt_wall_clk ();
	assign cnt_wall_clk.inc             = '1;
	assign cnt_wall_clk.dec             = '0;
	assign cnt_wall_clk.overflow_value  = sync_count_max;
	logic  cnt_wall_clk_clr_cdc;
	assign cnt_wall_clk.clr = cnt_wall_clk_clr_cdc;

	counter #(.T(ct_synccnt_counter_t), .MODE(MODE_SATURATION))  counter_wallclk_inst(
		.clk(wall_clk),
		.rst(wall_clk_rst),
		.cnt(cnt_wall_clk)
	);

	vector_cdc2 #( .DATA_WIDTH (1))   // do CDC
	cnt_wall_clk_clr_cdc_inst (
		.d_clk  (clk),
		.d_rst  (rst),
		.d_data (SyncCntClr),
		.q_clk  (wall_clk),
		.q_rst  (wall_clk_rst),
		.q_data (cnt_wall_clk_clr_cdc)
	);

	logic cnt_wall_clk_overflow_cdc;

	vector_cdc2 #( .DATA_WIDTH (1))   // do CDC
	cnt_wall_clk_overflow_cdc_inst (
		.d_clk  (wall_clk),
		.d_rst  (wall_clk_rst),
		.d_data (cnt_wall_clk.overflow),
		.q_clk  (clk),
		.q_rst  (rst),
		.q_data (cnt_wall_clk_overflow_cdc)
	);

	//----------------------------------------------------------------------------
	// External Sync Requests
	//----------------------------------------------------------------------------

	logic                                       ExtSyncAck;
	uwire                                       do_extsync;
	logic                                       extsync_req;
	assign extsync_req = (   synq_req_trace_byte_count
						 ||  synq_req_trace_msg_count
						 || (sync_req_atb_synq && cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_ATB));

	signal_ack_lock_fsm #(.DO_CDC(1))
	do_sync_ack_lock_fsm (
		.clk,
		.rst,
		.in(extsync_req),
		.ack(ExtSyncAck),
		.out(do_extsync)
	);

	//----------------------------------------------------------------------------
	// Compute output
	//----------------------------------------------------------------------------

	nexus_sync_reason_e	SyncReason = NEXUS_SYNC_NONE;
	logic               ExitFromSystemReset = '1;
	// Pending TRACE_ENABLE one-shot: latched on every rising edge of effective
	// instruction tracing and consumed by the first qualifying retired
	// instruction. The post-reset EXIT_FROM_SYS_RST opportunity wins over this
	// when both are pending in the same cycle.
	//
	// Effective instruction tracing = trTeEnable && trTeInstTracing. Keying the
	// one-shot on this (rather than just trTeEnable) means resuming instruction
	// tracing mid-stream -- whether by Enable 0->1 or by InstTracing 0->1 with
	// Enable already high -- re-anchors the decoder with a TRACE_ENABLE sync.
	logic               ExitFromTraceEnable    = '0;
	logic               PrevInstTraceActiveSync = '0;
	uwire               inst_trace_active = cs_tip.trTeEnable && cs_tip.trTeInstTracing;

	uwire is_overflow =   (cnt_tipcycles.overflow       && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_CLK_CYCLES  ))
						 ||(cnt_tiphalfword.overflow     && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_HALFWORDS   ))
						 ||(cnt_tipinstructions.overflow && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_INSTRUCTIONS))
						 ||(cnt_wall_clk_overflow_cdc    && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_WALL_CLK    ));

	always_ff @(posedge clk) begin
		// Default: no sync event
		SyncReason  <= NEXUS_SYNC_NONE;

		if (rst) begin
			ExitFromSystemReset     <= '1;
			ExitFromTraceEnable     <= '0;
			PrevInstTraceActiveSync <= '0;
			ExtSyncAck              <= '0;
			SyncCntClr              <= '1;
		end
		else begin
			if (!do_extsync && ExtSyncAck) begin
				ExtSyncAck <= 0;
			end

			// Latch a pending TRACE_ENABLE on every 0->1 transition of effective
			// instruction tracing (Enable && InstTracing). The one-shot fires on
			// the next qualifying iretire (and is overridden by the post-reset
			// EXIT_FROM_SYS_RST path when both are pending). Keying on the
			// combined signal handles both initial enable and mid-stream resume
			// after an instruction-tracing pause.
			PrevInstTraceActiveSync <= inst_trace_active;
			if (inst_trace_active && !PrevInstTraceActiveSync) begin
				ExitFromTraceEnable <= '1;
			end

			// IMPORTANT: The periodic sync generator must operate even if there are
			// long gaps without retired instructions. Otherwise an overflow can
			// happen while SyncCntClr is still asserted, which would prevent any
			// periodic sync from being emitted.
			//
			// Therefore, we update the overflow/clear state machine every cycle.

			if (ExitFromSystemReset && tip.iretire) begin
				// Consume the one-shot post-reset sync opportunity on the first
				// retired instruction, but only emit a sync message when both
				// the master Enable and InstTracing are asserted.
				if (cs_tip.trTeEnable && cs_tip.trTeInstTracing) begin
					SyncReason <= NEXUS_SYNC_EXIT_FROM_SYS_RST;
					// EXIT_FROM_SYS_RST subsumes the TRACE_ENABLE one-shot.
					ExitFromTraceEnable <= '0;
				end
				ExitFromSystemReset <= '0;
				SyncCntClr    <= '1;
			end
			else if (cs_tip.trTeEnable && cs_tip.trTeInstTracing && ExitFromTraceEnable && tip.iretire) begin
				// First qualifying iretire after the encoder was enabled
				// mid-stream (and the post-reset opportunity was already
				// consumed): emit a TRACE_ENABLE sync so the decoder can
				// re-anchor to the current PC.
				SyncReason          <= NEXUS_SYNC_TRACE_ENABLE;
				ExitFromTraceEnable <= '0;
				SyncCntClr          <= '1;
			end
			else if (cs_tip.trTeEnable && cs_tip.trTeInstTracing && do_extsync && tip.iretire) begin
				SyncReason    <= NEXUS_SYNC_PERIODIC;
				ExtSyncAck    <= '1;
				SyncCntClr    <= '1;
			end
			else if (cs_tip.trTeEnable && cs_tip.trTeInstTracing && is_overflow && !SyncCntClr) begin
				// Once overflow is detected and counters are not currently being cleared,
				// generate periodic sync on a retired instruction.
				//
				// IMPORTANT:
				// tip.iretire can be 0 for extended periods (e.g. due to TB driving policy
				// or real CPU stalls). We must not immediately assert SyncCntClr in a cycle
				// without iretire, otherwise the overflow condition is cleared before we
				// ever emit the periodic sync.
				if (tip.iretire) begin
					SyncReason <= NEXUS_SYNC_PERIODIC;
					SyncCntClr <= '1;
				end
			end
			else if (!is_overflow && SyncCntClr) begin
				// Release clear once overflow condition is gone.
				SyncCntClr <= '0;
			end
		end
	end

	nexus_sync_reason_e [EXTRA_DELAY_MAX:0]	SyncReasonPipe;

	always_ff @(posedge clk) begin
		if (rst) begin
			// Clear pipe
			for (int idx = 0; idx <= EXTRA_DELAY_MAX; idx++) begin
				SyncReasonPipe[idx]  <= NEXUS_SYNC_NONE;
			end
		end
		else begin
			// stage 0 capture
			SyncReasonPipe[0]    <= SyncReason;

			// shift through remaining stages
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				SyncReasonPipe[idx]  <= SyncReasonPipe[idx-1];
			end
		end
	end

	// Output is at the tail of the pipeline
	assign sync.reason  = SyncReasonPipe[extra_delay];
	assign internal_delay   = 2;

endmodule // ct_L23_preproc_csc

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
