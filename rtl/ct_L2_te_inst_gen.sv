// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder layer 2 E-Trace te_inst generator (eTIP -> te_inst packets).
 *
 * @details
 *   Consumes the same eTIP stream as ct_L2_msg_gen and produces "Efficient
 *   Trace for RISC-V" v2.0 te_inst packets (baseline algorithm, instruction
 *   trace only). The event mapping mirrors the reference encoder model
 *   (third_party/riscv-trace-spec-ref/scripts/encoder_model.py):
 *
 *     plain TAKEN/NONTAKEN branch  -> branch_map bit (0 = taken, LSB oldest);
 *                                     31st bit -> Format 1 without address
 *     uninferable discontinuity    -> Format 1 (pending branches) or Format 2
 *                                     with differential address = jump target
 *     trap (EXCEPTION/INTERRUPT)   -> flush F1/F2 at the trap point, then a
 *                                     DEFERRED Format 3.1 (thaddr=1, handler
 *                                     address) -- deferred one event so the
 *                                     sync "branch" bit can be resolved when
 *                                     the anchor instruction is a branch
 *     enable sync (first beat)     -> Format 3.3 SUPPORT (ienable=1) +
 *                                     Format 3.0 full-address anchor
 *     FIFO overrun sync            -> F3.3 SUPPORT qual=trace_lost + F3.0
 *     trace-off / corr rcodes      -> flush F1/F2 + F3.3 SUPPORT (ienable=0,
 *                                     qual=ended_rep)
 *     composer ICNT drains         -> consumed silently (E-Trace has no ICNT)
 *
 *   Restrictions of this implementation: control-flow-only profile (see the
 *   elaboration guard below). Mid-trace composer syncs (periodic / REQ /
 *   EVTI / SEQ) re-anchor through a deferred Format 3.0 (RsyncPend).
 *   ecause, tval, priv and ilastsize ride the eTIP sideband.
 */

