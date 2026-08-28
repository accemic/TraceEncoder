// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief   Formal wrapper for ct_L2_msg_gen (P-MSG-1..4, abstracted eTIP).
 *
 * @details
 *   The 1700-line message generator is NOT proven whole; this wrapper
 *   checks the CONSERVATION layer with an abstracted payload (brief §4):
 *   the eTIP item is reduced to {sub_type, do_flush, small token fields},
 *   the CSR feature enables are free-but-stable inputs, and the module's
 *   own translate_off drift-guard assertions ride along as live formal
 *   checks (sv2v ignores synthesis comment pragmas — deliberate here).
 *
 *   Assumption budget (each justified in formal/README.md):
 *     ASM-MSG-1: initial reset in cycle 0.
 *     ASM-MSG-2: CSR fields are stable (quasi-static programming contract).
 *     ASM-MSG-3: FWFT source contract on both input queues — while
 *                valid && !ack the item stays put and valid stays high
 *                (cvs_fifo behaviour; a free-morphing item under an open
 *                multi-cycle drain hold would be un-FIFO-like).
 *     ASM-MSG-4: sub_type is a legal enum value (0..4).
 *
 *   Properties (see formal/README.md):
 *     P-MSG-1 (Klasse-8-Regression, Gate 15 / Fix 8f8e85aa): a composing
 *             consume beat is never clobbered — the cycle after a
 *             non-silent consume, TraceMsg carries the composed message,
 *             never the internal FLUSH marker.
 *     P-MSG-2 (backpressure stability): !ready_in holds TraceMsg
 *             bit-stable.
 *     P-MSG-3 (consume/emission): drain holds emit exactly their drain
 *             message and do NOT consume; a non-silent CF consume
 *             composes in the same beat (TraceMsg is one register, so
 *             "at most one composition per cycle" holds structurally).
 *     P-MSG-4 (flush debt): the latched FlushRequest is never lost — it
 *             persists until the FLUSH marker goes out, and a free
 *             emission slot pays it immediately (safety form of the
 *             brief's bounded-liveness variant, strictly stronger).
 *
 *   RED_CLASS8: -DRED_CLASS8 keeps only the P-MSG-1 sync-consume variant
 *   (a sync-carrying CF consume ALWAYS composes), so the red run against
 *   the pre-fix RTL (335393b6, trailing `if (FlushRequest)`) fails
 *   unambiguously on the flush-clobber property.
 */

`default_nettype none

module f_msg_check (
	input wire logic                                                           clk,
	input wire logic                                                           rst,
	// downstream flow control
	input wire logic                                                           in_ready,
	// abstracted eTIP item
	input wire logic                                                           in_valid,
	input wire ct_pkg::ct_sub_type_e                                           in_sub_type,
	input wire logic                                                           in_do_flush,
	input wire logic [7:0]                                                     in_ts,
	input wire nexus::nexus_sync_reason_e                                      in_sync_reason,
	input wire nexus::nexus_btype_e                                            in_btype,
	input wire nexus::nexus_rcode_e                                            in_rcode,
	input wire tip_pkg::tip_itype_e                                            in_itype,
	input wire tip_pkg::tip_iaddr_t                                            in_iaddr,
	input wire logic [3:0]                                                     in_icnt,
	// next-iaddr sideband
	input wire logic                                                           in_nia_valid,
	input wire tip_pkg::tip_iaddr_t                                            in_nia_addr,
	input wire logic                                                           in_ret_pred,
	// CSR view (free but stable)
	input wire ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e in_mode,
	input wire logic                                                           in_en_wide_icnt,
	input wire logic                                                           in_en_impl_ret,
	input wire logic                                                           in_en_bp,
	input wire logic                                                           in_en_rh,
	input wire logic                                                           in_en_rb,
	input wire logic                                                           in_en_jtc,
	input wire logic                                                           in_en_ibhs,
	input wire logic                                                           in_en_rpt_instr
);
	import ct_pkg::*;
	import ct_etip_pkg::*;
	import tip_pkg::*;
	import nexus::*;
	import nexus_vendor::*;
	import ct_cs_cpuif_pkg::*;

	// ------------------------------------------------------------------
	// Interfaces + DUT
	// ------------------------------------------------------------------
	ct_cs_procclk_if cs ();
	source_if #(.T(etip_msg_struct_t),  .STOP_ON_UNDERRUN(0)) etip_q (.clk(clk), .rst(rst));
	source_if #(.T(etip_next_iaddr_t),  .STOP_ON_UNDERRUN(0)) nia_q  (.clk(clk), .rst(rst));

	// Abstracted eTIP item assembly (payload token fields; the packed
	// union means DF/DAQ/OTHER views reinterpret the same bits — payload
	// content never gates the emission control flow under test).
	etip_cf_msg_struct_t f_cf;
	etip_msg_struct_t    f_etip;
	always_comb begin
		f_cf             = '0;
		f_cf.sync_reason = in_sync_reason;
		f_cf.btype       = in_btype;
		f_cf.rcode       = in_rcode;
		f_cf.itype       = in_itype;
		f_cf.iaddr       = in_iaddr;
		f_cf.icnt        = etip_icnt_t'(in_icnt);
		f_etip           = '0;
		f_etip.sub_type  = in_sub_type;
		f_etip.do_flush  = in_do_flush;
		f_etip.ts        = etip_ts_t'(in_ts);
		f_etip.sub.cf    = f_cf;
	end

	assign etip_q.valid = in_valid;
	assign etip_q.q     = f_etip;
	assign nia_q.valid  = in_nia_valid;
	assign nia_q.q      = '{ret_predicted: in_ret_pred, addr: in_nia_addr};

	assign cs.trTeInstMode               = in_mode;
	assign cs.trTeInstEnWideIcnt         = in_en_wide_icnt;
	assign cs.trTeInstEnImplicitReturn   = in_en_impl_ret;
	assign cs.trTeInstEnBranchPrediction = in_en_bp;
	assign cs.trTeInstEnRepeatedHistory  = in_en_rh;
	assign cs.trTeInstEnRepeatBranch     = in_en_rb;
	assign cs.trTeInstEnJumpTargetCache  = in_en_jtc;
	assign cs.trTeInstEnIbhs             = in_en_ibhs;
	assign cs.trTeInstEnRepeatInstr      = in_en_rpt_instr;

	nexus_msg_struct_t trace_msg;
	wire logic         msg_gen_idle;

	ct_L2_msg_gen dut (
		.proc_clk     (clk),
		.proc_rst     (rst),
		.cs_proc      (cs),
		.etip_q       (etip_q),
		.next_iaddr_q (nia_q),
		.trace_msg    (trace_msg),
		.ready_in     (in_ready),
		.msg_gen_idle (msg_gen_idle)
	);

	// ------------------------------------------------------------------
	// Probes (bind lexically after sv2v inlining)
	// ------------------------------------------------------------------
	wire logic f_consume    = dut.consume_etip;
	wire logic f_flushreq   = dut.FlushRequest;
	wire logic f_jtc_clear  = (dut.JtcValid == '0);
	wire logic f_pred_zero  = (dut.PredCnt == 0);
	// The RTL's drain-hold set, mirrored EXACTLY -- all eight arms of the
	// emission chain that precede `else if (consume_etip)`. A hold missing
	// here does not weaken a check, it makes one WRONG: the wrapper then
	// reads a legitimate drain cycle as a free emission slot (P-MSG-4) and
	// the gate reports an RTL defect that does not exist. That is exactly
	// what happened between 2026-08-12 and 2026-08-24 -- the list was
	// complete when written on 2026-08-02 and silently stopped being so
	// when ee25d098f85 added the eighth arm (cf_sync_icnt_overflow_hold).
	// A_consume_decomposition below turns the next such addition into a
	// NAMED verdict instead of a forensic exercise on a counterexample.
	wire logic f_any_hold   = dut.cf_repeat_branch_drain_hold
	                        || dut.cf_repeat_drain_hold
	                        || dut.cf_rpt_instr_drain_hold
	                        || dut.cf_bp_icnt_drain_hold
	                        || dut.cf_btm_icnt_overflow_hold
	                        || dut.cf_indirect_hist_overflow_hold
	                        || dut.cf_sync_hist_flush_hold
`ifndef RED_CLASS8
	// The eighth arm is referenced ONLY outside the RED_CLASS8 build: the
	// pre-fix revision that build replays (335393b6) has seven arms and no
	// cf_sync_icnt_overflow_hold, and yosys does not error on an upward
	// reference it cannot bind -- it leaves it SILENTLY unbound, reading 0.
	// A naked reference there would quietly weaken that run instead of
	// failing it, which is the worse of the two outcomes.
	// P-MSG-1, the only property in that build, does not use this term.
	                        || dut.cf_sync_icnt_overflow_hold
`endif
	                        ;

	// Mirror of consume_etip's POSITIVE term (this item may be consumed
	// this cycle, holds aside). Because consume_etip is DEFINED as
	// `eligible && !<any hold>`, the term `f_eligible && !f_consume` is
	// the RTL's hold set by algebra -- it needs no enumeration and cannot
	// go stale. A_consume_decomposition compares the two; only that
	// assertion uses this signal, so a wrong mirror here cannot silently
	// weaken any P-MSG property -- it can only fail that assertion.
`ifndef RED_CLASS8
	wire logic f_eligible   = in_ready && etip_q.valid
	                        && ((dut.etip_msg.sub_type == SUB_MSG_NONE)
	                         || (dut.etip_msg.sub_type == SUB_MSG_DF)
	                         || (dut.etip_msg.sub_type == SUB_MSG_DAQ)
	                         || (dut.etip_msg.sub_type == SUB_MSG_OTHER)
	                         || ((dut.etip_msg.sub_type == SUB_MSG_CF)
	                          && (!dut.cf_needs_next_iaddr || nia_q.valid)));
`endif

	// ------------------------------------------------------------------
	// Environment assumptions
	// ------------------------------------------------------------------
	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;

	// ASM-MSG-1
	always_comb if (!f_past_valid) assume (rst);

	// ASM-MSG-4: legal sub_type encoding
	always_comb assume (in_sub_type <= SUB_MSG_OTHER);

	// ASM-MSG-5: composer eTIP contract — the composer only ever puts
	// these rcodes on an eTIP CF item (composer emission sites; a free
	// rcode encoding like 7 routes the consume into arms the drift-guard
	// mirrors legitimately exclude — found via CEX, env artifact).
	always_comb assume ((in_rcode == NEXUS_RCODE_NONE)
	                 || (in_rcode == NEXUS_RCODE_ICNT_OVERFLOW)
	                 || (in_rcode == NEXUS_RCODE_TRACE_DISABLED)
	                 || (in_rcode == NEXUS_RCODE_CORR_DEBUG_ENTRY)
	                 || (in_rcode == NEXUS_RCODE_CORR_LOW_POWER));

	// ASM-MSG-2: quasi-static CSRs
	logic [3:0] p_mode_q;
	logic [7:0] p_en_q;
	always_ff @(posedge clk) begin
		p_mode_q <= 4'(in_mode);
		p_en_q   <= {in_en_wide_icnt, in_en_impl_ret, in_en_bp, in_en_rh,
		             in_en_rb, in_en_jtc, in_en_ibhs, in_en_rpt_instr};
	end
	always_comb if (f_past_valid) begin
		assume (4'(in_mode) == p_mode_q);
		assume ({in_en_wide_icnt, in_en_impl_ret, in_en_bp, in_en_rh,
		         in_en_rb, in_en_jtc, in_en_ibhs, in_en_rpt_instr} == p_en_q);
	end

	// ASM-MSG-3: FWFT source contract (item + valid stable until ack).
	logic       p_pend_etip = 1'b0, p_pend_nia = 1'b0;
	logic       p_nia_valid_q;
	etip_msg_struct_t p_etip_q;
	etip_next_iaddr_t p_nia_q;
	always_ff @(posedge clk) begin
		p_pend_etip <= in_valid && !etip_q.ack && !rst;
		p_pend_nia  <= in_nia_valid && !nia_q.ack && !rst;
		p_etip_q    <= f_etip;
		p_nia_q     <= nia_q.q;
		p_nia_valid_q <= in_nia_valid;
	end
	always_comb if (f_past_valid) begin
		if (p_pend_etip) assume (in_valid && (f_etip == p_etip_q));
		if (p_pend_nia)  assume (in_nia_valid && (nia_q.q == p_nia_q));
	end

	// ------------------------------------------------------------------
	// Helper state (previous = decision cycle)
	// ------------------------------------------------------------------
	logic p_rst_q       = 1'b1;
	logic p_ready_q     = 1'b0;
	logic p_consume_q   = 1'b0; // any consume beat
	logic p_nonother_q  = 1'b0; // ... whose item was not SUB_MSG_OTHER
	logic p_synccf_q    = 1'b0; // sync-carrying CF consume (always composes)
	logic p_df_q        = 1'b0; // DF consume (always composes)
	logic p_daq_q       = 1'b0; // DAQ consume (always composes)
	logic p_hold_q      = 1'b0; // drain hold active (emits, must not consume)
	logic p_flushreq_q  = 1'b0;
	logic p_freeslot_q  = 1'b0; // flush debt + free emission slot
	logic p_debtslot_q  = 1'b0; // flush debt + ready + no consume (NO hold term)
	nexus_msg_struct_t p_msg_q;

	always_ff @(posedge clk) begin
		p_rst_q       <= rst;
		p_ready_q     <= in_ready;
		p_msg_q       <= trace_msg;
		p_consume_q   <= f_consume;
		p_nonother_q  <= f_consume && (in_sub_type != SUB_MSG_OTHER);
		p_synccf_q    <= f_consume && (in_sub_type == SUB_MSG_CF)
		                 && (in_sync_reason != NEXUS_SYNC_NONE);
		p_df_q        <= f_consume && (in_sub_type == SUB_MSG_DF);
		p_daq_q       <= f_consume && (in_sub_type == SUB_MSG_DAQ);
		p_hold_q      <= f_any_hold;
		p_flushreq_q  <= f_flushreq;
		p_freeslot_q  <= f_flushreq && in_ready && !f_consume && !f_any_hold;
		p_debtslot_q  <= f_flushreq && in_ready && !f_consume;
	end

	// ------------------------------------------------------------------
	// Assertions
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (f_past_valid && !p_rst_q && !rst) begin
			// P-MSG-1 — Klasse-8-Regression (red-compatible variant): a
			// sync-carrying CF consume ALWAYS composes; the flush marker
			// must never clobber it in the same beat.
			if (p_synccf_q) begin
				assert (trace_msg.sub_type != SUB_MSG_NONE);          // A_msg1_red_present
				assert (trace_msg.tcode    != NEXUS_MSG_FLUSH);       // A_msg1_red_noclobber
			end

`ifndef RED_CLASS8
			// P-MSG-1 — full form: NO consume beat ever coincides with a
			// flush-marker emission (exactly the else-if fix, without
			// re-deriving the silent-beat classification; OTHER consumes
			// are excluded because a raw eTIP OTHER item may legitimately
			// carry tcode 36 through send_other_msg).
			if (p_nonother_q)
				assert (!((trace_msg.sub_type == SUB_MSG_OTHER)
				       && (trace_msg.tcode == NEXUS_MSG_FLUSH)));     // A_msg1_noclobber
			// ... presence checks for the exactly-classifiable consumes:
			if (p_df_q)
				assert (trace_msg.sub_type == SUB_MSG_DF);            // A_msg1_df_present
			if (p_daq_q)
				assert (trace_msg.sub_type == SUB_MSG_DAQ);           // A_msg1_daq_present

			// P-MSG-2 — backpressure holds TraceMsg bit-stable.
			if (!p_ready_q)
				assert (trace_msg == p_msg_q);                        // A_msg2_stable

			// P-MSG-3 — a drain hold emits its drain message ...
			if (p_hold_q)
				assert (trace_msg.sub_type != SUB_MSG_NONE);          // A_msg3_drain_emits

			// P-MSG-4 — flush debt: persists until paid ...
			if (p_flushreq_q)
				assert (f_flushreq
				     || ((trace_msg.sub_type == SUB_MSG_OTHER)
				      && (trace_msg.tcode == NEXUS_MSG_FLUSH)));      // A_msg4_debt_kept
			// ... and a free emission slot pays it immediately.
			if (p_freeslot_q)
				assert ((trace_msg.sub_type == SUB_MSG_OTHER)
				     && (trace_msg.tcode == NEXUS_MSG_FLUSH));        // A_msg4_slot_pays
			// ... and, free of ANY hold enumeration: with a debt outstanding a
			// ready non-consuming beat never goes out EMPTY -- either a drain
			// arm uses the slot or the marker is paid. Stays sound even if the
			// f_any_hold mirror above ever drifts again (it is the same claim
			// as A_msg4_slot_pays, minus the part that needs the hold set).
			if (p_debtslot_q)
				assert (trace_msg.sub_type != SUB_MSG_NONE);           // A_msg4_no_idle_beat

			// Standing invariants I6/I7 (release hardening 2026-08-01): the RTL
			// carries them as concurrent SVA, which yosys' free frontend
			// cannot parse — re-stated here 1:1 as same-cycle immediate
			// assertions (run.sh strips the SVA blocks from the conversion).
			if ((trace_msg.sub_type == SUB_MSG_CF)
			 && (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_CORRELATION))
				assert (f_jtc_clear && f_pred_zero);                  // A_i6_corr_clears_models
			if ((trace_msg.sub_type == SUB_MSG_CF)
			 && ((trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_SYNC)
			  || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC)
			  || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC)
			  || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC))
			 && (trace_msg.sub.cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN))
				assert (trace_msg.sub.cf.icnt == 0);                  // A_i7_ovf_sync_pure_anchor
