// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder layer 2/3 eTIP composer.
 *
 * @details
 *   Composes the control-flow (CF), data-flow (DF) and data-acquisition (DAQ)
 *   eTIP messages and serializes the parallel message inputs into one stream,
 *   with CDC into the proc_clk domain. Also drives the flush path: an ATB flush
 *   (or trace-off) raises do_flush, which is emitted as a standalone flush eTIP
 *   even when the core is idle (no new tip.iretire).
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import nexus::*;
import nexus_vendor::*;
import tip_pkg::*;
import ct_pkg::*;
import ct_cs_cpuif_pkg::*;
import ct_cs_cpuif_types_pkg::*;
import ct_etip_pkg::*;

module ct_L23_preproc_composer_etip #(
	// When 1: STOREs use tip.sdata; LOADs emit DF at lresp using tip.ldata + saved daddr/dsize.
	// When 0: both use tip.data at dretire time (legacy dretire-combined mode).
	bit SPLIT_DATA_ACCESS = 0
) (
	input uwire logic        clk,      // trace input clock
	input uwire logic        rst,      // reset
	input uwire tip_time_t   ts_value, // selected timestamp from timestamp unit
	ct_act_cap_if.slave      act_cap_st,
	tip_if.slave             tip,
	// Effective instruction-tracing level (Enable && InstTracing), aligned by
	// the integrating module (ct_L23_preproc) to this module's beat latency.
	// This module consumes DELAYED tip beats, so a level sampled live would
	// cut pause edges up to max_delay beats too early or too late.
	input uwire logic        inst_trace_active_q,
	input uwire logic        atb_afvalid,
	ct_sync_if.slave         sync,
	ct_hit_if.slave_region   cf_qualifier,
	ct_hit_if.slave          df_qualifier,
	ct_perfcnt_if.slave_etip perfcnt,
	source_if.impl           etip_q,
	source_if.impl           next_iaddr_q,
	ct_cs_tipclk_if.slave    cs_tip,   // TIP FIFO status/clear (tip_clk side of CSR bundle)
	output delay_t           internal_delay
);
	// NOTE (P2.2/D10): the former TraceMsgCount/synq_req_trace_msg_count
	// pair was REMOVED, not rewired: it counted eTIP slots, not on-wire
	// messages -- the wrong truth at the wrong place. The on-wire message
	// quota is counted in the L2 egress modules (see ct_L2_*_formatter/
	// packer/packetizer genQuotaCnt).

	// ----------------------------------------------------------------
	// Profile guard: the Watchpoint message (P4) takes its hit bitmap from
	// the ACT-ST command path, so it is meaningless without the ACT blocks
	// (same elaboration-$fatal pattern as the compact packer's CF-only
	// guard and the formatter's DF-compression guard).
	// ----------------------------------------------------------------
	if (CT_EN_WATCHPOINT_MSG && !CT_EN_ACT) begin : genWatchpointNeedsAct
		$fatal(1, "ct_L23_preproc_composer_etip: CT_EN_WATCHPOINT_MSG requires CT_EN_ACT (WPHIT comes from the ACT-ST command path)");
	end
	// P7: the data-trace drop policy suppresses DF eTIP arms -- meaningless
	// (and structurally dead) without the data-trace feature group.
	if (CT_EN_DF_DROP && !CT_EN_DATA_TRACE) begin : genDfDropNeedsDataTrace
		$fatal(1, "ct_L23_preproc_composer_etip: CT_EN_DF_DROP requires CT_EN_DATA_TRACE (there is no data trace to drop)");
	end

	// Registered state (initial values match reset values; 'x where no reset)
	// Parallel eTIP slot count / id widths follow the profile-dependent
	// ETIP_PAR_MSG (3 with data-trace/DAQ/ACT, 2 for control-flow only).
	localparam int unsigned MSGID_W = $clog2(ETIP_PAR_MSG + 1);
	etip_msg_struct_t[ETIP_PAR_MSG-1:0] EtipMsg      = 'x;
	// Cumulated halfword count between CF eTIPs: the ICNT pre-drain caps it
	// at the wide cap 2**16 (plus one instruction of slack) -- 18 bits hold
	// it (was 32, resource pass 3; mirrors msg_gen's ICNT_ACC_W).
	logic [17:0]                ICntCum              = 0;
	logic [MSGID_W-1:0]         MsgId                = 0;
	logic                       PendingCfNextIaddr   = 0;
	etip_next_iaddr_t           NextIaddr            = 'x;
	logic                       NextIaddrWr          = 0;
	// Implicit-return prediction of the CF event awaiting its next_iaddr
	// capture (valid together with PendingCfNextIaddr when that event was
	// a RETURN with a stack prediction).
	logic                       PendingRetPred       = 0;
	tip_iaddr_t                 PendingRetTarget     = '0;
	// Implicit-return return-address stack (Accemic): pushed on calls, popped on
	// returns. The popped value is the predicted return target handed to msg_gen,
	// which suppresses the return's indirect-branch message when it matches the
	// actual next iaddr (feature gated there by trTeInstEnImplicitReturn). Always
	// maintained (harmless when the feature is off). Depth = RET_STACK_DEPTH
	// (ct_pkg SSOT -- also advertised in config-message P3, C2).
	localparam int              RET_STACK_DEPTH      = ct_pkg::CT_RET_STACK_DEPTH;
	localparam tip_iaddr_t      RET_SENTINEL         = '1;  // all-ones: never a real target
	tip_iaddr_t [RET_STACK_DEPTH-1:0] RetStack       = '0;
	logic [$clog2(RET_STACK_DEPTH):0] RetSp          = '0;  // next free slot; 0 = empty
	tip_iaddr_t                 PrevIAddr            = '0;
	// Size of the last retired instruction. Used to compute the address of
	// the next instruction (PrevIAddr + (1 << PrevIlastsize)) for the
	// FIFO_OVERRUN injected sync — see ovf_inject_msg1 below. Tracking it
	// here rather than re-reading tip.ilastsize keeps the value defined
	// during arbitrary periods of iretire=0 (when the spec leaves
	// tip.ilastsize undefined).
	tip_ilastsize_t             PrevIlastsize        = '0;
	// Block ingress only (R1.3): the statically next PC after the last
	// retiring BEAT. `PrevIAddr + (2 << PrevIlastsize)` computes that for a
	// single retirement, but a block starts at PrevIAddr and ends
	// 2*iretire bytes later, so the sum of the two registers is the wrong
	// address by everything but the last instruction. Written only when
	// CT_EN_BLOCK_TIP is set and read only there -- with the switch off it
	// has neither driver nor reader and disappears in synthesis.
	tip_iaddr_t                 PrevIAddrAfter       = '0;
	// 1 iff the most recent retired instruction CHANGED control flow. While
	// set, `PrevIAddr + size` does NOT name the next retire address (the CPU
	// continued at the branch/jump target, which the encoder only learns on
	// the next retire) — the FIFO_OVERRUN resync marker must not anchor
	// there. Feeds the ovf_injector's inject_hold.
	logic                       PrevRetireWasCf      = 1'b0;
	// 1 iff a trap redirect (EXCEPTION_TRAP/INTERRUPT marker beat) happened
	// since the last RETIRE. The static successor `PrevIAddr + size` then
	// names an address that is NEVER executed: the trapping instruction does
	// not retire and execution continues in the handler. This is the third
	// case of the same anchor assumption, after CF and NOT_TAKEN_BRANCH -- a
	// soak run anchored recovery at FADDR = the ecall itself, so the decoder
	// anchored on never-executed code and derailed. Cleared by the next real
	// retire (handler entry), from which point PrevIAddr+size is valid
	// again.
	logic                       PrevEventWasTrap     = 1'b0;
	tip_iaddr_t                 LastIAddrBeforeException = '0;
	tip_daddr_t                 PrevDAddr            = '0;
	tip_data_t                  PrevData             = '0;
	tip_dtype_dsize_t           PrevDtypeDsize       = '0;
	// split-load state: load address captured at dretire; data arrives separately at lresp
	tip_daddr_t                 PendingSplitLoadDaddr = '0;
	tip_dsize_t                 PendingSplitLoadDsize = '0;

	// Combinational next-state
	etip_msg_struct_t[ETIP_PAR_MSG-1:0] etip_msg_next;
	logic [17:0]                icnt_cum_next;
	// Sized from the number of ALLOCATION SITES, not from ETIP_PAR_MSG: the
	// counter must be able to represent a bound VIOLATION, otherwise it
	// wraps and a_p4_slot_bound below silently passes on the very beats it
	// exists for. (P4 re-audit B-1: with ETIP_PAR_MSG = 6 the old width
	// $clog2(ETIP_PAR_MSG+2) = 3 bits covered 0..7 while the profile has
	// nine simultaneously enabled sites.)
	logic [$clog2(ETIP_SLOT_SITES+1)-1:0] msg_id_next;
	logic                       pending_cf_next_iaddr_next;
	logic                       next_iaddr_wr_next;
	etip_next_iaddr_t           next_iaddr_val;
	logic                       pending_ret_pred_next;
	tip_iaddr_t                 pending_ret_target_next;
	tip_iaddr_t [RET_STACK_DEPTH-1:0] ret_stack_next;
	logic [$clog2(RET_STACK_DEPTH):0] ret_sp_next;
	logic                       do_flush_ack_next;
	logic                       etip_ovf_drop_now;
	logic                       sideband_ovf_drop;
	tip_data_t                  mask;
	// ----------------------------------------------------------------
	// Data-trace drop policy (P7, trTeDataControl.DataDropEna). While armed,
	// the DF eTIP arms are suppressed BEFORE the queue runs full, so the
	// remaining capacity stays with the instruction trace. State:
	//   DfDropArm     : registered watermark verdict (policy armed AND the
	//                   eTIP CVS fill has reached CT_DF_DROP_WATERMARK).
	//                   Registered on purpose -- the fill comes out of the
	//                   FIFO whose write enable this signal influences, so a
	//                   combinational path would close a loop.
	//   DfDropEpisode : one marker + one status event per drop EPISODE
	//                   (rearmed when the fill falls back below the mark).
	// The comb signals are driven in the main always_comb below.
	logic                       DfDropArm     = 1'b0;
	logic                       DfDropEpisode = 1'b0;
	logic                       df_drop_now;      // a DF slot was suppressed this beat
	logic                       df_drop_mark_now; // ... and it is the episode's FIRST
	function automatic tip_xaddr_data_t pack_daq_context_direct(
		input tip_dtype_dsize_t dtype_dsize,
		input logic [23:0] direct_data
	);
		pack_daq_context_direct =
			tip_xaddr_data_t'({{(TIP_XADDR_DATA_WIDTH-24-$bits(tip_dtype_dsize_t)){1'b0}}, direct_data, dtype_dsize});
	endfunction

	// Width adapter for DAQ eTIP payload elements: with the ACT/DAQ groups
	// compiled out the element narrows to 1 bit (profile-slimmed union) --
	// the explicit truncation keeps the dead arm lint-clean.
	function automatic logic [ETIP_DAQ_ELEM_W-1:0] daq_elem(input tip_xaddr_data_t v);
		return ETIP_DAQ_ELEM_W'(v);
	endfunction

	// process ATB flush request (atb_afvalid)
	logic                       DoFlushAck = 0;
	uwire                       do_flush;
	uwire                       do_flush_atb;
	logic                       DoFlushEnableFall      = 1'b0;
	logic                       DoCorrDisable          = 1'b0;
	// W2 -- CF-filter anchoring. DoCorrFilterExit is a SECOND source of the
	// SAME correlation slot as DoCorrDisable (not a second slot: the
	// emission site below tests the OR), so the proven ETIP_PAR_MSG bound is
	// untouched -- the formal environment already lets that slot fire on any
	// beat. FiltSyncPend/FiltSyncHeld carry a sync verdict that landed on a
	// beat the filter rejected, so it is not lost.
	logic                       DoCorrFilterExit       = 1'b0;
	logic                       FiltSyncPend           = 1'b0;
	nexus_sync_reason_e         FiltSyncHeld           = NEXUS_SYNC_NONE;
	logic                       PrevTrTeEnable         = 1'b0;
	logic                       PrevInstTraceActive    = 1'b0;
	// Debug-/low-power-entry edge trackers (B1): the correlation markers
	// fire on the rising edge of the ALIGNED tip.debug_mode / tip.power_down
	// levels (this module consumes the delayed tip).
	logic                       PrevDbgMode            = 1'b0;
	logic                       PrevPwrDown            = 1'b0;
	// Ownership (B6): privilege level of the last qualified retire.
	tip_priv_t                  PrevPrivQ              = 3'd3;
	uwire                       etip_ovf_dropping;
	uwire                       etip_ovf_inject_done;
	// Serialize arrangement only (parallel ties 0): a drop happened and the
	// ERROR + FIFO_OVERFLOW marker pair is still owed — asserted from the
	// drop event until the injector accepts the (skid-drained) force_inject.
	// While set, every new beat keeps dropping (same overflow episode, same
	// ERROR covers it) so the marker pair lands in STREAM ORDER behind all
	// previously accepted messages (natural-overflow fix 2026-07-22, see
	// tests/overflow/02_natural_overflow).
	uwire                       etip_ovf_pending;

	// ----------------------------------------------------------------
	// Block ingress (R1.3, ct_pkg::CT_EN_BLOCK_TIP) -- derived ONCE here,
	// so no arm of this module re-derives the SR-vs-block rule. With the
	// switch at 0 all three fold to the historical expression at
	// elaboration (localparam), so an OFF build contains no block logic
	// (measured OFF-vs-pre-R1.3 delta +16 LUTs / -8 FFs, restructuring
	// noise -- see the note at ct_pkg::CT_EN_BLOCK_TIP).
	//
	//   tip_retires     |iretire                       (was: iretire)
	//   beat_halfwords  halfwords this beat represents (was: 1 << ilastsize)
	//   iaddr_last      SOURCE PC of the beat's control-flow event, i.e.
	//                   the LAST instruction of the block (was: tip.iaddr)
	//   iaddr_after     statically next PC after the block (was:
	//                   tip.iaddr + (2 << ilastsize))
	//
	// tip.iaddr itself keeps its meaning wherever the code means "where the
	// hart is NOW" -- the target capture for a pending CF, the return
	// prediction compare, the pre-drain/SEQ_SYNC FADDR. Those are the FIRST
	// instruction of the block, which is exactly what tip.iaddr is.
	// ----------------------------------------------------------------
	uwire logic      tip_retires    = TipBeatRetires(tip.iretire);
	uwire tip_icnt_t beat_halfwords = TipBeatHalfwords(tip.iretire, tip.ilastsize);
	uwire tip_iaddr_t iaddr_last    = TipLastIaddr(tip.iaddr, tip.iretire, tip.ilastsize);
	uwire tip_iaddr_t iaddr_after   = TipBlockNextIaddr(tip.iaddr, tip.iretire, tip.ilastsize);

	// Instruction tracing is effectively active only while the encoder is
	// enabled AND instruction tracing is selected. Setting trTeEnable=0
	// therefore implicitly disables instruction tracing (and data tracing).
	//
	// ALIGNED, not live: this module consumes the DELAYED tip beats, so the
	// qualification level arrives pipeline-aligned from the integrating
	// module (inst_trace_active_q). Sampling it live
	// (cs_tip.trTeEnable && cs_tip.trTeInstTracing) loses up to max_delay
	// already retired instructions at the off edge, and processes up to
	// max_delay instructions retired while paused out of the delay pipe at
	// the on edge. Observed on a KV260 capture as five VendorBP messages with
	// BCNT=0 between the correlation message and the TRACE_ENABLE sync, the
	// sync carrying ICNT=24.
	uwire inst_trace_active = inst_trace_active_q;

	// W2: is a CF filter actually SELECTING? trTeInstFilters = 0 means
	// "trace all" (comp_filters.sv: mask 0 -> unconditional hit), i.e. the
	// region signals are meaningless and the whole anchoring block below must
	// stay dead -- that is what makes every pre-W2 stream byte-identical by
	// CONSTRUCTION. Compiled out with CT_EN_FILTER_SYNC, and structurally
	// dead without CT_EN_FILTERS (the qualifier stub is constant-pass, so
	// region_entered/_exited never fire anyway -- the term is there so a
	// reader does not have to derive that).
	uwire filt_anchor = CT_EN_FILTER_SYNC && CT_EN_FILTERS
	                 && (cs_tip.trTeInstFilters != '0);

	// The retire arm of process_now, visible outside the always_comb that
	// declares it (the trap arm is deliberately NOT part of it: a trap
	// bypasses the filter and carries its own anchor).
	uwire filt_beat_processed = inst_trace_active
	                         && !(CT_EN_DEBUG_EVENTS && tip.debug_mode)
	                         && tip_retires
	                         && cf_qualifier.hit_valid && cf_qualifier.hit;

	// Resume gate: between the (aligned) re-enable edge and the sync anchor
	// beat, NO beats are processed. The sync generator works on the live side
	// and may, through sync_anchor_ok, only anchor a few retires after the
	// edge (branches are deferred in BP mode). Without this gate the
	// pre-anchor retires enter the stream as ordinary CF events, at a
	// position the decoder does not know, and their branch outcomes shift
	// PredCnt / JTC / HIST against the decoder's model -- the same
	// BCNT off-by-N failure the pause/resume regression gates cover. With the
	// gate, the EXCLUSIVE sync arm below carries ICNT=0 by itself, making it
	// a pure re-anchor.
	logic ResumeHold = 1'b0;

	signal_ack_lock_fsm #(.DO_CDC(1))
	atb_afvalid_ack_lock_fsm (
		.clk,
		.rst,
		.in(atb_afvalid),
		.ack(DoFlushAck),
		.out(do_flush_atb)
	);

	// ----------------------------------------------------------------
	// Trace-off detection
	// ----------------------------------------------------------------
	// Two distinct events, both latched as sticky one-shots cleared by
	// DoFlushAck (so a single edge produces exactly one event):
	//
	//   DoFlushEnableFall : trTeControl.Enable 1->0. Per the RDL,
	//       Enable=0 "flushes any queued trace data to the sink"; it does
	//       nothing more than flush (instruction/data tracing are gated off
	//       implicitly via inst_trace_active / DataTracing).
	//
	//   DoCorrDisable      : instruction tracing turned OFF, i.e. the
	//       falling edge of inst_trace_active (= Enable && InstTracing).
	//       This is what should produce the Program Trace Correlation
	//       Message (TCODE 33, EVCODE=Program Trace Disabled) carrying the
	//       residual ICNT/HIST. It fires both when InstTracing is cleared
	//       directly (Enable still 1) and when Enable=0 implicitly disables
	//       instruction tracing.
	always_ff @(posedge clk) begin
		if (rst) begin
			PrevTrTeEnable        <= 1'b0;
			PrevInstTraceActive   <= 1'b0;
			DoFlushEnableFall  <= 1'b0;
			DoCorrDisable       <= 1'b0;
			DoCorrFilterExit    <= 1'b0;
			FiltSyncPend        <= 1'b0;
			FiltSyncHeld        <= NEXUS_SYNC_NONE;
			PrevDbgMode         <= 1'b0;
			PrevPwrDown         <= 1'b0;
		end else begin
			PrevTrTeEnable      <= cs_tip.trTeEnable;
			PrevInstTraceActive <= inst_trace_active;
			PrevDbgMode         <= CT_EN_DEBUG_EVENTS ? tip.debug_mode : 1'b0;
			PrevPwrDown         <= CT_EN_POWER_EVENTS ? tip.power_down : 1'b0;
			if (CT_EN_OWNERSHIP && inst_trace_active && tip_retires)
				PrevPrivQ <= tip.priv;
			if (PrevTrTeEnable && !cs_tip.trTeEnable) begin
				DoFlushEnableFall <= 1'b1;
			end else if (DoFlushAck) begin
				DoFlushEnableFall <= 1'b0;
			end
			if (PrevInstTraceActive && !inst_trace_active) begin
				DoCorrDisable <= 1'b1;
			end else if (DoFlushAck) begin
				DoCorrDisable <= 1'b0;
			end
			// W2: leaving the CF filter region is the same event class as
			// instruction tracing being switched off -- everything after it is
			// invisible to the decoder until the next anchor. Same one-shot,
			// same slot, same acknowledge.
			if (filt_anchor && inst_trace_active
			    && cf_qualifier.hit_valid && cf_qualifier.region_exited) begin
				DoCorrFilterExit <= 1'b1;
			end else if (DoFlushAck) begin
				DoCorrFilterExit <= 1'b0;
			end
			// W2: a sync verdict on a beat the filter rejects has no CF slot
			// to ride on and would be lost. Hold it for the next processed
			// beat. Cleared only when a beat is REALLY processed -- clearing
			// on the qualifier alone would drop the held anchor on a beat that
			// process_now rejects for another reason (debug suppression), and
			// the stream would be short exactly one re-anchor with no trace of
			// why. `filt_beat_processed` is the part of process_now this block
			// can see; resume_suppress is deliberately not mirrored, because
			// it is released by the very condition that sets this hold
			// (sync.reason != NONE clears ResumeHold in the same cycle).
			if (filt_anchor && (sync.reason != NEXUS_SYNC_NONE)
			    && !filt_beat_processed) begin
				FiltSyncPend <= 1'b1;
				FiltSyncHeld <= sync.reason;
			end else if (filt_beat_processed) begin
				FiltSyncPend <= 1'b0;
			end
			// Resume gate: set on the (aligned) re-enable edge, released by
			// the sync anchor beat -- sync.reason arrives delay-balanced WITH
			// that beat. Release wins on coincidence: the anchor beat is
			// processed and ends the hold in the same cycle.
			if (sync.reason != NEXUS_SYNC_NONE) begin
				ResumeHold <= 1'b0;
			end else if (inst_trace_active && !PrevInstTraceActive) begin
				ResumeHold <= 1'b1;
			end
		end
	end

	// A trace-off correlation message must itself be pushed out, so the
	// instruction-disable event also requests a flush.
	assign do_flush = do_flush_atb || DoFlushEnableFall || DoCorrDisable || DoCorrFilterExit;

	// ----------------------------------------------------------------
	// Combinational next-state logic
	// ----------------------------------------------------------------
	always_comb begin
		// Defaults: clear message slots, retain sub fields
		for (int i = 0; i < ETIP_PAR_MSG; i++) begin
			etip_msg_next[i]          = EtipMsg[i];
			etip_msg_next[i].sub_type = SUB_MSG_NONE;
			etip_msg_next[i].do_flush = 0;
			etip_msg_next[i].ts       = etip_ts_t'(ts_value);
		end

		next_iaddr_wr_next              = 0;
		next_iaddr_val                  = NextIaddr;
		icnt_cum_next                   = ICntCum;
		msg_id_next                     = 0;
		pending_cf_next_iaddr_next      = PendingCfNextIaddr;
		pending_ret_pred_next           = PendingRetPred;
		pending_ret_target_next         = PendingRetTarget;
		ret_stack_next                  = RetStack;
		ret_sp_next                     = RetSp;
		etip_ovf_drop_now               = 0;
		do_flush_ack_next               = DoFlushAck;
		mask                            = '0;
		df_drop_now                     = 0;
		df_drop_mark_now                = 0;

		if (!rst) begin

			// Trap-event marker (INTERRUPT or EXCEPTION_TRAP) can arrive on
			// a tip beat with iretire=0 -- no instruction commits when the
			// trap is taken, but the encoder must still emit a CF eTIP so
			// the decoder gets an IBH (BTYPE=INTERRUPT/EXCEPTION) with the
			// trap-target UADDR. Without this, the next CF event (typically
			// the trap-handler's mret) carries the full handler body in its
			// ICNT and the decoder loses synchronisation.
			//
			// This is explicitly sanctioned by the RISC-V E-Trace ingress
			// port spec (https://docs.riscv.org/reference/e-trace/v2.0/ingressPort.html,
			// riscv-trace-spec/ingressPort.adoc @ f185ac28d71f48cc):
			//   "Note if itype is 1 or 2 (indicating an exception or an
			//    interrupt), the number of instructions retired may be
			//    zero."
			// and conversely
			//   "If iretire=0 and itype=0, the values of all other signals
			//    are undefined."
			// i.e. an iretire=0 beat is meaningful exactly when itype is
			// EXCEPTION_TRAP (1) or INTERRUPT (2); for any other itype we
			// must still gate on iretire.
			//
			// The cf_qualifier qualifier chain (preproc_cf + comp_filters)
			// only fires on tip.iretire=1, so we bypass it for trap events
			// -- trap delivery is privileged and is always traced regardless
			// of the user's CF filter selection.
			// Debug-mode suppression (B1, "no trace in debug"): while the
			// aligned tip.debug_mode level is 1, NO trace is generated or
			// counted -- CF events, traps, halfword counting and the DF/DAQ
			// arms are all gated off. The port contract (tip_if.sv) puts the
			// level's rise after the last pre-debug retire and its fall
			// before the first post-debug retire, so no retired instruction
			// is lost at the window edges. Compile-time gated.
			automatic logic dbg_suppress =
				CT_EN_DEBUG_EVENTS && tip.debug_mode;
			automatic logic is_trap_event =
				!dbg_suppress &&
				((tip.itype == EXCEPTION_TRAP) || (tip.itype == INTERRUPT));
			// Instruction tracing must be effectively active (Enable &&
			// InstTracing) to generate any instruction-trace message or
			// accumulate ICNT. While paused (InstTracing=0 with Enable still
			// high, or Enable=0) the encoder emits nothing and counts nothing;
			// the trace-off correlation message (DoCorrDisable path below)
			// has already carried the residual, and on resume a TRACE_ENABLE
			// sync re-anchors the decoder. Traps during a pause are not traced
			// either.
			// Resume gate: while ResumeHold is set, only beats carrying a
			// sync verdict are processed -- that is, the anchor itself. Every
			// retire between the re-enable edge and the anchor has no
			// position the decoder can place, so it must neither count nor
			// touch PredCnt / JTC / HIST / RetStack. The edge itself is taken
			// into account combinationally, because the register only becomes
			// visible in the following cycle and a non-anchor beat in the edge
			// cycle must not slip through.
			automatic logic resume_hold_now =
				ResumeHold || (inst_trace_active && !PrevInstTraceActive);
			automatic logic resume_suppress =
				resume_hold_now && (sync.reason == NEXUS_SYNC_NONE);
			automatic logic process_now =
				inst_trace_active && !dbg_suppress && !resume_suppress
				&& ( (tip_retires && cf_qualifier.hit_valid && cf_qualifier.hit)
				     || is_trap_event );
			// See the comment block below at the icnt accumulation.
			// Accemic MBV 1:1-fix (2026-07-18): count ONLY retired instructions (iretire=1).
			// The faulting instruction of a synchronous exception has iretire=0 per the RISC-V
			// trace ingress rule (report §5, "faulting instruction retires normally NOT";
			// ECALL/EBREAK -> iretire=0), so it must NOT increment ICNT. The previous
			// `|| itype==EXCEPTION_TRAP` special case walked the faulting PC into the
			// reconstructed sequence (convention A); dropping it makes the decoded iaddr
			// stream == the TIP iretire=1 stream, which is what the ingress rule prescribes.
			// (INTERRUPT was already excluded here, hence interrupts already matched.)
			automatic logic count_halfwords =
				inst_trace_active && !dbg_suppress && !resume_suppress && tip_retires;

			// ACT-CAP CF_SYNC: a CSR-driven request for an instruction
			// synchronization message (Nexus only). It rides on the
			// retiring `csrw 0x0B10` (itype=OTHER) and is turned into a
			// sync exactly like a periodic sync landing on a non-CF
			// instruction. On-wire reason = NEXUS_SYNC_REQ (vendor code 14,
			// the single "explicit sync request" code -- N-Trace 1.0 keeps
			// 12/13 reserved for future standard use; the request source is
			// recorded in te.trTeSyncStatus.SyncReqSource, see
			// ct_L23_preproc). When a real sync reason is already present on
			// this beat, it takes precedence (a sync is emitted either way).
			// The DAQ block below suppresses the DAQ message for this
			// command.
			automatic logic act_cf_sync =
				act_cap_st.valid
				&& (  (act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS)
				    ||(act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS))
				&& (act_cap_st.cmd.Cmd.value == ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC);
			// W2 -- the CF filter needs its own anchoring. Two holes, both
			// measured on the cv64a6 two-process workload
			// (sim/cva6_rv64/run_cva6_ctx_e2e.ps1):
			//
			//  (a) A sync verdict is anchored on any RETIRE
			//      (ct_L23_preproc_sync.sv, sync_anchor_ok = tip.iretire),
			//      but the CF slot that would carry it only exists inside
			//      `if (process_now)`. If the anchor retire is one the
			//      filter rejects, the sync is DROPPED. Measured: with a
			//      context filter the stream contained NOT ONE
			//      ProgTraceSync -- not even the trace-enable anchor -- and
			//      NexRv decoded 0 of 218 instructions.
			//  (b) Coming back into the filter region, the decoder still
			//      sits where it was before the gap. Without a re-anchor it
			//      walks the next ICNT from a position that has nothing to
			//      do with the resumed code.
			//
			// (a) is fixed by HOLDING a dropped verdict (FiltSyncPend) until
			// the next processed beat, (b) by turning the region entry into
			// a TRACE_ENABLE sync -- the same on-wire code the trace-on edge
			// uses, so no decoder learns a new message. Region EXIT emits the
			// Program Trace Correlation of the trace-off path (see the
			// DoCorrFilterExit one-shot), which carries the residual ICNT out
			// and lets both sides drop their call stacks together.
			//
			// Gated by `filt_anchor` = the filter selection is non-empty.
			// With trTeInstFilters = 0 ("trace all", the reset value) the
			// whole block is dead, so every existing stream is byte-identical
			// by construction, not by measurement luck.
			automatic logic filt_region_entry =
				filt_anchor && cf_qualifier.hit_valid && cf_qualifier.region_entered;
			automatic nexus_sync_reason_e eff_sync_reason =
				(sync.reason != NEXUS_SYNC_NONE) ? sync.reason
				: (FiltSyncPend ? FiltSyncHeld
				: (filt_region_entry ? NEXUS_SYNC_TRACE_ENABLE
				: (act_cf_sync ? NEXUS_SYNC_REQ : NEXUS_SYNC_NONE)));

			// Device ID message (TCODE 1, P4).
			// Emitted as the very FIRST slot of the beat -- BEFORE the
			// config slot below, so the on-wire order is
			//   Device ID -> Config -> first synchronizing message
			// (contract DO-1; asserted by a_p4_devid_before_cfg). Mode
			// DID_ONCE fires on the trace-start edge (rising effective
			// instruction tracing), exactly like SendConfig=CFG_ONCE; there
			// is no ON_SYNC variant (the ID is static, and a stock Nexus
			// decoder needs it once per session).
			// Like the config message the PAYLOAD is not carried in the
			// eTIP: the ID is an elaboration parameter, sampled by the
			// formatter/packer at emission time (CT_DEVICE_ID). The slot
			// transports only the trigger; ETIP_PAR_MSG carries the +1.
			begin
				automatic logic send_devid_now = CT_EN_DEVICE_ID
					&& (cs_tip.trTeSendDeviceId
					    == ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e__DID_ONCE)
					&& inst_trace_active && !PrevInstTraceActive;
				if (send_devid_now) begin
					etip_msg_next[msg_id_next].sub_type      = SUB_MSG_OTHER;
					etip_msg_next[msg_id_next].sub.other.tcode   = NEXUS_MSG_DEVICE_ID;
					etip_msg_next[msg_id_next].sub.other.etype   = nexus_etype_e'(0);
					etip_msg_next[msg_id_next].sub.other.ecode   = '0;
					etip_msg_next[msg_id_next].sub.other.payload = '0;
					msg_id_next = msg_id_next + 1;
				end
			end

			// Config message (TCODE 58).
			// Stateless emission as the first slot of the beat after the
			// optional Device ID slot above, so the stream order "config
			// before the synchronizing message" holds even when a retire
			// lands on the very same beat:
			//   CFG_ONCE   : on the trace-start edge (rising effective
			//                instruction tracing). The first sync arises no
			//                earlier than this beat's retire -> config
			//                precedes the first sync on-wire.
			//   CFG_ON_SYNC: on EVERY beat that emits a synchronizing CF
			//                (covers the start implicitly via the first
			//                TRACE_ENABLE/EXIT_RESET sync -- no separate
			//                edge shot, no double config at start). A decoder
			//                attaching mid-stream finds a config immediately
			//                before each re-anchor point.
			// The payload is NOT carried in the eTIP (it would widen the CDC
			// FIFO): the slot transports only the trigger; the formatter/
			// packer sample CAPS/ENAB/P0..P3 from cs_proc at emission time.
			// ETIP_PAR_MSG carries the +1 for this slot.
			begin
				automatic logic send_cfg_now = CT_EN_CONFIG_MSG && (
					   ( (cs_tip.trTeSendConfig == ct_cs_cpuif__te__trTeControl__trTeSendConfigMode_e__CFG_ONCE)
					     && inst_trace_active && !PrevInstTraceActive )
					|| ( (cs_tip.trTeSendConfig == ct_cs_cpuif__te__trTeControl__trTeSendConfigMode_e__CFG_ON_SYNC)
					     && process_now && (eff_sync_reason != NEXUS_SYNC_NONE) ));
				if (send_cfg_now) begin
					etip_msg_next[msg_id_next].sub_type      = SUB_MSG_OTHER;
					etip_msg_next[msg_id_next].sub.other.tcode   = NEXUS_MSG_VENDOR_CONFIG;
					etip_msg_next[msg_id_next].sub.other.etype   = nexus_etype_e'(0);
					etip_msg_next[msg_id_next].sub.other.ecode   = '0;
					etip_msg_next[msg_id_next].sub.other.payload = '0;
					msg_id_next = msg_id_next + 1;
				end
			end

			// Debug-/low-power-entry correlation markers (B1). On the rising
			// edge of the aligned level (while tracing is active) a marker
			// eTIP carries the residual halfword count to msg_gen, which
			// turns it into a Program Trace Correlation Message with
			// EVCODE=0 (debug, N-Trace Required) resp. EVCODE=1 (low-power)
			// and clears its accumulators -- same contract as the trace-off
			// marker. The entry beat itself carries no CF slots (the port
			// contract puts the level's rise after the last pre-debug
			// retire, and dbg_suppress gates process_now), so the marker is
			// the beat's only slot and the ETIP_PAR_MSG bound is unchanged.
			// Low-power entry: retires are not expected while powered down,
			// so no extra suppression is needed beyond the marker.
			begin
				automatic logic dbg_entry = CT_EN_DEBUG_EVENTS && inst_trace_active
					&& tip.debug_mode && !PrevDbgMode;
				automatic logic pwr_entry = CT_EN_POWER_EVENTS && inst_trace_active
					&& tip.power_down && !PrevPwrDown && !dbg_suppress;
				if (dbg_entry || pwr_entry) begin
					etip_msg_next[msg_id_next].sub_type           = SUB_MSG_CF;
					etip_msg_next[msg_id_next].sub.cf.sync_reason = NEXUS_SYNC_NONE;
					etip_msg_next[msg_id_next].sub.cf.btype       = NEXUS_BTYPE_IBRANCH;
					etip_msg_next[msg_id_next].sub.cf.itype       = OTHER;
					etip_msg_next[msg_id_next].sub.cf.iaddr       = tip.iaddr;
					etip_msg_next[msg_id_next].sub.cf.icnt        = icnt_cum_next;
					etip_msg_next[msg_id_next].sub.cf.rcode       = dbg_entry
						? NEXUS_RCODE_CORR_DEBUG_ENTRY
						: NEXUS_RCODE_CORR_LOW_POWER;
					msg_id_next   = msg_id_next + 1;
					icnt_cum_next = 0;
				end
			end

			// Pause capture: if the LAST qualified retire before a pause edge
			// was a CF, its next_iaddr pairing is still outstanding. The first
			// (unqualified) retire after the edge carries the TRUE successor
			// address. Without capturing it, the queued CF would stay
			// unpairable (msg_gen waits for next_iaddr) or would later be
			// mispaired with a post-resume address, giving the last pre-pause
			// CF a wrong UADDR.
			// Deliberately restricted to the pause/hold window: a retire that
			// fails to qualify because of a filter keeps the existing
			// semantics.
			if (!process_now && pending_cf_next_iaddr_next && tip_retires
			    && (!inst_trace_active || resume_suppress)) begin
				next_iaddr_val      = '{ret_predicted: pending_ret_pred_next
				                                        && (pending_ret_target_next == tip.iaddr),
				                        addr:          tip.iaddr};
				next_iaddr_wr_next  = 1;
				pending_ret_pred_next      = 0;
				pending_cf_next_iaddr_next = 0;
			end

			if (process_now) begin
				if (pending_cf_next_iaddr_next) begin
					// Capture the previous CF event's actual target. If that
					// event was a RETURN with a return-stack prediction, the
					// implicit-return decision (predicted == actual) is made
					// HERE and travels as a single flag bit.
					next_iaddr_val      = '{ret_predicted: pending_ret_pred_next
					                                        && (pending_ret_target_next == tip.iaddr),
					                        addr:          tip.iaddr};
					next_iaddr_wr_next  = 1;
					pending_ret_pred_next = 0; // prediction consumed by this capture
				end
				pending_cf_next_iaddr_next = 0;

				// Count halfwords for any TIP beat that actually retired
				// something -- `count_halfwords` above is qualified on
				// tip_retires, i.e. iretire != 0, and NOTHING else.
				//
				// (Corrected 2026-08-09, R1.3 finding B-R13-2: this block
				// used to describe convention A, in which a beat with
				// iretire == 0 && itype == EXCEPTION_TRAP also contributed
				// the faulting instruction's halfwords. That special case was
				// removed on 2026-07-18 -- see the comment at
				// `count_halfwords` -- so the text contradicted the code
				// three lines above it. The faulting instruction of a
				// synchronous exception does not retire and is not counted;
				// an asynchronous INTERRUPT marker leaves iaddr/ilastsize
				// undefined per the ingress spec and contributes nothing
				// either.)
				//
				// How many halfwords a retiring beat is worth is the ONE
				// place the two ingress shapes differ: with the SR ingress
				// it is the single instruction (2^ilastsize), with the block
				// ingress the whole block (iretire). `beat_halfwords` holds
				// whichever applies.
				//
				// Long spans of OTHER instructions between two CF events
				// (e.g. dense CSR_WRITE bodies in absint, or the n_gap=70
				// jalr->INTERRUPT sweep) can accumulate >255 halfwords
				// before the next CF eTIP is emitted. Silently clamping
				// would lose the excess; passing >255 through to msg_gen
				// breaks `cf_indirect_hist_overflow_hold` (it only emits
				// rdata=CurrICnt and re-fires forever if etip_cf.icnt
				// alone overflows). Instead, pre-drain here: emit a
				// synthetic SUB_MSG_CF marked with rcode=ICNT_OVERFLOW
				// carrying the accumulated halfwords. msg_gen recognises
				// the marker and forwards a wire RCODE=0 directly without
				// touching CurrICnt / Hist / HistCount; etip_cf.icnt then
				// stays ≤ NEXUS_MSG_I_CNT_WIDTH-1 = 255 on every CF
				// emission.
				if (count_halfwords) begin
					if ((icnt_cum_next + beat_halfwords)
					    >= ((CT_EN_WIDE_ICNT && cs_tip.trTeInstEnWideIcnt)
					        ? 2**NEXUS_MSG_I_CNT_WIDTH_WIDE
					        : 2**NEXUS_MSG_I_CNT_WIDTH)) begin
						if (CT_EN_SEQ_SYNC && cs_tip.trTeInstSeqSyncEnable) begin
							// B5: full re-anchor with SYNC=4
							// (Sequential Instruction Counter) instead of the
							// bandwidth-lean RCODE-0 drain. Exclusive
							// ProgTraceSync semantics fall out naturally: the
							// slot fires BEFORE the current instruction is
							// accumulated, so ICNT covers everything before
							// it and FADDR (= tip.iaddr) is the next PC the
							// decoder walks. Pending HIST is carried by the
							// existing pre-flush hold / IBHS in msg_gen.
							// (N-Trace binds SYNC=4 to BTM -- documented
							// Accemic extension, runtime reset 0.)
							etip_msg_next[msg_id_next].sub_type           = SUB_MSG_CF;
							etip_msg_next[msg_id_next].sub.cf.sync_reason = NEXUS_SYNC_SEQ_INSTR_COUNTER;
							etip_msg_next[msg_id_next].sub.cf.btype       = NEXUS_BTYPE_IBRANCH;
							etip_msg_next[msg_id_next].sub.cf.itype       = OTHER;
							etip_msg_next[msg_id_next].sub.cf.iaddr       = tip.iaddr;
							etip_msg_next[msg_id_next].sub.cf.icnt        = icnt_cum_next;
							etip_msg_next[msg_id_next].sub.cf.rcode       = NEXUS_RCODE_NONE;
						end
						else begin
						etip_msg_next[msg_id_next].sub_type           = SUB_MSG_CF;
						etip_msg_next[msg_id_next].sub.cf.sync_reason = NEXUS_SYNC_NONE;
						etip_msg_next[msg_id_next].sub.cf.btype       = NEXUS_BTYPE_IBRANCH;
						etip_msg_next[msg_id_next].sub.cf.itype       = OTHER;
						etip_msg_next[msg_id_next].sub.cf.iaddr       = tip.iaddr;
						etip_msg_next[msg_id_next].sub.cf.icnt        = icnt_cum_next;
						etip_msg_next[msg_id_next].sub.cf.rcode       = NEXUS_RCODE_ICNT_OVERFLOW;
						end
						msg_id_next = msg_id_next + 1;
						icnt_cum_next = 0;
					end
					icnt_cum_next = icnt_cum_next + beat_halfwords;
				end

				// Emit CF eTIP messages for sync events and for real control-flow
				// instructions so the downstream formatter can generate branch messages again.
				if ((eff_sync_reason != NEXUS_SYNC_NONE) || IsControlFlowInstruction(tip.itype)) begin
					etip_msg_next[msg_id_next].sub_type           = SUB_MSG_CF;
					etip_msg_next[msg_id_next].sub.cf.sync_reason = eff_sync_reason;
					etip_msg_next[msg_id_next].sub.cf.itype       = tip.itype;
					// Source PC of the CF event. For an INTERRUPT this field is a
					// don't-care downstream: the interrupt is encoded as an
					// Indirect Branch (ICNT + target UADDR) and the decoder
					// reconstructs the source by walking ICNT — only a
					// ProgTraceSync (a non-CF sync) transmits curr_iaddr. So
					// tip.iaddr being undefined for an interrupt
					// (riscv-trace-spec#324) does not affect the interrupt message
					// (proven by tests/instruction/02_interrupts). tip.iaddr IS
					// consumed when an async interrupt follows a taken CF, but
					// there it supplies the PRIOR branch's target via the
					// pending_cf_next_iaddr capture below, not this source.
					etip_msg_next[msg_id_next].sub.cf.iaddr       = iaddr_last;
					etip_msg_next[msg_id_next].sub.cf.rcode       = NEXUS_RCODE_NONE;
					// E-Trace sideband (1-bit stubs without CT_EN_ETRACE):
					// trap cause/tval for format 3.1, privilege for 3.0/3.1,
					// last-instruction size for the retirement tracking.
					// Only ct_L2_te_inst_gen consumes these.
					etip_msg_next[msg_id_next].sub.cf.trap_ecause = ETIP_TRAP_EC_W'(tip.ecause);
					etip_msg_next[msg_id_next].sub.cf.trap_tval   = ETIP_TRAP_TVAL_W'(tip.tval);
					etip_msg_next[msg_id_next].sub.cf.priv        = ETIP_PRIV_W'(tip.priv);
					etip_msg_next[msg_id_next].sub.cf.ilastsize   = ETIP_ILS_W'(tip.ilastsize);

					// --- Implicit-return return-address stack (Accemic) ---
					// Push the return address on calls; pop on returns. The
					// prediction no longer travels as a 32-bit field in the eTIP
					// (CDC-FIFO width!): the compare against the ACTUAL target
					// happens right here at the next_iaddr capture beat, and only
					// a 1-bit ret_predicted flag rides the next_iaddr sideband.
					// Compile-time gated: without the implicit-return feature the
					// whole stack consts away.
					//
					// Gap re-anchors are SIDE-EFFECT FREE: a TRACE_ENABLE or
					// EXIT_* sync that anchors on a call/return retire must NOT
					// touch the stack. The decoder re-locks on such a sync as a
					// pure anchor -- no walk, no call semantics; it does not
					// even know the call's source address. A one-sided encoder
					// push would make the next return "implicit" against an
					// empty decoder stack ("Not enough entries on callstack").
					// Symmetry rather than deferral: deferring the anchor to a
					// non-CF retire would starve in CF-dense loops, such as a
					// board idling in `j _exit`.
					begin
						automatic logic gap_reanchor =
							eff_sync_reason inside {NEXUS_SYNC_TRACE_ENABLE,
							                        NEXUS_SYNC_EXIT_FROM_DEBUG,
							                        NEXUS_SYNC_EXIT_FROM_POWERDOWN,
							                        NEXUS_SYNC_EXIT_FROM_SYS_RST};
						pending_ret_pred_next   = 1'b0;
						pending_ret_target_next = RET_SENTINEL;
						if (CT_EN_IMPLICIT_RETURN && !gap_reanchor
						    && tip.itype inside {INFERRABLE_CALL, UNINFERABLE_CALL}) begin
							if (ret_sp_next < RET_STACK_DEPTH[$clog2(RET_STACK_DEPTH):0]) begin
								// Return address = call PC + size of the call instruction in
								// BYTES. tip.iaddr is a byte address; (1<<ilastsize) is the
								// size in HALF-WORDS (2 for a 32-bit call, 1 for a 16-bit
								// c.jal[r]), so the byte size is (2<<ilastsize). Must match
								// the actual next_iaddr the decoder sees on return.
								ret_stack_next[ret_sp_next] = iaddr_after;
								ret_sp_next                 = ret_sp_next + 1;
							end
						end else if (CT_EN_IMPLICIT_RETURN && !gap_reanchor && tip.itype == RETURN) begin
							if (ret_sp_next > 0) begin
								pending_ret_pred_next   = 1'b1;
								pending_ret_target_next = ret_stack_next[ret_sp_next - 1];
								ret_sp_next = ret_sp_next - 1;
							end
						end
					end

					if (eff_sync_reason != NEXUS_SYNC_NONE) begin
						// Nexus ICNT = instruction units executed since the last
						// transmitted ICNT. Sync messages carry that count via
						// (CurrICnt in msg_gen) + (this etip.cf.icnt), but the
						// inclusive/exclusive treatment of the sync PC depends
						// on the sync type — matching what the NexRv decoder
						// expects:
						// - DirectBranchSync / IndirectBranchSync (sync + CF):
						//   FADDR is the branch target. ICNT is INCLUSIVE of
						//   the sync (branch) instruction — the decoder walks
						//   it, processes the branch, and lands on the target.
						// - ProgTraceSync (pure sync, no CF): FADDR is the
						//   sync instruction itself. ICNT is EXCLUSIVE of the
						//   sync instruction; the next message's walk emits it
						//   as its first PC. Carry the sync instruction's own
						//   halfwords into the next accumulator.
						// The inclusive/exclusive choice must track the message
						// type msg_gen will emit, which keys off whether the
						// instruction CHANGED control flow:
						//   - HasChangedControlFlow (taken branch, jump, call,
						//     return, trap) -> DirectBranchSync / IndirectBranchSync,
						//     FADDR is the target -> INCLUSIVE (decoder walks the
						//     branch and lands on the target).
						//   - otherwise (OTHER, NOT_TAKEN_BRANCH) -> ProgTraceSync,
						//     FADDR is the sync instruction itself -> EXCLUSIVE
						//     (the decoder re-counts the sync instruction's
						//     half-words on its next walk).
						// A NOT_TAKEN_BRANCH is a control-flow instruction but does
						// not change control flow, so it must take the EXCLUSIVE
						// path here; msg_gen seeds its direction into the post-sync
						// history (see send_cf_msg) so the branch is counted and
						// resolved exactly once in the next segment. EXIT_FROM_SYS_RST
						// is always exclusive (it never changes control flow).
						if (HasChangedControlFlow(tip.itype)
						 && eff_sync_reason != NEXUS_SYNC_EXIT_FROM_SYS_RST) begin
							etip_msg_next[msg_id_next].sub.cf.icnt = icnt_cum_next;
							icnt_cum_next = 0;
						end else begin
							// EXCLUSIVE (ProgTraceSync). This is the ONE message
							// that transmits cf.iaddr as a wire address
							// (msg_gen: TraceMsg.sub.cf.curr_iaddr -> F-ADDR);
							// everywhere else the field is the BP index / the
							// RepeatInstruction key, i.e. the branch itself.
							// A block ingress makes the two differ, and the
							// anchor is the one that has to win here:
							//
							// the anchor sits BEFORE the reported instructions,
							// and the encoder cannot split a block -- so the
							// anchor is the block START and the WHOLE block
							// carries over into the next segment's count. With
							// iaddr_last / (1 << ilastsize) instead, everything
							// but the last instruction of the anchoring block
							// falls out of the reconstruction (measured: the
							// first three PCs of a four-instruction opening
							// block, R1.3 gate run 2).
							//
							// The BP index is not lost to this: the sync
							// generator DEFERS the anchor away from branches
							// while branch prediction is on (sync_anchor_ok in
							// ct_L23_preproc_sync), so a not-taken branch and an
							// exclusive sync cannot share a beat in that mode;
							// and RepeatInstruction needs TAKEN_BRANCH, which
							// takes the inclusive path above.
							//
							// At the single-retirement ingress both expressions
							// reduce to the historical ones (iaddr_last ==
							// tip.iaddr, beat_halfwords == 1 << ilastsize).
							etip_msg_next[msg_id_next].sub.cf.iaddr = tip.iaddr;
							etip_msg_next[msg_id_next].sub.cf.icnt = icnt_cum_next - beat_halfwords;
							icnt_cum_next = beat_halfwords;
						end
					end else begin
						etip_msg_next[msg_id_next].sub.cf.icnt = icnt_cum_next;
						icnt_cum_next = 0;
					end
					msg_id_next   = msg_id_next + 1;
					pending_cf_next_iaddr_next = HasChangedControlFlow(tip.itype);
				end

				// Ownership messages (TCODE 2, N-Trace 7.1):
				// emitted while trTeControl.Context is set on (a) a context-
				// report ingress event (tip.ctype != 0 -> FORMAT=2 with the
				// scontext value), (b) a privilege-level change between
				// qualified retires, or (c) "immediately after all
				// synchronizing messages" -- as the slot FOLLOWING the sync
				// CF in the SAME beat (ETIP_PAR_MSG carries the +1).
				if (CT_EN_OWNERSHIP && cs_tip.trTeContext
				    && ( (tip.ctype != '0)
				      || (tip_retires && (tip.priv != PrevPrivQ))
				      || (eff_sync_reason != NEXUS_SYNC_NONE) )) begin
					automatic nexus_process_t own_proc;
					own_proc.format   = (tip.ctype != '0) ? CONTEXT_SCONTEXT : CONTEXT_V_PRV;
					own_proc.prv      = nexus_context_prv_e'(tip.priv[1:0]);
					own_proc.v        = tip.priv[2];
					own_proc._context = (tip.ctype != '0)
					                  ? NEXUS_MSG_PROCESS_WIDTH'(tip._context) : '0;
					etip_msg_next[msg_id_next].sub_type          = SUB_MSG_OTHER;
					etip_msg_next[msg_id_next].sub.other.tcode   = NEXUS_MSG_OWNERSHIP_TRACE;
					etip_msg_next[msg_id_next].sub.other.etype   = nexus_etype_e'(0);
					etip_msg_next[msg_id_next].sub.other.ecode   = '0;
					etip_msg_next[msg_id_next].sub.other.payload = ETIP_OTHER_PAYLOAD_W'(own_proc);
					msg_id_next = msg_id_next + 1;
				end
			end

			// Data-trace eTIP arms: hard-gated by the build profile. The
			// qualifier stubs are constant-pass in slim profiles, so without
			// this gate a dretire beat could still raise a DF slot -- the
			// CF-only ETIP_PAR_MSG=2 bound relies on these arms being
			// provably dead when CT_EN_DATA_TRACE=0.
			//
			// P7 drop policy: while DfDropArm is set, each arm that WOULD have
			// raised a DF slot instead raises df_drop_now and emits nothing.
			// The suppression is deliberately per-slot (not per-beat): a beat's
			// CF slot must keep flowing -- that is the whole point of the
			// policy ("avoid instruction trace overflows").
			if (CT_EN_DATA_TRACE && SPLIT_DATA_ACCESS) begin
				if (!dbg_suppress && tip.dretire && (tip.dtype == STORE) && df_qualifier.hit_valid && df_qualifier.hit && DfDropArm) begin
					df_drop_now = 1'b1;
				end
				else if (!dbg_suppress && tip.dretire && (tip.dtype == STORE) && df_qualifier.hit_valid && df_qualifier.hit) begin
					etip_msg_next[msg_id_next].sub_type      = SUB_MSG_DF;
					mask = ({TIP_DATA_WIDTH{1'b1}} >> (TIP_DATA_WIDTH - (8 << tip.dsize)));
					etip_msg_next[msg_id_next].sub.df.data       = ETIP_DF_DATA_W'(tip_data_t'(tip.sdata) & mask);
					etip_msg_next[msg_id_next].sub.df.addr_idtag = ETIP_DF_ADDR_W'(tip.daddr);
					etip_msg_next[msg_id_next].sub.df.dtype      = tip.dtype;
					etip_msg_next[msg_id_next].sub.df.dsz        = GetDsz(tip.dsize);
					etip_msg_next[msg_id_next].sub.df.elsz       = GetElsz(tip.dsize);
					msg_id_next = msg_id_next + 1;
				end
				if (!dbg_suppress && tip.lresp[1] && df_qualifier.hit_valid && df_qualifier.hit && DfDropArm) begin
					df_drop_now = 1'b1;
				end
				else if (!dbg_suppress && tip.lresp[1] && df_qualifier.hit_valid && df_qualifier.hit) begin
					etip_msg_next[msg_id_next].sub_type      = SUB_MSG_DF;
					mask = ({TIP_DATA_WIDTH{1'b1}} >> (TIP_DATA_WIDTH - (8 << PendingSplitLoadDsize)));
					etip_msg_next[msg_id_next].sub.df.data       = ETIP_DF_DATA_W'(tip_data_t'(tip.ldata) & mask);
					etip_msg_next[msg_id_next].sub.df.addr_idtag = ETIP_DF_ADDR_W'(PendingSplitLoadDaddr);
					etip_msg_next[msg_id_next].sub.df.dtype      = LOAD;
					etip_msg_next[msg_id_next].sub.df.dsz        = GetDsz(PendingSplitLoadDsize);
					etip_msg_next[msg_id_next].sub.df.elsz       = GetElsz(PendingSplitLoadDsize);
					msg_id_next = msg_id_next + 1;
				end
			end else if (CT_EN_DATA_TRACE) begin
				if (!dbg_suppress && tip.dretire && df_qualifier.hit_valid && df_qualifier.hit && DfDropArm) begin
					df_drop_now = 1'b1;
				end
				else if (!dbg_suppress && tip.dretire && df_qualifier.hit_valid && df_qualifier.hit) begin
					etip_msg_next[msg_id_next].sub_type      = SUB_MSG_DF;
					mask = ({TIP_DATA_WIDTH{1'b1}} >> (TIP_DATA_WIDTH - (8 << tip.dsize)));
					etip_msg_next[msg_id_next].sub.df.data       = ETIP_DF_DATA_W'(tip.data & mask);
					etip_msg_next[msg_id_next].sub.df.addr_idtag = ETIP_DF_ADDR_W'(tip.daddr);
					etip_msg_next[msg_id_next].sub.df.dtype      = tip.dtype;
					etip_msg_next[msg_id_next].sub.df.dsz        = GetDsz(tip.dsize);
					etip_msg_next[msg_id_next].sub.df.elsz       = GetElsz(tip.dsize);
					msg_id_next = msg_id_next + 1;
				end
			end

			// P7 drop marker: ONE Error message per drop EPISODE announces the
			// data-trace loss on the wire -- ETYPE = QueueOverrun, ECODE = 0x02
			// (DataMessageLost), and DELIBERATELY WITHOUT the ProgramTraceSync
			// (SYNC=7) re-anchor that the generic eTIP overflow path injects:
			// forcing an instruction re-anchor per dropped data message would be
			// the exact opposite of what the policy promises. The marker takes
			// the slot the suppressed DF would have used, so the ETIP_PAR_MSG
			// bound cannot grow (a drop beat emits at most as many slots as the
			// same beat without the policy).
			if (CT_EN_DF_DROP && df_drop_now && !DfDropEpisode) begin
				etip_msg_next[msg_id_next].sub_type        = SUB_MSG_OTHER;
				etip_msg_next[msg_id_next].sub.other.tcode = NEXUS_MSG_ERROR;
				etip_msg_next[msg_id_next].sub.other.etype = NEXUS_ETYPE_QUEUE_OVERRUN;
				etip_msg_next[msg_id_next].sub.other.ecode =
					nexus_vendor_ecode_t'(NEXUS_ECODE_DF_MSG_LOST);
				msg_id_next      = msg_id_next + 1;
				df_drop_mark_now = 1'b1;
			end

			// Watchpoint eTIP arm (TCODE 15, P4): the ACT-ST command
			// ACT_CAP_ST_WATCHPOINT reports WHICH watchpoint fired, instead
			// of the anonymous SYNC=6 trigger marker. WPHIT =
			// Cmd.DirectData[15:0] AND trWpMask.WEM -- software owns the
			// slot<->bit convention (the ACT-ST table entry that fires
			// carries the bit in its DirectData), the WEM mask decides which
			// slots may report at all. WEM = 0 (reset) masks every hit, so
			// the arm raises no slot until software opts in. Unlike the DAQ
			// arm below, the payload TRAVELS in the eTIP (ownership
			// pattern): it is a per-event value, not a quasi-static
			// configuration the emission site could re-sample.
			if (   CT_EN_WATCHPOINT_MSG
				&& !dbg_suppress
				&& act_cap_st.valid
				&& (act_cap_st.cmd.Cmd.value == ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_WATCHPOINT)
				&& (  (act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS)
					||(act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS))
				&& ((act_cap_st.cmd.DirectData.value[NEXUS_MSG_WPHIT_IMPL_WIDTH-1:0]
				     & cs_tip.trWpWEM) != '0)) begin
				etip_msg_next[msg_id_next].sub_type          = SUB_MSG_OTHER;
				etip_msg_next[msg_id_next].sub.other.tcode   = NEXUS_MSG_WATCHPOINT;
				etip_msg_next[msg_id_next].sub.other.etype   = nexus_etype_e'(0);
				etip_msg_next[msg_id_next].sub.other.ecode   = '0;
				etip_msg_next[msg_id_next].sub.other.payload = ETIP_OTHER_PAYLOAD_W'(
					act_cap_st.cmd.DirectData.value[NEXUS_MSG_WPHIT_IMPL_WIDTH-1:0]
					& cs_tip.trWpWEM);
				msg_id_next = msg_id_next + 1;
			end

			// DAQ eTIP arm: only exists with the ACT blocks (their stub drives
			// act_cap_st.valid=0; the CT_EN_ACT gate makes the arm provably
			// dead for the CF-only ETIP_PAR_MSG=2 bound). ACT_CAP_ST_CF_SYNC
			// and ACT_CAP_ST_WATCHPOINT have their own arms (above) and must
			// not additionally raise a DAQ message.
			if (   CT_EN_ACT
				&& !dbg_suppress
				&& (act_cap_st.valid)
				&& (act_cap_st.cmd.Cmd.value != ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC)
				&& (act_cap_st.cmd.Cmd.value != ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_WATCHPOINT)
				&& (  (act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS)
					||(act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS))) begin
				etip_msg_next[msg_id_next].sub_type         = SUB_MSG_DAQ;
				etip_msg_next[msg_id_next].sub.daq.addr_idtag = ETIP_DAQ_ADDR_W'(act_cap_st.cmd.Cmd.value);
				etip_msg_next[msg_id_next].sub.daq.data     = '0;
				case (act_cap_st.cmd.Cmd.value)
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(tip.iaddr);
						etip_msg_next[msg_id_next].sub.daq.data[1] = daq_elem(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR_LAST: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(tip.iaddr);
						etip_msg_next[msg_id_next].sub.daq.data[1] = daq_elem(LastIAddrBeforeException);
						etip_msg_next[msg_id_next].sub.daq.data[2] = daq_elem(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(PrevData);
						etip_msg_next[msg_id_next].sub.daq.data[1] = daq_elem(tip_xaddr_data_t'(PrevDtypeDsize));
						etip_msg_next[msg_id_next].sub.daq.data[2] = daq_elem(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(tip_xaddr_data_t'(PrevDAddr));
						etip_msg_next[msg_id_next].sub.daq.data[1] = daq_elem(tip_xaddr_data_t'(PrevDtypeDsize));
						etip_msg_next[msg_id_next].sub.daq.data[2] = daq_elem(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(PrevData);
						etip_msg_next[msg_id_next].sub.daq.data[1] = daq_elem(tip_xaddr_data_t'(PrevDAddr));
						etip_msg_next[msg_id_next].sub.daq.data[2] = daq_elem(pack_daq_context_direct(PrevDtypeDsize, act_cap_st.cmd.DirectData.value));
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_RD_RANGES)
							etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(tip_xaddr_data_t'(perfcnt.data_rd_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0]]));
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_WR: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_WR_RANGES)
							etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(tip_xaddr_data_t'(perfcnt.data_wr_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0]]));
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_IFETCH_TH: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0] <= NUM_PERFCNT_IFETCH_TH_RANGES)
							etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(tip_xaddr_data_t'(perfcnt.ifetch_th_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0]]));
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD_TH: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_RD_TH_RANGES)
							etip_msg_next[msg_id_next].sub.daq.data[0] = daq_elem(tip_xaddr_data_t'(perfcnt.data_rd_th_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0]]));
					end
					default: begin
					end
				endcase
				msg_id_next = msg_id_next + 1;
			end

			// process flush request
			do_flush_ack_next = (!do_flush && DoFlushAck) ? 0 : DoFlushAck;
			if (do_flush && !do_flush_ack_next) begin
				// W2: DoCorrFilterExit takes the SAME arm -- leaving the filter
				// region and switching instruction tracing off are the same
				// thing from the decoder's side (everything after this point is
				// invisible until the next anchor), so they get the same
				// message, the same residual ICNT/HIST hand-over and the same
				// call-stack clear. One slot, two sources.
				if (DoCorrDisable || DoCorrFilterExit) begin
					// Instruction tracing turned off: emit a Program Trace
					// Correlation Message (TCODE 33, EVCODE=Program Trace
					// Disabled) per IEEE-ISTO 5001 §4.3.16, carrying the residual
					// instruction count so the decoder can walk out the final
					// instructions up to the trace-off point. The rcode marks it
					// for msg_gen, which adds its accumulated ICNT, attaches the pending HIST,
					// and clears the accumulators (mirrors the ICNT_OVERFLOW
					// pre-drain marker above). do_flush=1 drains the pipeline
					// after it.
					etip_msg_next[msg_id_next].sub_type           = SUB_MSG_CF;
					etip_msg_next[msg_id_next].sub.cf.sync_reason = NEXUS_SYNC_NONE;
					etip_msg_next[msg_id_next].sub.cf.btype       = NEXUS_BTYPE_IBRANCH;
					etip_msg_next[msg_id_next].sub.cf.itype       = OTHER;
					etip_msg_next[msg_id_next].sub.cf.iaddr       = tip.iaddr;
					etip_msg_next[msg_id_next].sub.cf.icnt        = icnt_cum_next;
					etip_msg_next[msg_id_next].sub.cf.rcode       = NEXUS_RCODE_TRACE_DISABLED;
					etip_msg_next[msg_id_next].do_flush           = 1;
					msg_id_next       = msg_id_next + 1;
					icnt_cum_next     = 0;
					do_flush_ack_next = 1;
					// Clear the implicit-return stack at the pause edge:
					// calls and returns DURING the pause are invisible. A
					// surviving frame that happens to predict the real target
					// after the resume would make that return "implicit",
					// while the decoder -- NexRv clears its call stack on the
					// correlation message -- pops from an empty or different
					// stack. Same failure mode as at the FIFO_OVERRUN anchor.
					// Clearing is always SAFE: it forces explicit returns
					// until both sides refill in lockstep.
					if (CT_EN_IMPLICIT_RETURN) begin
						ret_sp_next           = '0;
						pending_ret_pred_next = 1'b0;
					end
				end else begin
					msg_id_next = (msg_id_next == 0) ? 1 : msg_id_next;
					etip_msg_next[msg_id_next-1].do_flush = 1;
					do_flush_ack_next = 1;
				end
			end

			// P4-SLOT (slot bound): checked HERE, at the end of the slot
			// allocation, as an IMMEDIATE assertion -- `msg_id_next` is a
			// variable of this always_comb, so a concurrent property
			// (@(posedge clk)) samples the PREPONED value and misses every
			// violation (the P4 audit proved that experimentally: with
			// ETIP_PAR_MSG forced below the demand the bound was really
			// broken while the concurrent property stayed silent).
			// `etip_msg_next[msg_id_next]` with an out-of-range index writes
			// NOWHERE, so an exceeded bound loses messages SILENTLY -- this
			// checker is the only thing that makes it visible.
			// pragma translate_off
			a_p4_slot_bound: assert (msg_id_next <= ETIP_PAR_MSG)
				else $error("%m P4-SLOT: eTIP slot count %0d exceeds ETIP_PAR_MSG=%0d -- messages are silently dropped",
					msg_id_next, ETIP_PAR_MSG);
			// pragma translate_on

			// R1.3 block-ingress contract, checked where it is consumed
			// rather than trusted. Both are vacuous (and compiled out)
			// without CT_EN_BLOCK_TIP.
			//
			//  1. A block is at least as long as its own last instruction.
			//     Violating this makes TipLastIaddr underflow, and the CF
			//     source PC would land somewhere near the top of the address
			//     space instead of failing loudly.
			//  2. A single beat must stay below the ICNT pre-drain
			//     threshold. The drain restarts the accumulator AT
			//     beat_halfwords, so a beat that alone exceeds the threshold
			//     would leave icnt_cum >= 2^8 and msg_gen's
			//     cf_indirect_hist_overflow_hold would re-fire for ever.
			//     ct_encoder bounds CT_IRETIRE_WIDTH at elaboration; this is
			//     the runtime witness that the bound is the right one.
			//
			// Both are functions of `tip` ALONE -- deliberately not of the
			// derived uwires. An immediate assertion inside always_comb sees
			// every intermediate evaluation, and a continuously assigned
			// uwire settles one delta behind the signal that drove it: the
			// first version of this check guarded on `tip_retires` and fired
			// on the beat where iretire fell to 0 while the (stale) uwire
			// still read 1. The settled datapath is correct either way --
			// always_comb is sensitive to the uwires and re-evaluates -- but
			// a checker must not need that argument to be readable.
			// pragma translate_off
			if (CT_EN_BLOCK_TIP && (|tip.iretire)) begin
				a_r13_block_covers_last: assert (tip_icnt_t'(tip.iretire) >= (tip_icnt_t'(1) << tip.ilastsize))
					else $error("%m R1.3-BLOCK: iretire=%0d halfwords is shorter than the last instruction (ilastsize=%0d -> %0d halfwords)",
						tip.iretire, tip.ilastsize, (1 << tip.ilastsize));
				a_r13_block_icnt_bound: assert (tip_icnt_t'(tip.iretire) < tip_icnt_t'(2**NEXUS_MSG_I_CNT_WIDTH))
					else $error("%m R1.3-BLOCK: iretire=%0d halfwords in ONE beat reaches the ICNT pre-drain threshold %0d -- the adapter must split the run into itype=OTHER blocks",
						tip.iretire, 2**NEXUS_MSG_I_CNT_WIDTH);
			end
			// pragma translate_on

			// Sink-overflow view: parallel mode = the eTIP FIFO's full flag;
			// serialize mode = "this beat's messages do not fit into the skid
			// queue" (driven from the generate branches below).
			etip_ovf_drop_now = (msg_id_next != 0) && etip_sink_overflow_now;
			// etip_ovf_pending: in the serialize arrangement the drop episode
			// extends past the instantaneous full/dropping view — beats keep
			// dropping until the owed marker pair has gone out in stream
			// order, so their sideband captures must be cleared here exactly
			// like the directly dropped ones.
			if (etip_ovf_drop_now || etip_ovf_dropping || etip_ovf_pending) begin
				// Do NOT clear `next_iaddr_wr_next` here. It
				// carries the PREVIOUS cycle's CF's pending capture (set
				// at the "if (pending_cf_next_iaddr_next)" block above)
				// — that CF is already queued in etip_cvs_d (it landed
				// while the FIFO had room) and msg_gen will need its
				// next_iaddr_q entry when it pops it. next_iaddr_q is
				// an independent FIFO; sideband_ovf_drop below handles
				// its own back-pressure. Clearing the write strobe here
				// would orphan the queued CF and stall msg_gen
				// indefinitely waiting for next_iaddr_q.valid.
				//
				// We DO still clear `pending_cf_next_iaddr_next`,
				// because if THIS cycle emitted a new CF (line 354 set
				// the flag), ovf_injector is dropping it from the etip
				// stream — no future capture is owed for a slot that
				// never reaches etip_cvs_d.
				//
				// But ONLY on beats that can carry a CF (retire / trap):
				// this comb block runs EVERY clk cycle, and the drop
				// conditions are LEVELS that stay high between beats. An
				// unconditional clear here wipes the pending capture of
				// the PREVIOUS, already-queued CF during the idle cycles
				// between two retires — its next_iaddr entry is then
				// never written and msg_gen pairs every later CF with
				// its successor's address (measured 2026-07-20: phase-D
				// DirectBranchSync FADDR = the NEXT jump's target).
				if (tip.iretire || is_trap_event) begin
					pending_cf_next_iaddr_next = 0;
					pending_ret_pred_next      = 0;
				end
			end

			// Sideband (next_iaddr) FIFO back-pressure.
			//
			// The ETIP-path drop gate above only looks at the ETIP FIFO's
			// full signal, but the next_iaddr FIFO can fill independently:
			// the ETIP cvs_cdc_fifo2 compacts up to P=3 msgs per slot, so
			// its effective capacity is far above the sideband FIFO's
			// 1-msg-per-slot depth. Under dense change-of-CF traffic the
			// sideband hits capacity well before `etip_cvs_d.full` fires
			// and the inner `fifo2clk_fwft` silently masks a `wr && full`
			// write — which breaks the 1:1 pairing msg_gen relies on.
			//
			// Drop margin: both `msg_id_next`/`next_iaddr_wr_next` reach
			// the sinks one register stage later, so decide on
			// `cnt_avail < 2` to cover the in-flight write committed by
			// the previous cycle's decision.
			sideband_ovf_drop = next_iaddr_d.cnt_avail < 2;
			if (sideband_ovf_drop) begin
				// Do NOT clear `next_iaddr_wr_next` (same rule as the ETIP
				// drop gate above): it is the CAPTURE for the PREVIOUS
				// beat's CF, which already sits in etip_cvs_d. Suppressing
				// it starves that CF of its next_iaddr entry and msg_gen
				// pairs every later CF with its successor's address —
				// measured as a FIFO_OVERRUN-recovery DirectBranchSync
				// whose FADDR was the NEXT jump's target (0x3200 instead
				// of 0x3000, phase D of overrun_recovery_tb). The `<2`
				// margin above reserves exactly this in-flight write, so
				// it can never be silently masked by a full FIFO.
				// Clear pendings only on CF-capable beats — this drop
				// condition is a LEVEL; see the identical guard in the
				// ETIP drop gate above for the failure mode.
				if (tip.iretire || is_trap_event) begin
					pending_cf_next_iaddr_next = 0;
					pending_ret_pred_next      = 0;
				end
				// Symmetrically drop this cycle's ETIP msgs so msg_gen
				// never sees a CF without its matching next_iaddr entry.
				// The ovf_injector is notified via `force_drop` below and
				// emits ERROR + SYNC(FIFO_OVERRUN) on the ETIP stream so
				// the decoder resyncs.
				msg_id_next = 0;
				for (int i = 0; i < ETIP_PAR_MSG; i++) begin
					etip_msg_next[i].sub_type = SUB_MSG_NONE;
					etip_msg_next[i].do_flush = 0;
				end
			end

			// P7: a drop marker only COUNTS as emitted when its beat survived
			// both drop gates above. If the beat is discarded anyway, the
			// generic overflow ERROR (which lists DF_MSG_LOST in its ECODE
			// mask) already covers the loss -- and the episode must stay
			// unarmed so the next surviving beat can place the marker.
			if (etip_ovf_drop_now || etip_ovf_dropping || etip_ovf_pending
			    || sideband_ovf_drop) begin
				df_drop_mark_now = 1'b0;
			end

			// FIFO_OVERRUN resync anchor: in the cycle the injector emits
			// the SYNC marker (anchor = PrevIAddr + size, sampled NOW),
			// restart the halfword accumulator AT the anchor. Without this
			// the first post-recovery CF would carry the halfwords of the
			// discarded window too and the decoder's ICNT walk would
			// overshoot the true CF source (measured: NexRv resolved the
			// phase-D indirect-jump source to a non-indirect PC). A retire
			// in this very cycle is the anchor instruction itself — the
			// decoder walks it first, so it belongs to the new count.
			if (etip_ovf_inject_done) begin
				// (same qualification as `count_halfwords` above)
				icnt_cum_next = (inst_trace_active
				                 && !(CT_EN_DEBUG_EVENTS && tip.debug_mode)
				                 && tip_retires)
					? beat_halfwords : '0;
				// Implicit-return stack: calls/returns inside the dropped
				// window mutated OUR stack while the decoder saw none of them
				// (and NexRv clears its call stack on the Error message). A
				// stale frame that still predicts the actual target flags the
				// return "implicit", the decoder pops a wrong/empty frame and
				// desyncs ("Expected an indirect branch ..." / "Not enough
				// entires on callstack" -- KV260 robustness campaign classes
				// B3/B10, soak runs with the full suite). Emptying the stack
				// is always SAFE: an empty stack merely forces explicit
				// returns (bandwidth, not correctness) until post-recovery
				// calls repopulate both sides in lockstep. Same family and
				// same anchor point as the JtcValid/BpEpoch clears (B1).
				if (CT_EN_IMPLICIT_RETURN) begin
					ret_sp_next           = '0;
					pending_ret_pred_next = 1'b0;
				end
			end
		end
	end

	// ----------------------------------------------------------------
	// Register update (non-blocking only)
	// ----------------------------------------------------------------
	always_ff @(posedge clk) begin
		EtipMsg              <= etip_msg_next;
		NextIaddrWr          <= next_iaddr_wr_next;
		NextIaddr            <= next_iaddr_val;

		if (rst) begin
			MsgId                       <= 0;
			PendingCfNextIaddr          <= 0;
			PendingRetPred              <= 0;
			PendingRetTarget            <= '0;
			ICntCum                     <= 0;
			DoFlushAck                  <= 0;
			PrevIAddr                   <= '0;
			PrevRetireWasCf             <= 1'b0;
			LastIAddrBeforeException    <= '0;
			PrevDAddr                   <= '0;
			PrevData                    <= '0;
			PrevDtypeDsize              <= '0;
			PendingSplitLoadDaddr       <= '0;
			PendingSplitLoadDsize       <= '0;
			RetSp                       <= '0;
			RetStack                    <= '0;
		end
		else begin
			MsgId              <= msg_id_next;
			ICntCum            <= icnt_cum_next;
			DoFlushAck         <= do_flush_ack_next;
			PendingCfNextIaddr <= pending_cf_next_iaddr_next;
			PendingRetPred     <= pending_ret_pred_next;
			PendingRetTarget   <= pending_ret_target_next;
			RetSp              <= ret_sp_next;
			RetStack           <= ret_stack_next;

			if (tip.dretire) begin
				PrevDAddr      <= tip.daddr;
				PrevData       <= tip.data;
				PrevDtypeDsize <= {tip.dtype, tip.dsize};
			end
			// Track the trap redirect for anchor validity (see the
			// declaration): the trap marker beat (iretire=0) sets it, the next
			// real retire (handler entry) clears it. A beat that carries both
			// counts as a trap -- conservatively defer the anchor.
			if ((tip.itype == EXCEPTION_TRAP) || (tip.itype == INTERRUPT)) begin
				PrevEventWasTrap <= 1'b1;
			end else if (tip_retires) begin
				PrevEventWasTrap <= 1'b0;
			end
			if (tip_retires) begin
				PrevIAddr     <= tip.iaddr;
				PrevIlastsize <= tip.ilastsize;
				if (CT_EN_BLOCK_TIP) PrevIAddrAfter <= iaddr_after;
				PrevRetireWasCf <= HasChangedControlFlow(tip.itype);
				if (cf_qualifier.hit_valid && cf_qualifier.hit)
					if ((tip.itype == EXCEPTION_TRAP) || (tip.itype == INTERRUPT))
						LastIAddrBeforeException <= PrevIAddr;
			end
			if (SPLIT_DATA_ACCESS && tip.dretire && (tip.dtype == LOAD)) begin
				PendingSplitLoadDaddr <= tip.daddr;
				PendingSplitLoadDsize <= tip.dsize;
			end

			// Perfcnt counter clear pulses (active for one cycle on DAQ read)
			if (act_cap_st.valid
				&& (  (act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS)
					||(act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS))) begin
				case (act_cap_st.cmd.Cmd.value)
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_RD_RANGES)
							perfcnt.data_rd_counter_clr_etip[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0]] <= '1;
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_WR: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_WR_RANGES)
							perfcnt.data_wr_counter_clr_etip[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0]] <= '1;
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_IFETCH_TH: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0] <= NUM_PERFCNT_IFETCH_TH_RANGES)
							perfcnt.ifetch_th_counter_clr_etip[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0]] <= '1;
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD_TH: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_RD_TH_RANGES)
							perfcnt.data_rd_th_counter_clr_etip[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0]] <= '1;
					end
					default: begin end
				endcase
			end
		end
	end

	// ----------------------------------------------------------------
	// next_iaddr FIFO (tip_clk -> proc_clk)
	// ----------------------------------------------------------------

	sink_if   #(.T(etip_next_iaddr_t)) next_iaddr_d ( .clk, .rst );
	assign next_iaddr_d.d  = NextIaddr;
	assign next_iaddr_d.wr = NextIaddrWr;

	// Depth: at most ONE next_iaddr entry per in-flight eTIP slot, and the
	// eTIP path buffers CVS + CDC slots -- size the sideband to the same
	// total so it can never become the earlier-full bottleneck.
	if (CT_SINGLE_CLOCK) begin : genNextIaddrFifo1clk
		fifo1clk_fwft #(
			.T          (etip_next_iaddr_t),
			.MIN_DEPTH  (ETIP_CVS_FIFO_DEPTH + ETIP_CDC_FIFO_DEPTH),
			.FIFO_STYLE ("auto"))
		next_iaddr_fifo (
			.d(next_iaddr_d),
			.q(next_iaddr_q)
		);
	end
	else begin : genNextIaddrFifo2clk
		fifo2clk_fwft #(
			.T          (etip_next_iaddr_t),
			.MIN_DEPTH  (ETIP_CVS_FIFO_DEPTH + ETIP_CDC_FIFO_DEPTH),
			.FIFO_STYLE ("auto"),
			.SAFE_RESETS(1))
		next_iaddr_fifo (
			.d(next_iaddr_d),
			.q(next_iaddr_q)
		);
	end

	// ----------------------------------------------------------------
	// eTIP presentation stage: parallel (historical, P-wide compacting
	// FIFO) or serialized (M-Serialize: 1 slot/cycle + skid queue, FIFO
	// width = ONE entry). Selected by ct_pkg::CT_ETIP_SERIALIZE; shared
	// drop bookkeeping above uses etip_sink_overflow_now/etip_ovf_dropping.
	// ----------------------------------------------------------------

	uwire logic        etip_sink_overflow_now;
	uwire logic [31:0] etip_ovf_discard_cnt;
	uwire [$clog2(ETIP_CVS_FIFO_DEPTH+1)-1:0] etip_cvs_fill;

	// B7: the drop gate discards WHOLE beats, so every message
	// class the profile can raise may be lost -- the ECODE bitmask lists
	// them all (profile-gated). ETYPE=1 (HIGH_PRIO contention) remains
	// structurally unreachable: CTTE has no priority preemption between
	// message classes (documented, not implemented).
	// The Watchpoint bit is gated by CT_EN_WATCHPOINT_MSG (P4, D-P4-10):
	// until P4 it was gated by CT_EN_TRIG_SYNC, which is an over-claim --
	// the trigger feature emits a SYNC=6 marker inside a CF message, no
	// Watchpoint message exists to be lost. The bit now means what it says.
	// P7 completes that clean-up: the DF and DAQ bits were unconditional,
	// which is the same class of over-claim -- a CF-only profile has no
	// data-trace and no DAQ message that COULD be lost, so a decoder saw an
	// ECODE claiming losses the build can never produce. CF stays
	// unconditional: the control-flow path exists in every profile.
	localparam nexus_vendor_ecode_t ETIP_OVF_ECODE =
		nexus_vendor_ecode_t'(
			NEXUS_ECODE_CF_MSG_LOST
			| (CT_EN_DATA_TRACE     ? NEXUS_ECODE_DF_MSG_LOST         : 8'h0)
			| ((CT_EN_DAQ || CT_EN_ACT) ? NEXUS_ECODE_DAQ_MSG_LOST    : 8'h0)
			| (CT_EN_OWNERSHIP     ? NEXUS_ECODE_OWNERSHIP_MSG_LOST  : 8'h0)
			| (CT_EN_WATCHPOINT_MSG ? NEXUS_ECODE_WATCHPOINT_MSG_LOST : 8'h0)
		);

	etip_msg_struct_t ovf_inject_msg0;
	etip_msg_struct_t ovf_inject_msg1;
	always_comb begin
		ovf_inject_msg0                    = '0;
		ovf_inject_msg0.sub_type           = SUB_MSG_OTHER;
		ovf_inject_msg0.do_flush           = 1'b0;
		ovf_inject_msg0.ts                 = etip_ts_t'(ts_value);
		ovf_inject_msg0.sub.other.tcode    = NEXUS_MSG_ERROR;
		ovf_inject_msg0.sub.other.etype    = NEXUS_ETYPE_QUEUE_OVERRUN;
		ovf_inject_msg0.sub.other.ecode    = ETIP_OVF_ECODE;

		ovf_inject_msg1                    = '0;
		ovf_inject_msg1.sub_type           = SUB_MSG_CF;
		ovf_inject_msg1.do_flush           = 1'b0;
		ovf_inject_msg1.ts                 = etip_ts_t'(ts_value);
		ovf_inject_msg1.sub.cf.sync_reason = nexus_sync_reason_e'(NEXUS_SYNC_FIFO_OVERRUN);
		ovf_inject_msg1.sub.cf.itype       = OTHER;
		// FADDR for the injected sync = address of the NEXT instruction to
		// retire after the last observed retirement. This is where the CPU
		// resumes execution from the encoder's point of view; landing the
		// decoder anchor here (rather than at PrevIAddr, the last RETIRED
		// iaddr) avoids re-walking the last retired instruction. That last
		// instruction may be a BD / JI in PCInfo whose direction or target
		// the decoder has no way to resolve at this anchor (its HIST bit
		// or IBH UADDR was either dropped upstream or is part of state
		// we've already reset).
		//
		// Instruction size in bytes = 2 * 2^ilastsize (ilastsize is
		// log2(halfwords); 2 bytes per halfword). For RV32I ilastsize=1 -> 4
		// bytes; for RVC ilastsize=0 -> 2 bytes.
		// Block ingress: the successor of a BLOCK is iaddr + 2*iretire, which
		// PrevIAddr + size cannot express (PrevIAddr is the block START). The
		// register below carries it; without CT_EN_BLOCK_TIP it has no driver
		// and no fanout, so it trims away and the expression is the historical one.
		ovf_inject_msg1.sub.cf.iaddr       = CT_EN_BLOCK_TIP
			? PrevIAddrAfter
			: PrevIAddr + (tip_iaddr_t'(2) << PrevIlastsize);
		ovf_inject_msg1.sub.cf.icnt        = '0;
		ovf_inject_msg1.sub.cf.btype       = NEXUS_BTYPE_IBRANCH;
		ovf_inject_msg1.sub.cf.rcode       = NEXUS_RCODE_NONE;
	end

	if (!CT_ETIP_SERIALIZE) begin : genEtipParallel
		// Historical arrangement: the whole beat (up to P slots) is presented
		// at once; the compacting CVS FIFO stores P entries per slot.
		cvsink_if #(.T(etip_msg_struct_t), .P(ETIP_PAR_MSG)) etip_cvs_raw_d (.clk, .rst);
		cvsink_if #(.T(etip_msg_struct_t), .P(ETIP_PAR_MSG)) etip_cvs_d     (.clk, .rst);
		assign etip_cvs_raw_d.d   = EtipMsg;
		assign etip_cvs_raw_d.cnt = MsgId;
		assign etip_sink_overflow_now = etip_cvs_d.full;
		// No presentation skid in the parallel arrangement — accepted beats
		// are already past the injector, marker order is FIFO order.
		assign etip_ovf_pending = 1'b0;

		ovf_injector #(
			.T       (etip_msg_struct_t)
		) etip_ovf_injector (
			.clk, .rst,
			.isnk        (etip_cvs_raw_d),
			.osnk        (etip_cvs_d),
			.inject_d0   (ovf_inject_msg0),
			.inject_d1   (ovf_inject_msg1),
			.inject_second_valid(1'b1),
			.force_inject(sideband_ovf_drop),
			// Anchor validity: PrevIAddr+size only names the next retire
			// address when the last retire was NOT a taken CF change. The
			// emission cycle itself must not retire a CF either: its beat is
			// still dropping (episode window), and the anchor sampled this
			// cycle would sit BEFORE that silently lost flow change — the
			// decoder would walk straight across it (post-anchor silent CF
			// loss, natural-overflow fix 2026-07-22).
			// A NOT_TAKEN_BRANCH retire in the emission cycle is the same
			// poison in BP/HTM mode (seen on KV260 captures as the
			// "recovery anchor" variant): its outcome
			// beat is still dropping, yet the anchor sampled this cycle
			// points AT the branch. The decoder (BpInit at SYNC==7) walks it
			// as the first post-anchor branch and consumes an outcome the
			// encoder never counted — the board stream shows the resulting
			// BCNT off-by-one verbatim (good recoveries at the same anchor:
			// first VendorBP BCNT=1; the poisoned one: BCNT=0, and the
			// decoder inverts the ANCHOR branch instead of the real
			// mispredict, det-pair_a 0x8d8 -> 0x970 against 24/24 refs).
			// Traps are the third case of the same assumption: from the trap
			// marker beat until the handler retire, PrevIAddr+size points at
			// the trapping instruction, which NEVER retires -- so hold there
			// too.
			.inject_hold (PrevRetireWasCf || PrevEventWasTrap
			              || (tip.itype == EXCEPTION_TRAP) || (tip.itype == INTERRUPT)
			              || (tip.iretire && (HasChangedControlFlow(tip.itype)
			                                  || (tip.itype == NOT_TAKEN_BRANCH)))),
			.clear       (cs_tip.trTeTipFifoNumOverflowsClear),
			.dropping    (etip_ovf_dropping),
			.inject_done (etip_ovf_inject_done),
			// Parallel arrangement presents REGISTERED beats (MsgId) and
			// cannot retract them; the one-beat discard window at inject
			// entry remains here (documented residual, serialize-only fix).
			.busy        (),
			.discard_cnt (etip_ovf_discard_cnt)
		);

		cvs_cdc_fifo2 #(
			.T  (etip_msg_struct_t),
			.P  (ETIP_PAR_MSG),                         // max # of T elements @ input (profile-dependent)
			.PO (1),                                    // max # of T elements @ output
			.CVS_MIN_DEPTH (ETIP_CVS_FIFO_DEPTH),
			.CDC_MIN_DEPTH (ETIP_CDC_FIFO_DEPTH),
			.CVS_FIFO_STYLE (CT_ETIP_FIFO_STYLE),   // "auto": total-bits heuristic
			.CDC_FIFO_STYLE (CT_ETIP_FIFO_STYLE),
			.SINGLE_CLK     (CT_SINGLE_CLOCK), // no gray-pointer CDC in 1-clk builds
			.SAFE_RESETS(1))                            // Ensure resets are safe: must be set to '1' explicitly
		etip_cvs_cdc_fifo(
			.d (etip_cvs_d),
			.q (etip_q),
			.cvs_fill (etip_cvs_fill)
		);
	end
	else begin : genEtipSerial
		// M-Serialize (FINDINGS_etip_collisions §3): accept one slot per
		// cycle into a single-entry-wide FIFO; a small skid queue absorbs
		// the multi-slot beats (pre-drain+CF, +DF/DAQ in full profiles).
		// Sustained rates stay <= 1 event/instruction (structural bound),
		// so the queue only ever holds transients; a beat whose slots do
		// not fit is dropped WHOLE (mirrors the parallel drop semantics,
		// keeps the next_iaddr pairing rules intact) and the ovf_injector
		// emits ERROR + FIFO_OVERRUN resync via force_inject.
		// Message ORDER and per-message ts (stamped at build) are identical
		// to the parallel arrangement -- the byte stream does not change.
		localparam int unsigned SKID = 4;
		localparam int unsigned SKID_CNT_W = $clog2(SKID + 1);

		cvsink_if #(.T(etip_msg_struct_t), .P(1)) etip_ser_raw_d (.clk, .rst);
		cvsink_if #(.T(etip_msg_struct_t), .P(1)) etip_ser_d     (.clk, .rst);

		etip_msg_struct_t          SkidQ [SKID];
		logic [SKID_CNT_W-1:0]     SkidCnt = '0;

		// Dequeue: present the head whenever the FIFO has room and the
		// injector is not mid-inject. Gating on the REGISTERED inject
		// state (not the combinational `dropping`, which feeds back
		// through isnk.cnt) keeps the path loop-free. Without the
		// mid-inject gate a presented head is DISCARDED by the injector --
		// but its CF already wrote a next_iaddr sideband entry when it was
		// queued, so every such discard orphans one entry and msg_gen
		// pairs all later CFs with their successor's address (measured:
		// post-recovery DirectBranchSync FADDR = the NEXT jump's target).
		//
		// STREAM-ORDER RULE (natural-overflow fix 2026-07-22, found via
		// tests/overflow/02_natural_overflow + the MBV KV260 jalr storm):
		// the marker pair must NOT be injected while accepted beats still
		// wait in the skid — the injector sits BETWEEN skid and FIFO, so an
		// immediate force_inject makes ERROR+SYNC overtake up to SKID
		// already-accepted messages. The decoder then sees the (late)
		// recovery anchor followed by PRE-anchor messages and desyncs
		// ("resolved source ... to a non-indirect instruction"). Instead a
		// drop event arms OvfPending: every further beat of the episode
		// keeps dropping (covered by the same owed ERROR), the skid drains
		// first, and only at SkidCnt==0 does force_inject fire — the pair
		// lands in stream order and the anchor (sampled combinationally at
		// emission) covers the whole episode. Non-overflow streams never
		// arm OvfPending: byte-identical.
		logic OvfPending = 1'b0;
		uwire InjectorBusy;
		uwire deq = (SkidCnt != 0) && !etip_ser_d.full && !InjectorBusy;
		assign etip_ser_raw_d.d[0] = SkidQ[0];
		assign etip_ser_raw_d.cnt  = deq ? 1'b1 : 1'b0;

		// Free slots available for THIS beat's messages (after the dequeue
		// committed in the same cycle).
		uwire [SKID_CNT_W:0] skid_free = (SKID_CNT_W+1)'(SKID) - SkidCnt + (deq ? 1'b1 : 1'b0);
		assign etip_sink_overflow_now = (skid_free < {1'b0, msg_id_next});

		// Episode latch: set on any drop event (skid overflow OR sideband
		// guard), cleared when the last marker element goes out
		// (inject_done samples the anchor — any drop in that same cycle
		// re-arms for a follow-up pair). Loop-free: force_inject depends
		// only on the REGISTERED OvfPending and SkidCnt.
		always_ff @(posedge clk) begin
			if (rst) begin
				OvfPending <= 1'b0;
			end
			else begin
				OvfPending <= (OvfPending && !etip_ovf_inject_done)
					|| etip_ovf_drop_now || sideband_ovf_drop;
			end
		end

		always_ff @(posedge clk) begin
			if (rst) begin
				SkidCnt          <= '0;
			end
			else begin
				automatic logic [SKID_CNT_W-1:0] cnt_after;
				automatic etip_msg_struct_t      q_new [SKID];
				automatic int unsigned           n_new;
				cnt_after = SkidCnt - (deq ? 1'b1 : 1'b0);
				for (int i = 0; i < SKID; i++) begin
					q_new[i] = (deq && (i < SKID-1)) ? SkidQ[i+1] : SkidQ[i];
				end
				// Whole-beat enqueue (or whole-beat drop -- bookkeeping for
				// the drop already ran in the shared comb block above).
				// OvfPending extends the drop to the whole episode: once a
				// beat was lost, every later beat before the marker pair
				// must drop too (its ICNT/HIST would span the gap and is
				// undecodable), all covered by the one owed ERROR.
				n_new = (etip_ovf_drop_now || etip_ovf_dropping || OvfPending) ? 0 : 32'(msg_id_next);
				for (int j = 0; j < ETIP_PAR_MSG; j++) begin
					if ((j < n_new) && ((32'(cnt_after) + j) < SKID)) begin
						q_new[32'(cnt_after) + j] = etip_msg_next[j];
					end
				end
				for (int i = 0; i < SKID; i++) begin
					SkidQ[i] <= q_new[i];
				end
				SkidCnt <= cnt_after + SKID_CNT_W'(n_new);
			end
		end

		ovf_injector #(
			.T          (etip_msg_struct_t),
			// etip_ser_d is a P=1 sink (1-bit cnt): the ERROR + resync
			// marker pair MUST be injected over two cycles -- a combined
			// cnt=2 truncates to 0 and both markers are lost silently.
			.SEQ_INJECT (1)
		) etip_ovf_injector (
			.clk, .rst,
			.isnk        (etip_ser_raw_d),
			.osnk        (etip_ser_d),
			.inject_d0   (ovf_inject_msg0),
			.inject_d1   (ovf_inject_msg1),
			.inject_second_valid(1'b1),
			// Skid overflow is detected composer-side (the injector never
			// sees FIFO-full drops here because presentation is gated) --
			// force_inject fires only once the episode latch is set AND the
			// skid has DRAINED (stream order, see OvfPending above): the
			// marker pair then lands behind every accepted message.
			// Registered sources only: loop-free by construction.
			.force_inject(OvfPending && (SkidCnt == '0)),
			// Anchor validity: PrevIAddr+size only names the next retire
			// address when the last retire was NOT a taken CF change. The
			// emission cycle itself must not retire a CF either: its beat is
			// still dropping (episode window), and the anchor sampled this
			// cycle would sit BEFORE that silently lost flow change — the
			// decoder would walk straight across it (post-anchor silent CF
			// loss, natural-overflow fix 2026-07-22).
			// Same poison for a NOT_TAKEN_BRANCH retire in the emission
			// cycle (the "recovery anchor" variant seen on KV260 captures):
			// its outcome beat is still dropping while the
			// anchor points AT the branch — the decoder walks it as first
			// post-anchor branch and consumes an outcome the encoder never
			// counted (board stream: first VendorBP after the poisoned
			// anchor carries BCNT=0 where the eleven good recoveries at the
			// SAME anchor address carry BCNT=1). See the parallel-arm
			// comment above for the full forensics chain.
			// Traps are the third case of the same assumption: from the trap
			// marker beat until the handler retire, PrevIAddr+size points at
			// the trapping instruction, which NEVER retires -- so hold there
			// too.
			.inject_hold (PrevRetireWasCf || PrevEventWasTrap
			              || (tip.itype == EXCEPTION_TRAP) || (tip.itype == INTERRUPT)
			              || (tip.iretire && (HasChangedControlFlow(tip.itype)
			                                  || (tip.itype == NOT_TAKEN_BRANCH)))),
			.clear       (cs_tip.trTeTipFifoNumOverflowsClear),
			.dropping    (etip_ovf_dropping),
			.inject_done (etip_ovf_inject_done),
			.busy        (InjectorBusy),
			.discard_cnt (etip_ovf_discard_cnt)
		);

		cvs_cdc_fifo2 #(
			.T  (etip_msg_struct_t),
			.P  (1),                                    // serialized: ONE entry per slot
			.PO (1),
			.CVS_MIN_DEPTH (ETIP_CVS_FIFO_DEPTH),
			.CDC_MIN_DEPTH (ETIP_CDC_FIFO_DEPTH),
			.CVS_FIFO_STYLE (CT_ETIP_FIFO_STYLE),
			.CDC_FIFO_STYLE (CT_ETIP_FIFO_STYLE),
			.SINGLE_CLK     (CT_SINGLE_CLOCK),
			.SAFE_RESETS(1))
		etip_cvs_cdc_fifo(
			.d (etip_ser_d),
			.q (etip_q),
			.cvs_fill (etip_cvs_fill)
		);

		assign etip_ovf_pending = OvfPending;

		// pragma translate_off
		// The whole-beat drop guarantee must hold: after the enqueue there
		// can never be more than SKID entries in flight.
		always @(posedge clk) begin
			if (!rst) begin
				assert (SkidCnt <= SKID_CNT_W'(SKID))
					else $fatal(1, "*** ERROR (%m): SkidCnt=%0d overflowed SKID=%0d", SkidCnt, SKID);
				// Stream-order rule: the injector may only leave Forwarding
				// with an empty skid — a marker overtaking accepted beats is
				// exactly the natural-overflow desync (2026-07-22).
				assert (!(InjectorBusy && (SkidCnt != '0)))
					else $fatal(1, "*** ERROR (%m): marker injection with %0d accepted beats still in the skid", SkidCnt);
			end
		end
		// pragma translate_on
	end

	// Saturate the 32-bit discard counter into the 15-bit CSR field.
	assign cs_tip.trTeTipFifoNumOverflows = (|etip_ovf_discard_cnt[31:15])
		? 15'h7FFF
		: etip_ovf_discard_cnt[14:0];

	// ----------------------------------------------------------------
	// Data-trace drop policy state (P7). The watermark verdict is REGISTERED:
	// etip_cvs_fill comes out of the very FIFO whose write count df_drop_now
	// influences, so a combinational compare would close a loop through the
	// FIFO's write port. One cycle of lag is irrelevant for a threshold that
	// sits a quarter of the depth below full.
	// ----------------------------------------------------------------
	if (CT_EN_DF_DROP) begin : genDfDrop
		always_ff @(posedge clk) begin
			if (rst) begin
				DfDropArm     <= 1'b0;
				DfDropEpisode <= 1'b0;
			end
			else begin
				DfDropArm <= cs_tip.trTeDataDropEna
				          && (etip_cvs_fill >= $bits(etip_cvs_fill)'(CT_DF_DROP_WATERMARK));
				// Episode latch: armed by the first suppressed DF, released
				// once the queue has drained back below the watermark (or the
				// policy was disarmed) -- so a long backpressure phase costs
				// exactly ONE marker, and a second phase gets its own.
				if (!DfDropArm)         DfDropEpisode <= 1'b0;
				else if (df_drop_now)   DfDropEpisode <= 1'b1;
			end
		end
	end
	else begin : genNoDfDrop
		always_comb begin
			DfDropArm     = 1'b0;
			DfDropEpisode = 1'b0;
		end
	end

	// ----------------------------------------------------------------
	// Sticky-status event strobes (P7/G12) towards the CSR shim, which turns
	// them into the RW1C bits trTeControl.InstStallOrOverflow /
	// trTeDataControl.{DataStallOrOverflow,DataDrop}. Pure status -- neither
	// signal touches the message path.
	//   overflow : the cycle the injector actually emits its marker pair, i.e.
	//              "an overflow message was generated" (the exact wording of
	//              the standard status bit).
	//   df drop  : the first suppressed DF of a drop episode (one strobe per
	//              episode -- the same qualification as the wire marker, but
	//              independent of whether that marker's beat survived).
	// ----------------------------------------------------------------
	logic InstOverflowEventQ = 1'b0;
	logic DataDropEventQ     = 1'b0;
	always_ff @(posedge clk) begin
		if (rst) begin
			InstOverflowEventQ <= 1'b0;
			DataDropEventQ     <= 1'b0;
		end
		else begin
			InstOverflowEventQ <= etip_ovf_inject_done;
			DataDropEventQ     <= CT_EN_DF_DROP && df_drop_now && !DfDropEpisode;
		end
	end
	assign cs_tip.trTeInstOverflowEvent = InstOverflowEventQ;
	assign cs_tip.trTeDataDropEvent     = DataDropEventQ;

	// High-water watermark of etip_cvs_d fill level (tip_clk domain). Cleared by
	// SW via trTeTipFifoMaxFillClear (level, synchronised into tip_clk).
	// CT_EN_ETIP_WATERMARK=0 (O1 interface diet): the CSR field reads 0 and
	// the whole fill chain (FIFO stats counters -> cvs_fill -> compare) loses
	// its only synthesis consumer and trims away; the end-of-sim report keeps
	// working through the sim-only shadow below.
	if (CT_EN_ETIP_WATERMARK) begin : genEtipWatermark
		logic [14:0] MaxFillTip = '0;
		always_ff @(posedge clk) begin
			if (rst || cs_tip.trTeTipFifoMaxFillClear) begin
				MaxFillTip <= '0;
			end
			else if (15'(etip_cvs_fill) > MaxFillTip) begin
				MaxFillTip <= 15'(etip_cvs_fill);
			end
		end
		assign cs_tip.trTeTipFifoMaxFill = MaxFillTip;
	end
	else begin : genNoEtipWatermark
		assign cs_tip.trTeTipFifoMaxFill = '0;
	end

	// eTIP-CVS-FIFO fill-level histogram (I-02, 2026-07-20):
	// CT_FIFO_HIST_BINS saturating 16-bit counters; counter b increments on
	// the UPWARD crossing of fill level (b+1)*DEPTH/BINS (the top bin fires
	// at DEPTH = completely full). Answers the FIFO sizing question
	// empirically -- distribution of reached levels, complementing the
	// MaxFill watermark. tip_clk only, deliberately NO CDC anywhere (cs
	// export is plain wires): read/clear contract is "trace quiescent"
	// (trTeControl.Enable=0). The counter arithmetic carries (* use_dsp *)
	// so the increments map into (otherwise unused) DSP48 slices instead of
	// fabric LUTs. Compiled out -> counters, compare chain and the CSR
	// registers (RDL register-omission) all vanish; the cs wires tie 0.
	if (CT_EN_FIFO_HIST) begin : genEtipFillHist
		// pragma translate_off
		initial begin
			if ((CT_FIFO_HIST_BINS % 2) || (CT_FIFO_HIST_BINS < 2) || (CT_FIFO_HIST_BINS > 64)) begin
				$fatal(1, "*** ERROR (%m): CT_FIFO_HIST_BINS=%0d must be even and in 2..64", CT_FIFO_HIST_BINS);
			end
			if (ETIP_CVS_FIFO_DEPTH % CT_FIFO_HIST_BINS) begin
				$fatal(1, "*** ERROR (%m): CT_FIFO_HIST_BINS=%0d must divide ETIP_CVS_FIFO_DEPTH=%0d",
					CT_FIFO_HIST_BINS, ETIP_CVS_FIFO_DEPTH);
			end
		end
		// pragma translate_on
		(* use_dsp = "yes" *)
		logic [CT_FIFO_HIST_BINS-1:0][15:0] HistCnt  = '0;
		logic [$bits(etip_cvs_fill)-1:0]    PrevFill = '0;
		always_ff @(posedge clk) begin
			if (rst || cs_tip.trTeTipFifoHistClear) begin
				HistCnt  <= '0;
				PrevFill <= '0;
			end
			else begin
				PrevFill <= etip_cvs_fill;
				for (int b = 0; b < CT_FIFO_HIST_BINS; b++) begin
					// threshold for bin b: (b+1)*DEPTH/BINS (elab-checked to
					// be an exact integer, see above).
					automatic int unsigned thr = (b + 1) * ETIP_CVS_FIFO_DEPTH / CT_FIFO_HIST_BINS;
					if ((32'(PrevFill) < thr) && (32'(etip_cvs_fill) >= thr)
					    && (HistCnt[b] != 16'hFFFF)) begin
						HistCnt[b] <= HistCnt[b] + 1'b1;
					end
				end
			end
		end
		assign cs_tip.trTeTipFifoHist = HistCnt;
	end
	else begin : genNoEtipFillHist
		assign cs_tip.trTeTipFifoHist = '0;
	end

	// pragma translate_off
	// Sim-only watermark shadow: keeps the end-of-sim depth-tuning report
	// (and its clear semantics) identical whether or not the CSR chain is in
	// the netlist.
	logic [14:0] MaxFillSim = '0;
	always_ff @(posedge clk) begin
		if (rst || cs_tip.trTeTipFifoMaxFillClear) begin
			MaxFillSim <= '0;
		end
		else if (15'(etip_cvs_fill) > MaxFillSim) begin
			MaxFillSim <= 15'(etip_cvs_fill);
		end
	end
	// pragma translate_on

	assign sync.done        = 0;
	assign internal_delay   = 1;

	// pragma translate_off
	// Slot-demand watermark: the MEASURED counterpart of the ETIP_PAR_MSG
	// bound. Sampled at the same instant as the functional `MsgId` register
	// below, so it is the per-beat slot count the design really commits --
	// not a combinational transient. It is what turns "the beat needs N
	// slots" from an argument into a number (P4 audit finding A-2); the
	// end-of-sim line below reports it next to the FIFO watermark.
	// The BOUND itself is checked where it is allocated, by the immediate
	// assertion a_p4_slot_bound in the always_comb above.
	logic [$clog2(ETIP_PAR_MSG+2)-1:0] MaxSlotsSim = '0;
	always_ff @(posedge clk) begin
		if (rst)
			MaxSlotsSim <= '0;
		else if (msg_id_next > MaxSlotsSim)
			MaxSlotsSim <= msg_id_next;
	end

	// End-of-simulation watermark report: measured basis for the M2
	// FIFO-depth tuning (ETIP_CVS/CDC_FIFO_DEPTH in ct_pkg). MaxFillTip is
	// the same value SW reads via trTeTipFifoMaxFill.
	final begin
		$display("*** INFO (%m): eTIP CVS FIFO max fill = %0d of %0d (P=%0d)",
			MaxFillSim, ETIP_CVS_FIFO_DEPTH, ETIP_PAR_MSG);
		$display("*** INFO (%m): eTIP max slots per beat = %0d of ETIP_PAR_MSG=%0d",
			MaxSlotsSim, ETIP_PAR_MSG);
	end

	// eTIP slot balance: permanent simulation telemetry. The end-of-run
	// identity (raised == dropped + consumed + in-flight) is what proved the
	// serialize-vs-direct-out throughput finding, where the tail was
	// truncated although zero slots were dropped. It stays as a final INFO so
	// future eTIP rework can separate silent loss from an in-flight remainder
	// without adding instrumentation first.
	int unsigned EtipSlotsRaised   = 0;
	int unsigned EtipSlotsDropped  = 0;
	int unsigned EtipQConsumed     = 0;
	int unsigned EtipNiaWr         = 0;
	int unsigned EtipNiaRd         = 0;
	always_ff @(posedge clk) begin
		if (!rst) begin
			// Mirror of the enqueue condition (n_new in the serialize branch,
			// injector view in the parallel one): raised = actually enqueued,
			// dropped = lost to the overflow episode incl. the OvfPending
			// drain window.
			if (!(etip_ovf_drop_now || etip_ovf_dropping || etip_ovf_pending))
				EtipSlotsRaised <= EtipSlotsRaised + 32'(msg_id_next);
			else
				EtipSlotsDropped <= EtipSlotsDropped + 32'(msg_id_next);
			if (etip_q.valid && etip_q.ack)
				EtipQConsumed <= EtipQConsumed + 1;
			if (next_iaddr_d.wr && !next_iaddr_d.full)
				EtipNiaWr <= EtipNiaWr + 1;
			if (next_iaddr_q.valid && next_iaddr_q.ack)
				EtipNiaRd <= EtipNiaRd + 1;
		end
	end
	final begin
		// delta = raised - dropped - consumed. Positive means an in-flight
		// remainder; NEGATIVE means ovf_injector insertions, since its
		// ERROR/resync messages are consumed but never "raised" on the
		// composer side -- the overflow tests exercise exactly that.
		$display("*** INFO (%m): eTIP slot balance: raised=%0d dropped=%0d consumed=%0d delta=%0d | nia wr=%0d rd=%0d | discard_cnt=%0d",
			EtipSlotsRaised, EtipSlotsDropped, EtipQConsumed,
			$signed(EtipSlotsRaised) - $signed(EtipSlotsDropped) - $signed(EtipQConsumed),
			EtipNiaWr, EtipNiaRd, etip_ovf_discard_cnt);
	end
	// pragma translate_on

	// ----------------------------------------------------------------
	// Standing invariants (SVA, simulation only). Each property encodes a
	// contract that a hardware robustness campaign established the expensive
	// way; as an assertion it runs in EVERY simulation and turns a regression
	// red immediately instead of only on the board.
	// ----------------------------------------------------------------
	// pragma translate_off
`ifndef SYNTHESIS
	// Helper view: does the registered slot set carry an "ordinary" CF eTIP,
	// that is, neither a marker nor a sync?
	function automatic logic etip_has_plain_cf(input etip_msg_struct_t [ETIP_PAR_MSG-1:0] slots);
		for (int i = 0; i < ETIP_PAR_MSG; i++) begin
			if (slots[i].sub_type == SUB_MSG_CF
			    && slots[i].sub.cf.rcode == NEXUS_RCODE_NONE
			    && slots[i].sub.cf.sync_reason == NEXUS_SYNC_NONE)
				return 1'b1;
		end
		return 1'b0;
	endfunction

	// Helper view (P4): does the registered slot set carry a DAQ message?
	function automatic logic etip_has_daq(input etip_msg_struct_t [ETIP_PAR_MSG-1:0] slots);
		for (int i = 0; i < ETIP_PAR_MSG; i++) begin
			if (slots[i].sub_type == SUB_MSG_DAQ)
				return 1'b1;
		end
		return 1'b0;
	endfunction

	// Helper view (P4): slot index of the first OTHER message with the given
	// TCODE, or -1 when the beat carries none.
	function automatic int etip_slot_of(input etip_msg_struct_t [ETIP_PAR_MSG-1:0] slots,
	                                    input nexus_tcode_e tcode);
		for (int i = 0; i < ETIP_PAR_MSG; i++) begin
			if (slots[i].sub_type == SUB_MSG_OTHER && slots[i].sub.other.tcode == tcode)
				return i;
		end
		return -1;
	endfunction

	// I1 (pause-edge class): while the resume hold is active NO ordinary CF
	// eTIP may be produced -- only the sync anchor beat ends the hold. A
	// violation means messages without a decodable position ahead of the
	// re-anchor, the failure a KV260 capture showed as five VendorBP messages
	// with BCNT=0.
	a_i1_resume_gate: assert property (@(posedge clk) disable iff (rst)
		(ResumeHold && (sync.reason == NEXUS_SYNC_NONE)) |=> !etip_has_plain_cf(EtipMsg))
		else $error("%m I1: CF eTIP during ResumeHold (pause-edge contract)");

	// I2: while tracing is paused (aligned qualifier low) no ordinary CF eTIP
	// is produced -- only markers (correlation / drain) are allowed.
	a_i2_pause_quiet: assert property (@(posedge clk) disable iff (rst)
		(!inst_trace_active) |=> !etip_has_plain_cf(EtipMsg))
		else $error("%m I2: CF eTIP during an instruction-tracing pause");

	// I3: on the trace-off correlation the implicit-return stack is empty,
	// because calls and returns during a pause are invisible. Since W2 the
	// same holds for a CF-filter region exit -- it emits the SAME correlation
	// and the instructions it hides are just as invisible, so the property
	// covers both sources instead of silently exempting the new one.
	generate if (CT_EN_IMPLICIT_RETURN) begin : genI3
		a_i3_corr_clears_retstack: assert property (@(posedge clk) disable iff (rst)
			((DoCorrDisable || DoCorrFilterExit) && DoFlushAck) |-> (RetSp == '0))
			else $error("%m I3: RetStack not empty at the pause edge");
	end endgenerate

	// I4 (pairing invariant behind three separate findings): a next_iaddr
	// capture may only happen when a CF is waiting for one.
	a_i4_capture_owed: assert property (@(posedge clk) disable iff (rst)
		next_iaddr_wr_next |-> PendingCfNextIaddr)
		else $error("%m I4: next_iaddr capture without an outstanding CF");

	// I5 (gap re-anchor is side-effect free; counter-proof for the decoder's
	// "Not enough entries on callstack"): a TRACE_ENABLE / EXIT_* sync on a
	// call or return retire leaves the stack unchanged.
	generate if (CT_EN_IMPLICIT_RETURN) begin : genI5
		a_i5_gap_anchor_no_stack: assert property (@(posedge clk) disable iff (rst)
			(tip.iretire
			 && (sync.reason inside {NEXUS_SYNC_TRACE_ENABLE, NEXUS_SYNC_EXIT_FROM_DEBUG,
			                         NEXUS_SYNC_EXIT_FROM_POWERDOWN, NEXUS_SYNC_EXIT_FROM_SYS_RST})
			 && (tip.itype inside {INFERRABLE_CALL, UNINFERABLE_CALL, RETURN})
			 // Mask coincidence with the LEGITIMATE clears (overflow anchor,
			 // pause edge), where RetSp is allowed to change -- to 0:
			 && !etip_ovf_inject_done && !DoCorrDisable)
			|=> (RetSp == $past(RetSp)))
			else $error("%m I5: gap re-anchor modified the RetStack");
	end endgenerate

	// P4 slot-demand telemetry (measured basis of the ETIP_PAR_MSG cost
	// argument, audit finding A-2): how often does a SINGLE beat carry the
	// Device ID slot AND the Config slot? Both fire on the trace-start edge,
	// so this is the beat identity behind "the Device ID needs a slot of its
	// own on top of the config slot" -- as a number in the simulation log,
	// not as an argument. `EtipMsg` / `MsgId` are the REGISTERED slot set and
	// its count, i.e. exactly what the beat committed.
	generate if (CT_EN_DEVICE_ID && CT_EN_CONFIG_MSG) begin : genP4Tele
		int unsigned DevIdCfgBeats = 0;
		always_ff @(posedge clk) begin
			if (!rst && (etip_slot_of(EtipMsg, NEXUS_MSG_DEVICE_ID) >= 0)
			         && (etip_slot_of(EtipMsg, NEXUS_MSG_VENDOR_CONFIG) >= 0)) begin
				DevIdCfgBeats <= DevIdCfgBeats + 1;
				$display("*** INFO (%m): ONE beat carries Device ID (slot %0d) AND Config (slot %0d), beat uses %0d of %0d slots",
					etip_slot_of(EtipMsg, NEXUS_MSG_DEVICE_ID),
					etip_slot_of(EtipMsg, NEXUS_MSG_VENDOR_CONFIG), MsgId, ETIP_PAR_MSG);
			end
		end
		final begin
			$display("*** INFO (%m): beats with Device ID AND Config in the same beat = %0d",
				DevIdCfgBeats);
		end
	end endgenerate

	// The P4 slot bound does NOT live here: `msg_id_next` is an always_comb
	// variable, and a concurrent property samples the preponed value, which
	// has long fallen back to the default. The check is an IMMEDIATE
	// assertion at the allocation site (a_p4_slot_bound in the always_comb),
	// the measurement is MaxSlotsSim. Every property in this block that
	// looks at a signal must therefore keep to REGISTERED state (EtipMsg,
	// RetSp, ResumeHold) or to module inputs (tip, sync) -- see the audit
	// note in doc/integration.adoc#p4-cost.

	// I10 (P4 slot sharing, cost argument): the watchpoint arm and the DAQ
	// arm are selected by the SAME beat qualifier (act_cap_st.valid) and by
	// MUTUALLY EXCLUSIVE command codes, so a watchpoint slot always takes
	// the place of the DAQ slot the same beat would otherwise have raised.
	// This is why CT_EN_WATCHPOINT_MSG does NOT widen ETIP_PAR_MSG. The
	// property watches the registered slot set, where both messages are
	// visible as OTHER/DAQ sub-types.
	generate if (CT_EN_WATCHPOINT_MSG) begin : genI10
		a_p4_wp_daq_exclusive: assert property (@(posedge clk) disable iff (rst)
			(etip_slot_of(EtipMsg, NEXUS_MSG_WATCHPOINT) >= 0)
			|-> !etip_has_daq(EtipMsg))
			else $error("%m I10: watchpoint and DAQ slot in the SAME beat -- the shared-slot cost argument is void");
	end endgenerate

	// I9 (P4 / DO-1 order contract): whenever a beat carries BOTH the Device
	// ID and the Config trigger, Device ID must sit in the LOWER slot --
	// slot order is emission order, so this is the on-wire order
	// "Device ID before Config before the first synchronizing message".
	generate if (CT_EN_DEVICE_ID && CT_EN_CONFIG_MSG) begin : genI9
		a_p4_devid_before_cfg: assert property (@(posedge clk) disable iff (rst)
			etip_slot_of(EtipMsg, NEXUS_MSG_DEVICE_ID) >= 0
			 && etip_slot_of(EtipMsg, NEXUS_MSG_VENDOR_CONFIG) >= 0
			|-> etip_slot_of(EtipMsg, NEXUS_MSG_DEVICE_ID)
			     < etip_slot_of(EtipMsg, NEXUS_MSG_VENDOR_CONFIG))
			else $error("%m I9: Device ID must precede the Config message in the beat");
	end endgenerate

	// I11 (W2, CF-filter gap): between leaving the filter region and the
	// re-anchor, NO ordinary CF eTIP may be produced. Same contract as I1/I2,
	// one level further in: after the region-exit correlation the decoder has
	// no position, so a plain control-flow message would be a message it
	// cannot place -- exactly the failure mode that made a filtered stream
	// undecodable before this feature existed. `FiltGapOpen` is a
	// simulation-only shadow of that window (the RTL itself needs no such
	// register -- the filter keeps process_now low all by itself; the shadow
	// exists so the property can NAME the window).
	logic FiltGapOpen = 1'b0;
	always_ff @(posedge clk) begin
		if (rst) FiltGapOpen <= 1'b0;
		// V1 (2026-08-09): switching CF filtering OFF also ends the window.
		// Both the set and the clear term below are gated on `filt_anchor`,
		// i.e. on a NON-EMPTY filter selection. Software that leaves a region
		// and then writes trTeInstFilters = 0 (or clears the last filter's
		// Enable) therefore left this shadow stuck at 1 with no way back:
		// `region_entered` can never fire again once the qualifier is gone.
		// From that moment every ordinary CF eTIP -- all of them legitimate,
		// because process_now is no longer filter-gated -- fired I11.
		// MEASURED on tests/instruction/19_feature_matrix, which disables the
		// filter chain at the end of Ph.4: seven I11 errors, in Ph.7, Ph.8 and
		// Ph.10, i.e. three phases after the last filter write. Nobody had
		// seen them because that testbench had no runner (D1-F6); it has one
		// now (scripts/cli_featurematrix_test.sh), and the gate counts I11 at
		// zero. Simulation-only: the whole block is inside `ifndef SYNTHESIS`,
		// and FiltGapOpen drives nothing but this assertion.
		else if (!filt_anchor) FiltGapOpen <= 1'b0;
		else if (filt_anchor && cf_qualifier.hit_valid && cf_qualifier.region_exited)
			FiltGapOpen <= 1'b1;
		else if (filt_anchor && cf_qualifier.hit_valid && cf_qualifier.region_entered)
			FiltGapOpen <= 1'b0;
	end
	a_i11_filter_gap_quiet: assert property (@(posedge clk) disable iff (rst)
		FiltGapOpen |=> !etip_has_plain_cf(EtipMsg))
		else $error("%m I11: ordinary CF eTIP inside a CF-filter gap (no anchor yet)");
`endif
	// pragma translate_on

endmodule // ct_L23_preproc_composer_etip

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
