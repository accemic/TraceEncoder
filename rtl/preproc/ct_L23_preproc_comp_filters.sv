// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * Address: Kiefersfelden, Germany
 *
 * @file    ct_L23_preproc_comp_filters.sv
 * @brief   Preprocessing stage for per-filter matching using comparator results, trap windows, and TIP sideband predicates.
 *
 * @details
 * This module implements a multi-filter trace-comparator engine for processor trace preprocessing.
 * It evaluates up to NUM_TRACE_FILTER filter entries against current TIP ingress signals and
 * comparator outcomes to assert a consolidated trace-filter hit for instruction or data streams.
 *
 * The design is closely modeled after RISC-V N-Trace Specification (Version 1.0, Ratified):
 * - "RISC-V Trace Control Interface Specification"
 *
 * KEY FEATURES:
 *
 * Comparator Engine:
 * - Selects primary/secondary 32-bit inputs per comparator from TIP fields (iaddr, context, tval, daddr)
 * - Computes p_match/s_match via configurable comparison functions:
 *   • EQUAL, NOT_EQUAL, GREATER_EQUAL, LESS_EQUAL, GREATER, LESS, TRUE, FALSE
 * - Supports 4 programmable match modes:
 *   • Mode 0: Primary result true
 *   • Mode 1: Primary AND Secondary result both true
 *   • Mode 2: NOT (Primary AND Secondary)
 *   • Mode 3: Latched (Set on Primary → Clear on Secondary after retire)
 *
 * Trap Window Filtering:
 * - Exception cause window: trTeFilterMatchEcause with marker-based exception match history stack
 * - Interrupt/exception window: trTeFilterMatchInterrupt with trTeFilterMatchValueInterrupt selector
 * - Implements RISC-V N-Trace Section 6.3 semantics:
 *   "Start matching from exception/interrupt, stop matching upon return from the first matching trap"
 * - Stack-based implementation ensures correct counter semantics for nested exceptions
 * - Underflow/overflow detection for hot-start and debug scenarios
 *
 * Per-Filter Predicates:
 * - Enable gate: trTeFilterEnable[i]
 * - Privilege bitmap: trTeFilterMatchPrivilege[i] with trTeFilterMatchChoicePrivilege[i][tip.priv]
 * - Data type filtering: trTeFilterMatchDtype[i] with trTeFilterMatchChoiceDtype[i]
 * - Data size filtering: trTeFilterMatchDsize[i] with trTeFilterMatchChoiceDsize[i]
 * - Comparator gating: trTeFilterMatchComp[i] with indices trTeFilterComp[i][j]
 *
 * Selection and Result:
 * - If filter selection mask is zero, unconditional tracing is performed ("trace all" policy per spec)
 * - Output hit is qualified after per-cycle commit and delay alignment
 *
 * @implementation_notes
 * - Stack uses shift-register with marker for efficient overflow/underflow detection
 * - Mode 3 latches are synchronized with retire boundaries (tip.iretire or tip.dretire)
 * - Saturating counters track ecause/interrupt window depth
 * - Assertion checks for stack errors (simulation only)
 * - Pipeline depth controlled by EXTRA_DELAY_MAX parameter for synchronization
 * @ports
 * clk                  Trace clock (TIP domain)
 * rst                  Synchronous active-high reset
 * cs_tip               Control/status interface (ct_cs_tipclk_if, TIP clock domain)
 * tip                  TIP ingress interface providing itype, ecause, iaddr, daddr, priv, iretire, etc.
 * cf_filter            Control flow filter hit output interface (ct_hit_if)
 * df_filter            Data flow filter hit output interface (ct_hit_if)
 * internal_delay       Delay of this component including all submodules
 * extra_delay          Extra delay for synchronizing preprocessing modules
 *
 * @timing
 * - Comparator evaluation: Combinatorial (same cycle)
 * - Stack operations: Sequential (registered on posedge clk)
 * - Counter updates: Sequential via counter_if instances
 * - Filter result: Pipelined through HitPipe[EXTRA_DELAY_MAX:0]
 * - Total latency: internal_delay + extra_delay cycles
 */

