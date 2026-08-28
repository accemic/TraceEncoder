// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder layer 2 trace message generator (eTIP -> generic Nexus messages).
 *
 * @details
 *   Generates generic trace messages — oriented on Nexus message fields — from
 *   the eTIP input stream. One eTIP cycle can produce several messages, sent
 *   consecutively, and the module stalls under downstream backpressure. On an
 *   ATB flush (signalled via the TIP side channel) it emits a non-Nexus flush
 *   message that forces atb.afready. Understanding this module requires
 *   knowledge of the Nexus and ATB protocols.
 *
 *   Example: the initial TIP message forces a synchronization message followed
 *   by an ownership message.
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif
module ct_L2_msg_gen (
	input uwire logic                proc_clk,     // trace processing clock
	input uwire logic                proc_rst,     // reset
	ct_cs_procclk_if.slave           cs_proc,      // control / status interface

	// Input - Extended internal-ETIP message + next PC
	source_if.client                 etip_q,       // extended tip struct from FIFO
	source_if.client                 next_iaddr_q, // next iaddr from FIFO

	output nexus::nexus_msg_struct_t trace_msg,    // generic trace message output

	// Flow Control from Downstream
	input uwire logic                ready_in,     // if 0, do not output new data

	// trTeControl.Empty chain: 1 means no message output is presented AND no
	// (repeat-)compression substance is being held back. CurrICnt and Hist
	// deliberately do NOT count as "generated trace" -- they are accumulator
	// state, not a message that was produced but not yet emitted (the flush /
	// correlation path drains them before Empty becomes relevant).
	output uwire logic               msg_gen_idle
);
	import ct_pkg::*;
	import ct_etip_pkg::*;
	import tip_pkg::*;
	import nexus_vendor::*;
	import nexus::*;

	uwire etip_msg_struct_t       etip_msg     = etip_msg_struct_t'       (etip_q.q);
	uwire etip_cf_msg_struct_t    etip_cf      = etip_cf_msg_struct_t'    (etip_msg.sub.cf);
	uwire etip_df_msg_struct_t    etip_df      = etip_df_msg_struct_t'    (etip_msg.sub.df);
	uwire etip_daq_msg_struct_t   etip_daq     = etip_daq_msg_struct_t'   (etip_msg.sub.daq);
	uwire etip_other_msg_struct_t etip_other   = etip_other_msg_struct_t' (etip_msg.sub.other);

	// ICNT accumulator width: bounded by construction (drained via RCODE=0
	// once past MAX_NEXUS_ICNT <= 2^16-1, plus one composer segment of at
	// most the wide drain threshold) -- 18 bits hold the maximum with slack.
	localparam int unsigned ICNT_ACC_W = NEXUS_MSG_I_CNT_WIDTH_WIDE + 2;
	logic [ICNT_ACC_W-1:0]                  CurrICnt     = 0;  // current ICount
	// HIST registers are sized to the WIRE field (30 bit incl. stop bit),
	// not to the 192-bit generic max field width -- the window logic caps
	// the bit count at NEXUS_MSG_RDATA_WIDTH-1 data bits by construction.
	logic [NEXUS_MSG_RDATA_WIDTH-1:0]       Hist         = 1;  // Hist field (commercial version only)
	// Valid-bit count of the Hist window: bounded by the window-full drain at
	// NEXUS_MSG_RDATA_WIDTH-1 = 29 (partial-match reloads set at most
	// 1+2*shift = 5) -- 6 bits hold it with slack (was 32, resource pass 3).
	logic [5:0]                             HistCount    = 1;  // length of valid bits in Hist field (commercial version only)

	// Repeated-history compression (Accemic): with trTeInstEnRepeatedHistory
	// set, a full HIST pattern that would emit ResourceFull(RCODE=1) is
	// buffered here instead. An identical follow-up pattern only increments
	// the counter; the buffered run is emitted as a single ResourceFull with
	// RCODE=2 (HIST_OVERFLOW_REPEATED, rdata0=pattern, rdata1=count) -- or
	// plain RCODE=1 when the pattern occurred once -- when the pattern
	// changes or a PC-walking message must go out (see cf_repeat_drain_hold).
	// Matches the reference software encoder NexRvEnco (conf_Repeat & 2),
	// including the partial-pattern trim (NexRvEnco IsHistMatch_30_28,
	// re-derived for this 29-data-bit window as 28/27-bit trims below).
	// HistRepeatCnt == 0 means "buffer empty". HistRepeatShift is 0 for an
	// exact full-window run and s>0 for a trimmed run (pattern = 29-s data
	// bits; s LSBs of each window are carried into the next accumulation).
	logic [NEXUS_MSG_RDATA_WIDTH-1:0]       HistRepeatPrev  = '0;
	logic [31:0]                            HistRepeatCnt   = 0;
	logic [2:0]                             HistRepeatShift = 0;

	// RepeatBranch compression (Accemic, TCODE 30): an IndirectBranchHist
	// identical to the LAST EMITTED one (same HIST, same ICNT, same target)
	// is suppressed and counted; the run is closed by a RepeatBranch message
	// carrying the suppression count. NexRv replays its saved previous
	// message count times (NexRvDeco.c:1071-1090). HARD decoder constraint:
	// NexRv saves only msgFields[0..1] across the TCODE-30 parse -- ANY
	// intervening message clobbers the remembered IBH fields, so the count
	// must be drained BEFORE every other emission (including RCODE=0 drains,
	// unlike the repeated-history buffer) and LastIbhValid must be cleared
	// whenever any non-IBH message goes out.
	logic [31:0]                            RepeatBranchCnt = 0;
	logic                                   LastIbhValid    = 0;
	logic [NEXUS_MSG_RDATA_WIDTH-1:0]       LastIbhHist     = '0;
	logic [ICNT_ACC_W-1:0]                  LastIbhIcnt     = '0;
	tip_iaddr_t                             LastIbhAddr     = '0;
	// Replay soundness (P10 soak finding S-7, seed 1317011359): NexRv replays
	// the saved previous message VERBATIM, so a replayed TCODE-28 re-applies
	// its differential UADDR against the moved address reference -- correct
	// ONLY when that UADDR was 0 (then the reference sits at the target and
	// stays there through every replay). A TCODE-57 replay is always sound
	// (the cache index resolves the ABSOLUTE target, and no install can
	// happen between the 57 and its replays because any other emission
	// clears LastIbhValid). The old match (same HIST/ICNT/target alone)
	// collapsed two DIFFERENT calls with the same target into a repeat whose
	// head message carried UADDR!=0 -- the decoder then walked a stale loop
	// iteration and derailed ("resolved source ... to a non-indirect
	// instruction"). Only byte-identical messages may collapse (doc:
	// enhanced-features "Identical repeated IBH messages").
	logic                                   LastIbhReplayable = 0;
	// Mirror of the packer's Nexus address-compression reference (RefAddr in
	// ct_L2_nexus_formatter / ct_L2_compact_packer, identical tables): the
	// last transmitted program-trace address. Kept UNSHIFTED -- instruction
	// addresses have constant zero low bits, so unshifted equality is
	// equivalent to the packers' pre-shifted equality. Updated centrally at
	// the output handshake (the cycle the packer accepts the message and
	// moves its RefAddr). Needed because the UADDR of the message being
	// emitted is computed one stage downstream.
	tip_iaddr_t                             LastXmitAddr    = '0;

	// Jump-target-cache compression (Accemic, vendor TCODE 57): a plain
	// (BTYPE=IBRANCH) IndirectBranchHist whose target is already installed
	// in the 64-entry direct-mapped cache is emitted as VendorJTC carrying
	// the 6-bit index instead of the differential UADDR. The cache installs
	// on every EMITTED plain IBH (cache miss); the decoder mirrors exactly
	// that rule (NexRvDeco: learn on BTYPE=0 IBH, read-only on TCODE 57),
	// so both models stay bit-identical. Index = XOR fold over 6-bit address
	// slices -- far-apart targets (where JTC wins most) typically have
	// zero low bytes and would all collide on a plain [7:2] index.
	// Cleared at trace-off (correlation): a decoder starting at the next
	// session must never see an index it could not have learned.
	localparam int unsigned JTC_ENTRIES = ct_pkg::CT_JTC_ENTRIES; // pkg SSOT (advertised in config-message P3)
	tip_iaddr_t                             JtcCache [JTC_ENTRIES];
	logic [JTC_ENTRIES-1:0]                 JtcValid = '0;

	// Highest address bit the fold consumes. At 32 bit it is 25, i.e. the
	// historical four slices [7:2] [13:8] [19:14] [25:20] -- the fold has to
	// stay bit-identical there, so the width is a knob and not simply "all
	// bits". At 64 bit the remaining eleven slices join in: leaving them out
	// would make the index blind above bit 25, and under Sv39 the kernel/user
	// split lives entirely above it -- every kernel target would hash as if
	// its high half were zero and collide with the user-space target sharing
	// its low 24 bits. The last slice is short (bits 63:62) and enters
	// zero-extended.
	// DECODER MIRROR: NexRvDeco.c JtcIndex() must fold exactly this way,
	// switched by the ADDR64 capability bit (CAPS 23) it reads from the
	// config message. A one-bit disagreement desynchronizes the two caches
	// silently, which is why the fold is spelled out as a loop here rather
	// than as a hand-unrolled XOR chain.
	localparam int unsigned JTC_FOLD_MSB = ct_pkg::CT_ADDR64 ? 63 : 25;

	function automatic logic [5:0] jtc_fold(input tip_iaddr_t t);
		logic [5:0] h;
		logic [5:0] sl;
		h = '0;
		for (int i = 2; i <= JTC_FOLD_MSB; i += 6) begin
			sl = '0;
			for (int b = 0; b < 6; b++) begin
				if ((i + b) <= JTC_FOLD_MSB) sl[b] = t[i + b];
			end
			h = h ^ sl;
		end
		return h;
	endfunction

	uwire jtc_en = CT_EN_JTC && cs_proc.trTeInstEnJumpTargetCache;
	uwire tip_iaddr_t jtc_target = next_iaddr_q.q.addr;
	uwire [5:0] jtc_idx = jtc_fold(jtc_target);
	uwire jtc_hit = jtc_en && next_iaddr_q.valid
	                && JtcValid[jtc_idx] && (JtcCache[jtc_idx] == jtc_target);

	// Branch-prediction compression (Accemic, vendor TCODE 56): with
	// trTeInstEnBranchPrediction set, direct branches do not accumulate HIST
	// bits. Both sides run a bit-identical predictor (direct-mapped table of
	// 2^9 two-bit saturating counters, index = iaddr[10:2], init = weakly
	// not-taken, updated with the actual outcome of EVERY processed direct
	// branch). A correctly predicted branch is silent (PredCnt counts it);
	// the decoder resolves it from its own predictor while walking the ICNT
	// of whatever message eventually covers it. Only a MISPREDICT emits a
	// message: TCODE 56 with BCNT = PredCnt = correctly predicted branches
	// since the last PC-walking emission; the decoder eagerly walks BCNT
	// branches predictor-resolved plus ONE more inverted (RCODE-1/2-style
	// walk, no ICNT field, resourceFull-subtract convention). PredCnt
	// therefore resets on every PC-walking emission (IBH/57/sync/corr/56)
	// and NOT on ResourceFull drains (RCODE 0 does not walk; RCODE 1/2
	// walk only carried-over seed bits). Sync-carried branches keep the
	// existing 1-bit HIST seed path; the decoder consumes pending HIST
	// bits before consulting its predictor, updating it either way.
	// Mutually exclusive with RepeatedHistory/RepeatBranch (hard-gated
	// below). Table cleared at trace-off and on FIFO_OVERRUN recovery
	// (decoder mirrors both; overrun-dropped branches are never seen by
	// msg_gen nor walked by the decoder, so the models stay in lockstep).
	localparam int unsigned BP_ENTRIES = ct_pkg::CT_BP_ENTRIES; // pkg SSOT (advertised in config-message P3)
	// LUTRAM-friendly predictor storage (resource pass): entries carry an
	// EPOCH TAG instead of being clear-loop-reset (a reset/clear loop forces
	// flip-flops). "Clearing" the model (trace-off, FIFO overrun, reset)
	// bumps BpEpoch: entries with a stale tag READ as the init value
	// (weakly-not-taken 2'b01) -- bit-identical to a real clear. A
	// background scrubber rewrites one stale entry per idle cycle so a tag
	// value can never alias even after 2**BP_EPOCH_W clears.
	localparam int unsigned BP_EPOCH_W = 16;
	typedef struct packed {
		logic [BP_EPOCH_W-1:0] tag;
		logic [1:0]            ctr;
	} bp_entry_t;
	bp_entry_t                     PredTable [BP_ENTRIES];
	logic [BP_EPOCH_W-1:0]         BpEpoch = '0;
	logic [$clog2(BP_ENTRIES)-1:0] BpScrub = '0;
	logic [31:0]                   PredCnt = 0;
	initial for (int i = 0; i < BP_ENTRIES; i++) PredTable[i] = '{tag: '1, ctr: 2'b01};

	function automatic logic [1:0] bp_next(input logic [1:0] ctr, input logic taken);
		if (taken)  return (ctr == 2'b11) ? 2'b11 : ctr + 2'b01;
		else        return (ctr == 2'b00) ? 2'b00 : ctr - 2'b01;
	endfunction

	uwire       bp_en           = CT_EN_BP && cs_proc.trTeInstEnBranchPrediction;
	uwire [8:0] bp_idx          = etip_cf.iaddr[10:2];
	uwire bp_entry_t bp_rd      = PredTable[bp_idx];
	uwire [1:0] bp_ctr          = (bp_rd.tag == BpEpoch) ? bp_rd.ctr : 2'b01;
	uwire       bp_pred_taken   = bp_ctr[1];
	uwire       bp_actual_taken = (etip_cf.itype == TAKEN_BRANCH);
	uwire       cf_is_plain_branch =
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.rcode == NEXUS_RCODE_NONE) &&
		(etip_cf.sync_reason == NEXUS_SYNC_NONE) &&
		(etip_cf.itype inside {TAKEN_BRANCH, NOT_TAKEN_BRANCH});
	uwire       bp_mispredict = bp_en && cf_is_plain_branch
	                            && (bp_pred_taken != bp_actual_taken);

	// BP excludes the HIST-based loop compressions: the predictor replaces
	// the HIST accumulation those features buffer/replay. Hard-gate so a
	// misprogrammed CSR cannot mix the models (BP off = bit-identical to
	// the previous behavior). Each feature switch consts its own logic
	// away at compile time (CT_EN_* per feature, resource pass 2).
	uwire rh_en_eff = CT_EN_REPEATED_HISTORY && cs_proc.trTeInstEnRepeatedHistory && !bp_en;
	uwire rb_en_eff = CT_EN_REPEAT_BRANCH    && cs_proc.trTeInstEnRepeatBranch    && !bp_en;

	// RepeatInstruction (ISTO TCODE 31/32): single-instruction
	// spin-loop compression -- a plain TAKEN_BRANCH targeting its own
	// address. The FIRST execution is accounted normally (HIST bit + ICNT);
	// every following identical iteration is silently COUNTED (no bit, no
	// ICNT). The run closes as ONE TCODE 31 (R-CNT, I-CNT, HIST) before any
	// other emission, or as TCODE 32 when a sync lands ON the loop branch
	// mid-run. Decoder contract (NexRv arm, Accemic-defined -- 31/32 are
	// ISTO-5001 messages, reserved in N-Trace 1.0):
	//   TCODE 31: walk I-CNT with HIST (ends back at the loop PC after the
	//       first execution's taken bit), then re-emit the loop PC R-CNT
	//       times; the replays touch NO ICNT accounting (ICNT restarts at
	//       zero after this message).
	//   TCODE 32: walk I-CNT with HIST, then R-CNT+1 replays (the counted
	//       iterations plus the sync-carrying iteration itself, whose
	//       halfwords the encoder DROPS -- neither ICNT nor replay carries
	//       them), then hard re-anchor at F-ADDR (= the loop PC).
	// Excluded under BP (the predictor already absorbs spin loops via
	// PredCnt); FIFO_OVERRUN discards the count (pre-gap, like RH/RB).
	localparam int unsigned RPT_INSTR_CNT_W   = 18; // ~ NTRACE_MAX_HREPEAT
	localparam logic [RPT_INSTR_CNT_W-1:0] RPT_INSTR_CNT_CAP = '1;
	logic [RPT_INSTR_CNT_W-1:0] RptInstrCnt = '0;
	logic                       RptArmed    = 1'b0; // last consumed CF was a plain self-loop taken branch
	tip_iaddr_t                 RptAddr     = '0;
	nexus_icnt_t                RptIcnt     = '0;  // per-iteration halfwords (defensive match)

	uwire rpt_en_eff = CT_EN_REPEAT_INSTR && cs_proc.trTeInstEnRepeatInstr && !bp_en;
	// Plain self-loop taken branch (first execution / arming candidate).
	uwire cf_is_self_loop =
		rpt_en_eff && cf_is_plain_branch &&
		(etip_cf.itype == TAKEN_BRANCH) &&
		next_iaddr_q.valid &&
		(next_iaddr_q.q.addr == etip_cf.iaddr);
	// Counted silent iteration of the armed run.
	uwire rpt_count_now = cf_is_self_loop && RptArmed
		&& (RptAddr == etip_cf.iaddr)
		&& (nexus_icnt_t'(etip_cf.icnt) == RptIcnt)
		&& (RptInstrCnt != RPT_INSTR_CNT_CAP);
	// A sync landing ON the armed loop branch mid-run closes it as TCODE 32.
	uwire rpt_sync_upgrade_now = rpt_en_eff && (RptInstrCnt != 0) &&
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.rcode == NEXUS_RCODE_NONE) &&
		(etip_cf.sync_reason != NEXUS_SYNC_NONE) &&
		(etip_cf.sync_reason != NEXUS_SYNC_EXIT_FROM_SYS_RST) &&
		(etip_cf.sync_reason != NEXUS_SYNC_FIFO_OVERRUN) &&
		(etip_cf.itype == TAKEN_BRANCH) &&
		next_iaddr_q.valid &&
		(next_iaddr_q.q.addr == etip_cf.iaddr) &&
		(etip_cf.iaddr == RptAddr);

	// Partial-pattern trim detection (NexRvEnco IsHistMatch_30_28 for a
	// 31-bit window trims to 30/28; this window has W = 29 data bits, a
	// prime, so EVERY non-uniform periodic pattern phase-drifts and never
	// matches exactly). For a trim by s (window W-s) the branch stream is
	// periodic with p | (W-s) iff
	//   (1) prev[s-1:0]     == prev[W-1 -: s]   (pattern closes across the
	//                                            trimmed-window boundary)
	//   (2) prev[W-s-1 : s] == hist[W-1 : 2*s]  (hist continues prev,
	//                                            shifted by the s-bit drift)
	// Implemented shifts: s=1 -> 28-bit window (periods 2,4,7,14,28: the
	// if/else-in-loop case) and s=2 -> 27-bit window (periods 3,9,27:
	// 3-way unrolls). Checked only on the SECOND window of a run (cnt==1,
	// shift==0), like the reference.
	function automatic logic [2:0] hist_partial_match_shift(
		input logic [NEXUS_MSG_RDATA_WIDTH-1:0] prev,
		input logic [NEXUS_MSG_RDATA_WIDTH-1:0] hist_v);
		localparam int W = NEXUS_MSG_RDATA_WIDTH - 1; // 29 data bits
		if ((prev[0]   == prev[W-1])                 // s=1
		    && (prev[W-2:1] == hist_v[W-1:2]))
			return 3'd1;
		if ((prev[1:0] == prev[W-1:W-2])             // s=2
		    && (prev[W-3:2] == hist_v[W-1:4]))
			return 3'd2;
		return 3'd0;
	endfunction
	nexus_msg_struct_t                      TraceMsg     = '0; // generated trace message
	logic                                   FlushRequest = 0;
	// ICNT cap: CSR-selectable (Accemic wide-ICNT compression). The wire
	// ICNT field is variable-length, so widening the cap only changes WHEN
	// ResourceFull(RCODE=0) drains fire -- with the default (narrow) cap the
	// byte stream is identical to the original fixed 8-bit-cap behavior.
	uwire logic [31:0] MAX_NEXUS_ICNT = (CT_EN_WIDE_ICNT && cs_proc.trTeInstEnWideIcnt)
		? ((1 << NEXUS_MSG_I_CNT_WIDTH_WIDE) - 1)
		: ((1 << NEXUS_MSG_I_CNT_WIDTH) - 1);

	// What an INLINE ICNT drain puts on the wire, and what it leaves behind.
	//
	// Seven arms below consume a SILENT control-flow event (not-taken branch,
	// inferable jump, folded return, correctly predicted branch -- HTM and BTM)
	// and emit a ResourceFull(RCODE=0) when `CurrICnt + etip_cf.icnt` no longer
	// fits the ICNT field. Until 2026-08-12 every one of them emitted that SUM
	// and zeroed CurrICnt -- and the sum is, by the very condition that
	// triggers the arm, ALWAYS greater than MAX_NEXUS_ICNT. The N-Trace 1.0
	// I-CNT variable is capped at NEXUS_MSG_I_CNT_WIDTH bits, so each of those
	// drains was an over-cap field. It decoded (the MSEO field is variable
	// length and NexRv reads it), which is why it stayed invisible: measured on
	// the committed artefacts as RCODE=0 RDATA values of 256/258/260 in four
	// testbenches, including the one written for this very path
	// (tests/instruction/20_icnt_overflow -- it produces the stream and judges
	// no field value; the decode gate its header names never existed).
	//
	// The correct split is the one the HOLD paths already use and explain
	// (send_icnt_overflow_msg call sites: "rdata0 = CurrICnt only (not +
	// etip_cf.icnt) ... Including icnt here would double-count"): drain what
	// accumulated BEFORE this event and carry the event's own halfwords
	// forward. The total the decoder walks is unchanged -- RCODE=0 RDATA feeds
	// the same ICNT adjustment accumulator that the next message's ICNT adds
	// to -- so this is a re-split of one number across two messages, not a
	// change of accounting.
	//
	// `etip_cf.icnt <= MAX_NEXUS_ICNT` comes from the composer's tip-side
	// pre-drain (ct_L23_preproc_composer_etip.sv, `icnt_cum`) and holds.
	//
	// `CurrICnt <= MAX_NEXUS_ICNT` does NOT (found 2026-08-20 by a_i12_*,
	// gate `rh`: a ResourceFull carried ICNT 258). The induction claimed here
	// until then -- "it is only ever set to 0, to etip_cf.icnt, or to a sum
	// this guard has already found small enough" -- misses one case, and it is
	// a structural one, not a corner: in the HIST accumulation arm the ICNT
	// guard sits in the `else if` of the HIST-full check
	//
	//     if (HistCount >= NEXUS_MSG_RDATA_WIDTH - 1) ...   // HIST overflow
	//     else if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) ...
	//
	// so when BOTH would fire in the same beat, HIST wins and the ICNT drain
	// is skipped -- while `CurrICnt <= CurrICnt + etip_cf.icnt` above has
	// already run unconditionally. CurrICnt then stands above the cap and the
	// next drain puts that value on the wire. Only one message can leave per
	// beat, so skipping is right; carrying the excess silently is not.
	// Measured: 252 + 6 -> 258 at 134198 ns, emitted at 134298 ns
	// (tests/instruction/07_repeated_history; the repeated-history path fills
	// the HIST window often enough to hit the combination regularly).
	//
	// Hence a SPLIT rather than a cap: send at most MAX_NEXUS_ICNT and keep
	// the excess in CurrICnt, where the next drain sends it. That is the same
	// accounting the block comment above describes -- RCODE=0 RDATA feeds the
	// decoder's ICNT adjustment accumulator, which the next message's ICNT
	// adds to, so re-splitting one number across two messages changes nothing
	// the decoder computes. Clamping without the residue would LOSE halfwords
	// and desync it.
	//
	// Kept as two named expressions instead of inline arithmetic in seven
	// places for two reasons: one place to be right, and a one-line mutation
	// for the red counter-proof leg of scripts/cli_i20_test.sh.
	uwire logic icnt_drain_over_cap = (CurrICnt > ICNT_ACC_W'(MAX_NEXUS_ICNT));
	uwire logic [ICNT_ACC_W-1:0] icnt_drain_value   =
		icnt_drain_over_cap ? ICNT_ACC_W'(MAX_NEXUS_ICNT) : CurrICnt;
	uwire logic [ICNT_ACC_W-1:0] icnt_drain_residue =
		icnt_drain_over_cap
			? (CurrICnt - ICNT_ACC_W'(MAX_NEXUS_ICNT) + ICNT_ACC_W'(etip_cf.icnt))
			: ICNT_ACC_W'(etip_cf.icnt);

	uwire cf_needs_next_iaddr = HasChangedControlFlow(etip_cf.itype);

	// Implicit-return compression (Accemic): a RETURN whose target the
	// composer's return-address stack predicted (predicted_ret) AND that
	// prediction equals the actual next_iaddr can be folded like an
	// inferable branch -- the decoder recovers the target from its own
	// return stack, so no IndirectBranchHist is emitted. Only in the
	// non-sync path and only when trTeInstEnImplicitReturn is set. A
	// sentinel (all-ones) predicted_ret means "stack had no prediction"
	// and never folds (the decoder's stack would be empty too).
	// The prediction compare moved into the composer (resource pass): only
	// the 1-bit result rides the next_iaddr sideband.
	uwire return_is_predicted =
		CT_EN_IMPLICIT_RETURN &&
		cs_proc.trTeInstEnImplicitReturn &&
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.itype == RETURN) &&
		(etip_cf.sync_reason == NEXUS_SYNC_NONE) &&
		next_iaddr_q.valid &&
		next_iaddr_q.q.ret_predicted;

	uwire cf_indirect_hist_overflow_hold =
		ready_in && etip_q.valid &&
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.sync_reason == NEXUS_SYNC_NONE) &&
		(cs_proc.trTeInstMode == ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH_HIST) &&
		(etip_cf.itype inside {
			UNINFERABLE_JUMP,
			INTERRUPT,
			EXCEPTION_IR,
			EXCEPTION_TRAP,
			UNINFERABLE_CALL,
			UNINFERABLE_TAIL_CALL,
			OTHER_UNINFERABLE_JUMP,
			CO_ROUTINE_SWAP,
			RETURN
		}) &&
		// A folded (predicted) return takes the inferable path and handles
		// its own ICNT overflow inline -- keep it out of the indirect hold.
		!return_is_predicted &&
		(!cf_needs_next_iaddr || next_iaddr_q.valid) &&
		((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT);

	// A periodic/external sync in BRANCH_HIST mode would otherwise clear the
	// accumulated HIST bits without emitting them, leaving the decoder no way
	// to resolve earlier direct branches between the previous flush and the
	// sync point. Hold the sync eTIP back one cycle and emit a ResourceFull
	// HIST flush first.
	//
	// NEXUS_SYNC_FIFO_OVERRUN is EXCLUDED: the composer's ovf_injector dropped
	// CF events upstream of msg_gen, so msg_gen's CurrICnt and Hist now
	// represent only the subset that reached it. Pre-flushing the residual
	// HIST bits would walk the decoder through branches without the matching
	// in-between half-words (those were dropped), landing it at a PC that
	// disagrees with the sync's FADDR. The sync emission path below instead
	// overrides ICNT to 0 on FIFO_OVERRUN and the existing sync reset zeroes
	// Hist/HistCount in the same cycle — turning the recovery sync into a
	// pure re-anchor at FADDR, which is the only ground truth available.
	// (NexRv's ICNT-adjust heuristic can absorb a small over-count, but the
	// post-overrun under-count is unbounded and would underflow as soon as
	// the gap exceeds the in-message ICNT field -- observed on a hardware
	// trace as a SYNC=FIFO_OVERRUN message carrying ICNT=40.)
	// IBHS (TCODE 29): with trTeInstFeatures.InstEnIbhs set, a
	// synchronizing message CARRIES the pending branch history itself
	// (IndirectBranchHistorySync) instead of pre-flushing it as a separate
	// ResourceFull(RCODE=1) -- the hold below is bypassed and send_cf_msg
	// picks TCODE 29. NexRv walks ICNT resolving branches from the HIST
	// field, then hard re-anchors at FADDR -- exactly the two-message
	// semantics in one message. FIFO_OVERRUN stays excluded (its history
	// is DISCARDED, see the comment below); EXIT_FROM_SYS_RST never has
	// pending history.
	uwire ibhs_en = CT_EN_IBHS && cs_proc.trTeInstEnIbhs;

	uwire cf_sync_hist_flush_hold =
		ready_in && etip_q.valid &&
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.sync_reason != NEXUS_SYNC_NONE) &&
		(etip_cf.sync_reason != NEXUS_SYNC_EXIT_FROM_SYS_RST) &&
		(etip_cf.sync_reason != NEXUS_SYNC_FIFO_OVERRUN) &&
		(cs_proc.trTeInstMode == ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH_HIST) &&
		(!cf_needs_next_iaddr || next_iaddr_q.valid) &&
		(HistCount > 1) &&
		!ibhs_en;

	// Drain the buffered repeated-history run BEFORE any message that walks
	// or repositions the decoder PC: IndirectBranchHist (uninferable CF /
	// unpredicted return), any sync except FIFO_OVERRUN, the trace-off
	// correlation, and an ATB flush request. The buffered patterns are the
	// oldest pending trace content; the decoder replays them from its
	// current PC, so they must precede those messages on the wire.
	// ResourceFull RCODE=0 (ICNT drains) deliberately does NOT drain: the
	// decoder only accumulates its RDATA into the same adjustment counter
	// that HIST walks subtract from (NexRvDeco resourceFull_ICNT), so RCODE=0
	// commutes with RCODE=1/2 and draining would only cost compression.
	// A FIFO_OVERRUN sync instead DISCARDS the buffer (see send_cf_msg):
	// the dropped CF events upstream make any HIST walk unreliable; the
	// recovery sync re-anchors at FADDR (same rule as the residual-Hist
	// discard, see cf_sync_hist_flush_hold).
	uwire cf_repeat_drain_hold =
		ready_in && etip_q.valid && (HistRepeatCnt != 0) &&
		(
			((etip_msg.sub_type == SUB_MSG_CF) &&
			 (!cf_needs_next_iaddr || next_iaddr_q.valid) &&
			 ( (etip_cf.rcode inside {NEXUS_RCODE_TRACE_DISABLED,
			                          NEXUS_RCODE_CORR_DEBUG_ENTRY,
			                          NEXUS_RCODE_CORR_LOW_POWER}) ||
			   ((etip_cf.rcode == NEXUS_RCODE_NONE) &&
			    ( ((etip_cf.sync_reason != NEXUS_SYNC_NONE) &&
			       (etip_cf.sync_reason != NEXUS_SYNC_FIFO_OVERRUN)) ||
			      ((etip_cf.sync_reason == NEXUS_SYNC_NONE) &&
			       ((etip_cf.itype inside {
			           UNINFERABLE_JUMP,
			           INTERRUPT,
			           EXCEPTION_IR,
			           EXCEPTION_TRAP,
			           UNINFERABLE_CALL,
			           UNINFERABLE_TAIL_CALL,
			           OTHER_UNINFERABLE_JUMP,
			           CO_ROUTINE_SWAP
			         })
			        || ((etip_cf.itype == RETURN) && !return_is_predicted))))))) ||
			etip_msg.do_flush
		);

	// ---- RepeatBranch match / drain logic --------------------------------
	// The current eTIP item would emit a plain (BTYPE=IBRANCH) IBH.
	uwire cf_is_plain_ibh =
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.rcode == NEXUS_RCODE_NONE) &&
		(etip_cf.sync_reason == NEXUS_SYNC_NONE) &&
		( (etip_cf.itype inside {UNINFERABLE_JUMP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL,
		                         OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, EXCEPTION_IR})
		  || ((etip_cf.itype == RETURN) && !return_is_predicted) );

	// The would-be IBH equals the last emitted one -> suppress and count.
	// Requires an empty repeated-history buffer (mixed runs fall back to
	// the normal path -- correct, just less compression) and a REPLAYABLE
	// last message (see LastIbhReplayable above): same HIST/ICNT/target is
	// necessary but not sufficient -- with UADDR!=0 in the head message the
	// suppressed occurrences are NOT byte-identical to it, and the decoder's
	// verbatim replay walks a different address chain (S-7).
	uwire repeat_branch_match =
		rb_en_eff &&
		cf_is_plain_ibh &&
		next_iaddr_q.valid &&
		!etip_msg.do_flush &&
		LastIbhValid &&
		LastIbhReplayable &&
		(HistRepeatCnt == 0) &&
		(Hist == LastIbhHist) &&
		((CurrICnt + etip_cf.icnt) == LastIbhIcnt) &&
		(next_iaddr_q.q.addr == LastIbhAddr);

	// Address-reference mirror (see LastXmitAddr): combinational view of the
	// reference AFTER the message currently held in TraceMsg -- the packers
	// apply exactly this table on accept (TCODE 9 re-anchors at the CURRENT
	// address, every other address-carrying program message at the NEXT/
	// target address; DF addresses live in their own reference and DirectBranch
	// (3), ResourceFull, 30/31/56, Correlation, Error etc. do not move it).
	logic       xmit_ref_upd_now;
	tip_iaddr_t xmit_ref_now;
	always_comb begin
		xmit_ref_upd_now = 1'b0;
		xmit_ref_now     = LastXmitAddr;
		if (TraceMsg.sub_type != SUB_MSG_NONE) begin
			case (TraceMsg.tcode)
				NEXUS_MSG_PROGRAM_TRACE_SYNC: begin
					xmit_ref_upd_now = 1'b1;
					xmit_ref_now     = TraceMsg.sub.cf.curr_iaddr;
				end
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH,
				NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC,
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC,
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC,
				NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY,
				NEXUS_MSG_VENDOR_JUMP_TARGET_CACHE,
				NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC: begin
					xmit_ref_upd_now = 1'b1;
					xmit_ref_now     = TraceMsg.sub.cf.next_iaddr;
				end
				default: ;
			endcase
		end
	end
	// The IBH being emitted THIS cycle will carry UADDR == 0 iff its target
	// equals the reference after the outgoing message (both consumptions
	// happen in the same ready_in cycle, so xmit_ref_now is the right base).
	uwire cf_ibh_uaddr_zero = (next_iaddr_q.q.addr == xmit_ref_now);

	// Combinational mirror of the branch-arm behavior in send_cf_msg: does
	// consuming the current TAKEN/NOT_TAKEN item emit NO message this cycle?
	uwire [NEXUS_MSG_RDATA_WIDTH-1:0] hist_shifted_now =
		(etip_cf.itype == TAKEN_BRANCH) ? ((Hist << 1) | 1'b1) : (Hist << 1);
	uwire rh_window_full_now = (HistCount >= NEXUS_MSG_RDATA_WIDTH - 1);
	uwire rh_match_now   = (HistRepeatCnt != 0)
	                       && ((hist_shifted_now >> HistRepeatShift) == HistRepeatPrev);
	uwire rh_convert_now = (HistRepeatCnt == 1) && (HistRepeatShift == 0)
	                       && (hist_partial_match_shift(HistRepeatPrev, hist_shifted_now) != 0);
	uwire cf_branch_silent =
		(etip_cf.itype inside {TAKEN_BRANCH, NOT_TAKEN_BRANCH}) &&
		( bp_en
			? (!bp_mispredict && !((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT))
			: ( rh_window_full_now
				? (rh_en_eff
					&& ((HistRepeatCnt == 0) || rh_match_now || rh_convert_now))
				: !((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) ) );
	uwire cf_inferable_silent =
		((etip_cf.itype inside {INFERRABLE_CALL, INFERRABLE_TAIL_CALL, OTHER_INFERABLE_JUMP})
		 || return_is_predicted) &&
		!((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT);

	uwire consume_is_silent =
		((etip_msg.sub_type == SUB_MSG_NONE) && !etip_msg.do_flush) ||
		((etip_msg.sub_type == SUB_MSG_CF) && !etip_msg.do_flush &&
		 (etip_cf.rcode == NEXUS_RCODE_NONE) && (etip_cf.sync_reason == NEXUS_SYNC_NONE) &&
		 (cf_branch_silent || cf_inferable_silent || repeat_branch_match || rpt_count_now));

	// Drain the RepeatBranch count before ANY message emission (see the
	// decoder constraint above). Highest hold priority: the counted IBHs
	// are chronologically the oldest pending content.
	uwire cf_repeat_branch_drain_hold =
		ready_in && etip_q.valid && (RepeatBranchCnt != 0) &&
		((etip_msg.sub_type != SUB_MSG_CF) || !cf_needs_next_iaddr || next_iaddr_q.valid) &&
		!consume_is_silent;

	// Close an open RepeatInstruction run before ANY state-moving consume --
	// silent ones included: even a silently accounted branch would put its
	// HIST bit ahead of the run's replays (the TCODE-31 walk would then run
	// PAST the loop before replaying). Exceptions: the counting iteration
	// itself, empty non-flush beats, the TCODE-32 sync-upgrade (closes the
	// run itself), and a FIFO_OVERRUN sync (its send_cf_msg arm DISCARDS
	// the pre-gap count, like RH/RB).
	uwire cf_rpt_instr_drain_hold =
		ready_in && etip_q.valid && (RptInstrCnt != 0) &&
		((etip_msg.sub_type != SUB_MSG_NONE) || etip_msg.do_flush) &&
		((etip_msg.sub_type != SUB_MSG_CF) || !cf_needs_next_iaddr || next_iaddr_q.valid) &&
		!rpt_count_now &&
		!rpt_sync_upgrade_now &&
		!((etip_msg.sub_type == SUB_MSG_CF) && (etip_cf.rcode == NEXUS_RCODE_NONE)
		  && (etip_cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN));

	// A mispredicted branch must go out as TCODE 56, which carries no ICNT
	// field -- CurrICnt keeps accumulating across it. When the branch's own
	// halfwords would push CurrICnt past the cap, drain the accumulated
	// count (RCODE=0) first and keep the branch queued; the TCODE 56 goes
	// out the next cycle. (A correctly predicted branch drains inline in
	// its arm, like the inferable-CF path.) RCODE=0 commutes with the
	// TCODE-56 walk on the decoder side: both only touch the shared ICNT
	// adjustment accumulator.
	uwire cf_bp_icnt_drain_hold =
		ready_in && etip_q.valid &&
		bp_mispredict &&
		((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT);

	// BTM ICNT pre-drain: a DirectBranch (TCODE 3) / IndirectBranch
	// (TCODE 4) carries ICNT = CurrICnt + etip_cf.icnt. When that sum would
	// exceed the ICNT field, drain the accumulated CurrICnt as RCODE=0 first
	// (the branch stays queued and goes out next cycle with CurrICnt=0) --
	// the BTM analogue of cf_indirect_hist_overflow_hold's HistCount==1 leg.
	// Predicted returns and the silent not-taken/inferable arms handle their
	// own overflow inline (they consume), so they are excluded here.
	uwire cf_btm_icnt_overflow_hold =
		ready_in && etip_q.valid &&
		CT_EN_BTM &&
		(cs_proc.trTeInstMode == ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH) &&
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.sync_reason == NEXUS_SYNC_NONE) &&
		(etip_cf.rcode == NEXUS_RCODE_NONE) &&
		(etip_cf.itype inside {
			TAKEN_BRANCH,
			UNINFERABLE_JUMP, INTERRUPT, EXCEPTION_IR, EXCEPTION_TRAP,
			UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP,
			CO_ROUTINE_SWAP, RETURN
		}) &&
		!return_is_predicted &&
		(!cf_needs_next_iaddr || next_iaddr_q.valid) &&
		((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT);

	// Sync ICNT pre-drain (P0-04, second defect). A synchronizing message
	// carries ICNT = CurrICnt + etip_cf.icnt like every other ICNT-bearing
	// message -- and NO hold covered it. cf_sync_hist_flush_hold pre-flushes
	// the HIST bits and deliberately leaves CurrICnt running; the three ICNT
	// holds above are all keyed to a NON-sync event
	// (sync_reason == NEXUS_SYNC_NONE), so a sync fell between them. Both
	// summands are individually within the cap, so their sum can reach twice
	// it.
	//
	// Not a derivation: measured on the FIXED tree as three ProgTraceSync
	// messages carrying ICNT=258 at the narrow cap in
	// tests/instruction/10_branch_predict (OFF leg). a_i12_icnt_field_cap
	// reported them; no decode gate, PC check or byte comparison in this tree
	// could -- the same blindness that let the drain-arm defect live.
	//
	// Same shape as cf_btm_icnt_overflow_hold: drain the accumulated CurrICnt
	// as RCODE=0 first and keep the sync queued; next cycle CurrICnt is 0 and
	// the sync's own icnt (bounded by the composer's tip-side pre-drain) fits.
	// The walked total is unchanged, because the decoder applies a pending
	// RCODE=0 adjustment to a SYNC message's ICNT as well -- NexRvDeco.c,
	// NEXUS_TCODE_ProgTraceSync calls EmitICNT(), which folds
	// resourceFull_ICNT into n before walking.
	//
	// FIFO_OVERRUN is excluded for exactly the reason it is excluded from the
	// HIST pre-flush: that sync is a PURE re-anchor whose ICNT is overridden
	// to 0 and whose history is DISCARDED, because the composer's ovf_injector
	// dropped events upstream. Draining a residual count there would walk the
	// decoder through halfwords whose events never reached msg_gen -- and I7
	// asserts the ICNT=0 that this exclusion preserves.
	uwire cf_sync_icnt_overflow_hold =
		ready_in && etip_q.valid &&
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.sync_reason != NEXUS_SYNC_NONE) &&
		(etip_cf.sync_reason != NEXUS_SYNC_FIFO_OVERRUN) &&
		(etip_cf.rcode == NEXUS_RCODE_NONE) &&
		(!cf_needs_next_iaddr || next_iaddr_q.valid) &&
		((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT);

	uwire consume_etip =
		ready_in && etip_q.valid && (
			(etip_msg.sub_type == SUB_MSG_NONE) ||
			(etip_msg.sub_type == SUB_MSG_DF)   ||
			(etip_msg.sub_type == SUB_MSG_DAQ)  ||
			(etip_msg.sub_type == SUB_MSG_OTHER) ||
			((etip_msg.sub_type == SUB_MSG_CF) && (!cf_needs_next_iaddr || next_iaddr_q.valid))
		) && !cf_indirect_hist_overflow_hold && !cf_sync_hist_flush_hold && !cf_repeat_drain_hold
		  && !cf_repeat_branch_drain_hold && !cf_bp_icnt_drain_hold && !cf_rpt_instr_drain_hold
		  && !cf_btm_icnt_overflow_hold && !cf_sync_icnt_overflow_hold;

	//--------------------------------------------------------------------
	// main
	//--------------------------------------------------------------------
	// Combinational ack for both input source_ifs.
	assign etip_q.ack       = consume_etip;
	assign next_iaddr_q.ack = consume_etip
	                          && (etip_msg.sub_type == SUB_MSG_CF)
	                          && cf_needs_next_iaddr;

	// ---- Dedicated vendor-model write ports (LUTRAM-inferable) ----------
	// RAM template rule: array writes must live in their own simple
	// always_ff (writes buried inside a task of the big FSM block are not
	// recognized -- measured). The enables mirror the emission conditions
	// of send_cf_msg; translate_off assertions there guard against drift.
	uwire in_hist_mode =
		(cs_proc.trTeInstMode == ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH_HIST);

	// Jump-target cache: install on every EMITTED plain-IBRANCH miss.
	uwire jtc_install =
		consume_etip && in_hist_mode && jtc_en &&
		cf_is_plain_ibh && next_iaddr_q.valid && !jtc_hit && !repeat_branch_match;

	always_ff @(posedge proc_clk) begin
		if (jtc_install) JtcCache[jtc_idx] <= jtc_target;
	end

	// Branch predictor: update with the ACTUAL outcome of every consumed
	// direct branch -- plain branches (BRANCH_HIST mode) and sync-carried
	// branches (any mode; the sync path runs before the mode case). The
	// FIFO_OVERRUN special cases mirror send_cf_msg: a TAKEN overrun branch
	// is never walked by the decoder (no update), a NOT_TAKEN one updates
	// on top of the freshly bumped epoch from the weakly-not-taken base.
	uwire bp_upd_plain = consume_etip && in_hist_mode && bp_en && cf_is_plain_branch;
	uwire bp_upd_sync  = consume_etip && bp_en &&
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.rcode == NEXUS_RCODE_NONE) &&
		(etip_cf.sync_reason != NEXUS_SYNC_NONE) &&
		(etip_cf.itype inside {TAKEN_BRANCH, NOT_TAKEN_BRANCH}) &&
		!((etip_cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN) && (etip_cf.itype == TAKEN_BRANCH));
	uwire bp_overrun_upd = bp_upd_sync && (etip_cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN);
	uwire [1:0]            bp_wr_base = bp_overrun_upd ? 2'b01 : bp_ctr;
	uwire [BP_EPOCH_W-1:0] bp_wr_tag  = bp_overrun_upd ? BpEpoch + 1'b1 : BpEpoch;
	uwire                  bp_we      = bp_upd_plain || bp_upd_sync;
	uwire bp_entry_t       bp_scrub_rd = PredTable[BpScrub];

	// SINGLE write port (address-muxed): two separate write targets in one
	// process defeat LUTRAM inference (measured: 512x18 bit fell into FFs).
	// Update wins; the scrubber only fires on idle cycles -- identical to
	// the previous priority behavior.
	uwire                          bp_wr_strobe = bp_we || (bp_scrub_rd.tag != BpEpoch);
	uwire [$clog2(BP_ENTRIES)-1:0] bp_wr_addr   = bp_we ? bp_idx : BpScrub;
	uwire bp_entry_t               bp_wr_data   = bp_we
		? '{tag: bp_wr_tag, ctr: bp_next(bp_wr_base, bp_actual_taken)}
		: '{tag: BpEpoch,   ctr: 2'b01};

	always_ff @(posedge proc_clk) begin
		if (bp_wr_strobe) PredTable[bp_wr_addr] <= bp_wr_data;
	end

	// RepeatInstruction arming: every consumed plain CF re-decides whether
	// the NEXT iteration may be counted (armed = the just-consumed CF was a
	// plain self-loop taken branch). Kept outside the big FSM block so the
	// decision is uniform across all consume paths (silent or emitting).
	always_ff @(posedge proc_clk) begin
		if (proc_rst) begin
			RptArmed <= 1'b0;
			RptAddr  <= '0;
			RptIcnt  <= '0;
		end
		else if (consume_etip && (etip_msg.sub_type == SUB_MSG_CF)) begin
			RptArmed <= cf_is_self_loop;
			if (cf_is_self_loop && !rpt_count_now) begin
				RptAddr <= etip_cf.iaddr;
				RptIcnt <= nexus_icnt_t'(etip_cf.icnt);
			end
		end
	end

	uwire cf_proc_ready = ready_in;

	always_ff @(posedge proc_clk)begin
		if (proc_rst) begin
			FlushRequest <= 0;
			CurrICnt     <= 0;
			Hist         <= 1; // pre-load the stop bit
			HistCount    <= 1;
			HistRepeatPrev  <= '0;
			HistRepeatCnt   <= 0;
			HistRepeatShift <= 0;
			RepeatBranchCnt <= 0;
			RptInstrCnt     <= 0;
			LastIbhValid    <= 0;
			LastIbhReplayable <= 0;
			LastXmitAddr    <= '0;
			JtcValid        <= '0;
			PredCnt         <= 0;
			BpEpoch         <= '0; // epoch bump == model clear (LUTRAM untouched)
			BpScrub         <= '0;
			TraceMsg     <= '0;
			TraceMsg.sub_type <= SUB_MSG_NONE;
		end
		else begin
			// Predictor scrubber: whenever the update port is idle, refresh
			// one stale entry so epoch tags can never alias across wraps.
			if (!bp_we) BpScrub <= BpScrub + 1'b1;
			if (ready_in) begin
				// Address-reference mirror: the packer accepts the held
				// TraceMsg in this cycle and moves its RefAddr by the same
				// table (see xmit_ref_now above). Non-blocking reads see the
				// pre-edge TraceMsg, i.e. exactly the outgoing message.
				if (xmit_ref_upd_now) begin
					LastXmitAddr <= xmit_ref_now;
				end
				// Default output: no message.
				// IMPORTANT: only clear when ready_in==1.
				// If ready_in==0, we must hold TraceMsg stable so the downstream
				// formatter can apply backpressure without losing messages.
				TraceMsg.sub_type   <= SUB_MSG_NONE;

				if (cf_repeat_branch_drain_hold) begin
					// Close the RepeatBranch run first (oldest pending content;
					// the decoder's saved previous message must still be the
					// original IBH when TCODE 30 arrives).
					send_repeat_branch_msg(etip_msg.ts);
				end
				else if (cf_repeat_drain_hold) begin
					// Emit the buffered repeated-history run first and keep the
					// eTIP item queued; HistRepeatCnt is cleared by the task, so
					// the hold releases next cycle and the item proceeds through
					// the remaining holds / the normal consume path.
					send_hist_repeat_msg(etip_msg.ts);
				end
				else if (cf_rpt_instr_drain_hold) begin
					// Close the open RepeatInstruction run (TCODE 31) first and
					// keep the eTIP item queued; RptInstrCnt clears, the hold
					// releases next cycle.
					send_repeat_instr_msg(etip_msg.ts);
				end
				else if (cf_bp_icnt_drain_hold) begin
					// Drain the accumulated ICNT before the pending TCODE 56
					// (which carries no ICNT field); the mispredicted branch
					// stays queued and goes out next cycle.
					send_icnt_overflow_msg(etip_msg.ts, CurrICnt);
				end
				else if (cf_btm_icnt_overflow_hold) begin
					// BTM: drain the accumulated CurrICnt (RCODE=0) before the
					// pending DirectBranch/IndirectBranch; the branch stays
					// queued and emits next cycle with CurrICnt=0 (its own
					// etip_cf.icnt then fits). rdata0 = CurrICnt only, for the
					// same no-double-count reason as the indirect-hist path.
					send_icnt_overflow_msg(etip_msg.ts, CurrICnt);
				end
				else if (cf_indirect_hist_overflow_hold) begin
					// Emit a flush first and keep the eTIP CF item queued. On the
					// next cycle the relevant accumulators are reset so consuming
					// the same CF item yields a legal ICNT.
					//   - HistCount > 1 : real branches in Hist. RCODE=1 (HIST_OVERFLOW),
					//                     carries the HIST bits; CurrICnt keeps running
					//                     (decoder subtracts what it walks).
					//   - HistCount == 1: Hist is just the preloaded stop bit, i.e. the
					//                     payload would be 0x1 -- useless, NexRv drops
					//                     RDATA<=1. Emit RCODE=0 (ICNT_OVERFLOW) instead,
					//                     carrying the accumulated halfwords, and reset
					//                     CurrICnt so we break out of the hold.
					if (HistCount > 1) begin
						send_hist_overflow_msg(etip_msg.ts, Hist);
					end else begin
						// rdata0 = CurrICnt only (not + etip_cf.icnt):
						// the indirect CF item stays queued and will be
						// consumed the cycle after this flush. Its own
						// INDIRECT_BRANCH_HISTORY message (at line ~355)
						// already counts etip_cf.icnt via
						// TraceMsg.sub.cf.icnt = CurrICnt + etip_cf.icnt
						// (CurrICnt=0 after this reset). Including icnt
						// here would double-count those halfwords on
						// the decoder side.
						send_icnt_overflow_msg(etip_msg.ts, CurrICnt);
					end
				end
				else if (cf_sync_hist_flush_hold) begin
					// Same idea, but triggered by a pending sync eTIP carrying
					// accumulated HIST bits. Without this, send_cf_msg would
					// reset Hist as part of the sync path and the decoder would
					// lose the branch decisions that occurred between the last
					// ResourceFull-HIST flush and the sync point.
					send_hist_overflow_msg(etip_msg.ts, Hist);
				end
				else if (cf_sync_icnt_overflow_hold) begin
					// The sync's ICNT would not fit the field: drain the
					// accumulated count as RCODE=0 and keep the sync queued.
					// AFTER the HIST pre-flush above on purpose -- the HIST
					// bits are the older content, and RCODE=0 commutes with
					// RCODE=1 on the decoder side (both only touch the shared
					// ICNT adjustment accumulator), so this ordering costs
					// nothing and keeps the wire chronological. Each hold
					// releases itself: the flush leaves HistCount == 1, this
					// drain leaves CurrICnt == 0, so the sync goes out on the
					// third cycle at the latest.
					send_icnt_overflow_msg(etip_msg.ts, CurrICnt);
				end
				else if (consume_etip) begin
					if (etip_msg.do_flush) begin
						FlushRequest <= 1;
					end
					case (etip_msg.sub_type)
						SUB_MSG_NONE: begin
						end
						SUB_MSG_CF: begin
							send_cf_msg(etip_cf, etip_msg.ts);
						end
						SUB_MSG_DF: begin
							send_df_msg(etip_df, etip_msg.ts);
						end
						SUB_MSG_DAQ: begin
							send_daq_msg(etip_daq, etip_msg.ts);
						end
						SUB_MSG_OTHER: begin
							send_other_msg(etip_other, etip_msg.ts);
						end
						default: begin
						end
					endcase
				end
				else if (FlushRequest) begin
					// Emit the flush marker ONLY into a free emission slot --
					// hence the else-if at the lowest priority. Written as a
					// trailing `if` AFTER the arm chain, send_flush_msg would
					// overwrite the message composed in the SAME cycle
					// (sub_type/tcode become FLUSH, for which the formatter
					// emits no wire bytes), so EXACTLY ONE message would
					// disappear from the stream while the framing still looked
					// intact. Observed on hardware at enable-off and flush
					// edges (do_flush = atb_afvalid || EnableFall ||
					// CorrDisable): a JTC hit went missing and the target ring
					// slipped by one position. Whether the collision happens
					// depends on the backpressure phase, so it is intermittent.
					//
					// Deferring to the next free slot is semantically lossless:
					// the marker only has to sit BEHIND everything already
					// emitted. Under sustained load it moves to the next
					// consumption gap -- idle beats exist in every real regime,
					// and the stop sequences quiesce anyway.
					send_flush_msg();
					FlushRequest <= 0;
				end
			end
		end
	end

	// ----------------------------------------------
	// TASK: send_cf_msg
	// ----------------------------------------------
	task send_cf_msg;
		input etip_cf_msg_struct_t          etip_cf;
		input tip_time_t    ts;

		logic [NEXUS_MSG_RDATA_WIDTH-1:0] hist;
		logic [2:0] rh_conv_shift;

		// Composer-side ICNT_OVERFLOW drain. The composer emits a
		// SUB_MSG_CF with rcode=ICNT_OVERFLOW when icnt_cum would push
		// past the 8-bit wire ICNT field. We forward it as a wire RCODE=0
		// directly and leave CurrICnt / Hist / HistCount untouched -- the
		// drain represents halfwords already accounted for in tip-clk
		// accumulation; CurrICnt only ever carries proc-clk accumulation
		// from real CF events. Without this short-circuit, the drained
		// halfwords would either re-enter CurrICnt and re-trip the same
		// hold, or truncate at the IBH path's 8-bit field.
		if (etip_cf.rcode == NEXUS_RCODE_ICNT_OVERFLOW) begin
			TraceMsg.sub_type      <= SUB_MSG_CF;
			TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
			TraceMsg.ts            <= ts;
			TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_ICNT_OVERFLOW;
			TraceMsg.sub.cf.rdata0 <= etip_cf.icnt;
			LastIbhValid           <= 0;
			return;
		end

		// Composer-side trace-off marker. On trTeControl.Enable 1->0 the
		// composer emits a SUB_MSG_CF with rcode=TRACE_DISABLED carrying the
		// residual half-words. Turn it into a Program Trace Correlation Message
		// (TCODE 33, EVCODE=Program Trace Disabled): ICNT = all instruction
		// units since the last transmitted ICNT (CurrICnt + composer residual),
		// CDATA = the pending branch HIST. Per the N-Trace 1.0 HTM rule
		// (Table 24) the formatter/packer emits CDF=1 and the HIST field
		// ALWAYS -- an empty history goes out as 0x1 (the stop-bit-preloaded
		// Hist below is >= 0x1 by construction). Clear the accumulators (this
		// is the final message).
		if (etip_cf.rcode inside {NEXUS_RCODE_TRACE_DISABLED,
		                          NEXUS_RCODE_CORR_DEBUG_ENTRY,
		                          NEXUS_RCODE_CORR_LOW_POWER}) begin
			TraceMsg.sub_type      <= SUB_MSG_CF;
			TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_CORRELATION;
			TraceMsg.ts            <= ts;
			TraceMsg.sub.cf.icnt   <= CurrICnt + etip_cf.icnt;
			TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_NONE;
			TraceMsg.sub.cf.rdata0 <= Hist;
			// EVCODE rides rdata1[3:0] into the formatter/packer correlation
			// arm (TCODE 33 has no other use for rdata1): 4 = Program Trace
			// Disabled, 0 = Entry into Debug Mode (Required), 1 = Entry into
			// Low-power Mode.
			TraceMsg.sub.cf.rdata1 <=
				  (etip_cf.rcode == NEXUS_RCODE_CORR_DEBUG_ENTRY)
					? NEXUS_MSG_RDATA_WIDTH'(NEXUS_EVCODE_ENTRY_DEBUG)
				: (etip_cf.rcode == NEXUS_RCODE_CORR_LOW_POWER)
					? NEXUS_MSG_RDATA_WIDTH'(NEXUS_EVCODE_ENTRY_LOW_POWER)
				:     NEXUS_MSG_RDATA_WIDTH'(NEXUS_EVCODE_PROGRAM_TRACE_DISABLED);
			CurrICnt  <= 0;
			Hist      <= 1;
			HistCount <= 1;
			LastIbhValid <= 0;
			JtcValid  <= '0; // trace-off/debug/low-power: decoder restarts cold at the correlation
			PredCnt   <= 0;  // correlation ICNT walk covers all pending branches
			// trace-off (and debug/low-power entry): reset the predictor so
			// the next segment starts from the same weakly-not-taken state
			// as a decoder that resets its model on the correlation message.
			// Epoch bump == full clear.
			BpEpoch   <= BpEpoch + 1'b1;
			// pragma translate_off
			assert (HistRepeatCnt == 0)
				else $error("%m: trace-off correlation with pending repeated-history buffer -- cf_repeat_drain_hold failed");
			assert (RepeatBranchCnt == 0)
				else $error("%m: trace-off correlation with pending RepeatBranch count -- cf_repeat_branch_drain_hold failed");
			assert (RptInstrCnt == 0)
				else $error("%m: trace-off correlation with pending RepeatInstruction count -- cf_rpt_instr_drain_hold failed");
			// pragma translate_on
			return;
		end

		TraceMsg.sub_type           <= SUB_MSG_CF;
		TraceMsg.ts                 <= ts;
		TraceMsg.sub.cf.sync_reason <= etip_cf.sync_reason;
		TraceMsg.sub.cf.curr_iaddr  <= etip_cf.iaddr;
		TraceMsg.sub.cf.next_iaddr  <= next_iaddr_q.q.addr;
		// FIFO_OVERRUN sync: CurrICnt only counts the CF events msg_gen saw,
		// not the events the composer's ovf_injector dropped. Emitting that
		// partial count would under-count the actual half-words between the
		// prior anchor and this sync's FADDR, and the decoder's ICNT-adjust
		// heuristic would underflow (observed on a hardware trace).
		// Override to 0 so the recovery sync is a pure re-anchor at FADDR;
		// the existing reset below zeroes CurrICnt/Hist alongside.
		TraceMsg.sub.cf.icnt        <= (etip_cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN)
											? '0
											: (CurrICnt + etip_cf.icnt);
		TraceMsg.sub.cf.rcode       <= NEXUS_RCODE_NONE;
		TraceMsg.sub.cf.rdata0      <= '0;
		TraceMsg.sub.cf.rdata1      <= '0;

			if (etip_cf.sync_reason != NEXUS_SYNC_NONE) begin
				// Emitted sync ICNT = CurrICnt (accumulated from prior CF
				// messages that did not themselves transmit ICNT) +
				// etip_cf.icnt (halfwords carried by the composer for the
				// current segment). Per the Nexus spec this is the number
				// of instruction units executed since the last transmitted
				// ICNT — inclusive of the sync PC for CF-syncs, exclusive
				// for ProgTraceSync (see the composer for the asymmetry).
				// (FIFO_OVERRUN is overridden to ICNT=0 above — see comment.)
				// Reset CurrICnt so the next message starts fresh.
				CurrICnt <= 0;
				Hist        <= 1; // pre-load the stop bit
				HistCount   <= 1;
				LastIbhValid <= 0; // sync message breaks RepeatBranch adjacency
				PredCnt      <= 0; // the sync's ICNT walk covers all pending branches

				// FIFO_OVERRUN: discard the buffered repeated-history run --
				// its patterns may span the dropped-events gap, so replaying
				// them could walk the decoder astray; the recovery sync
				// re-anchors at FADDR (same rationale as the residual-Hist
				// discard, see cf_sync_hist_flush_hold). All other syncs
				// arrive here with an empty buffer (cf_repeat_drain_hold).
				if (etip_cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN) begin
					HistRepeatCnt   <= 0;
					RepeatBranchCnt <= 0; // pre-gap repeats: discard with the rest
					RptInstrCnt     <= 0; // pre-gap spin-loop count: discard too
					// BP: pre-overrun decoder predictor state never saw the
					// gap either, but the pre-gap segment between the last
					// emission and the overflow is never walked -- reset the
					// model on BOTH sides at the recovery sync so they
					// re-lock (decoder keys off the SYNC field). Epoch bump
					// == clear; the dedicated write port applies a same-cycle
					// NOT_TAKEN update on top of the NEW epoch (bp_wr_tag).
					BpEpoch <= BpEpoch + 1'b1;
					// JTC: exactly the same argument, and the header comment
					// above (JtcCache/JtcValid) already promised it -- but the
					// clear was missing. An INSTALL that fell into the dropped
					// window is unknown to the decoder, so a later HIT on that
					// index sends it to a target it never learned: it either
					// reports "index N not yet installed" or resolves a stale
					// slot to a non-indirect instruction, and aborts. Found on
					// the KV260 under sustained saturation and reproduced in
					// tests/overflow/03_jtc_overflow.
					// Byte-neutral for streams without overflow: this arm only
					// runs on a FIFO_OVERRUN recovery sync.
					JtcValid <= '0;
				end
				// (BP predictor updates for sync-carried branches happen in
				// the dedicated write port -- see bp_upd_sync above.)
				// pragma translate_off
				assert ((etip_cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN) || (HistRepeatCnt == 0))
					else $error("%m: sync consumed with pending repeated-history buffer (cnt=%0d) -- cf_repeat_drain_hold failed to drain", HistRepeatCnt);
				// pragma translate_on

				// A conditional branch can itself carry a sync reason — most
				// notably the EXIT_FROM_SYS_RST sync, which is attached to the
				// first retired instruction (often a branch). The sync path
				// emits a ProgTraceSync and resets the history WITHOUT running
				// the branch-HIST accumulation, so this branch's direction
				// would be lost: the very first HIST overflow then flushes one
				// extra branch and a following indirect branch's ICNT collapses
				// (see tests/instruction/04_sync_indirect_collapse).
				//
				// Seed the fresh history with this branch's direction so the
				// decoder can resolve it when it walks forward from the sync
				// FADDR. The branch's half-words are carried into the next
				// segment by the composer's EXCLUSIVE sync path (it keys off
				// HasChangedControlFlow, which is 0 for a not-taken branch), so
				// counting and history stay in agreement — no double count.
				//
				// Seed ONLY when the sync we are about to emit is a ProgTraceSync
				// (address-only): there the decoder positions AT the branch's
				// FADDR and re-walks it, so it needs the bit. A periodic sync on a
				// TAKEN_BRANCH instead emits a DirectBranchSync, which resolves the
				// branch itself and leaves the decoder PAST it — seeding there
				// strands a HIST bit and the next IndirectBranchHist fails with
				// "hist bits pending". The ProgTraceSync cases are: any
				// EXIT_FROM_SYS_RST, or a NOT_TAKEN_BRANCH (its periodic sync falls
				// through to the ProgTraceSync default, see the case below).
				if (etip_cf.itype == NOT_TAKEN_BRANCH
						|| (etip_cf.itype == TAKEN_BRANCH
							&& etip_cf.sync_reason == NEXUS_SYNC_EXIT_FROM_SYS_RST)) begin
					Hist      <= (1 << 1) | (etip_cf.itype == TAKEN_BRANCH ? 1'b1 : 1'b0);
					HistCount <= 2;
				end

				if (rpt_sync_upgrade_now) begin
					// TCODE 32 (RepeatInstructionSync, ISTO 4.3.15): a sync
					// landed ON the armed spin-loop branch mid-run. Fields:
					// SYNC, R-CNT(rdata1), I-CNT, F-ADDR(next_iaddr = loop
					// PC), HIST(rdata0). I-CNT is CurrICnt WITHOUT this
					// iteration's own halfwords -- the decoder replays
					// R-CNT+1 loop-PC hits (the counted iterations plus the
					// sync-carrying one) after walking I-CNT+HIST, then
					// re-anchors at F-ADDR; the sync iteration's halfwords
					// are dropped on both sides by contract.
					TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC;
					TraceMsg.sub.cf.icnt   <= CurrICnt;
					TraceMsg.sub.cf.rdata0 <= Hist;
					TraceMsg.sub.cf.rdata1 <= NEXUS_MSG_RDATA_WIDTH'(RptInstrCnt);
					TraceMsg.sub.cf.btype  <= NEXUS_BTYPE_IBRANCH;
					RptInstrCnt            <= 0;
				end
				else if (ibhs_en && (HistCount > 1)
				    && (etip_cf.sync_reason != NEXUS_SYNC_EXIT_FROM_SYS_RST)
				    && (etip_cf.sync_reason != NEXUS_SYNC_FIFO_OVERRUN)) begin
					// IBHS: the sync carries the pending history (TCODE 29:
					// SYNC, BTYPE, ICNT, FADDR, HIST). NexRv walks ICNT with
					// the HIST bits from its current PC and then re-anchors
					// hard at FADDR, so the same value works for every case:
					//   - CF sync (taken branch / indirect): FADDR = target
					//     (next_iaddr, inclusive ICNT from the composer); the
					//     terminal branch is resolved by the anchor itself --
					//     its direction bit is NOT in HIST (same as the
					//     DirectBranchSync/IndirectBranchSync forms today).
					//   - non-CF sync (periodic on a linear instr, marker
					//     one-shots): FADDR = the sync instruction itself
					//     (exclusive ICNT), BTYPE=0 -- explicitly sanctioned
					//     by N-Trace 8.4 ("B-TYPE=0 ... will not mean
					//     indirect flow change").
					// The NT-branch direction seed above stays as-is: it
					// belongs to the NEXT segment, while rdata0 carries the
					// OLD pending bits.
					TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC;
					TraceMsg.sub.cf.rdata0 <= Hist;
					if (!HasChangedControlFlow(etip_cf.itype)) begin
						TraceMsg.sub.cf.next_iaddr <= etip_cf.iaddr;
					end
					case (etip_cf.itype)
						INTERRUPT:      TraceMsg.sub.cf.btype <= NEXUS_BTYPE_INTERRUPT;
						EXCEPTION_TRAP: TraceMsg.sub.cf.btype <= NEXUS_BTYPE_EXCEPTION;
						EXCEPTION_IR:   TraceMsg.sub.cf.btype <= NEXUS_BTYPE_INTERRUPT;
						default:        TraceMsg.sub.cf.btype <= NEXUS_BTYPE_IBRANCH;
					endcase
				end
				else begin
				case (etip_cf.sync_reason)
					NEXUS_SYNC_EXIT_FROM_SYS_RST: begin
						TraceMsg.tcode <= NEXUS_MSG_PROGRAM_TRACE_SYNC;
					end
					default: begin
						case (etip_cf.itype)
						TAKEN_BRANCH, INFERRABLE_CALL, INFERRABLE_TAIL_CALL, OTHER_INFERABLE_JUMP: begin
							TraceMsg.tcode <= NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC;
						end
						UNINFERABLE_JUMP, INTERRUPT, EXCEPTION_IR, EXCEPTION_TRAP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, RETURN: begin
							TraceMsg.tcode <= NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC;
							case (etip_cf.itype)
								UNINFERABLE_JUMP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, RETURN: begin
									TraceMsg.sub.cf.btype <= NEXUS_BTYPE_IBRANCH;
								end
								INTERRUPT: begin
									TraceMsg.sub.cf.btype <= NEXUS_BTYPE_INTERRUPT;
								end
								EXCEPTION_TRAP: begin
									TraceMsg.sub.cf.btype <= NEXUS_BTYPE_EXCEPTION;
								end
								EXCEPTION_IR: begin
									TraceMsg.sub.cf.btype <= NEXUS_BTYPE_INTERRUPT;
								end
								default: begin
								end
							endcase
						end
						default: begin
							TraceMsg.tcode <= NEXUS_MSG_PROGRAM_TRACE_SYNC;
						end
						endcase
					end
				endcase
				end
			end
		else begin
			case (cs_proc.trTeInstMode)
				// ITR_BRANCH (Branch Trace Messaging, BTM: Nexus DirectBranch
				// TCODE 3 / IndirectBranch TCODE 4. The SECOND N-Trace
				// instruction-trace mode next to HTM. No history accumulation:
				// each TAKEN direct conditional branch emits ONE DirectBranch
				// (ICNT only; decoder decodes the branch opcode for the target),
				// not-taken/inferable/predicted-return just accumulate ICNT
				// silently, and every indirect CF emits an IndirectBranch (BTYPE,
				// ICNT, UADDR). ICNT overflow between messages drains via
				// cf_btm_icnt_overflow_hold (RCODE=0). The sync-carrying-branch
				// path above already produced DirectBranchSync(11)/IndirectBranchSync(12)
				// -- both HIST-free, exactly the BTM sync forms. Compile-gated on
				// CT_EN_BTM (when off the WARL never lets InstMode reach 3, so
				// this arm folds to the default SUB_MSG_NONE).
					ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH: begin
						if (!ct_pkg::CT_EN_BTM) begin
							TraceMsg.sub_type <= SUB_MSG_NONE;
						end
						else begin
						case (etip_cf.itype)
							TAKEN_BRANCH: begin
								// DirectBranch (TCODE 3): the taken conditional
								// branch closes the block. ICNT (= CurrICnt +
								// etip_cf.icnt, set at the task top) covers all
								// halfwords up to and including it. No HIST.
								TraceMsg.tcode <= NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH;
								CurrICnt       <= 0;
								LastIbhValid   <= 0;
							end
							NOT_TAKEN_BRANCH: begin
								// Not-taken: silent, just accumulate ICNT. The
								// cf_btm_icnt_overflow_hold drained CurrICnt first
								// if the sum would overflow, so the inline path is
								// the common (no-overflow) case; guard anyway.
								CurrICnt          <= CurrICnt + etip_cf.icnt;
								TraceMsg.sub_type <= SUB_MSG_NONE;
								if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) begin
									TraceMsg.sub_type      <= SUB_MSG_CF;
									TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
									TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_ICNT_OVERFLOW;
									TraceMsg.sub.cf.rdata0 <= icnt_drain_value;
									CurrICnt               <= icnt_drain_residue;
									LastIbhValid           <= 0;
								end
							end
							INFERRABLE_CALL, INFERRABLE_TAIL_CALL, OTHER_INFERABLE_JUMP: begin
								// Inferable jump: silent, accumulate ICNT (decoder
								// infers the target from the opcode). Same overflow
								// handling as HTM's inferable arm.
								CurrICnt          <= CurrICnt + etip_cf.icnt;
								TraceMsg.sub_type <= SUB_MSG_NONE;
								if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) begin
									TraceMsg.sub_type      <= SUB_MSG_CF;
									TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
									TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_ICNT_OVERFLOW;
									TraceMsg.sub.cf.rdata0 <= icnt_drain_value;
									CurrICnt               <= icnt_drain_residue;
									LastIbhValid           <= 0;
								end
							end
							RETURN: begin
								if (return_is_predicted) begin
									// Implicit-return fold (same runtime gate as
									// HTM): silent, decoder pops its return stack.
									CurrICnt          <= CurrICnt + etip_cf.icnt;
									TraceMsg.sub_type <= SUB_MSG_NONE;
									if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) begin
										TraceMsg.sub_type      <= SUB_MSG_CF;
										TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
										TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_ICNT_OVERFLOW;
										TraceMsg.sub.cf.rdata0 <= icnt_drain_value;
										CurrICnt               <= icnt_drain_residue;
										LastIbhValid           <= 0;
									end
								end
								else begin
									// Unpredicted return -> IndirectBranch (TCODE 4).
									TraceMsg.tcode        <= NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH;
									TraceMsg.sub.cf.btype <= NEXUS_BTYPE_IBRANCH;
									CurrICnt              <= 0;
									LastIbhValid          <= 0;
								end
							end
							UNINFERABLE_JUMP, INTERRUPT, EXCEPTION_IR, EXCEPTION_TRAP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP: begin
								// IndirectBranch (TCODE 4): BTYPE + ICNT + UADDR.
								// No HIST, no JTC (HTM-only). BTYPE mapping mirrors
								// the HTM IBH / sync path.
								TraceMsg.tcode <= NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH;
								case (etip_cf.itype)
									UNINFERABLE_JUMP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, EXCEPTION_IR: begin
										TraceMsg.sub.cf.btype <= NEXUS_BTYPE_IBRANCH;
									end
									INTERRUPT: begin
										TraceMsg.sub.cf.btype <= NEXUS_BTYPE_INTERRUPT;
									end
									EXCEPTION_TRAP: begin
										TraceMsg.sub.cf.btype <= NEXUS_BTYPE_EXCEPTION;
									end
									default: begin
									end
								endcase
								CurrICnt     <= 0;
								LastIbhValid <= 0;
							end
							default: begin
								TraceMsg.sub_type <= SUB_MSG_NONE;
							end
						endcase
						end
					end
					ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH_HIST: begin
						case (etip_cf.itype)
							TAKEN_BRANCH, NOT_TAKEN_BRANCH: begin
							if (rpt_count_now) begin
								// RepeatInstruction: silent counted iteration of
								// the armed spin loop -- no HIST bit, no ICNT.
								RptInstrCnt       <= RptInstrCnt + 1'b1;
								TraceMsg.sub_type <= SUB_MSG_NONE;
							end
							else if (bp_en) begin
								// Branch-prediction compression: no HIST
								// accumulation. The predictor update happens
								// in the dedicated write port (bp_upd_plain).
								// Correct prediction -> silent, count it;
								// mispredict -> TCODE 56 (BCNT = counted run).
								// CurrICnt accumulates either way; TCODE 56
								// carries no ICNT (walk-subtract convention),
								// the correct path drains RCODE=0 inline like
								// the inferable arm. The mispredict+overflow
								// combination was already drained by
								// cf_bp_icnt_drain_hold.
								CurrICnt          <= CurrICnt + etip_cf.icnt;
								TraceMsg.sub_type <= SUB_MSG_NONE;
								if (bp_mispredict) begin
									send_branch_predict_msg(etip_msg.ts);
								end
								else begin
									PredCnt <= PredCnt + 1;
									if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) begin
										TraceMsg.sub_type       <= SUB_MSG_CF;
										TraceMsg.tcode          <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
										TraceMsg.sub.cf.rcode   <= NEXUS_RCODE_ICNT_OVERFLOW;
										TraceMsg.sub.cf.rdata0  <= icnt_drain_value;
										CurrICnt                <= icnt_drain_residue;
										LastIbhValid            <= 0;
									end
								end
							end
							else begin
								if (etip_cf.itype == TAKEN_BRANCH) begin
									hist = Hist << 1 | 1;
								end
								else begin
									hist = Hist << 1 | 0;
								end

								CurrICnt          <= CurrICnt + etip_cf.icnt;
								Hist              <= hist;
								HistCount         <= HistCount + 1;
								TraceMsg.sub_type <= SUB_MSG_NONE;

							// Overflow handling, per Nexus spec:
							//   RCODE=1 (HIST_OVERFLOW)  — the HIST payload is full.
							//       Flush HIST only; the HIST_OVERFLOW message carries
							//       no ICNT field. CurrICnt is NOT reset here: ICNT
							//       keeps accumulating across the flush and is reported
							//       in full by the next history-bearing message (IBH /
							//       sync / correlation), which is where it is reset. The
							//       decoder subtracts the half-words it walks while
							//       resolving the flushed HIST from that next ICNT, so
							//       the span is counted exactly once. (This mirrors the
							//       reference software encoder NexRvEnco, whose
							//       ResourceFull path leaves encoICNT untouched; zeroing
							//       it here dropped the non-HIST-covered half-words and
							//       desynced the decoder — see tests/instruction/03_stress.)
							//   RCODE=0 (ICNT_OVERFLOW) — CurrICnt no longer fits the
							//       ICNT field of the next packet. Emit the accumulated
							//       halfwords now and reset CurrICnt; HIST is preserved.
							if (HistCount >= NEXUS_MSG_RDATA_WIDTH - 1) begin
								if (rh_en_eff) begin
									// Repeated-history compression: buffer / count the
									// full pattern instead of emitting it. CurrICnt
									// keeps accumulating exactly as in the RCODE=1 case
									// -- neither the buffered nor the counted pattern
									// transmits ICNT. A 32-bit counter cannot
									// realistically saturate (2^32 windows of >=27
									// branches each).
									if ((HistRepeatCnt != 0)
									    && ((hist >> HistRepeatShift) == HistRepeatPrev)) begin
										// Match (exact when shift==0, trimmed otherwise):
										// count the window; carry the s drift LSBs into
										// the fresh accumulation (stop bit at position s).
										HistRepeatCnt <= HistRepeatCnt + 1;
										Hist      <= (1 << HistRepeatShift)
										           | (hist & ((1 << HistRepeatShift) - 1));
										HistCount <= 1 + HistRepeatShift;
									end
									else if ((HistRepeatCnt == 1) && (HistRepeatShift == 0)
									         && (hist_partial_match_shift(HistRepeatPrev, hist) != 0)) begin
										// Second window of a run, no exact match, but a
										// trimmed match: convert the run to the trimmed
										// pattern (NexRvEnco conversion path). The buffered
										// pattern loses its s drift LSBs (they are the
										// leading bits of THIS window); this window carries
										// 2s LSBs into the next accumulation (s for the
										// trimmed-off tail of the previous window, s for
										// its own drift).
										rh_conv_shift   = hist_partial_match_shift(HistRepeatPrev, hist);
										HistRepeatShift <= rh_conv_shift;
										HistRepeatPrev  <= HistRepeatPrev >> rh_conv_shift;
										HistRepeatCnt   <= 2;
										Hist      <= (1 << (2*rh_conv_shift))
										           | (hist & ((1 << (2*rh_conv_shift)) - 1));
										HistCount <= 1 + 2*rh_conv_shift;
									end
									else begin
										if (HistRepeatCnt != 0) begin
											// Pattern changed: emit the buffered run now,
											// then start a fresh full-window run with the
											// new pattern (the later nonblocking assigns
											// override the task's HistRepeatCnt <= 0).
											send_hist_repeat_msg(etip_msg.ts);
										end
										HistRepeatPrev  <= hist;
										HistRepeatCnt   <= 1;
										HistRepeatShift <= 0;
										Hist      <= 1;
										HistCount <= 1;
									end
								end
								else begin
									TraceMsg.sub_type       <= SUB_MSG_CF;
									TraceMsg.tcode          <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
									TraceMsg.sub.cf.rcode   <= NEXUS_RCODE_HIST_OVERFLOW;
									TraceMsg.sub.cf.rdata0  <= hist;
									Hist                    <= 1;
									HistCount               <= 1;
									LastIbhValid            <= 0;
								end
							end
							else if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) begin
								TraceMsg.sub_type       <= SUB_MSG_CF;
								TraceMsg.tcode          <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
								TraceMsg.sub.cf.rcode   <= NEXUS_RCODE_ICNT_OVERFLOW;
								TraceMsg.sub.cf.rdata0  <= icnt_drain_value;
								CurrICnt                <= icnt_drain_residue;
								LastIbhValid            <= 0;
							end
							end // !bp_en (HIST accumulation path)
						end
						INFERRABLE_CALL, INFERRABLE_TAIL_CALL, OTHER_INFERABLE_JUMP: begin
							CurrICnt          <= CurrICnt + etip_cf.icnt;
							TraceMsg.sub_type <= SUB_MSG_NONE;

							// Inferable control-flow changes need no HIST bit, but
							// their halfwords still count toward ICNT; emit RCODE=0
							// if CurrICnt can no longer fit the next ICNT field.
							if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) begin
								TraceMsg.sub_type       <= SUB_MSG_CF;
								TraceMsg.tcode          <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
								TraceMsg.sub.cf.rcode   <= NEXUS_RCODE_ICNT_OVERFLOW;
								TraceMsg.sub.cf.rdata0  <= icnt_drain_value;
								CurrICnt                <= icnt_drain_residue;
								LastIbhValid            <= 0;
							end
						end
						RETURN: begin
							if (return_is_predicted) begin
								// Implicit-return compression: the target matches the
								// composer's return-stack prediction, so fold like an
								// inferable branch -- accumulate ICNT, emit NO
								// IndirectBranchHist. The decoder pops its own return
								// stack to recover the target. Same overflow handling as
								// the INFERRABLE_CALL arm above.
								CurrICnt          <= CurrICnt + etip_cf.icnt;
								TraceMsg.sub_type <= SUB_MSG_NONE;
								if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) begin
									TraceMsg.sub_type       <= SUB_MSG_CF;
									TraceMsg.tcode          <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
									TraceMsg.sub.cf.rcode   <= NEXUS_RCODE_ICNT_OVERFLOW;
									TraceMsg.sub.cf.rdata0  <= icnt_drain_value;
									CurrICnt                <= icnt_drain_residue;
									LastIbhValid            <= 0;
								end
							end
							else if (repeat_branch_match) begin
								// RepeatBranch: identical to the last emitted IBH --
								// suppress and count; reset the accumulators exactly
								// as an emission would (the decoder's replay redoes
								// the walk with the saved fields).
								TraceMsg.sub_type <= SUB_MSG_NONE;
								RepeatBranchCnt   <= RepeatBranchCnt + 1;
								CurrICnt          <= 0;
								Hist              <= 1;
								HistCount         <= 1;
							end
							else begin
								// Unpredicted return -> normal IndirectBranchHist,
								// identical to the uninferable-indirect group below.
								// With a jump-target-cache hit the same event goes
								// out as VendorJTC (index instead of UADDR); on a
								// miss the cache learns the target.
								if (jtc_hit) begin
									TraceMsg.tcode         <= NEXUS_MSG_VENDOR_JUMP_TARGET_CACHE;
									TraceMsg.sub.cf.rdata1 <= jtc_idx;
								end
								else begin
									TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY;
									// data write in the dedicated jtc_install port
									if (jtc_en) begin
										JtcValid[jtc_idx] <= 1'b1;
										// pragma translate_off
										assert (jtc_install)
											else $error("%m: task install path without jtc_install (drift)");
										// pragma translate_on
									end
								end
								TraceMsg.sub.cf.rdata0 <= Hist;
								TraceMsg.sub.cf.btype  <= NEXUS_BTYPE_IBRANCH;
								CurrICnt               <= 0;
								Hist                   <= 1;
								HistCount              <= 1;
								PredCnt                <= 0; // IBH walk covers all pending branches
								LastIbhValid           <= 1;
								LastIbhHist            <= Hist;
								LastIbhIcnt            <= CurrICnt + etip_cf.icnt;
								LastIbhAddr            <= next_iaddr_q.q.addr;
								// Replay-sound iff TCODE 57 (absolute index) or
								// the emitted UADDR is 0 (S-7, see declaration).
								LastIbhReplayable      <= jtc_hit || cf_ibh_uaddr_zero;
								// pragma translate_off
								assert (HistRepeatCnt == 0)
									else $error("%m: IBH (unpredicted return) with pending repeated-history buffer -- cf_repeat_drain_hold failed");
								assert (RepeatBranchCnt == 0)
									else $error("%m: IBH (unpredicted return) with pending RepeatBranch count -- cf_repeat_branch_drain_hold failed");
								// pragma translate_on
							end
						end
						UNINFERABLE_JUMP, INTERRUPT, EXCEPTION_IR, EXCEPTION_TRAP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP: begin
							if (repeat_branch_match) begin
								// RepeatBranch: suppress + count (see the RETURN arm).
								TraceMsg.sub_type <= SUB_MSG_NONE;
								RepeatBranchCnt   <= RepeatBranchCnt + 1;
								CurrICnt          <= 0;
								Hist              <= 1;
								HistCount         <= 1;
							end
							else begin
							// Jump-target cache: only plain IBRANCH events
							// participate (interrupt/exception targets keep the
							// full UADDR and do not touch the cache -- decoder
							// mirror: learn/read only on BTYPE=0). Data write in
							// the dedicated jtc_install port.
							if (cf_is_plain_ibh && jtc_hit) begin
								TraceMsg.tcode         <= NEXUS_MSG_VENDOR_JUMP_TARGET_CACHE;
								TraceMsg.sub.cf.rdata1 <= jtc_idx;
							end
							else begin
								TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY;
								if (jtc_en && cf_is_plain_ibh) begin
									JtcValid[jtc_idx] <= 1'b1;
									// pragma translate_off
									assert (jtc_install)
										else $error("%m: task install path without jtc_install (drift)");
									// pragma translate_on
								end
							end
							TraceMsg.sub.cf.rdata0 <= Hist;
							CurrICnt               <= 0;
							Hist                   <= 1;
							HistCount              <= 1;
							PredCnt                <= 0; // IBH walk covers all pending branches
							// Remember the emitted IBH for RepeatBranch matching --
							// only plain IBRANCH-type messages participate.
							if (cf_is_plain_ibh) begin
								LastIbhValid <= 1;
								LastIbhHist  <= Hist;
								LastIbhIcnt  <= CurrICnt + etip_cf.icnt;
								LastIbhAddr  <= next_iaddr_q.q.addr;
								// Replay-sound iff TCODE 57 (absolute index) or
								// the emitted UADDR is 0 (S-7, see declaration).
								LastIbhReplayable <= jtc_hit || cf_ibh_uaddr_zero;
							end
							else begin
								LastIbhValid <= 0;
							end
							// pragma translate_off
							assert (HistRepeatCnt == 0)
								else $error("%m: IBH (uninferable CF) with pending repeated-history buffer -- cf_repeat_drain_hold failed");
							assert (RepeatBranchCnt == 0)
								else $error("%m: IBH (uninferable CF) with pending RepeatBranch count -- cf_repeat_branch_drain_hold failed");
							// pragma translate_on

							case (etip_cf.itype)
								// EXCEPTION_IR (mret/sret) returns from a trap. From the
								// decoder's perspective it is an indirect branch, not an
								// interrupt entry -- mapping it to IBRANCH keeps the
								// handler-body halfwords on a BTYPE=IBRANCH IBH instead
								// of inflating BTYPE=INTERRUPT IBHs (whose ICNT must
								// reflect only the gap from the previous CF to the trap).
								UNINFERABLE_JUMP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, EXCEPTION_IR: begin
									TraceMsg.sub.cf.btype <= NEXUS_BTYPE_IBRANCH;
								end
								INTERRUPT: begin
									TraceMsg.sub.cf.btype <= NEXUS_BTYPE_INTERRUPT;
								end
								EXCEPTION_TRAP: begin
									TraceMsg.sub.cf.btype <= NEXUS_BTYPE_EXCEPTION;
								end
								default: begin
								end
							endcase
							end
						end
						default: begin
							TraceMsg.sub_type <= SUB_MSG_NONE;
						end
					endcase
				end
				default: begin
					TraceMsg.sub_type <= SUB_MSG_NONE;
				end
			endcase
		end
	endtask

	// ----------------------------------------------
	// TASK: send_hist_overflow_msg
	// ----------------------------------------------
	task send_hist_overflow_msg;
		input tip_time_t ts;
		input logic [NEXUS_MSG_RDATA_WIDTH-1:0] hist;

		// RCODE=1 (HIST_OVERFLOW) carries no ICNT field. The decoder
		// resolves the flushed branch bits by walking the program
		// (PCInfo) from its current PC, and subtracts the half-words it
		// walks from the next ICNT-bearing packet. So CurrICnt is NOT
		// reset here: it keeps accumulating across the flush and the next
		// history-bearing message (IBH / sync / correlation) reports the
		// full span; the decoder's subtraction makes it count exactly
		// once. This matches the reference software encoder NexRvEnco
		// (its ResourceFull path leaves encoICNT untouched) and the
		// inline HistCount-overflow path in send_cf_msg. Only HIST is
		// flushed and reset here. (Zeroing CurrICnt dropped the
		// non-HIST-covered half-words and desynced the decoder at the
		// next periodic sync — see tests/instruction/03_stress and
		// tests/combined/01_all.)
		TraceMsg.sub_type         <= SUB_MSG_CF;
		TraceMsg.tcode            <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
		TraceMsg.ts               <= ts;
		TraceMsg.sub.cf.rcode     <= NEXUS_RCODE_HIST_OVERFLOW;
		TraceMsg.sub.cf.rdata0    <= hist;
		Hist                      <= 1;
		HistCount                 <= 1;
		LastIbhValid              <= 0;

		// pragma translate_off
		// Spec Table 4-3: HIST is `stop_bit | data_bits`. A value of 0x1 is
		// just the stop bit with zero data bits -- pure noise on the wire.
		// NexRv silently drops it (`if (RDATA > 1)`), but on the ATB it
		// still burns message overhead. If this fires the caller is flushing
		// HIST with no bits to flush; fix the caller's guard instead.
		assert (hist > 'b1)
			else $error("%m: send_hist_overflow_msg called with empty HIST (rdata0=0x1) -- caller should use RCODE=0 path");
		// pragma translate_on
	endtask

	// ----------------------------------------------
	// TASK: send_hist_repeat_msg
	// ----------------------------------------------
	task send_hist_repeat_msg;
		input tip_time_t ts;

		// Emit the buffered repeated-history run: ResourceFull with
		// RCODE=2 (HIST_OVERFLOW_REPEATED, rdata0=pattern, rdata1=count)
		// when the pattern occurred more than once, plain RCODE=1
		// otherwise (matching NexRvEnco's emit-on-mismatch path). Like
		// send_hist_overflow_msg this carries no ICNT field, so CurrICnt
		// is left untouched -- the decoder subtracts the half-words it
		// walks (count x pattern) from the next ICNT-bearing packet
		// (NexRvDeco resourceFull_ICNT). The formatter appends RDATA1
		// automatically for RCODE=2.
		TraceMsg.sub_type      <= SUB_MSG_CF;
		TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
		TraceMsg.ts            <= ts;
		TraceMsg.sub.cf.rdata0 <= HistRepeatPrev;
		if (HistRepeatCnt > 1) begin
			TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_HIST_OVERFLOW_REPEATED;
			TraceMsg.sub.cf.rdata1 <= HistRepeatCnt;
		end
		else begin
			TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_HIST_OVERFLOW;
			TraceMsg.sub.cf.rdata1 <= '0;
		end
		HistRepeatCnt <= 0;
		LastIbhValid  <= 0;

		// pragma translate_off
		assert (HistRepeatCnt != 0)
			else $error("%m: send_hist_repeat_msg called with empty repeat buffer");
		assert (HistRepeatPrev > 'b1)
			else $error("%m: send_hist_repeat_msg buffered pattern is empty (0x%0h)", HistRepeatPrev);
		// pragma translate_on
	endtask

	// ----------------------------------------------
	// TASK: send_icnt_overflow_msg
	// ----------------------------------------------
	task send_icnt_overflow_msg;
		input tip_time_t ts;
		input logic [31:0] icnt;

		// RCODE=0 (ICNT_OVERFLOW): carry the accumulated halfwords out to
		// the decoder and reset CurrICnt so the next real packet's ICNT
		// field can fit. HIST is preserved.
		TraceMsg.sub_type         <= SUB_MSG_CF;
		TraceMsg.tcode            <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
		TraceMsg.ts               <= ts;
		TraceMsg.sub.cf.rcode     <= NEXUS_RCODE_ICNT_OVERFLOW;
		// Same split as icnt_drain_value/_residue above: all four call sites
		// pass CurrICnt, which can stand above the cap (see there). Send at
		// most MAX_NEXUS_ICNT and keep the excess, instead of clamping it
		// away -- the decoder's ICNT adjustment accumulator sums both drains.
		TraceMsg.sub.cf.rdata0    <= (icnt > MAX_NEXUS_ICNT) ? MAX_NEXUS_ICNT : icnt;
		CurrICnt                  <= (icnt > MAX_NEXUS_ICNT)
		                             ? ICNT_ACC_W'(icnt - MAX_NEXUS_ICNT) : '0;
		LastIbhValid              <= 0;
	endtask

	// ----------------------------------------------
	// TASK: send_repeat_branch_msg
	// ----------------------------------------------
	task send_repeat_branch_msg;
		input tip_time_t ts;

		// Close a RepeatBranch run: TCODE 30 with BCNT = number of
		// SUPPRESSED identical IBHs (the decoder replays its saved
		// previous message BCNT more times). After this the wire-previous
		// message is the TCODE 30 itself, so the remembered IBH is
		// invalidated -- a further identical IBH must be emitted in full
		// before a new run can start (mirrors NexRvEnco:381-384).
		TraceMsg.sub_type      <= SUB_MSG_CF;
		TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_REPEAT_BRANCH;
		TraceMsg.ts            <= ts;
		TraceMsg.sub.cf.rdata0 <= RepeatBranchCnt;
		RepeatBranchCnt        <= 0;
		LastIbhValid           <= 0;

		// pragma translate_off
		assert (RepeatBranchCnt != 0)
			else $error("%m: send_repeat_branch_msg called with empty count");
		// pragma translate_on
	endtask

	// ----------------------------------------------
	// TASK: send_repeat_instr_msg
	// ----------------------------------------------
	task send_repeat_instr_msg;
		input tip_time_t ts;

		// Close a RepeatInstruction run (ISTO 4.3.14, TCODE 31): R-CNT =
		// counted silent iterations, I-CNT = halfwords up to AND INCLUDING
		// the run's first (normally accounted) loop execution, HIST = the
		// pending bits incl. that first iteration's taken bit. Decoder
		// (NexRv arm): walk I-CNT with HIST (lands back on the loop PC),
		// then re-emit the loop PC R-CNT times WITHOUT touching any ICNT
		// accounting; ICNT restarts at zero after this message. The eTIP
		// that triggered the drain stays queued and is consumed next.
		TraceMsg.sub_type      <= SUB_MSG_CF;
		TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION;
		TraceMsg.ts            <= ts;
		TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_NONE;
		TraceMsg.sub.cf.icnt   <= CurrICnt;
		TraceMsg.sub.cf.rdata0 <= Hist;
		TraceMsg.sub.cf.rdata1 <= NEXUS_MSG_RDATA_WIDTH'(RptInstrCnt);
		CurrICnt      <= 0;
		Hist          <= 1;
		HistCount     <= 1;
		RptInstrCnt   <= 0;
		LastIbhValid  <= 0;
		PredCnt       <= 0;

		// pragma translate_off
		assert (RptInstrCnt != 0)
			else $error("%m: send_repeat_instr_msg called with empty count");
		// pragma translate_on
	endtask

	// ----------------------------------------------
	// TASK: send_branch_predict_msg
	// ----------------------------------------------
	task send_branch_predict_msg;
		input tip_time_t ts;

		// Vendor TCODE 56 on a mispredicted direct branch: BCNT = PredCnt =
		// number of correctly predicted branches since the last PC-walking
		// emission; the decoder eagerly walks those predictor-resolved plus
		// this branch with the INVERTED prediction, then subtracts the
		// walked halfwords from the next ICNT-bearing packet (RCODE-1/2
		// convention -- no ICNT field here, CurrICnt is left accumulating
		// by the caller). BCNT=0 is legal and common (back-to-back
		// mispredicts, cold counters).
		TraceMsg.sub_type      <= SUB_MSG_CF;
		TraceMsg.tcode         <= NEXUS_MSG_VENDOR_BRANCH_PREDICT;
		TraceMsg.ts            <= ts;
		TraceMsg.sub.cf.rdata0 <= PredCnt;
		PredCnt                <= 0;
		LastIbhValid           <= 0;
	endtask

	// ----------------------------------------------
	// TASK: send_df_msg
	// ----------------------------------------------
	task send_df_msg;
		input etip_df_msg_struct_t          etip_df;
		input tip_time_t    ts;

		TraceMsg.sub_type               <= SUB_MSG_DF;
		TraceMsg.ts                     <= ts;
		TraceMsg.sub.df_daq.data        <= etip_df.data;
		TraceMsg.sub.df_daq.dsz         <= etip_df.dsz;
		TraceMsg.sub.df_daq.elsz        <= etip_df.elsz;
		TraceMsg.sub.df_daq.addr_idtag  <= etip_df.addr_idtag;

		case (etip_df.dtype)
			LOAD: begin
				TraceMsg.tcode <= NEXUS_MSG_DATA_TRACE_READ;
			end
			STORE: begin
				TraceMsg.tcode <= NEXUS_MSG_DATA_TRACE_WRITE;
			end
			default: begin
			end
		endcase
		LastIbhValid <= 0;
	endtask

	// ----------------------------------------------
	// TASK: send_daq_msg
	// ----------------------------------------------
	task send_daq_msg;
		input etip_daq_msg_struct_t         etip_daq;
		input tip_time_t                    ts;

		TraceMsg.sub_type               <= SUB_MSG_DAQ;
		TraceMsg.ts                     <= ts;
		TraceMsg.sub.df_daq.data        <= etip_daq.data;
		TraceMsg.sub.df_daq.addr_idtag  <= etip_daq.addr_idtag;
		TraceMsg.tcode                  <= NEXUS_MSG_DATA_ACQUISITION;
		LastIbhValid                    <= 0;
	endtask

	// ----------------------------------------------
	// TASK: send_flush_msg
	// ----------------------------------------------
	task send_flush_msg;
		TraceMsg.sub_type   <= SUB_MSG_OTHER;
		TraceMsg.tcode      <= NEXUS_MSG_FLUSH;
		LastIbhValid        <= 0;
	endtask

	// ----------------------------------------------
	// TASK: send_other_msg
	// ----------------------------------------------
	task send_other_msg;
		input etip_other_msg_struct_t etip_other;
		input tip_time_t ts;

		TraceMsg.sub_type <= SUB_MSG_OTHER;
		TraceMsg.ts       <= ts;
		TraceMsg.tcode    <= etip_other.tcode;

		case (etip_other.tcode)
			NEXUS_MSG_ERROR: begin
				TraceMsg.sub.err.etype <= etip_other.etype;
				TraceMsg.sub.err.ecode <= etip_other.ecode;
			end
			NEXUS_MSG_OWNERSHIP_TRACE: begin
				// Ownership (TCODE 2, B6): PROCESS payload passes through.
				// Compile-gated (4a zero-cost-when-off; the composer never
				// raises the slot with the feature off).
				if (ct_pkg::CT_EN_OWNERSHIP) begin
					TraceMsg.sub.other._process <= nexus_process_t'(etip_other.payload);
				end
			end
			NEXUS_MSG_WATCHPOINT: begin
				// Watchpoint (TCODE 15, P4): the WPHIT bitmap passes through
				// from the same generic eTIP payload slot as PROCESS (the
				// two message types are mutually exclusive per eTIP entry).
				// Compile-gated (4a zero-cost-when-off).
				if (ct_pkg::CT_EN_WATCHPOINT_MSG) begin
					TraceMsg.sub.other.wphit <= NEXUS_MSG_WPHIT_IMPL_WIDTH'(etip_other.payload);
				end
			end
			// NEXUS_MSG_DEVICE_ID (TCODE 1, P4) needs no arm: the ID is an
			// elaboration parameter sampled at the EMISSION site (config
			// message pattern), so the default arm's zeroing is exactly
			// right -- the eTIP slot carried only the trigger.
			default: begin
				TraceMsg.sub.other <= '0;
			end
		endcase
		LastIbhValid <= 0;
	endtask

	assign trace_msg = TraceMsg;

	// ----------------------------------------------------------------
	// Standing invariants (SVA, simulation only).
	// ----------------------------------------------------------------
	// pragma translate_off
`ifndef SYNTHESIS
	// I6: on a correlation message (trace-off / debug / low-power) the JTC
	// mirror and PredCnt are cleared -- the decoder starts the next session
	// cold, so the encoder has to as well.
	a_i6_corr_clears_models: assert property (@(posedge proc_clk) disable iff (proc_rst)
		(TraceMsg.sub_type == SUB_MSG_CF
		 && TraceMsg.tcode == NEXUS_MSG_PROGRAM_TRACE_CORRELATION)
		|-> (JtcValid == '0 && PredCnt == 0))
		else $error("%m I6: correlation without JTC/PredCnt clear");

	// I7 (overflow-recovery contract): the FIFO_OVERRUN recovery sync is a
	// PURE re-anchor, so the emitted ICNT must be 0.
	// The TCODE gate is required: the correlation / drain arm does not
	// rewrite sync_reason (the union retains the predecessor message's
	// value), so without the gate the property would fire on a correlation
	// message that FOLLOWS a recovery.
	a_i7_ovf_sync_pure_anchor: assert property (@(posedge proc_clk) disable iff (proc_rst)
		(TraceMsg.sub_type == SUB_MSG_CF
		 && TraceMsg.tcode inside {NEXUS_MSG_PROGRAM_TRACE_SYNC,
		                           NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC,
		                           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC,
		                           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC}
		 && TraceMsg.sub.cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN)
		|-> (TraceMsg.sub.cf.icnt == 0))
		else $error("%m I7: FIFO_OVERRUN sync with ICNT != 0");

	// I12 (N-Trace 1.0 field-width conformance): the I-CNT variable of a
	// program-trace message holds at most NEXUS_MSG_I_CNT_WIDTH bits, i.e.
	// MAX_NEXUS_ICNT -- raised to NEXUS_MSG_I_CNT_WIDTH_WIDE by
	// trTeInstFeatures.InstEnWideIcnt (Accemic wide-ICNT compression), which is
	// why the bound is the runtime expression and not a constant.
	//
	// This is a CONFORMANCE invariant, not a functional one, and that is
	// exactly why it needs an assertion: the field is MSEO-variable-length, so
	// an over-cap value costs one more wire byte and decodes correctly. No
	// decode gate, no PC comparison and no byte-neutrality gate in this tree
	// can see it -- the stream stays lossless while leaving the standard. Seven
	// inline drain arms did precisely that until 2026-08-12 (see
	// icnt_drain_value above); an assertion is the only channel that makes the
	// class visible where it arises, in every testbench that runs.
	//
	// TCODE gate, and it is load-bearing: `sub` is a union whose cf.icnt keeps
	// the PREDECESSOR message's value on a message type that has no ICNT field
	// (the same reason I7 carries one). The list is the set of ICNT-bearing
	// wire formats as the FORMATTER builds them (ct_L2_nexus_formatter.sv, the
	// `'{ICNT, VARIABLE, cf.icnt, ...}` sites) -- not the format table in
	// nexus_vendor_riscv_pkg, which is documentation with no RTL consumer and
	// spells out only two of them.
	a_i12_icnt_field_cap: assert property (@(posedge proc_clk) disable iff (proc_rst)
		(TraceMsg.sub_type == SUB_MSG_CF
		 && TraceMsg.tcode inside {NEXUS_MSG_PROGRAM_TRACE_SYNC,
		                           NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH,
		                           NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC,
		                           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH,
		                           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC,
		                           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY,
		                           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC,
		                           NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION,
		                           NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC,
		                           NEXUS_MSG_PROGRAM_TRACE_CORRELATION,
		                           NEXUS_MSG_VENDOR_JUMP_TARGET_CACHE})
		|-> (TraceMsg.sub.cf.icnt <= MAX_NEXUS_ICNT))
		else $error("%m I12: TCODE %0d carries ICNT %0d > cap %0d -- the N-Trace I-CNT field is %0d bit",
			TraceMsg.tcode, TraceMsg.sub.cf.icnt, MAX_NEXUS_ICNT,
			(CT_EN_WIDE_ICNT && cs_proc.trTeInstEnWideIcnt)
				? NEXUS_MSG_I_CNT_WIDTH_WIDE : NEXUS_MSG_I_CNT_WIDTH);

	// I12b: the same cap on the OTHER wire carrier of an instruction count --
	// ResourceFull with RCODE=0 (ICNT_OVERFLOW), where the count rides in
	// RDATA. RCODE 1 (HIST) and 2 (repeated HIST) put a history pattern and a
	// repeat count there and are NOT bound by the I-CNT width, hence the RCODE
	// gate.
	a_i12_rcode0_cap: assert property (@(posedge proc_clk) disable iff (proc_rst)
		(TraceMsg.sub_type == SUB_MSG_CF
		 && TraceMsg.tcode == NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL
		 && TraceMsg.sub.cf.rcode == NEXUS_RCODE_ICNT_OVERFLOW)
		|-> (TraceMsg.sub.cf.rdata0 <= MAX_NEXUS_ICNT))
		else $error("%m I12: ResourceFull(RCODE=0) carries ICNT %0d > cap %0d",
			TraceMsg.sub.cf.rdata0, MAX_NEXUS_ICNT);
`endif
	// pragma translate_on

	// trTeControl.Empty chain: no message output presented and no repeat
	// substance held back (the repeated-history buffer and the RepeatBranch /
	// RepeatInstruction counters are suppressed messages that have not been
	// emitted yet). LastIbh*, the branch predictor and the JTC mirror are
	// compression STATE of already emitted messages and do not count.
	assign msg_gen_idle = (TraceMsg.sub_type == SUB_MSG_NONE)
		&& (HistRepeatCnt   == 0)
		&& (RepeatBranchCnt == 0)
		&& (RptInstrCnt     == '0);

	// pragma translate_off
	// Consume-stall watchdog (sim only): a valid eTIP head that is not
	// consumed for 512 consecutive ready cycles is a hold deadlock -- dump
	// the hold bits and the head's fields once, so silent in-flight rests
	// (slot-balance delta > 0) are diagnosable without waves.
	int unsigned StallCnt = 0;
	always @(posedge proc_clk) begin
		if (proc_rst) StallCnt <= 0;
		else if (etip_q.valid && ready_in && !consume_etip) begin
			StallCnt <= StallCnt + 1;
			if (StallCnt == 512) begin
				$display("*** WARN (%m): eTIP head stalled 512 ready cycles: sub_type=%0d itype=%0d sync=%0d rcode=%0d icnt=%0d needs_nia=%0b nia_valid=%0b holds{ind=%0b sync=%0b rpt=%0b rb=%0b bp=%0b btm=%0b syncicnt=%0b}",
					etip_msg.sub_type, etip_cf.itype, etip_cf.sync_reason, etip_cf.rcode, etip_cf.icnt,
					cf_needs_next_iaddr, next_iaddr_q.valid,
					cf_indirect_hist_overflow_hold, cf_sync_hist_flush_hold,
					cf_repeat_drain_hold, cf_repeat_branch_drain_hold, cf_bp_icnt_drain_hold,
					cf_btm_icnt_overflow_hold, cf_sync_icnt_overflow_hold);
			end
		end
		else StallCnt <= 0;
	end
	// pragma translate_on

endmodule

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
