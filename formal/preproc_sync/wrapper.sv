// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief   Formal wrapper for ct_L23_preproc_sync (P-SYNC-1..4).
 *
 * @details
 *   Safety top `f_top` (free environment) + bounded-liveness top `f_live`
 *   (deterministic environment). Internal one-shot state is observed via
 *   hierarchical probes into the sv2v-inlined DUT scope; canary assertions
 *   (exact mirrors of two DUT registers) guard against silently unbound
 *   probes — if a probe ever came back free, the canaries fail in the
 *   base case.
 *
 *   Assumption budget (each justified in formal/README.md):
 *     ASM-SYNC-1: reset is asserted in the very first cycle (uninitialised
 *                 counter/pipe registers get their architectural start).
 *     ASM-SYNC-2: trTeInstSyncMode / trTeInstSyncMax are stable
 *                 (quasi-static CSR programming contract: written only
 *                 while trTeControl.Enable = 0).
 *     ASM-SYNC-3: wall_clk == clk, wall_clk_rst == rst (single-clock
 *                 abstraction; CDC metastability is out of scope, the
 *                 handshake CDCs are proven-deterministic under one clock).
 *   Everything else — including Enable/InstTracing (the pause/resume
 *   dynamics under test), all tip events and the external sync requests —
 *   is FREE.
 *
 *   Properties (see formal/README.md):
 *     P-SYNC-1 (Klasse-9-Regression, Gate 14 / Fix 335393b6): while a
 *              TRACE_ENABLE re-anchor is outstanding (one-shot latched or
 *              latch-delay edge cycle), SyncReason never becomes PERIODIC —
 *              neither from is_overflow nor from do_extsync.
 *     P-SYNC-2 (one-shot semantics): every emitted sync of a one-shot type
 *              had its one-shot armed; pending event one-shots are dropped
 *              on a tracing pause.
 *     P-SYNC-3 (anchor qualification): SyncReason is only set in cycles
 *              qualified by sync_anchor_ok (BP-deferral contract).
 *     P-SYNC-4 (bounded liveness, f_live): under permanent overflow and
 *              fair retires a PERIODIC arrives within 64 cycles — the fix
 *              guard does not starve the periodic arm.
 *     P-SYNC-5 (quota, two parts): (a) mode gating in f_top — no PERIODIC
 *              in modes OFF/ATB regardless of the quota levels
 *              (A_sync5_mode); (b) window bound in f_quota — between two
 *              emitted syncs at most 2^(Max+4) + DELTA_F bytes are
 *              accepted (A_sync5_win; closed loop through the real CDC
 *              pairs with an exact model of the egress quota counter).
 *     P-SYNC-6 (no lost request, f_quota): a held quota-overflow level
 *              leads to a sync within a bounded number of cycles under
 *              the fair environment (A_sync6_live).
 *     P-SYNC-7 (no double request, f_quota): no second quota PERIODIC
 *              without an intervening egress-counter rearm
 *              (quota_cnt_clr) — A_sync7_rearm.
 *     P-SYNC-8 (completeness, P7 audit A-2): every arming condition the
 *              DUT states MUST set its one-shot in the next cycle, unless
 *              the same cycle already consumed it (A_te_complete,
 *              A_dbg_complete, A_pwr_complete, A_evti_complete,
 *              A_trig_complete). This is the direction P-SYNC-2 and the
 *              A_*_impl strengthenings structurally cannot cover: they
 *              carry the model on the CONCLUSION side, so a DUT that
 *              stops arming satisfies them. Mutation MUT-F1 (the TCI
 *              trigger action removed from the RTL) is green without
 *              P-SYNC-8 and red with it.
 *
 *   RED_CLASS9: compiling with -DRED_CLASS9 keeps ONLY the P-SYNC-1
 *   assertion (plus its helpers), so the red counter-proof run against the
 *   pre-fix RTL fails unambiguously on the Klasse-9 property.
 */

`default_nettype none

module f_preproc_check (
	input wire logic       clk,
	input wire logic       rst,
	// tip events
	input wire logic       in_iretire,
	input wire logic [1:0] in_ilastsize,
	input wire logic [3:0] in_itype,
	input wire logic       in_debug_mode,
	input wire logic       in_evti,
	input wire logic       in_power_down,
	input wire logic       in_trigger,
	// CSR view
	input wire logic       in_en,        // trTeControl.Enable
	input wire logic       in_tracing,   // trTeControl.InstTracing
	input wire logic       in_bp_en,     // trTeInstFeatures.InstEnBranchPrediction
	input wire logic       in_trig_en,   // trTeControl.InstTrigEnable
	// trTeTrigExtInControl.ExtInAction0 (P7): the SECOND enable source of the
	// SYNC=6 marker one-shot. Action 4 (trace-notify) arms it independently of
	// InstTrigEnable, exactly as the TCI text prescribes. Left FREE for the
	// solver, so the proof covers every action value including the illegal
	// ones the WARL never lets through.
	// NOTE (P7 audit A-2): leaving it free does NOT by itself make the
	// existing A_trig_impl assertion see this path -- that assertion has
	// m_trig on its CONCLUSION side, so a model term that arms in MORE
	// states makes it monotonically WEAKER. The obligation that actually
	// constrains the path is A_trig_complete below.
	input wire logic [3:0] in_trig_act,  // trTeTrigExtInControl.ExtInAction0
	input wire logic [2:0] in_sync_mode, // trTeControl.InstSyncMode (assumed stable)
	input wire logic [3:0] in_sync_max,  // trTeControl.InstSyncMax  (assumed stable)
	// external sync requests
	input wire logic       in_req_atb,
	input wire logic       in_req_bytes,
	input wire logic       in_req_msgs
);
	import tip_pkg::*;
	import nexus::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	// ------------------------------------------------------------------
	// Interfaces + DUT
	// ------------------------------------------------------------------
	tip_if           tip ();
	ct_sync_if       sync_o ();
	ct_cs_tipclk_if  cs ();

	assign tip.iretire    = in_iretire;
	assign tip.ilastsize  = in_ilastsize;
	assign tip.itype      = tip_itype_e'(in_itype);
	assign tip.debug_mode = in_debug_mode;
	assign tip.evti       = in_evti;
	assign tip.power_down = in_power_down;
	assign tip.trigger    = in_trigger;

	assign cs.trTeEnable                 = in_en;
	assign cs.trTeInstTracing            = in_tracing;
	assign cs.trTeInstEnBranchPrediction = in_bp_en;
	assign cs.trTeInstTrigEnable         = in_trig_en;
	assign cs.trTeTrigExtInAction0       = in_trig_act;
	assign cs.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e'(in_sync_mode);
	assign cs.trTeInstSyncMax  = in_sync_max;

	assign sync_o.done = 1'b0;
	// P8: the TE request source is proven in its own top (f_tereq); tie it
	// off here so the existing proofs stay exactly the environment they were
	// written for.
	assign cs.trTeInstSyncReq = 1'b0;

	// The P2 quota ports (proc_clk/proc_rst + quota observers) exist only
	// on the post-P2 DUT. The RED_CLASS9 build is ALSO compiled against
	// the pre-fix worktree 441eac4c (run_red.sh cross-check 2/2), whose
	// DUT pre-dates them — so those bindings are compile-gated out there.
	// On the CURRENT RTL the RED_CLASS9 build then leaves them unconnected:
	// harmless for P-SYNC-1 (the quota levels only add further FREE
	// is_overflow sources, and the resume guard protects independently).
	ct_L23_preproc_sync dut (
		.clk                       (clk),
		.rst                       (rst),
		.tip                       (tip),
		.wall_clk_rst              (rst),   // ASM-SYNC-3
		.wall_clk                  (clk),   // ASM-SYNC-3
`ifndef RED_CLASS9
		.proc_clk                  (clk),   // ASM-SYNC-3 (P2 quota domain)
		.proc_rst                  (rst),
		.quota_cnt_clr             (),
		.quota_byte_ovf_tip        (),
		.quota_msg_ovf_tip         (),
