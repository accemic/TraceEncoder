// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    C-Trace Package
 */

package ct_pkg;

	import ct_cs_cpuif_pkg::*;

	localparam SRC_ID_MAX_WIDTH = 12; // corresponds to NTRACE_MAX_SRC
	localparam ADDR_WIDTH       = 32; // Nexus F-ADDR / U-ADDR width
	localparam ADDR_MAX_WIDTH   = 64; // corresponds to NTRACE_MAX_ADDR
	localparam HIST_WIDTH       = 32; // Nexus HIST width
	localparam HIST_MAX_WIDTH   = 32; // corresponds to NTRACE_MAX_HIST
	localparam TSTAMP_WIDTH     = 64; // Nexus TSTAMP width
	localparam TSTAMP_MAX_WIDTH = 64; // corresponds to NTRACE_MAX_TSTAMP

	localparam SYNC_COUNT_AEMPTY = 50; // send "xxx Branch with Sync Message" if SyncCount < SYNC_COUNT_AEMPTY

	localparam ETIP_PAR_MSG        =   3; // number of parallel etip messages
	localparam ETIP_CVS_FIFO_DEPTH = 128;
	localparam ETIP_CDC_FIFO_DEPTH = 128;

	localparam ATB_FUNNEL_IMPUT_FIFO_DEPTH = 16;
	localparam ATB_MAX_CHUNKS               =  4; // 4 x 8/16/32 Bit
	localparam ATB_CVS_FIFO_DEPTH           =  8;
	localparam ATB_CDC_FIFO_DEPTH           =  8;

	localparam NUM_ATB = 2; // # of ATB inputs of funnel

	localparam DISP_ALL  = 32'hFFFFFFFF;
	localparam DISP_NONE = '0;
	localparam DISP_1    = 32'h00000001 << 0;
	localparam DISP_2    = 32'h00000001 << 1; // info output from nexus formatter
	localparam DISP_3    = 32'h00000001 << 2; // info output from msoe mdo formatter
	localparam DISP_4    = 32'h00000001 << 3;

	localparam DISP = DISP_3;

	typedef enum logic [1:0] {
		DATA_RD        = 0, // count # of data reads
		DATA_WR        = 1, // count # of data writes
		INSTR_FETCH_TH = 2, // count # of instruction fetches exceeding threshold
		DATA_RD_TH     = 3  // count # of data reads exceeding threshold
	} ct_perfcnt_type_e;

	localparam NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH  = $clog2(NUM_PERFCNT_IFETCH_TH_RANGES);
	localparam NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH = $clog2(NUM_PERFCNT_DATA_RD_TH_RANGES);
	localparam NUM_PERFCNT_DATA_RD_RANGES_WIDTH    = $clog2(NUM_PERFCNT_DATA_RD_RANGES);
	localparam NUM_PERFCNT_DATA_WR_RANGES_WIDTH    = $clog2(NUM_PERFCNT_DATA_WR_RANGES);

	localparam SYNCCNT_WIDTH             = 21; // must be greater than cs_tip.trTeInstSyncMax(=16) + 4
	localparam PERFCNT_WIDTH             = 32;
	localparam TRACE_MATCH_WIDTH         = 32;
	localparam PERFCNT_TH_WIDTH          =  8;
	localparam EXCEPTION_STACK_DEPTH     =  4; // 4 for debugging of overflow, later: 16 or 32
	localparam NUM_TRACE_COMPARATORS_WIDTH = $clog2(NUM_TRACE_COMPARATORS); // width of # of trace comparators (max 4)
	localparam TRACE_COMPARATORS_WIDTH   = 32; // data width of trace comparator
	localparam MATCH_CNT_WIDTH           =  8; // width of FilterMatchEcause / FilterMatchInterrupt counter
	localparam SEARCH_RESULT_WIDTH       =  2;
	localparam MAX_DAQ_DATA_ELEMENTS     =  3;
	localparam PREPROC_DELAY_MAX         = 20;
	localparam PREPROC_DELAY_MAX_WIDTH   = $clog2(PREPROC_DELAY_MAX);
	localparam EXTRA_DELAY_MAX           = PREPROC_DELAY_MAX; // Maximum configurable additional pipeline depth (default: 20)
	                                                          // Allows synchronization with other preprocessing modules.

	typedef logic [SYNCCNT_WIDTH-1:0]                    ct_synccnt_counter_t;
	typedef logic [PERFCNT_WIDTH-1:0]                    ct_perfcnt_counter_t;
	typedef logic [SEARCH_RESULT_WIDTH-1:0]              ct_search_result_t;
	typedef logic [SRC_ID_MAX_WIDTH-1:0]                 ct_src_id_t;
	typedef logic [NUM_TRACE_FILTER-1:0]                 ct_trace_filter_t;
	typedef logic [NUM_TRACE_COMPARATORS-1:0]            ct_trace_comp_t;
	typedef logic [TRACE_COMPARATORS_WIDTH-1:0]          ct_trace_comp_data_t;
	typedef logic [2:0]                                  ct_trace_filter_match_comp_t; // three comparator selectors (1..3) per filter
	typedef logic [2:0][NUM_TRACE_COMPARATORS_WIDTH-1:0] ct_trace_filter_comp_t;        // comparator selector id | comparator id
	typedef logic [EXCEPTION_STACK_DEPTH-1:0]            ct_exception_stack_t;
	typedef logic [EXCEPTION_STACK_DEPTH:0]              ct_exception_stack_marker_t;
	typedef logic [TRACE_MATCH_WIDTH-1:0]                ct_trace_match_t;
	typedef logic [MATCH_CNT_WIDTH-1:0]                  ct_trace_match_cnt_t;
	typedef logic [PERFCNT_TH_WIDTH-1:0]                 ct_perfcnt_th_t;

	localparam ACT_CAP_INT_ELEMENT_WIDTH = 32;
	localparam ACT_CAP_AXIS_TDATA_WIDTH  = 3 * ACT_CAP_INT_ELEMENT_WIDTH;
	localparam ACT_CAP_AXIS_TID_WIDTH    = 8; // TODO: check with act_cap_cmd_t.data.id_data.id

	// C-trace internal sub message type
	typedef enum logic [2:0] {
		SUB_MSG_NONE  = 0, // sub message is not valid
		SUB_MSG_CF    = 1, // sub message is etip_cf_msg_struct_t
		SUB_MSG_DF    = 2, // sub message is etip_df_msg_struct_t
		SUB_MSG_DAQ   = 3, // sub message is etip_daq_msg_struct_t
		SUB_MSG_OTHER = 4
	} ct_sub_type_e;

	// ACT-CAP/ST definitions
	localparam ACT_CAP_DATA_WIDTH = 32;
	localparam ACT_CAP_ADDR_WIDTH = 32;
	typedef logic [ACT_CAP_DATA_WIDTH-1:0] ct_act_cap_data_t;
	typedef logic [ACT_CAP_ADDR_WIDTH-1:0] ct_act_cap_addr_t;

	// ATC-CAP/ST TE register access
	typedef enum logic [7:0] {
		ACT_CAP_TE_INSTR_TRACING = 0, // trTeControl.InstTracing
		ACT_CAP_TE_DATA_TRACING  = 1  // trTeDataControl.DataTracing
	} ct_act_cap_te_ctrl_e;

	typedef struct packed {
		ct_act_cap_te_ctrl_e ctrl;
		logic [15:0]         data;
	} ct_act_cap_te_t;

	// Definitions for M0 (act_st)
	localparam int M0_DIM    = 4;
	localparam int M0_N      = (2**M0_DIM)-1;
	localparam int M0_STAGES = (M0_N > 1) ? $clog2(M0_N) : 1;

	localparam type   M0_K           = logic [31:0]; // key = iaddr
	localparam type   M0_R           = logic [31:0]; // 32 Bit value
	localparam string M0_SEARCH_MODE = "VALUE";      // "VALUE, "RANGE"
	localparam int    M0_NUM_KEYS    = (M0_SEARCH_MODE == "VALUE") ? 1 : 2;

	typedef struct packed {
		M0_K [M0_NUM_KEYS-1:0] key;
		M0_R                   value;
	} m0_kr_t;

	// Definitions for M1 (df range)
	localparam int M1_DIM    = 4;
	localparam int M1_N      = (2**M1_DIM)-1;
	localparam int M1_STAGES = (M1_N > 1) ? $clog2(M1_N) : 1;

	localparam type   M1_K           = logic [31:0]; // hit, if key0 <= daddr <= key1
	localparam string M1_SEARCH_MODE = "RANGE";      // "VALUE, "RANGE"
	localparam int    M1_NUM_KEYS    = (M1_SEARCH_MODE == "VALUE") ? 1 : 2;

	typedef struct packed {
		M1_K [M1_NUM_KEYS-1:0] key;
	} m1_kr_t;

	typedef logic [PREPROC_DELAY_MAX_WIDTH-1:0] delay_t;

endpackage // ct_pkg

`default_nettype wire
