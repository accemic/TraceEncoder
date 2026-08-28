// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder L2 compact packer (generic trace message -> ATB chunks)
 *
 * @details
 *   Selected by ct_pkg::CT_COMPACT_PACKER: replaces the historical
 *   nexus_formatter (generic 10-field array) + message buffer + barrel bit
 *   slicer + MSEO controller with ONE module that produces the MDO/MSEO
 *   chunk stream DIRECTLY from a per-TCODE layout table (single-module
 *   packer pattern). The downstream ATB tail (chunk packer,
 *   CDC FIFO, flush detect) is reused unchanged.
 *
 *   Wire contract (byte-identical to the historical path):
 *   - Fields in per-TCODE order, transmitted LSB-first (IEEE-ISTO-5001 S.5).
 *   - All FIXED fields of a message form one contiguous bit string ("prefix":
 *     TCODE, optional SRC, per-TCODE subfields) -- dual-pin MSEO marks no
 *     fixed-field boundaries, so pre-merging them changes no byte.
 *   - Every VARIABLE field is emitted with leading-zero suppression
 *     (LengthWoLeadingZeros, >= 1 bit) and ends its MDO slice: the last
 *     slice holding its bits is zero-padded to the slice boundary.
 *   - MSEO per chunk: 11 on the message's last slice, 01 on a slice that
 *     ends a variable field mid-message, 00 otherwise (dual-pin encoding,
 *     as produced by the historical mseo_controller USE_DUAL_MSEO path).
 *   - FLUSH (TCODE 36) emits no data chunks; it pulses the chunk packer's
 *     flush_start (FLUSH_BEAT_COUNT idle beats), like the historical
 *     message-buffer flush detect.
 *   - RefAddr (Nexus address compression) and TSTAMP delta/absolute
 *     handling replicate ct_L2_nexus_formatter exactly, including the
 *     TCODE-30 no-TSTAMP rule (NexRv replay-clobber contract) and the
 *     historical trTeSrcBits==0 truncation quirk (see below).
 *
 *   Only assembly TIMING differs from the historical chain (~1 slice/cycle;
 *   one cycle per message accept and per variable-field handoff). The byte
 *   stream is invariant against assembly timing (proven pattern: the
 *   CT_SLICER_STEPS experiments), so the profiles this packer targets
 *   (bandwidth-uncritical slim/CF-only) see identical wire bytes.
 *
 *   Scope: CF-only profiles. The layout table covers the program-trace path
 *   (TCODEs 9/11/12/27 RCODE 0..2/28/30/33/56/57), ERROR (8) and FLUSH (36)
 *   -- everything ct_L2_msg_gen can emit in a control-flow-only profile.
 *   DF/DAQ message formats (TCODE 5/6/7) stay on the historical path;
 *   elaboration fails for profiles that could emit them.
 */

