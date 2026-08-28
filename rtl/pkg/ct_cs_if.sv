// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder Control & Status Interface for individual clk domains
 */

import ct_pkg::*;
import ct_cs_cpuif_pkg::*;
import tip_pkg::*;

interface ct_cs_tipclk_if ();

	logic trTeActive;         // trTeControl.trTeActive
	logic trTeEnable;         // trTeControl.trTeEnable
	logic trTeInstTracing;    // trTeControl.trTeInstTracing
	logic trTeInstTracingSet; // trTeControl.trTeInstTracing override by ACT-CAP
	logic trTeInstTracingClr; // trTeControl.trTeInstTracing override by ACT-CAP

	ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e trTeInstMode; // trTeControl.trTeInstMode
	ct_cs_cpuif__te__trTeControl__trTeSendConfigMode_e_e trTeSendConfig; // trTeControl.SendConfig (CFG_NONE/ONCE/ON_SYNC, C2)
	ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e_e trTeSendDeviceId; // trTeControl.SendDeviceId (DID_NONE/DID_ONCE, P4)
	logic [15:0] trWpWEM; // trWpMask.WEM (watchpoint slot enable mask, P4)
	logic trTeContext;    // trTeControl.trTeContext

	ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e trTeInstSyncMode;
	tip_isync_max_t   trTeInstSyncMax; // trTeControl.trTeInstSyncMax
	ct_trace_filter_t trTeInstFilters; // trTeInstFiltersReg.Filters
	logic trTeInstEnWideIcnt; // trTeInstFeatures.InstEnWideIcnt (16-bit internal ICNT cap, composer drain threshold)
	logic trTeInstEnBranchPrediction; // trTeInstFeatures.InstEnBranchPrediction (defers the sync anchor off branch retires, see ct_L23_preproc_sync)
	logic trTeInstTrigEnable;    // trTeControl.InstTrigEnable (tip.trigger -> SYNC=6 marker)
	logic trTeInstSeqSyncEnable; // trTeControl.InstSeqSyncEnable (SYNC=4 instead of RCODE-0 pre-drain)

	// External trigger input #0 action (P7, trTeTrigExtInControl.ExtInAction0
	// @te:0x054, TCI Table 20): 0 = no action, 2 = trace-on, 3 = trace-off,
	// 4 = trace-notify (the SYNC=6 marker). Constant 0 without CT_EN_TRIG_REGS.
	logic [3:0] trTeTrigExtInAction0;
	// Trigger-driven trace on/off (P7): tip-clk strobes from the external
	// trigger input's action 2/3, OR-ed into the InstTracing hwset/hwclr path
	// next to the ACT-CAP overrides. Constant 0 without CT_EN_TRIG_REGS.
	logic trTeTrigTracingSet;
	logic trTeTrigTracingClr;

	logic trTeDataTracing;    // trTeDataControl.trTeDataTracing
	logic trTeDataTracingSet; // trTeDataControl.trTeDataTracing override by ACT-CAP
	logic trTeDataTracingClr; // trTeDataControl.trTeDataTracing override by ACT-CAP
	logic trTeDataDropEna;    // trTeDataControl.DataDropEna (P7, DF watermark drop policy)

	ct_trace_filter_t trTeDataFilters; // trTeDataFiltersReg.trTeDataFilters

	logic trTsActive; // trTsControl.trTsActive
	logic trTsCount;  // trTsControl.trTsCount
	logic trTsReset;  // trTsControl.trTsReset

	ct_cs_cpuif__te__trTsControl__trTsType_e_e trTsType;

	logic [1:0] trTsPrescale; // trTsControl.trTsPrescale
	logic       trTsEnable;   // trTsControl.trTsEnable

	// Trace Filters
	ct_trace_filter_t trTeFilterEnable;         // trTeFilter.Control.Enable
	ct_trace_filter_t trTeFilterMatchPrivilege; // trTeFilter.Control.MatchPrivilege
	ct_trace_filter_t trTeFilterMatchEcause;    // trTeFilter.Control.MatchEcause
	ct_trace_filter_t trTeFilterMatchInterrupt; // trTeFilter.Control.MatchInterrupt
	ct_trace_filter_match_comp_t [NUM_TRACE_FILTER-1:0] trTeFilterMatchComp; // trTeFilter.Control.MatchComp1..3
	ct_trace_filter_comp_t       [NUM_TRACE_FILTER-1:0] trTeFilterComp;      // trTeFilter.Control.Comp1..3
	ct_trace_filter_t trTeFilterMatchImpdef; // trTeFilter.Control.MatchImpdef
	ct_trace_filter_t trTeFilterMatchDtype;  // trTeFilter.Control.MatchDtype
	ct_trace_filter_t trTeFilterMatchDsize;  // trTeFilter.Control.MatchDsize
	tip_priv_t [NUM_TRACE_FILTER-1:0] trTeFilterMatchChoicePrivilege; // trTeFilter.Match.ChoicePrivilege
	ct_cs_cpuif__te__trTeFilter__Match__trTeFilterMatchInstExInt_e_e [NUM_TRACE_FILTER-1:0] trTeFilterMatchValueInterrupt; // trTeFilter.Match.ValueInterrupt
	// One CSR register each (32 bit); the RTL joins them into a
	// tip_ecause_vector_t. Typed as the register, not as the joined vector,
	// so the interface cannot silently zero-extend one half over the other.
	ct_trace_match_t [NUM_TRACE_FILTER-1:0] trTeFilterMatchChoiceEcauseLow;  // trTeFilter.MatchEcauseLow.Value
	ct_trace_match_t [NUM_TRACE_FILTER-1:0] trTeFilterMatchChoiceEcauseHigh; // trTeFilter.MatchEcauseHigh.Value
	tip_impdef_t [NUM_TRACE_FILTER-1:0] trTeFilterMatchValueImpdef; // trTeFilter.MatchValueImpdef.Value
	tip_impdef_t [NUM_TRACE_FILTER-1:0] trTeFilterMatchMaskImpdef;  // trTeFilter.MatchMaskImpdef.Value
	tip_dtype_t  [NUM_TRACE_FILTER-1:0] trTeFilterMatchChoiceDtype; // trTeFilter.MatchChoiceData.Dtype
	tip_dsize_t  [NUM_TRACE_FILTER-1:0] trTeFilterMatchChoiceDsize; // trTeFilter.MatchChoiceData.Dsize

	// Trace Comparators
	ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e_e     [NUM_TRACE_COMPARATORS-1:0] trTeCompPInput;    // trTeCompControl.trTeCompPInput
	ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e_e     [NUM_TRACE_COMPARATORS-1:0] trTeCompSInput;    // trTeCompControl.trTeCompSInput
	ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e_e [NUM_TRACE_COMPARATORS-1:0] trTeCompPFunction; // trTeCompControl.trTeCompPFunction
	ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e_e [NUM_TRACE_COMPARATORS-1:0] trTeCompSFunction; // trTeCompControl.trTeCompSFunction
	ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e_e [NUM_TRACE_COMPARATORS-1:0] trTeCompMatchMode; // trTeCompControl.trTeCompMatchMode
	ct_trace_comp_t trTeCompPNotify; // trTeCompControl.PNotify
	ct_trace_comp_t trTeCompSNotify; // trTeCompControl.SNotify
	ct_trace_match_t [NUM_TRACE_COMPARATORS-1:0] trTeCompPMatchLow;  // trTeCompPMatchLow.Value
	ct_trace_match_t [NUM_TRACE_COMPARATORS-1:0] trTeCompPMatchHigh; // trTeCompPMatchHigh.Value
	ct_trace_match_t [NUM_TRACE_COMPARATORS-1:0] trTeCompSMatchLow;  // trTeCompSMatchLow.Value
	ct_trace_match_t [NUM_TRACE_COMPARATORS-1:0] trTeCompSMatchHigh; // trTeCompSMatchHigh.Value
	ct_trace_match_t [NUM_TRACE_COMPARATORS-1:0] trTeCompSMaskLow;   // trTeCompSMaskLow.Value  (PMASK mode)
	ct_trace_match_t [NUM_TRACE_COMPARATORS-1:0] trTeCompSMaskHigh;  // trTeCompSMaskHigh.Value (PMASK mode)

	// Trace Source config (TIP generator, TIP player, CPUs)
	logic trCPU0Reset;    // trSrcControl0.trCPU0Reset
	logic trCPU1Reset;    // trSrcControl0.trCPU1Reset
	logic trCPU2Reset;    // trSrcControl0.trCPU2Reset
	logic trCPU3Reset;    // trSrcControl0.trCPU3Reset
	logic trTipGenReset;  // trSrcControl0.trTipGenReset
	logic trTipPlayReset; // trSrcControl0.trTipPlayReset

	logic [63:0] trTeTs; // timestamp counter

	logic [31:0] trTeActStWaAddress [31:0]; // smart trigger addresses
	logic [31:0] trTeActStWcData    [31:0]; // control register values for respective smart trigger addresses

	ct_perfcnt_th_t trPcIFetchThreshold; // trPerfCntControl.IFetchThreshold
	ct_perfcnt_th_t trPcDataRdThreshold; // trPerfCntControl.DataWrThreshold

	tip_iaddr_t [NUM_PERFCNT_IFETCH_TH_RANGES-1:0]  trTePerfCntIFetchRangeLow;
	tip_iaddr_t [NUM_PERFCNT_IFETCH_TH_RANGES-1:0]  trTePerfCntIFetchRangeHigh;
	tip_daddr_t [NUM_PERFCNT_DATA_RD_TH_RANGES-1:0] trTePerfCntDataRdThRangeLow;
	tip_daddr_t [NUM_PERFCNT_DATA_RD_TH_RANGES-1:0] trTePerfCntDataRdThRangeHigh;
	tip_daddr_t [NUM_PERFCNT_DATA_RD_RANGES-1:0]    trTePerfCntDataRdRangeLow;
	tip_daddr_t [NUM_PERFCNT_DATA_RD_RANGES-1:0]    trTePerfCntDataRdRangeHigh;
	tip_daddr_t [NUM_PERFCNT_DATA_WR_RANGES-1:0]    trTePerfCntDataWrRangeLow;
	tip_daddr_t [NUM_PERFCNT_DATA_WR_RANGES-1:0]    trTePerfCntDataWrRangeHigh;

	// TIP FIFO status (trTeTipFifoStatus @ 0x1400)
	logic [14:0] trTeTipFifoMaxFill;           // status : tip-clk -> wb
	logic        trTeTipFifoMaxFillClear;      // control: wb -> tip-clk (level)
	logic [14:0] trTeTipFifoNumOverflows;      // status : tip-clk -> wb
	logic        trTeTipFifoNumOverflowsClear; // control: wb -> tip-clk (level)

	// eTIP FIFO fill histogram (trTeTipFifoHist* @ te:0xE10, I-02):
	// CT_FIFO_HIST_BINS saturating upward-crossing counters, tip_clk domain.
	// Deliberately NO CDC on either direction -- read/clear contract: trace
	// quiescent only (trTeControl.Enable=0). Tied 0 / unused when
	// CT_EN_FIFO_HIST=0.
	logic [CT_FIFO_HIST_BINS-1:0][15:0] trTeTipFifoHist;      // status : tip-clk -> wb (no CDC)
	logic                               trTeTipFifoHistClear; // control: wb -> tip-clk (level, no CDC)

	// Explicit-sync-request source (trTeSyncStatus.SyncReqSource, RO diag):
	// 0 none since reset, 1 ACT-CAP CF_SYNC (the hart), 2 ATB, 3 trace quota,
	// 4 trTeControl.InstSyncReq (the control bus, P8). On-wire all explicit
	// requests share the single vendor SYNC code 14.
	logic [2:0]  trTeSyncReqSource;            // status : tip-clk -> wb

	// Explicit sync request over the TE register (P8, trTeControl.InstSyncReq).
	// The two phases of a four-phase LEVEL handshake, paced by
	// ct_sync_req_pacer: the request goes up for one request at a time and is
	// withdrawn only after the acknowledgement has been seen, so two requests
	// are always a full round trip apart and neither crossing can swallow one.
	// A write arriving while a request is outstanding is remembered and raised
	// afterwards as its OWN request, so it gets its own sync message; only a
	// write on top of an already queued one collapses.
	// LEVELS and not strobes on purpose (P8 closing audit B-N1): these two
	// signals live in domains with INDEPENDENT resets, and a strobe that a
	// one-sided reset destroys is gone for good, while `request up, not
	// acknowledged` still means "one is owed" whichever side was reset. The
	// same property makes the ATB request path (signal_ack_lock_fsm) immune.
	// Both are constant 0 with CT_EN_INST_SYNC_REQ = 0.
	logic        trTeInstSyncReq;              // control: wb -> tip-clk (level, one request owed)
	logic        trTeInstSyncReqAck;           // status : tip-clk -> wb (level, that request served)

	// Sticky status sources (P7/G12, N-Trace Required trTeInstStallOrOverflow
	// + its data-trace twin): ONE-CYCLE tip-clk strobes, crossed into wb_clk
	// as strobes and applied as `hwset` to the RW1C status bits. A strobe (not
	// a level) is what makes the RW1C contract work -- software clears the bit
	// and it stays clear until the NEXT event.
	//   trTeInstOverflowEvent : the eTIP drop path generated an overflow
	//                           ERROR message (messages were lost).
	//   trTeDataDropEvent     : the DataDropEna policy dropped data-trace
	//                           messages (one strobe per drop episode).
	logic        trTeInstOverflowEvent;        // status : tip-clk -> wb (strobe)
	logic        trTeDataDropEvent;            // status : tip-clk -> wb (strobe)

	modport master (
		input   trTeInstTracingSet, trTeInstTracingClr,
				trTeTrigTracingSet, trTeTrigTracingClr,
				trTeDataTracingSet, trTeDataTracingClr,
				trTeTs,
				trTeTipFifoMaxFill, trTeTipFifoNumOverflows,
				trTeTipFifoHist,
				trTeSyncReqSource,
				trTeInstOverflowEvent, trTeDataDropEvent, trTeInstSyncReqAck,
		output  trTeActive, trTeEnable, trTeInstMode, trTeSendConfig, trTeSendDeviceId, trWpWEM, trTeContext, trTeInstSyncMode, trTeInstSyncMax, trTeInstSyncReq,
				trTeTrigExtInAction0, trTeDataDropEna,
				trTeInstFilters, trTeInstEnWideIcnt, trTeInstEnBranchPrediction, trTeInstTrigEnable, trTeInstSeqSyncEnable, trTeDataFilters,
				trTsActive, trTsCount, trTsReset, trTsType, trTsPrescale, trTsEnable,
				trTeFilterEnable, trTeFilterMatchPrivilege, trTeFilterMatchEcause, trTeFilterMatchInterrupt, trTeFilterMatchComp, trTeFilterComp,
				trTeFilterMatchImpdef, trTeFilterMatchDtype, trTeFilterMatchDsize,
				trTeFilterMatchChoicePrivilege, trTeFilterMatchValueInterrupt, trTeFilterMatchChoiceEcauseLow, trTeFilterMatchChoiceEcauseHigh, trTeFilterMatchValueImpdef,
				trTeFilterMatchMaskImpdef, trTeFilterMatchChoiceDtype, trTeFilterMatchChoiceDsize,
				trTeCompPInput, trTeCompSInput, trTeCompPFunction, trTeCompSFunction, trTeCompMatchMode, trTeCompPNotify,
				trTeCompSNotify, trTeCompPMatchLow, trTeCompPMatchHigh, trTeCompSMatchLow, trTeCompSMatchHigh,
				trTeCompSMaskLow, trTeCompSMaskHigh,
				trCPU0Reset, trCPU1Reset, trCPU2Reset, trCPU3Reset, trTipGenReset, trTipPlayReset,
				trTeActStWaAddress, trTeActStWcData,
				trPcIFetchThreshold, trPcDataRdThreshold,
				trTePerfCntIFetchRangeLow,  trTePerfCntDataRdThRangeLow,  trTePerfCntDataRdRangeLow,  trTePerfCntDataWrRangeLow,
				trTePerfCntIFetchRangeHigh, trTePerfCntDataRdThRangeHigh, trTePerfCntDataRdRangeHigh, trTePerfCntDataWrRangeHigh,
				trTeInstTracing, trTeDataTracing,
				trTeTipFifoMaxFillClear, trTeTipFifoNumOverflowsClear, trTeTipFifoHistClear
	);

	modport slave (
		output  trTeInstTracingSet, trTeInstTracingClr,
				trTeTrigTracingSet, trTeTrigTracingClr,
				trTeDataTracingSet, trTeDataTracingClr,
				trTeTs,
				trTeTipFifoMaxFill,
				trTeTipFifoNumOverflows,
				trTeTipFifoHist,
				trTeSyncReqSource,
				trTeInstOverflowEvent, trTeDataDropEvent, trTeInstSyncReqAck,
		input   trTeActive, trTeEnable, trTeInstMode, trTeSendConfig, trTeSendDeviceId, trWpWEM, trTeContext, trTeInstSyncMode, trTeInstSyncMax, trTeInstSyncReq,
				trTeTrigExtInAction0, trTeDataDropEna,
				trTeInstFilters, trTeInstEnWideIcnt, trTeInstEnBranchPrediction, trTeInstTrigEnable, trTeInstSeqSyncEnable, trTeDataFilters,
				trTsActive, trTsCount, trTsReset, trTsType, trTsPrescale, trTsEnable,
				trTeFilterEnable, trTeFilterMatchPrivilege, trTeFilterMatchEcause, trTeFilterMatchInterrupt, trTeFilterMatchComp, trTeFilterComp,
				trTeFilterMatchImpdef, trTeFilterMatchDtype, trTeFilterMatchDsize,
				trTeFilterMatchChoicePrivilege, trTeFilterMatchValueInterrupt, trTeFilterMatchChoiceEcauseLow, trTeFilterMatchChoiceEcauseHigh, trTeFilterMatchValueImpdef,
				trTeFilterMatchMaskImpdef, trTeFilterMatchChoiceDtype, trTeFilterMatchChoiceDsize,
				trTeCompPInput, trTeCompSInput, trTeCompPFunction, trTeCompSFunction, trTeCompMatchMode, trTeCompPNotify,
				trTeCompSNotify, trTeCompPMatchLow, trTeCompPMatchHigh, trTeCompSMatchLow, trTeCompSMatchHigh,
				trTeCompSMaskLow, trTeCompSMaskHigh,
				trCPU0Reset, trCPU1Reset, trCPU2Reset, trCPU3Reset, trTipGenReset, trTipPlayReset,
				trTeActStWaAddress, trTeActStWcData,
				trPcIFetchThreshold, trPcDataRdThreshold,
				trTePerfCntIFetchRangeLow,  trTePerfCntDataRdThRangeLow,  trTePerfCntDataRdRangeLow,  trTePerfCntDataWrRangeLow,
				trTePerfCntIFetchRangeHigh, trTePerfCntDataRdThRangeHigh, trTePerfCntDataRdRangeHigh, trTePerfCntDataWrRangeHigh,
				trTeInstTracing, trTeDataTracing,
				trTeTipFifoMaxFillClear, trTeTipFifoNumOverflowsClear, trTeTipFifoHistClear
	);

