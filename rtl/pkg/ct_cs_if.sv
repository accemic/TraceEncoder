// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author	Albert Schulz <aschulz@accemic.com>
* @author	Alexander Lange <alange@accemic.com>
*
* @brief    C-Trace Control & Status Interface for individual clk domains
*/

import ct_pkg::*;
import ct_cs_cpuif_pkg::*;
import tip_pkg::*;

interface ct_cs_tipclk_if #(
	) ();

	logic 																			trTeActive;				// trTeControl.trTeActive
	logic																			trTeEnable; 			// trTeControl.trTeEnable
	logic																			trTeInstTracing;		// trTeControl.trTeInstTracing
	logic																			trTeInstTracingSet;		// trTeControl.trTeInstTracing override by ACT-CAP
	logic																			trTeInstTracingClr;		// trTeControl.trTeInstTracing override by ACT-CAP

																											// trTeControl.trTeEmpty
	ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e 										trTeInstMode;			// trTeControl.trTeInstMode
	logic																			trTeSendConfig;			// trTeControl.trTeSendConfig
	logic																			trTeContext;			// trTeControl.trTeContext
																											// trTeControl.trTeInstTrigEnable
																											// trTeControl.trTeInstStallOrOverflow
																											// trTeControl.trTeInstStallEna
																											// trTeControl.trTeInhibitSrc
	ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e 									trTeInstSyncMode;
	tip_isync_max_t																	trTeInstSyncMax;		// trTeControl.trTeInstSyncMax
																											// trTeControl.trTeFormat
	ct_trace_filter_t																trTeInstFilters;		// trTeInstFiltersReg.Filters

																											// trTeDataControl.trTeDataImplemented
	logic 																			trTeDataTracing;		// trTeDataControl.trTeDataTracing
	logic																			trTeDataTracingSet;		// trTeDataControl.trTeDataTracing override by ACT-CAP
	logic																			trTeDataTracingClr;		// trTeDataControl.trTeDataTracing override by ACT-CAP
																											// trTeDataControl.trTeDataTrigEnable
																											// trTeDataControl.trTeDataStallOrOverflow
																											// trTeDataControl.trTeDataStallEna
																											// trTeDataControl.trTeDataDrop
																											// trTeDataControl.trTeDataDropEna
																											// trTeDataControl.trTeDataNoValue
																											// trTeDataControl.trTeDataNoAddr
																											// trTeDataControl.trTeDataAddrCompress

	ct_trace_filter_t																trTeDataFilters;		// trTeDataFiltersReg.trTeDataFilters

	logic 																			trTsActive;				// trTsControl.trTsActive
	logic 																			trTsCount;				// trTsControl.trTsCount
	logic 																			trTsReset;				// trTsControl.trTsReset
																											// trTsControl.trTsRunInDebug
	ct_cs_cpuif__te__trTsControl__trTsType_e_e											trTsType;

	logic [1:0]																		trTsPrescale;			// trTsControl.trTsPrescale
	logic 																			trTsEnable;				// trTsControl.trTsEnable
																											// trTsControl.trTsWidth
	// Trace Filters
	ct_trace_filter_t																trTeFilterEnable;					// trTeFilter.Control.Enable
	ct_trace_filter_t 																trTeFilterMatchPrivilege;			// trTeFilter.Control.MatchPrivilege
	ct_trace_filter_t 																trTeFilterMatchEcause;				// trTeFilter.Control.MatchEcause
	ct_trace_filter_t 																trTeFilterMatchInterrupt;			// trTeFilter.Control.MatchInterrupt
	ct_trace_filter_match_comp_t	[NUM_TRACE_FILTER-1:0]							trTeFilterMatchComp;				// trTeFilter.Control.MatchComp1..3
	ct_trace_filter_comp_t  		[NUM_TRACE_FILTER-1:0]							trTeFilterComp;						// trTeFilter.Control.Comp1..3
	ct_trace_filter_t 																trTeFilterMatchImpdef;				// trTeFilter.Control.MatchImpdef
	ct_trace_filter_t 																trTeFilterMatchDtype;				// trTeFilter.Control.MatchDtype
	ct_trace_filter_t 																trTeFilterMatchDsize;				// trTeFilter.Control.MatchDsize
	tip_priv_t				[NUM_TRACE_FILTER-1:0]									trTeFilterMatchChoicePrivilege;		// trTeFilter.Match.ChoicePrivilege
	ct_cs_cpuif__te__trTeFilter__Match__trTeFilterMatchInstExInt_e_e	[NUM_TRACE_FILTER-1:0] trTeFilterMatchValueInterrupt;	// trTeFilter.Match.ValueInterrupt
	tip_ecause_vector_t		[NUM_TRACE_FILTER-1:0]									trTeFilterMatchChoiceEcauseLow;		// trTeFilter.MatchEcauseLow.Value
	tip_ecause_vector_t		[NUM_TRACE_FILTER-1:0]									trTeFilterMatchChoiceEcauseHigh;	// trTeFilter.MatchEcauseHigh.Value
	tip_impdef_t			[NUM_TRACE_FILTER-1:0]									trTeFilterMatchValueImpdef;			// trTeFilter.MatchValueImpdef.Value
	tip_impdef_t			[NUM_TRACE_FILTER-1:0]									trTeFilterMatchMaskImpdef;			// trTeFilter.MatchMaskImpdef.Value
	tip_dtype_t				[NUM_TRACE_FILTER-1:0]									trTeFilterMatchChoiceDtype;			// trTeFilter.MatchChoiceData.Dtype
	tip_dsize_t				[NUM_TRACE_FILTER-1:0]									trTeFilterMatchChoiceDsize;			// trTeFilter.MatchChoiceData.Dsize

	// Trace Comparators
	ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e_e     [NUM_TRACE_COMPARATORS-1:0] trTeCompPInput;						// trTeCompControl.trTeCompPInput
	ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e_e     [NUM_TRACE_COMPARATORS-1:0] trTeCompSInput;						// trTeCompControl.trTeCompSInput
	ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e_e [NUM_TRACE_COMPARATORS-1:0] trTeCompPFunction;					// trTeCompControl.trTeCompPFunction
	ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e_e [NUM_TRACE_COMPARATORS-1:0] trTeCompSFunction;					// trTeCompControl.trTeCompSFunction
	ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e_e [NUM_TRACE_COMPARATORS-1:0] trTeCompMatchMode;					// trTeCompControl.trTeCompMatchMode
	ct_trace_comp_t																	trTeCompPNotify;					// trTeCompControl.PNotify
	ct_trace_comp_t																	trTeCompSNotify;					// trTeCompControl.SNotify
	ct_trace_match_t									[NUM_TRACE_COMPARATORS-1:0]	trTeCompPMatchLow;					// trTeCompPMatchLow.Value
	ct_trace_match_t									[NUM_TRACE_COMPARATORS-1:0]	trTeCompPMatchHigh;					// trTeCompPMatchHigh.Value
	ct_trace_match_t									[NUM_TRACE_COMPARATORS-1:0]	trTeCompSMatchLow;					// trTeCompSMatchLow.Value
	ct_trace_match_t									[NUM_TRACE_COMPARATORS-1:0]	trTeCompSMatchHigh;					// trTeCompSMatchHigh.Value


	// Trace Source config (TIP generator, TIP player, CPUs)
	logic										trCPU0Reset;				// trSrcControl0.trCPU0Reset
	logic										trCPU1Reset;				// trSrcControl0.trCPU1Reset
	logic										trCPU2Reset;				// trSrcControl0.trCPU2Reset
	logic										trCPU3Reset;				// trSrcControl0.trCPU3Reset
	logic										trTipGenReset;				// trSrcControl0.trTipGenReset
	logic										trTipPlayReset;				// trSrcControl0.trTipPlayReset

	logic[63:0]									trTeTs; 					// timestamp counter

	logic[31:0]									trTeActStWaAddress [31:0]; 	// smart trigger addresses
	logic[31:0]									trTeActStWcData    [31:0]; 	// control register values for respective smart trigger addresses

	ct_perfcnt_th_t								trPcIFetchThreshold;		// trPerfCntControl.IFetchThreshold
	ct_perfcnt_th_t								trPcDataRdThreshold;		// trPerfCntControl.DataWrThreshold

	tip_iaddr_t	[NUM_PERFCNT_IFETCH_TH_RANGES-1:0]	trTePerfCntIFetchRangeLow;
	tip_iaddr_t	[NUM_PERFCNT_IFETCH_TH_RANGES-1:0]	trTePerfCntIFetchRangeHigh;
	tip_daddr_t	[NUM_PERFCNT_DATA_RD_TH_RANGES-1:0]	trTePerfCntDataRdThRangeLow;
	tip_daddr_t	[NUM_PERFCNT_DATA_RD_TH_RANGES-1:0]	trTePerfCntDataRdThRangeHigh;
	tip_daddr_t	[NUM_PERFCNT_DATA_RD_RANGES-1:0]	trTePerfCntDataRdRangeLow;
	tip_daddr_t	[NUM_PERFCNT_DATA_RD_RANGES-1:0]	trTePerfCntDataRdRangeHigh;
	tip_daddr_t	[NUM_PERFCNT_DATA_WR_RANGES-1:0]	trTePerfCntDataWrRangeLow;
	tip_daddr_t	[NUM_PERFCNT_DATA_WR_RANGES-1:0]	trTePerfCntDataWrRangeHigh;

	// TIP FIFO status (trTeTipFifoStatus @ 0x1400)
	logic [14:0]									trTeTipFifoMaxFill;			// status : tip-clk -> wb
	logic											trTeTipFifoMaxFillClear;		// control: wb -> tip-clk (level)
	logic [14:0]									trTeTipFifoNumOverflows;	// status : tip-clk -> wb
	logic											trTeTipFifoNumOverflowsClear;	// control: wb -> tip-clk (level)

	modport master (
		input   trTeInstTracingSet, trTeInstTracingClr,
				trTeDataTracingSet, trTeDataTracingClr,
				trTeTs,
				trTeTipFifoMaxFill, trTeTipFifoNumOverflows,
		output	trTeActive, trTeEnable, trTeInstMode, trTeSendConfig, trTeContext, trTeInstSyncMode, trTeInstSyncMax,
				trTeInstFilters, trTeDataFilters,
				trTsActive, trTsCount, trTsReset, trTsType, trTsPrescale, trTsEnable,
				trTeFilterEnable, trTeFilterMatchPrivilege, trTeFilterMatchEcause, trTeFilterMatchInterrupt, trTeFilterMatchComp, trTeFilterComp,
				trTeFilterMatchImpdef, trTeFilterMatchDtype, trTeFilterMatchDsize,
				trTeFilterMatchChoicePrivilege, trTeFilterMatchValueInterrupt, trTeFilterMatchChoiceEcauseLow, trTeFilterMatchChoiceEcauseHigh, trTeFilterMatchValueImpdef,
				trTeFilterMatchMaskImpdef, trTeFilterMatchChoiceDtype, trTeFilterMatchChoiceDsize,
				trTeCompPInput, trTeCompSInput, trTeCompPFunction, trTeCompSFunction, trTeCompMatchMode, trTeCompPNotify,
				trTeCompSNotify, trTeCompPMatchLow, trTeCompPMatchHigh, trTeCompSMatchLow, trTeCompSMatchHigh,
				trCPU0Reset, trCPU1Reset, trCPU2Reset, trCPU3Reset, trTipGenReset, trTipPlayReset,
				trTeActStWaAddress, trTeActStWcData,
				trPcIFetchThreshold, trPcDataRdThreshold,
				trTePerfCntIFetchRangeLow,  trTePerfCntDataRdThRangeLow,  trTePerfCntDataRdRangeLow,  trTePerfCntDataWrRangeLow,
				trTePerfCntIFetchRangeHigh, trTePerfCntDataRdThRangeHigh, trTePerfCntDataRdRangeHigh, trTePerfCntDataWrRangeHigh,
				trTeInstTracing, trTeDataTracing,
				trTeTipFifoMaxFillClear, trTeTipFifoNumOverflowsClear
	);

	modport slave (
		output	trTeInstTracingSet, trTeInstTracingClr,
				trTeDataTracingSet, trTeDataTracingClr,
				trTeTs,
				trTeTipFifoMaxFill,
				trTeTipFifoNumOverflows,
		input	trTeActive, trTeEnable, trTeInstMode, trTeSendConfig, trTeContext, trTeInstSyncMode, trTeInstSyncMax,
				trTeInstFilters, trTeDataFilters,
				trTsActive, trTsCount, trTsReset, trTsType, trTsPrescale, trTsEnable,
				trTeFilterEnable, trTeFilterMatchPrivilege, trTeFilterMatchEcause, trTeFilterMatchInterrupt, trTeFilterMatchComp, trTeFilterComp,
				trTeFilterMatchImpdef, trTeFilterMatchDtype, trTeFilterMatchDsize,
				trTeFilterMatchChoicePrivilege, trTeFilterMatchValueInterrupt, trTeFilterMatchChoiceEcauseLow, trTeFilterMatchChoiceEcauseHigh, trTeFilterMatchValueImpdef,
				trTeFilterMatchMaskImpdef, trTeFilterMatchChoiceDtype, trTeFilterMatchChoiceDsize,
				trTeCompPInput, trTeCompSInput, trTeCompPFunction, trTeCompSFunction, trTeCompMatchMode, trTeCompPNotify,
				trTeCompSNotify, trTeCompPMatchLow, trTeCompPMatchHigh, trTeCompSMatchLow, trTeCompSMatchHigh,
				trCPU0Reset, trCPU1Reset, trCPU2Reset, trCPU3Reset, trTipGenReset, trTipPlayReset,
				trTeActStWaAddress, trTeActStWcData,
				trPcIFetchThreshold, trPcDataRdThreshold,
				trTePerfCntIFetchRangeLow,  trTePerfCntDataRdThRangeLow,  trTePerfCntDataRdRangeLow,  trTePerfCntDataWrRangeLow,
				trTePerfCntIFetchRangeHigh, trTePerfCntDataRdThRangeHigh, trTePerfCntDataRdRangeHigh, trTePerfCntDataWrRangeHigh,
				trTeInstTracing, trTeDataTracing,
				trTeTipFifoMaxFillClear, trTeTipFifoNumOverflowsClear
	);