module ct_L2_compact_packer #(
	int unsigned MDO_WIDTH          = nexus_vendor::NEXUS_MDO_WIDTH, // MDO payload bits per chunk
	int unsigned ATB_CDC_FIFO_DEPTH = 8,                             // min depth of proc->atb CDC fifo
	bit          CT_SIJUMP          = 1'b0,                          // core integration attribute (config-message CAPS.6, see formatter)
	logic [nexus_vendor::NEXUS_MSG_DEVID_WIDTH-1:0] CT_DEVICE_ID = '0 // Device ID payload (TCODE 1, P4 -- see formatter)
) (
	input uwire logic               proc_clk,                  // trace processing clock
	input uwire logic               proc_rst,                  // trace processing reset
	input uwire logic               atb_atclk,                 // ATB clock
	input uwire logic               atb_atresetn,              // ATB reset (low active)
	input nexus::nexus_msg_struct_t trace_msg,                 // generic trace msg (from msg_gen)
	ct_cs_procclk_if.slave          cs_proc,                   // control / status interface (proc_clk domain)
	ct_cs_atbclk_if.slave           cs_atb,                    // control / status interface (atb_atclk domain)
	atb_if.master                   atb,                       // ATB output
	// Trace-output quota (P2) -- see ct_L2_mseo_mdo_formatter, identical
	// contract: held overflow levels + crossed SyncCntClr rearm.
	output logic                    synq_req_trace_byte_count, // byte-quota overflow level (InstSyncMode 4)
	output logic                    synq_req_trace_msg_count,  // message-quota overflow level (InstSyncMode 1)
	input  uwire logic              quota_cnt_clr,             // crossed SyncCntClr (proc_clk domain, rearm)
	output logic                    ready_out,                 // backpressure to msg_gen
	// trTeControl.Empty chain -- see ct_L2_mseo_mdo_formatter, identical
	// semantics: two-flop synchronizer plus a 16-cycle quiet filter in the
	// ATB domain, conservative.
	input uwire logic               upstream_empty,
	output uwire logic              chain_empty                // atb_atclk domain
);
	import nexus::*;
	import nexus_vendor::*;

	// ----------------------------------------------------------------
	// Profile guard: the layout table is CF-only (no DF/DAQ formats).
	// ----------------------------------------------------------------
	if (ct_pkg::CT_EN_DAQ || ct_pkg::CT_EN_DATA_TRACE || ct_pkg::CT_EN_ACT) begin : genUnsupportedProfile
		$fatal(1, "ct_L2_compact_packer: CT_COMPACT_PACKER requires a CF-only profile (CT_EN_DAQ=CT_EN_DATA_TRACE=CT_EN_ACT=0); DF/DAQ formats live only on the historical formatter path");
	end
	if (MDO_WIDTH != 6 && MDO_WIDTH != 14) begin : genUnsupportedMdo
		$fatal(1, "ct_L2_compact_packer: MDO_WIDTH=%0d not supported (6 and 14 only, like the bit slicer)", MDO_WIDTH);
	end

	// ----------------------------------------------------------------
	// Local constants
	// ----------------------------------------------------------------
	localparam int unsigned MSEO_WIDTH  = 2;
	localparam int unsigned CHUNK_WIDTH = MDO_WIDTH + MSEO_WIDTH;
	localparam int unsigned ATB_BEAT_BYTES = atb_pkg::ATDATA_WIDTH / 8;
	localparam int unsigned NUM_CHUNKS_PER_ATB_BEAT =
		(atb_pkg::ATDATA_WIDTH >= CHUNK_WIDTH) ? (atb_pkg::ATDATA_WIDTH / CHUNK_WIDTH) : 1;
	localparam int unsigned ATB_PAYLOAD_WIDTH = NUM_CHUNKS_PER_ATB_BEAT * CHUNK_WIDTH;
	localparam int unsigned ATB_PADDING_WIDTH = atb_pkg::ATDATA_WIDTH - ATB_PAYLOAD_WIDTH;

	// Fixed prefix: TCODE(6) + SRC (trTeSrcBits, 4-bit CSR -> up to 15) +
	// per-TCODE subfields (max 12: ERROR's ETYPE+ECODE).
	localparam int unsigned PREFIX_W = 6 + 15 + 12;
	// Widest walker payload: prefix or the widest single field.
	localparam int unsigned CURW  = (PREFIX_W > NEXUS_MAX_FIELD_DATA_WIDTH)
	                              ? PREFIX_W : NEXUS_MAX_FIELD_DATA_WIDTH;
	localparam int unsigned REM_W = $clog2(CURW + 1);
	localparam int unsigned POS_W = $clog2(MDO_WIDTH);

	// Segment indices: 0 = fixed prefix, 1..6 = variable payload slots,
	// 7 = TSTAMP. Variable slots fill in order (no gaps before TS).
	// Slots V4..V6 exist for the wide messages (TCODE 32: 4 var fields;
	// vendor config TCODE 58: 6 var fields) -- a profile that never
	// presents them keeps their present bits constant 0, so the extra
	// walker slots fold away (off-state stays LUT-neutral).
	localparam int unsigned SEG_PREFIX = 0;
	localparam int unsigned SEG_V1     = 1;
	localparam int unsigned SEG_V2     = 2;
	localparam int unsigned SEG_V3     = 3;
	localparam int unsigned SEG_V4     = 4;
	localparam int unsigned SEG_V5     = 5;
	localparam int unsigned SEG_V6     = 6;
	localparam int unsigned SEG_TS     = 7;

	typedef logic [CURW-1:0]  cur_t;
	typedef logic [REM_W-1:0] rem_t;
	typedef logic [3:0]       seg_idx_t;

	uwire logic msg_valid_in = (trace_msg.sub_type != ct_pkg::SUB_MSG_NONE);
	uwire nexus_cf_msg_struct_t    cf  = trace_msg.sub.cf;
	uwire nexus_error_msg_struct_t err = trace_msg.sub.err;
	uwire nexus_other_msg_struct_t oth = trace_msg.sub.other;

	// Config-message payload (TCODE 58, C2): replicates the historical
	// formatter's construction 1:1 (see ct_L2_nexus_formatter -- byte
	// equivalence proven by the compact=0/1 pair legs).
	localparam logic [NEXUS_MSG_CFG_CAPS_WIDTH-1:0] CFG_CAPS =
		ct_pkg::ct_cfgmsg_caps(CT_SIJUMP);
	localparam logic [NEXUS_MSG_CFG_P3_WIDTH-1:0]   CFG_P3 = {
		5'(ct_pkg::CT_RET_STACK_DEPTH),
		4'($clog2(ct_pkg::CT_BP_ENTRIES)),
		4'($clog2(ct_pkg::CT_JTC_ENTRIES))
	};
	// QUOTA_SYNC (CAPS.18) ENAB term -- see ct_L2_nexus_formatter: the mode
	// selection IS the runtime enable (no separate enable bit).
	localparam ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e
		QUOTA_MODE_MSG   = ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_MSG,
		QUOTA_MODE_BYTES = ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES;
	localparam ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e_e
		DID_NONE = ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e__DID_NONE;
	uwire logic [NEXUS_MSG_CFG_CAPS_WIDTH-1:0] cfg_enab = CFG_CAPS & {
		// 23 ADDR64 = CAPS: the address width has no runtime enable (it is
		// what the netlist is), so ENAB mirrors CAPS -- exactly as in
		// ct_L2_nexus_formatter.
		1'b1,
		// 22 DF_DROP: constant-0 here for the same reason as bit 21 --
		// CT_EN_DF_DROP requires CT_EN_DATA_TRACE, which is 0 in every
		// legal packer profile, so CAPS masks the bit anyway.
		1'b0,
		// 21 DF_ADDR_COMPRESS: constant-0 here. The packer is CF-only
		// ($fatal guard above), so CT_EN_DF_ADDR_COMPRESS (which requires
		// CT_EN_DATA_TRACE) is structurally 0 -- CAPS masks the bit anyway.
		1'b0,
		// 20 WATCHPOINT_MSG likewise: WPHIT comes from the ACT-ST path and
		// CT_EN_ACT is 0 in every legal packer profile (WEM reads 0 too).
		1'b0,
		(cs_proc.trTeSendDeviceId != DID_NONE),           // 19 DEVICE_ID
		(cs_proc.trTeInstSyncMode == QUOTA_MODE_MSG)
			|| (cs_proc.trTeInstSyncMode == QUOTA_MODE_BYTES), // 18 QUOTA_SYNC
		1'b1, cs_proc.trTeDataTracing, cs_proc.trTsEnable,
		cs_proc.trTeInstSeqSyncEnable, cs_proc.trTeInstTrigEnable,
		1'b1, 1'b1, 1'b1,
		cs_proc.trTeInstEnRepeatInstr, cs_proc.trTeInstEnIbhs,
		cs_proc.trTeContext, 1'b1,
		cs_proc.trTeInstEnBranchPrediction, cs_proc.trTeInstEnJumpTargetCache,
		cs_proc.trTeInstEnRepeatBranch, cs_proc.trTeInstEnWideIcnt,
		cs_proc.trTeInstEnRepeatedHistory, cs_proc.trTeInstEnImplicitReturn
	};
	uwire logic [NEXUS_MSG_CFG_P0_WIDTH-1:0] cfg_p0 =
		{cs_proc.trTeSrcID, cs_proc.trTeSrcBits};
	uwire logic [NEXUS_MSG_CFG_P1_WIDTH-1:0] cfg_p1 =
		{cs_proc.trTeInhibitSrc, cs_proc.trTeInstSyncMax,
		 4'(cs_proc.trTeInstSyncMode), 3'(cs_proc.trTeInstMode)};
	uwire logic [NEXUS_MSG_CFG_P2_WIDTH-1:0] cfg_p2 =
		{cs_proc.trTsWidth, cs_proc.trTsPrescale,
		 3'(cs_proc.trTsType), cs_proc.trTsEnable};

	// ----------------------------------------------------------------
	// Formatter state (identical semantics to ct_L2_nexus_formatter)
	// ----------------------------------------------------------------
	nexus_addr_t RefAddr       = '0; // Nexus address compression reference (pre-shifted)
	nexus_ts_t   TsLastEmitted = '0; // baseline of the TSTAMP delta encoding

	// ----------------------------------------------------------------
	// Per-TCODE layout decode (combinational, evaluated in the accept cycle)
	// ----------------------------------------------------------------
	uwire logic dec_is_flush = (trace_msg.tcode == NEXUS_MSG_FLUSH);

	// SRC insertion mirrors the formatter: suppressed for FLUSH and by
	// trTeInhibitSrc. Historical quirk kept bit-exact: with SRC enabled but
	// trTeSrcBits==0 the bit slicer treats the zero-width field as
	// end-of-message and truncates every message to its TCODE field.
	uwire logic       dec_insert_src = !cs_proc.trTeInhibitSrc && !dec_is_flush;
	uwire logic [3:0] dec_src_bits   = dec_insert_src ? cs_proc.trTeSrcBits : 4'd0;
	uwire logic       dec_src_trunc  = dec_insert_src && (cs_proc.trTeSrcBits == 4'd0);
	uwire logic [14:0] dec_src_data  = 15'(cs_proc.trTeSrcID) & ~(15'h7FFF << dec_src_bits);

	// TSTAMP: sync messages carry the absolute value, everything else the
	// delta to the previous TSTAMP-carrying message; TCODE 30 and FLUSH
	// carry none (and do not move the baseline).
	uwire logic dec_tcode_is_sync = (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_SYNC)
	                             || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC)
	                             || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC)
	                             || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC)
	                             || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC);
	uwire logic dec_has_ts = cs_proc.trTsEnable && !dec_is_flush
	                      && (trace_msg.tcode != NEXUS_MSG_PROGRAM_TRACE_REPEAT_BRANCH);
	uwire nexus_ts_t dec_ts_field = dec_tcode_is_sync ? trace_msg.ts
	                                                  : (trace_msg.ts - TsLastEmitted);

	// Address values (pre-shifted coordinates, see nexus_formatter RefAddr).
	uwire nexus_addr_t dec_faddr_curr = cf.curr_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
	uwire nexus_addr_t dec_faddr_next = cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
	uwire nexus_addr_t dec_uaddr      = GetUaddr(dec_faddr_next, RefAddr);

	// Layout table: fixed subfield bits (after TCODE+SRC), variable slots.
	logic [11:0]                           dec_sub;
	logic [3:0]                            dec_sub_len;
	logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] dec_seg [SEG_V1:SEG_V6];
	logic [SEG_TS:SEG_V1]                  dec_pres;
	logic                                  dec_ref_upd;
	nexus_addr_t                           dec_ref_val;

	always_comb begin
		dec_sub          = '0;
		dec_sub_len      = 4'd0;
		dec_seg[SEG_V1]  = '0;
		dec_seg[SEG_V2]  = '0;
		dec_seg[SEG_V3]  = '0;
		dec_seg[SEG_V4]  = '0;
		dec_seg[SEG_V5]  = '0;
		dec_seg[SEG_V6]  = '0;
		dec_pres         = '0;
		dec_pres[SEG_TS] = dec_has_ts;
		dec_ref_upd      = 1'b0;
		dec_ref_val      = dec_faddr_next;

		case (trace_msg.tcode)
			// DirectBranch (TCODE 3, BTM): ICNT only. The decoder
			// decodes the taken conditional branch opcode for the target, so
			// no address is transmitted and RefAddr does NOT advance (mirrors
			// the historical formatter's TCODE-3 arm).
			NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH: begin
				if (ct_pkg::CT_EN_BTM) begin
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
					dec_pres[SEG_V1] = 1'b1;
				end
			end
			// IndirectBranch (TCODE 4, BTM): BTYPE | ICNT, UADDR.
			// Like IndirectBranchHist (28) minus the HIST field; RefAddr
			// advances to the transmitted target.
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH: begin
				if (ct_pkg::CT_EN_BTM) begin
					dec_sub          = 12'(cf.btype);
					dec_sub_len      = 4'd2;
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
					dec_pres[SEG_V1] = 1'b1;
					dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(dec_uaddr);
					dec_pres[SEG_V2] = 1'b1;
					dec_ref_upd      = 1'b1;
				end
			end
			// 4.3.11 ProgTraceSync: SYNC | ICNT, FADDR(curr)
			NEXUS_MSG_PROGRAM_TRACE_SYNC: begin
				dec_sub          = 12'(cf.sync_reason);
				dec_sub_len      = 4'd4;
				dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
				dec_pres[SEG_V1] = 1'b1;
				dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(dec_faddr_curr);
				dec_pres[SEG_V2] = 1'b1;
				dec_ref_upd      = 1'b1;
				dec_ref_val      = dec_faddr_curr;
			end
			// 4.3.13 DirectBranchSync: SYNC | ICNT, FADDR(next)
			NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC: begin
				dec_sub          = 12'(cf.sync_reason);
				dec_sub_len      = 4'd4;
				dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
				dec_pres[SEG_V1] = 1'b1;
				dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(dec_faddr_next);
				dec_pres[SEG_V2] = 1'b1;
				dec_ref_upd      = 1'b1;
			end
			// 4.3.14 IndirectBranchSync: SYNC, BTYPE | ICNT, FADDR(next)
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC: begin
				dec_sub          = 12'(cf.sync_reason) | (12'(cf.btype) << 4);
				dec_sub_len      = 4'd6;
				dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
				dec_pres[SEG_V1] = 1'b1;
				dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(dec_faddr_next);
				dec_pres[SEG_V2] = 1'b1;
				dec_ref_upd      = 1'b1;
			end
			// IBHS (TCODE 29): SYNC, BTYPE | ICNT, FADDR, HIST.
			// Anchor address rides next_iaddr (see msg_gen/formatter).
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC: begin
				if (ct_pkg::CT_EN_IBHS) begin
					dec_sub          = 12'(cf.sync_reason) | (12'(cf.btype) << 4);
					dec_sub_len      = 4'd6;
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
					dec_pres[SEG_V1] = 1'b1;
					dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(dec_faddr_next);
					dec_pres[SEG_V2] = 1'b1;
					dec_seg[SEG_V3]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
					dec_pres[SEG_V3] = 1'b1;
					dec_ref_upd      = 1'b1;
				end
			end
			// 4.3.15 IndirectBranchHist: BTYPE | ICNT, UADDR, HIST(rdata0)
			NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY: begin
				dec_sub          = 12'(cf.btype);
				dec_sub_len      = 4'd2;
				dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
				dec_pres[SEG_V1] = 1'b1;
				dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(dec_uaddr);
				dec_pres[SEG_V2] = 1'b1;
				dec_seg[SEG_V3]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
				dec_pres[SEG_V3] = 1'b1;
				dec_ref_upd      = 1'b1;
			end
			// Vendor TCODE 57 (JTC): BTYPE | ICNT, JIDX(rdata1), HIST(rdata0);
			// RefAddr still advances to the real target (decoder mirror).
			NEXUS_MSG_VENDOR_JUMP_TARGET_CACHE: begin
				if (ct_pkg::CT_EN_JTC) begin
					dec_sub          = 12'(cf.btype);
					dec_sub_len      = 4'd2;
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
					dec_pres[SEG_V1] = 1'b1;
					dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata1);
					dec_pres[SEG_V2] = 1'b1;
					dec_seg[SEG_V3]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
					dec_pres[SEG_V3] = 1'b1;
					dec_ref_upd      = 1'b1;
				end
			end
			// 4.3.19 ResourceFull: RCODE | RDATA0 [, RDATA1 iff RCODE=2]
			NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL: begin
				dec_sub          = 12'(cf.rcode);
				dec_sub_len      = 4'd4;
				dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
				dec_pres[SEG_V1] = 1'b1;
				if (ct_pkg::CT_EN_REPEATED_HISTORY
				    && (cf.rcode == NEXUS_RCODE_HIST_OVERFLOW_REPEATED)) begin
					dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata1);
					dec_pres[SEG_V2] = 1'b1;
				end
			end
			// TCODE 31 RepeatInstruction (ISTO): R-CNT(rdata1) |
			// ICNT | HIST(rdata0), field order per ISTO Table 4-22.
			NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION: begin
				if (ct_pkg::CT_EN_REPEAT_INSTR) begin
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata1);
					dec_pres[SEG_V1] = 1'b1;
					dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
					dec_pres[SEG_V2] = 1'b1;
					dec_seg[SEG_V3]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
					dec_pres[SEG_V3] = 1'b1;
				end
			end
			// TCODE 32 RepeatInstructionSync (ISTO Table 4-23): SYNC |
			// R-CNT(rdata1) | ICNT | FADDR | HIST(rdata0); synchronizing.
			NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC: begin
				if (ct_pkg::CT_EN_REPEAT_INSTR) begin
					dec_sub          = 12'(cf.sync_reason);
					dec_sub_len      = 4'd4;
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata1);
					dec_pres[SEG_V1] = 1'b1;
					dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
					dec_pres[SEG_V2] = 1'b1;
					dec_seg[SEG_V3]  = NEXUS_MAX_FIELD_DATA_WIDTH'(dec_faddr_next);
					dec_pres[SEG_V3] = 1'b1;
					dec_seg[SEG_V4]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
					dec_pres[SEG_V4] = 1'b1;
					dec_ref_upd      = 1'b1;
				end
			end
			// TCODE 30 RepeatBranch: single BCNT(rdata0); never a TSTAMP.
			NEXUS_MSG_PROGRAM_TRACE_REPEAT_BRANCH: begin
				if (ct_pkg::CT_EN_REPEAT_BRANCH) begin
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
					dec_pres[SEG_V1] = 1'b1;
				end
			end
			// Vendor TCODE 56 (BP): single BCNT(rdata0).
			NEXUS_MSG_VENDOR_BRANCH_PREDICT: begin
				if (ct_pkg::CT_EN_BP) begin
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
					dec_pres[SEG_V1] = 1'b1;
				end
			end
			// Correlation (trace-off): EVCODE, CDF | ICNT, HIST. N-Trace 1.0
			// Table 24 HTM rule: CDF is ALWAYS 1 and the HIST field is always
			// present (empty history encoded as 0x1 -- rdata0 carries the
			// stop-bit-preloaded Hist, so it is >= 0x1 by construction).
			NEXUS_MSG_PROGRAM_TRACE_CORRELATION: begin
				// EVCODE rides cf.rdata1[3:0] (set by msg_gen; see formatter).
				dec_sub          = 12'(cf.rdata1[NEXUS_MSG_EVCODE_WIDTH-1:0])
				                 | (12'b01 << 4);
				dec_sub_len      = 4'd6;
				dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.icnt);
				dec_pres[SEG_V1] = 1'b1;
				dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cf.rdata0);
				dec_pres[SEG_V2] = 1'b1;
			end
			// Ownership (TCODE 2, B6): single variable PROCESS field.
			NEXUS_MSG_OWNERSHIP_TRACE: begin
				if (ct_pkg::CT_EN_OWNERSHIP) begin
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(oth._process);
					dec_pres[SEG_V1] = 1'b1;
				end
			end
			// Device ID (TCODE 1, P4): single variable ID field, sampled
			// from the elaboration parameter like the config payload.
			// (No TCODE-15 arm: the Watchpoint message needs CT_EN_ACT,
			// which the CF-only profile guard above excludes -- an arm here
			// would be unreachable code, so the packer legitimately does not
			// carry that format.)
			NEXUS_MSG_DEVICE_ID: begin
				if (ct_pkg::CT_EN_DEVICE_ID) begin
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(CT_DEVICE_ID);
					dec_pres[SEG_V1] = 1'b1;
				end
			end
			// Vendor TCODE 58 (config message, C2): CFGVER fixed(4), then
			// CAPS/ENAB/P0..P3 -- exactly the six variable slots.
			NEXUS_MSG_VENDOR_CONFIG: begin
				if (ct_pkg::CT_EN_CONFIG_MSG) begin
					dec_sub          = 12'(ct_pkg::CT_CFGMSG_VER);
					dec_sub_len      = 4'd4;
					dec_seg[SEG_V1]  = NEXUS_MAX_FIELD_DATA_WIDTH'(CFG_CAPS);
					dec_pres[SEG_V1] = 1'b1;
					dec_seg[SEG_V2]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cfg_enab);
					dec_pres[SEG_V2] = 1'b1;
					dec_seg[SEG_V3]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cfg_p0);
					dec_pres[SEG_V3] = 1'b1;
					dec_seg[SEG_V4]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cfg_p1);
					dec_pres[SEG_V4] = 1'b1;
					dec_seg[SEG_V5]  = NEXUS_MAX_FIELD_DATA_WIDTH'(cfg_p2);
					dec_pres[SEG_V5] = 1'b1;
					dec_seg[SEG_V6]  = NEXUS_MAX_FIELD_DATA_WIDTH'(CFG_P3);
					dec_pres[SEG_V6] = 1'b1;
				end
			end
			// 4.3.8 Error: ETYPE, ECODE (fixed only)
			NEXUS_MSG_ERROR: begin
				dec_sub     = 12'(err.etype) | (12'(err.ecode) << 4);
				dec_sub_len = 4'd12;
			end
			default: begin
				// Like the historical formatter's default arm: TCODE [+SRC]
				// [+TSTAMP] only. (BTM TCODE 3/4 are never emitted by
				// msg_gen -- ITR_BRANCH is reserved; DF/DAQ are excluded by
				// the profile guard above.)
			end
		endcase
	end

	// Prefix concatenation: TCODE | SRC | subfields, LSB-first field order.
	uwire logic [PREFIX_W-1:0] dec_prefix =
		PREFIX_W'(trace_msg.tcode)
		| (PREFIX_W'(dec_src_data) << 6)
		| ((PREFIX_W'(dec_sub) << 6) << dec_src_bits);
	uwire rem_t dec_prefix_len = dec_src_trunc
		? rem_t'(6)
		: rem_t'(6 + 32'(dec_src_bits) + 32'(dec_sub_len));

	// ----------------------------------------------------------------
	// Message state (latched in the accept cycle; msg_gen may replace
	// trace_msg one cycle after ready_out, so nothing downstream reads it)
	// ----------------------------------------------------------------
	logic                                  Busy      = 1'b0;
	logic                                  FlushPend = 1'b0;
	logic                                  EomPend   = 1'b0;
	logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] SegQ [SEG_V1:SEG_TS] = '{default: '0};
	logic [SEG_TS:SEG_V1]                  PresQ = '0;

	// Walker state
	seg_idx_t                SegIdx  = '0;
	cur_t                    CurData = '0;
	rem_t                    CurRem  = '0;
	logic [POS_W-1:0]        Pos     = '0;
	logic [MDO_WIDTH-1:0]    Acc     = '0;

	// Output chunk register (one entry, like the slicer's pipe stage)
	logic [MDO_WIDTH-1:0]    OutBits  = '0;
	logic [MSEO_WIDTH-1:0]   OutMseo  = 2'b11;
	logic                    OutEom   = 1'b0;
	logic                    OutValid = 1'b0;

	assign ready_out = !proc_rst && !Busy;

	// ----------------------------------------------------------------
	// Downstream: reused ATB tail (chunk packer -> CDC FIFO -> ATB)
	// ----------------------------------------------------------------
	typedef logic [ATB_PAYLOAD_WIDTH-1:0] atb_data_t;

	uwire logic packer_idle;
	uwire logic slice_ready;
	uwire logic packer_wr;
	uwire atb_data_t packer_payload;
	uwire logic atb_afready;
	uwire logic [atb_pkg::ATDATA_WIDTH-1:0] atdata_payload;

	uwire logic out_fire = OutValid && slice_ready;
	uwire logic [CHUNK_WIDTH-1:0] out_chunk = {OutBits, OutMseo};

	uwire logic atb_rst = !atb_atresetn;

	sink_if #(.T(atb_data_t)) atb_cdc_d (
		.clk(proc_clk),
		.rst(proc_rst)
	);
	source_if #(.T(atb_data_t)) atb_q (
		.clk(atb_atclk),
		.rst(atb_rst)
	);

	// Flush handshake: mirror of the historical flush_ready gating (chunk
	// packer drained + CDC FIFO can take the first idle beat). The pulse is
	// one cycle by construction: FlushPend clears in the same cycle.
	uwire logic flush_start = FlushPend && packer_idle && !OutValid && !atb_cdc_d.full;

	ct_L2_mseo_mdo_formatter_atb_chunk_packer #(
		.NEXUS_MAX_FIELDS(NEXUS_MAX_FIELDS), // keeps FLUSH_BEAT_COUNT identical to the historical path
		.MDO_WIDTH(MDO_WIDTH),
		.MSEO_WIDTH(MSEO_WIDTH)
	) u_chunk_packer (
		.clk(proc_clk),
		.rst(proc_rst),
		.atb_full(atb_cdc_d.full),
		.flush_start,
		.slice_valid(OutValid),
		.end_of_message(OutEom),
		.chunk_in(out_chunk),
		.slice_ready,
		.idle(packer_idle),
		.wr(packer_wr),
		.payload_out(packer_payload)
	);

	assign atb_cdc_d.d  = packer_payload;
	assign atb_cdc_d.wr = packer_wr;

	if (ct_pkg::CT_SINGLE_CLOCK) begin : genAtbFifo1clk
		fifo1clk_fwft #(
			.T(atb_data_t),
			.MIN_DEPTH(ATB_CDC_FIFO_DEPTH),
			.FIFO_STYLE("auto")
		) atb_cdc_fifo (
			.d(atb_cdc_d),
			.q(atb_q)
		);
	end
	else begin : genAtbFifo2clk
		fifo2clk_fwft #(
			.T(atb_data_t),
			.MIN_DEPTH(ATB_CDC_FIFO_DEPTH),
			.FIFO_STYLE("auto"),
			.SAFE_RESETS(1)
		) atb_cdc_fifo (
			.d(atb_cdc_d),
			.q(atb_q)
		);
	end

	assign atb_q.ack   = atb_q.valid && atb.atready;
	assign atb.atvalid = atb_q.valid;
	if (ATB_PADDING_WIDTH > 0) begin : blkAtbPad
		assign atdata_payload = {{ATB_PADDING_WIDTH{1'b1}}, atb_q.q};
	end
	else begin : blkAtbPad
		assign atdata_payload = atb_pkg::ATDATA_WIDTH'(atb_q.q);
	end
	assign atb.atdata  = atb_q.valid ? atdata_payload : {atb_pkg::ATDATA_WIDTH{1'b1}};
	assign atb.atid    = cs_atb.trAtbId;
	assign atb.atbytes = atb_pkg::ATBYTES_WIDTH'(ATB_BEAT_BYTES - 1);

	ct_L2_mseo_mdo_formatter_atb_flush_detect #(
		.MDO_WIDTH(MDO_WIDTH),
		.MSEO_WIDTH(MSEO_WIDTH)
	) u_atb_flush_detect (
		.clk(atb_atclk),
		.rst(atb_rst),
		.atvalid(atb_q.valid && atb.atready),
		.afvalid(atb.afvalid),
		.atb_payload(atb_q.q),
		.afready(atb_afready)
	);

	assign atb.afready = atb_afready;

	// ----------------------------------------------------------------
	// Trace-output quota counter (P2, D2/D3) -- same dedicated counter as
	// in ct_L2_mseo_mdo_formatter (see the design rationale there; NOT
	// counter.sv, '>='-compare, held level, clr priority, in-module mode
	// gate). Byte event = packer_wr (whole ATB beats incl. alignment
	// padding and flush idle beats); message event = out_fire && OutEom
	// (the FLUSH pseudo-message produces no chunks, so no OutEom).
	// QUOTA_MODE_MSG / QUOTA_MODE_BYTES are the module-level shorthands
	// declared next to the config-message payload above.
	// ----------------------------------------------------------------
	if (ct_pkg::CT_EN_QUOTA_SYNC) begin : genQuotaCnt
		uwire logic quota_mode_bytes = (cs_proc.trTeInstSyncMode == QUOTA_MODE_BYTES);
		uwire logic quota_mode_msg   = (cs_proc.trTeInstSyncMode == QUOTA_MODE_MSG);
		uwire ct_pkg::ct_synccnt_counter_t quota_max = 1 << (cs_proc.trTeInstSyncMax + 4);
		uwire logic quota_byte_ev = packer_wr;          // one accepted ATB beat
		uwire logic quota_msg_ev  = out_fire && OutEom; // last chunk of a message
		ct_pkg::ct_synccnt_counter_t QuotaCnt = '0;
		uwire logic quota_ovf = (QuotaCnt >= quota_max);
		always_ff @(posedge proc_clk) begin
			if (proc_rst || quota_cnt_clr || !(quota_mode_bytes || quota_mode_msg))
				QuotaCnt <= '0;
			else if (!quota_ovf) begin
				if      (quota_mode_bytes && quota_byte_ev) QuotaCnt <= QuotaCnt + ATB_BEAT_BYTES;
				else if (quota_mode_msg   && quota_msg_ev)  QuotaCnt <= QuotaCnt + 1'b1;
			end
		end
		assign synq_req_trace_byte_count = quota_ovf && quota_mode_bytes;
		assign synq_req_trace_msg_count  = quota_ovf && quota_mode_msg;
	end
	else begin : genNoQuotaCnt
		// Compiled out: zero cost, tie-offs like the pre-P2 state.
		assign synq_req_trace_byte_count = 1'b0;
		assign synq_req_trace_msg_count  = 1'b0;
		uwire logic unused_quota_cnt_clr = quota_cnt_clr;
	end

	// ----------------------------------------------------------------
	// trTeControl.Empty chain: registered on the proc side, two-flop
	// synchronized, 16-cycle quiet filter in the ATB domain (see
	// mseo_mdo_formatter).
	// ----------------------------------------------------------------
	logic       ProcEmptyQ    = 1'b0;
	logic [1:0] EmptySyncQ    = '0;
	logic [3:0] EmptyQuietCnt = '0;
	logic       ChainEmptyQ   = 1'b0;

	always_ff @(posedge proc_clk) begin
		if (proc_rst) ProcEmptyQ <= 1'b0;
		else ProcEmptyQ <= upstream_empty && !msg_valid_in && !Busy
		                   && !FlushPend && !OutValid && packer_idle;
	end

	always_ff @(posedge atb_atclk) begin
		if (atb_rst) begin
			EmptySyncQ    <= '0;
			EmptyQuietCnt <= '0;
			ChainEmptyQ   <= 1'b0;
		end
		else begin
			EmptySyncQ <= {EmptySyncQ[0], ProcEmptyQ};
			if (EmptySyncQ[1] && !atb_q.valid) begin
				if (&EmptyQuietCnt) ChainEmptyQ <= 1'b1;
				else                EmptyQuietCnt <= EmptyQuietCnt + 1'b1;
			end
			else begin
				EmptyQuietCnt <= '0;
				ChainEmptyQ   <= 1'b0;
			end
		end
	end
	assign chain_empty = ChainEmptyQ;

	// I8 (Empty contract, simulation only): Empty implies an idle ATB
	// output -- any remaining visible substance must drop Empty immediately.
	// pragma translate_off
`ifndef SYNTHESIS
	a_i8_empty_no_data: assert property (@(posedge atb_atclk) disable iff (atb_rst)
		ChainEmptyQ |-> !atb_q.valid)
		else $error("%m I8: trTeEmpty=1 while atb_q.valid=1");
`endif
	// pragma translate_on

	// Keep the compatibility tie-off explicit so lint does not flag the read.
	if (1) begin : blkCompat
		uwire logic unused_cs_proc_active = cs_proc.trTeActive;
	end

	// ----------------------------------------------------------------
	// Accept + walker (one MDO slice per cycle)
	// ----------------------------------------------------------------
	function automatic logic [MDO_WIDTH-1:0] mdo_low_mask(input int unsigned nbits);
		logic [MDO_WIDTH-1:0] mask;
		if (nbits == 0)               mask = '0;
		else if (nbits >= MDO_WIDTH)  mask = '1;
		else                          mask = ({MDO_WIDTH{1'b1}} >> (MDO_WIDTH - nbits));
		return mask;
	endfunction

	// Next present segment strictly after idx (SEG_TS+1 = none).
	function automatic seg_idx_t next_seg(input seg_idx_t idx,
	                                      input logic [SEG_TS:SEG_V1] pres);
		for (int i = SEG_V1; i <= SEG_TS; i++) begin
			if ((i > 32'(idx)) && pres[i]) begin
				return seg_idx_t'(i);
			end
		end
		return seg_idx_t'(SEG_TS + 1);
	endfunction

	always_ff @(posedge proc_clk) begin
		if (proc_rst) begin
			Busy      <= 1'b0;
			FlushPend <= 1'b0;
			EomPend   <= 1'b0;
			SegIdx    <= '0;
			CurData   <= '0;
			CurRem    <= '0;
			Pos       <= '0;
			Acc       <= '0;
			OutBits   <= '0;
			OutMseo   <= 2'b11;
			OutEom    <= 1'b0;
			OutValid  <= 1'b0;
			RefAddr       <= '0;
			TsLastEmitted <= '0;
			for (int i = SEG_V1; i <= SEG_TS; i++) begin
				SegQ[i]  <= '0;
				PresQ[i] <= 1'b0;
			end
		end
		else begin
			if (out_fire) begin
				OutValid <= 1'b0;
			end

			if (!Busy) begin
				// ------------------------------------------------------
				// Accept: latch the per-TCODE layout; update RefAddr and
				// the TSTAMP baseline in message order (values consumed by
				// this message were computed from the pre-update state).
				// ------------------------------------------------------
				if (msg_valid_in && !proc_rst) begin
					Busy <= 1'b1;
					if (dec_is_flush) begin
						FlushPend <= 1'b1;
					end
					else begin
						CurData <= CURW'(dec_prefix);
						CurRem  <= dec_prefix_len;
						SegIdx  <= seg_idx_t'(SEG_PREFIX);
						Pos     <= '0;
						Acc     <= '0;
						for (int i = SEG_V1; i <= SEG_V6; i++) begin
							SegQ[i] <= dec_seg[i];
						end
						SegQ[SEG_TS] <= NEXUS_MAX_FIELD_DATA_WIDTH'(dec_ts_field);
						PresQ        <= dec_src_trunc ? '0 : dec_pres;
						if (dec_ref_upd) begin
							RefAddr <= dec_ref_val;
						end
						if (dec_has_ts) begin
							// Baseline moves whenever a TSTAMP goes out --
							// matching the formatter, which does not special-
							// case the SrcBits==0 truncation quirk either
							// (its TS update runs before the slicer truncates).
							TsLastEmitted <= trace_msg.ts;
						end
					end
					// pragma translate_off
					assert (trace_msg.sub_type inside {ct_pkg::SUB_MSG_CF, ct_pkg::SUB_MSG_OTHER})
						else $error("%m: compact packer got sub_type=%0d (DF/DAQ are excluded by the CF-only profile guard)", trace_msg.sub_type);
					// pragma translate_on
				end
			end
			else if (FlushPend) begin
				if (flush_start) begin
					FlushPend <= 1'b0;
					Busy      <= 1'b0;
				end
			end
			else if (EomPend) begin
				// Final chunk is in the output register; release the message
				// once the chunk packer takes it.
				if (out_fire) begin
					EomPend <= 1'b0;
					Busy    <= 1'b0;
				end
			end
			else if (!OutValid || out_fire) begin
				// ------------------------------------------------------
				// Build step: consume up to one field per cycle into the
				// slice accumulator; emit when the slice closes.
				// ------------------------------------------------------
				int unsigned          avail_i;
				int unsigned          take_i;
				logic [MDO_WIDTH-1:0] acc_next;
				cur_t                 data_next;
				rem_t                 rem_next;
				int unsigned          pos_after;
				logic                 is_prefix;
				seg_idx_t             nxt;

				avail_i   = MDO_WIDTH - 32'(Pos);
				take_i    = (32'(CurRem) < avail_i) ? 32'(CurRem) : avail_i;
				acc_next  = Acc | ((MDO_WIDTH'(CurData) & mdo_low_mask(take_i)) << Pos);
				data_next = CurData >> take_i;
				rem_next  = CurRem - rem_t'(take_i);
				pos_after = 32'(Pos) + take_i;
				is_prefix = (SegIdx == seg_idx_t'(SEG_PREFIX));
				nxt       = next_seg(SegIdx, PresQ);

				if (rem_next != '0) begin
					// Field continues; slice is full by construction
					// (take < rem implies take == avail).
					OutBits  <= acc_next;
					OutMseo  <= 2'b00;
					OutEom   <= 1'b0;
					OutValid <= 1'b1;
					Acc      <= '0;
					Pos      <= '0;
					CurData  <= data_next;
					CurRem   <= rem_next;
				end
				else if (nxt > seg_idx_t'(SEG_TS)) begin
					// Message ends with this field: emit the final slice
					// (zero-padded when partial) with MSEO end-of-message.
					OutBits  <= acc_next;
					OutMseo  <= 2'b11;
					OutEom   <= 1'b1;
					OutValid <= 1'b1;
					Acc      <= '0;
					Pos      <= '0;
					EomPend  <= 1'b1;
				end
				else if (is_prefix) begin
					// Fixed prefix exhausted: the next (variable) field
					// continues in the SAME slice -- no MSEO boundary for
					// fixed fields on the dual-pin encoding.
					SegIdx  <= nxt;
					CurData <= CURW'(SegQ[nxt]);
					CurRem  <= rem_t'(LengthWoLeadingZeros(SegQ[nxt]));
					if (pos_after == MDO_WIDTH) begin
						OutBits  <= acc_next;
						OutMseo  <= 2'b00;
						OutEom   <= 1'b0;
						OutValid <= 1'b1;
						Acc      <= '0;
						Pos      <= '0;
					end
					else begin
						// Partial slice stays in the accumulator; the
						// variable field fills it next cycle.
						Acc <= acc_next;
						Pos <= POS_W'(pos_after);
					end
				end
				else begin
					// Variable field ends: it always closes its slice
					// (zero-padded to the boundary), MSEO end-of-packet.
					OutBits  <= acc_next;
					OutMseo  <= 2'b01;
					OutEom   <= 1'b0;
					OutValid <= 1'b1;
					Acc      <= '0;
					Pos      <= '0;
					SegIdx   <= nxt;
					CurData  <= CURW'(SegQ[nxt]);
					CurRem   <= rem_t'(LengthWoLeadingZeros(SegQ[nxt]));
				end
			end
		end
	end

endmodule

`default_nettype wire
