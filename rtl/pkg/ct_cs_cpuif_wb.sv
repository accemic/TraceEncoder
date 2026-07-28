// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder control/status register block (Wishbone CSR access + CDC).
 *
 * @details
 *   Distributes the control/status signals to the respective pipeline stages
 *   and exposes them over Wishbone via the generated CPUIF:
 *   - CDC into the tip_clk, proc_clk and atb.aclk domains
 *   - several signals need no CDC but are only writable while trTeControl.Enable = 0
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

module ct_cs_cpuif_wb (
	input uwire                wb_clk,         // wishbone clock
	input uwire                wb_rst,         // wishbone reset
	input uwire                ct_cs_rst,      // ct_cs reset
	input uwire                tip_clk,        // TIP clock
	input uwire                tip_rst,        // TIP reset
	input uwire                proc_clk,       // TE processing stage clk
	input uwire                proc_rst,       // TE processing stage clk
	ct_cs_tipclk_if.master     cs_tip,         // control / status registers for tip.clk domain
	ocram_write_if.client      act_st_wext,    // write interface for memory in tip.clk domain
	ocram_write_if.client      df_range_wext,  // write interface for memory in tip.clk domain
	ct_cs_procclk_if.master    cs_proc,        // control / status registers for proc_clk domain
	ct_cs_atbclk_if.master     cs_atb,         // control / status registers for atb_clk domain
	ct_cs_decclk_if.master     cs_dec,         // control / status registers for decoder clk domain
	wb_if.slave                wb              // wishbone
);

	import ct_cs_cpuif_pkg::*;

	logic        s_cpuif_req;
	logic        s_cpuif_req_is_wr;
	logic [14:0] s_cpuif_addr;
	logic [31:0] s_cpuif_wr_data;
	logic [31:0] s_cpuif_wr_biten;
	logic        s_cpuif_req_stall_wr;
	logic        s_cpuif_req_stall_rd;
	logic        s_cpuif_rd_ack;
	logic        s_cpuif_rd_err;
	logic [31:0] s_cpuif_rd_data;
	logic        s_cpuif_wr_ack;
	logic        s_cpuif_wr_err;

	// wb to cpuif bridge
	wb_to_cpuif #(
		.ADDR_WIDTH     (32),
		.DATA_WIDTH     (32),
		.IMPLEMENTATION ("COMB"))
	wb_to_cpuif_inst (
		.clk (wb_clk),
		.rst (wb_rst),
		.wb,
		.s_cpuif_req,
		.s_cpuif_req_is_wr,
		.s_cpuif_addr,
		.s_cpuif_wr_data,
		.s_cpuif_wr_biten,
		.s_cpuif_req_stall_wr,
		.s_cpuif_req_stall_rd,
		.s_cpuif_rd_ack,
		.s_cpuif_rd_err,
		.s_cpuif_rd_data,
		.s_cpuif_wr_ack,
		.s_cpuif_wr_err
	);

	ct_cs_cpuif__in_t        hwif_in;
	uwire ct_cs_cpuif__out_t hwif_out;

	ct_cs_cpuif ct_cs_cpuif_inst (
		.clk (wb_clk),
		.rst (ct_cs_rst),
		.s_cpuif_req,
		.s_cpuif_req_is_wr,
		.s_cpuif_addr,
		.s_cpuif_wr_data,
		.s_cpuif_wr_biten,
		.s_cpuif_req_stall_wr,
		.s_cpuif_req_stall_rd,
		.s_cpuif_rd_ack,
		.s_cpuif_rd_err,
		.s_cpuif_rd_data,
		.s_cpuif_wr_ack,
		.s_cpuif_wr_err,
		.hwif_in,
		.hwif_out
	);

	// SWWE gating ("configuration fields are accessible only while
	// trTeControl.Enable=0") is expressed declaratively in the RDL via
	// `<path>->swwel = te.trTeControl.Enable;` dynamic assignments at the end
	// of ct_cs_cpuif.rdl. PeakRDL-regblock 1.3.x honours those references and
	// generates the internal write gate directly in ct_cs_cpuif.sv, so no
	// hwif_in.*.swwe inputs exist anymore and no wrapper-side plumbing is
	// needed. The TIP-FIFO clear bits intentionally stay always-writable by
	// not listing them in the RDL swwel block.

	// act_st_mem interface (watchpoints)
	// Lower 32-bit word at base+0x0: key
	// Upper 32-bit word at base+0x4: value

	typedef struct packed {
		logic [31:0] key;
		logic [31:0] value;
	} tp_watchpoints_t;

	localparam int WATCHPOINTS_WORD_SEL_BIT   = $clog2(32/8);
	localparam int WATCHPOINTS_ENTRY_ADDR_LSB = $clog2($bits(tp_watchpoints_t)/8);
	localparam int WATCHPOINTS_DEPTH          = 1 << ($bits(hwif_out.watchpoints.addr) - WATCHPOINTS_ENTRY_ADDR_LSB);

	tp_watchpoints_t                     TpWatchpoints     = '0;
	logic [$bits(act_st_wext.addr)-1:0]  WrAddrWatchpoints = '0;
	logic                                WrWatchpoints     = 1'b0;
	(* ram_style = "block" *) tp_watchpoints_t ActStMemShadow [0:WATCHPOINTS_DEPTH-1];

	uwire [$bits(act_st_wext.addr)-1:0] rd_addr_watchpoints = hwif_out.watchpoints.addr >> WATCHPOINTS_ENTRY_ADDR_LSB;

	always_ff @(posedge wb_clk) begin
		if (wb_rst || ct_cs_rst) begin
			TpWatchpoints     <= '0;
			WrAddrWatchpoints <= '0;
			WrWatchpoints     <= 1'b0;
			for (int idx = 0; idx < WATCHPOINTS_DEPTH; idx++) begin
				ActStMemShadow[idx] <= '0;
			end
		end
		else begin
			WrWatchpoints <= 1'b0;
			if (hwif_out.watchpoints.req && hwif_out.watchpoints.req_is_wr) begin
				if (hwif_out.watchpoints.addr[WATCHPOINTS_WORD_SEL_BIT] == 0) begin // lower 32-bit word, store key
					TpWatchpoints.key <= hwif_out.watchpoints.wr_data;
				end
				else begin
					TpWatchpoints.value <= hwif_out.watchpoints.wr_data;
					WrAddrWatchpoints   <= hwif_out.watchpoints.addr >> WATCHPOINTS_ENTRY_ADDR_LSB;
					WrWatchpoints       <= 1'b1;
					ActStMemShadow[hwif_out.watchpoints.addr >> WATCHPOINTS_ENTRY_ADDR_LSB].key   <= TpWatchpoints.key;
					ActStMemShadow[hwif_out.watchpoints.addr >> WATCHPOINTS_ENTRY_ADDR_LSB].value <= hwif_out.watchpoints.wr_data;
				end
			end
		end
	end

	assign act_st_wext.ce   = WrWatchpoints;
	assign act_st_wext.we   = WrWatchpoints;
	assign act_st_wext.addr = WrAddrWatchpoints;
	assign act_st_wext.d    = TpWatchpoints;

	// df_mem interface (mem1)
	// Lower 32-bit word at base+0x0: key0
	// Upper 32-bit word at base+0x4: key1

	typedef struct packed {
		logic [31:0] key;
		logic [31:0] value;
	} tp_mem1_t;

	localparam int MEM1_WORD_SEL_BIT   = $clog2(32/8);
	localparam int MEM1_ENTRY_ADDR_LSB = $clog2($bits(tp_mem1_t)/8);
	localparam int MEM1_DEPTH          = 1 << ($bits(hwif_out.mem1.addr) - MEM1_ENTRY_ADDR_LSB);

	tp_mem1_t                             TpMem1     = '0;
	logic [$bits(df_range_wext.addr)-1:0] WrAddrMem1 = '0;
	logic                                 WrMem1     = 1'b0;
	(* ram_style = "block" *) tp_mem1_t DfRangeMemShadow [0:MEM1_DEPTH-1];

	uwire [$bits(df_range_wext.addr)-1:0] rd_addr_mem1 = hwif_out.mem1.addr >> MEM1_ENTRY_ADDR_LSB;

	always_ff @(posedge wb_clk) begin
		if (wb_rst || ct_cs_rst) begin
			TpMem1     <= '0;
			WrAddrMem1 <= '0;
			WrMem1     <= 1'b0;
			for (int idx = 0; idx < MEM1_DEPTH; idx++) begin
				DfRangeMemShadow[idx] <= '0;
			end
		end
		else begin
			WrMem1 <= 1'b0;
			if (hwif_out.mem1.req && hwif_out.mem1.req_is_wr) begin
				if (hwif_out.mem1.addr[MEM1_WORD_SEL_BIT] == 0) begin // lower 32-bit word, store key
					TpMem1.key <= hwif_out.mem1.wr_data;
				end
				else begin
					TpMem1.value <= hwif_out.mem1.wr_data;
					WrAddrMem1   <= hwif_out.mem1.addr >> MEM1_ENTRY_ADDR_LSB;
					WrMem1       <= 1'b1;
					DfRangeMemShadow[hwif_out.mem1.addr >> MEM1_ENTRY_ADDR_LSB].key   <= TpMem1.key;
					DfRangeMemShadow[hwif_out.mem1.addr >> MEM1_ENTRY_ADDR_LSB].value <= hwif_out.mem1.wr_data;
				end
			end
		end
	end

	assign df_range_wext.ce   = WrMem1;
	assign df_range_wext.we   = WrMem1;
	assign df_range_wext.addr = WrAddrMem1;
	assign df_range_wext.d    = TpMem1;

	always_comb begin
		// External memory read-data muxes
		hwif_in.watchpoints.wr_ack  = hwif_out.watchpoints.req &&  hwif_out.watchpoints.req_is_wr;
		hwif_in.watchpoints.rd_ack  = hwif_out.watchpoints.req && !hwif_out.watchpoints.req_is_wr;
		hwif_in.watchpoints.rd_data = (hwif_out.watchpoints.addr[WATCHPOINTS_WORD_SEL_BIT] == 0)
			? ActStMemShadow[rd_addr_watchpoints].key
			: ActStMemShadow[rd_addr_watchpoints].value;

		hwif_in.mem1.wr_ack  = hwif_out.mem1.req &&  hwif_out.mem1.req_is_wr;
		hwif_in.mem1.rd_ack  = hwif_out.mem1.req && !hwif_out.mem1.req_is_wr;
		hwif_in.mem1.rd_data = (hwif_out.mem1.addr[MEM1_WORD_SEL_BIT] == 0)
			? DfRangeMemShadow[rd_addr_mem1].key
			: DfRangeMemShadow[rd_addr_mem1].value;

		// ----------------------------------------------------------------------------------------------------
		// Trace Encoder - tip_clk domain
		// (tip_clk / proc_clk / atb_clk consumers are only sampled while trTeControl.Enable = 0,
		//  so these fields do not need CDC.)
		// ----------------------------------------------------------------------------------------------------
		cs_tip.trTeActive       = hwif_out.te.trTeControl.Active.value;
		cs_tip.trTeContext      = hwif_out.te.trTeControl.Context.value;
		cs_tip.trTeSendConfig   = hwif_out.te.trTeControl.SendConfig.value;
		cs_tip.trTeInstMode     = ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e'    (hwif_out.te.trTeControl.InstMode.value);
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e'(hwif_out.te.trTeControl.InstSyncMode.value);
		cs_tip.trTeInstSyncMax  = hwif_out.te.trTeControl.InstSyncMax.value;
		cs_tip.trTeInstFilters  = hwif_out.te.trTeInstFilters.Filters.value;
		cs_tip.trTeDataFilters  = hwif_out.te.trTeDataFilters.Filters.value;

		cs_tip.trTsReset    = hwif_out.te.trTsControl.Reset.value;
		cs_tip.trTsType     = ct_cs_cpuif__te__trTsControl__trTsType_e_e'(hwif_out.te.trTsControl.Type.value);
		cs_tip.trTsPrescale = hwif_out.te.trTsControl.Prescale.value;

		cs_tip.trPcIFetchThreshold = hwif_out.pc.trPerfCntControl.IFetchThreshold.value;
		cs_tip.trPcDataRdThreshold = hwif_out.pc.trPerfCntControl.DataWrThreshold.value;
	end

	for (genvar i = 0; i < NUM_TRACE_FILTER; i++) begin
		always_comb begin
			cs_tip.trTeFilterEnable[i]                = hwif_out.te.trTeFilter[i].Control.Enable.value;
			cs_tip.trTeFilterMatchPrivilege[i]        = hwif_out.te.trTeFilter[i].Control.MatchPrivilege.value;
			cs_tip.trTeFilterMatchEcause[i]           = hwif_out.te.trTeFilter[i].Control.MatchEcause.value;
			cs_tip.trTeFilterMatchInterrupt[i]        = hwif_out.te.trTeFilter[i].Control.MatchInterrupt.value;
			cs_tip.trTeFilterMatchComp[i][0]          = hwif_out.te.trTeFilter[i].Control.MatchComp1.value;
			cs_tip.trTeFilterComp[i][0]               = hwif_out.te.trTeFilter[i].Control.Comp1.value;
			cs_tip.trTeFilterMatchComp[i][1]          = hwif_out.te.trTeFilter[i].Control.MatchComp2.value;
			cs_tip.trTeFilterComp[i][1]               = hwif_out.te.trTeFilter[i].Control.Comp2.value;
			cs_tip.trTeFilterMatchComp[i][2]          = hwif_out.te.trTeFilter[i].Control.MatchComp3.value;
			cs_tip.trTeFilterComp[i][2]               = hwif_out.te.trTeFilter[i].Control.Comp3.value;
			cs_tip.trTeFilterMatchImpdef[i]           = hwif_out.te.trTeFilter[i].Control.Impdef.value;
			cs_tip.trTeFilterMatchDtype[i]            = hwif_out.te.trTeFilter[i].Control.Dtype.value;
			cs_tip.trTeFilterMatchDsize[i]            = hwif_out.te.trTeFilter[i].Control.Dsize.value;
			cs_tip.trTeFilterMatchChoicePrivilege[i]  = hwif_out.te.trTeFilter[i].Match.ChoicePrivilege.value;
			cs_tip.trTeFilterMatchValueInterrupt[i]   = ct_cs_cpuif__te__trTeFilter__Match__trTeFilterMatchInstExInt_e_e'(hwif_out.te.trTeFilter[i].Match.ValueInterrupt.value);
			cs_tip.trTeFilterMatchChoiceEcauseLow[i]  = hwif_out.te.trTeFilter[i].MatchChoiceEcauseLow.Value.value;
			cs_tip.trTeFilterMatchChoiceEcauseHigh[i] = hwif_out.te.trTeFilter[i].MatchChoiceEcauseHigh.Value.value;
			cs_tip.trTeFilterMatchValueImpdef[i]      = hwif_out.te.trTeFilter[i].MatchValueImpdef.Value.value;
			cs_tip.trTeFilterMatchMaskImpdef[i]       = hwif_out.te.trTeFilter[i].MatchMaskImpdef.Value.value;
			cs_tip.trTeFilterMatchChoiceDtype[i]      = hwif_out.te.trTeFilter[i].MatchChoiceData.Dtype.value;
			cs_tip.trTeFilterMatchChoiceDsize[i]      = hwif_out.te.trTeFilter[i].MatchChoiceData.Dsize.value;
		end
	end

	for (genvar i = 0; i < NUM_TRACE_COMPARATORS; i++) begin
		always_comb begin
			cs_tip.trTeCompPFunction[i]  = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e_e'(hwif_out.te.trTeComp[i].Control.PFunction.value);
			cs_tip.trTeCompSFunction[i]  = ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e_e'(hwif_out.te.trTeComp[i].Control.SFunction.value);
			cs_tip.trTeCompMatchMode[i]  = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e_e'(hwif_out.te.trTeComp[i].Control.MatchMode.value);
			cs_tip.trTeCompPNotify[i]    = hwif_out.te.trTeComp[i].Control.PNotify.value;
			cs_tip.trTeCompSNotify[i]    = hwif_out.te.trTeComp[i].Control.SNotify.value;
			cs_tip.trTeCompPMatchLow[i]  = hwif_out.te.trTeComp[i].PMatchLow.Value.value;
			cs_tip.trTeCompPMatchHigh[i] = hwif_out.te.trTeComp[i].PMatchHigh.Value.value;
			cs_tip.trTeCompSMatchLow[i]  = hwif_out.te.trTeComp[i].SMatchLow.Value.value;
			cs_tip.trTeCompSMatchHigh[i] = hwif_out.te.trTeComp[i].SMatchHigh.Value.value;
		end
	end

	for (genvar i = 0; i < NUM_PERFCNT_IFETCH_TH_RANGES; i++) begin
		always_comb begin
			cs_tip.trTePerfCntIFetchRangeLow[i]  = hwif_out.pc.trTePerfCntIFetchRange[i].Low.Value.value;
			cs_tip.trTePerfCntIFetchRangeHigh[i] = hwif_out.pc.trTePerfCntIFetchRange[i].High.Value.value;
		end
	end

	for (genvar i = 0; i < NUM_PERFCNT_DATA_RD_TH_RANGES; i++) begin
		always_comb begin
			cs_tip.trTePerfCntDataRdThRangeLow[i]  = hwif_out.pc.trTePerfCntDataRdThRange[i].Low.Value.value;
			cs_tip.trTePerfCntDataRdThRangeHigh[i] = hwif_out.pc.trTePerfCntDataRdThRange[i].High.Value.value;
		end
	end

	for (genvar i = 0; i < NUM_PERFCNT_DATA_RD_RANGES; i++) begin
		always_comb begin
			cs_tip.trTePerfCntDataRdRangeLow[i]  = hwif_out.pc.trTePerfCntDataRdRange[i].Low.Value.value;
			cs_tip.trTePerfCntDataRdRangeHigh[i] = hwif_out.pc.trTePerfCntDataRdRange[i].High.Value.value;
		end
	end

	for (genvar i = 0; i < NUM_PERFCNT_DATA_WR_RANGES; i++) begin
		always_comb begin
			cs_tip.trTePerfCntDataWrRangeLow[i]  = hwif_out.pc.trTePerfCntDataWrRange[i].Low.Value.value;
			cs_tip.trTePerfCntDataWrRangeHigh[i] = hwif_out.pc.trTePerfCntDataWrRange[i].High.Value.value;
		end
	end

	always_comb begin
		// ----------------------------------------------------------------------------------------------------
		// Trace Encoder - proc_clk domain
		// ----------------------------------------------------------------------------------------------------
		cs_proc.trTeActive           = hwif_out.te.trTeControl.Active.value;
		cs_proc.trTeInstMode         = ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e'(hwif_out.te.trTeControl.InstMode.value);
		cs_proc.trTeContext          = hwif_out.te.trTeControl.Context.value;
		cs_proc.trTeInhibitSrc       = hwif_out.te.trTeControl.InhibitSrc.value;
		cs_proc.trTeInstSyncMode     = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e'(hwif_out.te.trTeControl.InstSyncMode.value);
		cs_proc.trTeInstSyncMax      = hwif_out.te.trTeControl.InstSyncMax.value;
		cs_proc.trTeSrcID            = hwif_out.te.trTeInstFeatures.SrcID.value;
		cs_proc.trTeSrcBits          = hwif_out.te.trTeInstFeatures.SrcBits.value;
		cs_proc.trTeDataAddrCompress = ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e_e'(hwif_out.te.trTeDataControl.DataAddrCompress.value);

		// ----------------------------------------------------------------------------------------------------
		// atb_clk domain
		// ----------------------------------------------------------------------------------------------------
		cs_atb.trAtbId                    = hwif_out.atb.trAtbBridgeControl.ID.value;
		hwif_in.te.trTeControl.Empty.next = cs_atb.trTeEmpty;

		// ----------------------------------------------------------------------------------------------------
		// dec_clk domain (decoder clock - simulation only)
		// ----------------------------------------------------------------------------------------------------
		cs_dec.trTdInhibitSrc = cs_proc.trTeInhibitSrc;
		cs_dec.trTdSrcBits    = cs_proc.trTeSrcBits;
	end

	// ----------------------------------------------------------------------------------------------------
	// CDC for ACT-CAP controlled signals (set, clr via ACT-CAP)
	// ----------------------------------------------------------------------------------------------------
	ct_hwif_ext_signal_cdc trTeInstTracing_cdc (
		.hwif_clk   (wb_clk),
		.hwif_rst   (wb_rst),
		.hwif_hwclr (hwif_in.te.trTeControl.InstTracing.hwclr),
		.hwif_hwset (hwif_in.te.trTeControl.InstTracing.hwset),
		.hwif_value (hwif_out.te.trTeControl.InstTracing.value),
		.ext_clk    (tip_clk),
		.ext_rst    (tip_rst),
		.ext_hwclr  (cs_tip.trTeInstTracingClr),
		.ext_hwset  (cs_tip.trTeInstTracingSet),
		.ext_value  (cs_tip.trTeInstTracing)
	);

	ct_hwif_ext_signal_cdc trTeDataTracing_cdc (
		.hwif_clk   (wb_clk),
		.hwif_rst   (wb_rst),
		.hwif_hwclr (hwif_in.te.trTeDataControl.DataTracing.hwclr),
		.hwif_hwset (hwif_in.te.trTeDataControl.DataTracing.hwset),
		.hwif_value (hwif_out.te.trTeDataControl.DataTracing.value),
		.ext_clk    (tip_clk),
		.ext_rst    (tip_rst),
		.ext_hwclr  (cs_tip.trTeDataTracingClr),
		.ext_hwset  (cs_tip.trTeDataTracingSet),
		.ext_value  (cs_tip.trTeDataTracing)
	);

	// CDC for trTeControl.Enable: master enable for the trace encoder.
	// SW transition 1->0 must trigger an automatic flush in the tip_clk
	// pipeline (handled inside ct_L23_preproc_composer_etip.sv via a
	// falling-edge detector).
	signal_cdc signal_cdc_trTeEnable (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (hwif_out.te.trTeControl.Enable.value),
		.out (cs_tip.trTeEnable)
	);

	// CDC for trTsEnable
	signal_cdc signal_cdc_trTsEnable (
		.clk (proc_clk),
		.rst (proc_rst),
		.in  (hwif_out.te.trTsControl.Enable.value),
		.out (cs_proc.trTsEnable)
	);

	// CDC for trTsActive
	signal_cdc signal_cdc_trTsActive (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (hwif_out.te.trTsControl.Active.value),
		.out (cs_tip.trTsActive)
	);

	// CDC for trTsCount
	signal_cdc signal_cdc_trTsCount (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (hwif_out.te.trTsControl.Count.value),
		.out (cs_tip.trTsCount)
	);

	// trTeInstSyncReq: sw write triggers a sync request; RDL field clears
	// automatically every cycle so the bit reads back as 0. No CDC strobe is
	// wired up today (the request is consumed in the wb_clk domain).
	assign hwif_in.te.trTeControl.InstSyncReq.next = '0;

	// Cross the 64-bit trTeTs counter from tip_clk (where it is generated by
	// ct_L23_preproc_ts) into wb_clk, then split into the High/Low readback
	// registers. vector_cdc2 uses a req/ack toggle handshake so sw always reads
	// a coherent snapshot rather than a half-updated value.
	uwire logic [63:0] trTeTsWb;
	vector_cdc2 #(.DATA_WIDTH(64)) cdc_trTeTs (
		.d_clk  (tip_clk),
		.d_rst  (tip_rst),
		.d_data (cs_tip.trTeTs),
		.q_clk  (wb_clk),
		.q_rst  (wb_rst),
		.q_data (trTeTsWb)
	);
	assign hwif_in.te.trTsCounterHigh.Value.next = trTeTsWb[63:32];
	assign hwif_in.te.trTsCounterLow.Value.next  = trTeTsWb[31:0];

	// CDC for trTeTipFifoMaxFill (tip_clk -> wb_clk): coherent snapshot.
	uwire logic [14:0] trTeTipFifoMaxFillWb;
	vector_cdc2 #(.DATA_WIDTH(15)) cdc_trTeTipFifoMaxFill (
		.d_clk  (tip_clk),
		.d_rst  (tip_rst),
		.d_data (cs_tip.trTeTipFifoMaxFill),
		.q_clk  (wb_clk),
		.q_rst  (wb_rst),
		.q_data (trTeTipFifoMaxFillWb)
	);
	assign hwif_in.te.trTeTipFifoStatus.trTeTipFifoMaxFill.next = trTeTipFifoMaxFillWb;

	// CDC for trTeTipFifoMaxFillClear (wb_clk -> tip_clk): level, synchronised.
	signal_cdc signal_cdc_trTeTipFifoMaxFillClear (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (hwif_out.te.trTeTipFifoStatus.trTeTipFifoMaxFillClear.value),
		.out (cs_tip.trTeTipFifoMaxFillClear)
	);

	// CDC for trTeTipFifoNumOverflows (tip_clk -> wb_clk): gray-coded coherent snapshot.
	uwire logic [14:0] trTeTipFifoNumOverflowsWb;
	vector_cdc2 #(.DATA_WIDTH(15)) cdc_trTeTipFifoNumOverflows (
		.d_clk  (tip_clk),
		.d_rst  (tip_rst),
		.d_data (cs_tip.trTeTipFifoNumOverflows),
		.q_clk  (wb_clk),
		.q_rst  (wb_rst),
		.q_data (trTeTipFifoNumOverflowsWb)
	);
	assign hwif_in.te.trTeTipFifoStatus.trTeTipFifoNumOverflows.next = trTeTipFifoNumOverflowsWb;

	// CDC for trTeTipFifoNumOverflowsClear (wb_clk -> tip_clk): level, synchronised.
	signal_cdc signal_cdc_trTeTipFifoNumOverflowsClear (
		.clk (tip_clk),
		.rst (tip_rst),
		.in  (hwif_out.te.trTeTipFifoStatus.trTeTipFifoNumOverflowsClear.value),
		.out (cs_tip.trTeTipFifoNumOverflowsClear)
	);

endmodule // ct_cs_cpuif_wb

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
