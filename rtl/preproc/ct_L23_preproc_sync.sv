// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder periodic / one-shot synchronization generator.
 *
 * @details
 *   Generates a `nexus_sync_reason_e` in the TIP clock domain which is later
 *   consumed by the eTIP composer. Sync events are retire-qualified (emitted
 *   only when `tip.iretire` is asserted) so that synchronization aligns with
 *   architectural boundaries.
 *
 *   Supported sources:
 *   - periodic sync based on programmable counters (cycles / instructions /
 *     retired half-words / wall clock / trace-output quota: emitted bytes
 *     or messages, counted in the L2 egress modules and crossed in as held
 *     overflow levels -- P2)
 *   - one-shot sync on exit from reset (first retired instruction)
 *   - external sync requests (ATB sync request input and the TE register
 *     field `trTeControl.InstSyncReq`; one lock/ack handshake each, both
 *     emitted as the explicit-request code SYNC=14 -- E-P2-1, P8)
 *
 *   The module exposes a selectable `extra_delay` pipeline tap to time-align
 *   the sync reason with other preprocessing paths.
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import nexus::*;
import nexus_vendor::*;
import counter_pkg::*;
import tip_pkg::*;
import ct_cs_cpuif_pkg::*;
import ct_pkg::*;

module ct_L23_preproc_sync (
	input uwire logic     clk,                       // trace input clock
	input uwire logic     rst,                       // reset
	tip_if.slave          tip,                       // TIP from CPU
	input uwire logic     wall_clk_rst,
	input uwire logic     wall_clk,
	// Egress-quota domain (P2): the quota counters live in the L2 egress
	// modules (proc_clk); both directions cross HERE following the
	// cnt_wall_clk pattern below.
	input uwire logic     proc_clk,
	input uwire logic     proc_rst,
	input uwire logic     sync_req_atb_synq,         // CDC required (inside signal_ack_lock_fsm)
	input uwire logic     synq_req_trace_byte_count, // proc_clk-domain HELD quota level (crossed here)
	input uwire logic     synq_req_trace_msg_count,  // proc_clk-domain HELD quota level (crossed here)
	output uwire logic    quota_cnt_clr,             // proc_clk domain: crossed SyncCntClr (rearms the egress quota counters)
	output uwire logic    quota_byte_ovf_tip,        // tip-domain crossed byte-quota level (diagnosis: SyncReqSource)
	output uwire logic    quota_msg_ovf_tip,         // tip-domain crossed msg-quota level (diagnosis: SyncReqSource)
	ct_sync_if.master     sync,
	ct_cs_tipclk_if.slave cs_tip,                    // control / status interface
	output delay_t        internal_delay,            // delay of this component including all submodules
	input uwire delay_t   extra_delay                // extra delay to be added for syncronizing preproc modules
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
	// counter_if.add left UNDRIVEN used to be the norm here: synthesis ties
	// it to 0, four-state simulation reads X and `add != '0` then evaluates
	// false, so it worked by accident. Formal had to pin it (ASM-SYNC-4).
	// Now that the half-word counter below actually uses the port, the three
	// that do not say so explicitly (D1).
	assign cnt_tipcycles.add            = '0;
	assign cnt_tipcycles.clr            = SyncCntClr;

	//----------------------------------------------------------------------------
	// Count tip instructions
	//----------------------------------------------------------------------------
	counter_if #(.T(ct_synccnt_counter_t))                         cnt_tipinstructions ();
	counter    #(.T(ct_synccnt_counter_t), .MODE(MODE_SATURATION)) cnt_tipinstructions_inst (.clk, .rst, .cnt (cnt_tipinstructions));
	assign cnt_tipinstructions.overflow_value   = sync_count_max;
	// counter_if.inc is ONE bit and adds exactly 1 per assertion, so this is
	// "beats that retired something", not an instruction count -- at a block
	// ingress one beat can carry several instructions and the cadence mode
	// ITR_SYNC_INSTRUCTIONS then counts blocks. Widening it would need the
	// counter's `add` port AND the instruction count, which a halfword sum
	// does not carry (a block of mixed RVC/32-bit sizes is ambiguous).
	// TipBeatRetires at least keeps the bit HONEST: a bare assignment would
	// truncate to the LSB, i.e. drop every even-halfword block entirely.
	assign cnt_tipinstructions.inc              = TipBeatRetires(tip.iretire);
	assign cnt_tipinstructions.dec              = '0;
	assign cnt_tipinstructions.add              = '0;   // see cnt_tipcycles.add (D1)
	assign cnt_tipinstructions.clr              = SyncCntClr;

	//----------------------------------------------------------------------------
	// Count tip halfwords
	//----------------------------------------------------------------------------
	counter_if #(.T(ct_synccnt_counter_t))                         cnt_tiphalfword ();
	counter    #(.T(ct_synccnt_counter_t), .MODE(MODE_SATURATION)) cnt_tiphalfword_inst (.clk, .rst, .cnt (cnt_tiphalfword));
	assign cnt_tiphalfword.overflow_value   = sync_count_max;
	// B-R13-1, fixed in D1. The old form was
	//     cnt_tiphalfword.inc = tip.iretire ? tip.ilastsize : '0;
	// and `counter_if.inc` is ONE bit that adds exactly 1, so what it really
	// counted was "beats whose ilastsize is odd": +1 per 32-bit instruction,
	// +0 per RVC instruction, and +0 for the 48-bit encoding (ilastsize=2)
	// as well. Measured before the fix in this module's unit testbench
	// (Test 6, rtl/preproc/test/ct_L23_preproc_sync_tb.sv): 10 RVC retires
	// moved the counter by 0, 10 32-bit retires by 10, a 5+5 mix by 5 --
	// against 10 / 20 / 15 half-words actually retired.
	//
	// The value port is `add`, and the half-word count of a beat is what
	// tip_pkg::TipBeatHalfwords answers for BOTH ingress shapes (SR:
	// 2^ilastsize, block: iretire). It must be qualified by TipBeatRetires
	// -- on a non-retiring beat the ingress leaves ilastsize undefined.
	uwire tip_icnt_t sync_beat_halfwords = TipBeatHalfwords(tip.iretire, tip.ilastsize);
	assign cnt_tiphalfword.inc              = '0;
	assign cnt_tiphalfword.add              = TipBeatRetires(tip.iretire)
	                                        ? ct_synccnt_counter_t'(sync_beat_halfwords) : '0;
	assign cnt_tiphalfword.dec              = '0;
	assign cnt_tiphalfword.clr              = SyncCntClr;

	//----------------------------------------------------------------------------
	// Count wallclock (with cdc to tip_clk)
	//----------------------------------------------------------------------------
	counter_if #(.T(ct_synccnt_counter_t)) cnt_wall_clk ();
	assign cnt_wall_clk.inc             = '1;
	assign cnt_wall_clk.dec             = '0;
	assign cnt_wall_clk.add             = '0;   // see cnt_tipcycles.add (D1)
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
	// Trace-output quota (P2, D1 option A+C): the quota counters live in the
	// L2 egress modules (proc_clk domain, one per egress path). Exactly the
	// cnt_wall_clk pattern above, with the counter body remote: SyncCntClr
	// crosses OUT to proc_clk (quota_cnt_clr rearms the egress counters),
	// the two HELD overflow levels cross IN to tip_clk and feed is_overflow
	// (the periodic arm), NOT extsync_req -- the ack/lock FSM has no
	// tip->proc return path for the rearm (analyst finding N1), while the
	// is_overflow arm inherits rearm, both resume guards and the formal
	// family from the wall-clock mode for free. Compile-gated: with
	// CT_EN_QUOTA_SYNC=0 the CDC pairs trim away and the levels are 0
	// (byte-neutral).
	//----------------------------------------------------------------------------
	logic quota_byte_ovf_cdc;
	logic quota_msg_ovf_cdc;
	if (CT_EN_QUOTA_SYNC) begin : genQuotaCdc
		vector_cdc2 #( .DATA_WIDTH (1))
		quota_cnt_clr_cdc_inst (
			.d_clk  (clk),
			.d_rst  (rst),
			.d_data (SyncCntClr),
			.q_clk  (proc_clk),
			.q_rst  (proc_rst),
			.q_data (quota_cnt_clr)
		);
		vector_cdc2 #( .DATA_WIDTH (1))
		quota_byte_ovf_cdc_inst (
			.d_clk  (proc_clk),
			.d_rst  (proc_rst),
			.d_data (synq_req_trace_byte_count),
			.q_clk  (clk),
			.q_rst  (rst),
			.q_data (quota_byte_ovf_cdc)
		);
		vector_cdc2 #( .DATA_WIDTH (1))
		quota_msg_ovf_cdc_inst (
			.d_clk  (proc_clk),
			.d_rst  (proc_rst),
			.d_data (synq_req_trace_msg_count),
			.q_clk  (clk),
			.q_rst  (rst),
			.q_data (quota_msg_ovf_cdc)
		);
	end
	else begin : genNoQuotaCdc
		assign quota_cnt_clr      = 1'b0;
		assign quota_byte_ovf_cdc = 1'b0;
		assign quota_msg_ovf_cdc  = 1'b0;
		uwire logic unused_quota_inputs = synq_req_trace_byte_count
		                               || synq_req_trace_msg_count;
	end
	// Crossed levels re-exported for the SyncReqSource=3 diagnosis in
	// ct_L23_preproc (already mode-gated at the source, see the egress
	// modules' in-module mode gate).
	assign quota_byte_ovf_tip = quota_byte_ovf_cdc;
	assign quota_msg_ovf_tip  = quota_msg_ovf_cdc;

	//----------------------------------------------------------------------------
	// External Sync Requests
	//----------------------------------------------------------------------------

	logic                                       ExtSyncAck;
	uwire                                       do_extsync;
	logic                                       extsync_req;
	// P2/D1: the two quota levels are deliberately NOT part of extsync_req
	// any more (pre-P2 they were OR-ed in here unconditionally -- the
	// latent ungated-mode defect of TASK_STATE G6). Arm 7 below is now
	// exclusively the ATB sync request (InstSyncMode 7); the quota flows
	// through is_overflow -> the periodic arm (Arm 8).
	assign extsync_req = (sync_req_atb_synq && cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_ATB);

	signal_ack_lock_fsm #(.DO_CDC(1))
	do_sync_ack_lock_fsm (
		.clk,
		.rst,
		.in(extsync_req),
		.ack(ExtSyncAck),
		.out(do_extsync)
	);

	// ----------------------------------------------------------------
	// Explicit sync request over the TE register (P8/G11,
	// trTeControl.InstSyncReq). SECOND source of the same arm, not a second
	// arm: on the wire it is the identical explicit-request code SYNC=14, and
	// sharing the arm means it inherits the anchor qualification, the resume
	// guard and the counter rearm unchanged.
	//
	// Deliberately NOT mode-gated (unlike the ATB request above): the field is
	// itself the trigger, so it works in every InstSyncMode. That is a
	// different case from the pre-P2 quota defect -- a LEVEL from a cadence
	// counter needed its mode gate, a one-shot software request does not.
	//
	// cs_tip.trTeInstSyncReq is a HELD LEVEL, the request phase of a
	// four-phase handshake the CSR shim's pacer drives (ct_sync_req_pacer):
	// it raises the level for one request at a time and withdraws it only
	// after seeing the acknowledgement below, so two requests are always a
	// full round trip apart.
	//
	// A level and not a strobe, for the same reason the ATB request path
	// above uses one (P8 closing audit B-N1): the pending latch here lives in
	// tip_rst while the pacer lives in wb_rst, and ct_encoder carries the two
	// resets as INDEPENDENT inputs. A reset on this side clears the latch
	// without an acknowledgement -- with a strobe the request would then be
	// gone for good, while a level is simply seen again and served. The
	// re-arm below is exactly that: `request up and not yet acknowledged`
	// means one is owed, no matter which side was reset.
	//
	// The pending state survives a tracing pause: unlike the hardware event
	// one-shots (EVTI, trigger) a software request is not tied to a moment in
	// the instruction stream -- it means "give me an anchor" -- so it is
	// deferred until tracing is active again rather than dropped (D-P8-6).
	// Compile-gated: with CT_EN_INST_SYNC_REQ = 0 the latch and the ack trim
	// away and the request is constant 0.
	// ----------------------------------------------------------------
	logic       TeSyncPending = 1'b0;
	logic       TeSyncAck     = 1'b0;
	uwire logic te_sync_req_lvl = CT_EN_INST_SYNC_REQ && cs_tip.trTeInstSyncReq;
	uwire logic do_tesync = CT_EN_INST_SYNC_REQ && TeSyncPending;
	// The acknowledgement phase: a LEVEL that goes up when the request has
	// been served and down again when the pacer has withdrawn the request.
	assign cs_tip.trTeInstSyncReqAck = TeSyncAck;

	//----------------------------------------------------------------------------
	// Compute output
	//----------------------------------------------------------------------------

	// Sync anchor qualification: in branch-prediction mode NO sync (periodic
	// or one-shot) may anchor on a plain direct-branch retire. The sync arm in
	// msg_gen consumes the carrying event without contributing to PredCnt,
	// while the decoder -- re-anchored at the EXCLUSIVE FADDR -- walks exactly
	// that branch as an ordinary post-anchor branch and counts it in BCNT+1:
	// a systematic off-by-one per collision. Reproduced in simulation by
	// tests/overflow/08_bp_syncbranch, whose counter-proof is red without this
	// guard.
	// Deferring to the next non-branch retire is spec-clean -- the period is a
	// maximum and the one-shots only require the "first QUALIFIED retired
	// instruction" -- and is byte-neutral with branch prediction off.
	uwire sync_anchor_ok = TipBeatRetires(tip.iretire)
		&& !(CT_EN_BP && cs_tip.trTeInstEnBranchPrediction
		     && ((tip.itype == TAKEN_BRANCH) || (tip.itype == NOT_TAKEN_BRANCH)));

	nexus_sync_reason_e SyncReason = NEXUS_SYNC_NONE;
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

	// Resume-anchor precedence: the TRACE_ENABLE re-anchor (SYNC=5) MUST be
	// the first synchronizing message after a pause -- the pause contract is
	// correlation -> [config] -> SYNC=5 with ICNT=0.
	//
	// The periodic arm, however, feeds off a PERSISTENT counter value
	// (is_overflow survives the pause) and do_extsync off an external request
	// level. Either can fire on the resume retire BEFORE the
	// ExitFromTraceEnable one-shot, which is registered and therefore only
	// visible one cycle later. The result is a stolen SYNC=2 anchor with a
	// trailing SYNC=5 (ICNT != 0) that opens the composer's resume gate too
	// early; under branch prediction the two predictor models then diverge
	// ("VendorBP walk ended after N of N+1"). Regression gate:
	// tests/overflow/14_ovf_window.
	//
	// The guard holds both lower-priority arms while a TRACE_ENABLE re-anchor
	// is outstanding, including the edge cycle itself (latch delay). Without
	// pauses it is byte-neutral: after the first anchor the guard is 0.
	uwire trace_enable_pending_now = ExitFromTraceEnable
		|| (inst_trace_active && !PrevInstTraceActiveSync);

	// Encoder-level event one-shots. Each latches on its edge /
	// pulse and is consumed by the first qualifying retired instruction.
	// Priority (documented, per N-Trace Table 25 semantics):
	//   EXIT_FROM_SYS_RST > EXIT_FROM_DEBUG (3) > EXIT_FROM_POWERDOWN (9)
	//   > EVTI marker (0) > TRACE_ENABLE (5) > explicit/periodic.
	// SYNC=3 subsumes a pending TRACE_ENABLE ("Trace Enable ... must not be
	// used for exit from debug mode -- SYNC=3 must be used", Table 25); the
	// EVTI marker fires only while tracing is already active (a trace START
	// via trigger keeps the TRACE_ENABLE path, SYNC=5).
	logic               ExitFromDebug     = '0;
	logic               ExitFromPowerdown = '0;
	logic               EvtiPending       = '0;
	logic               TrigPending       = '0; // tip.trigger pulse -> SYNC=6 marker (B4)
	logic               PrevDebugMode     = '0;
	logic               PrevPowerDown     = '0;

	uwire is_overflow =   (cnt_tipcycles.overflow       && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_CLK_CYCLES  ))
						 ||(cnt_tiphalfword.overflow     && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_HALFWORDS   ))
						 ||(cnt_tipinstructions.overflow && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_INSTRUCTIONS))
						 ||(cnt_wall_clk_overflow_cdc    && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_WALL_CLK    ))
						 // P2 (D1): trace-output quota levels, crossed from proc_clk.
						 // Mode-gated here AGAIN (defense in depth -- the egress
						 // counters only run in their mode anyway).
						 ||(quota_byte_ovf_cdc           && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES ))
						 ||(quota_msg_ovf_cdc            && (cs_tip.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_MSG   ));

	always_ff @(posedge clk) begin
		// Default: no sync event
		SyncReason  <= NEXUS_SYNC_NONE;

		if (rst) begin
			ExitFromSystemReset     <= '1;
			ExitFromTraceEnable     <= '0;
			PrevInstTraceActiveSync <= '0;
			ExtSyncAck              <= '0;
			TeSyncPending           <= '0;
			TeSyncAck               <= '0;
			SyncCntClr              <= '1;
			ExitFromDebug           <= '0;
			ExitFromPowerdown       <= '0;
			EvtiPending             <= '0;
			TrigPending             <= '0;
			PrevDebugMode           <= '0;
			PrevPowerDown           <= '0;
		end
		else begin
			if (!do_extsync && ExtSyncAck) begin
				ExtSyncAck <= 0;
			end

			// P8: the request phase of the four-phase handshake. "Request up
			// and not yet acknowledged" IS the statement that one is owed, so
			// this arms the latch from the LEVEL -- including after a reset on
			// this side, which is the whole point (B-N1): the pacer keeps the
			// level up until it has seen the acknowledgement, so a request
			// this reset destroyed is simply seen again.
			// Set and clear can meet in the cycle the arm below serves the
			// request (the level is still up, the acknowledgement is only
			// being raised). The LATER non-blocking assignment wins -- the
			// clear in the arm below, not this set -- which is exactly the
			// wanted order. (An earlier version of this comment claimed the
			// opposite priority; it was wrong about the language and
			// irrelevant to the design -- P8 audit C-4.)
			if (te_sync_req_lvl && !TeSyncAck) begin
				TeSyncPending <= '1;
			end
			// Fourth phase: the pacer has withdrawn the request, so the
			// acknowledgement goes down and the loop is idle again.
			if (!te_sync_req_lvl) begin
				TeSyncAck <= '0;
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

			// Event one-shots (B1). Edges are taken from the RAW tip signals
			// (this module consumes raw tip; alignment to the delayed stream
			// happens via SyncReasonPipe like every other reason). Compile-
			// time gated: with the event group off the latches const to 0.
			// Latch only while tracing is effectively active -- Table 25:
			// "If trace is disabled (at exit from debug mode) no messages
			// should be generated" (a later re-enable re-anchors via the
			// TRACE_ENABLE one-shot instead); same logic for powerdown/EVTI.
			// A tracing pause also DROPS pending one-shots.
			if (CT_EN_DEBUG_EVENTS) begin
				PrevDebugMode <= tip.debug_mode;
				if (PrevDebugMode && !tip.debug_mode && inst_trace_active) begin
					ExitFromDebug <= '1;
				end
			end
			if (CT_EN_POWER_EVENTS) begin
				PrevPowerDown <= tip.power_down;
				if (PrevPowerDown && !tip.power_down && inst_trace_active) begin
					ExitFromPowerdown <= '1;
				end
			end
			if (CT_EN_EVTI) begin
				// Marker only while tracing is active: a trigger that STARTS
				// tracing goes out as TRACE_ENABLE (SYNC=5) per Table 25.
				if (tip.evti && inst_trace_active) begin
					EvtiPending <= '1;
				end
			end
			if (CT_EN_TRIG_SYNC) begin
				// Watchpoint/trigger marker (SYNC=6): latched only while the
				// runtime enable is set and tracing is active.
				//
				// P7 (additive, AW decision E-P7-2): the marker now has TWO
				// enable sources. The historical one -- trTeControl.InstTrigEnable
				// -- is UNCHANGED. The second is the TCI trigger-action select
				// trTeTrigExtInControl.ExtInAction0 == 4 (trace-notify), which the
				// TCI text deliberately does NOT gate on InstTrigEnable ("if
				// tracing is active, the encoder generates a packet with the
				// current PC"). De-duplication is structural: both sources feed
				// the same ONE-SHOT latch, so a build with InstTrigEnable = 1 AND
				// Action0 = 4 still emits exactly ONE marker per trigger pulse.
				if (tip.trigger && inst_trace_active
				    && (cs_tip.trTeInstTrigEnable
				        || (CT_EN_TRIG_REGS
				            && (cs_tip.trTeTrigExtInAction0
				                == 4'(ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_NOTIFY))))) begin
					TrigPending <= '1;
				end
			end
			if (!inst_trace_active) begin
				ExitFromDebug     <= '0;
				ExitFromPowerdown <= '0;
				EvtiPending       <= '0;
				TrigPending       <= '0;
			end

			// IMPORTANT: The periodic sync generator must operate even if there are
			// long gaps without retired instructions. Otherwise an overflow can
			// happen while SyncCntClr is still asserted, which would prevent any
			// periodic sync from being emitted.
			//
			// Therefore, we update the overflow/clear state machine every cycle.

			if (ExitFromSystemReset && sync_anchor_ok) begin
				// Consume the one-shot post-reset sync opportunity on the first
				// retired instruction, but only emit a sync message when both
				// the master Enable and InstTracing are asserted.
				if (cs_tip.trTeEnable && cs_tip.trTeInstTracing) begin
					SyncReason <= NEXUS_SYNC_EXIT_FROM_SYS_RST;
					// EXIT_FROM_SYS_RST subsumes every other pending one-shot
					// (the reset re-anchor covers them all).
					ExitFromTraceEnable <= '0;
					ExitFromDebug       <= '0;
					ExitFromPowerdown   <= '0;
					EvtiPending         <= '0;
				end
				ExitFromSystemReset <= '0;
				SyncCntClr    <= '1;
			end
			else if (CT_EN_DEBUG_EVENTS && inst_trace_active && ExitFromDebug && sync_anchor_ok) begin
				// Very first synchronizing message after exit from debug mode
				// (SYNC=3, N-Trace Required). Subsumes a pending TRACE_ENABLE:
				// Table 25 forbids SYNC=5 for the debug-exit re-anchor.
				SyncReason          <= NEXUS_SYNC_EXIT_FROM_DEBUG;
				ExitFromDebug       <= '0;
				ExitFromTraceEnable <= '0;
				SyncCntClr          <= '1;
			end
			else if (CT_EN_POWER_EVENTS && inst_trace_active && ExitFromPowerdown && sync_anchor_ok) begin
				// First retire after powerdown exit (SYNC=9, optional). One
				// re-anchor suffices -- a pending TRACE_ENABLE is subsumed.
				SyncReason          <= NEXUS_SYNC_EXIT_FROM_POWERDOWN;
				ExitFromPowerdown   <= '0;
				ExitFromTraceEnable <= '0;
				SyncCntClr          <= '1;
			end
			else if (CT_EN_EVTI && inst_trace_active && EvtiPending && sync_anchor_ok) begin
				// External-trigger marker (SYNC=0) on the next retire.
				SyncReason  <= NEXUS_SYNC_EVTI;
				EvtiPending <= '0;
				SyncCntClr  <= '1;
			end
			else if (CT_EN_TRIG_SYNC && inst_trace_active && TrigPending && sync_anchor_ok) begin
				// Watchpoint/trigger marker (SYNC=6, Trace Event) on the next
				// retire (N-Trace 8.4: the next available message is upgraded
				// to its sync counterpart).
				SyncReason  <= NEXUS_SYNC_WATCHPOINT;
				TrigPending <= '0;
				SyncCntClr  <= '1;
			end
			else if (cs_tip.trTeEnable && cs_tip.trTeInstTracing && ExitFromTraceEnable && sync_anchor_ok) begin
				// First qualifying iretire after the encoder was enabled
				// mid-stream (and the post-reset opportunity was already
				// consumed): emit a TRACE_ENABLE sync so the decoder can
				// re-anchor to the current PC.
				SyncReason          <= NEXUS_SYNC_TRACE_ENABLE;
				ExitFromTraceEnable <= '0;
				SyncCntClr          <= '1;
			end
			else if (cs_tip.trTeEnable && cs_tip.trTeInstTracing
			         && ((do_extsync && !ExtSyncAck) || do_tesync)
			         && sync_anchor_ok && !trace_enable_pending_now) begin
				// E-P2-1 (AW decision 2026-08-03): an explicit sync request
				// emits the explicit-request vendor code SYNC=14
				// (NEXUS_SYNC_REQ), matching doc/trace-format.adoc and the E2
				// decision of 2026-07-19 (the RTL emitted PERIODIC here until
				// P2 stage 3).
				//
				// TWO sources since P8: the ATB sync request (mode 7) and the
				// TE register field trTeControl.InstSyncReq (any mode). They
				// share the arm because they mean the same thing on the wire.
				// Each is acknowledged only if it actually asked -- a blanket
				// ack would be a LOST request: ExtSyncAck is a level that
				// clears one cycle after do_extsync falls, so acking a request
				// that is not there could swallow an ATB request arriving in
				// exactly that cycle.
				// If BOTH asked, both are acknowledged and ONE message is
				// emitted: a synchronization message is a full re-anchor, so
				// it satisfies every outstanding request (the same de-dup
				// contract as the P7 trigger marker).
				//
				// The `!ExtSyncAck` term in the guard above closes a
				// ONE-CYCLE double-emission window that existed on the ATB
				// path since the handshake was introduced (P8 finding,
				// regression gates tests 4f/5f in ct_L23_preproc_sync_tb):
				// the FSM output only drops one cycle AFTER the
				// acknowledgement, so with two retires on consecutive cycles
				// the arm fired a SECOND time and one request produced two
				// SYNC=14 messages (measured: 2 for one request). A
				// single-cycle-retire testbench can never reach it -- a real
				// core can. The acknowledgement register IS the "already
				// served" state, so no extra flip-flop is needed. The TE path
				// needs no such term: its pending latch is cleared right here,
				// and the `!TeSyncAck` term of its re-arm above keeps the
				// still-standing request level from arming it again.
				SyncReason    <= NEXUS_SYNC_REQ;
				if (do_extsync) ExtSyncAck    <= '1;
				if (do_tesync) begin
					TeSyncAck     <= '1;
					TeSyncPending <= '0;
				end
				SyncCntClr    <= '1;
			end
			else if (cs_tip.trTeEnable && cs_tip.trTeInstTracing && is_overflow && !SyncCntClr
			         && !trace_enable_pending_now) begin
				// Once overflow is detected and counters are not currently being cleared,
				// generate periodic sync on a retired instruction.
				//
				// IMPORTANT:
				// tip.iretire can be 0 for extended periods (e.g. due to TB driving policy
				// or real CPU stalls). We must not immediately assert SyncCntClr in a cycle
				// without iretire, otherwise the overflow condition is cleared before we
				// ever emit the periodic sync.
				//
				// BP mode (regression gate tests/overflow/08_bp_syncbranch,
				// originally found on KV260 hardware): a periodic sync must
				// NOT anchor on a plain direct-branch retire. The sync arm consumes
				// the carrying event without a PredCnt contribution, while the
				// decoder -- re-anchored at the EXCLUSIVE FADDR -- walks that very
				// branch as a normal post-anchor branch and counts it toward the
				// next VendorBP's BCNT+1: a systematic off-by-one per collision
				// (measured: BCNT=1 where the window holds two predicted branches;
				// the eager walk then inverts one lap early -> "indirect address
				// encountered in ICNT" / "VendorBP walk ended" / silent lap loss).
				// The period is a MAXIMUM (2^(Max+4)), so deferring the anchor to
				// the next non-branch retire is spec-clean; only a degenerate
				// 1-instruction branch-self-loop could starve it (no real RV32
				// code shape -- even tight loops carry their backward jump).
				// Byte-neutral with BP off (guard below).
				if (sync_anchor_ok) begin
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

	nexus_sync_reason_e [EXTRA_DELAY_MAX:0] SyncReasonPipe;

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