endinterface // ct_cs_tipclk_if

//-----------------------------------------------------------
// control status interface for proc_clk domain
//-----------------------------------------------------------
interface ct_cs_procclk_if ();

	logic trTeActive; // trTeControl.trTeActive
	ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e trTeInstMode; // trTeControl.trTeInstMode
	logic trTeContext; // trTeControl.trTeContext
	logic trTeInhibitSrc; // trTeControl.trTeInhibitSrc
	ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e trTeInstSyncMode; // trTeControl.trTeInstSyncMode
	tip_isync_max_t trTeInstSyncMax; // trTeControl.trTeInstSyncMax
	// (trTeControl.InstSyncReq is NOT here: the explicit sync request is
	//  consumed in tip_clk by the sync generator -- see ct_cs_tipclk_if. The
	//  dead proc-clk copy was removed with P8.)

	ct_src_id_t trTeSrcID;   // trTeInstFeatures.trTeSrcID
	logic [3:0] trTeSrcBits; // trTeInstFeatures.trTeSrcBits
	logic trTeInstEnImplicitReturn; // trTeInstFeatures.InstEnImplicitReturn (implicit-return compression)
	logic trTeProtocolSel;          // trTeProtocolSel.Protocol (0=N-Trace, 1=E-Trace; constant of the built-in back end, P9)
	logic trTeInstEnBranchPrediction; // trTeInstFeatures.InstEnBranchPrediction (vendor TCODE 56 compression; excludes RepeatedHistory/RepeatBranch)
	logic trTeInstEnRepeatedHistory; // trTeInstFeatures.InstEnRepeatedHistory (repeated-history compression)
	logic trTeInstEnRepeatBranch; // trTeInstFeatures.InstEnRepeatBranch (RepeatBranch TCODE 30 compression)
	logic trTeInstEnJumpTargetCache; // trTeInstFeatures.InstEnJumpTargetCache (vendor TCODE 57 compression)
	logic trTeInstEnWideIcnt; // trTeInstFeatures.InstEnWideIcnt (16-bit internal ICNT cap)
	logic trTeInstEnIbhs; // trTeInstFeatures.InstEnIbhs (TCODE 29: syncs carry pending HIST)
	logic trTeInstEnRepeatInstr; // trTeInstFeatures.InstEnRepeatInstr (TCODE 31/32: spin-loop compression)

	// Config-message ENAB/P2 sources (TCODE 58, C2). Like the other fields
	// in this interface these are quasi-static config values (writable only
	// while trTeControl.Enable = 0 by programming contract), sampled by the
	// formatter/packer when a config message is emitted -- no CDC needed.
	logic trTeInstTrigEnable;    // trTeControl.InstTrigEnable    (ENAB.13)
	logic trTeInstSeqSyncEnable; // trTeControl.InstSeqSyncEnable (ENAB.14)
	ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e_e trTeSendDeviceId; // trTeControl.SendDeviceId (ENAB.19, P4)
	logic [15:0] trWpWEM;        // trWpMask.WEM                 (ENAB.20, P4)
	logic trTeDataTracing;       // trTeDataControl.DataTracing   (ENAB.16; SW-programmed start value, ACT-CAP overrides not reflected)
	logic trTeDataDropEna;       // trTeDataControl.DataDropEna   (ENAB.22, P7)
	ct_cs_cpuif__te__trTsControl__trTsType_e_e trTsType; // trTsControl.Type (P2)
	logic [1:0] trTsPrescale;    // trTsControl.Prescale (P2)
	logic [5:0] trTsWidth;       // trTsControl.Width    (P2)

	logic trTsEnable; // trTsControl.trTsEnable

	ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e_e trTeDataAddrCompress; // trTeDataControl.trTeDataAddrCompress
	logic [4:0] trTeNexusMdoBits; // trTeNexusFeatures.trTeNexusMDOBits

	modport master (
		output  trTeActive, trTeInstMode, trTeContext, trTeInhibitSrc, trTeInstSyncMode, trTeInstSyncMax,
				trTeSrcID, trTeSrcBits, trTeProtocolSel, trTeInstEnImplicitReturn, trTeInstEnBranchPrediction, trTeInstEnRepeatedHistory, trTeInstEnRepeatBranch, trTeInstEnJumpTargetCache, trTeInstEnWideIcnt, trTeInstEnIbhs, trTeInstEnRepeatInstr,
				trTeInstTrigEnable, trTeInstSeqSyncEnable, trTeSendDeviceId, trWpWEM, trTeDataTracing, trTeDataDropEna, trTsType, trTsPrescale, trTsWidth,
				trTsEnable, trTeDataAddrCompress, trTeNexusMdoBits
	);

	modport slave (
		input   trTeActive, trTeInstMode, trTeContext, trTeInhibitSrc, trTeInstSyncMode, trTeInstSyncMax,
				trTeSrcID, trTeSrcBits, trTeProtocolSel, trTeInstEnImplicitReturn, trTeInstEnBranchPrediction, trTeInstEnRepeatedHistory, trTeInstEnRepeatBranch, trTeInstEnJumpTargetCache, trTeInstEnWideIcnt, trTeInstEnIbhs, trTeInstEnRepeatInstr,
				trTeInstTrigEnable, trTeInstSeqSyncEnable, trTeSendDeviceId, trWpWEM, trTeDataTracing, trTeDataDropEna, trTsType, trTsPrescale, trTsWidth,
				trTsEnable, trTeDataAddrCompress, trTeNexusMdoBits
	);

