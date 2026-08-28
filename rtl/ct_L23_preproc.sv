// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder layer 2/3 preprocessor (tip_clk domain).
 *
 * @details
 *   Preprocesses the incoming TIP stream into the eTIP and next-IADDR streams
 *   consumed by the downstream message generator. Responsibilities:
 *   - TIP preprocessing with trace filtering
 *   - determining the next IADDR
 *   - periodic synchronization
 *   - FIFO buffering
 *   - flush handling: on `atb_afvalid` (flush request from ATB) the TIP output
 *     to the tip FIFO is stopped and a TIP side-channel `do_flush` is raised,
 *     which propagates a flush message through the downstream stages. The
 *     idle-core case (flush with no new tip.iretire) is covered by the eTIP
 *     composer's per-cycle flush path.
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import ct_pkg::*;
import tip_pkg::*;

module ct_L23_preproc #(
	bit SPLIT_DATA_ACCESS = 0  // propagated to df and composer_etip
) (
	// Global control (used as formal interface ports)
	input uwire logic     tip_clk,       // trace input clock
	input uwire logic     tip_rst,       // reset
	input uwire logic     wall_clk,
	input uwire logic     wall_clk_rst,
	// Egress-quota domain (P2): passed through to the sync generator's
	// CDC pairs (the quota counters live in the L2 egress modules).
	input uwire logic     proc_clk,
	input uwire logic     proc_rst,

	// Input / Output
	tip_if.slave          tip,           // TIP from CPU
	axis_if.master        axis,          // (wide) AXI Stream to watchdog CPU
	source_if.impl        etip_q,        // etip from preproc stage to processing stages
	source_if.impl        next_iaddr_q,  // next_iaddr from preproc stage to processing stages
	input uwire logic     atb_afvalid,
	input uwire logic     atb_syncreq,

	// Trace-output quota (P2): held overflow levels from the egress path
	// (proc_clk domain; exactly one back end is built per encoder) + the
	// crossed SyncCntClr rearm back toward the egress counters.
	input uwire logic     synq_req_trace_byte_count,
	input uwire logic     synq_req_trace_msg_count,
	output uwire logic    quota_cnt_clr,

	// Local control
	ct_cs_tipclk_if.slave cs_tip,        // control / status interface
	input uwire logic     wext_clk,
	ocram_write_if.impl   act_st_wext,   // act_st vector_binary_search memory config
	ocram_write_if.impl   df_range_wext, // data flow qualifier vector_binary_search memory config
	output delay_t        internal_delay
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

	uwire tip_iaddr_t       next_iaddr;

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
		// Regression guard (2026-07-19): a delay budget below the requirement
		// silently mis-aligns the qualifier chain (worst case: empty ATB
		// stream -- seen with the old `CT_EN_ACT ? 20 : 1` profile formula).
		// Fail HARD so no sim can pass with a broken profile budget.
		if (max_delay > EXTRA_DELAY_MAX) begin
			$fatal(1, "%m: max_delay(%0d) > EXTRA_DELAY_MAX(%0d) -- PREPROC_DELAY_MAX too small for this profile", max_delay, EXTRA_DELAY_MAX);
		end
		if (idelay_df != idelay_cf) begin
			$fatal(1, "%m: idelay_df(%0d) != idelay_cf(%0d)", idelay_df, idelay_cf);
		end
		// Regression guard (C0b): the ACT-ST delay REPORT must equal its
		// constant chain length 4*M0_DIM. A mismatch means internal_delay
		// was truncated on its way up (the FINDINGS §1.3 class: the budget
		// check above then compares a WRAPPED number and everything stays
		// green while act_st taps its pipe tens of cycles early).
		if (CT_EN_ACT && 32'($unsigned(idelay_act_st)) != 32'(4*M0_DIM)) begin
			$fatal(1, "%m: idelay_act_st(%0d) != 4*M0_DIM(%0d) -- internal_delay truncated between vbs and here", idelay_act_st, 4*M0_DIM);
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

	// Instantiate timestamp unit (CT_EN_TIMESTAMP=0: no TS hardware --
	// ts_value is constant 0 and every TS consumer downstream trims away).
	uwire tip_pkg::tip_time_t ts_value;
	if (CT_EN_TIMESTAMP) begin : genTs
		ct_L23_preproc_ts ts_inst (
			.clk                (tip_clk),
			.rst                (tip_rst),
			.cs_tip,
			.tip_time           (tip._time),
			.ts_value
		);
	end
	else begin : genNoTs
		assign ts_value = '0;
	end

	// Publish the current (tip-clk-domain) timestamp so the CSR shim can expose it
	// via trTsCounterHigh/Low after a safe wb_clk-side resynchronisation.
	assign cs_tip.trTeTs = ts_value;

	// ----------------------------------------------------------------
	// Explicit-sync-request source capture (te.trTeSyncStatus.SyncReqSource,
	// RO diagnosis; 2026-07-19). On-wire every explicit request is the
	// single vendor SYNC code 14 (NEXUS_SYNC_REQ) -- the source does not
	// matter to a decoder (each sync is a full re-anchor), so it is only
	// recorded here: 0 = none since reset, 1 = ACT-CAP CF_SYNC command (the
	// traced hart itself), 2 = ATB sync request, 3 = trace-quota counter,
	// 4 = trTeControl.InstSyncReq written over the control bus (P8).
	// Priority CSR > TE > ATB > quota when several fire in one cycle --
	// inserting TE in second place keeps every pre-existing pairwise
	// precedence, and a deliberate software request is the more informative
	// answer to "why did this sync happen" than an automatic cadence.
	// NOTE on what that priority does and does not decide: the CSR and TE
	// terms are one-cycle events (the retiring csrw carrying the command, and
	// the paced request strobe), while ATB and quota are HELD levels that stay
	// asserted until they are served and therefore keep re-recording
	// themselves. The priority settles a collision CYCLE; across cycles the
	// register simply ends on the most recent term that was true. Regression
	// gate: the cfsync leg of tests/instruction/33_te_sync_req.
	// The CSR decode mirrors the composer's act_cf_sync condition (ACT-CAP
	// CF_SYNC to a Nexus sink); the TE decode is the crossed request level
	// itself, sampled where it is raised, exactly like the other three.
	// ----------------------------------------------------------------
	logic [2:0] SyncReqSource = '0;
	uwire sync_req_src_csr = CT_EN_ACT && act_cap_st.valid
		&& (  (act_cap_st.cmd.Sink.value == ct_cs_cpuif_types_pkg::ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS)
		    ||(act_cap_st.cmd.Sink.value == ct_cs_cpuif_types_pkg::ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS))
		&& (act_cap_st.cmd.Cmd.value == ct_cs_cpuif_types_pkg::ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC);
	// N6 (P2/D10): atb.syncreq is an ATB-clock-domain level; this
	// diagnostic sampler runs in tip_clk. 2-FF-synchronize it for the
	// DIAGNOSTIC path (purely a metastability fix -- the functional path
	// keeps its own CDC inside preproc_sync's signal_ack_lock_fsm).
	uwire logic atb_syncreq_tip;
	signal_cdc atb_syncreq_diag_cdc_inst (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (atb_syncreq),
		.out (atb_syncreq_tip)
	);
	uwire sync_req_src_atb = atb_syncreq_tip
		&& (cs_tip.trTeInstSyncMode == ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_ATB);
	// P2.5: SyncReqSource=3 comes alive -- the crossed (tip-domain) quota
	// overflow levels from the sync generator; mode-gated at the source
	// (in-module mode gate of the egress quota counters).
	uwire logic quota_byte_ovf_tip;
	uwire logic quota_msg_ovf_tip;
	uwire sync_req_src_quota = quota_byte_ovf_tip || quota_msg_ovf_tip;
	// P8: the TE-register request, captured where it is raised. It is a HELD
	// LEVEL, not a strobe -- the closing audit (B-N1) replaced the paced
	// strobe pair by a four-phase level handshake, because a strobe cannot
	// survive a reset of the consumer's domain alone (doc/integration.adoc
	// #independent-resets). Already gated by the build switch in the CSR
	// shim (constant 0 when compiled out), so this term disappears with it.
	uwire sync_req_src_te = CT_EN_INST_SYNC_REQ && cs_tip.trTeInstSyncReq;
	// PRIORITY, and what the level does to it. The chain is a plain
	// first-match, so while the TE request STANDS it masks the two sources
	// below it: an ATB request or a quota overflow arriving in that window
	// does not update SyncReqSource, and the register still reads 4 when the
	// software asks who last asked. That is deliberate -- the field answers
	// "which source raised the request the encoder is currently serving",
	// and the TE request is the one being served -- but it is a consequence
	// of the level, not of a decision made per source, so it is written down
	// here. The masking window is the handshake's own length (request until
	// the consumer's acknowledge), not the duration of the sync.
	// Not separately gated: the collision itself is proven in
	// formal/preproc_sync (task reqcoll, P-SYNC-11, request meets quota) and
	// the level's reset behaviour in task tereqrst (P-SYNC-12); no test
	// pins the PRIORITY ORDER of this register.
	always_ff @(posedge tip_clk) begin
		if (tip_rst)                  SyncReqSource <= 3'd0;
		else if (sync_req_src_csr)    SyncReqSource <= 3'd1;
		else if (sync_req_src_te)     SyncReqSource <= 3'd4;
		else if (sync_req_src_atb)    SyncReqSource <= 3'd2;
		else if (sync_req_src_quota)  SyncReqSource <= 3'd3;
	end
	assign cs_tip.trTeSyncReqSource = SyncReqSource;

	// ----------------------------------------------------------------
	// External trigger input actions (P7, TCI Table 20 via
	// trTeTrigExtInControl.ExtInAction0). CTTE owns exactly ONE external
	// trigger input: the generic tip.trigger event port.
	//   action 2 (trace-on)  -> InstTracing 0 -> 1
	//   action 3 (trace-off) -> InstTracing 1 -> 0
	// Both are gated by trTeControl.InstTrigEnable exactly as the TCI text
	// prescribes ("When trTeInstTrigEnable = 1 it will start/stop instruction
	// tracing"). CTTE has no trTeDataTrigEnable, so data tracing is NOT
	// affected -- documented in the RDL.
	// Action 4 (trace-notify) is handled in ct_L23_preproc_sync (it IS the
	// SYNC=6 marker one-shot); action 0/1 and 5..15 never reach here (the
	// wrapper's WARL legalizes them to 0).
	//
	// Registered, so the strobes have the same one-cycle shape and the same
	// latency as the ACT-CAP overrides they are OR-ed with in the CSR shim.
	logic TrigTracingSet = 1'b0;
	logic TrigTracingClr = 1'b0;
	if (CT_EN_TRIG_REGS) begin : genTrigActions
		uwire trig_act_armed = tip.trigger && cs_tip.trTeEnable
		                    && cs_tip.trTeInstTrigEnable;
		always_ff @(posedge tip_clk) begin
			if (tip_rst) begin
				TrigTracingSet <= 1'b0;
				TrigTracingClr <= 1'b0;
			end
			else begin
				TrigTracingSet <= trig_act_armed
					&& (cs_tip.trTeTrigExtInAction0
					    == 4'(ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_ON));
				TrigTracingClr <= trig_act_armed
					&& (cs_tip.trTeTrigExtInAction0
					    == 4'(ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_OFF));
			end
		end
	end
	else begin : genNoTrigActions
		always_comb begin
			TrigTracingSet = 1'b0;
			TrigTracingClr = 1'b0;
		end
	end
	assign cs_tip.trTeTrigTracingSet = TrigTracingSet;
	assign cs_tip.trTeTrigTracingClr = TrigTracingClr;

	// Instantiate sync_gen
	ct_L23_preproc_sync sync_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip,
		.wall_clk,   .wall_clk_rst,
		.proc_clk,   .proc_rst,
		.sync_req_atb_synq  (atb_syncreq),
		.synq_req_trace_byte_count,
		.synq_req_trace_msg_count,
		.quota_cnt_clr,
		.quota_byte_ovf_tip,
		.quota_msg_ovf_tip,
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

	// ACT-CAP/ACT-ST watchpoint & cross-trigger blocks: profile-gated.
	// Without them act_cap_st presents "no command" and the delay budget
	// contribution is zero -- the composer's DAQ/sync-request paths are
	// simply never triggered (identical to the blocks' idle behavior).
	if (CT_EN_ACT) begin : genAct
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
	end
	else begin : genActStub
		assign act_cap_st.valid = 1'b0;
		assign act_cap_st.cmd   = '{default: '0};
		assign act_cap_st.addr  = '0;
		assign act_cap_st.data  = '0;
		assign idelay_act_st    = '0;
		assign idelay_act_cap   = '0;
		assign idelay_act_proc  = '0;
		// act_proc is the ONLY driver of the four ACT-CAP tracing overrides;
		// without it they must be tied off explicitly. Before P7 they were
		// left undriven here, which put an X into the CSR shim's hwset/hwclr
		// path of a CF-only profile (harmless in synthesis, but an X in
		// simulation and now OR-ed with the trigger actions).
		assign cs_tip.trTeInstTracingSet = 1'b0;
		assign cs_tip.trTeInstTracingClr = 1'b0;
		assign cs_tip.trTeDataTracingSet = 1'b0;
		assign cs_tip.trTeDataTracingClr = 1'b0;
	end

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

	// Qualifier pipelining. The effective instruction-tracing level
	// (Enable && InstTracing) is delayed by EXACTLY the composer's beat
	// latency, with the same staging semantics as TipPipe: stage [0] is one
	// cycle, the output is stage [extra_delay0], which aligns with
	// tip_delayed_composer.
	//
	// Qualifying the DELAYED beats with the LIVE level instead loses
	// instructions at both edges: at the off edge up to max_delay already
	// retired instructions vanish (a silent drain gap), and at the on edge up
	// to max_delay instructions retired while paused are still processed out
	// of the pipe -- their branches then enter the stream as
	// VendorBP/ResourceFull messages AHEAD of the TRACE_ENABLE re-anchor.
	// Seen on a KV260 robustness capture as five VendorBP messages with
	// BCNT=0 between the correlation message and the sync, with the sync
	// carrying ICNT=24: the decoder derails into the 0x40 idle trap even
	// though the workload kept running.
	logic [EXTRA_DELAY_MAX:0] ItaPipe = '0;
	uwire inst_trace_active_live = cs_tip.trTeEnable && cs_tip.trTeInstTracing;
	always_ff @(posedge tip_clk) begin
		if (tip_rst) begin
			ItaPipe <= '0;
		end
		else begin
			ItaPipe[0] <= inst_trace_active_live;
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				ItaPipe[idx] <= ItaPipe[idx-1];
			end
		end
	end
	uwire inst_trace_active_composer = ItaPipe[extra_delay_tip_delay_composer];

	// Same staging for the DATA-tracing level, tapped for the cf/df beat
	// latency: ct_L23_preproc_df consumes tip_delayed_cfdf, so stage
	// [extra_delay_tip_delay_cfdf] (= extra_delay1 + 1 cycles, with
	// idelay_tip_delay = 1) is exactly the delay of that tip copy.
	//
	// Qualifying the DELAYED beats with the LIVE cs_tip.trTeDataTracing is
	// the DF twin of the ItaPipe defect above, measured 2026-08-04 in
	// tests/data/03_addr_compress (probe on tip vs. tip_delayed_cfdf):
	//   - off edge: an access retiring up to max_delay-1 cycles BEFORE the
	//     edge lands is silently dropped (traced access lost, no ERROR --
	//     the reason the BLK+8 load never reached the wire),
	//   - on edge:  an access retiring up to max_delay-1 cycles BEFORE the
	//     edge is emitted although data tracing was OFF at its retire (the
	//     off-window store/load leak -- a data-filter violation, and worse,
	//     it becomes the 13/14 re-anchor the decoder then XORs against).
	// Both directions are gated in that test (short-edge + off-window legs).
	//
	// Hard-gated by the build profile: without data-trace hardware the level
	// is a constant 0 (the CSR bit is sw=r/0 in those profiles anyway), so the
	// staging registers cost nothing instead of relying on synthesis trimming
	// them through preproc_df -- same discipline as the df_range/comp_filters
	// stubs above.
	uwire data_trace_active_cfdf;
	if (CT_EN_DATA_TRACE) begin : genDtaPipe
		logic [EXTRA_DELAY_MAX:0] DtaPipe = '0;
		uwire data_trace_active_live = cs_tip.trTeDataTracing;
		always_ff @(posedge tip_clk) begin
			if (tip_rst) begin
				DtaPipe <= '0;
			end
			else begin
				DtaPipe[0] <= data_trace_active_live;
				for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
					DtaPipe[idx] <= DtaPipe[idx-1];
				end
			end
		end
		assign data_trace_active_cfdf = DtaPipe[extra_delay_tip_delay_cfdf];
	end
	else begin : genNoDtaPipe
		assign data_trace_active_cfdf = 1'b0;
	end

	// Data-trace range qualifier: only with the data-trace feature group.
	// Stub = constant pass (identical to the block's default-CSR output).
	if (CT_EN_DATA_TRACE) begin : genDfRange
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
	end
	else begin : genDfRangeStub
		assign df_range.hit_valid = 1'b1;
		assign df_range.hit       = 1'b1;
		assign idelay_df_range    = '0;
	end

	// Address comparator filters (instruction + data qualifiers): own
	// profile switch (instruction filtering is a program-trace feature).
	// Stub = constant pass (default-CSR behavior).
	if (CT_EN_FILTERS) begin : genCompFilters
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
	end
	else begin : genCompFiltersStub
		assign cf_filter.hit_valid = 1'b1;
		assign cf_filter.hit       = 1'b1;
		assign df_filter.hit_valid = 1'b1;
		assign df_filter.hit       = 1'b1;
		assign idelay_comp_filters = '0;
	end

	ct_L23_preproc_df #(.SPLIT_DATA_ACCESS(SPLIT_DATA_ACCESS)) df_inst (
		.clk                (tip_clk),
		.rst                (tip_rst),
		.tip                (tip_delayed_cfdf),
		.df_filter,
		.df_range,
		.df_qualifier,
		.cs_tip,
		.data_trace_active_q(data_trace_active_cfdf),
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
		.ts_value,
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
		.inst_trace_active_q(inst_trace_active_composer),
		.atb_afvalid        (atb_afvalid),
		.sync,
		.cf_qualifier,
		.df_qualifier,
		.perfcnt,
		.etip_q,
		.next_iaddr_q,
		.cs_tip,
		.internal_delay     (idelay_composer_etip)
	);

	assign internal_delay = idelay_tip_delay + extra_delay_tip_delay_composer + 1;

endmodule // ct_L23_preproc

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