endinterface // ct_cs_tipclk_if

//-----------------------------------------------------------
// control status interface for proc_clk domain
//-----------------------------------------------------------
interface ct_cs_procclk_if  ();

	logic 													trTeActive;				// trTeControl.trTeActive
//	logic													trTeEnable; 			// trTeControl.trTeEnable
//	logic													trTeInstTracing;		// trTeControl.trTeInstTracing
//																								// trTeControl.trTeEmpty
	ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e				trTeInstMode;			// trTeControl.trTeInstMode
	logic													trTeContext;			// trTeControl.trTeContext
//																								// trTeControl.trTeInstTrigEnable
//																								// trTeControl.trTeInstStallOrOverflow
//																								// trTeControl.trTeInstStallEna
	logic 													trTeInhibitSrc;			// trTeControl.trTeInhibitSrc
	ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e			trTeInstSyncMode;		// trTeControl.trTeInstSyncMode
	tip_isync_max_t											trTeInstSyncMax;		// trTeControl.trTeInstSyncMax
	logic													trTeInstSyncReq;		// trTeControl.trTeInstSyncReq

//																								// trTeControl.trTeFormat
//
//	trace_config_t											trTeConfig;				// Trace configuration for trace decoder (via NEXUS_MSG_VENDOR_CONFIG message)
//
//																								// trTeInstFeatures.trTeInstNoAddrDiff
//																								// trTeInstFeatures.trTeInstNoTrapAddr
//																								// trTeInstFeatures.trTeInstEnSequentialJump
//																								// trTeInstFeatures.trTeInstEnImplicitReturn
//																								// trTeInstFeatures.trTeInstEnBranchPrediction
//																								// trTeInstFeatures.trTeInstEnJumpTargetCache
//																								// trTeInstFeatures.trTeInstImplicitReturnMode
//																								// trTeInstFeatures.trTeInstEnRepeatedHistory
//																								// trTeInstFeatures.trTeInstEnAllJumps
//																								// trTeInstFeatures.trTeInstExtendAddrMSB
	ct_src_id_t												trTeSrcID;				// trTeInstFeatures.trTeSrcID
	logic [3:0]												trTeSrcBits;			// trTeInstFeatures.trTeSrcBits
