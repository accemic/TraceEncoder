// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author   Albert Schulz <aschulz@accemic.com>
* @author   Alexander Lange <alange@accemic.com>
*
* @brief    CEDARtrace Layer 2: generic trace message generation from eTIP input
*			- Detailed knowledge of the Nexus protocol and the ATB protocol is required to understand how this module is working
*			- elements of generic trace message are orientated on Nexus message fields
*			- one eTIP cycle can initiate multiple generic trace messages, sent consecutively
*			- stall support in case of backpressure by later processing stages
*			- in case of an ATB flush (signalized by TIP side channel) a non-Nexus flush message is  generated which forces  the setting of atb.afready
*
* @example	- initial tip message forces synchronization message, folloed by an owenership message
*
*/

`default_nettype none
`undef	MY_DEBUG
`ifdef	MY_DEBUG
`define	MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define	MY_MARK_DEBUG
`endif
module ct_L2_msg_gen (
	input uwire logic 					proc_clk, 				// trace processing clock
	input uwire logic 					proc_rst,				// reset
	ct_cs_procclk_if.slave				cs_proc,				// control / status interface
	
	// Input - Extended internal-ETIP message + next PC
	source_if.client					etip_q,					// extended tip struct from FIFO
	source_if.client					next_iaddr_q,			// next iaddr from FIFO
	
	output nexus::nexus_msg_struct_t	trace_msg,				// generic trace message output
	
	// Flow Control from Downstream
	input uwire logic 					ready_in				// if 0, do not output new data

// 	atb_if.master 						atb,					// ATB for atb.syncreq
// 	input uwire	logic					syncreq_trace_quota,	// force sync msg on trace quota (# of sent trace messages / # of trace bytes, @ proc_clk)
// 	input uwire logic					do_stall				// if 1, do not output new data
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

	logic [31:0]							CurrICnt  = 0;  // current ICount
	logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0]	Hist      = 1;  // Hist field (commercial version only)
	logic [31:0]							HistCount = 1;  // length of valid bits in Hist field (commercial version only)
	nexus_msg_struct_t						TraceMsg  = '0; // generated trace message
	logic									FlushRequest = 0;
	localparam int unsigned  MAX_NEXUS_ICNT = (1 << NEXUS_MSG_I_CNT_WIDTH) - 1;

	uwire cf_needs_next_iaddr = HasChangedControlFlow(etip_cf.itype);
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
		(!cf_needs_next_iaddr || next_iaddr_q.valid) &&
		((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT);

	// A periodic/external sync in BRANCH_HIST mode would otherwise clear the
	// accumulated HIST bits without emitting them, leaving the decoder no way
	// to resolve earlier direct branches between the previous flush and the
	// sync point. Hold the sync eTIP back one cycle and emit a ResourceFull
	// HIST flush first.
	uwire cf_sync_hist_flush_hold =
		ready_in && etip_q.valid &&
		(etip_msg.sub_type == SUB_MSG_CF) &&
		(etip_cf.sync_reason != NEXUS_SYNC_NONE) &&
		(etip_cf.sync_reason != NEXUS_SYNC_EXIT_FROM_SYS_RST) &&
		(cs_proc.trTeInstMode == ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH_HIST) &&
		(!cf_needs_next_iaddr || next_iaddr_q.valid) &&
		(HistCount > 1);

	uwire consume_etip =
		ready_in && etip_q.valid && (
			(etip_msg.sub_type == SUB_MSG_NONE) ||
			(etip_msg.sub_type == SUB_MSG_DF)   ||
			(etip_msg.sub_type == SUB_MSG_DAQ)  ||
			(etip_msg.sub_type == SUB_MSG_OTHER) ||
			((etip_msg.sub_type == SUB_MSG_CF) && (!cf_needs_next_iaddr || next_iaddr_q.valid))
		) && !cf_indirect_hist_overflow_hold && !cf_sync_hist_flush_hold;

	//--------------------------------------------------------------------
	// main
	//--------------------------------------------------------------------
	// Combinational ack for both input source_ifs.
	assign etip_q.ack       = consume_etip;
	assign next_iaddr_q.ack = consume_etip
	                          && (etip_msg.sub_type == SUB_MSG_CF)
	                          && cf_needs_next_iaddr;

	uwire cf_proc_ready = ready_in;

	always_ff @(posedge proc_clk)begin
		if (proc_rst) begin
			FlushRequest <= 0;
			CurrICnt	 <= 0;
			Hist		 <= 1; // pre-load the stop bit
			HistCount	 <= 1;
			TraceMsg	 <= '0;
			TraceMsg.sub_type <= SUB_MSG_NONE;
		end
		else begin
			if (ready_in) begin
				// Default output: no message.
				// IMPORTANT: only clear when ready_in==1.
				// If ready_in==0, we must hold TraceMsg stable so the downstream
				// formatter can apply backpressure without losing messages.
				TraceMsg.sub_type	<= SUB_MSG_NONE;

				if (cf_indirect_hist_overflow_hold) begin
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
				if (FlushRequest) begin
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
		input etip_cf_msg_struct_t 			etip_cf;
		input tip_time_t	ts;

		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] hist;

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
			return;
		end

		// Composer-side trace-off marker. On trTeControl.Enable 1->0 the
		// composer emits a SUB_MSG_CF with rcode=TRACE_DISABLED carrying the
		// residual half-words. Turn it into a Program Trace Correlation Message
		// (TCODE 33, EVCODE=Program Trace Disabled) per IEEE-ISTO 5001 §4.3.16:
		// ICNT = all instruction units since the last transmitted ICNT
		// (CurrICnt + composer residual), CDATA = the pending branch HIST. The
		// formatter sets CDF=1 and emits HIST when it is non-empty
		// (rdata0 != stop-bit), CDF=0 otherwise. Clear the accumulators (this
		// is the final message).
		if (etip_cf.rcode == NEXUS_RCODE_TRACE_DISABLED) begin
			TraceMsg.sub_type      <= SUB_MSG_CF;
			TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_CORRELATION;
			TraceMsg.ts            <= ts;
			TraceMsg.sub.cf.icnt   <= CurrICnt + etip_cf.icnt;
			TraceMsg.sub.cf.rcode  <= NEXUS_RCODE_NONE;
			TraceMsg.sub.cf.rdata0 <= Hist;
			CurrICnt  <= 0;
			Hist      <= 1;
			HistCount <= 1;
			return;
		end

		TraceMsg.sub_type			<= SUB_MSG_CF;
		TraceMsg.ts					<= ts;
		TraceMsg.sub.cf.sync_reason	<= etip_cf.sync_reason;
		TraceMsg.sub.cf.curr_iaddr	<= etip_cf.iaddr;
		TraceMsg.sub.cf.next_iaddr	<= tip_iaddr_t' (next_iaddr_q.q);
		TraceMsg.sub.cf.icnt		<= CurrICnt + etip_cf.icnt;
		TraceMsg.sub.cf.rcode		<= NEXUS_RCODE_NONE;
		TraceMsg.sub.cf.rdata0		<= '0;
		TraceMsg.sub.cf.rdata1		<= '0;

			if (etip_cf.sync_reason != NEXUS_SYNC_NONE) begin
				// Emitted sync ICNT = CurrICnt (accumulated from prior CF
				// messages that did not themselves transmit ICNT) +
				// etip_cf.icnt (halfwords carried by the composer for the
				// current segment). Per the Nexus spec this is the number
				// of instruction units executed since the last transmitted
				// ICNT — inclusive of the sync PC for CF-syncs, exclusive
				// for ProgTraceSync (see the composer for the asymmetry).
				// Reset CurrICnt so the next message starts fresh.
				CurrICnt <= 0;
				Hist		<= 1; // pre-load the stop bit
				HistCount	<= 1;

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
		else begin
			case (cs_proc.trTeInstMode)
				ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH: begin
					case (etip_cf.itype)
						TAKEN_BRANCH, INFERRABLE_CALL, INFERRABLE_TAIL_CALL, OTHER_INFERABLE_JUMP: begin
							TraceMsg.tcode <= NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH;
							CurrICnt       <= 0;
						end
						NOT_TAKEN_BRANCH: begin
							TraceMsg.sub_type <= SUB_MSG_NONE;
							CurrICnt          <= CurrICnt + etip_cf.icnt;
						end
						UNINFERABLE_JUMP, INTERRUPT, EXCEPTION_IR, EXCEPTION_TRAP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, RETURN: begin
							TraceMsg.tcode <= NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH;
							CurrICnt       <= 0;
							case (etip_cf.itype)
								// EXCEPTION_IR (mret/sret) returns from a trap. From the
								// decoder's perspective it is an indirect branch, not an
								// interrupt entry -- mapping it to IBRANCH keeps the
								// handler-body halfwords on a BTYPE=IBRANCH IBH instead
								// of inflating BTYPE=INTERRUPT IBHs (whose ICNT must
								// reflect only the gap from the previous CF to the trap).
								UNINFERABLE_JUMP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, RETURN, EXCEPTION_IR: begin
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
						default: begin
							TraceMsg.sub_type <= SUB_MSG_NONE;
						end
					endcase
				end
					ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH_HIST: begin
						case (etip_cf.itype)
							TAKEN_BRANCH, NOT_TAKEN_BRANCH: begin
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
							//       Flush HIST and reset CurrICnt. The HIST_OVERFLOW
							//       message carries no ICNT field; the decoder
							//       resolves the flushed branch bits by walking the
							//       program (PCInfo) from the current PC, which fully
							//       advances both its PC *and* its instruction count
							//       across this span. The next ICNT-bearing packet
							//       (e.g. a periodic sync) must therefore count only
							//       instructions retired AFTER this flush — otherwise
							//       the decoder walks the flushed span twice (once via
							//       HIST resolution, once via the inflated ICNT).
							//   RCODE=0 (ICNT_OVERFLOW) — CurrICnt no longer fits the
							//       ICNT field of the next packet. Emit the accumulated
							//       halfwords now and reset CurrICnt; HIST is preserved.
							if (HistCount >= NEXUS_MSG_RDATA_WIDTH - 1) begin
								TraceMsg.sub_type       <= SUB_MSG_CF;
								TraceMsg.tcode          <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
								TraceMsg.sub.cf.rcode   <= NEXUS_RCODE_HIST_OVERFLOW;
								TraceMsg.sub.cf.rdata0  <= hist;
								Hist                    <= 1;
								HistCount               <= 1;
								CurrICnt                <= 0;
							end
							else if ((CurrICnt + etip_cf.icnt) > MAX_NEXUS_ICNT) begin
								TraceMsg.sub_type       <= SUB_MSG_CF;
								TraceMsg.tcode          <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
								TraceMsg.sub.cf.rcode   <= NEXUS_RCODE_ICNT_OVERFLOW;
								TraceMsg.sub.cf.rdata0  <= CurrICnt + etip_cf.icnt;
								CurrICnt                <= 0;
							end
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
								TraceMsg.sub.cf.rdata0  <= CurrICnt + etip_cf.icnt;
								CurrICnt                <= 0;
							end
						end
						UNINFERABLE_JUMP, INTERRUPT, EXCEPTION_IR, EXCEPTION_TRAP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, RETURN: begin
							TraceMsg.tcode         <= NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY;
							TraceMsg.sub.cf.rdata0 <= Hist;
							CurrICnt               <= 0;
							Hist                   <= 1;
							HistCount              <= 1;

							case (etip_cf.itype)
								// EXCEPTION_IR (mret/sret) returns from a trap. From the
								// decoder's perspective it is an indirect branch, not an
								// interrupt entry -- mapping it to IBRANCH keeps the
								// handler-body halfwords on a BTYPE=IBRANCH IBH instead
								// of inflating BTYPE=INTERRUPT IBHs (whose ICNT must
								// reflect only the gap from the previous CF to the trap).
								UNINFERABLE_JUMP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP, CO_ROUTINE_SWAP, RETURN, EXCEPTION_IR: begin
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
		input logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] hist;

		// RCODE=1 (HIST_OVERFLOW) carries no ICNT field. The decoder
		// resolves the flushed branch bits by walking the program
		// (PCInfo) from its current PC, which fully advances both its
		// PC *and* its instruction count across the flushed span. The
		// next ICNT-bearing packet must therefore count only the
		// instructions retired AFTER this flush — so reset CurrICnt
		// here. (NexRv does not "subtract walked halfwords" from a
		// later ICNT; leaving CurrICnt running double-counts the
		// flushed span, e.g. a periodic sync immediately after this
		// flush re-walks every branch it covered.)
		TraceMsg.sub_type         <= SUB_MSG_CF;
		TraceMsg.tcode            <= NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL;
		TraceMsg.ts               <= ts;
		TraceMsg.sub.cf.rcode     <= NEXUS_RCODE_HIST_OVERFLOW;
		TraceMsg.sub.cf.rdata0    <= hist;
		Hist                      <= 1;
		HistCount                 <= 1;
		CurrICnt                  <= 0;

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
		TraceMsg.sub.cf.rdata0    <= icnt;
		CurrICnt                  <= 0;
	endtask

	// ----------------------------------------------
	// TASK: send_df_msg
	// ----------------------------------------------
	task send_df_msg;
		input etip_df_msg_struct_t 			etip_df;
		input tip_time_t	ts;

		TraceMsg.sub_type				<= SUB_MSG_DF;
		TraceMsg.ts						<= ts;
		TraceMsg.sub.df_daq.data		<= etip_df.data;
		TraceMsg.sub.df_daq.dsz			<= etip_df.dsz;
		TraceMsg.sub.df_daq.elsz		<= etip_df.elsz;
		TraceMsg.sub.df_daq.addr_idtag	<= etip_df.addr_idtag;

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
	endtask

	// ----------------------------------------------
	// TASK: send_daq_msg
	// ----------------------------------------------
	task send_daq_msg;
		input etip_daq_msg_struct_t 		etip_daq;
		input tip_time_t					ts;

		TraceMsg.sub_type				<= SUB_MSG_DAQ;
		TraceMsg.ts						<= ts;
		TraceMsg.sub.df_daq.data		<= etip_daq.data;
		TraceMsg.sub.df_daq.addr_idtag	<= etip_daq.addr_idtag;
		TraceMsg.tcode					<= NEXUS_MSG_DATA_ACQUISITION;
	endtask

	// ----------------------------------------------
	// TASK: send_flush_msg
	// ----------------------------------------------
	task send_flush_msg;
		TraceMsg.sub_type	<= SUB_MSG_OTHER;
		TraceMsg.tcode		<= NEXUS_MSG_FLUSH;
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
			default: begin
				TraceMsg.sub.other <= '0;
			end
		endcase
	endtask

	assign trace_msg = TraceMsg;

endmodule

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