module ct_L2_te_inst_gen (
	input uwire logic                                 proc_clk,
	input uwire logic                                 proc_rst,
	ct_cs_procclk_if.slave                            cs_proc,

	source_if.client                                  etip_q,
	source_if.client                                  next_iaddr_q,

	// Packet output (to ct_L2_te_packetizer)
	output logic [ct_pkg::CT_ETRACE_PKT_MAX_BITS-1:0] pkt_payload,
	output logic [7:0]                                pkt_nbits,
	output logic [1:0]                                pkt_mtype,
	output logic                                      pkt_valid,
	input uwire logic                                 pkt_ready,

	// trTeControl.Empty chain: 1 means no packet is presented and no emission
	// substance is held back (branch-map bits, a deferred trap anchor, a
	// pending updiscon, a pending re-anchor, the BP count). The JTC and
	// branch-predictor mirrors are compression state and do not count.
	output uwire logic                                gen_idle
);
	import ct_pkg::*;
	import ct_etip_pkg::*;
	import tip_pkg::*;
	import nexus_vendor::*;
	import nexus::*;

	// DF beats become te_data packets (unified load/store; format field is
	// 2 bits per spec because only unified load/store is offered); DAQ/ACT
	// beats become vendor packets (raw-framing msg_type 1 -- the framing is
	// a reference-toolchain convention, not spec; documented in
	// PLAN_etrace_df_daq). No open third-party te_data implementation
	// exists (reference models stub data trace) -- conformance rests on the
	// dataTracePayload spec tables plus our own decoder mirror.

	localparam int unsigned AB = CT_ETRACE_ADDR_BITS; // 31

	uwire etip_msg_struct_t    etip_msg = etip_msg_struct_t'    (etip_q.q);
	uwire etip_cf_msg_struct_t etip_cf  = etip_cf_msg_struct_t' (etip_msg.sub.cf);

	// ------------------------------------------------------------------
	// Beat classification
	// ------------------------------------------------------------------
	uwire is_cf     = (etip_msg.sub_type == SUB_MSG_CF);
	uwire is_df     = CT_EN_DATA_TRACE && (etip_msg.sub_type == SUB_MSG_DF);
	uwire is_daq    = (CT_EN_DAQ || CT_EN_ACT) && (etip_msg.sub_type == SUB_MSG_DAQ);
	uwire etip_df_msg_struct_t  etip_df  = etip_df_msg_struct_t' (etip_msg.sub.df);
	uwire etip_daq_msg_struct_t etip_daq = etip_daq_msg_struct_t'(etip_msg.sub.daq);
	uwire cf_branch = is_cf && (etip_cf.itype inside {TAKEN_BRANCH, NOT_TAKEN_BRANCH});

	// Implicit-return mode (E-Trace standard optional mode; ioptions bit 0):
	// a RETURN whose target the composer's return-address stack predicted is
	// SILENT -- the decoder pops its own mirrored stack while walking. A
	// mispredicted return stays a reported updiscon (the composer flags the
	// prediction result on the next_iaddr sideband, same source msg_gen uses).
	//
	// The composer's ret_predicted sideband is AUTHORITATIVE, including on
	// beats that carry a mid-trace sync_reason (PERIODIC/quota/marker): the
	// composer popped its stack for this return, the decoder mirror pops in
	// lockstep, and neither irreport nor irdepth is expressible on this wire
	// (irdepth width 0, irreport canonical) -- so an EXPLICIT report of a
	// predictable return can never be re-synchronized by the decoder. A
	// sync_reason == NONE term here did exactly that: a periodic sync
	// anchoring ON a RETURN retire forced the report, the decoder folded the
	// return implicitly and mis-bound the address to the next discontinuity
	// (P10 soak finding S-1, seed 1611636046: 6 phantom PCs per resync).
	// Beats the composer anchors WITHOUT popping (TRACE_ENABLE/EXIT_* gap
	// re-anchors, the injected FIFO_OVERRUN beat) carry ret_predicted = 0 by
	// composer construction and stay explicit.
	uwire ir_en = CT_EN_IMPLICIT_RETURN && cs_proc.trTeInstEnImplicitReturn;
	uwire return_is_predicted = ir_en && is_cf
		&& (etip_cf.itype == RETURN)
		&& (etip_cf.rcode == NEXUS_RCODE_NONE)
		&& next_iaddr_q.valid && next_iaddr_q.q.ret_predicted;

	// Updiscon set of the reference model with implicit-return OFF, plus
	// EXCEPTION_IR (mret/sret: an uninferable discontinuity for the decoder;
	// the baseline model never sees itype 3 from its own flow, we do).
	uwire cf_updiscon = is_cf && !return_is_predicted && (etip_cf.itype inside {
		EXCEPTION_IR, UNINFERABLE_JUMP, UNINFERABLE_CALL,
		UNINFERABLE_TAIL_CALL, CO_ROUTINE_SWAP, RETURN, OTHER_UNINFERABLE_JUMP});
	uwire cf_trap   = is_cf && (etip_cf.itype inside {EXCEPTION_TRAP, INTERRUPT});

	uwire cf_needs_nia = is_cf && HasChangedControlFlow(etip_cf.itype);

	uwire is_icnt_drain = is_cf && (etip_cf.rcode == NEXUS_RCODE_ICNT_OVERFLOW);
	uwire is_off        = is_cf && (etip_cf.rcode inside {NEXUS_RCODE_TRACE_DISABLED,
	                                                      NEXUS_RCODE_CORR_DEBUG_ENTRY,
	                                                      NEXUS_RCODE_CORR_LOW_POWER});
	uwire has_sync      = is_cf && (etip_cf.rcode == NEXUS_RCODE_NONE)
	                            && (etip_cf.sync_reason != NEXUS_SYNC_NONE);
	uwire sync_ovf      = has_sync && (etip_cf.sync_reason == NEXUS_SYNC_FIFO_OVERRUN);

	uwire tip_iaddr_t nia = next_iaddr_q.q.addr;

	// ------------------------------------------------------------------
	// Algorithm state
	// ------------------------------------------------------------------
	logic                Started   = 1'b0;
	logic [30:0]         Map       = '0;   // bit0 = oldest, 0 = taken
	logic [5:0]          Branches  = '0;   // 0..31
	tip_iaddr_t          LastAddr  = '0;   // last address sent (differential base)
	// Decoder POSITION (distinct from the differential base): after an
	// address packet it equals that packet's target, but after a Format-1-
	// without-address the decoder stops AT the 31st-bit branch holding one
	// pending bit -- flush/skip gates must key on THIS, not on LastAddr
	// (found via the f1ntrap leg: an F2 onto the decoder's own position
	// makes it consume the pending bit and walk away).
	tip_iaddr_t          DecPos    = '0;
	logic                TaValid   = 1'b0; // deferred trap-anchor pending
	tip_iaddr_t          TaAddr    = '0;   // trap handler address
	logic                TaIntr    = 1'b0;
	logic [3:0]          TaEc      = '0;   // trap cause (latched at the trap beat)
	tip_iaddr_t          TaTval    = '0;   // trap value (exceptions)
	logic [2:0]          TaPriv    = 3'd3; // privilege at the trap
	// Deferred anchor flavor: 0 = F3.1 thaddr=1 (normal trap), 1 = F3.0
	// START (used after an F3.1 thaddr=0 -- trap hit the UNRETIRED target
	// of the preceding updiscon, model's prev_updiscon/curr_exc_only path).
	logic                TaStart   = 1'b0;

	// One-beat deferral of updiscon reports (model 3-stage pipeline): the
	// packet address depends on whether the jump TARGET retires -- a trap/
	// trace-off immediately after (icnt==0) means it did NOT, and the
	// packet must carry the updiscon's OWN address instead (model
	// next_exc_only path; reporting the unretired target would make the
	// decoder walk a phantom PC). Resolved at the next accepted beat.
	logic                PuValid = 1'b0;
	tip_iaddr_t          PuOwn   = '0;  // updiscon instruction address
	tip_iaddr_t          PuTgt   = '0;  // its target (next_iaddr)
	logic [30:0]         PuMap   = '0;  // pending branch map at that point
	logic [5:0]          PuBr    = '0;
	logic                PuBpVal = 1'b0; // updiscon hit while in COUNT mode
	logic [31:0]         PuBpCnt = '0;

	// Mid-trace resync (Q2, 2026-07-25): a composer sync beat (PERIODIC /
	// REQ / EVTI / SEQ) while started arms a pending re-anchor instead of
	// being dropped. The Format 3.0 is emitted at the NEXT accepted CF beat
	// whose map is empty and whose iaddr differs from the decoder position
	// (the walk from DecPos to the anchor is then branch-free by
	// construction; silent inferables/IR-folds are resolved by the decoder
	// itself). A branch anchor rides the F3.0 branch field, mirroring the
	// deferred-trap-anchor mechanics.
	logic                RsyncPend = 1'b0;

	// Post-overflow re-anchor (P10 soak, gen_S_E idx 227): the composer's
	// FIFO_OVERRUN sync rides an INJECTED beat (ovf_inject_msg1) whose
	// itype is OTHER and whose priv is '0 -- the anchor address is the
	// resume point (PrevIAddr + size), but whether the instruction THERE is
	// a branch, and how it resolves, is unknowable at injection time. An
	// immediate F3.0 therefore lied in both fields whenever the resume
	// address held a branch (observed on the wire: f30 branch=1 privilege=0
	// at a taken branch; the decoder walked the not-taken arm, 26 PCs off
	// the reference, then died on leftover map bits). Same deferral idea as
	// TaValid/RsyncPend: announce the loss NOW (F3.3 qual=trace_lost, the
	// decoder is back in start_of_trace and clears its mirrors), anchor at
	// the FIRST conclusive CF beat -- its itype names the branch outcome
	// and its priv is authentic.
	logic                OvfPend = 1'b0;

	// Jump-target cache (E-Trace F0.1, optional mode; ioptions bit 3):
	// 64-entry direct-mapped, XOR-fold index (identical to the N-Trace
	// vendor-JTC model in msg_gen). INSTALL on every updiscon target
	// reported BY ADDRESS (the pending-updiscon target resolution) -- the
	// decoder mirrors exactly that rule (install at every uninferable-
	// discontinuity address it walks to); F0.1 hits are read-only on both
	// sides. Cleared at trace-off/overflow (decoder restarts cold).
	localparam int unsigned TE_JTC_ENTRIES = 64;
	tip_iaddr_t          JtcCache [TE_JTC_ENTRIES];
	logic [TE_JTC_ENTRIES-1:0] JtcValid = '0;

	uwire jtc_en = CT_EN_JTC && cs_proc.trTeInstEnJumpTargetCache;

	// Branch prediction (E-Trace F0.0, optional mode; ioptions bit 4):
	// bit-identical predictor model to the N-Trace vendor-BP in msg_gen
	// (2^9 x 2-bit saturating counters, index iaddr[10:2], init weakly-
	// not-taken, epoch-tagged LUTRAM clear). MAP mode accumulates the
	// branch map as usual but tracks per-bit prediction correctness; a
	// FULL map of 31 all-correct bits switches to COUNT mode (no F1N) --
	// further correct predictions only count, a mispredict emits F0.0
	// without address, an updiscon/trap/off in COUNT mode emits F0.0 with
	// address (count rides the address packet).
	localparam int unsigned TE_BP_ENTRIES = 512;
	localparam int unsigned TE_BP_EPOCH_W = 16;
	typedef struct packed {
		logic [TE_BP_EPOCH_W-1:0] tag;
		logic [1:0]               ctr;
	} te_bp_entry_t;
	te_bp_entry_t                     BpTable [TE_BP_ENTRIES];
	logic [TE_BP_EPOCH_W-1:0]         BpEpoch = '0;
	logic                             BpCountMode = 1'b0;
	logic [31:0]                      BpCount     = '0;
	logic [30:0]                      PredOk      = '0; // per-map-bit correctness
	initial for (int i = 0; i < TE_BP_ENTRIES; i++) BpTable[i] = '{tag: '1, ctr: 2'b01};

	uwire bp_en = CT_EN_BP && cs_proc.trTeInstEnBranchPrediction;
	uwire [8:0] bp_idx          = etip_cf.iaddr[10:2];
	uwire te_bp_entry_t bp_rd   = BpTable[bp_idx];
	uwire [1:0] bp_ctr          = (bp_rd.tag == BpEpoch) ? bp_rd.ctr : 2'b01;
	uwire       bp_pred_taken   = bp_ctr[1];
	uwire       bp_actual_taken = (etip_cf.itype == TAKEN_BRANCH);
	uwire       bp_correct      = (bp_pred_taken == bp_actual_taken);

	function automatic logic [1:0] te_bp_next(input logic [1:0] c, input logic t);
		if (t) return (c == 2'b11) ? 2'b11 : c + 2'b01;
		else   return (c == 2'b00) ? 2'b00 : c - 2'b01;
	endfunction
	uwire [5:0] jtc_idx_pu = PuTgt[7:2] ^ PuTgt[13:8] ^ PuTgt[19:14] ^ PuTgt[25:20];
	uwire jtc_hit_pu = jtc_en && PuValid && JtcValid[jtc_idx_pu]
	                   && (JtcCache[jtc_idx_pu] == PuTgt);

	// Retirement tracking: E-Trace reports the LAST RETIRED instruction at
	// trap/trace-off flush points, but the eTIP beat's iaddr is the FAULTING
	// pc for exceptions (never retired, convention B) and undefined for
	// interrupts (TIP spec; cpu_model drives poison). Reconstruct it from
	// the linear-segment base + the beat's cumulated halfword count and the
	// last instruction's size (ilastsize sideband -- C-ext ready).
	tip_iaddr_t          NextAddr  = '0;   // next address expected to retire
	tip_iaddr_t          LastRet   = '0;   // last retired instruction address
	// Set when instructions retired since the last ADDRESS-carrying packet:
	// a trap/trace-off flush is only needed then. An async trap landing on a
	// just-reported jump target (nothing retired in between) must NOT flush
	// -- the decoder already stands at the right position, and any address
	// (even LastRet) would send it on a stale detour walk.
	logic                RetiredSince = 1'b0;

	// icnt convention (empirically guarded below): the count INCLUDES the
	// event instruction itself for branch/updiscon beats.
	uwire tip_iaddr_t seg_last = NextAddr + (tip_iaddr_t'(etip_cf.icnt) << 1)
	                             - (tip_iaddr_t'(2) << etip_cf.ilastsize);
	uwire tip_iaddr_t flush_tgt = (etip_cf.icnt != 0) ? seg_last : LastRet;

	uwire map_bit  = (etip_cf.itype == NOT_TAKEN_BRANCH); // 0 = taken
	uwire sync_br  = !(is_cf && (etip_cf.itype == TAKEN_BRANCH)); // F3 "branch" field
	// Deferred-F3.1 resolution: the pending anchor instruction turned out to
	// be this very branch beat -> its outcome rides the sync branch field.
	uwire ta_hit_branch = TaValid && cf_branch && !has_sync
	                      && (etip_cf.rcode == NEXUS_RCODE_NONE)
	                      && (etip_cf.iaddr == TaAddr);

	// ------------------------------------------------------------------
	// Packet descriptors (up to 3 per beat, precomputed at acceptance)
	// ------------------------------------------------------------------
	typedef enum logic [3:0] {
		TE_K_F30, TE_K_F31, TE_K_F33, TE_K_F1A, TE_K_F1N, TE_K_F2, TE_K_F01,
		TE_K_F00N, TE_K_F00A, TE_K_TD, TE_K_DAQ
	} te_kind_e;

	typedef struct packed {
		te_kind_e     kind;
		logic [AB-1:0] addr31;  // full (F3.x) or differential (F1/F2), >>1
		// updiscon FLAG (differential trailer encoding happens at packing):
		// set on every address packet that reports the TARGET of an
		// uninferable discontinuity. The spec provides the flag exactly for
		// the case where that target is also reachable by executing to it
		// WITHOUT the discontinuity -- the decoder then keeps walking until
		// the address is reached AS a discontinuity target instead of
		// stopping at the first (linear) arrival. The reference encoder sets
		// it selectively (prev_updiscon && exception/priv-change/resync
		// pending) because its pipeline lacks retirement evidence; CTTE's
		// Pu deferral guarantees the target retired, so setting it on every
		// target report is always walkable and closes the whole ambiguity
		// class (P10 soak S-1/S-2: an early stop pending when a mid-stream
		// F3.0 arrives is unhealable -- the sync clears inferred_address).
		logic          updiscon;
		logic          branch;  // F3.0/F3.1 branch field
		logic          intr;    // F3.1
		logic          th0;     // F3.1: thaddr=0 (EPC report, no anchor)
		logic [2:0]    priv;    // F3.0/F3.1 privilege field
		logic [3:0]    ecause;  // F3.1
		logic [31:0]   tval;    // F3.1 (exceptions)
		logic [4:0]    ioptions; // F3.3 [BP,JTC,FA,IE,IR] (decoder-model order)
		logic [5:0]    jtc_idx; // F0.1 cache index
		logic [31:0]   bp_cnt;  // F0.0 branch_count (correct predictions - 31)
		logic          ienable; // F3.3
		logic [1:0]    qual;    // F3.3
		logic [30:0]   map;
		logic [4:0]    brcnt;   // F1 branches field value (1..30)
		// te_data (unified load/store; widths gated by CT_EN_DATA_TRACE)
		logic [ETIP_DF_DATA_W-1:0] df_data;
		logic [ETIP_DF_ADDR_W-1:0] df_addr; // byte addr (unal) or >> size (aligned)
		logic [1:0]    df_sz;   // access size = 2^df_sz bytes
		logic [2:0]    df_dlen; // data_len value (bytes-1 after sign strip)
		logic          df_store;
		logic          df_unal;
		// vendor DAQ packet (widths gated by CT_EN_DAQ/CT_EN_ACT)
		logic [MAX_DAQ_DATA_ELEMENTS*ETIP_DAQ_ELEM_W-1:0] daq_data;
		logic [7:0]    daq_idtag;
	} te_desc_t;

	function automatic te_desc_t desc_null();
		te_desc_t d;
		d = '{kind: TE_K_F30, addr31: '0, updiscon: 1'b0, branch: 1'b0, intr: 1'b0,
		      th0: 1'b0, priv: 3'd3, ecause: '0, tval: '0, ioptions: '0,
		      jtc_idx: '0, bp_cnt: '0, ienable: 1'b0, qual: 2'd0,
		      map: '0, brcnt: '0,
		      df_data: '0, df_addr: '0, df_sz: '0, df_dlen: '0,
		      df_store: 1'b0, df_unal: 1'b0, daq_data: '0, daq_idtag: '0};
		return d;
	endfunction

	// Differential address field: (target - base) >> 1, two's complement.
	function automatic logic [AB-1:0] diff31(input tip_iaddr_t target,
	                                         input tip_iaddr_t base);
		automatic tip_iaddr_t d = target - base;
		return d[31:1];
	endfunction

	// Flush descriptor for the pending branch map, working on the beat-local
	// running state (map/branch count may already have been modified by an
	// earlier phase of the SAME beat, e.g. a resolved deferred F3.1): F1
	// with address when branches are pending, plain F2 otherwise (model
	// create_branch_packet with_address=1).
	function automatic te_desc_t desc_flush_v(input tip_iaddr_t target,
	                                          input tip_iaddr_t base,
	                                          input logic [30:0] map_v,
	                                          input logic [5:0]  branches_v);
		automatic te_desc_t d = desc_null();
		if (bp_en && BpCountMode) begin
			// COUNT run interrupted by a trap/trace-off flush: the count
			// rides the address packet (map is empty in COUNT mode).
			d.kind   = TE_K_F00A;
			d.bp_cnt = BpCount;
		end
		else if (branches_v != 0) begin
			d.kind  = TE_K_F1A;
			d.brcnt = 5'(branches_v);
			d.map   = map_v;
		end
		else begin
			d.kind  = TE_K_F2;
		end
		d.addr31 = diff31(target, base);
		return d;
	endfunction

	function automatic te_desc_t desc_f30(input tip_iaddr_t addr, input logic br,
	                                      input logic [2:0] priv);
		automatic te_desc_t d = desc_null();
		d.kind   = TE_K_F30;
		d.addr31 = addr[31:1];
		d.branch = br;
		d.priv   = priv;
		return d;
	endfunction

	function automatic te_desc_t desc_f31(input tip_iaddr_t addr, input logic br,
	                                      input logic intr, input logic th0,
	                                      input logic [3:0] ecause,
	                                      input logic [31:0] tval,
	                                      input logic [2:0] priv);
		automatic te_desc_t d = desc_null();
		d.kind   = TE_K_F31;
		d.addr31 = addr[31:1];
		d.branch = br;
		d.intr   = intr;
		d.th0    = th0;
		d.ecause = ecause;
		d.tval   = tval;
		d.priv   = priv;
		return d;
	endfunction

	// data_len value: bytes-1 after stripping upper bytes equal to the
	// sign extension of the remaining value (decoder sign-extends from the
	// MSB of the received bytes; access width = 2^sz bytes).
	function automatic logic [2:0] te_dlen(input logic [63:0] v,
	                                       input logic [1:0] sz);
		automatic int unsigned bytes = 1 << sz;
		automatic int unsigned keep  = bytes;
		for (int i = 7; i >= 1; i--)
			if ((i < bytes) && (keep == i + 1)
			    && (v[8*i +: 8] == {8{v[8*i - 1]}}))
				keep = i;
		return 3'(keep - 1);
	endfunction

	function automatic te_desc_t desc_td(input etip_df_msg_struct_t df);
		automatic te_desc_t d = desc_null();
		automatic logic [1:0] sz;
		automatic logic [31:0] a = 32'(df.addr_idtag);
		case (df.elsz)
			NEXUS_ELSZ_2: sz = 2'd1;
			NEXUS_ELSZ_4: sz = 2'd2;
			NEXUS_ELSZ_8: sz = 2'd3;
			default:      sz = 2'd0;
		endcase
		d.kind     = TE_K_TD;
		d.df_sz    = sz;
		d.df_store = (df.dtype == STORE);
		d.df_unal  = |(a & ((32'd1 << sz) - 1));
		d.df_addr  = ETIP_DF_ADDR_W'(d.df_unal ? a : (a >> sz));
		d.df_data  = df.data;
		d.df_dlen  = te_dlen(64'(df.data), sz);
		return d;
	endfunction

	function automatic te_desc_t desc_daq(input etip_daq_msg_struct_t daq);
		automatic te_desc_t d = desc_null();
		d.kind      = TE_K_DAQ;
		d.daq_idtag = 8'(daq.addr_idtag);
		d.daq_data  = daq.data;
		return d;
	endfunction

	function automatic te_desc_t desc_f33(input logic ien, input logic [1:0] qual);
		automatic te_desc_t d = desc_null();
		d.kind     = TE_K_F33;
		d.ienable  = ien;
		d.qual     = qual;
		// ioptions [IR,IE,FA,JTC,BP] = bits 0..4 (decoder-model order);
		// latched at packet-build time from the runtime enables.
		d.ioptions = {bp_en, jtc_en, 2'b0, ir_en};
		return d;
	endfunction

	function automatic logic [6:0] f1a_mapbits(input logic [4:0] brcnt);
		if (brcnt <= 1)  return 7'd1;
		if (brcnt <= 3)  return 7'd3;
		if (brcnt <= 7)  return 7'd7;
		if (brcnt <= 15) return 7'd15;
		return 7'd31;
	endfunction

	// Compressed byte size of a payload under whole-packet sign
	// compression (same rule as ct_L2_te_packetizer.sig_bytes) -- used for
	// the spec-sanctioned F0.1-vs-F1/F2 size choice ("the encoder may
	// still choose to output the differential address ... if the
	// resulting packet is shorter").
	function automatic logic [3:0] te_sig_bytes_g(
		input logic [CT_ETRACE_PKT_MAX_BITS-1:0] p, input logic [6:0] nbits);
		automatic logic        sign = p[nbits-1];
		automatic int unsigned keep = 1;
		for (int i = 0; i < CT_ETRACE_PKT_MAX_BITS; i++)
			if ((i + 1 < nbits) && (p[i] != sign))
				keep = i + 2;
		return 4'((keep + 7) / 8);
	endfunction

	// Candidate sizes for the F0.1-vs-address choice (packet layouts as in
	// the packing below; header byte excluded -- identical on both sides).
	function automatic logic [3:0] f01_bytes(
		input logic [5:0] brcnt, input logic [30:0] map,
		input logic [5:0] idx);
		automatic logic [CT_ETRACE_PKT_MAX_BITS-1:0] p = '0;
		automatic logic [6:0] nb;
		automatic logic [6:0] mb;
		p[1:0] = 2'd0; p[2] = 1'b1; p[8:3] = idx;
		p[13:9] = 5'(brcnt);
		if (brcnt == 0) begin
			nb = 7'd15;
		end
		else begin
			mb = f1a_mapbits(5'(brcnt));
			for (int i = 0; i < 31; i++)
				if (i < mb) p[14 + i] = map[i];
			p[14 + 32'(mb)] = map[mb - 1];
			nb = 7'(14 + 32'(mb) + 1);
		end
		return te_sig_bytes_g(p, nb);
	endfunction

	function automatic logic [3:0] flush_bytes(
		input tip_iaddr_t target, input tip_iaddr_t base,
		input logic [30:0] map, input logic [5:0] brcnt);
		automatic logic [CT_ETRACE_PKT_MAX_BITS-1:0] p = '0;
		automatic logic [6:0] nb;
		automatic logic [6:0] mb;
		automatic logic [30:0] a31 = diff31(target, base);
		if (brcnt != 0) begin
			mb = f1a_mapbits(5'(brcnt));
			p[1:0] = 2'd1; p[6:2] = 5'(brcnt);
			for (int i = 0; i < 31; i++)
				if (i < mb) p[7 + i] = map[i];
			for (int i = 0; i < 31; i++)
				p[7 + 32'(mb) + i] = a31[i];
			for (int i = 0; i < 3; i++)
				p[7 + 32'(mb) + 31 + i] = a31[30];
			nb = 7'(7 + 32'(mb) + 31 + 3);
		end
		else begin
			p[1:0] = 2'd2; p[32:2] = a31; p[35:33] = {3{a31[30]}};
			nb = 7'd36;
		end
		return te_sig_bytes_g(p, nb);
	endfunction

	localparam logic [1:0] QUAL_NO_CHANGE  = 2'd0;
	localparam logic [1:0] QUAL_ENDED_REP  = 2'd1;
	localparam logic [1:0] QUAL_TRACE_LOST = 2'd2;

	// ------------------------------------------------------------------
	// Emission queue (registered; drained one packet per pkt handshake)
	// ------------------------------------------------------------------
	te_desc_t   Q [3];
	logic [1:0] QCnt = '0;

	uwire q_idle = (QCnt == 0);

	// Accept a beat only with an empty queue and (when the event carries a
	// target) an available next_iaddr side-band entry -- msg_gen's gating.
	uwire accept = q_idle && !proc_rst && etip_q.valid
	               && (!cf_needs_nia || next_iaddr_q.valid);

	assign etip_q.ack       = accept;
	assign next_iaddr_q.ack = accept && cf_needs_nia;

	// BP predictor: dedicated write port (LUTRAM rule), updated with the
	// actual outcome of EVERY accepted direct-branch beat -- the decoder
	// mirrors this at every walked branch.
	uwire bp_upd_now = bp_en && cf_branch && accept;
	always_ff @(posedge proc_clk) begin
		if (bp_upd_now)
			BpTable[bp_idx] <= '{tag: BpEpoch, ctr: te_bp_next(bp_ctr, bp_actual_taken)};
	end

	// pragma translate_off
	// Beat-level trace for bring-up diagnosis: +TE_BEAT_DUMP prints every
	// accepted eTIP beat with the fields the generator acts on.
	always_ff @(posedge proc_clk) begin
		if (!proc_rst && accept && $test$plusargs("TE_BEAT_DUMP"))
			$display("[te_beat] sub=%0d itype=%0d iaddr=%08x icnt=%0d sync=%0d rcode=%0d nia=%08x niav=%b NextAddr=%08x LastRet=%08x RetSince=%b TaV=%b Br=%0d",
				etip_msg.sub_type, etip_cf.itype, etip_cf.iaddr,
				etip_cf.icnt, etip_cf.sync_reason, etip_cf.rcode,
				next_iaddr_q.q.addr, next_iaddr_q.valid,
				NextAddr, LastRet, RetiredSince, TaValid, Branches);
	end
	// Empirical guard for the icnt convention the retirement tracking
	// relies on (count INCLUDES the event instruction for CF events).
	always_ff @(posedge proc_clk) begin
		if (!proc_rst && accept && Started && (cf_branch || cf_updiscon)
		    && !has_sync && (etip_cf.rcode == NEXUS_RCODE_NONE)
		    && (etip_cf.icnt != 0))
			assert (seg_last == etip_cf.iaddr)
				else $error("%m: icnt convention broken: seg_last=%08x != event iaddr=%08x (icnt=%0d NextAddr=%08x)",
					seg_last, etip_cf.iaddr, etip_cf.icnt, NextAddr);
	end
	// pragma translate_on

	always_ff @(posedge proc_clk) begin
		if (proc_rst) begin
			Started  <= 1'b0;
			Map      <= '0;
			Branches <= '0;
			LastAddr <= '0;
			TaValid  <= 1'b0;
			PuValid  <= 1'b0;
			RsyncPend <= 1'b0;
			OvfPend  <= 1'b0;
			RetiredSince <= 1'b0;
			QCnt     <= '0;
		end
		else begin
			// ---- drain ----
			if (pkt_valid && pkt_ready) begin
				Q[0]  <= Q[1];
				Q[1]  <= Q[2];
				QCnt  <= QCnt - 1'b1;
			end
			// ---- accept + plan ----
			if (accept) begin
				automatic te_desc_t nq [3];
				automatic int       n = 0;
				automatic logic [30:0] map_v      = Map;
				automatic logic [5:0]  branches_v = Branches;
				automatic tip_iaddr_t  last_v     = LastAddr;
				automatic logic        addr_sent  = 1'b0;
				automatic tip_iaddr_t  dec_pos_v  = DecPos;
				automatic logic        rsync_ate_branch = 1'b0;
				automatic logic        flush_needed
					= RetiredSince || (is_cf && (etip_cf.icnt != 0));

				automatic logic pu_resolved_own = 1'b0;

				nq[0] = desc_null(); nq[1] = desc_null(); nq[2] = desc_null();

				// DF/DAQ beats are emission-only: no CF state is touched
				// (pending Pu/Ta deferrals wait for the next CF beat -- a
				// data beat carries no retirement evidence either way).
				if (is_df || is_daq) begin
					nq[0] = is_df ? desc_td(etip_df) : desc_daq(etip_daq);
					n = 1;
				end
				else begin

				// Deferred updiscon report resolves first (it is the oldest
				// pending emission): target address when the target retired
				// (any beat with retirement evidence), OWN address when a
				// trap/trace-off with icnt==0 follows directly (the target
				// never retired -- model next_exc_only semantics).
				if (PuValid) begin
					automatic logic tgt_unret =
						(cf_trap || is_off) && is_cf && (etip_cf.icnt == 0);
					if (!PuBpVal && tgt_unret && (PuOwn == dec_pos_v)) begin
						// Own-address resolution onto the decoder's CURRENT
						// position: emit NOTHING. An address packet cannot
						// stand still -- the walk executes at least one
						// instruction, so a delta-0 own report right after
						// an anchor at the same address re-walks the anchor
						// instruction (P10 soak cal idx 43: F3.0 at a
						// self-targeted JI, trace-off with icnt==0, the F2
						// delta 0 duplicated the final PC). Same movement
						// gate the trace-off flush already has
						// (flush_tgt != dec_pos_v). The decoder already
						// sits at the last retired instruction, which is
						// all an own-address report communicates. The
						// BP-COUNT variant must still emit (the packet
						// carries the count); that corner keeps the
						// degenerate walk and is disclosed at the S-1c
						// note in doc/verification.adoc.
						pu_resolved_own = 1'b1;
					end
					else begin
					if (PuBpVal) begin
						// the updiscon interrupted a COUNT run: the count
						// rides the address packet (F0.0 branch_fmt=10)
						nq[n] = desc_null();
						nq[n].kind   = TE_K_F00A;
						nq[n].bp_cnt = PuBpCnt;
						nq[n].addr31 = diff31(tgt_unret ? PuOwn : PuTgt, last_v);
						// target report -> updiscon flag (see te_desc_t);
						// own-address reports are positional (linear arrival
						// is the intended stop) and stay canonical.
						nq[n].updiscon = !tgt_unret;
						if (!tgt_unret && jtc_en) begin
							JtcCache[jtc_idx_pu] <= PuTgt;
							JtcValid[jtc_idx_pu] <= 1'b1;
						end
					end
					else if (!tgt_unret && jtc_hit_pu
					    && (f01_bytes(PuBr, PuMap, jtc_idx_pu)
					        < flush_bytes(PuTgt, last_v, PuMap, PuBr))) begin
						// F0.1: cache index instead of the differential
						// address (read-only on hit, both sides) -- chosen
						// only when actually shorter (spec provision).
						nq[n] = desc_flush_v(PuTgt, last_v, PuMap, PuBr);
						nq[n].kind    = TE_K_F01;
						nq[n].jtc_idx = jtc_idx_pu;
					end
					else begin
						nq[n] = desc_flush_v(tgt_unret ? PuOwn : PuTgt,
						                     last_v, PuMap, PuBr);
						// target report -> updiscon flag (see te_desc_t)
						nq[n].updiscon = !tgt_unret;
						if (!tgt_unret && jtc_en) begin
							JtcCache[jtc_idx_pu] <= PuTgt;
							JtcValid[jtc_idx_pu] <= 1'b1;
						end
					end
					n++;
					addr_sent = 1'b1;
					last_v    = tgt_unret ? PuOwn : PuTgt;
					dec_pos_v = last_v;
					pu_resolved_own = tgt_unret;
					end
					PuValid <= 1'b0;
				end

				// Mid-trace sync beats arm the pending re-anchor (the beat
				// itself still runs through the normal arms below). While a
				// post-overflow re-anchor is pending, a periodic sync is
				// redundant -- the OvfPend F3.0 IS the re-anchor.
				if (has_sync && Started && !sync_ovf && !OvfPend)
					RsyncPend <= 1'b1;

				// Pending deferred Format 3.1 resolves next.
				if (TaValid) begin
					nq[n] = TaStart
						? desc_f30(TaAddr, ta_hit_branch ? map_bit : 1'b1, TaPriv)
						: desc_f31(TaAddr, ta_hit_branch ? map_bit : 1'b1, TaIntr,
						           1'b0, TaEc, TaTval, TaPriv);
					n++;
					addr_sent  = 1'b1;
					last_v     = TaAddr;
					dec_pos_v  = TaAddr;
					// Anchor-branch outcome rides ONLY the packet's branch
					// field: the decoder re-injects it into its own map
					// (model line 361-363), the encoder map stays empty --
					// re-transmitting it in a later F1 map would double it.
					map_v      = '0;
					branches_v = '0;
					TaValid    <= 1'b0;
					// An F3.1/F3.0 trap anchor is absolute -- it IS the
					// post-overflow re-anchor if one was pending.
					OvfPend    <= 1'b0;
					Started    <= 1'b1;
				end

				// Pending post-overflow re-anchor: F3.0 at the first
				// CONCLUSIVE CF beat. itype==OTHER beats (injected/sync-only)
				// are not conclusive: the instruction at their iaddr may be
				// a branch whose outcome nobody knows yet -- exactly the lie
				// this deferral removes. Traps resolve via the TaValid arm
				// (F3.1 is absolute), trace-off ends the episode.
				if (OvfPend && is_cf && !sync_ovf && !is_off
				    && !is_icnt_drain && !cf_trap && !TaValid
				    && (etip_cf.rcode == NEXUS_RCODE_NONE)
				    && (etip_cf.itype != OTHER)) begin
					nq[n] = desc_f30(etip_cf.iaddr, sync_br, 3'(etip_cf.priv));
					n++;
					addr_sent  = 1'b1;
					last_v     = etip_cf.iaddr;
					dec_pos_v  = etip_cf.iaddr;
					map_v      = '0;
					branches_v = '0;
					OvfPend    <= 1'b0;
					RsyncPend  <= 1'b0;
					Started    <= 1'b1;
					if (cf_branch) begin
						// anchor ON a branch: outcome rides the F3.0 branch
						// field (decoder-side map injection), beat consumed.
						rsync_ate_branch = 1'b1;
					end
				end

				// Pending mid-trace re-anchor: emit at the first suitable beat.
				if (RsyncPend && Started && is_cf && !has_sync && !is_off
				    && !is_icnt_drain && !cf_trap && !TaValid
				    && !(bp_en && BpCountMode)
				    && (branches_v == 0) && (etip_cf.iaddr != dec_pos_v)) begin
					nq[n] = desc_f30(etip_cf.iaddr, sync_br, 3'(etip_cf.priv));
					n++;
					addr_sent = 1'b1;
					last_v    = etip_cf.iaddr;
					dec_pos_v = etip_cf.iaddr;
					RsyncPend <= 1'b0;
					if (cf_branch) begin
						// anchor ON a branch: its outcome rides the F3.0
						// branch field (decoder pushes it into its map);
						// consume the beat silently, mirror stays empty.
						rsync_ate_branch = 1'b1;
					end
				end

				if (ta_hit_branch || is_icnt_drain) begin
					// beat fully handled (branch consumed into the F3.1
					// branch field / composer ICNT drain has no E-Trace
					// equivalent)
				end
				else if (is_off) begin
					if (Started) begin
						// Flush only when it moves the decoder: pending map
						// bits, or retirement since the last address packet
						// AND a target != the decoder's current position
						// (an equal-target F2 walks a degenerate loop).
						// After an own-address pending resolution the
						// decoder already sits at the last retired PC.
						// While a post-overflow re-anchor is pending there
						// is no decoder position at all (start_of_trace) --
						// the tail folds into the announced loss.
						if (!pu_resolved_own && !OvfPend && ((branches_v != 0)
						    || (flush_needed && (flush_tgt != dec_pos_v)))) begin
							nq[n] = desc_flush_v(flush_tgt, last_v, map_v, branches_v);
							n++;
							addr_sent = 1'b1;
							last_v    = flush_tgt;
							dec_pos_v = flush_tgt;
						end
						nq[n] = desc_f33(1'b0, QUAL_ENDED_REP);
						n++;
					end
					Started    <= 1'b0;
					RsyncPend  <= 1'b0;
					OvfPend    <= 1'b0;
					JtcValid   <= '0;
					BpEpoch    <= BpEpoch + 1'b1; // decoder restarts cold
					BpCountMode <= 1'b0;          // (count rode the off-flush)
					BpCount    <= '0;
					PredOk     <= '0;
					map_v      = '0;
					branches_v = '0;
				end
				else if (has_sync && sync_ovf) begin
					// FIFO overrun: announce the loss NOW, defer the F3.0
					// re-anchor (OvfPend above). The injected beat's iaddr
					// (resume address) still rebases NextAddr below; its
					// itype/priv are NOT trusted for the anchor.
					RsyncPend   <= 1'b0; // hard re-anchor supersedes
					OvfPend     <= 1'b1;
					JtcValid    <= '0; // decoder restarts cold
					BpEpoch     <= BpEpoch + 1'b1;
					BpCountMode <= 1'b0;
					BpCount     <= '0;
					PredOk <= '0;
					nq[n] = desc_f33(1'b1, QUAL_TRACE_LOST);
					n++;
					map_v      = '0;
					branches_v = '0;
				end
				else if (has_sync && !Started) begin
					RsyncPend <= 1'b0; // hard re-anchor supersedes
					PredOk <= '0;
					nq[n] = desc_f33(1'b1, QUAL_NO_CHANGE);
					n++;
					nq[n] = desc_f30(etip_cf.iaddr, sync_br, 3'(etip_cf.priv));
					n++;
					addr_sent  = 1'b1;
					// Anchor-branch bit rides ONLY the F3.0 branch field
					// (decoder-side map injection) -- see the F3.1 comment.
					map_v      = '0;
					branches_v = '0;
					last_v     = etip_cf.iaddr;
					dec_pos_v  = etip_cf.iaddr;
					if (cf_updiscon) begin
						// sync anchored ON an uninferable jump: report its
						// target as a follow-up address packet
						nq[n] = desc_null();
						nq[n].kind   = TE_K_F2;
						nq[n].addr31 = diff31(nia, etip_cf.iaddr);
						n++;
						last_v    = nia;
						dec_pos_v = nia;
					end
					Started <= 1'b1;
				end
				else if (cf_branch && !rsync_ate_branch) begin
					// (a mid-trace sync riding a branch beat is handled via
					// RsyncPend above; the bit then travels in the F3.0
					// branch field instead of the map)
					if (bp_en && BpCountMode) begin
						// COUNT mode: correct predictions only count; a
						// mispredict closes the run as F0.0 without address
						// (the failed branch is the implicit position).
						if (bp_correct) begin
							if (BpCount == 32'hFFFF_FFFF) begin
								// spec corner: counter saturation reports
								// WITH address (branch_fmt=10) -- rare, kept
								// for completeness (untested by the leg)
								nq[n] = desc_null();
								nq[n].kind   = TE_K_F00A;
								nq[n].bp_cnt = BpCount;
								nq[n].addr31 = diff31(etip_cf.iaddr, last_v);
								n++;
								addr_sent   = 1'b1;
								last_v      = etip_cf.iaddr;
								dec_pos_v   = etip_cf.iaddr;
								BpCountMode <= 1'b0;
								BpCount     <= '0;
							end
							else
								BpCount <= BpCount + 1'b1;
						end
						else begin
							nq[n] = desc_null();
							nq[n].kind   = TE_K_F00N;
							nq[n].bp_cnt = BpCount;
							n++;
							// decoder walks count+31 predicted branches plus
							// the failed one -- it ends BEHIND the failed
							// branch; the position for gates is the branch
							dec_pos_v   = etip_cf.iaddr;
							BpCountMode <= 1'b0;
							BpCount     <= '0;
						end
					end
					else if (branches_v == 6'd30) begin
						if (bp_en && (&PredOk[29:0]) && bp_correct) begin
							// full map, ALL 31 predicted correctly: switch
							// to COUNT mode instead of emitting F1N
							BpCountMode <= 1'b1;
							BpCount     <= '0;
							map_v       = '0;
							branches_v  = '0;
							// decoder consumes these branches predictor-
							// resolved during the eventual F0.0 walk; its
							// position advances only then
						end
						else begin
							nq[n] = desc_null();
							nq[n].kind = TE_K_F1N;
							nq[n].map  = map_v | (31'(map_bit) << 30);
							n++;
							map_v      = '0;
							branches_v = '0;
							// decoder's F1N walk stops AT this branch (one
							// bit pending) -- that is its position from now
							dec_pos_v  = etip_cf.iaddr;
						end
						PredOk <= '0;
					end
					else begin
						map_v[branches_v[4:0]] = map_bit;
						PredOk[branches_v[4:0]] <= bp_correct;
						branches_v = branches_v + 1'b1;
					end
				end
				else if (cf_updiscon) begin
					// Deferred by one beat (see PuValid above); the wire
					// packet is built at resolution with the then-known
					// target-retirement evidence.
					PuValid <= 1'b1;
					PuOwn   <= etip_cf.iaddr;
					PuTgt   <= nia;
					PuMap   <= map_v;
					PuBr    <= branches_v;
					PuBpVal <= bp_en && BpCountMode;
					PuBpCnt <= BpCount;
					BpCountMode <= 1'b0;
					BpCount     <= '0;
					map_v      = '0;
					branches_v = '0;
				end
				else if (cf_trap) begin
					if (pu_resolved_own || OvfPend) begin
						// The own-address updiscon report just positioned
						// the decoder at the last retired instruction --
						// no flush, no thaddr=0: plain deferred F3.1
						// (thaddr=1, handler) like the model's
						// prev_exception/!prev_reported path.
						// Same for a pending post-overflow re-anchor: the
						// decoder sits in start_of_trace with no position;
						// any flush/thaddr=0 address here would be a stale
						// pre-loss delta. The deferred F3.1 is absolute and
						// doubles as the re-anchor (TaValid arm above).
						TaStart <= 1'b0;
					end
					else if (Started && !flush_needed && (branches_v == 0)) begin
						// Trap hit the still-UNRETIRED target of the last
						// reported updiscon: report the trap as F3.1
						// thaddr=0 with the EPC (= last reported address);
						// the decoder takes note WITHOUT moving. The
						// handler anchor follows as a deferred F3.0 START
						// (model prev_reported path: TRAP thaddr=0 then
						// SYNC START at the handler).
						nq[n] = desc_f31(dec_pos_v, 1'b1,
						                 (etip_cf.itype == INTERRUPT), 1'b1,
						                 4'(etip_cf.trap_ecause),
						                 32'(etip_cf.trap_tval),
						                 3'(etip_cf.priv));
						n++;
						TaStart <= 1'b1;
					end
					else begin
						// Movement-gated flush as in the trace-off arm.
						if (Started && ((branches_v != 0)
						    || (flush_needed && (flush_tgt != dec_pos_v)))) begin
							nq[n] = desc_flush_v(flush_tgt, last_v, map_v, branches_v);
							n++;
							addr_sent = 1'b1;
							last_v    = flush_tgt;
							dec_pos_v = flush_tgt;
						end
						TaStart <= 1'b0;
					end
					map_v      = '0;
					branches_v = '0;
					PredOk     <= '0;
					BpCountMode <= 1'b0; // count rode the flush packet
					BpCount    <= '0;
					TaValid    <= 1'b1;
					TaAddr     <= nia;
					TaIntr     <= (etip_cf.itype == INTERRUPT);
					TaEc       <= 4'(etip_cf.trap_ecause);
					TaTval     <= 32'(etip_cf.trap_tval);
					TaPriv     <= 3'(etip_cf.priv);
				end
				// else: OTHER-itype CF beats, SUB_MSG_OTHER/NONE: consume silently

				end // !(is_df || is_daq)

				// ---- retirement tracking (see NextAddr/LastRet above) ----
				RetiredSince <= addr_sent
					? 1'b0 : (RetiredSince || (is_cf && (etip_cf.icnt != 0)));
				if (is_cf) begin
					if (etip_cf.icnt != 0)
						LastRet <= seg_last;
					// ANY control-flow-changing itype carries its target on
					// the next_iaddr sideband -- including INFERABLE calls/
					// jumps, which emit no packet but still break address
					// linearity (found via the interrupts leg: a jal between
					// mret and the next trap shifted the flush target).
					// A NOT_TAKEN branch (HCCF=0) advances linearly: its
					// icnt includes the branch, so the sum lands at iaddr+4.
					if (has_sync && (sync_ovf || !Started))
						// Exclusive anchor: the anchor instruction's own
						// halfwords ride the NEXT segment's icnt. Non-CF
						// anchor: count linearly from its address. CF
						// anchor (jump): the segment is anchor + block at
						// the TARGET -- only the sum matters, so start at
						// target minus the anchor width (found by the
						// +ANCHORJUMP coverage leg, icnt guard fired).
						NextAddr <= cf_needs_nia
							? (nia - (tip_iaddr_t'(2) << etip_cf.ilastsize))
							: etip_cf.iaddr;
					else if (cf_needs_nia)
						NextAddr <= nia;
					else
						NextAddr <= NextAddr + (tip_iaddr_t'(etip_cf.icnt) << 1);
				end

				Map      <= map_v;
				Branches <= branches_v;
				LastAddr <= last_v;
				DecPos   <= dec_pos_v;
				Q[0]  <= nq[0];
				Q[1]  <= nq[1];
				Q[2]  <= nq[2];
				QCnt  <= 2'(n);
			end
		end
	end

	// ------------------------------------------------------------------
	// Packet building (LSB-first field packing, reference raw layout)
	// ------------------------------------------------------------------

	always_comb begin
		automatic te_desc_t d = Q[0];
		automatic logic [CT_ETRACE_PKT_MAX_BITS-1:0] p = '0;
		automatic logic [7:0] n = '0;
		automatic logic [6:0] mb;
		case (d.kind)
			TE_K_F30: begin
				p[1:0]  = 2'd3;  p[3:2] = 2'd0;
				p[4]    = d.branch;
				p[7:5]  = d.priv;
				p[38:8] = d.addr31;
				n = 7'd39;
			end
			TE_K_F31: begin
				p[1:0]   = 2'd3;  p[3:2] = 2'd1;
				p[4]     = d.branch;
				p[7:5]   = d.priv;
				p[11:8]  = d.ecause;  // real cause via eTIP sideband
				p[12]    = d.intr;
				p[13]    = !d.th0;    // thaddr (0 = EPC report without anchor)
				p[44:14] = d.addr31;
				if (!d.intr)
					p[76:45] = d.tval; // trap value (exception only)
				n = d.intr ? 7'd45 : 7'd77;
			end
			TE_K_F33: begin
				p[1:0]   = 2'd3;  p[3:2] = 2'd3;
				p[4]     = d.ienable;
				p[5]     = 1'b0;      // encoder_mode
				p[7:6]   = d.qual;
				p[12:8]  = d.ioptions; // ioptions [IR,IE,FA,JTC,BP]
				// denable reflects the run-time DF enable; dloss stays 0
				// (MVP disclosure: DF loss on overflow is not signalled --
				// the N-Trace path carries DF without a recovery anchor too)
				p[13]    = CT_EN_DATA_TRACE ? cs_proc.trTeDataTracing : 1'b0;
				p[14]    = 1'b0;      // dloss
				p[18:15] = 4'd0;      // doptions
				n = 7'd19;
			end
			TE_K_F1N: begin
				p[1:0]  = 2'd1;
				p[6:2]  = 5'd0;       // branches=0 encodes the full 31-bit map
				p[37:7] = d.map;
				n = 7'd38;
			end
			TE_K_F1A: begin
				mb = f1a_mapbits(d.brcnt);
				p[1:0] = 2'd1;
				p[6:2] = d.brcnt;
				for (int i = 0; i < 31; i++)
					if (i < mb) p[7 + i] = d.map[i];
				for (int i = 0; i < 31; i++)
					p[7 + 32'(mb) + i] = d.addr31[i];
				// Differential trailer: notify canonical (== address MSB),
				// updiscon = notify XOR flag, irreport = updiscon (canonical).
				p[7 + 32'(mb) + 31]     = d.addr31[30];               // notify
				p[7 + 32'(mb) + 31 + 1] = d.addr31[30] ^ d.updiscon;  // updiscon
				p[7 + 32'(mb) + 31 + 2] = d.addr31[30] ^ d.updiscon;  // irreport
				n = 7'(7 + 32'(mb) + 31 + 3);
			end
			TE_K_F00N: begin
				// format(2)=0 | subformat(1)=0 | branch_count(32) |
				// branch_fmt(2)=00 -- zero fmt lets the count MSBs compress
				p[1:0]  = 2'd0;
				p[2]    = 1'b0;
				p[34:3] = d.bp_cnt;
				p[36:35] = 2'b00;
				n = 7'd37;
			end
			TE_K_F00A: begin
				// format | subformat=0 | branch_count(32) | branch_fmt=10 |
				// address(31) | notify/updiscon/irreport (differential)
				p[1:0]   = 2'd0;
				p[2]     = 1'b0;
				p[34:3]  = d.bp_cnt;
				p[36:35] = 2'b10;
				p[67:37] = d.addr31;
				p[68]    = d.addr31[30];               // notify (canonical)
				p[69]    = d.addr31[30] ^ d.updiscon;  // updiscon
				p[70]    = d.addr31[30] ^ d.updiscon;  // irreport (canonical)
				n = 7'd71;
			end
			TE_K_F01: begin
				// format(2)=0 | subformat(1)=1 | index(6) | branches(5) |
				// branch_map(mb, only when brcnt>0) | irreport(1, canonical)
				p[1:0] = 2'd0;
				p[2]   = 1'b1;
				p[8:3] = d.jtc_idx;
				p[13:9] = d.brcnt;
				if (d.brcnt == 0) begin
					p[14] = 1'b0;         // irreport == branches[MSB] (=0)
					n = 7'd15;
				end
				else begin
					mb = f1a_mapbits(d.brcnt);
					for (int i = 0; i < 31; i++)
						if (i < mb) p[14 + i] = d.map[i];
					p[14 + 32'(mb)] = d.map[mb - 1]; // irreport == map[MSB]
					n = 7'(14 + 32'(mb) + 1);
				end
			end
			TE_K_F2: begin
				p[1:0]   = 2'd2;
				p[32:2]  = d.addr31;
				p[33]    = d.addr31[30];               // notify (canonical)
				p[34]    = d.addr31[30] ^ d.updiscon;  // updiscon
				p[35]    = d.addr31[30] ^ d.updiscon;  // irreport (canonical)
				n = 7'd36;
			end
			// te_data unified load/store, address + data, diff=00 (full):
			// format(2) size(2) diff(2) data_len(sz bits) data(8*(dlen+1))
			// address(32). LSB-first on the wire like every te packet.
			TE_K_TD: if (CT_EN_DATA_TRACE) begin
				automatic logic [31:0] a32 = 32'(d.df_addr);
				p[1:0] = {d.df_store, d.df_unal};
				p[3:2] = d.df_sz;
				p[5:4] = 2'b00;
				n = 8'd6;
				for (int b = 0; b < 3; b++)
					if (b < 32'(d.df_sz)) begin
						p[n] = d.df_dlen[b];
						n++;
					end
				for (int b = 0; b < 64; b++)
					if (b < 8 * (32'(d.df_dlen) + 1)) begin
						p[n] = 1'(64'(d.df_data) >> b);
						n++;
					end
				for (int b = 0; b < 32; b++) begin
					p[n] = a32[b];
					n++;
				end
			end
			// vendor DAQ packet (raw-framing msg_type 1): idtag(8) then the
			// DQM data elements (element 0 first); the packetizer's whole-
			// packet sign compression strips the unused MSBs.
			TE_K_DAQ: if (CT_EN_DAQ || CT_EN_ACT) begin
				p[7:0] = d.daq_idtag;
				for (int b = 0; b < MAX_DAQ_DATA_ELEMENTS*ETIP_DAQ_ELEM_W; b++)
					p[8 + b] = d.daq_data[b];
				n = 8'(8 + MAX_DAQ_DATA_ELEMENTS*ETIP_DAQ_ELEM_W);
			end
			default: ;
		endcase
		pkt_payload = p;
		pkt_nbits   = n;
		pkt_mtype   = (d.kind == TE_K_TD)  ? 2'd3 :
		              (d.kind == TE_K_DAQ) ? 2'd1 : 2'd2;
	end

	assign pkt_valid = !proc_rst && (QCnt != 0);

	// trTeControl.Empty chain: output queue empty and no emission substance
	// held back.
	assign gen_idle = (QCnt == 0)
		&& (Branches == '0)
		&& !TaValid
		&& !PuValid
		&& !RsyncPend
		&& !BpCountMode;

	// pragma translate_off
	always_ff @(posedge proc_clk) begin
		if (pkt_valid && pkt_ready && $test$plusargs("TE_PKT_DUMP"))
			$display("[te_pkt] kind=%0d mtype=%0d nbits=%0d sz=%0d dlen=%0d data=%016x addr=%08x p0=%02x",
				Q[0].kind, pkt_mtype, pkt_nbits, Q[0].df_sz, Q[0].df_dlen,
				64'(Q[0].df_data), 32'(Q[0].df_addr), pkt_payload[7:0]);
	end
	// pragma translate_on

	// Keep the compatibility tie-off explicit so lint does not flag the read.
	if (1) begin : blkCompat
		uwire logic unused_cs_proc_active = cs_proc.trTeActive;
	end

endmodule // ct_L2_te_inst_gen

`default_nettype wire