`endif
		.sync_req_atb_synq         (in_req_atb),
		.synq_req_trace_byte_count (in_req_bytes),
		.synq_req_trace_msg_count  (in_req_msgs),
		.sync                      (sync_o),
		.cs_tip                    (cs),
		.internal_delay            (),
		.extra_delay               ('0)
	);

	// ------------------------------------------------------------------
	// Probes into the DUT scope (bind lexically after sv2v inlining)
	// ------------------------------------------------------------------
	wire logic [3:0] f_SR          = dut.SyncReason;
	wire logic       f_te_pend     = dut.ExitFromTraceEnable;
	wire logic       f_prev_active = dut.PrevInstTraceActiveSync;
	wire logic       f_rst_pend    = dut.ExitFromSystemReset;
	wire logic       f_dbg_pend    = dut.ExitFromDebug;
	wire logic       f_pwr_pend    = dut.ExitFromPowerdown;
	wire logic       f_evti_pend   = dut.EvtiPending;
	wire logic       f_trig_pend   = dut.TrigPending;
	wire logic       f_prev_dbg    = dut.PrevDebugMode;
	wire logic       f_prev_pwr    = dut.PrevPowerDown;

	// ------------------------------------------------------------------
	// Environment assumptions
	// ------------------------------------------------------------------
	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;

	// ASM-SYNC-1: initial reset (uninitialised DUT registers).
	always_comb if (!f_past_valid) assume (rst);

	// ASM-SYNC-2: quasi-static sync period CSRs.
	logic [2:0] p_sync_mode_q;
	logic [3:0] p_sync_max_q;
	always_ff @(posedge clk) begin
		p_sync_mode_q <= in_sync_mode;
		p_sync_max_q  <= in_sync_max;
	end
	always_comb if (f_past_valid) assume ((in_sync_mode == p_sync_mode_q) && (in_sync_max == p_sync_max_q));

	// ------------------------------------------------------------------
	// Helper state (values of the PREVIOUS cycle, i.e. the decision cycle)
	// ------------------------------------------------------------------
	uwire in_active    = in_en && in_tracing;      // effective instruction tracing
	// sync_anchor_ok mirror (CT_EN_BP = 1 in the full profile)
	uwire in_anchor_ok = in_iretire
		&& !(in_bp_en && ((tip_itype_e'(in_itype) == TAKEN_BRANCH)
		               || (tip_itype_e'(in_itype) == NOT_TAKEN_BRANCH)));
	// trace_enable_pending_now mirror: one-shot latched OR latch-delay edge
	uwire in_pending_now = f_te_pend || (in_active && !f_prev_active);

	// ------------------------------------------------------------------
	// Arming conditions, restated EXACTLY as the DUT states them
	// (rtl/preproc/ct_L23_preproc_sync.sv:329/344/350/357/374). They carry
	// the completeness obligations A_*_complete below -- the direction the
	// A_*_impl assertions structurally cannot cover.
	// The Prev* antecedents are taken from the DUT probes (canary-proven
	// equal to the model mirrors), so an arm condition is neither over- nor
	// under-approximated.
	// ------------------------------------------------------------------
	uwire in_arm_te   = in_active && !f_prev_active;
	uwire in_arm_dbg  = CT_EN_DEBUG_EVENTS && f_prev_dbg && !in_debug_mode && in_active;
	uwire in_arm_pwr  = CT_EN_POWER_EVENTS && f_prev_pwr && !in_power_down && in_active;
	uwire in_arm_evti = CT_EN_EVTI         && in_evti    && in_active;
	uwire in_arm_trig = CT_EN_TRIG_SYNC    && in_trigger && in_active
		&& (in_trig_en
		    || (CT_EN_TRIG_REGS
		        && (in_trig_act == 4'(ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_NOTIFY))));

	logic p_rst_q        = 1'b1;
	logic p_anchor_ok_q  = 1'b0;
	logic p_pending_q    = 1'b0;
	logic p_paused_q     = 1'b0;
	logic [3:0] p_SR_q   = 4'd15; // NEXUS_SYNC_NONE
	logic p_arm_te_q     = 1'b0;
	logic p_arm_dbg_q    = 1'b0;
	logic p_arm_pwr_q    = 1'b0;
	logic p_arm_evti_q   = 1'b0;
	logic p_arm_trig_q   = 1'b0;

	always_ff @(posedge clk) begin
		p_rst_q       <= rst;
		p_anchor_ok_q <= in_anchor_ok;
		p_pending_q   <= in_pending_now;
		p_paused_q    <= !in_active && !rst;
		p_SR_q        <= f_SR;
		p_arm_te_q    <= in_arm_te;
		p_arm_dbg_q   <= in_arm_dbg;
		p_arm_pwr_q   <= in_arm_pwr;
		p_arm_evti_q  <= in_arm_evti;
		p_arm_trig_q  <= in_arm_trig;
	end

	// ------------------------------------------------------------------
	// One-shot models (observable restatement of the arming rules)
	// ------------------------------------------------------------------
	// Canary mirrors — exact register equivalence; these fail in the base
	// case if the hierarchical probes were silently unbound.
	logic m_prev_active = 1'b0;
	logic m_prev_dbg    = 1'b0;
	logic m_prev_pwr    = 1'b0;
	// One-shot supersets (clear keyed on the OBSERVED SyncReason, i.e. one
	// cycle after the DUT clears its pending — hence "DUT implies model").
	logic m_te   = 1'b0;
	logic m_dbg  = 1'b0;
	logic m_pwr  = 1'b0;
	logic m_evti = 1'b0;
	logic m_trig = 1'b0;
	logic m_trig_act = 1'b0; // armed by the TCI action ONLY (P7 witness)
	logic m_rst  = 1'b1; // exact mirror of ExitFromSystemReset
	logic m_te_q = 1'b0, m_dbg_q = 1'b0, m_pwr_q = 1'b0;
	logic m_evti_q = 1'b0, m_trig_q = 1'b0, m_rst_q = 1'b1;
	logic m_trig_act_q = 1'b0;

	always_ff @(posedge clk) begin
		if (rst) begin
			m_prev_active <= 1'b0;
			m_prev_dbg    <= 1'b0;
			m_prev_pwr    <= 1'b0;
			m_te   <= 1'b0;
			m_dbg  <= 1'b0;
			m_pwr  <= 1'b0;
			m_evti <= 1'b0;
			m_trig <= 1'b0;
			m_trig_act <= 1'b0;
			m_rst  <= 1'b1;
		end
		else begin
			m_prev_active <= in_active;
			m_prev_dbg    <= in_debug_mode;
			m_prev_pwr    <= in_power_down;

			// TRACE_ENABLE: armed on the rising edge of effective tracing;
			// NOT dropped by a pause; consumed by the anchor arms that clear
			// ExitFromTraceEnable (RST/DEBUG/POWERDOWN subsume, TE emits).
			if (in_active && !f_prev_active)                       m_te <= 1'b1;
			else if ((f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST))
			      || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_DEBUG))
			      || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_POWERDOWN))
			      || (f_SR == 4'(NEXUS_SYNC_TRACE_ENABLE)))        m_te <= 1'b0;

			// DEBUG exit: armed on falling debug_mode while tracing active;
			// dropped on pause; consumed by its own arm or subsumed by RST.
			if (m_prev_dbg && !in_debug_mode && in_active)         m_dbg <= 1'b1;
			else if (!in_active)                                   m_dbg <= 1'b0;
			else if ((f_SR == 4'(NEXUS_SYNC_EXIT_FROM_DEBUG))
			      || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST)))   m_dbg <= 1'b0;

			// POWERDOWN exit: analogous.
			if (m_prev_pwr && !in_power_down && in_active)         m_pwr <= 1'b1;
			else if (!in_active)                                   m_pwr <= 1'b0;
			else if ((f_SR == 4'(NEXUS_SYNC_EXIT_FROM_POWERDOWN))
			      || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST)))   m_pwr <= 1'b0;

			// EVTI marker: armed on an evti pulse while active; dropped on
			// pause; consumed by its own arm or subsumed by RST.
			if (in_evti && in_active)                              m_evti <= 1'b1;
			else if (!in_active)                                   m_evti <= 1'b0;
			else if ((f_SR == 4'(NEXUS_SYNC_EVTI))
			      || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST)))   m_evti <= 1'b0;

			// Trigger marker: armed on a trigger pulse while active and
			// runtime-enabled; dropped on pause; consumed by its own arm.
			// (Deliberately NOT cleared by the RST arm — the RTL keeps a
			// pending trigger across the reset re-anchor.)
			// P7: TWO enable sources feed the SAME one-shot -- the historical
			// InstTrigEnable and the TCI trigger action 4 (trace-notify),
			// which the spec does NOT gate on InstTrigEnable. Modelling them
			// as an OR is also the de-duplication proof: with both active the
			// latch still arms exactly once, so the SYNC=6 arm below can
			// never fire twice for one pulse.
			if (in_trigger && in_active
			    && (in_trig_en
			        || (CT_EN_TRIG_REGS
			            && (in_trig_act == 4'(ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_NOTIFY)))))
				                                                   m_trig <= 1'b1;
			else if (!in_active)                                   m_trig <= 1'b0;
			else if (f_SR == 4'(NEXUS_SYNC_WATCHPOINT))            m_trig <= 1'b0;

			// P7 non-vacuity provenance (audit A-2): armed ONLY by the TCI
			// action 4 with InstTrigEnable = 0, cleared exactly where the DUT
			// clears TrigPending. Carries the C_trig_action4 witness -- proof
			// that the action-only path can really reach a SYNC=6, so
			// A_trig_complete's action term is live and not dead code.
			if (in_trigger && in_active && !in_trig_en
			    && CT_EN_TRIG_SYNC && CT_EN_TRIG_REGS
			    && (in_trig_act == 4'(ct_cs_cpuif__te__trTeTrigExtInControl__trTeTrigAction_e__TRIG_ACT_NOTIFY)))
				                                                   m_trig_act <= 1'b1;
			else if (!in_active)                                   m_trig_act <= 1'b0;
			else if (f_SR == 4'(NEXUS_SYNC_WATCHPOINT))            m_trig_act <= 1'b0;

			// Post-reset opportunity: exact mirror (consumed by the first
			// anchor-qualified retire, emission or not).
			if (m_rst && in_anchor_ok)                             m_rst <= 1'b0;
		end
		m_te_q   <= m_te;
		m_dbg_q  <= m_dbg;
		m_pwr_q  <= m_pwr;
		m_evti_q <= m_evti;
		m_trig_q <= m_trig;
		m_trig_act_q <= m_trig_act;
		m_rst_q  <= m_rst;
	end

	// ------------------------------------------------------------------
	// Assertions
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (f_past_valid && !p_rst_q && !rst) begin
			// P-SYNC-1 — Klasse-9-Regression (Gate 14, Fix 335393b6):
			// no PERIODIC while the TRACE_ENABLE re-anchor is outstanding.
			assert (!((f_SR == 4'(NEXUS_SYNC_PERIODIC)) && p_pending_q)); // A_sync1

`ifndef RED_CLASS9
			// Canaries (probe binding + exact mirrors)
			assert (f_prev_active == m_prev_active);              // A_canary_active
			assert (f_prev_dbg    == m_prev_dbg);                 // A_canary_dbg
			assert (f_prev_pwr    == m_prev_pwr);                 // A_canary_pwr
			assert (f_rst_pend    == m_rst);                      // A_canary_rst
			assert (sync_o.reason == nexus_sync_reason_e'(p_SR_q)); // A_canary_pipe (extra_delay=0 tap)

			// Strengthening: DUT one-shot implies model armed (model clears
			// one observation cycle later, so it is a superset).
			// DIRECTION WARNING (P7 audit A-2): these five have the MODEL on
			// the conclusion side. A model term that arms in more states
			// makes them monotonically weaker, and a DUT that never arms at
			// all satisfies them vacuously -- they catch a SPURIOUS arm,
			// never a MISSING one. The A_*_complete block below carries the
			// other direction; do not add an arming source here without
			// adding it there.
			assert (!f_te_pend   || m_te);                        // A_te_impl
			assert (!f_dbg_pend  || m_dbg);                       // A_dbg_impl
			assert (!f_pwr_pend  || m_pwr);                       // A_pwr_impl
			assert (!f_evti_pend || m_evti);                      // A_evti_impl
			assert (!f_trig_pend || m_trig);                      // A_trig_impl

			// COMPLETENESS -- the missing direction (P7 audit A-2). If an
			// arming condition held in the decision cycle, the DUT one-shot
			// IS set one cycle later. The only escape is that the DUT
			// consumed the request in the very same cycle: the priority
			// chain (RTL :396-451) assigns AFTER the arming statement
			// (RTL :329-381), so its clear wins, and that consumption is
			// observable as the corresponding SyncReason. Each escape list
			// below is exactly the set of arms that clear that register
			// (RTL :404-407 / :417-418 / :425-426 / :432 / :440); note the
			// reset re-anchor deliberately does NOT clear TrigPending.
			// These are the assertions that go red when an arming source is
			// removed from the hardware -- e.g. P7's trigger action 4
			// (mutation MUT-F1: cs_tip.trTeTrigExtInAction0 -> 4'd0).
			assert (!p_arm_te_q   || f_te_pend
			        || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST))
			        || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_DEBUG))
			        || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_POWERDOWN))
			        || (f_SR == 4'(NEXUS_SYNC_TRACE_ENABLE)));    // A_te_complete
			assert (!p_arm_dbg_q  || f_dbg_pend
			        || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_DEBUG))
			        || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST))); // A_dbg_complete
			assert (!p_arm_pwr_q  || f_pwr_pend
			        || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_POWERDOWN))
			        || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST))); // A_pwr_complete
			assert (!p_arm_evti_q || f_evti_pend
			        || (f_SR == 4'(NEXUS_SYNC_EVTI))
			        || (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST))); // A_evti_complete
			assert (!p_arm_trig_q || f_trig_pend
			        || (f_SR == 4'(NEXUS_SYNC_WATCHPOINT)));      // A_trig_complete

			// P-SYNC-2 — one-shot semantics: an emitted sync of a one-shot
			// type had its one-shot armed in the decision cycle.
			assert (!(f_SR == 4'(NEXUS_SYNC_TRACE_ENABLE))       || m_te_q);   // A_sync2_te
			assert (!(f_SR == 4'(NEXUS_SYNC_EXIT_FROM_DEBUG))    || m_dbg_q);  // A_sync2_dbg
			assert (!(f_SR == 4'(NEXUS_SYNC_EXIT_FROM_POWERDOWN))|| m_pwr_q);  // A_sync2_pwr
			assert (!(f_SR == 4'(NEXUS_SYNC_EVTI))               || m_evti_q); // A_sync2_evti
			assert (!(f_SR == 4'(NEXUS_SYNC_WATCHPOINT))         || m_trig_q); // A_sync2_trig
			assert (!(f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST))  || m_rst_q);  // A_sync2_rst

			// P-SYNC-2 — pause drops the event one-shots (RTL lines 289 ff.).
			assert (!p_paused_q || !(f_dbg_pend || f_pwr_pend
			                      || f_evti_pend || f_trig_pend));           // A_sync2_drop

			// P-SYNC-3 — anchor qualification: any emitted SyncReason was
			// decided in a sync_anchor_ok cycle.
			assert ((f_SR == 4'(NEXUS_SYNC_NONE)) || p_anchor_ok_q);          // A_sync3

			// P-SYNC-5 (quota family, mode gating): a PERIODIC can only
			// originate from a mode-SELECTED counter source. In the two
			// modes without one — OFF (0) and ATB (7, the explicit-
			// request arm) — no PERIODIC may ever be emitted, no matter
			// what the (free) quota levels in_req_bytes/in_req_msgs do.
			// Formal shadow of the per-term mode gates in is_overflow;
			// red under mutation M-A (TRACE_BYTES gate dropped: a held
			// byte-quota level then fires PERIODIC in mode OFF/ATB —
			// exactly the latent pre-P2 ungated-OR defect, TASK_STATE G6).
			assert (!((f_SR == 4'(NEXUS_SYNC_PERIODIC))
			          && ((p_sync_mode_q == 3'(ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_OFF))
			           || (p_sync_mode_q == 3'(ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_ATB))))); // A_sync5_mode
`endif
		end
	end

`ifndef RED_CLASS9
	// ------------------------------------------------------------------
	// Cover (non-vacuity witnesses)
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (f_past_valid && !p_rst_q && !rst) begin
			cover (f_SR == 4'(NEXUS_SYNC_PERIODIC));              // C_periodic
			cover (f_SR == 4'(NEXUS_SYNC_TRACE_ENABLE));          // C_te
			cover (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_SYS_RST));     // C_rst
			cover (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_DEBUG));       // C_dbg
			cover (f_SR == 4'(NEXUS_SYNC_EXIT_FROM_POWERDOWN));   // C_pwr
			cover (f_SR == 4'(NEXUS_SYNC_EVTI));                  // C_evti
			cover (f_SR == 4'(NEXUS_SYNC_WATCHPOINT));            // C_trig
			// P7 (audit A-2): the SAME marker produced by the TCI trigger
			// action 4 ALONE, with the historical InstTrigEnable off.
			cover ((f_SR == 4'(NEXUS_SYNC_WATCHPOINT)) && m_trig_act_q); // C_trig_action4
			// The Gate-14 collision, resolved the FIXED way: re-anchor wins
			// while a periodic/extsync trigger could have fired.
			cover ((f_SR == 4'(NEXUS_SYNC_TRACE_ENABLE)) && p_pending_q); // C_resume_anchor
			// A pause with a still-armed TE one-shot (survives the pause).
			cover (f_te_pend && !in_active);                      // C_pause_pending
			// A quota-mode PERIODIC actually fires through the CDC-crossed
			// level (non-vacuity for A_sync5_mode's mode discrimination).
			cover ((f_SR == 4'(NEXUS_SYNC_PERIODIC))
			       && (p_sync_mode_q == 3'(ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES))); // C_quota_periodic
		end
	end
`endif

endmodule : f_preproc_check


`ifndef RED_CLASS9
// Bounded-liveness top (P-SYNC-4): deterministic environment — permanent
// instruction-count overflow pressure, fair retires, no competing events.
// The gap bound proves the Klasse-9 guard does not starve the periodic arm.
// (Compiled out under RED_CLASS9: the pre-fix red-side DUT lacks the P2
// quota ports this top connects.)
module f_live (
	input wire logic clk,
	input wire logic rst
);
	import tip_pkg::*;
	import nexus::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	tip_if           tip ();
	ct_sync_if       sync_o ();
	ct_cs_tipclk_if  cs ();

	// Fair, maximally simple environment: retire every cycle, plain itype.
	assign tip.iretire    = 1'b1;
	assign tip.ilastsize  = 2'd2;
	assign tip.itype      = OTHER;
	assign tip.debug_mode = 1'b0;
	assign tip.evti       = 1'b0;
	assign tip.power_down = 1'b0;
	assign tip.trigger    = 1'b0;

	assign cs.trTeEnable                 = 1'b1;
	assign cs.trTeInstTracing            = 1'b1;
	assign cs.trTeInstEnBranchPrediction = 1'b0;
	assign cs.trTeInstTrigEnable         = 1'b0;
	// P7: no external trigger action either -- these environments prove
	// liveness/quota, not the marker path.
	assign cs.trTeTrigExtInAction0       = 4'd0;
	// INSTRUCTIONS mode, minimal period: sync_count_max = 1 << (0+4) = 16.
	assign cs.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_INSTRUCTIONS;
	assign cs.trTeInstSyncMax  = 4'd0;

	assign sync_o.done = 1'b0;
	// P8: the TE request source is proven in its own top (f_tereq); tie it
	// off here so the existing proofs stay exactly the environment they were
	// written for.
	assign cs.trTeInstSyncReq = 1'b0;

	ct_L23_preproc_sync dut (
		.clk                       (clk),
		.rst                       (rst),
		.tip                       (tip),
		.wall_clk_rst              (rst),
		.wall_clk                  (clk),
		.proc_clk                  (clk),
		.proc_rst                  (rst),
		.sync_req_atb_synq         (1'b0),
		.synq_req_trace_byte_count (1'b0),
		.synq_req_trace_msg_count  (1'b0),
		.quota_cnt_clr             (),
		.quota_byte_ovf_tip        (),
		.quota_msg_ovf_tip         (),
		.sync                      (sync_o),
		.cs_tip                    (cs),
		.internal_delay            (),
		.extra_delay               ('0)
	);

	wire logic [3:0] f_SR = dut.SyncReason;

	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;
	// Reset exactly in the first cycle, never again (deterministic run).
	always_comb assume (rst == !f_past_valid);

	// ASM-SYNC-4 is RETIRED (D1). It used to read
	//     assume (dut.cnt_{tipcycles,tipinstructions,tiphalfword,wall_clk}.add == '0)
	// because the DUT drove none of the four add ports: the fields were
	// undriven, synthesis tied them to 0 and 4-state simulation read X
	// (`add != '0` evaluates false). Without the pin the solver found a
	// saturation ESCAPE in counter.sv — land EXACTLY on overflow_value via
	// the add path (`wide > ov` misses equality), then step past it via the
	// inc path (`Count+1 == ov` never true again), Overflow never sets and
	// the periodic sync starves. That was hardening finding F-1.
	//
	// D1 implemented BOTH halves of the F-1 recommendation: counter.sv's add
	// path now compares `>=`, and all four add ports are driven explicitly —
	// three at '0, and cnt_tiphalfword with the beat's half-word count,
	// which is what makes the ITR_SYNC_HALFWORDS cadence count half-words at
	// all (B-R13-1). Keeping the assumption would therefore be worse than
	// useless: on cnt_tiphalfword it is a CONTRADICTION on every retiring
	// beat, and a contradiction does not constrain the model, it EMPTIES it
	// — every property below would pass vacuously. The other three are
	// driven constants, so assuming them is redundant.
	//
	// P2 note (D3) stays true for a different reason: the trace-quota
	// counters in the egress modules are deliberately not counter.sv
	// instances (they were written with the `>=` comparison F-1 asked for)
	// and are modeled EXACTLY (step 4, clr priority, saturation at the
	// threshold) in the f_quota top below.

	// P-SYNC-4: no starvation — some sync within any 64-cycle window.
	logic [7:0] f_gap = '0;
	logic [3:0] f_num_per = '0;
	always_ff @(posedge clk) begin
		if (rst)                                f_gap <= '0;
		else if (f_SR != 4'(NEXUS_SYNC_NONE))   f_gap <= '0;
		else                                    f_gap <= f_gap + 1'b1;
		if (rst)                                     f_num_per <= '0;
		else if ((f_SR == 4'(NEXUS_SYNC_PERIODIC)) && (f_num_per != 4'd15))
		                                             f_num_per <= f_num_per + 1'b1;
	end

	always @(posedge clk) begin
		if (f_past_valid && !rst) begin
			assert (f_gap <= 8'd64);                              // A_sync4_bound
			cover (f_num_per == 4'd3);                            // C_sync4_recurrence
		end
	end

endmodule : f_live


// Trace-quota closed loop (P-SYNC-5b/6/7): deterministic fair environment
// (retire every cycle, BP off, tracing on, TRACE_BYTES mode, Max=0 ->
// 16-B quota) around the DUT, with an EXACT model of the egress byte-quota
// counter (ct_L2_mseo_mdo_formatter genQuotaCnt: step ATB_BEAT_BYTES=4,
// clr priority, saturation AT the threshold via `>=`, mode term constant
// true here). The loop closes through the DUT's REAL vector_cdc2 pairs:
// model level -> synq_req_trace_byte_count -> is_overflow -> PERIODIC ->
// SyncCntClr -> quota_cnt_clr -> model clear. Under ASM-SYNC-3 (single
// clock) the handshake latency is deterministic; the byte-event input is
// FREE (solver-chosen worst case, up to the ATB ceiling of one 4-byte
// beat per cycle).
//
// Observation is PORT-only (no new XMR probes): sync_o.reason is the
// extra_delay=0 pipe tap (SyncReason delayed one cycle — the existing
// A_canary_pipe in f_top proves that equivalence), quota_cnt_clr is a DUT
// output.
//
// DELTA_F derivation (single-clock formal analogue of the D7 delta; the
// multi-clock Delta for the on-wire window check is derived in
// scripts/check_sync_window.py):
//   vector_cdc2 worst-case transfer (stale in-flight transfer, then the
//   new value): capture 3 + ack 3 + relaunch 1 + capture 3 = D_CDC = 10.
//   detect path : level in (D_CDC) + arm decision 1 + pipe tap 1  = 12
//   rearm dead  : clr out (D_CDC) + level-drop back (D_CDC)
//                 + SyncCntClr release 1 + clr fall out (D_CDC)   = 31
//   refill      : 16 B at 4 B/cycle                               =  4
//   window <= (12 + 31 + 4) cycles * 4 B/cycle = 188 B  ->
//   A_sync5_win bound = F_QUOTA + DELTA_F with DELTA_F = 184
//   (16 + 184 = 200 B >= 188 analytic worst case; margin 12 B for the
//   +-few-cycle uncertainty of the handshake accounting).
module f_quota (
	input wire logic clk,
	input wire logic rst,
	input wire logic ev_byte     // FREE byte event: one accepted 4-B ATB beat
);
	import tip_pkg::*;
	import nexus::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	localparam int unsigned F_QUOTA   = 16;   // 2^(Max+4), Max=0
	localparam int unsigned F_DELTA   = 184;  // derivation above
	localparam int unsigned F_K6      = 32;   // P-SYNC-6 bound (detect path 12 + margin)

	tip_if           tip ();
	ct_sync_if       sync_o ();
	ct_cs_tipclk_if  cs ();

	// Fair, maximally simple environment: retire every cycle, plain itype,
	// BP off (every retire is a legal anchor), tracing permanently on.
	assign tip.iretire    = 1'b1;
	assign tip.ilastsize  = 2'd2;
	assign tip.itype      = OTHER;
	assign tip.debug_mode = 1'b0;
	assign tip.evti       = 1'b0;
	assign tip.power_down = 1'b0;
	assign tip.trigger    = 1'b0;

	assign cs.trTeEnable                 = 1'b1;
	assign cs.trTeInstTracing            = 1'b1;
	assign cs.trTeInstEnBranchPrediction = 1'b0;
	assign cs.trTeInstTrigEnable         = 1'b0;
	// P7: no external trigger action either -- these environments prove
	// liveness/quota, not the marker path.
	assign cs.trTeTrigExtInAction0       = 4'd0;
	assign cs.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES;
	assign cs.trTeInstSyncMax  = 4'd0;

	assign sync_o.done = 1'b0;
	// P8: the TE request source is proven in its own top (f_tereq); tie it
	// off here so the existing proofs stay exactly the environment they were
	// written for.
	assign cs.trTeInstSyncReq = 1'b0;

	// ------------------------------------------------------------------
	// Exact model of the egress byte-quota counter (genQuotaCnt mirror;
	// the mode terms are constant true in this environment).
	// ------------------------------------------------------------------
	uwire logic quota_clr;                       // DUT quota_cnt_clr output
	ct_synccnt_counter_t QuotaCnt = '0;
	uwire logic quota_ovf = (QuotaCnt >= ct_synccnt_counter_t'(F_QUOTA));
	always_ff @(posedge clk) begin
		if (rst || quota_clr)          QuotaCnt <= '0;
		else if (!quota_ovf && ev_byte) QuotaCnt <= QuotaCnt + ct_synccnt_counter_t'(4);
	end

	ct_L23_preproc_sync dut (
		.clk                       (clk),
		.rst                       (rst),
		.tip                       (tip),
		.wall_clk_rst              (rst),   // ASM-SYNC-3
		.wall_clk                  (clk),   // ASM-SYNC-3
		.proc_clk                  (clk),   // ASM-SYNC-3 (quota domain)
		.proc_rst                  (rst),
		.sync_req_atb_synq         (1'b0),
		.synq_req_trace_byte_count (quota_ovf),
		.synq_req_trace_msg_count  (1'b0),
		.quota_cnt_clr             (quota_clr),
		.quota_byte_ovf_tip        (),
		.quota_msg_ovf_tip         (),
		.sync                      (sync_o),
		.cs_tip                    (cs),
		.internal_delay            (),
		.extra_delay               ('0)
	);

	// Port-based observation (extra_delay=0 pipe tap).
	uwire logic f_periodic = (sync_o.reason == NEXUS_SYNC_PERIODIC);
	uwire logic f_sync_any = (sync_o.reason != NEXUS_SYNC_NONE);

	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;
	// Reset exactly in the first cycle, never again (deterministic run).
	always_comb assume (rst == !f_past_valid);

	// ASM-SYNC-4 is RETIRED (D1) -- no assumption stands here any more. See
	// the note at the f_live top.

	// ------------------------------------------------------------------
	// P-SYNC-5b — window bound: bytes accepted between two consecutive
	// emitted syncs (ANY sync is a re-anchor; the startup
	// EXIT_FROM_SYS_RST also rearms the quota) never exceed the
	// programmed quota plus the derived slack.
	// ------------------------------------------------------------------
	logic [15:0] f_win = '0;
	always_ff @(posedge clk) begin
		if (rst)             f_win <= '0;
		else if (f_sync_any) f_win <= (ev_byte ? 16'd4 : 16'd0);
		else if (ev_byte)    f_win <= f_win + 16'd4;
	end

	// ------------------------------------------------------------------
	// P-SYNC-6 — no lost request: a held overflow level leads to a sync
	// within F_K6 cycles (level phases during the rearm drain are cleared
	// by the crossing clr and terminate the pressure window).
	// ------------------------------------------------------------------
	logic [7:0] f_press = '0;
	always_ff @(posedge clk) begin
		if (rst || !quota_ovf || f_sync_any) f_press <= '0;
		else                                 f_press <= f_press + 1'b1;
	end

	// ------------------------------------------------------------------
	// P-SYNC-7 — no double request: a second quota PERIODIC requires an
	// intervening egress-counter rearm (quota_clr high at least once
	// since the previous PERIODIC).
	// ------------------------------------------------------------------
	logic f_seen_per = 1'b0;
	logic f_rearm    = 1'b0;
	logic [1:0] f_num_per = '0;
	always_ff @(posedge clk) begin
		if (rst) begin
			f_seen_per <= 1'b0;
			f_rearm    <= 1'b0;
			f_num_per  <= '0;
		end
		else if (f_periodic) begin
			f_seen_per <= 1'b1;
			f_rearm    <= 1'b0;
			if (f_num_per != 2'd3) f_num_per <= f_num_per + 1'b1;
		end
		else if (quota_clr) f_rearm <= 1'b1;
	end

	always @(posedge clk) begin
		if (f_past_valid && !rst) begin
			assert (f_win   <= 16'(F_QUOTA + F_DELTA));           // A_sync5_win
			assert (f_press <= 8'(F_K6));                         // A_sync6_live
			assert (!(f_periodic && f_seen_per) || f_rearm);      // A_sync7_rearm
			// Non-vacuity witnesses: pressure exists, the quota fires, and
			// it fires AGAIN after a full rearm round trip.
			cover (quota_ovf);                                    // C_quota_press
			cover (f_num_per == 2'd1);                            // C_quota_per1
			cover (f_num_per == 2'd2);                            // C_quota_per2
		end
	end

endmodule : f_quota

// ---------------------------------------------------------------------------
// Explicit-sync-request-over-TE closed loop (P-SYNC-9/10, P8): the same
// deterministic fair environment as f_quota (retire every cycle, BP off,
// tracing on) with InstSyncMode = OFF, so the ONLY thing that can produce a
// synchronization message after the startup anchor is the request itself.
//
// The environment is not a model of the programming interface, it IS the
// programming interface: ct_sync_req_pacer (the CSR shim's launch pacing,
// instantiated in ct_cs_cpuif_wb.sv exactly like this) and BOTH strobe_cdc
// crossings the shim wires around it are in the cone. The loop therefore
// closes through the real launch path, the real acknowledge path and the
// DUT's real ports. The write event itself is FREE (solver-chosen).
//
// Honest scope of that claim (P8 audit B-2): the two crossings run at EQUAL
// clocks here -- ASM-SYNC-3, the single-clock assumption this whole wrapper
// carries. What is proven is that the pacing protocol plus the toggle
// synchronizers lose no request and serve none twice at a common clock. That
// two independent clocks do not break a toggle synchronizer is a CDC
// methodology argument (and the timing constraints in the .xdc), NOT a result
// of this proof. Nothing else of the CSR shim is in the cone: address
// decoding, the generated register block and the field's self-clear are
// covered by simulation (scripts/cli_tesyncreq_test.sh), not here.
//
// Observation is PORT-only: sync_o.reason is the extra_delay=0 pipe tap
// (A_canary_pipe in f_top proves that equivalence) and the acknowledgement
// is an interface output of the DUT.
//
// F_K9 derivation (single clock, ASM-SYNC-3): write -> launch 0 (combinational
// in the pacer) + strobe_cdc 3 (edge flop + 2-FF synchronizer) + pending latch
// 1 + arm decision/pipe tap 1 = 5 cycles for a request that is launched right
// away. A write that has to wait for a queued predecessor adds the return
// path: message -> ack strobe_cdc 3 -> launch -> 5 again, and the startup
// EXIT_FROM_SYS_RST anchor plus the TRACE_ENABLE guard can hold the arm for a
// few more. The bound is set to 32 -- above the analytic worst case (~15) and
// still tight enough that a dead request path (mutations ME/MF/MG) trips it
// inside the BMC depth.
// ---------------------------------------------------------------------------
module f_tereq (
	input wire logic clk,
	input wire logic rst,
	input wire logic ev_write    // FREE: software writes 1 to trTeControl.InstSyncReq
);
	import tip_pkg::*;
	import nexus::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	localparam int unsigned F_K9 = 32;   // no-lost-request bound (derivation above)

	tip_if           tip ();
	ct_sync_if       sync_o ();
	ct_cs_tipclk_if  cs ();

	assign tip.iretire    = 1'b1;
	assign tip.ilastsize  = 2'd2;
	assign tip.itype      = OTHER;
	assign tip.debug_mode = 1'b0;
	assign tip.evti       = 1'b0;
	assign tip.power_down = 1'b0;
	assign tip.trigger    = 1'b0;

	assign cs.trTeEnable                 = 1'b1;
	assign cs.trTeInstTracing            = 1'b1;
	assign cs.trTeInstEnBranchPrediction = 1'b0;
	assign cs.trTeInstTrigEnable         = 1'b0;
	assign cs.trTeTrigExtInAction0       = 4'd0;
	// No cadence at all: every sync in this environment is either the startup
	// anchor or a served request. That is what makes the counting properties
	// below unambiguous -- and it is at the same time the mode-independence
	// claim D-P8-5 (the request works with InstSyncMode = OFF).
	assign cs.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_OFF;
	assign cs.trTeInstSyncMax  = 4'd0;

	assign sync_o.done = 1'b0;

	// ------------------------------------------------------------------
	// The real CSR-side pacing and the real crossings (see header).
	// ------------------------------------------------------------------
	uwire logic req_wb;    // wb side: the request LEVEL the pacer raises
	uwire logic ack_wb;    // wb side: the acknowledgement level, crossed back
	uwire logic req_tip;   // tip side: the request level, crossed over
	// One launch = the rising edge of the request level; the properties below
	// count launches, so they need that edge, not the level.
	logic       req_wb_q = 1'b0;
	logic       ack_wb_q = 1'b0;
	always_ff @(posedge clk) begin
		req_wb_q <= rst ? 1'b0 : req_wb;
		ack_wb_q <= rst ? 1'b0 : ack_wb;
	end
	uwire logic launch = req_wb && !req_wb_q;

	ct_sync_req_pacer pacer (
		.clk   (clk),
		.rst   (rst),
		.write (ev_write),
		.ack   (ack_wb),
		.req   (req_wb)
	);
	// ASM-SYNC-5: this environment has ONE reset, so the consumer is never
	// reset on its own. The split-reset case is f_tereqrst.
	signal_cdc cdc_req (
		.clk (clk),
		.rst (rst),
		.in  (req_wb),
		.out (req_tip)
	);
	signal_cdc cdc_ack (
		.clk (clk),
		.rst (rst),
		.in  (cs.trTeInstSyncReqAck),
		.out (ack_wb)
	);
	assign cs.trTeInstSyncReq = req_tip;

	ct_L23_preproc_sync dut (
		.clk                       (clk),
		.rst                       (rst),
		.tip                       (tip),
		.wall_clk_rst              (rst),   // ASM-SYNC-3
		.wall_clk                  (clk),   // ASM-SYNC-3
		.proc_clk                  (clk),   // ASM-SYNC-3
		.proc_rst                  (rst),
		.sync_req_atb_synq         (1'b0),
		.synq_req_trace_byte_count (1'b0),
		.synq_req_trace_msg_count  (1'b0),
		.quota_cnt_clr             (),
		.quota_byte_ovf_tip        (),
		.quota_msg_ovf_tip         (),
		.sync                      (sync_o),
		.cs_tip                    (cs),
		.internal_delay            (),
		.extra_delay               ('0)
	);

	uwire logic f_req_sync = (sync_o.reason == NEXUS_SYNC_REQ);

	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;
	always_comb assume (rst == !f_past_valid);

	// ASM-SYNC-4 is RETIRED (D1) -- no assumption stands here any more. See
	// the note at the f_live top.

	// ------------------------------------------------------------------
	// P-SYNC-9 -- no lost request: after a WRITE to trTeControl.InstSyncReq a
	// synchronization message follows within F_K9 cycles. The trigger is the
	// software event and the only thing that stops the clock is a MESSAGE.
	//
	// The first version keyed the pressure on the pacer's Busy flag, and that
	// was a hole the DUT itself controlled: Busy is released by the DUT's own
	// acknowledgement, so a DUT that acknowledges without emitting anything
	// ("ack yes, message no") kept this property green and was caught only by
	// the auxiliary bound below -- an assertion that does not enforce the
	// behaviour it is named after (P8 audit C-2, the same class as P7 A-2).
	// Mutation MG_ack_without_msg is exactly that defect and is red here now.
	//
	// A message answers one outstanding request and restarts the deadline for
	// whatever is still queued; a write landing in the message cycle is NOT
	// answered by it (the DUT cannot have seen it yet), so it keeps the clock
	// running.
	// ------------------------------------------------------------------
	logic       f_wait  = 1'b0;   // a write is waiting for its message
	logic [7:0] f_press = '0;
	always_ff @(posedge clk) begin
		if (rst) begin
			f_wait  <= 1'b0;
			f_press <= '0;
		end
		else if (f_req_sync) begin
			f_wait  <= ev_write;
			f_press <= '0;
		end
		else if (ev_write || f_wait) begin
			f_wait  <= 1'b1;
			f_press <= f_press + 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// P-SYNC-10 -- no double request, as a CREDIT count: every explicit sync
	// consumes one launched request, so the encoder can never emit more
	// messages than were asked for. A flag ("was there a launch since the
	// last message") is not enough here and was tried first: a launch can
	// happen while the previous message is still in the reason pipe, and the
	// flag then loses it -- the property failed on its own bookkeeping, not
	// on the DUT (observed at step 7, two legitimate requests). The counter
	// has no such blind spot.
	//
	// The assertion reads the credit BEFORE this cycle's update, which is
	// exactly right: a message decided in the previous cycle cannot be the
	// answer to a launch happening in this one.
	// ------------------------------------------------------------------
	logic [3:0] f_credit  = '0;   // launched, not yet answered
	logic [1:0] f_num_req = '0;
	always_ff @(posedge clk) begin
		if (rst) begin
			f_credit  <= '0;
			f_num_req <= '0;
		end
		else begin
			f_credit <= f_credit + (launch ? 4'd1 : 4'd0) - (f_req_sync ? 4'd1 : 4'd0);
			if (f_req_sync && (f_num_req != 2'd3)) f_num_req <= f_num_req + 1'b1;
		end
	end

	// Contract witness for the queue DEPTH (P8 audit A-1): a write that lands
	// while a request is still outstanding is not swallowed -- it becomes its
	// own request and produces a SECOND synchronization message. The audit
	// proved the old "is absorbed" wording wrong with exactly this cover, so
	// it stays in the tree as the standing witness of the real contract; the
	// simulation half of it is the req2 leg of scripts/cli_tesyncreq_test.sh.
	logic f_write_while_busy = 1'b0;
	always_ff @(posedge clk) begin
		if (rst)                                 f_write_while_busy <= 1'b0;
		else if (ev_write && (f_credit != 4'd0)) f_write_while_busy <= 1'b1;
	end

	always @(posedge clk) begin
		if (f_past_valid && !rst) begin
			assert (f_press <= 8'(F_K9));                        // A_sync9_live
			// RED_MASK_SYNC10 (red runs only): the credit pair below trips on
			// a defect that also starves the request path, and its shallower
			// counterexample would hide which property really catches it. A
			// green run passes no defines -- see run.sh.
`ifndef RED_MASK_SYNC10
			assert (!f_req_sync || (f_credit != 4'd0));           // A_sync10_credit
			// Aux invariant: the pacing keeps at most one request in flight
			// (plus the co-timed launch), so the credit cannot run away --
			// a counter that could would make A_sync9 vacuous.
			assert (f_credit <= 4'd2);                            // A_sync10_bound
`endif
			// The handshake protocol itself, from the ports alone: a request
			// is only ever raised out of the IDLE phase (no request standing,
			// no acknowledgement standing), and it is only ever withdrawn
			// once the acknowledgement is in. That is what keeps two requests
			// a full round trip apart -- the property the pacing exists for,
			// and the one a "just hold a level" simplification would break.
			assert (!launch || !ack_wb_q);                        // A_sync12_phase
			assert (!(!req_wb && req_wb_q && !ack_wb_q));         // A_sync12_hold
			// Non-vacuity witnesses: a request is served, a SECOND one is
			// served after a full round trip, and a write arriving while one
			// is outstanding yields that second message.
			cover (f_num_req == 2'd1);                            // C_tereq_served
			cover (f_num_req == 2'd2);                            // C_tereq_twice
			cover (f_write_while_busy && (f_num_req == 2'd2));    // C_tereq_queued_second
		end
	end

endmodule : f_tereq

// ---------------------------------------------------------------------------
// P-SYNC-12 -- the request survives a reset of the CONSUMER's domain alone
// (P8 closing audit B-N1).
//
// The two halves of one request live in two reset domains: the pacing in
// wb_rst, the pending latch in tip_rst. ct_encoder carries both as
// INDEPENDENT inputs and doc/integration.adoc says so ("every domain has its
// own synchronous reset"), so a core reset that leaves the CSR domain running
// is a legal system event -- and it clears the pending latch without an
// acknowledgement. f_tereq cannot see any of this: it has ONE reset
// (ASM-SYNC-5), which is exactly the assumption the audit found unstated.
//
// This environment removes that assumption. `ev_peer_rst` is FREE: the solver
// may reset the consumer whenever and for as long as it likes, and only the
// consumer -- the pacer keeps running, and so do the two synchroniser halves
// that live on its side. Everything else is f_tereq's: the same deterministic
// retire stream, InstSyncMode = OFF, the real pacer and the real crossings.
//
// What is proven: a request the consumer has NOT taken is not dropped on the
// floor by a reset -- once the consumer runs again it is taken and answered
// within F_K12 cycles. A request the consumer HAS taken counts as answered
// (its acknowledgement is up) even if the reset then wiped the message out of
// the sync pipe: the EXIT_FROM_SYS_RST anchor the consumer owes right
// afterwards is the re-anchor software asked for, and demanding a SYNC=14 on
// top of it would be demanding that a reset does not reset. The deadline
// RESTARTS on every reset: a consumer held in reset, or reset again and
// again, cannot be expected to answer.
//
// This is also the property the FIRST answer to B-N1 failed, twice, and both
// counterexamples came out of this task rather than out of a reading:
//   * keeping the strobe crossings and teaching the pacer to watch the
//     consumer's reset -- an acknowledgement already travelling when the
//     reset lands arrives BEFORE the synchronised reset does, clears the
//     pacer, and the request is gone (step 58);
//   * demanding a SYNC=14 after every reset -- the consumer had already
//     decided the message and the reset wiped it out of the pipe (step 51),
//     which is a reset doing its job, not a lost request.
// The level handshake needs no race to be won: "request up, acknowledgement
// down" is a statement about the present, not an event in the past.
//
// What is NOT proven, and deliberately so: that exactly ONE message follows.
// A request that had been served but whose acknowledgement the reset
// destroyed is asked for again, so a re-anchor may cost one additional
// synchronization message. A synchronization message is always safe to emit,
// and claiming otherwise would be a claim this environment cannot support.
//
// F_K12 derivation: the consumer leaves reset -> it re-detects the standing
// request level (signal_cdc, 2) -> pending latch 1 -> but it owes an
// EXIT_FROM_SYS_RST anchor first (1 retire) and holds lower-priority arms
// while the TRACE_ENABLE re-anchor is outstanding (a few more) -> arm + pipe
// tap 2. Analytic worst case ~15; the bound is 40, tight enough that a dead
// or wedged path trips it inside the BMC depth.
// ---------------------------------------------------------------------------
module f_tereqrst (
	input wire logic clk,
	input wire logic rst,           // power-on, both domains (pinned below)
	input wire logic ev_peer_rst,   // FREE: the CONSUMER's domain is reset
	input wire logic ev_write       // FREE: software writes 1 to InstSyncReq
);
	import tip_pkg::*;
	import nexus::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	localparam int unsigned F_K12 = 40;

	tip_if           tip ();
	ct_sync_if       sync_o ();
	ct_cs_tipclk_if  cs ();

	// The consumer's reset: power-on OR the free event. The pacer's own reset
	// is `rst` alone -- that asymmetry IS the case under test.
	uwire logic tip_rst = rst || ev_peer_rst;

	assign tip.iretire    = 1'b1;
	assign tip.ilastsize  = 2'd2;
	assign tip.itype      = OTHER;
	assign tip.debug_mode = 1'b0;
	assign tip.evti       = 1'b0;
	assign tip.power_down = 1'b0;
	assign tip.trigger    = 1'b0;

	assign cs.trTeEnable                 = 1'b1;
	assign cs.trTeInstTracing            = 1'b1;
	assign cs.trTeInstEnBranchPrediction = 1'b0;
	assign cs.trTeInstTrigEnable         = 1'b0;
	assign cs.trTeTrigExtInAction0       = 4'd0;
	assign cs.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_OFF;
	assign cs.trTeInstSyncMax  = 4'd0;
	assign sync_o.done = 1'b0;

	uwire logic req_wb;
	uwire logic ack_wb;
	uwire logic req_tip;

	ct_sync_req_pacer pacer (
		.clk   (clk),
		.rst   (rst),
		.write (ev_write),
		.ack   (ack_wb),
		.req   (req_wb)
	);
	// The crossings as the shim wires them: the request's DESTINATION side
	// and the acknowledgement's SOURCE side live in the CONSUMER's reset,
	// the two other halves in the pacer's. That asymmetry is the case under
	// test.
	signal_cdc cdc_req (
		.clk (clk),
		.rst (tip_rst),
		.in  (req_wb),
		.out (req_tip)
	);
	signal_cdc cdc_ack (
		.clk (clk),
		.rst (rst),
		.in  (cs.trTeInstSyncReqAck),
		.out (ack_wb)
	);
	assign cs.trTeInstSyncReq = req_tip;

	ct_L23_preproc_sync dut (
		.clk                       (clk),
		.rst                       (tip_rst),
		.tip                       (tip),
		.wall_clk_rst              (tip_rst),  // ASM-SYNC-3
		.wall_clk                  (clk),      // ASM-SYNC-3
		.proc_clk                  (clk),      // ASM-SYNC-3
		.proc_rst                  (tip_rst),
		.sync_req_atb_synq         (1'b0),
		.synq_req_trace_byte_count (1'b0),
		.synq_req_trace_msg_count  (1'b0),
		.quota_cnt_clr             (),
		.quota_byte_ovf_tip        (),
		.quota_msg_ovf_tip         (),
		.sync                      (sync_o),
		.cs_tip                    (cs),
		.internal_delay            (),
		.extra_delay               ('0)
	);

	uwire logic f_req_sync = (sync_o.reason == NEXUS_SYNC_REQ);

	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;
	always_comb assume (rst == !f_past_valid);

	// ASM-SYNC-4 is RETIRED (D1) -- no assumption stands here any more. See
	// the note at the f_live top.

	// Pressure, as in f_tereq, with two differences.
	//
	// (1) A consumer reset RESTARTS the deadline instead of cancelling the
	//     claim: the write is still owed -- that is the whole point -- only
	//     the clock goes back to zero, because a consumer that is held in
	//     reset cannot answer.
	// (2) The acknowledgement counts as an answer, not only the message.
	//     That is not a weakening, it is the truthful line: once the consumer
	//     has taken the request and decided its message, a reset landing in
	//     the next cycle wipes that message out of the pipe -- and the
	//     EXIT_FROM_SYS_RST anchor the consumer owes right after IS the
	//     re-anchor software asked for. Demanding a SYNC=14 on top would be
	//     demanding that a reset does not reset. What must NOT happen, and
	//     what this measures, is a request the consumer never took being
	//     dropped on the floor: no acknowledgement, no message, ever.
	logic       f_wait  = 1'b0;
	logic [7:0] f_press = '0;
	logic       f_rst_hit = 1'b0;   // a waiting request was hit by a reset
	always_ff @(posedge clk) begin
		if (rst) begin
			f_wait    <= 1'b0;
			f_press   <= '0;
			f_rst_hit <= 1'b0;
		end
		else if (f_req_sync || ack_wb) begin
			f_wait    <= ev_write;
			f_press   <= '0;
			f_rst_hit <= 1'b0;
		end
		else if (tip_rst) begin
			f_wait    <= f_wait || ev_write;
			f_press   <= '0;
			f_rst_hit <= f_rst_hit || f_wait || ev_write;
		end
		else if (ev_write || f_wait) begin
			f_wait    <= 1'b1;
			f_press   <= f_press + 1'b1;
		end
	end

	always @(posedge clk) begin
		if (f_past_valid && !rst) begin
			// A_sync12_rstlive -- no wedged and no silently dropped request:
			// once the consumer is running again, a request it never took is
			// taken and answered within the bound.
			assert (f_press <= 8'(F_K12));
			// Non-vacuity: the interesting trace really happens -- a request
			// that was standing when the consumer was reset gets its own
			// SYNC = 14 afterwards, because the level was still there to be
			// seen. This is the witness the strobe design cannot produce.
			cover (f_rst_hit && f_req_sync);                      // C_rst_relaunch
			// And the reset really is exercised on its own.
			cover (tip_rst && !rst);                              // C_peer_rst_alone
		end
	end

endmodule : f_tereqrst

// ---------------------------------------------------------------------------
// Explicit request MEETS the trace quota (P-SYNC-11, P8 audit B-5): both
// sources live in ONE environment, so the collision is exercised on the same
// beat instead of merely coexisting in the same run.
//
// The system test can only place the two NEAR each other (a request while a
// byte quota is running); which retire the quota level actually lands on is
// not under the testbench's control. Here it is: the byte event is free, the
// write is free, and the solver is free to line them up -- so "arm 7 beats
// arm 8, and the quota is rearmed rather than lost" stops being a reading of
// the RTL and becomes a checked statement.
//
// Environment = f_quota's (deterministic retires, TRACE_BYTES mode, Max = 0,
// exact egress-counter model, real vector_cdc2 pairs inside the DUT) PLUS
// f_tereq's request path (the real ct_sync_req_pacer and both real strobe_cdc
// crossings at equal clocks, ASM-SYNC-3).
//
// Observation stays port-side: `quota_ovf` is the level this wrapper drives
// INTO the DUT, `f_tip_pend` is rebuilt from the DUT's own request strobe and
// acknowledgement, and the message is the extra_delay = 0 pipe tap.
// ---------------------------------------------------------------------------
module f_reqcoll (
	input wire logic clk,
	input wire logic rst,
	input wire logic ev_byte,    // FREE byte event: one accepted 4-B ATB beat
	input wire logic ev_write    // FREE: software writes 1 to trTeControl.InstSyncReq
);
	import tip_pkg::*;
	import nexus::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	localparam int unsigned F_QUOTA = 16;    // 2^(Max+4), Max = 0
	localparam int unsigned F_DELTA = 184;   // as f_quota (derivation there)
	localparam int unsigned F_K9    = 32;    // as f_tereq (derivation there)

	tip_if           tip ();
	ct_sync_if       sync_o ();
	ct_cs_tipclk_if  cs ();

	assign tip.iretire    = 1'b1;
	assign tip.ilastsize  = 2'd2;
	assign tip.itype      = OTHER;
	assign tip.debug_mode = 1'b0;
	assign tip.evti       = 1'b0;
	assign tip.power_down = 1'b0;
	assign tip.trigger    = 1'b0;

	assign cs.trTeEnable                 = 1'b1;
	assign cs.trTeInstTracing            = 1'b1;
	assign cs.trTeInstEnBranchPrediction = 1'b0;
	assign cs.trTeInstTrigEnable         = 1'b0;
	assign cs.trTeTrigExtInAction0       = 4'd0;
	assign cs.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES;
	assign cs.trTeInstSyncMax  = 4'd0;
	assign sync_o.done = 1'b0;

	// Egress byte-quota counter model (genQuotaCnt mirror, as f_quota).
	uwire logic quota_clr;
	uwire logic quota_ovf_tip;   // the crossed level, as the sync arm sees it
	ct_synccnt_counter_t QuotaCnt = '0;
	uwire logic quota_ovf = (QuotaCnt >= ct_synccnt_counter_t'(F_QUOTA));
	always_ff @(posedge clk) begin
		if (rst || quota_clr)           QuotaCnt <= '0;
		else if (!quota_ovf && ev_byte) QuotaCnt <= QuotaCnt + ct_synccnt_counter_t'(4);
	end

	// The real CSR-side pacing and the real crossings (as f_tereq).
	uwire logic req_wb;
	uwire logic ack_wb;
	uwire logic req_tip;

	logic       req_wb_q = 1'b0;
	always_ff @(posedge clk) req_wb_q <= rst ? 1'b0 : req_wb;
	uwire logic launch = req_wb && !req_wb_q;

	ct_sync_req_pacer pacer (
		.clk   (clk),
		.rst   (rst),
		.write (ev_write),
		.ack   (ack_wb),
		.req   (req_wb)
	);
	signal_cdc cdc_req (                     // ASM-SYNC-5, as f_tereq
		.clk (clk),
		.rst (rst),
		.in  (req_wb),
		.out (req_tip)
	);
	signal_cdc cdc_ack (
		.clk (clk),
		.rst (rst),
		.in  (cs.trTeInstSyncReqAck),
		.out (ack_wb)
	);
	assign cs.trTeInstSyncReq = req_tip;

	ct_L23_preproc_sync dut (
		.clk                       (clk),
		.rst                       (rst),
		.tip                       (tip),
		.wall_clk_rst              (rst),   // ASM-SYNC-3
		.wall_clk                  (clk),   // ASM-SYNC-3
		.proc_clk                  (clk),   // ASM-SYNC-3
		.proc_rst                  (rst),
		.sync_req_atb_synq         (1'b0),
		.synq_req_trace_byte_count (quota_ovf),
		.synq_req_trace_msg_count  (1'b0),
		.quota_cnt_clr             (quota_clr),
		// The crossed level AS THE ARM SEES IT -- a DUT output, so the
		// collision predicate below needs no XMR and no latency estimate.
		.quota_byte_ovf_tip        (quota_ovf_tip),
		.quota_msg_ovf_tip         (),
		.sync                      (sync_o),
		.cs_tip                    (cs),
		.internal_delay            (),
		.extra_delay               ('0)
	);

	uwire logic f_req_sync = (sync_o.reason == NEXUS_SYNC_REQ);
	uwire logic f_periodic = (sync_o.reason == NEXUS_SYNC_PERIODIC);
	uwire logic f_sync_any = (sync_o.reason != NEXUS_SYNC_NONE);

	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;
	always_comb assume (rst == !f_past_valid);

	// ASM-SYNC-4 is RETIRED (D1) -- no assumption stands here any more. See
	// the note at the f_live top.

	// The DUT's request-pending state, rebuilt from its own ports: a request
	// is owed while the request LEVEL stands and has not been acknowledged,
	// and it is settled when the acknowledgement goes up (P8 closing audit
	// B-N1 turned both signals from strobes into the two phases of a level
	// handshake, and this observer follows them).
	logic f_tip_pend = 1'b0;
	always_ff @(posedge clk) begin
		if (rst)                                             f_tip_pend <= 1'b0;
		else if (cs.trTeInstSyncReqAck)                      f_tip_pend <= 1'b0;
		else if (req_tip)                                    f_tip_pend <= 1'b1;
	end
	// "Just served" -- the acknowledgement's rising edge, not its level.
	logic       ack_tip_q = 1'b0;
	always_ff @(posedge clk) ack_tip_q <= rst ? 1'b0 : cs.trTeInstSyncReqAck;
	uwire logic ack_tip_rise = cs.trTeInstSyncReqAck && !ack_tip_q;

	// The startup anchor (EXIT_FROM_SYS_RST / TRACE_ENABLE) is behind us:
	// afterwards only PERIODIC and REQ can occur in this environment.
	logic f_started = 1'b0;
	always_ff @(posedge clk) begin
		if (rst)             f_started <= 1'b0;
		else if (f_sync_any) f_started <= 1'b1;
	end

	// Alignment: the arm decides in cycle T, SyncReason and the acknowledge
	// strobe register at T+1, and sync_o.reason is the extra_delay = 0 pipe
	// tap, i.e. T+2. So a message observed now was decided on the [1] stage
	// of these shift registers, and its acknowledgement is one stage behind.
	logic [1:0] sr_started  = '0;
	logic [1:0] sr_ovf_seen = '0;
	logic [1:0] sr_tip_pend = '0;
	logic       sr_ack      = 1'b0;
	always_ff @(posedge clk) begin
		sr_started  <= {sr_started[0],  f_started};
		sr_ovf_seen <= {sr_ovf_seen[0], quota_ovf_tip};
		sr_tip_pend <= {sr_tip_pend[0], f_tip_pend};
		sr_ack      <= ack_tip_rise;
	end

	// Window bound and request liveness, as in the single-source environments
	// -- here with the OTHER source running, which is the point.
	logic [15:0] f_win = '0;
	always_ff @(posedge clk) begin
		if (rst)             f_win <= '0;
		else if (f_sync_any) f_win <= (ev_byte ? 16'd4 : 16'd0);
		else if (ev_byte)    f_win <= f_win + 16'd4;
	end

	logic       f_wait  = 1'b0;
	logic [7:0] f_press = '0;
	always_ff @(posedge clk) begin
		if (rst) begin
			f_wait  <= 1'b0;
			f_press <= '0;
		end
		else if (f_req_sync) begin
			f_wait  <= ev_write;
			f_press <= '0;
		end
		else if (ev_write || f_wait) begin
			f_wait  <= 1'b1;
			f_press <= f_press + 1'b1;
		end
	end

	logic [3:0] f_credit = '0;
	always_ff @(posedge clk) begin
		if (rst) f_credit <= '0;
		else     f_credit <= f_credit + (launch ? 4'd1 : 4'd0) - (f_req_sync ? 4'd1 : 4'd0);
	end

	// Witness bookkeeping: a message that served the TE request while the
	// quota level stood at the arm, and a PERIODIC seen AFTER such a
	// collision (the quota was rearmed by the collision message, not lost).
	uwire logic f_collision = f_req_sync && sr_ack && sr_ovf_seen[1];
	logic f_coll_seen = 1'b0;
	always_ff @(posedge clk) begin
		if (rst)               f_coll_seen <= 1'b0;
		else if (f_collision)  f_coll_seen <= 1'b1;
	end

	always @(posedge clk) begin
		if (f_past_valid && !rst) begin
			// A_sync11_prio: when the quota level and a TE request are both
			// standing at the arm on the same qualifying retire, the emitted
			// message is the explicit request -- arm 7 outranks arm 8, and the
			// quota is rearmed by that message instead of emitting a second
			// one. (Before the first sync the startup one-shots legitimately
			// outrank both.)
			assert (!(f_sync_any && sr_started[1] && sr_ovf_seen[1] && sr_tip_pend[1])
			        || f_req_sync);                              // A_sync11_prio
			// The single-source guarantees must survive the other source:
			assert (f_win   <= 16'(F_QUOTA + F_DELTA));          // A_sync11_win
			assert (f_press <= 8'(F_K9));                        // A_sync11_live
			assert (!f_req_sync || (f_credit != 4'd0));          // A_sync11_credit
			// Non-vacuity: the collision really is reachable (and with it the
			// antecedent of A_sync11_prio), and the quota keeps running after
			// it.
			cover (f_collision);                                 // C_coll_on_one_beat
			cover (f_coll_seen && f_periodic);                   // C_coll_quota_alive
		end
	end

endmodule : f_reqcoll

`endif // RED_CLASS9

`default_nettype wire