//
//	logic 													trTsActive;				// trTsControl.trTsActive
//																					// trTsControl.trTsCount
//	logic 													trTsReset;				// trTsControl.trTsReset
//																					// trTsControl.trTsRunInDebug
//																					// trTsControl.trTsType
//																					// trTsControl.trTsPrescale
	logic 													trTsEnable;				// trTsControl.trTsEnable
//																					// trTsControl.trTsWidth
//
//																					// trTeDataControl.trTeDataImplemented
//	logic 													trTeDataTracing;		// trTeDataControl.trTeDataTracing
//																					// trTeDataControl.trTeDataTrigEnable
//																					// trTeDataControl.trTeDataStallOrOverflow
//																					// trTeDataControl.trTeDataStallEna
//																					// trTeDataControl.trTeDataDrop
//																					// trTeDataControl.trTeDataDropEna
//	logic 													trTeDataNoValue;		// trTeDataControl.trTeDataNoValue
//	logic 													trTeDataNoAddr;			// trTeDataControl.trTeDataNoAddr
	ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e_e 	trTeDataAddrCompress;	// trTeDataControl.trTeDataAddrCompress
	logic[4:0]												trTeNexusMdoBits;		// trTeNexusFeatures.trTeNexusMDOBits

	modport master (
		output	trTeActive, trTeInstMode, trTeContext, trTeInhibitSrc, trTeInstSyncMode, trTeInstSyncMax, trTeInstSyncReq,
				trTeSrcID, trTeSrcBits, trTsEnable, trTeDataAddrCompress, trTeNexusMdoBits
	);

	modport slave (
		input	trTeActive, trTeInstMode, trTeContext, trTeInhibitSrc, trTeInstSyncMode, trTeInstSyncMax, trTeInstSyncReq,
				trTeSrcID, trTeSrcBits, trTsEnable, trTeDataAddrCompress, trTeNexusMdoBits
	);

