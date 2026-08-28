// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>
 *
 * @brief    Micro CSR block: hand-written drop-in
 *           replacement for the generated ct_cs_cpuif in CONTROL-FLOW-ONLY
 *           slim profiles. Selected by ct_pkg::CT_MICRO_CSR inside
 *           ct_cs_cpuif_wb; port- and hwif-compatible.
 *
 * @details
 *   SW-visible contract (verified against the PeakRDL slim regblock,
 *   profile CT_EN_{DAQ,DATA_TRACE,ACT,FILTERS,<compression>} = 0):
 *     - live registers: trTeControl (0x0), trTeInstFeatures (0x8, SrcID/
 *       SrcBits), trTsControl (0x40, iff CT_EN_TIMESTAMP), trTeTipFifoStatus
 *       (0xe04, clear bits), trAtbBridgeControl.ID (0x1000),
 *       trAtbBridgeImpl.AsyncFreq (0x1004); swwel gating (writable only
 *       while trTeControl.Enable==0) identical to the RDL declarations.
 *     - read-only constants: trTeImpl, trPc-, trWp-, trDf- discovery regs,
 *       trTeConstants, trPerfCntControl -- byte-identical values.
 *     - gated feature groups (filters/comparators/perfcnt ranges/DF/DAQ)
 *       read 0 exactly like their sw=r reset-0 constants in the generated
 *       slim block; writes are acked and ignored (no decode error -- the
 *       generated block has "no valid address check" either).
 *     - trTeDataControl.DataTracing reads constant 0 (the generated slim
 *       block keeps an hwset/hwclr storage for it, but the only setters
 *       are the ACT-CAP blocks, which the profile guard excludes).
 *     - external watchpoint/df-range windows (0x41xx/0x6xxx) do not exist
 *       (profile guard); reads return 0 without stalling.
 *   Protocol: passthrough cpuif, combinational single-cycle ack, no
 *   stalls, no error responses -- same timing as the generated block for
 *   non-external accesses (the generated block only stalled on external
 *   watchpoint/mem windows, which this profile does not have).
 */

