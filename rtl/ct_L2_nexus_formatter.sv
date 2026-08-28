// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    Nexus message formatter (proc_clk): generic CF/DF/DAQ messages -> Nexus field lists.
 *
 * @details
 *   Converts CTTE generic trace messages (CF/DF/DAQ) into a Nexus message
 *   field list (`nexus_message_t`) — the field-oriented representation that the
 *   subsequent MDO/MSEO formatter packs into ATB chunks. A Nexus message is a
 *   sequence of fields and always starts with a TCODE field; understanding this
 *   module requires knowledge of the Nexus and ATB protocols. Field reference:
 *   https://github.com/riscv-non-isa/tg-nexus-trace/blob/master/docs/NexusTrace-TG-MessageDetails.adoc#71-fields-in-messages
 *
 *   Backpressure:
 *   - `ready_in` stalls the formatter chain.
 *   - When stalled, this module holds its output stable and deasserts
 *     `ready_out` to prevent upstream consumption.
 *
 *   Documentation reference:
 *   - See the CTTE Reference Manual (Processing Stage chapter).
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import nexus_vendor::*;
import nexus::*;
import ct_pkg::*;
import ct_cs_cpuif_pkg::*;

module ct_L2_nexus_formatter #(
	// Integration attribute of the attached core (sequentially-implicit
	// jumps ingress convention): advertised as config-message CAPS.6 so a
	// decoder knows the PCInfo must carry the -sijump convention. Set by
	// the integrator (MBV adapter: 1); no logic depends on it beyond the
	// config-message payload.
	parameter bit CT_SIJUMP = 1'b0,
	// Device ID (TCODE 1, P4) payload of THIS encoder instance. Layout per
	// IEEE-ISTO 5001 Table B-5 (RN | PN | MID); sampled here at emission
	// time exactly like the config-message payload -- the eTIP slot carries
	// only the trigger. The default 0 means "the integrator assigned no
	// device ID"; the message is only ever emitted when software sets
	// trTeControl.SendDeviceId != DID_NONE (reset DID_NONE).
	parameter logic [NEXUS_MSG_DEVID_WIDTH-1:0] CT_DEVICE_ID = '0
) (
	input uwire logic              proc_clk,  // trace processing clock
	input uwire logic              proc_rst,  // reset
	ct_cs_procclk_if.slave         cs_proc,   // control / status interface
	input uwire nexus_msg_struct_t trace_msg, // generic trace msg input
	output nexus_message_t         nexus_msg, // nexus msg output
	input uwire logic              ready_in,
	output uwire                   ready_out  // ready for receiving new trace_msg
);

	// ----------------------------------------------------------------
	// Sanity checks (simulation only)
	// ----------------------------------------------------------------
	// pragma translate_off
		initial begin
			if ($bits(nexus_process_t) != 49) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_process_t)=%0d (expected 49)", $bits(nexus_process_t));
			end
			if ($bits(nexus_cf_msg_struct_t) != NEXUS_MSG_SUB_WIDTH) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_cf_msg_struct_t)=%0d (expected %0d)",
					$bits(nexus_cf_msg_struct_t), NEXUS_MSG_SUB_WIDTH);
			end
			if ($bits(nexus_df_daq_msg_struct_t) != NEXUS_MSG_SUB_WIDTH) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_df_daq_msg_struct_t)=%0d (expected %0d)",
					$bits(nexus_df_daq_msg_struct_t), NEXUS_MSG_SUB_WIDTH);
			end
			if ($bits(nexus_other_msg_struct_t) != NEXUS_MSG_SUB_WIDTH) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_other_msg_struct_t)=%0d (expected %0d)",
					$bits(nexus_other_msg_struct_t), NEXUS_MSG_SUB_WIDTH);
			end
			if ($bits(nexus_error_msg_struct_t) != NEXUS_MSG_SUB_WIDTH) begin
				$fatal(1, "*** ERROR (%m): Unexpected $bits(nexus_error_msg_struct_t)=%0d (expected %0d)",
					$bits(nexus_error_msg_struct_t), NEXUS_MSG_SUB_WIDTH);
			end
		end
	// pragma translate_on

	// ----------------------------------------------------------------
	// Profile guard: DF address compression (P3) lives on the DF path --
	// TCODE 13/14 and the XOR reference are data-trace features, so the
	// switch is meaningless without the data-trace datapath (same
	// elaboration-$fatal pattern as the compact packer's CF-only guard).
	// ----------------------------------------------------------------
	if (ct_pkg::CT_EN_DF_ADDR_COMPRESS && !ct_pkg::CT_EN_DATA_TRACE) begin : genDfCompressNeedsDataTrace
		$fatal(1, "ct_L2_nexus_formatter: CT_EN_DF_ADDR_COMPRESS requires CT_EN_DATA_TRACE (TCODE 13/14 / DF XOR compression are data-trace features)");
	end

	// fixed nexus message field indices
	localparam IDX_TCODE                = 0;
	localparam IDX_SRC                  = 1;
	localparam IDX_DATA                 = 2;
	localparam IDX_TSTAMP               = NEXUS_MAX_FIELDS-1;


	nexus_cf_msg_struct_t       cf;
	nexus_df_daq_msg_struct_t   df_daq;
	nexus_error_msg_struct_t    err;
	nexus_other_msg_struct_t    other;

	// ----------------------------------------------------------------
	// Config-message payload (TCODE 58, C2 -- SPEC_config_message.md v1).
	// Sampled HERE from cs_proc when the message is emitted (the eTIP slot
	// carries only the trigger; the fields are quasi-static: writable only
	// while trTeControl.Enable = 0 by programming contract). The compact
	// packer replicates this construction -- byte equivalence is proven by
	// the compact=0/1 pair legs.
	// ----------------------------------------------------------------
	localparam logic [NEXUS_MSG_CFG_CAPS_WIDTH-1:0] CFG_CAPS =
		ct_pkg::ct_cfgmsg_caps(CT_SIJUMP);
	localparam logic [NEXUS_MSG_CFG_P3_WIDTH-1:0]   CFG_P3 = {
		5'(ct_pkg::CT_RET_STACK_DEPTH),        // [12:8] RetStackDepth
		4'($clog2(ct_pkg::CT_BP_ENTRIES)),     // [7:4]  BpTableLog2
		4'($clog2(ct_pkg::CT_JTC_ENTRIES))     // [3:0]  JtcIndexBits
	};
	// QUOTA_SYNC (CAPS.18) runtime-ENAB term: "actively used" = one of the
	// two trace-quota cadence modes is selected in InstSyncMode. There is no
	// separate enable bit -- the quota counters only run in these modes, so
	// the mode selection IS the runtime enable (ENAB semantics: feature
	// actively in use for this stream).
	localparam ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e
		QUOTA_MODE_MSG   = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_MSG,
		QUOTA_MODE_BYTES = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES;
	// DF_ADDR_COMPRESS (CAPS.21) runtime-ENAB term: the mode selection IS
	// the runtime enable (same pattern as QUOTA_SYNC -- no separate enable
	// bit; DTR_ADDR_FULL means the feature is not in use for this stream).
	localparam ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e_e
		DADDR_FULL = ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e__DTR_ADDR_FULL;
	// Tie the runtime-payload wires off when the feature is compiled out so
	// nothing survives synthesis (the consuming arm is gated the same way).
	// DEVICE_ID (CAPS.19) / WATCHPOINT_MSG (CAPS.20) runtime-ENAB terms (P4):
	// again the mode/mask selection IS the runtime enable -- SendDeviceId
	// != DID_NONE means the stream carries a Device ID message, a non-zero
	// WEM means at least one watchpoint slot may report.
	localparam ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e_e
		DID_NONE = ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e__DID_NONE;
	uwire logic [NEXUS_MSG_CFG_CAPS_WIDTH-1:0] cfg_enab = !ct_pkg::CT_EN_CONFIG_MSG ? '0 : CFG_CAPS & {
		1'b1,                                  // 23 ADDR64       = CAPS
		cs_proc.trTeDataDropEna,               // 22 DF_DROP
		(cs_proc.trTeDataAddrCompress != DADDR_FULL), // 21 DF_ADDR_COMPRESS
		(|cs_proc.trWpWEM),                    // 20 WATCHPOINT_MSG
		(cs_proc.trTeSendDeviceId != DID_NONE),// 19 DEVICE_ID
		(cs_proc.trTeInstSyncMode == QUOTA_MODE_MSG) || (cs_proc.trTeInstSyncMode == QUOTA_MODE_BYTES), // 18 QUOTA_SYNC
		1'b1,                                  // 17 DAQ          = CAPS
		cs_proc.trTeDataTracing,               // 16 DATA_TRACE
		cs_proc.trTsEnable,                    // 15 TIMESTAMP
		cs_proc.trTeInstSeqSyncEnable,         // 14 SEQ_SYNC
		cs_proc.trTeInstTrigEnable,            // 13 TRIG_SYNC
		1'b1,                                  // 12 EVTI         = CAPS
		1'b1,                                  // 11 POWER_EVENTS = CAPS
		1'b1,                                  // 10 DEBUG_EVENTS = CAPS
		cs_proc.trTeInstEnRepeatInstr,         //  9 REPEAT_INSTR
		cs_proc.trTeInstEnIbhs,                //  8 IBHS
		cs_proc.trTeContext,                   //  7 OWNERSHIP
		1'b1,                                  //  6 SIJUMP       = CAPS
		cs_proc.trTeInstEnBranchPrediction,    //  5 BP (steering)
		cs_proc.trTeInstEnJumpTargetCache,     //  4 JTC
		cs_proc.trTeInstEnRepeatBranch,        //  3 RB
		cs_proc.trTeInstEnWideIcnt,            //  2 WIDE_ICNT
		cs_proc.trTeInstEnRepeatedHistory,     //  1 RH
		cs_proc.trTeInstEnImplicitReturn       //  0 IR
	};
	uwire logic [NEXUS_MSG_CFG_P0_WIDTH-1:0] cfg_p0 = !ct_pkg::CT_EN_CONFIG_MSG ? '0 :
		{cs_proc.trTeSrcID, cs_proc.trTeSrcBits};
	uwire logic [NEXUS_MSG_CFG_P1_WIDTH-1:0] cfg_p1 = !ct_pkg::CT_EN_CONFIG_MSG ? '0 :
		{cs_proc.trTeInhibitSrc, cs_proc.trTeInstSyncMax,
		 4'(cs_proc.trTeInstSyncMode), 3'(cs_proc.trTeInstMode)};
	uwire logic [NEXUS_MSG_CFG_P2_WIDTH-1:0] cfg_p2 = !ct_pkg::CT_EN_CONFIG_MSG ? '0 :
		{cs_proc.trTsWidth, cs_proc.trTsPrescale,
		 3'(cs_proc.trTsType), cs_proc.trTsEnable};

	assign cf     = trace_msg.sub.cf;
	assign df_daq = trace_msg.sub.df_daq;
	assign err    = trace_msg.sub.err;
	assign other  = trace_msg.sub.other;

	nexus_message_t             NexusMsg;
	// NEXUS_MSG_PC_ADDR_SHIFT (from nexus_vendor) is the number of bits the encoder
	// drops from PC_FADDR / UADDR before emission; the decoder applies the
	// same count as a left-shift when reconstructing PCs. For RISC-V the
	// value is 1 (instructions are 16-bit aligned, so the LSB is always 0).
	// RefAddr stores the pre-shifted value so GetUaddr's XOR operates on
	// shifted coordinates consistently with FADDR emissions.
	nexus_addr_t                RefAddr  = 0;   //  reference address, see https://github.com/riscv-non-isa/tg-nexus-trace/blob/master/docs/NexusTrace-TG-MessageDetails.adoc#91-address-compression
	logic [31:0]                MsgNum   = 0;   // # of generated message (for debug only)

	// ----------------------------------------------------------------
	// DF address compression (P3, CT_EN_DF_ADDR_COMPRESS -- D-P3-1: the
	// reference lives HERE, behind the eTIP drop point, so lost messages
	// can never desynchronize it; the E-Trace path keeps its own full
	// address in the eTIP). RefDaddr holds the PREVIOUS data-trace
	// message's address in emission order (byte-granular -- data addresses
	// carry no PC shift). DfReanchor is the sticky re-anchor flag: while
	// set, the next DF message is upgraded to the synchronizing TCODE
	// 13/14 form carrying the FULL address (TCODE substitution at
	// emission; msg_gen keeps selecting 5/6). All logic consts away with
	// the switch at 0 (4a zero-cost-when-off); with mode DTR_ADDR_FULL
	// (runtime reset) the DF arm takes the historical full-address path
	// and the stream stays byte-identical.
	// ----------------------------------------------------------------
	uwire logic df_compress_active = ct_pkg::CT_EN_DF_ADDR_COMPRESS
	                              && (cs_proc.trTeDataAddrCompress != DADDR_FULL);
	logic [ADDR_WIDTH-1:0]      RefDaddr        = '0;   // previous DF message's address
	logic                       DfReanchor      = 1'b1; // sticky: next DF emits the 13/14 sync form
	logic                       DataTracingPrev = 1'b0; // for the DataTracing rising-edge trigger
	uwire logic df_is_df = (trace_msg.tcode == NEXUS_MSG_DATA_TRACE_READ)
	                    || (trace_msg.tcode == NEXUS_MSG_DATA_TRACE_WRITE);
	uwire nexus_tcode_e df_sync_tcode = (trace_msg.tcode == NEXUS_MSG_DATA_TRACE_READ)
		? NEXUS_MSG_DATA_TRACE_READ_SYNC
		: NEXUS_MSG_DATA_TRACE_WRITE_SYNC;
	uwire logic [ADDR_WIDTH-1:0] daddr_xor = !ct_pkg::CT_EN_DF_ADDR_COMPRESS ? '0
		: GetDaddrXor(df_daq.addr_idtag, RefDaddr);

	// TSTAMP encoding follows RISC-V N-Trace 8.5 / IEEE-ISTO 5001:
	//   - Synchronizing messages carry an *absolute* TSTAMP. The decoder
	//     re-baselines its accumulated time on each sync.
	//   - All other messages carry a *delta* relative to the previous TSTAMP-
	//     carrying message. The decoder reconstructs absolute time by adding
	//     each delta to its baseline.
	// On reset TsLastEmitted is 0, so the first emitted delta would equal
	// absolute time anyway — but real traces always start with a sync, which
	// carries the absolute value explicitly.
	// Unsigned 64-bit subtraction handles monotonic counter wrap naturally.
	nexus_ts_t                  TsLastEmitted = '0;
	nexus_ts_t                  TsDelta;
	nexus_ts_t                  ts_field;
	logic                       tcode_is_sync;
	logic                       df_sync_now;
	always_comb begin
		TsDelta = trace_msg.ts - TsLastEmitted;
		// The IBHS/RepeatInstructionSync terms are compile-masked: with the
		// feature off msg_gen never selects the TCODE, so the comparator
		// must not survive synthesis (4a zero-cost-when-off discipline).
		// tcode_is_sync deliberately does NOT cover TCODE 13/14: msg_gen
		// never selects them (the formatter upgrades a 5/6 at emission),
		// and the DF re-anchor trigger below must not re-set the flag the
		// upgrade just consumed. The synchronizing-TSTAMP rule for 13/14
		// (D-P3-5 / N-Trace 8.4) enters through the df_sync_now OR-term.
		tcode_is_sync = (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_SYNC)
					 || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC)
					 || (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC)
					 || (ct_pkg::CT_EN_IBHS && (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC))
					 || (ct_pkg::CT_EN_REPEAT_INSTR && (trace_msg.tcode == NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC));
		// The 13/14 upgrade condition of THIS message (combinational: the
		// DF arm emits the sync form and the TSTAMP mux goes absolute in
		// the same beat). Consts away with the switch (df_compress_active).
		df_sync_now = df_compress_active && DfReanchor && df_is_df;
		ts_field = (tcode_is_sync || df_sync_now) ? trace_msg.ts : TsDelta;
	end

	logic [ADDR_WIDTH-1:0] uaddr;
	always_comb begin
		uaddr = GetUaddr(cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, RefAddr);
	end

	// ----------------------------------------------------------------
	// DF reference / re-anchor state (P3). A dedicated always_ff: the
	// DataTracing edge must be observed in EVERY proc_clk cycle (also
	// during a ready_in stall), while the reference update and the flag
	// set/clear are tied to actual message emission (ready_in beat). Same
	// clock domain as the message path -- no interlock needed; the DF arm
	// below only READS DfReanchor/RefDaddr (via df_sync_now/daddr_xor).
	// ----------------------------------------------------------------
	if (ct_pkg::CT_EN_DF_ADDR_COMPRESS) begin : genDfAddrCompress
		uwire logic msg_fire = ready_in && (trace_msg.sub_type != SUB_MSG_NONE);
		always_ff @(posedge proc_clk) begin
			if (proc_rst) begin
				RefDaddr        <= '0;
				DfReanchor      <= 1'b1; // T2 trigger (d): reset re-anchors
				DataTracingPrev <= 1'b0;
			end
			else begin
				// Every emitted DF message re-seats the reference on its own
				// address (Nexus rule: UADDR is relative to the PREVIOUS
				// data-trace message -- the 13/14 sync form included) and
				// consumes the sticky flag.
				if (msg_fire && df_is_df && df_compress_active) begin
					RefDaddr   <= df_daq.addr_idtag[ADDR_WIDTH-1:0];
					DfReanchor <= 1'b0;
				end
				// Re-anchor triggers T2 (D-P3-2), set-dominant (a DF message
				// is never sync/ERROR itself, so set and clear cannot meet):
				//  (a) any synchronizing CF emission,
				//  (c) any ERROR emission (TCODE 8) -- decoder symmetry:
				//      NexRv invalidates its DF reference on ERROR (R8).
				if (msg_fire && (tcode_is_sync || (trace_msg.tcode == NEXUS_MSG_ERROR))) begin
					DfReanchor <= 1'b1;
				end
				//  (b) DataTracing rising edge -- observed unconditionally
				//      (an edge during a stall must not be lost). cs_proc
				//      carries the SW-programmed value; ACT-CAP runtime
				//      overrides are not visible here -- benign: the XOR
				//      chain stays consistent through emission gaps, the
				//      edge only ADDS a re-anchor point (documented in the
				//      P3 contract; data-only runs rely on exactly this
				//      trigger for their first 13/14).
				DataTracingPrev <= cs_proc.trTeDataTracing;
				if (cs_proc.trTeDataTracing && !DataTracingPrev) begin
					DfReanchor <= 1'b1;
				end
			end
		end
	end

	// No internal buffering: upstream may only advance when the downstream
	// formatter chain is ready. Keep this path combinational so backpressure is
	// visible in the same cycle, but gate it off during reset.
	assign ready_out = !proc_rst && ready_in;

	// ----------------------------------------------------------------
	// Task for simulation log output
	// ----------------------------------------------------------------

	task SimulationOutput;
		input integer       line;
		input integer       msg_num;
		input nexus_tcode_e tcode;

		// pragma translate_off
		$display("*** INFO (nexus_formatter, line %0d): (Msg %d) %s", line, msg_num, tcode.name());
		// pragma translate_on

	endtask

	// ----------------------------------------------------------------
	// convert generic trace msg to Nexus Message
	// ----------------------------------------------------------------
	always_ff @(posedge proc_clk)begin
		logic insert_src;
		int idx_data;
		int idx_next;

		if (proc_rst) begin
			// Initialize NexusMsg.fields (for simulation) on reset.
			for (int j = 0; j < NEXUS_MAX_FIELDS; j++) begin
				NexusMsg.fields[j].field_type   <= FIELD_INVALID;
				NexusMsg.fields[j].name         <= X;
				NexusMsg.fields[j].data         <= '0;
				NexusMsg.fields[j].data_width   <= 0;
			end
			RefAddr       <= 0;
			MsgNum        <= 0;
			TsLastEmitted <= '0;
		end
		else if (ready_in) begin
			// Only update output when the downstream is ready. Otherwise keep
			// NexusMsg stable to avoid dropping messages.
			//
			// Initialize NexusMsg.fields (for simulation)
			for (int j = 0; j < NEXUS_MAX_FIELDS; j++) begin
				NexusMsg.fields[j].field_type   <= FIELD_INVALID;
				NexusMsg.fields[j].name         <= X;
				NexusMsg.fields[j].data         <= '0;
				NexusMsg.fields[j].data_width   <= 0;
			end

			if (trace_msg.sub_type != SUB_MSG_NONE) begin

				MsgNum <= MsgNum+1;

				NexusMsg.id <= trace_msg.id;    // id of corresponding trace message, for debug

				// compose Nexus message: TCODE & SRC (first field for all Nexus messages)
				NexusMsg.fields[IDX_TCODE] <= '{TCODE, FIXED, trace_msg.tcode, 6};

				insert_src = !cs_proc.trTeInhibitSrc && trace_msg.tcode != NEXUS_MSG_FLUSH;
				idx_data = insert_src ? IDX_DATA : IDX_SRC;
				idx_next = idx_data;

				// Optional SRC must keep the field array dense because the new
				// parallel formatter consumes fields sequentially from index 0.
				if (insert_src) begin
					NexusMsg.fields[IDX_SRC] <= '{SRC, VENDOR_FIXED, cs_proc.trTeSrcID, cs_proc.trTeSrcBits};
				end

					case (trace_msg.tcode)
						NEXUS_MSG_PROGRAM_TRACE_SYNC: begin                     // compose Nexus Sync message
							NexusMsg.fields[idx_data+0] <= '{SYNC,      VENDOR_FIXED,    cf.sync_reason,    $size(nexus_sync_reason_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT,      VARIABLE,        cf.icnt,           LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{PC_FADDR,  VARIABLE,        cf.curr_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(cf.curr_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT)};
							idx_next                    = idx_data + 3;
							RefAddr                     <= cf.curr_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
							// V1 (2026-08-09): the sync REASON, by name, in the
							// simulator log. Until now it was only readable from
							// a successful NexRv decode of the whole stream --
							// which is unavailable exactly where it matters most:
							// a scenario that reconfigures on the fly makes the
							// decoder give up part way (measured on
							// tests/instruction/19_feature_matrix: the encoder
							// emits 190 messages, NexRv places 81), and every
							// statement about the cadence AFTER that point was
							// then unprovable. A cadence defect that emits NO
							// periodic sync at all (B-R13-1) is invisible in a
							// TCODE census -- the message simply is not there --
							// so a gate needs the reason, not the count.
							// Simulation-only, like SimulationOutput itself.
							// pragma translate_off
							$display("*** INFO (nexus_formatter, sync reason): (Msg %d) %s",
							         MsgNum, cf.sync_reason.name());
							// pragma translate_on
						end
						NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH: begin
							NexusMsg.fields[idx_data+0] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							idx_next                    = idx_data + 1;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC: begin
							NexusMsg.fields[idx_data+0] <= '{SYNC, VENDOR_FIXED, cf.sync_reason, $size(nexus_sync_reason_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{PC_FADDR, VARIABLE, cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT)};
							idx_next                    = idx_data + 3;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH: begin
							NexusMsg.fields[idx_data+0] <= '{BTYPE, VENDOR_FIXED, cf.btype, $size(nexus_btype_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{UADDR, VARIABLE, uaddr, LengthWoLeadingZeros(uaddr)};
							idx_next                    = idx_data + 3;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC: begin
							NexusMsg.fields[idx_data+0] <= '{SYNC, VENDOR_FIXED, cf.sync_reason, $size(nexus_sync_reason_e)};
							NexusMsg.fields[idx_data+1] <= '{BTYPE, VENDOR_FIXED, cf.btype, $size(nexus_btype_e)};
							NexusMsg.fields[idx_data+2] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+3] <= '{PC_FADDR, VARIABLE, cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT)};
							idx_next                    = idx_data + 4;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC: begin
							// TCODE 29 (IBHS): sync form that CARRIES
							// the pending branch history. Layout per N-Trace
							// Table 9: SYNC, BTYPE, ICNT, FADDR, HIST. msg_gen
							// places the anchor address in next_iaddr (target
							// for CF syncs, the sync instruction itself for
							// non-CF syncs) and the pending HIST in rdata0.
							// Compile-gated: with the feature off msg_gen never
							// selects this TCODE (4a zero-cost-when-off).
							if (ct_pkg::CT_EN_IBHS) begin
								NexusMsg.fields[idx_data+0] <= '{SYNC, VENDOR_FIXED, cf.sync_reason, $size(nexus_sync_reason_e)};
								NexusMsg.fields[idx_data+1] <= '{BTYPE, VENDOR_FIXED, cf.btype, $size(nexus_btype_e)};
								NexusMsg.fields[idx_data+2] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
								NexusMsg.fields[idx_data+3] <= '{PC_FADDR, VARIABLE, cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT)};
								NexusMsg.fields[idx_data+4] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
								idx_next                    = idx_data + 5;
								RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
								SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
							end
						end
						NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL: begin
							NexusMsg.fields[idx_data+0] <= '{RCODE, VENDOR_FIXED, cf.rcode, $size(nexus_rcode_e)};
							NexusMsg.fields[idx_data+1] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
							idx_next                    = idx_data + 2;
							if (cf.rcode == NEXUS_RCODE_HIST_OVERFLOW_REPEATED) begin
								NexusMsg.fields[idx_data+2] <= '{RDATA1, VENDOR_VARIABLE, cf.rdata1, LengthWoLeadingZeros(cf.rdata1)};
								idx_next                    = idx_data + 3;
							end
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION: begin
							// TCODE 31 (ISTO 4.3.14): R-CNT(rdata1),
							// I-CNT, HIST(rdata0) -- field order per Table 4-22
							// (bottom-up): TCODE, SRC, R-CNT, I-CNT, HIST, TSTAMP.
							// Compile-gated (4a zero-cost-when-off).
							if (ct_pkg::CT_EN_REPEAT_INSTR) begin
								NexusMsg.fields[idx_data+0] <= '{RDATA1, VENDOR_VARIABLE, cf.rdata1, LengthWoLeadingZeros(cf.rdata1)};
								NexusMsg.fields[idx_data+1] <= '{ICNT,   VARIABLE,        cf.icnt,   LengthWoLeadingZeros(cf.icnt)};
								NexusMsg.fields[idx_data+2] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
								idx_next                    = idx_data + 3;
								SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
							end
						end
						NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC: begin
							// TCODE 32 (ISTO 4.3.15): SYNC, R-CNT(rdata1), I-CNT,
							// F-ADDR(next_iaddr = loop PC), HIST(rdata0);
							// synchronizing -> RefAddr re-anchors.
							// Compile-gated (4a zero-cost-when-off).
							if (ct_pkg::CT_EN_REPEAT_INSTR) begin
								NexusMsg.fields[idx_data+0] <= '{SYNC,   VENDOR_FIXED,    cf.sync_reason, $size(nexus_sync_reason_e)};
								NexusMsg.fields[idx_data+1] <= '{RDATA1, VENDOR_VARIABLE, cf.rdata1, LengthWoLeadingZeros(cf.rdata1)};
								NexusMsg.fields[idx_data+2] <= '{ICNT,   VARIABLE,        cf.icnt,   LengthWoLeadingZeros(cf.icnt)};
								NexusMsg.fields[idx_data+3] <= '{PC_FADDR, VARIABLE, cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT)};
								NexusMsg.fields[idx_data+4] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
								idx_next                    = idx_data + 5;
								RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
								SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
							end
						end
						NEXUS_MSG_PROGRAM_TRACE_REPEAT_BRANCH: begin
							// TCODE 30: single BCNT field (suppressed-repeat count of
							// the previous IndirectBranchHist), variable-length like
							// the reference software encoder's AddVar(BCNT).
							NexusMsg.fields[idx_data+0] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
							idx_next                    = idx_data + 1;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_VENDOR_BRANCH_PREDICT: begin
							// Vendor TCODE 56: single BCNT field (rdata0) =
							// correctly predicted direct branches since the
							// last PC-walking message; the branch after them
							// mispredicted. No ICNT/UADDR; RefAddr does not
							// move (the decoder resolves targets by walking).
							// Unlike TCODE 30 it may carry a TSTAMP (it is a
							// regular message to the decoder, not a replay).
							NexusMsg.fields[idx_data+0] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
							idx_next                    = idx_data + 1;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_VENDOR_JUMP_TARGET_CACHE: begin
							// Vendor TCODE 57: IndirectBranchHist layout with the
							// 6-bit jump-target-cache index (rdata1) in place of
							// the differential UADDR. RefAddr still advances to
							// the actual target so later UADDR diffs stay correct
							// (decoder mirror: lastAddr = cache[JIDX]).
							NexusMsg.fields[idx_data+0] <= '{BTYPE, VENDOR_FIXED, cf.btype, $size(nexus_btype_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{RDATA1, VENDOR_VARIABLE, cf.rdata1, LengthWoLeadingZeros(cf.rdata1)};
							NexusMsg.fields[idx_data+3] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
							idx_next                    = idx_data + 4;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_CORRELATION: begin
							// TCODE 33, emitted only as the "Program Trace Disabled"
							// event on trace-off. Layout per RISC-V N-Trace 1.0
							// Table 24: EVCODE, CDF, ICNT, HIST. N-Trace HTM rule
							// (stricter than IEEE-ISTO 5001 §4.3.16): "In HTM trace
							// mode CDF must be 1 (even if HIST field is empty,
							// encoded as 0x1)" -- the HIST field is ALWAYS present
							// so the decoder need not read CDF to know it exists.
							// cf.rdata0 carries the stop-bit-preloaded Hist and is
							// therefore >= 0x1 by construction.
							// EVCODE rides cf.rdata1[3:0] (set by msg_gen: 4 =
							// Program Trace Disabled, 0 = Entry into Debug Mode,
							// 1 = Entry into Low-power Mode).
							NexusMsg.fields[idx_data+0] <= '{ETYPE, VENDOR_FIXED, cf.rdata1[NEXUS_MSG_EVCODE_WIDTH-1:0], NEXUS_MSG_EVCODE_WIDTH};
							NexusMsg.fields[idx_data+1] <= '{ECODE,  VENDOR_FIXED,    2'b01,     2};
							NexusMsg.fields[idx_data+2] <= '{ICNT,   VARIABLE,        cf.icnt,   LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+3] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
							idx_next                    = idx_data + 4;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY: begin
							NexusMsg.fields[idx_data+0] <= '{BTYPE, VENDOR_FIXED, cf.btype, $size(nexus_btype_e)};
							NexusMsg.fields[idx_data+1] <= '{ICNT, VARIABLE, cf.icnt, LengthWoLeadingZeros(cf.icnt)};
							NexusMsg.fields[idx_data+2] <= '{UADDR, VARIABLE, uaddr, LengthWoLeadingZeros(uaddr)};
							NexusMsg.fields[idx_data+3] <= '{RDATA0, VENDOR_VARIABLE, cf.rdata0, LengthWoLeadingZeros(cf.rdata0)};
							idx_next                    = idx_data + 4;
							RefAddr                     <= cf.next_iaddr >> NEXUS_MSG_PC_ADDR_SHIFT;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
						NEXUS_MSG_DATA_TRACE_READ, NEXUS_MSG_DATA_TRACE_WRITE: begin
							NexusMsg.fields[idx_data+0] <= '{DSZ,       VENDOR_FIXED,    df_daq.dsz,        $size(nexus_dsz_e)};
							NexusMsg.fields[idx_data+1] <= '{ELSZ,      VENDOR_FIXED,    df_daq.elsz,       $size(nexus_elsz_e)};
							// Address slot (P3, CT_EN_DF_ADDR_COMPRESS): mode
							// DTR_ADDR_FULL (reset) emits the unmodified
							// address -- byte-identical to the pre-P3 stream.
							// Mode XOR emits the XOR against the previous DF
							// message's address; the FIRST DF after a
							// re-anchor event is upgraded to the
							// synchronizing TCODE 13/14 with the FULL address
							// (TCODE substitution: the IDX_TCODE write below
							// overrides the generic one above -- last
							// nonblocking write wins; msg_gen keeps
							// selecting 5/6). Reference upkeep lives in
							// genDfAddrCompress above.
							if (df_sync_now) begin
								NexusMsg.fields[IDX_TCODE]  <= '{TCODE, FIXED,    df_sync_tcode,     6};
								NexusMsg.fields[idx_data+2] <= '{ADDR,  VARIABLE, df_daq.addr_idtag, LengthWoLeadingZeros(df_daq.addr_idtag)};
							end
							else if (df_compress_active) begin
								NexusMsg.fields[idx_data+2] <= '{UADDR, VARIABLE, daddr_xor,         LengthWoLeadingZeros(daddr_xor)};
							end
							else begin
								NexusMsg.fields[idx_data+2] <= '{UADDR, VARIABLE, df_daq.addr_idtag, LengthWoLeadingZeros(df_daq.addr_idtag)};
							end
							NexusMsg.fields[idx_data+3] <= '{DQDATA,    VARIABLE,        df_daq.data,       LengthWoLeadingZeros(df_daq.data)};
							idx_next                    = idx_data + 4;
							SimulationOutput(`__LINE__, MsgNum, df_sync_now ? df_sync_tcode : trace_msg.tcode);
						end
					NEXUS_MSG_DATA_ACQUISITION: begin
						NexusMsg.fields[idx_data+0] <= '{IDTAG,     VENDOR_FIXED,    df_daq.addr_idtag, NEXUS_IDTAG_WIDTH};
						NexusMsg.fields[idx_data+1] <= '{DQDATA,    VENDOR_VARIABLE, df_daq.data,       LengthWoLeadingZeros(df_daq.data)};
						idx_next                    = idx_data + 2;
						// pragma translate_off
							$display("*** INFO (nexus_formatter, line %0d): (Msg %0d) DAQ idtag=%0h dqdata=%0h",
								`__LINE__, MsgNum, df_daq.addr_idtag, df_daq.data);
						// pragma translate_on
						SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
					end

					NEXUS_MSG_OWNERSHIP_TRACE: begin
						// TCODE 2 (B6, N-Trace 7.1): single variable-length
						// PROCESS field = {CONTEXT, V, PRV, FORMAT} LSB-first
						// (Table 13; nexus_process_t is packed exactly so).
						// Compile-gated (4a zero-cost-when-off).
						if (ct_pkg::CT_EN_OWNERSHIP) begin
							NexusMsg.fields[idx_data+0] <= '{PROCESS, VENDOR_VARIABLE, other._process, LengthWoLeadingZeros(other._process)};
							idx_next                    = idx_data + 1;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
					end

					NEXUS_MSG_DEVICE_ID: begin
						// TCODE 1 (P4): single ID field. Payload sampled HERE
						// from the elaboration parameter (config-message
						// pattern -- the eTIP slot only triggered the
						// emission). VENDOR_VARIABLE instead of the "Fixed
						// 32" of ISTO Table 4-7: a fixed field would need a
						// SRC special case in both egress paths and in the
						// decoder's table mechanism -- documented deviation
						// (doc/trace-format.adoc). Non-sync: TSTAMP stays a
						// delta. Compile-gated (4a zero-cost-when-off).
						if (ct_pkg::CT_EN_DEVICE_ID) begin
							NexusMsg.fields[idx_data+0] <= '{DEVID, VENDOR_VARIABLE, CT_DEVICE_ID, LengthWoLeadingZeros(CT_DEVICE_ID)};
							idx_next                    = idx_data + 1;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
					end

					NEXUS_MSG_WATCHPOINT: begin
						// TCODE 15 (P4): single WPHIT field = the bitmap of
						// the watchpoints that fired (ACT-ST slot bits masked
						// by trWpMask.WEM; the mask is applied at the
						// composer, so what arrives here is already the
						// reportable set). Non-sync, so the TSTAMP below
						// stays a delta and RefAddr does not move.
						// Compile-gated (4a zero-cost-when-off).
						if (ct_pkg::CT_EN_WATCHPOINT_MSG) begin
							NexusMsg.fields[idx_data+0] <= '{WPHIT, VENDOR_VARIABLE, other.wphit, LengthWoLeadingZeros(other.wphit)};
							idx_next                    = idx_data + 1;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
					end

					NEXUS_MSG_VENDOR_CONFIG: begin
						// TCODE 58 (C2): CFGVER fixed(4), then six var fields
						// CAPS/ENAB/P0..P3 (SPEC_config_message.md v1). Payload
						// sampled from cs_proc/compile constants right here --
						// the eTIP slot only triggered the emission. Non-sync:
						// TSTAMP (below) stays a delta, tcode_is_sync untouched.
						// Compile-gated (4a zero-cost-when-off).
						if (ct_pkg::CT_EN_CONFIG_MSG) begin
							NexusMsg.fields[idx_data+0] <= '{CFGVER, VENDOR_FIXED,    ct_pkg::CT_CFGMSG_VER, NEXUS_MSG_CFGVER_WIDTH};
							NexusMsg.fields[idx_data+1] <= '{CAPS,   VENDOR_VARIABLE, CFG_CAPS, LengthWoLeadingZeros(CFG_CAPS)};
							NexusMsg.fields[idx_data+2] <= '{ENAB,   VENDOR_VARIABLE, cfg_enab, LengthWoLeadingZeros(cfg_enab)};
							NexusMsg.fields[idx_data+3] <= '{PARAM0, VENDOR_VARIABLE, cfg_p0,   LengthWoLeadingZeros(cfg_p0)};
							NexusMsg.fields[idx_data+4] <= '{PARAM1, VENDOR_VARIABLE, cfg_p1,   LengthWoLeadingZeros(cfg_p1)};
							NexusMsg.fields[idx_data+5] <= '{PARAM2, VENDOR_VARIABLE, cfg_p2,   LengthWoLeadingZeros(cfg_p2)};
							NexusMsg.fields[idx_data+6] <= '{PARAM3, VENDOR_VARIABLE, CFG_P3,   LengthWoLeadingZeros(CFG_P3)};
							idx_next                    = idx_data + 7;
							SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
						end
					end
					NEXUS_MSG_FLUSH: begin
						// TCODE only required, no other fields
						idx_next = IDX_SRC;
					end
						NEXUS_MSG_ERROR: begin
						NexusMsg.fields[idx_data+0] <= '{ETYPE,     FIXED,              err.etype,      $size(nexus_etype_e)};
						NexusMsg.fields[idx_data+1] <= '{ECODE,     VENDOR_FIXED,       err.ecode,      NEXUS_MSG_ECODE_WIDTH};
						idx_next                    = idx_data + 2;
						SimulationOutput(`__LINE__, MsgNum, trace_msg.tcode);
					end

					default: begin
						// TBD: error unexpected trace_msg.tcode
					end
				endcase

				// add optional timestamp. Sync messages carry the absolute
				// timestamp; all other messages carry a delta relative to the
				// previously emitted TSTAMP. Always update the baseline on a
				// TSTAMP emission so the next delta is computed against the
				// actual emitted (absolute or delta-base) value.
				// RepeatBranch (TCODE 30) is emitted WITHOUT a timestamp, like
				// the reference software encoder: NexRv preserves only the
				// first two fields of the previous message across the TCODE-30
				// parse, so a third (TSTAMP) field would clobber the saved
				// IBH's ICNT and the replay would walk zero instructions.
				if (cs_proc.trTsEnable && trace_msg.tcode != NEXUS_MSG_FLUSH
				    && trace_msg.tcode != NEXUS_MSG_PROGRAM_TRACE_REPEAT_BRANCH) begin
					NexusMsg.fields[idx_next]   <= '{TSTAMP, VENDOR_VARIABLE, ts_field, LengthWoLeadingZeros(ts_field)};
					TsLastEmitted               <= trace_msg.ts;
				end

			end
		end
	end

	assign nexus_msg = NexusMsg;

endmodule

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