endinterface // ct_cs_procclk_if

//-----------------------------------------------------------
// control status interface for atb_clk domain
//-----------------------------------------------------------
interface ct_cs_atbclk_if ();

	logic							trTeEmpty;				// trTeControl.trTeEmpty
	logic							trPibActive;	 		// trPibControl.trPibActive
	logic							trPibEnable; 			// trPibControl.trPibEnable
	logic							trPibEmpty;	 			// trPibControl.trPibEmpty
	// trPibMode_e					trPibMode; 				// trPibControl.trPibMode
	logic							trPibClkCenter; 		// trPibControl.trPibClkCenter
	logic							trPibCalibrate;			// trPibControl.trPibCalibrate
	// trAlignSyncFreq_e			trPibAsyncFreq;			// trPibControl.trPibAsyncFreq
	logic [15:0]					trPibDivider; 			// trPibControl.trPibDivider
	logic [6:0]						trAtbId;				// trAtbControl.trAtbId

	modport master (
		input 	trPibEmpty, trTeEmpty,
		output	trPibActive, trPibEnable, trPibClkCenter, trPibCalibrate, trPibDivider, trAtbId
	);

	modport slave (
		output 	trPibEmpty, trTeEmpty,
		input	trPibActive, trPibEnable, trPibClkCenter, trPibCalibrate, trPibDivider, trAtbId
	);

endinterface // ct_cs_atbclk_if

//-----------------------------------------------------------
// control status interface for decoder clk domain
//-----------------------------------------------------------
interface ct_cs_decclk_if  ();

	logic 							trTdInhibitSrc;			// trTeControl.trTeInhibitSrc
	logic[3:0]						trTdSrcBits;			// trTeInstFeatures.trTeSrcBits

	modport master (
		output	trTdInhibitSrc, trTdSrcBits
	);

	modport slave (
		input	trTdInhibitSrc, trTdSrcBits
	);

endinterface // ct_cs_decclk_if