endinterface // ct_cs_procclk_if

//-----------------------------------------------------------
// control status interface for atb_clk domain
//-----------------------------------------------------------
interface ct_cs_atbclk_if ();

	logic        trTeEmpty;      // trTeControl.trTeEmpty
	logic        trPibActive;    // trPibControl.trPibActive
	logic        trPibEnable;    // trPibControl.trPibEnable
	logic        trPibEmpty;     // trPibControl.trPibEmpty
	logic        trPibClkCenter; // trPibControl.trPibClkCenter
	logic        trPibCalibrate; // trPibControl.trPibCalibrate
	logic [15:0] trPibDivider;   // trPibControl.trPibDivider
	logic [6:0]  trAtbId;        // trAtbControl.trAtbId
	logic        trTeProtocolSel; // trTeProtocolSel.Protocol (constant of the built-in back end, P9)

	modport master (
		input   trPibEmpty, trTeEmpty,
		output  trPibActive, trPibEnable, trPibClkCenter, trPibCalibrate, trPibDivider, trAtbId, trTeProtocolSel
	);

	modport slave (
		output  trPibEmpty, trTeEmpty,
		input   trPibActive, trPibEnable, trPibClkCenter, trPibCalibrate, trPibDivider, trAtbId, trTeProtocolSel
	);

endinterface // ct_cs_atbclk_if

//-----------------------------------------------------------
// control status interface for decoder clk domain
//-----------------------------------------------------------
interface ct_cs_decclk_if ();

	logic       trTdInhibitSrc; // trTeControl.trTeInhibitSrc
	logic [3:0] trTdSrcBits;    // trTeInstFeatures.trTeSrcBits

	modport master (
		output  trTdInhibitSrc, trTdSrcBits
	);

	modport slave (
		input   trTdInhibitSrc, trTdSrcBits
	);

endinterface // ct_cs_decclk_if

`default_nettype wire