import ct_cs_cpuif_pkg::*;
import tip_pkg::*;
import ct_pkg::*;

module ct_L23_preproc_comp_filters #(
	// Keep TB compatibility: other preproc modules use ct_pkg::EXTRA_DELAY_MAX.
	int EXTRA_DELAY_MAX = ct_pkg::EXTRA_DELAY_MAX
)(
	input  uwire logic    clk,
	input  uwire logic    rst,
	ct_cs_tipclk_if.slave cs_tip,
	tip_if.slave          tip,
	ct_hit_if.master      cf_filter,
	ct_hit_if.master      df_filter,
	output delay_t        internal_delay, // delay of this component including all submodules
	input uwire delay_t   extra_delay     // extra delay to be added for syncronizing preproc modules
);

	// ---------------------------------------------------------------------------
	// Comparator engine
	// - Per comparator j: select primary/secondary values from tip_if
	// - Inclusive range match against P/S Low/High
	// - Combine P/S according by MatchMode
	// - Map comp_hit[0..2] to per-filter Comp1/2/3 checks
	//
	// Width (X2a): the comparator datapath is ct_trace_comp_data_t, i.e.
	// ct_pkg::TRACE_COMPARATORS_WIDTH = CT_XLEN. The CSR side is unchanged --
	// a bound is still a pair of 32-bit registers, joined by comp_join below.
	// Before X2a everything here was a hard [31:0], so a 64-bit iaddr would
	// have been truncated SILENTLY: the filter would have matched on the low
	// half alone and happily fired on a completely different address.
	// ---------------------------------------------------------------------------

	// Join a {High,Low} CSR register pair into one comparator-wide value.
	// The cast does the profile switch on its own: at CT_XLEN = 32 the
	// concatenation is truncated back to the Low half (bit-identical to the
	// historical code, which read Low only and left High unused), at 64 it is
	// the full bound.
	function automatic ct_trace_comp_data_t comp_join(input ct_trace_match_t hi,
	                                                  input ct_trace_match_t lo);
		comp_join = ct_trace_comp_data_t'({hi, lo});
	endfunction

	// Bit `ec` of the per-filter exception-cause bitmap, which spans the
	// {MatchChoiceEcauseHigh, MatchChoiceEcauseLow} register pair (one bit
	// per cause).
	function automatic logic ecause_selected(input ct_trace_match_t hi,
	                                         input ct_trace_match_t lo,
	                                         input tip_ecause_t     ec);
		tip_ecause_vector_t bitmap;
		bitmap          = tip_ecause_vector_t'({hi, lo});
		ecause_selected = bitmap[ec];
	endfunction

	// Select a comparator input from tip- and cs-sources using a simple code
	function automatic ct_trace_comp_data_t comp_select_input(ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e_e sel_code);
		unique case (sel_code)
			ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_IADDR:     comp_select_input = ct_trace_comp_data_t'(tip.iaddr);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_CONTEXT:   comp_select_input = ct_trace_comp_data_t'(tip._context);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_TVAL:      comp_select_input = ct_trace_comp_data_t'(tip.tval);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_DADDR:     comp_select_input = ct_trace_comp_data_t'(tip.daddr);
			default:                                                                comp_select_input = '0;
		endcase
	endfunction

	// Comparator evaluation
	// Note: PeakRDL exposes separate enums for primary/secondary functions.
	// - Primary: 0..5 compare, 6 reserved_match, 7 always_match
	// - Secondary: 0..5 compare, 6 PMASK, 7 always_match
	function automatic logic comp_eval_p(
		input ct_trace_comp_data_t val,
		input ct_trace_comp_data_t match,
		input ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e_e func
	);
		unique case (func)
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_EQUAL:          comp_eval_p = (val == match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_NOT_EQUAL:      comp_eval_p = (val != match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_LESS:           comp_eval_p = (val <  match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_LESS_EQUAL:     comp_eval_p = (val <= match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_GREATER:        comp_eval_p = (val >  match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_GREATER_EQUAL:  comp_eval_p = (val >= match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_RESERVED_MATCH: comp_eval_p = 1'b0; // reserved: treat as no-match
			ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_ALWAYS_MATCH:   comp_eval_p = 1'b1;
			default:                                                                          comp_eval_p = 1'b0;
		endcase
	endfunction

	function automatic logic comp_eval_s(
		input ct_trace_comp_data_t val,
		input ct_trace_comp_data_t match,
		input ct_trace_comp_data_t mask,
		input ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e_e func
	);
		unique case (func)
			ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_EQUAL:         comp_eval_s = (val == match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_NOT_EQUAL:     comp_eval_s = (val != match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_LESS:          comp_eval_s = (val <  match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_LESS_EQUAL:    comp_eval_s = (val <= match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_GREATER:       comp_eval_s = (val >  match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_GREATER_EQUAL: comp_eval_s = (val >= match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_PMASK:         comp_eval_s = ((val & mask) == match);
			ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_ALWAYS_MATCH:  comp_eval_s = 1'b1;
			default:                                                                         comp_eval_s = 1'b0;
		endcase
	endfunction

	ct_trace_comp_t                                     comp_hit;           // Per‑comparator combined match result according to the selected match mode
	logic                                               all_comps_hit;
	ct_trace_comp_data_t    [NUM_TRACE_COMPARATORS-1:0] p_val;              // Primary input value per comparator (CT_XLEN wide)
	ct_trace_comp_data_t    [NUM_TRACE_COMPARATORS-1:0] s_val;              // Secondary input value per comparator (CT_XLEN wide)
	ct_trace_comp_t                                     p_match;    // Primary match flag per comparator
	ct_trace_comp_t                                     s_match;    // Secondary match flag per comparator

	// Intermediate signals
	ct_trace_filter_t                                   ecause_match;
	ct_trace_filter_t                                   intr_match;
	ct_trace_filter_t                                   priv_match;
	ct_trace_filter_t                                   dtype_match;
	ct_trace_filter_t                                   dsize_match;
	ct_trace_filter_t                                   stack_has_data;
	ct_trace_filter_t                                   bottom_match_status;

	logic                                               any_match_cf_now;                // OR-ed qualifier for control flow trace
	logic                                               any_match_df_now;                // OR-ed qualifier for data flow trace
	logic                                               any_match_cf_next, AnyMatchCf;   // delayed by 1 cycle
	logic                                               any_match_df_next, AnyMatchDf;   // delayed by 1 cycle
	logic                                               TipIretire;
	logic                                               TipDretire;
	ct_trace_comp_t                                     CompLatchM3;  // Comp Mode 3 latch state

	//========================================================================
	// MARKER-BASED EXCEPTION MATCH HISTORY STACK
	//========================================================================

	// Stack data: exception match history (1 = matched, 0 = didn't match)
	ct_exception_stack_t        ExceptionStack            [NUM_TRACE_FILTER];
	ct_exception_stack_marker_t ExceptionStackMarker      [NUM_TRACE_FILTER];

	// Error flags
	logic                       ExceptionStackOverflow    [NUM_TRACE_FILTER];
	logic                       ExceptionStackUnderflow   [NUM_TRACE_FILTER];

	//========================================================================
	// TRAP WINDOW COUNTERS
	//========================================================================

	// counter signals
	ct_trace_filter_t       cnt_ecause_inc;
	ct_trace_filter_t       cnt_ecause_dec;
	ct_trace_filter_t       cnt_ecause_overflow;
	ct_trace_match_cnt_t    cnt_intr_value[NUM_TRACE_FILTER];

	ct_trace_filter_t       cnt_intr_inc;
	ct_trace_filter_t       cnt_intr_dec;
	ct_trace_filter_t       cnt_intr_overflow;
	ct_trace_match_cnt_t    cnt_ecause_value[NUM_TRACE_FILTER];

	counter_if #(.T(ct_trace_match_cnt_t)) cnt_ecause[NUM_TRACE_FILTER] ();
	counter_if #(.T(ct_trace_match_cnt_t)) cnt_intr  [NUM_TRACE_FILTER] ();

	generate
		for(genvar i=0; i<NUM_TRACE_FILTER; i++) begin

			counter #(.T(ct_trace_match_cnt_t), .MODE(MODE_SATURATION)) cnt_ecause_inst (
				.clk(clk),
				.rst(rst),
				.cnt(cnt_ecause[i])
			);
			assign cnt_ecause[i].overflow_value = ct_trace_match_cnt_t'('1);
			assign cnt_ecause[i].inc            = cnt_ecause_inc[i];
			assign cnt_ecause[i].dec            = cnt_ecause_dec[i];
			assign cnt_ecause[i].add            = '0;
			assign cnt_ecause[i].clr            = '0;
			assign cnt_ecause_overflow[i]       = cnt_ecause[i].overflow;
			assign cnt_ecause_value[i]          = cnt_ecause[i].value;

			counter #(.T(ct_trace_match_cnt_t), .MODE(MODE_SATURATION)) cnt_intr_inst (
				.clk(clk),
				.rst(rst),
				.cnt(cnt_intr[i])
			);
			assign cnt_intr[i].overflow_value = ct_trace_match_cnt_t'('1);
			assign cnt_intr[i].inc            = cnt_intr_inc[i];
			assign cnt_intr[i].dec            = cnt_intr_dec[i];
			assign cnt_intr[i].add            = '0;
			assign cnt_intr[i].clr            = '0;
			assign cnt_intr_overflow[i]       = cnt_intr[i].overflow;
			assign cnt_intr_value[i]          = cnt_intr[i].value;
		end
	endgenerate

	//========================================================================
	// COMPARATOR MODE 3 LATCH CONTROL (Sequential)
	// Implements latched behavior: set on p_match, clear after s_match
	//========================================================================

	always_ff @(posedge clk or posedge rst) begin
		if (rst) begin
			CompLatchM3 <= '0;  // All latches cleared on reset
		end
		else if (tip.iretire || tip.dretire) begin  // Update latches only on retire
			for (int j = 0; j < NUM_TRACE_COMPARATORS; j++) begin
				if (cs_tip.trTeCompMatchMode[j] == ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_INPUT_MODE3) begin

					// SET: When primary match occurs
					if (p_match[j]) begin
						CompLatchM3[j] <= 1'b1;
					end

					// CLEAR: After secondary match instruction is retired
					// (Note: Clear happens on NEXT cycle after s_match, due to retire boundary)
					else  if (s_match[j]) begin
						CompLatchM3[j] <= 1'b0;
					end
					// else: Latch holds current state
				end
			end
		end
	end

	//========================================================================
	// Trap window match predicates (combinational)
	//========================================================================

	always_comb begin
		ecause_match = '0;
		intr_match   = '0;

		for (int i = 0; i < NUM_TRACE_FILTER; i++) begin
			// The bitmap is the {High,Low} CSR pair -- one bit per cause. The
			// High half has existed in the RDL from the start and had no
			// reader; wiring it makes a 6-bit ecause (X8b) a width change
			// instead of a structural one. At the current 4-bit width the
			// index never leaves the low 16 bits, so High constant-folds away
			// and the netlist is unchanged.
			// TipEcauseIsValid(itype) is the ecause validity qualifier -- the
			// TIP contract has no separate valid line (X8a).
			ecause_match[i]  = cs_tip.trTeFilterMatchEcause[i]
							&& tip.iretire
							&& TipEcauseIsValid(tip.itype)
							&& ecause_selected(cs_tip.trTeFilterMatchChoiceEcauseHigh[i],
							                   cs_tip.trTeFilterMatchChoiceEcauseLow[i],
							                   tip.ecause);

			intr_match[i]    = cs_tip.trTeFilterMatchInterrupt[i]
							&& tip.iretire
							&& (   (   (cs_tip.trTeFilterMatchValueInterrupt[i] == 1'b0)
									&& (tip.itype == EXCEPTION_TRAP))
								|| (   (cs_tip.trTeFilterMatchValueInterrupt[i] == 1'b1)
									&& (tip.itype == INTERRUPT)));
		end
	end

	//========================================================================
	// COMPARATOR EVALUATION
	//========================================================================

	always_comb begin
		for (int j = 0; j < NUM_TRACE_COMPARATORS; j++) begin

			p_val[j] = comp_select_input(cs_tip.trTeCompPInput[j]);
			s_val[j] = comp_select_input(cs_tip.trTeCompSInput[j]);
			// {High,Low} IS the bound (X2a, decision E-R-1). The PMASK mask
			// used to be read out of SMatchHigh, which cost the secondary
			// bound its high half -- it now has its own register pair.
			p_match[j] = comp_eval_p(p_val[j],
			                         comp_join(cs_tip.trTeCompPMatchHigh[j], cs_tip.trTeCompPMatchLow[j]),
			                         cs_tip.trTeCompPFunction[j]);
			s_match[j] = comp_eval_s(s_val[j],
			                         comp_join(cs_tip.trTeCompSMatchHigh[j], cs_tip.trTeCompSMatchLow[j]),
			                         comp_join(cs_tip.trTeCompSMaskHigh[j],  cs_tip.trTeCompSMaskLow[j]),
			                         cs_tip.trTeCompSFunction[j]);

			unique case (cs_tip.trTeCompMatchMode[j])
				ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0: comp_hit[j] =   p_match[j];                                 // mode 0: primary result true
				ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_INPUT_MODE1: comp_hit[j] =   p_match[j] & s_match[j];                    // mode 1: primary and secondary result both true
				ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_INPUT_MODE2: comp_hit[j] = ~(p_match[j] & s_match[j]);                   // mode 2: either primary or secondary result does not match
				ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_INPUT_MODE3: comp_hit[j] =   p_match[j] || s_match[j] || CompLatchM3[j]; // mode 3: latched - output latch OR (p_match & still_in_window)
																																					//         The output remains 1 until secondary match, then clears
				default:                                                                comp_hit[j] = '0;                                           // safe default
			endcase
		end
	end

	//========================================================================
	// STACK PUSH/POP LOGIC (Sequential)
	// One always_ff block only (avoid multiple drivers)
	//========================================================================
	always_ff @(posedge clk or posedge rst) begin
		if (rst) begin
			// Reset all stacks and error flags
			for (int i = 0; i < NUM_TRACE_FILTER; i++) begin
				ExceptionStack[i]           <= '0;
				ExceptionStackMarker[i]     <= {{EXCEPTION_STACK_DEPTH{1'b0}}, 1'b1};  // Marker at LSB
				ExceptionStackOverflow[i]   <= '0;
				ExceptionStackUnderflow[i]  <= '0;
			end
		end
		else begin
			// Process each filter
			for (int i = 0; i < NUM_TRACE_FILTER; i++) begin
				// Calculate match status
				if (tip.iretire && ((tip.itype == EXCEPTION_TRAP) || (tip.itype == INTERRUPT))) begin
					// PUSH: Shift left ExceptionStack and ExceptionStackMarker
					ExceptionStack[i]       <= (ExceptionStack[i] << 1) | (ecause_match[i] || intr_match[i]);
					ExceptionStackMarker[i] <= (ExceptionStackMarker[i] << 1);
				end
				else if (tip.iretire && (tip.itype == EXCEPTION_IR)) begin
					// Check for underflow condition (marker at LSB = stack empty)
					if (ExceptionStackMarker[i][0]) begin
						// UNDERFLOW: Pop from empty stack - set error flag, no shift
						ExceptionStackUnderflow[i] <= 1'b1;
						// Keep stack in valid empty state (no shift)
					end
					else begin
						// POP: Shift right by 1
						ExceptionStack[i]       <= (ExceptionStack[i] >> 1);
						ExceptionStackMarker[i] <= (ExceptionStackMarker[i] >> 1);
					end
				end
			end
		end
	end

	//========================================================================
	// COUNTER CONTROL LOGIC (Combinatorial)
	// Stack-based decrement ensures spec compliance
	//========================================================================

	always_comb begin
		for (int i = 0; i < NUM_TRACE_FILTER; i++) begin

			// Stack has data if any bit is set AND no underflow occurred
			stack_has_data[i] = (ExceptionStack[i] != '0) && !ExceptionStackUnderflow[i];

			// Read LSB = most recently pushed exception (stack top for pop)
			bottom_match_status[i] = ExceptionStack[i][0];

			// ================================================================
			// ECAUSE FILTER: Counter control
			// ================================================================

			// INCREMENT: Exception with matching ecause
			cnt_ecause_inc[i] =     cs_tip.trTeFilterMatchEcause[i]
								&&  tip.iretire
								&&  TipEcauseIsValid(tip.itype)
								&&  ecause_selected(cs_tip.trTeFilterMatchChoiceEcauseHigh[i],
								                    cs_tip.trTeFilterMatchChoiceEcauseLow[i],
								                    tip.ecause);

			// DECREMENT: ONLY if returning exception was a MATCH (stack-based semantics)
			// This ensures spec compliance: "stop matching upon return from the 1st matching exception"
			cnt_ecause_dec[i] =     cs_tip.trTeFilterMatchEcause[i]
								&&  tip.iretire
								&& (tip.itype == EXCEPTION_IR)
								&&  stack_has_data[i]
								&&  bottom_match_status[i];  // Check if this exception matched

			// ================================================================
			// INTERRUPT FILTER: Counter control
			// ================================================================

			// INCREMENT: Interrupt (or exception if configured for exception matching)
			cnt_intr_inc[i] =       cs_tip.trTeFilterMatchInterrupt[i]
								&&  tip.iretire
								&& (   (   (cs_tip.trTeFilterMatchValueInterrupt[i] == 1'b0)
										&& (tip.itype == EXCEPTION_TRAP))
									|| (   (cs_tip.trTeFilterMatchValueInterrupt[i] == 1'b1)
										&& (tip.itype == INTERRUPT)));

			// DECREMENT: ONLY if returning exception/interrupt was a MATCH (stack-based semantics)
			cnt_intr_dec[i] =       cs_tip.trTeFilterMatchInterrupt[i]
								&&  tip.iretire
								&& (tip.itype == EXCEPTION_IR)
								&&  stack_has_data[i]
								&&  bottom_match_status[i];
		end
	end

	//========================================================================
	// PER-FILTER MATCHING LOGIC
	//========================================================================

	// Helper: OR match
	task automatic set_match_now (input int i);
		any_match_cf_now |= cs_tip.trTeInstFilters[i];
		any_match_df_now |= cs_tip.trTeDataFilters[i];
	endtask

	task automatic set_match_next (input int i);
		any_match_cf_next |= cs_tip.trTeInstFilters[i];
		any_match_df_next |= cs_tip.trTeDataFilters[i];
	endtask

	typedef struct packed {
		logic cf_filter_hit_valid;
		logic cf_filter_hit;
		logic df_filter_hit_valid;
		logic df_filter_hit;
	} hits_t;

	hits_t HitPipe [EXTRA_DELAY_MAX:0];

	// Per-filter accumulator used in the sequential loop below. Declared here
	// to stay compatible with Vivado's Verilog-2005 style parsing (no block
	// scoped declarations inside procedural blocks).
	logic pred_ok;

	always_ff @(posedge clk) begin
		// verilog_lint: waive-start always-ff-non-blocking
		// This block uses blocking assignments to temporaries and arrays to implement
		// sequential predicate accumulation. Flops are still updated with <=.

		any_match_cf_now     = '0;
		any_match_df_now     = '0;
		any_match_cf_next    = '0;
		any_match_df_next    = '0;
		AnyMatchCf          <= '0;
		AnyMatchDf          <= '0;

		if (rst) begin
			HitPipe[0]  <= '0;
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				HitPipe[idx] <= '0;
			end
			priv_match      = '0;
			dtype_match     = '0;
			dsize_match     = '0;
			all_comps_hit   = '0;
			TipIretire     <= '0;
			TipDretire     <= '0;
		end
		else begin

			for (int i = 0; i < NUM_TRACE_FILTER; i++) begin
				// Predicate evaluation according to RDL bitmaps.
				// Within one filter: enabled predicates are AND'ed.
				priv_match[i]  = cs_tip.trTeFilterMatchPrivilege[i]
							  && cs_tip.trTeFilterMatchChoicePrivilege[i][tip.priv];
				dtype_match[i] = cs_tip.trTeFilterMatchDtype[i]
							  && cs_tip.trTeFilterMatchChoiceDtype[i][tip.dtype];
				dsize_match[i] = cs_tip.trTeFilterMatchDsize[i]
							  && cs_tip.trTeFilterMatchChoiceDsize[i][tip.dsize];

				pred_ok = cs_tip.trTeFilterEnable[i];

				// AND only the predicates that are enabled via their Match* bits.
				if (cs_tip.trTeFilterMatchPrivilege[i]) pred_ok &= priv_match[i];
				if (cs_tip.trTeFilterMatchDtype[i])     pred_ok &= dtype_match[i];
				if (cs_tip.trTeFilterMatchDsize[i])     pred_ok &= dsize_match[i];

				// Trap window conditions are active while counters are non-zero.
				if (cs_tip.trTeFilterMatchEcause[i]) begin
					pred_ok &= ((cnt_ecause_value[i] != '0) && (!cnt_ecause_overflow[i]));
				end

				if (cs_tip.trTeFilterMatchInterrupt[i]) begin
					pred_ok &= ((cnt_intr_value[i] != '0) && (!cnt_intr_overflow[i]));
				end

				// Comparator gating: only apply if any MatchComp bit is set.
				if (cs_tip.trTeFilterMatchComp[i] != '0) begin
					all_comps_hit = 1'b1;
					for (int j = 0; j <= 2; j++) begin
						if (cs_tip.trTeFilterMatchComp[i][j] && (cs_tip.trTeFilterComp[i][j] < NUM_TRACE_COMPARATORS)) begin
							all_comps_hit &= comp_hit[cs_tip.trTeFilterComp[i][j]];
						end
					end
					pred_ok &= all_comps_hit;
				end

				if (pred_ok) begin
					set_match_next(i);
				end
			end

			// TipBeatRetires: TipIretire is one bit (see tip_pkg -- a bare
			// assignment would truncate a block iretire to its LSB).
			TipIretire   <= TipBeatRetires(tip.iretire);
			TipDretire   <= tip.dretire;

			AnyMatchCf   <= any_match_cf_next;
			AnyMatchDf   <= any_match_df_next;

			// Final decision (mask==0 => trace all)
			HitPipe[0].cf_filter_hit_valid <= TipIretire;
			HitPipe[0].cf_filter_hit       <= (cs_tip.trTeInstFilters == '0) || AnyMatchCf || any_match_cf_now;
			HitPipe[0].df_filter_hit_valid <= TipDretire;
			HitPipe[0].df_filter_hit       <= (cs_tip.trTeDataFilters == '0) || AnyMatchDf || any_match_df_now;

			// Pipeline delays
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				HitPipe[idx] <= HitPipe[idx-1];
			end
		end
	end
	// verilog_lint: waive-stop always-ff-non-blocking

	assign cf_filter.hit_valid = HitPipe[extra_delay].cf_filter_hit_valid;
	assign cf_filter.hit       = HitPipe[extra_delay].cf_filter_hit;
	assign df_filter.hit_valid = HitPipe[extra_delay].df_filter_hit_valid;
	assign df_filter.hit       = HitPipe[extra_delay].df_filter_hit;
	assign internal_delay      = 2;

endmodule

`default_nettype wire