module ct_cs_micro (
	input uwire logic                          clk,
	input uwire logic                          rst,

	input uwire logic                          s_cpuif_req,
	input uwire logic                          s_cpuif_req_is_wr,
	input uwire logic [14:0]                   s_cpuif_addr,
	input uwire logic [31:0]                   s_cpuif_wr_data,
	input uwire logic [31:0]                   s_cpuif_wr_biten,
	output logic                               s_cpuif_req_stall_wr,
	output logic                               s_cpuif_req_stall_rd,
	output logic                               s_cpuif_rd_ack,
	output logic                               s_cpuif_rd_err,
	output logic [31:0]                        s_cpuif_rd_data,
	output logic                               s_cpuif_wr_ack,
	output logic                               s_cpuif_wr_err,

	input  ct_cs_cpuif_pkg::ct_cs_cpuif__in_t  hwif_in,
	output ct_cs_cpuif_pkg::ct_cs_cpuif__out_t hwif_out
);

	import ct_cs_cpuif_pkg::*;

	// Profile guard: the micro block implements exactly the CF-only slim
	// register contract -- any richer profile must use the generated block.
	initial begin
		if (ct_pkg::CT_EN_DAQ || ct_pkg::CT_EN_DATA_TRACE || ct_pkg::CT_EN_ACT
			|| ct_pkg::CT_EN_FILTERS || ct_pkg::CT_EN_COMPRESSION)
			$fatal(1, "*** ERROR (%m): CT_MICRO_CSR requires the CF-only slim profile (DAQ/DT/ACT/FILTERS/compression all 0)");
		// P7: the micro block does not decode the trigger configuration block
		// (te 0x050/0x054/0x058). Silently reading 0 from ExtInAction0 while
		// the routing is BUILT would be a lying discovery answer -- so a
		// CT_EN_TRIG_REGS build must use the generated block.
		if (ct_pkg::CT_EN_TRIG_REGS)
			$fatal(1, "*** ERROR (%m): CT_MICRO_CSR does not implement the trigger configuration block -- set CT_EN_TRIG_REGS = 0 or use the generated register block");
		// Same class, found by the P8 twin-drift guard: the micro block does
		// not decode the eTIP FIFO fill histogram (te 0xe10/0xe14). With
		// CT_EN_FIFO_HIST = 1 the bins are COUNTING in tip_clk, so reading a
		// constant 0 here would hide a built diagnostic just as silently.
		if (ct_pkg::CT_EN_FIFO_HIST)
			$fatal(1, "*** ERROR (%m): CT_MICRO_CSR does not implement the eTIP FIFO fill histogram -- set CT_EN_FIFO_HIST = 0 or use the generated register block");
	end

	// ----------------------------------------------------------------
	// Request decode (live registers only; everything else acks + reads 0)
	// ----------------------------------------------------------------
	uwire        req    = s_cpuif_req;
	uwire        wr     = s_cpuif_req & s_cpuif_req_is_wr;
	uwire [14:0] addr   = s_cpuif_addr;
	uwire [31:0] wdata  = s_cpuif_wr_data;
	uwire [31:0] biten  = s_cpuif_wr_biten;

	uwire sel_control    = (addr == 15'h0);
	uwire sel_features   = (addr == 15'h8);
	uwire sel_tscontrol  = (addr == 15'h40);
	uwire sel_fifostatus = (addr == 15'he04);
	uwire sel_atbctrl    = (addr == 15'h1000);
	uwire sel_atbimpl    = (addr == 15'h1004);

	// ----------------------------------------------------------------
	// Storage (resets == RDL reset values of the slim regblock)
	// ----------------------------------------------------------------
	logic       Active       = 1'b0;
	logic       Enable       = 1'b0;
	logic       InstTracing  = 1'b0;
	logic [2:0] InstMode     = 3'h6;
	logic       InhibitSrc   = 1'b1;
	logic [3:0] InstSyncMode = 4'h0;
	logic [3:0] InstSyncMax  = 4'h6;   // 2^(6+4) = 1024 units (P0-02)
	logic       InstSyncReq  = 1'b0;
	// trTeControl.InstStallOrOverflow [12] (P7/G12, N-Trace Required): sticky
	// RW1C overflow status. Implemented here too -- reading a constant 0 while
	// the encoder CAN overflow would be a lying status bit.
	logic       InstStallOvf = 1'b0;

	logic [11:0] SrcID   = 12'ha;
	logic [3:0]  SrcBits = 4'h4;

	logic       TsActive   = 1'b0;
	logic       TsCount    = 1'b0;
	logic       TsReset    = 1'b0;
	logic [2:0] TsType     = 3'h0;
	logic [1:0] TsPrescale = 2'h0;
	logic       TsEnable   = ct_pkg::CT_EN_TIMESTAMP ? 1'b1 : 1'b0;

	logic       MaxFillClear      = 1'b0;
	logic       NumOverflowsClear = 1'b0;

	logic [6:0] AtbId       = 7'h8;
	logic [2:0] AtbAsyncFreq = 3'h0;

	// trTeCsrControl (0xe00, read-only for SW): plain hw-follow registers,
	// one cycle behind hwif_in like the generated block.
	logic CsrSendSync = 1'b0, CsrSendPC = 1'b0, CsrSendTS = 1'b0, CsrSendCC = 1'b0;

	// swwel: config fields writable only while Enable==0 (gate evaluates the
	// CURRENT stored Enable, exactly like the generated write gate).
	uwire cfg_wr_en = !Enable;

	always_ff @(posedge clk) begin
		if (rst) begin
			Active       <= 1'b0;
			Enable       <= 1'b0;
			InstTracing  <= 1'b0;
			InstMode     <= 3'h6;
			InhibitSrc   <= 1'b1;
			InstSyncMode <= 4'h0;
			InstSyncMax  <= 4'h6;
			InstSyncReq  <= 1'b0;
			InstStallOvf <= 1'b0;
			SrcID        <= 12'ha;
			SrcBits      <= 4'h4;
			TsActive     <= 1'b0;
			TsCount      <= 1'b0;
			TsReset      <= 1'b0;
			TsType       <= 3'h0;
			TsPrescale   <= 2'h0;
			TsEnable     <= ct_pkg::CT_EN_TIMESTAMP ? 1'b1 : 1'b0;
			MaxFillClear      <= 1'b0;
			NumOverflowsClear <= 1'b0;
			AtbId        <= 7'h8;
			AtbAsyncFreq <= 3'h0;
			CsrSendSync <= 1'b0; CsrSendPC <= 1'b0; CsrSendTS <= 1'b0; CsrSendCC <= 1'b0;
		end
		else begin
			// trTeControl @0x0 (bitwise write-enable == generated biten mask)
			if (wr && sel_control) begin
				Active      <= biten[0] ? wdata[0] : Active;
				Enable      <= biten[1] ? wdata[1] : Enable;
				InstTracing <= biten[2] ? wdata[2] : InstTracing;
				if (cfg_wr_en) begin
					InstMode     <= (InstMode     & ~biten[6:4])   | (wdata[6:4]   & biten[6:4]);
					InhibitSrc   <= biten[15] ? wdata[15] : InhibitSrc;
					InstSyncMode <= (InstSyncMode & ~biten[19:16]) | (wdata[19:16] & biten[19:16]);
					InstSyncMax  <= (InstSyncMax  & ~biten[23:20]) | (wdata[23:20] & biten[23:20]);
				end
				InstSyncReq <= biten[27] ? wdata[27] : InstSyncReq;
				// InstStallOrOverflow [12] is RW1C (P7/G12): a written 1 clears.
				if (biten[12] && wdata[12]) InstStallOvf <= 1'b0;
			end
			else begin
				// InstTracing: hw set/clear (ACT-CAP path; priority below SW
				// write like the generated block); InstSyncReq is
				// `sw = w; singlepulse;` and clears itself in the cycle after
				// the write -- the generated block does exactly this (`next_c
				// = '0` in its non-write branch), so the twin does too.
				if (hwif_in.te.trTeControl.InstTracing.hwset)      InstTracing <= 1'b1;
				else if (hwif_in.te.trTeControl.InstTracing.hwclr) InstTracing <= 1'b0;
				InstSyncReq <= 1'b0;
			end
			// InstStallOrOverflow: hw set (overflow message generated) /
			// hw clear (encoder disabled), same precedence as the generated
			// block -- SW write wins, then hwset, then hwclr.
			if (!(wr && sel_control && biten[12] && wdata[12])) begin
				if (hwif_in.te.trTeControl.InstStallOrOverflow.hwset)      InstStallOvf <= 1'b1;
				else if (hwif_in.te.trTeControl.InstStallOrOverflow.hwclr) InstStallOvf <= 1'b0;
			end

			// trTeInstFeatures @0x8 (feature-enable bits are sw=r constants)
			if (wr && sel_features && cfg_wr_en) begin
				SrcID   <= (SrcID   & ~biten[27:16]) | (wdata[27:16] & biten[27:16]);
				SrcBits <= (SrcBits & ~biten[31:28]) | (wdata[31:28] & biten[31:28]);
			end

			// trTsControl @0x40 (whole register sw=r when TS compiled out)
			if (ct_pkg::CT_EN_TIMESTAMP && wr && sel_tscontrol) begin
				TsActive <= biten[0]  ? wdata[0]  : TsActive;
				TsCount  <= biten[1]  ? wdata[1]  : TsCount;
				TsReset  <= biten[2]  ? wdata[2]  : TsReset;
				TsEnable <= biten[15] ? wdata[15] : TsEnable;
				if (cfg_wr_en) begin
					TsType     <= (TsType     & ~biten[6:4]) | (wdata[6:4] & biten[6:4]);
					TsPrescale <= (TsPrescale & ~biten[9:8]) | (wdata[9:8] & biten[9:8]);
				end
			end

			// trTeTipFifoStatus @0xe04 (clear bits always writable -- they are
			// deliberately NOT in the RDL swwel list)
			if (wr && sel_fifostatus) begin
				MaxFillClear      <= biten[15] ? wdata[15] : MaxFillClear;
				NumOverflowsClear <= biten[31] ? wdata[31] : NumOverflowsClear;
			end

			// trAtbBridgeControl @0x1000 / trAtbBridgeImpl @0x1004
			if (wr && sel_atbctrl && cfg_wr_en)
				AtbId <= (AtbId & ~biten[14:8]) | (wdata[14:8] & biten[14:8]);
			if (wr && sel_atbimpl && cfg_wr_en)
				AtbAsyncFreq <= (AtbAsyncFreq & ~biten[14:12]) | (wdata[14:12] & biten[14:12]);

			// trTeCsrControl: follow hw every cycle (1-FF delay as generated)
			CsrSendSync <= hwif_in.te.trTeCsrControl.trTeCsrSendSync.next;
			CsrSendPC   <= hwif_in.te.trTeCsrControl.trTeCsrSendPC.next;
			CsrSendTS   <= hwif_in.te.trTeCsrControl.trTeCsrSendTS.next;
			CsrSendCC   <= hwif_in.te.trTeCsrControl.trTeCsrSendCC.next;
		end
	end

	// ----------------------------------------------------------------
	// Readback (single always_comb case; unmapped addresses read 0 --
	// identical to the generated slim block's constant folding)
	// ----------------------------------------------------------------
	always_comb begin
		s_cpuif_rd_data = '0;
		case (addr)
			15'h0: begin
				s_cpuif_rd_data[0]     = Active;
				s_cpuif_rd_data[1]     = Enable;
				s_cpuif_rd_data[2]     = InstTracing;
				s_cpuif_rd_data[3]     = hwif_in.te.trTeControl.Empty.next;
				s_cpuif_rd_data[6:4]   = InstMode;
				s_cpuif_rd_data[12]    = InstStallOvf;               // P7/G12
				s_cpuif_rd_data[15]    = InhibitSrc;
				s_cpuif_rd_data[19:16] = InstSyncMode;
				s_cpuif_rd_data[23:20] = InstSyncMax;
				s_cpuif_rd_data[26:24] = 3'h1;                       // Format
			end
			15'h4: begin                                             // trTeImpl
				s_cpuif_rd_data[3:0]   = 4'h1;
				s_cpuif_rd_data[11:8]  = 4'h1;
				// Protocol discovery is hardware-driven (P9): the back end is
				// a synthesis parameter of the enclosing encoder instance.
				s_cpuif_rd_data[19:16] = hwif_in.te.trTeImpl.ProtocolMajor.next;
			end
			15'h30:                                                  // trTeProtocolSel
				s_cpuif_rd_data[0]     = hwif_in.te.trTeProtocolSel.Protocol.next;
			15'h8: begin                                             // trTeInstFeatures
				s_cpuif_rd_data[27:16] = SrcID;
				s_cpuif_rd_data[31:28] = SrcBits;
			end
			15'h10: begin                                            // trTeDataControl
				s_cpuif_rd_data[20]    = hwif_in.te.trTeDataControl.DataSplitLoad.next;
			end
			15'h40: begin                                            // trTsControl
				s_cpuif_rd_data[0]     = TsActive;
				s_cpuif_rd_data[1]     = TsCount;
				s_cpuif_rd_data[2]     = TsReset;
				s_cpuif_rd_data[6:4]   = TsType;
				s_cpuif_rd_data[9:8]   = TsPrescale;
				s_cpuif_rd_data[15]    = TsEnable;
				s_cpuif_rd_data[29:24] = ct_pkg::CT_EN_TIMESTAMP ? 6'h3f : 6'h0; // Width
			end
			15'h48:  s_cpuif_rd_data       = hwif_in.te.trTsCounterLow.Value.next;
			15'h4c:  s_cpuif_rd_data       = hwif_in.te.trTsCounterHigh.Value.next;
			15'he00: begin                                           // trTeCsrControl
				s_cpuif_rd_data[0] = CsrSendSync;
				s_cpuif_rd_data[1] = CsrSendPC;
				s_cpuif_rd_data[2] = CsrSendTS;
				s_cpuif_rd_data[3] = CsrSendCC;
			end
			15'he04: begin                                           // trTeTipFifoStatus
				s_cpuif_rd_data[14:0]  = hwif_in.te.trTeTipFifoStatus.trTeTipFifoMaxFill.next;
				s_cpuif_rd_data[15]    = MaxFillClear;
				s_cpuif_rd_data[30:16] = hwif_in.te.trTeTipFifoStatus.trTeTipFifoNumOverflows.next;
				s_cpuif_rd_data[31]    = NumOverflowsClear;
			end
			15'he08: begin                                           // trTeSyncStatus
				// THREE bits since P8 (SYNC_REQ_TE = 4 joined none/CSR/ATB/
				// quota). A [1:0] slice here read the new source back as 0 --
				// "nobody ever asked" -- and D-P8-2 made this read-back the
				// ONLY software discovery the feature has. Kept honest
				// mechanically by scripts/check_micro_csr_twin.py.
				s_cpuif_rd_data[2:0]   = hwif_in.te.trTeSyncStatus.SyncReqSource.next;
			end
			15'h1000: begin                                          // trAtbBridgeControl
				s_cpuif_rd_data[0]    = 1'b1;
				s_cpuif_rd_data[1]    = 1'b1;
				s_cpuif_rd_data[3]    = hwif_in.atb.trAtbBridgeControl.Empty.next;
				s_cpuif_rd_data[14:8] = AtbId;
			end
			15'h1004: begin                                          // trAtbBridgeImpl
				s_cpuif_rd_data[3:0]   = 4'h1;
				s_cpuif_rd_data[11:8]  = 4'he;
				s_cpuif_rd_data[14:12] = AtbAsyncFreq;
			end
			15'h3000: s_cpuif_rd_data[0] = 1'b1;                     // trPcControl.Active
			15'h3004: begin                                          // trPcImpl
				s_cpuif_rd_data[3:0]  = 4'h1;
				s_cpuif_rd_data[11:8] = 4'h3;
			end
			15'h3008: begin                                          // trTeConstants
				s_cpuif_rd_data[4:0]   = 5'h10;
				s_cpuif_rd_data[8:5]   = 4'h8;
				s_cpuif_rd_data[12:9]  = 4'h3;
				s_cpuif_rd_data[16:13] = 4'h3;
				s_cpuif_rd_data[20:17] = 4'h7;
				s_cpuif_rd_data[24:21] = 4'h7;
			end
			15'h3010: begin                                          // trPerfCntControl
				s_cpuif_rd_data[7:0]  = 8'h4;
				s_cpuif_rd_data[15:8] = 8'h4;
			end
			15'h4000: s_cpuif_rd_data[0] = 1'b1;                     // trWpControl.Active
			15'h4004: begin                                          // trWpImpl
				s_cpuif_rd_data[3:0]  = 4'h1;
				s_cpuif_rd_data[11:8] = 4'h4;
			end
			15'h5000: s_cpuif_rd_data[0] = 1'b1;                     // trDfControl.Active
			15'h5004: begin                                          // trDfImpl
				s_cpuif_rd_data[3:0]  = 4'h1;
				s_cpuif_rd_data[11:8] = 4'h5;
			end
			default: ;                                               // reads 0
		endcase
	end

	// Combinational single-cycle response, no stalls, no errors (the
	// generated block only stalled on the external windows, absent here).
	assign s_cpuif_req_stall_wr = 1'b0;
	assign s_cpuif_req_stall_rd = 1'b0;
	assign s_cpuif_rd_ack = req & ~s_cpuif_req_is_wr;
	assign s_cpuif_wr_ack = wr;
	assign s_cpuif_rd_err = 1'b0;
	assign s_cpuif_wr_err = 1'b0;

	// ----------------------------------------------------------------
	// hwif_out: live values + the slim profile's constants. Only members
	// the wrapper consumes (grep-verified list, 2026-07-19) plus the
	// readback-only storages above are driven; gated groups carry their
	// reset-0 constants exactly like the generated slim block.
	// ----------------------------------------------------------------
	always_comb begin
		// te.trTeControl
		hwif_out.te.trTeControl.Active.value       = Active;
		hwif_out.te.trTeControl.Enable.value       = Enable;
		hwif_out.te.trTeControl.InstTracing.value  = InstTracing;
		hwif_out.te.trTeControl.InstMode.value     = InstMode;
		hwif_out.te.trTeControl.SendConfig.value   = 2'h0;
		hwif_out.te.trTeControl.SendDeviceId.value = 2'h0;   // P4: DID_NONE (slim profile)
		hwif_out.te.trTeControl.Context.value      = 1'h0;
		hwif_out.te.trTeControl.InhibitSrc.value   = InhibitSrc;
		hwif_out.te.trTeControl.InstSyncMode.value = InstSyncMode;
		hwif_out.te.trTeControl.InstSyncMax.value  = InstSyncMax;
		hwif_out.te.trTeControl.Format.value       = 3'h1;
		hwif_out.te.trTeControl.InstSyncReq.value  = InstSyncReq;
		hwif_out.te.trTeControl.InstStallOrOverflow.value = InstStallOvf;
		// te.trTeImpl (discovery constants)
		hwif_out.te.trTeImpl.VerMajor.value      = 4'h1;
		hwif_out.te.trTeImpl.VerMinor.value      = 4'h0;
		hwif_out.te.trTeImpl.CompType.value      = 4'h1;
		// ProtocolMajor / trTeProtocolSel.Protocol are sw=r/hw=w since P9 --
		// they have no hwif_out member, the readback above uses hwif_in.
		hwif_out.te.trTeImpl.ProtocolMinor.value = 4'h0;
		// te.trTeInstFeatures
		hwif_out.te.trTeInstFeatures.InstEnImplicitReturn.value   = 1'h0;
		hwif_out.te.trTeInstFeatures.InstEnBranchPrediction.value = 1'h0;
		hwif_out.te.trTeInstFeatures.InstEnJumpTargetCache.value  = 1'h0;
		hwif_out.te.trTeInstFeatures.InstEnRepeatedHistory.value  = 1'h0;
		hwif_out.te.trTeInstFeatures.InstEnRepeatBranch.value     = 1'h0;
		hwif_out.te.trTeInstFeatures.InstEnWideIcnt.value         = 1'h0;
		hwif_out.te.trTeInstFeatures.SrcID.value                  = SrcID;
		hwif_out.te.trTeInstFeatures.SrcBits.value                = SrcBits;
		// te filters/data (gated groups: reset-0 constants)
		hwif_out.te.trTeInstFilters.Filters.value          = 16'h0;
		hwif_out.te.trTeDataControl.DataImplemented.value  = 1'h0;
		hwif_out.te.trTeDataControl.DataTracing.value      = 1'h0;
		hwif_out.te.trTeDataControl.DataAddrCompress.value = 2'h0;
		hwif_out.te.trTeDataControl.DataStallOrOverflow.value = 1'h0; // P7: no data trace here
		hwif_out.te.trTeDataControl.DataDrop.value            = 1'h0;
		hwif_out.te.trTeDataControl.DataDropEna.value         = 1'h0;
		hwif_out.te.trTeDataFilters.Filters.value          = 16'h0;
		// P7 trigger configuration block: not decoded here (elaboration guard
		// above rejects CT_EN_TRIG_REGS), so the consumers see the reset
		// constants -- action 0 = "no action", no trigger output events.
		hwif_out.te.trTeTrigDbgControl.TrigDbgSetup.value      = 32'h0;
		hwif_out.te.trTeTrigExtInControl.ExtInAction0.value    = 4'h0;
		hwif_out.te.trTeTrigExtInControl.ExtInActionN.value    = 28'h0;
		hwif_out.te.trTeTrigExtOutControl.ExtOutEvent0.value   = 4'h0;
		hwif_out.te.trTeTrigExtOutControl.ExtOutEventN.value   = 28'h0;
		// te.trTsControl
		hwif_out.te.trTsControl.Active.value   = TsActive;
		hwif_out.te.trTsControl.Count.value    = TsCount;
		hwif_out.te.trTsControl.Reset.value    = TsReset;
		hwif_out.te.trTsControl.Type.value     = TsType;
		hwif_out.te.trTsControl.Prescale.value = TsPrescale;
		hwif_out.te.trTsControl.Enable.value   = TsEnable;
		hwif_out.te.trTsControl.Width.value    = ct_pkg::CT_EN_TIMESTAMP ? 6'h3f : 6'h0;
		// te.trTeCsrControl (readback-only mirrors)
		hwif_out.te.trTeCsrControl.trTeCsrSendSync.value = CsrSendSync;
		hwif_out.te.trTeCsrControl.trTeCsrSendPC.value   = CsrSendPC;
		hwif_out.te.trTeCsrControl.trTeCsrSendTS.value   = CsrSendTS;
		hwif_out.te.trTeCsrControl.trTeCsrSendCC.value   = CsrSendCC;
		// te.trTeTipFifoStatus
		hwif_out.te.trTeTipFifoStatus.trTeTipFifoMaxFillClear.value      = MaxFillClear;
		hwif_out.te.trTeTipFifoStatus.trTeTipFifoNumOverflowsClear.value = NumOverflowsClear;
		// te.trTeFilter / te.trTeComp arrays (gated: reset-0 constants)
		for (int i = 0; i < 16; i++) begin
			hwif_out.te.trTeFilter[i].Control.Enable.value         = 1'h0;
			hwif_out.te.trTeFilter[i].Control.MatchPrivilege.value = 1'h0;
			hwif_out.te.trTeFilter[i].Control.MatchEcause.value    = 1'h0;
			hwif_out.te.trTeFilter[i].Control.MatchInterrupt.value = 1'h0;
			hwif_out.te.trTeFilter[i].Control.MatchComp1.value     = 1'h0;
			hwif_out.te.trTeFilter[i].Control.Comp1.value          = 3'h0;
			hwif_out.te.trTeFilter[i].Control.MatchComp2.value     = 1'h0;
			hwif_out.te.trTeFilter[i].Control.Comp2.value          = 3'h0;
			hwif_out.te.trTeFilter[i].Control.MatchComp3.value     = 1'h0;
			hwif_out.te.trTeFilter[i].Control.Comp3.value          = 3'h0;
			hwif_out.te.trTeFilter[i].Control.Impdef.value         = 1'h0;
			hwif_out.te.trTeFilter[i].Control.Dtype.value          = 1'h0;
			hwif_out.te.trTeFilter[i].Control.Dsize.value          = 1'h0;
			hwif_out.te.trTeFilter[i].Match.ChoicePrivilege.value  = '0;
			hwif_out.te.trTeFilter[i].Match.ValueInterrupt.value   = '0;
			hwif_out.te.trTeFilter[i].MatchChoiceEcauseLow.Value.value  = '0;
			hwif_out.te.trTeFilter[i].MatchChoiceEcauseHigh.Value.value = '0;
			hwif_out.te.trTeFilter[i].MatchValueImpdef.Value.value      = '0;
			hwif_out.te.trTeFilter[i].MatchMaskImpdef.Value.value       = '0;
			hwif_out.te.trTeFilter[i].MatchChoiceData.Dtype.value       = '0;
			hwif_out.te.trTeFilter[i].MatchChoiceData.Dsize.value       = '0;
		end
		for (int i = 0; i < 8; i++) begin
			hwif_out.te.trTeComp[i].Control.PInput.value    = '0;
			hwif_out.te.trTeComp[i].Control.SInput.value    = '0;
			hwif_out.te.trTeComp[i].Control.PFunction.value = '0;
			hwif_out.te.trTeComp[i].Control.SFunction.value = '0;
			hwif_out.te.trTeComp[i].Control.MatchMode.value = '0;
			hwif_out.te.trTeComp[i].Control.PNotify.value   = '0;
			hwif_out.te.trTeComp[i].Control.SNotify.value   = '0;
			hwif_out.te.trTeComp[i].PMatchLow.Value.value   = '0;
			hwif_out.te.trTeComp[i].PMatchHigh.Value.value  = '0;
			hwif_out.te.trTeComp[i].SMatchLow.Value.value   = '0;
			hwif_out.te.trTeComp[i].SMatchHigh.Value.value  = '0;
		end
		// atb
		hwif_out.atb.trAtbBridgeControl.Active.value = 1'h1;
		hwif_out.atb.trAtbBridgeControl.Enable.value = 1'h1;
		hwif_out.atb.trAtbBridgeControl.ID.value     = AtbId;
		hwif_out.atb.trAtbBridgeImpl.VerMajor.value  = 4'h1;
		hwif_out.atb.trAtbBridgeImpl.VerMinor.value  = 4'h0;
		hwif_out.atb.trAtbBridgeImpl.CompType.value  = 4'he;
		hwif_out.atb.trAtbBridgeImpl.AsyncFreq.value = AtbAsyncFreq;
		// pc (constants; perfcnt ranges gated -> 0)
		hwif_out.pc.trPcControl.Active.value  = 1'h1;
		hwif_out.pc.trPcImpl.VerMajor.value   = 4'h1;
		hwif_out.pc.trPcImpl.VerMinor.value   = 4'h0;
		hwif_out.pc.trPcImpl.CompType.value   = 4'h3;
		hwif_out.pc.trTeConstants.num_trace_filter.value             = 5'h10;
		hwif_out.pc.trTeConstants.num_trace_comparators.value        = 4'h8;
		hwif_out.pc.trTeConstants.num_perfcnt_ifetch_th_ranges.value = 4'h3;
		hwif_out.pc.trTeConstants.num_perfcnt_data_rd_th_ranges.value= 4'h3;
		hwif_out.pc.trTeConstants.num_perfcnt_data_rd_ranges.value   = 4'h7;
		hwif_out.pc.trTeConstants.num_perfcnt_data_wr_ranges.value   = 4'h7;
		hwif_out.pc.trPerfCntControl.IFetchThreshold.value = 8'h4;
		hwif_out.pc.trPerfCntControl.DataWrThreshold.value = 8'h4;
		for (int i = 0; i < 3; i++) begin
			hwif_out.pc.trTePerfCntIFetchRange[i].Low.Value.value    = '0;
			hwif_out.pc.trTePerfCntIFetchRange[i].High.Value.value   = '0;
			hwif_out.pc.trTePerfCntDataRdThRange[i].Low.Value.value  = '0;
			hwif_out.pc.trTePerfCntDataRdThRange[i].High.Value.value = '0;
		end
		for (int i = 0; i < 7; i++) begin
			hwif_out.pc.trTePerfCntDataRdRange[i].Low.Value.value  = '0;
			hwif_out.pc.trTePerfCntDataRdRange[i].High.Value.value = '0;
			hwif_out.pc.trTePerfCntDataWrRange[i].Low.Value.value  = '0;
			hwif_out.pc.trTePerfCntDataWrRange[i].High.Value.value = '0;
		end
		// wp / df discovery
		hwif_out.trWpControl.Active.value  = 1'h1;
		hwif_out.trWpImpl.VerMajor.value   = 4'h1;
		hwif_out.trWpImpl.VerMinor.value   = 4'h0;
		hwif_out.trWpImpl.CompType.value   = 4'h4;
		// Watchpoint message mask (P4): the micro CSR serves CF-only slim
		// profiles, where CT_EN_ACT (and with it CT_EN_WATCHPOINT_MSG) is 0
		// by its own elaboration guard -- the mask is a read-0 constant,
		// exactly like the other gated groups above.
		hwif_out.trWpMask.WEM.value        = 16'h0;
		hwif_out.trDfControl.Active.value  = 1'h1;
		hwif_out.trDfImpl.VerMajor.value   = 4'h1;
		hwif_out.trDfImpl.VerMinor.value   = 4'h0;
		hwif_out.trDfImpl.CompType.value   = 4'h5;
		// Indirect watchpoint load path (C0b): no ACT blocks in this
		// profile -- index/staging are read-0 constants, the commit strobe
		// and the serial-readback strobe never pulse, and the capacity
		// honestly reads 0 (same discovery pattern as trTsControl.Width).
		hwif_out.trWpIndex.Idx.value            = 16'h0;
		hwif_out.trWpDataLow.Value.value        = 32'h0;
		hwif_out.trWpDataHigh.Cmd.value         = 6'h0;
		hwif_out.trWpDataHigh.Cmd.swmod         = 1'b0;
		hwif_out.trWpDataHigh.Sink.value        = 2'h0;
		hwif_out.trWpDataHigh.DirectData.value  = 24'h0;
		hwif_out.trWpReadHigh.Cmd.swacc         = 1'b0;
		hwif_out.trWpCap.Entries.value          = 16'h0;
		hwif_out.mem1.req       = 1'b0;
		hwif_out.mem1.addr      = '0;
		hwif_out.mem1.req_is_wr = 1'b0;
		hwif_out.mem1.wr_data   = '0;
		hwif_out.mem1.wr_biten  = '0;
	end

endmodule // ct_cs_micro

`default_nettype wire
