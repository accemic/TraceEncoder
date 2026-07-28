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
	input uwire logic           clk,                // trace input clock
	input uwire logic           rst,                // reset
	input uwire tip_time_t      ts_value,           // selected timestamp from timestamp unit
	ct_act_cap_if.slave         act_cap_st,
	tip_if.slave                tip,
	input uwire logic           atb_afvalid,
	ct_sync_if.slave            sync,
	ct_hit_if.slave_region      cf_qualifier,
	ct_hit_if.slave             df_qualifier,
	ct_perfcnt_if.slave_etip    perfcnt,
	source_if.impl              etip_q,
	source_if.impl              next_iaddr_q,
	ct_cs_tipclk_if.slave       cs_tip,              // TIP FIFO status/clear (tip_clk side of CSR bundle)
	output logic                synq_req_trace_msg_count,
	output delay_t              internal_delay
);

	// Registered state (initial values match reset values; 'x where no reset)
	etip_msg_struct_t[2:0]      EtipMsg              = 'x;
	logic [31:0]                ICntCum              = 0;
	logic [1:0]                 MsgId                = 0;
	logic                       PendingCfNextIaddr   = 0;
	tip_iaddr_t                 NextIaddr            = 'x;
	logic                       NextIaddrWr          = 0;
	logic [31:0]                TraceMsgCount        = 100;
	logic                       SyncReqTraceMsgCount = 0;
	tip_iaddr_t                 PrevIAddr            = '0;
	// Size of the last retired instruction. Used to compute the address of
	// the next instruction (PrevIAddr + (1 << PrevIlastsize)) for the
	// FIFO_OVERRUN injected sync — see ovf_inject_msg1 below. Tracking it
	// here rather than re-reading tip.ilastsize keeps the value defined
	// during arbitrary periods of iretire=0 (when the spec leaves
	// tip.ilastsize undefined).
	tip_ilastsize_t             PrevIlastsize        = '0;
	tip_iaddr_t                 LastIAddrBeforeException = '0;
	tip_daddr_t                 PrevDAddr            = '0;
	tip_data_t                  PrevData             = '0;
	tip_dtype_dsize_t           PrevDtypeDsize       = '0;
	// split-load state: load address captured at dretire; data arrives separately at lresp
	tip_daddr_t                 PendingSplitLoadDaddr = '0;
	tip_dsize_t                 PendingSplitLoadDsize = '0;

	// Combinational next-state
	etip_msg_struct_t[2:0]      etip_msg_next;
	logic [31:0]                icnt_cum_next;
	logic [2:0]                 msg_id_next;
	logic                       pending_cf_next_iaddr_next;
	logic                       next_iaddr_wr_next;
	tip_iaddr_t                 next_iaddr_val;
	logic [31:0]                trace_msg_count_next;
	logic                       sync_req_trace_msg_count_next;
	logic                       do_flush_ack_next;
	logic                       etip_ovf_drop_now;
	logic                       sideband_ovf_drop;
	tip_data_t                  mask;
	function automatic tip_xaddr_data_t pack_daq_context_direct(
		input tip_dtype_dsize_t dtype_dsize,
		input logic [23:0] direct_data
	);
		pack_daq_context_direct =
			tip_xaddr_data_t'({{(TIP_XADDR_DATA_WIDTH-24-$bits(tip_dtype_dsize_t)){1'b0}}, direct_data, dtype_dsize});
	endfunction

	// process ATB flush request (atb_afvalid)
	logic                       DoFlushAck = 0;
	uwire                       do_flush;
	uwire                       do_flush_atb;
	logic                       DoFlushEnableFall      = 1'b0;
	logic                       DoCorrDisable          = 1'b0;
	logic                       PrevTrTeEnable         = 1'b0;
	logic                       PrevInstTraceActive    = 1'b0;
	uwire                       etip_ovf_dropping;

	// Instruction tracing is effectively active only while the encoder is
	// enabled AND instruction tracing is selected. Setting trTeEnable=0
	// therefore implicitly disables instruction tracing (and data tracing).
	uwire inst_trace_active = cs_tip.trTeEnable && cs_tip.trTeInstTracing;

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
		end else begin
			PrevTrTeEnable      <= cs_tip.trTeEnable;
			PrevInstTraceActive <= inst_trace_active;
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
		end
	end

	// A trace-off correlation message must itself be pushed out, so the
	// instruction-disable event also requests a flush.
	assign do_flush = do_flush_atb || DoFlushEnableFall || DoCorrDisable;

	// ----------------------------------------------------------------
	// Combinational next-state logic
	// ----------------------------------------------------------------
	always_comb begin
		// Defaults: clear message slots, retain sub fields
		for (int i = 0; i < ETIP_PAR_MSG; i++) begin
			etip_msg_next[i]          = EtipMsg[i];
			etip_msg_next[i].sub_type = SUB_MSG_NONE;
			etip_msg_next[i].do_flush = 0;
			etip_msg_next[i].ts       = ts_value;
		end

		next_iaddr_wr_next              = 0;
		next_iaddr_val                  = NextIaddr;
		icnt_cum_next                   = ICntCum;
		msg_id_next                     = 0;
		pending_cf_next_iaddr_next      = PendingCfNextIaddr;
		etip_ovf_drop_now               = 0;
		do_flush_ack_next               = DoFlushAck;
		trace_msg_count_next            = TraceMsgCount;
		sync_req_trace_msg_count_next   = 0;
		mask                            = '0;

		if (!rst) begin

			// Trap-event marker (INTERRUPT or EXCEPTION_TRAP) can arrive on
			// a tip beat with iretire=0 -- no instruction commits when the
			// trap is taken, but the encoder must still emit a CF eTIP so
			// the decoder gets an IBH (BTYPE=INTERRUPT/EXCEPTION) with the
			// trap-target UADDR. Without this, the next CF event (typically
			// the trap-handler's mret) carries the full handler body in its
			// ICNT and the decoder loses synchronisation.
			//
			// This is explicitly sanctioned by the RISC-V N-Trace ingress
			// port spec
			// (riscv-trace-spec/ingressPort.adoc @ f185ac28d71f48cc):
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
			automatic logic is_trap_event =
				(tip.itype == EXCEPTION_TRAP) || (tip.itype == INTERRUPT);
			// Instruction tracing must be effectively active (Enable &&
			// InstTracing) to generate any instruction-trace message or
			// accumulate ICNT. While paused (InstTracing=0 with Enable still
			// high, or Enable=0) the encoder emits nothing and counts nothing;
			// the trace-off correlation message (DoCorrDisable path below)
			// has already carried the residual, and on resume a TRACE_ENABLE
			// sync re-anchors the decoder. Traps during a pause are not traced
			// either.
			automatic logic process_now =
				inst_trace_active
				&& ( (tip.iretire && cf_qualifier.hit_valid && cf_qualifier.hit)
				     || is_trap_event );
			// See the comment block below at the icnt accumulation.
			automatic logic count_halfwords =
				inst_trace_active
				&& (tip.iretire || (tip.itype == EXCEPTION_TRAP));

			// ACT-CAP CF_SYNC: a CSR-driven request for an instruction
			// synchronization message (Nexus only). It rides on the
			// retiring `csrw 0x0B10` (itype=OTHER) and is turned into a
			// sync exactly like a periodic sync landing on a non-CF
			// instruction (NEXUS_SYNC_REQ_CSR). When a real sync reason is
			// already present on this beat, it takes precedence (a sync is
			// emitted either way). The DAQ block below suppresses the DAQ
			// message for this command.
			automatic logic act_cf_sync =
				act_cap_st.valid
				&& (  (act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS)
				    ||(act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS))
				&& (act_cap_st.cmd.Cmd.value == ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC);
			automatic nexus_sync_reason_e eff_sync_reason =
				(sync.reason != NEXUS_SYNC_NONE) ? sync.reason
				: (act_cf_sync ? NEXUS_SYNC_REQ_CSR : NEXUS_SYNC_NONE);

			if (process_now) begin
				if (pending_cf_next_iaddr_next) begin
					next_iaddr_val      = tip.iaddr;
					next_iaddr_wr_next  = 1;
					trace_msg_count_next = TraceMsgCount + 1;
				end
				pending_cf_next_iaddr_next = 0;

				// Count halfwords for any TIP block that actually represents
				// at least one instruction's worth of binary:
				//   - iretire >  0                            : iretire halfwords retired
				//   - iretire == 0 && itype == EXCEPTION_TRAP : the faulting instruction
				//     (didn't retire because it faulted, but its halfwords are what the
				//     decoder must walk to land on the faulting PC = mepc).
				// For iretire == 0 && itype == INTERRUPT the trap is asynchronous and
				// taken at an instruction boundary that prior trace history already
				// pins down; per the ingress-port spec tip.iaddr / tip.ilastsize are
				// undefined and contribute nothing to ICNT.
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
					if ((icnt_cum_next + (1 << tip.ilastsize)) >= 2**NEXUS_MSG_I_CNT_WIDTH) begin
						etip_msg_next[msg_id_next].sub_type           = SUB_MSG_CF;
						etip_msg_next[msg_id_next].sub.cf.sync_reason = NEXUS_SYNC_NONE;
						etip_msg_next[msg_id_next].sub.cf.btype       = NEXUS_BTYPE_IBRANCH;
						etip_msg_next[msg_id_next].sub.cf.itype       = OTHER;
						etip_msg_next[msg_id_next].sub.cf.iaddr       = tip.iaddr;
						etip_msg_next[msg_id_next].sub.cf.icnt        = icnt_cum_next;
						etip_msg_next[msg_id_next].sub.cf.rcode       = NEXUS_RCODE_ICNT_OVERFLOW;
						etip_msg_next[msg_id_next].sub.cf.rdata0      = '0;
						etip_msg_next[msg_id_next].sub.cf.rdata1      = '0;
						msg_id_next = msg_id_next + 1;
						icnt_cum_next = 0;
					end
					icnt_cum_next = icnt_cum_next + (1 << tip.ilastsize);
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
					etip_msg_next[msg_id_next].sub.cf.iaddr       = tip.iaddr;
					etip_msg_next[msg_id_next].sub.cf.rcode       = NEXUS_RCODE_NONE;
					etip_msg_next[msg_id_next].sub.cf.rdata0      = '0;
					etip_msg_next[msg_id_next].sub.cf.rdata1      = '0;
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
							etip_msg_next[msg_id_next].sub.cf.icnt = icnt_cum_next - (1 << tip.ilastsize);
							icnt_cum_next = (1 << tip.ilastsize);
						end
					end else begin
						etip_msg_next[msg_id_next].sub.cf.icnt = icnt_cum_next;
						icnt_cum_next = 0;
					end
					msg_id_next   = msg_id_next + 1;
					pending_cf_next_iaddr_next = HasChangedControlFlow(tip.itype);
				end
			end

			if (SPLIT_DATA_ACCESS) begin
				if (tip.dretire && (tip.dtype == STORE) && df_qualifier.hit_valid && df_qualifier.hit) begin
					etip_msg_next[msg_id_next].sub_type      = SUB_MSG_DF;
					mask = ({TIP_DATA_WIDTH{1'b1}} >> (TIP_DATA_WIDTH - (8 << tip.dsize)));
					etip_msg_next[msg_id_next].sub.df.data       = tip_data_t'(tip.sdata) & mask;
					etip_msg_next[msg_id_next].sub.df.addr_idtag = tip.daddr;
					etip_msg_next[msg_id_next].sub.df.dtype      = tip.dtype;
					etip_msg_next[msg_id_next].sub.df.dsz        = GetDsz(tip.dsize);
					etip_msg_next[msg_id_next].sub.df.elsz       = GetElsz(tip.dsize);
					msg_id_next = msg_id_next + 1;
				end
				if (tip.lresp[1] && df_qualifier.hit_valid && df_qualifier.hit) begin
					etip_msg_next[msg_id_next].sub_type      = SUB_MSG_DF;
					mask = ({TIP_DATA_WIDTH{1'b1}} >> (TIP_DATA_WIDTH - (8 << PendingSplitLoadDsize)));
					etip_msg_next[msg_id_next].sub.df.data       = tip_data_t'(tip.ldata) & mask;
					etip_msg_next[msg_id_next].sub.df.addr_idtag = PendingSplitLoadDaddr;
					etip_msg_next[msg_id_next].sub.df.dtype      = LOAD;
					etip_msg_next[msg_id_next].sub.df.dsz        = GetDsz(PendingSplitLoadDsize);
					etip_msg_next[msg_id_next].sub.df.elsz       = GetElsz(PendingSplitLoadDsize);
					msg_id_next = msg_id_next + 1;
				end
			end else begin
				if (tip.dretire && df_qualifier.hit_valid && df_qualifier.hit) begin
					etip_msg_next[msg_id_next].sub_type      = SUB_MSG_DF;
					mask = ({TIP_DATA_WIDTH{1'b1}} >> (TIP_DATA_WIDTH - (8 << tip.dsize)));
					etip_msg_next[msg_id_next].sub.df.data       = tip.data & mask;
					etip_msg_next[msg_id_next].sub.df.addr_idtag = tip.daddr;
					etip_msg_next[msg_id_next].sub.df.dtype      = tip.dtype;
					etip_msg_next[msg_id_next].sub.df.dsz        = GetDsz(tip.dsize);
					etip_msg_next[msg_id_next].sub.df.elsz       = GetElsz(tip.dsize);
					msg_id_next = msg_id_next + 1;
				end
			end

			if (   (act_cap_st.valid)
				&& (act_cap_st.cmd.Cmd.value != ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC)
				&& (  (act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS)
					||(act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS))) begin
				etip_msg_next[msg_id_next].sub_type         = SUB_MSG_DAQ;
				etip_msg_next[msg_id_next].sub.daq.addr_idtag = act_cap_st.cmd.Cmd.value;
				etip_msg_next[msg_id_next].sub.daq.data     = '0;
				case (act_cap_st.cmd.Cmd.value)
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = tip_xaddr_data_t'(tip.iaddr);
						etip_msg_next[msg_id_next].sub.daq.data[1] = tip_xaddr_data_t'(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR_LAST: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = tip_xaddr_data_t'(tip.iaddr);
						etip_msg_next[msg_id_next].sub.daq.data[1] = tip_xaddr_data_t'(LastIAddrBeforeException);
						etip_msg_next[msg_id_next].sub.daq.data[2] = tip_xaddr_data_t'(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = tip_xaddr_data_t'(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = PrevData;
						etip_msg_next[msg_id_next].sub.daq.data[1] = PrevDtypeDsize;
						etip_msg_next[msg_id_next].sub.daq.data[2] = tip_xaddr_data_t'(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = PrevDAddr;
						etip_msg_next[msg_id_next].sub.daq.data[1] = PrevDtypeDsize;
						etip_msg_next[msg_id_next].sub.daq.data[2] = tip_xaddr_data_t'(act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR: begin
						etip_msg_next[msg_id_next].sub.daq.data[0] = PrevData;
						etip_msg_next[msg_id_next].sub.daq.data[1] = PrevDAddr;
						etip_msg_next[msg_id_next].sub.daq.data[2] = pack_daq_context_direct(PrevDtypeDsize, act_cap_st.cmd.DirectData.value);
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_RD_RANGES)
							etip_msg_next[msg_id_next].sub.daq.data[0] = perfcnt.data_rd_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0]];
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_WR: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_WR_RANGES)
							etip_msg_next[msg_id_next].sub.daq.data[0] = perfcnt.data_wr_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0]];
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_IFETCH_TH: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0] <= NUM_PERFCNT_IFETCH_TH_RANGES)
							etip_msg_next[msg_id_next].sub.daq.data[0] = perfcnt.ifetch_th_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0]];
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD_TH: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0] <= NUM_PERFCNT_DATA_RD_TH_RANGES)
							etip_msg_next[msg_id_next].sub.daq.data[0] = perfcnt.data_rd_th_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0]];
					end
					default: begin
					end
				endcase
				msg_id_next = msg_id_next + 1;
			end

			// process flush request
			do_flush_ack_next = (!do_flush && DoFlushAck) ? 0 : DoFlushAck;
			if (do_flush && !do_flush_ack_next) begin
				if (DoCorrDisable) begin
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
					etip_msg_next[msg_id_next].sub.cf.rdata0      = '0;
					etip_msg_next[msg_id_next].sub.cf.rdata1      = '0;
					etip_msg_next[msg_id_next].do_flush           = 1;
					msg_id_next       = msg_id_next + 1;
					icnt_cum_next     = 0;
					do_flush_ack_next = 1;
				end else begin
					msg_id_next = (msg_id_next == 0) ? 2'd1 : msg_id_next;
					etip_msg_next[msg_id_next-1].do_flush = 1;
					do_flush_ack_next = 1;
				end
			end

			etip_ovf_drop_now = (msg_id_next != 0) && etip_cvs_d.full;
			if (etip_ovf_drop_now || etip_ovf_dropping) begin
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
				pending_cf_next_iaddr_next = 0;
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
				next_iaddr_wr_next         = 0;
				pending_cf_next_iaddr_next = 0;
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
		end
	end

	// ----------------------------------------------------------------
	// Register update (non-blocking only)
	// ----------------------------------------------------------------
	always_ff @(posedge clk) begin
		EtipMsg              <= etip_msg_next;
		NextIaddrWr          <= next_iaddr_wr_next;
		NextIaddr            <= next_iaddr_val;
		SyncReqTraceMsgCount <= sync_req_trace_msg_count_next;

		if (rst) begin
			MsgId                       <= 0;
			PendingCfNextIaddr          <= 0;
			ICntCum                     <= 0;
			TraceMsgCount               <= 100;
			DoFlushAck                  <= 0;
			PrevIAddr                   <= '0;
			LastIAddrBeforeException    <= '0;
			PrevDAddr                   <= '0;
			PrevData                    <= '0;
			PrevDtypeDsize              <= '0;
			PendingSplitLoadDaddr       <= '0;
			PendingSplitLoadDsize       <= '0;
		end
		else begin
			MsgId              <= msg_id_next;
			ICntCum            <= icnt_cum_next;
			DoFlushAck         <= do_flush_ack_next;
			PendingCfNextIaddr <= pending_cf_next_iaddr_next;
			TraceMsgCount      <= trace_msg_count_next;

			if (tip.dretire) begin
				PrevDAddr      <= tip.daddr;
				PrevData       <= tip.data;
				PrevDtypeDsize <= {tip.dtype, tip.dsize};
			end
			if (tip.iretire) begin
				PrevIAddr     <= tip.iaddr;
				PrevIlastsize <= tip.ilastsize;
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

	assign synq_req_trace_msg_count = SyncReqTraceMsgCount;

	// ----------------------------------------------------------------
	// next_iaddr FIFO (tip_clk -> proc_clk)
	// ----------------------------------------------------------------

	sink_if   #(.T(tip_iaddr_t)) next_iaddr_d ( .clk, .rst );
	assign next_iaddr_d.d  = NextIaddr;
	assign next_iaddr_d.wr = NextIaddrWr;

	fifo2clk_fwft #(
		.T          (tip_iaddr_t),
		.MIN_DEPTH  (ETIP_CVS_FIFO_DEPTH + ETIP_CVS_FIFO_DEPTH),
		.FIFO_STYLE ("distributed"),
		.SAFE_RESETS(1))
	next_iaddr_fifo (
		.d(next_iaddr_d),
		.q(next_iaddr_q)
	);

	// ----------------------------------------------------------------
	// Compact up to three parallel EtipMsg and CDC (tip_clk -> proc_clk)
	// ----------------------------------------------------------------

	cvsink_if    #(.T(etip_msg_struct_t), .P(3))  etip_cvs_raw_d (.clk, .rst);
	cvsink_if    #(.T(etip_msg_struct_t), .P(3))  etip_cvs_d     (.clk, .rst);
	assign etip_cvs_raw_d.d     = EtipMsg[2:0];
	assign etip_cvs_raw_d.cnt   = MsgId;

	localparam nexus_vendor_ecode_t ETIP_OVF_ECODE =
		nexus_vendor_ecode_t'(
			NEXUS_ECODE_CF_MSG_LOST
			| NEXUS_ECODE_DF_MSG_LOST
			| NEXUS_ECODE_DAQ_MSG_LOST
		);

	etip_msg_struct_t ovf_inject_msg0;
	etip_msg_struct_t ovf_inject_msg1;
	always_comb begin
		ovf_inject_msg0                    = '0;
		ovf_inject_msg0.sub_type           = SUB_MSG_OTHER;
		ovf_inject_msg0.do_flush           = 1'b0;
		ovf_inject_msg0.ts                 = ts_value;
		ovf_inject_msg0.sub.other.tcode    = NEXUS_MSG_ERROR;
		ovf_inject_msg0.sub.other.etype    = NEXUS_ETYPE_QUEUE_OVERRUN;
		ovf_inject_msg0.sub.other.ecode    = ETIP_OVF_ECODE;

		ovf_inject_msg1                    = '0;
		ovf_inject_msg1.sub_type           = SUB_MSG_CF;
		ovf_inject_msg1.do_flush           = 1'b0;
		ovf_inject_msg1.ts                 = ts_value;
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
		ovf_inject_msg1.sub.cf.iaddr       = PrevIAddr + (tip_iaddr_t'(2) << PrevIlastsize);
		ovf_inject_msg1.sub.cf.icnt        = '0;
		ovf_inject_msg1.sub.cf.btype       = NEXUS_BTYPE_IBRANCH;
		ovf_inject_msg1.sub.cf.rcode       = NEXUS_RCODE_NONE;
		ovf_inject_msg1.sub.cf.rdata0      = '0;
		ovf_inject_msg1.sub.cf.rdata1      = '0;
	end

	uwire logic [31:0] etip_ovf_discard_cnt;

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
		.clear       (cs_tip.trTeTipFifoNumOverflowsClear),
		.dropping    (etip_ovf_dropping),
		.discard_cnt (etip_ovf_discard_cnt)
	);

	// Saturate the 32-bit discard counter into the 15-bit CSR field.
	assign cs_tip.trTeTipFifoNumOverflows = (|etip_ovf_discard_cnt[31:15])
		? 15'h7FFF
		: etip_ovf_discard_cnt[14:0];

	uwire [$clog2(ETIP_CVS_FIFO_DEPTH+1)-1:0] etip_cvs_fill;

	cvs_cdc_fifo2 #(
		.T  (etip_msg_struct_t),
		.P  (3),                                    // max # of T elements @ input
		.PO (1),                                    // max # of T elements @ output
		.CVS_MIN_DEPTH (ETIP_CVS_FIFO_DEPTH),
		.CDC_MIN_DEPTH (ETIP_CDC_FIFO_DEPTH),
		.CVS_FIFO_STYLE ("distributed"),
		.CDC_FIFO_STYLE ("distributed"),
		.SAFE_RESETS(1))                            // Ensure resets are safe: must be set to '1' explicitly
	etip_cvs_cdc_fifo(
		.d (etip_cvs_d),
		.q (etip_q),
		.cvs_fill (etip_cvs_fill)
	);

	// High-water watermark of etip_cvs_d fill level (tip_clk domain). Cleared by
	// SW via trTeTipFifoMaxFillClear (level, synchronised into tip_clk).
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

	assign sync.done        = 0;
	assign internal_delay   = 1;

endmodule // ct_L23_preproc_composer_etip

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