`endif
		end
	end

	// P-MSG-3 — ... and never consumes (combinational: holds and ack are
	// mutually exclusive by construction; checked, not trusted).
	always_comb if (f_past_valid && !rst) begin
		assert (!(f_any_hold && etip_q.ack));                         // A_msg3_hold_noconsume
		assert (etip_q.ack == f_consume);                             // A_msg3_ack_is_consume
`ifndef RED_CLASS8
		// Mirror drift guard: the RTL DEFINES consume_etip as
		// `eligible && !<any hold>`, so restating that definition with the
		// wrapper's two mirrors and comparing against the probed signal
		// catches drift in BOTH of them and in both directions -- a hold arm
		// the list lost (eligible, held, but f_any_hold == 0) and an
		// eligibility mirror that is too weak (consumed, but f_eligible == 0).
		// It is also the canary for the hold probes themselves: an upward
		// reference yosys failed to bind reads 0 and shows up right here.
		// Without this, a stale mirror surfaces as a P-MSG-4 counterexample
		// that reads like an RTL defect -- which is what happened between
		// 2026-08-12 and 2026-08-24 (see f_any_hold above).
		assert (f_consume == (f_eligible && !f_any_hold));            // A_consume_decomposition
`endif
	end

`ifndef RED_CLASS8
	// ------------------------------------------------------------------
	// Cover (non-vacuity witnesses)
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (f_past_valid && !p_rst_q && !rst) begin
			cover (p_synccf_q && (trace_msg.sub_type != SUB_MSG_NONE));   // C_sync_composed
			cover ((trace_msg.sub_type == SUB_MSG_OTHER)
			    && (trace_msg.tcode == NEXUS_MSG_FLUSH));                 // C_flush_emitted
			cover (p_flushreq_q && p_synccf_q);                           // C_clobber_collision
			cover (p_hold_q);                                             // C_drain_hold
			cover (!p_ready_q && (p_msg_q.sub_type != SUB_MSG_NONE));     // C_backpressure_hold
			cover (f_flushreq && f_consume);                              // C_debt_during_consume
			// Non-vacuity of A_msg4_slot_pays itself: the free-slot antecedent
			// must be REACHABLE, or completing the hold mirror above would have
			// bought a green run by emptying the property.
			cover (p_freeslot_q);                                         // C_freeslot_reached
			// The 2026-08-24 counterexample, now as a WITNESS of legitimate
			// behaviour: a debt beat whose emission slot a drain arm took.
			// This is the state the stale hold mirror mislabelled as free.
			cover (p_debtslot_q && !p_freeslot_q
			    && (trace_msg.sub_type != SUB_MSG_NONE));                 // C_debt_slot_drained
		end
	end
`endif

endmodule : f_msg_check

`default_nettype wire
