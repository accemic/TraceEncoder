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
* @brief    Accemic C-Trace Performance Counter Pakage (for simulation)
*/

package ct_comp_filters_pkg;

	import tip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	//------------------------------------------------------------------------
	// Comparator /Filter Helper
	//------------------------------------------------------------------------
	// Example usage:
	// The following example configures the C‑Trace control/status interface
	// to trace all instructions executed within the address range
	// from 0x1000 to 0x1100.
	//
	// // Initialize all comparator and filter units
	// CompFilterInit(cs_tip);
	//
	// // Configure two instruction address comparators defining the range
	// // Comparator 0 -> start address (>= 0x1000)
	// // Comparator 1 -> end address   (<= 0x1100)
	// CompFilterSetIaddrRange(cs_tip, 0, 0, 1, 32'h1000, 32'h1100);
	//
	// // Enable instruction filter 0 (uses comparators 0 and 1)
	// // to trace all instruction fetches within the range.
	// CompFilterInstEnable(cs_tip, 16'h1);
	//
	// At runtime, the C‑Trace will now capture trace entries
	// only for instructions fetched from addresses between
	// 0x1000 and 0x1100 (inclusive).
	//------------------------------------------------------------------------

	//------------------------------------------------------------------------
	// Task: CompFilterInit
	// Resets and initializes all comparator and filter structures
	// to default (inactive) values in the C‑Trace control/status interface.
	// Parameter:
	//   cs_tip - Virtual C‑Trace control/status interface.
	// Example usage:
	//   CompFilterInit(cs_tip);
	//   This call disables all trace filters and resets all
	//   comparators to their default state, ensuring a clean
	//   starting point before configuring specific filtering rules.
	//------------------------------------------------------------------------
	task automatic CompFilterInit(
		virtual ct_cs_tipclk_if.master	cs_tip );

		cs_tip.trTeInstFilters = '0;
		cs_tip.trTeDataFilters = '0;

		for (int i = 0; i < NUM_TRACE_FILTER; i++) begin
			cs_tip.trTeFilterEnable[i]                  = '0;
			cs_tip.trTeFilterMatchPrivilege[i]          = '0;
			cs_tip.trTeFilterMatchEcause[i]             = '0;
			cs_tip.trTeFilterMatchInterrupt[i]          = '0;
			for(int j = 1; j <= 3; j++ ) begin
				cs_tip.trTeFilterMatchComp[i]           = '0;
				cs_tip.trTeFilterComp[i]                = '0;
			end
			cs_tip.trTeFilterMatchImpdef[i]             = '0;
			cs_tip.trTeFilterMatchDtype[i]              = '0;
			cs_tip.trTeFilterMatchDsize[i]              = '0;
			cs_tip.trTeFilterMatchChoicePrivilege[i]    = '0;
			cs_tip.trTeFilterMatchValueInterrupt[i]     = ct_cs_cpuif__te__trTeFilter__Match__trTeFilterMatchInstExInt_e__TR_FILTER_MATCHVALUE_EXCEPTION_TRAP;
			cs_tip.trTeFilterMatchChoiceEcauseLow[i]    = '0;
			cs_tip.trTeFilterMatchChoiceEcauseHigh[i]   = '0;
			cs_tip.trTeFilterMatchValueImpdef[i]        = '0;
			cs_tip.trTeFilterMatchMaskImpdef[i]         = '0;
			cs_tip.trTeFilterMatchChoiceDtype[i]        = '0;
			cs_tip.trTeFilterMatchChoiceDsize[i]        = '0;
		end

		// config comparators (comp_hit is always false)
		for (int i = 0; i < NUM_TRACE_COMPARATORS; i++) begin
			 cs_tip.trTeCompPInput[i]                   = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_DADDR;
			 cs_tip.trTeCompSInput[i]                   = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_DADDR;
			 // Primary function: use RESERVED_MATCH as a safe "always false".
			 cs_tip.trTeCompPFunction[i]                = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_RESERVED_MATCH;
			 // Secondary is don't-care for MatchMode0, set to ALWAYS_MATCH to avoid surprises.
			 cs_tip.trTeCompSFunction[i]                = ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_ALWAYS_MATCH;
			 cs_tip.trTeCompMatchMode[i]                = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0;
			 cs_tip.trTeCompPNotify[i]                  = '0;
			 cs_tip.trTeCompSNotify[i]                  = '0;
			 cs_tip.trTeCompPMatchLow[i]                = '0;
			 cs_tip.trTeCompPMatchHigh[i]               = '0;
			 cs_tip.trTeCompSMatchLow[i]                = '0;
			 cs_tip.trTeCompSMatchHigh[i]               = '0;
		end
	endtask

	//------------------------------------------------------------------------
	// Task: CompFilterInstEnable
	// Enables instruction-related filters by setting bits according
	// to the provided mask in the C‑Trace control/status interface.
	// Parameters:
	//   cs_tip - Virtual C‑Trace control/status interface.
	//   value  - Bitmask for filter enable.
	// Example usage:
	//   CompFilterInstEnable(cs_tip, 16'h3);
	//   This enables instruction filters 0 and 1 (bits 0 and 1 set).
	//   Only instruction trace events that match the configured
	//   filters 0 and 1 will be captured and recorded.
	//------------------------------------------------------------------------
	task automatic CompFilterInstEnable(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter);
		cs_tip.trTeInstFilters |= 16'h1 << filter;
	endtask

	//------------------------------------------------------------------------
	// Task: CompFilterDataEnable
	// Enables data-related filters by setting bits according
	// to the provided mask in the C‑Trace control/status interface.
	// Parameters:
	//   cs_tip - Virtual C‑Trace control/status interface.
	//   value  - Bitmask for filter enable.
	// Example usage:
	//   CompFilterDataEnable(cs_tip, 16'h1);
	//   This enables data filter 0 (bit 0 set). Only data access
	//   trace events that match the configured filter 0 will be
	//   captured and recorded in the trace output.
	//------------------------------------------------------------------------
	task automatic CompFilterDataEnable(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter);
		cs_tip.trTeDataFilters |= 16'h1 << filter;
	endtask

	//------------------------------------------------------------------------
	// Task: CompFilterCheckRanges
	// Verifies filter and comparator indices to ensure they are
	// within their valid ranges in the C‑Trace control/status interface.
	// Parameters:
	//   cs_tip   - Virtual C‑Trace control/status interface.
	//   filter   - Filter index.
	//   comp     - Comparator index.
	//   comp_id  - Comparator assignment (1, 2, or 3).
	// Example usage:
	//   CompFilterCheckRanges(cs_tip, 2, 1, 1);
	//   This validates that filter index 2, comparator index 1,
	//   and comparator assignment 1 are all within legal bounds
	//   before attempting configuration to prevent runtime errors.
	//------------------------------------------------------------------------
	task automatic CompFilterCheckRanges(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter, int comp, input int comp_id);

		if (filter >= NUM_TRACE_FILTER) begin
			$error("filter = %0d is too high (max. %0d)", filter, NUM_TRACE_FILTER-1);
			$finish();
		end
		if (comp >= NUM_TRACE_COMPARATORS) begin
			$error("comp_id = %0d is too high (max. %0d)", comp, NUM_TRACE_COMPARATORS-1);
			$finish();
		end
		if ((comp_id < 1) || (comp_id>3)) begin
			$error("comp_id = %0d is out of range (1..3)", comp_id);
			$finish();
		end
	endtask

	//------------------------------------------------------------------------
	// Task: CompFilterSetDaddr
	// Assigns a comparator for data address matching to a filter
	// in the control/status interface and activates match settings.
	// Parameters:
	//   cs_tip   - Virtual C‑Trace control/status interface.
	//   filter   - Filter index.
	//   comp     - Comparator index.
	//   comp_id  - Comparator assignment within filter.
	//   daddr    - Data address to match.
	// Example usage:
	//   CompFilterSetDaddr(cs_tip, 0, 0, 1, 32'h1050);
	//   This configures filter 0 to use comparator 0 (assignment 1)
	//   to match data accesses at address 0x1050. Only data reads
	//   or writes to this exact address will pass through the filter.
	//------------------------------------------------------------------------
	task automatic CompFilterSetDaddr(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter, int comp, input int comp_id, tip_daddr_t daddr);

		cs_tip.trTeFilterMatchComp[filter]          = 3'h1;     // use MatchComp1
		cs_tip.trTeFilterComp[filter][1]            = comp_id;
		cs_tip.trTeCompPInput[comp]                 = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_DADDR;
		cs_tip.trTeCompPFunction[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_EQUAL;
		cs_tip.trTeCompMatchMode[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0;
		cs_tip.trTeCompPMatchLow[comp]              = daddr;
		cs_tip.trTeFilterEnable[filter]             = 1'h1;
		cs_tip.trTeDataFilters                     |= 16'h1 << filter;
	endtask

	//------------------------------------------------------------------------
	// Task: CompSetDaddr
	//------------------------------------------------------------------------
	task automatic CompSetDaddr(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int comp, tip_daddr_t daddr);

		cs_tip.trTeCompPInput[comp]                 = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_DADDR;
		cs_tip.trTeCompPFunction[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_EQUAL;
		cs_tip.trTeCompMatchMode[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0;
		cs_tip.trTeCompPMatchLow[comp]              = daddr;
	endtask

	//------------------------------------------------------------------------
	// Task: CompSetInactive
	// config a comp which always returns FALSE
	//------------------------------------------------------------------------
	task automatic CompSetInactive(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int comp);
		cs_tip.trTeCompPFunction[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_RESERVED_MATCH;
		cs_tip.trTeCompMatchMode[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0;
	endtask

	//------------------------------------------------------------------------
	// Task: CompFilterSetIaddr
	// Assigns a comparator for instruction address matching to a
	// filter in the control/status interface and activates match settings.
	// Parameters:
	//   cs_tip   - Virtual C‑Trace control/status interface.
	//   filter   - Filter index.
	//   comp     - Comparator index.
	//   comp_id  - Comparator assignment within filter.
	//   iaddr    - Instruction address to match.
	// Example usage:
	//   CompFilterSetIaddr(cs_tip, 1, 0, 1, 32'h2000);
	//   This configures filter 1 to use comparator 0 (assignment 1)
	//   to match instruction fetches from address 0x2000. Only
	//   instruction execution at this exact address will be traced.
	//------------------------------------------------------------------------
	task automatic CompFilterSetIaddr(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter, int comp, input int comp_id, tip_iaddr_t iaddr);

		cs_tip.trTeFilterMatchComp[filter]          = 3'h1;
		cs_tip.trTeFilterComp[filter][1]            = comp_id;
		cs_tip.trTeCompPInput[comp]                 = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_IADDR;
		cs_tip.trTeCompPFunction[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_EQUAL;
		cs_tip.trTeCompMatchMode[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0;
		cs_tip.trTeCompPMatchLow[comp]              = iaddr;
		cs_tip.trTeFilterEnable[filter]             = 1'h1;
		cs_tip.trTeInstFilters                      = cs_tip.trTeInstFilters | (16'h1 << filter);
	endtask

	//------------------------------------------------------------------------
	// Task: CompSetIaddr
	// Configures a primary comparator for instruction address matching.
	// Parameters:
	//   cs_tip   - Virtual C‑Trace control/status interface.
	//   comp     - Comparator index.
	//   mode     - comparator mode
	//                  ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_EQUAL
	//                  ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_NOT_EQUAL
	//                  ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_LESS
	//                  ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_LESS_EQUAL
	//                  ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_GREATER
	//                  ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_GREATER_EQUAL
	//                  ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_RESERVED_MATCH
	//                  ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_ALWAYS_MATCH
	//   iaddr    - Instruction address to match.
	// Example usage:
	//   CompSetIaddr(cs_tip, 0, 32'h2000);
	//   This configures comparator 0
	//   to match instruction fetches at address 0x2000.
	//------------------------------------------------------------------------
	task automatic CompSetIaddr(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int comp, tip_iaddr_t iaddr);

		cs_tip.trTeCompPInput[comp]                 = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_IADDR;
		cs_tip.trTeCompPFunction[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_EQUAL;
		cs_tip.trTeCompMatchMode[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0;
		cs_tip.trTeCompPMatchLow[comp]              = iaddr;
	endtask

	//------------------------------------------------------------------------
	// Task: CompSetMode3
	// Example usage:
	//   CompSetMode3(cs_tip, 1, 0, 1, 32'h2000);
	//   This configures filter 1 to use comparator 0 (assignment 1)
	//   to match all instruction fetches after executing address 0x2000 and before executing 0x3000 (inclusive).
	//------------------------------------------------------------------------
	task automatic CompSetMode3(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int comp, tip_iaddr_t p_iaddr, tip_iaddr_t s_iaddr);

		cs_tip.trTeCompPInput[comp]                 = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_IADDR;
		cs_tip.trTeCompPFunction[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_EQUAL;
		cs_tip.trTeCompPMatchLow[comp]              = p_iaddr;
		cs_tip.trTeCompSInput[comp]                 = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_IADDR;
		cs_tip.trTeCompSFunction[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompSFunction_e__TR_COMP_SFUNC_EQUAL;
		cs_tip.trTeCompSMatchLow[comp]              = s_iaddr;
		cs_tip.trTeCompMatchMode[comp]              = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_INPUT_MODE3;
	endtask

	//------------------------------------------------------------------------
	// Task: FilterSetInstComp
	// Example usage:
	//------------------------------------------------------------------------
	task automatic FilterSetInstComp(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter, int comp_id, int comp);

		cs_tip.trTeInstFilters[filter]                   = 1;
		cs_tip.trTeFilterEnable[filter]                  = 1;
		cs_tip.trTeFilterMatchComp[filter]              |= 3'h1 << comp_id;
		cs_tip.trTeFilterComp[filter][comp_id]           = comp;
	endtask

	//------------------------------------------------------------------------
	// Task: FilterSetDataComp
	// Example usage:
	//------------------------------------------------------------------------
	task automatic FilterSetDataComp(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter, int comp_id, int comp);

		cs_tip.trTeDataFilters[filter]                   = 1;
		cs_tip.trTeFilterEnable[filter]                  = 1;
		cs_tip.trTeFilterMatchComp[filter]              |= 3'h1 << comp_id;
		cs_tip.trTeFilterComp[filter][comp_id]           = comp;
	endtask

	//------------------------------------------------------------------------
	// Task: FilterSetEcause
	// Example usage:
	//------------------------------------------------------------------------
	task automatic FilterSetEcause(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter, tip_ecause_t ecause);

		cs_tip.trTeInstFilters[filter]                          = 1;
		cs_tip.trTeFilterEnable[filter]                         = 1;
		cs_tip.trTeFilterMatchEcause[filter]                    = 1;
		cs_tip.trTeFilterMatchChoiceEcauseLow[filter][ecause]   = 1;
	endtask

	//------------------------------------------------------------------------
	// Task: FilterSetDtype
	// Example usage:
	//------------------------------------------------------------------------
	task automatic FilterSetDtype(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter, tip_dtype_e dtype);

		// Dtype is a *data* sideband predicate => tie to DataFilters by default.
		// If you want it to qualify instruction tracing, call CompFilterInstEnable/FilterSetInstComp accordingly.
		cs_tip.trTeDataFilters[filter]                  = 1;
		cs_tip.trTeFilterEnable[filter]                 = 1;
		cs_tip.trTeFilterMatchDtype[filter]             = 1;
		// RDL defines this as a bitmap: bit N matches dtype=N
		cs_tip.trTeFilterMatchChoiceDtype[filter]       = '0;
		cs_tip.trTeFilterMatchChoiceDtype[filter][dtype]= 1'b1;
	endtask

	//------------------------------------------------------------------------
	// Task: FilterSetDsize
	// Example usage:
	//------------------------------------------------------------------------
	task automatic FilterSetDsize(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input int filter, tip_dsize_t dsize);

		// Dsize is a *data* sideband predicate => tie to DataFilters by default.
		cs_tip.trTeDataFilters[filter]                  = 1;
		cs_tip.trTeFilterEnable[filter]                 = 1;
		cs_tip.trTeFilterMatchDsize[filter]             = 1;
		// RDL defines this as a bitmap: bit N matches dsize=N
		cs_tip.trTeFilterMatchChoiceDsize[filter]       = '0;
		cs_tip.trTeFilterMatchChoiceDsize[filter][dsize]= 1'b1;
	endtask

	//------------------------------------------------------------------------
	// Task: CompFilterSetIaddrRange
	// Assigns a comparator for instruction address matching to a
	// filter in the control/status interface and activates match settings.
	// Parameters:
	//   cs_tip     - Virtual C‑Trace control/status interface.
	//   filter     - Filter index.
	//   comp_low   - Comparator low index.
	//   comp_high  - Comparator high index.
	//   iaddr_low  - Instruction low address to match.
	//   iaddr_high - Instruction high address to match.
	// Example usage:
	//   CompFilterSetIaddrRange(cs_tip, 0, 0, 1, 32'h1000, 32'h1100);
	//   This configures filter 0 to use comparator 0 and 1
	//   to match instruction fetches from address 0x1000 to 0x1100.
	//   Only instructions execution within this address range will be traced.
	//------------------------------------------------------------------------
	task automatic CompFilterSetIaddrRange(
		virtual ct_cs_tipclk_if.master	cs_tip,
		input   int                     filter,
				int                     comp_low,
				int                     comp_high,
				tip_iaddr_t             iaddr_low,
				tip_iaddr_t             iaddr_high);

		cs_tip.trTeFilterMatchComp[filter]          = 3'h3;         // use MatchComp1 and MatchComp2
		cs_tip.trTeFilterComp[filter][1]            = comp_low;     // MatchComp1 is assigned to comparator[comp_low]
		cs_tip.trTeFilterComp[filter][2]            = comp_high;    // MatchComp2 is assigned to comparator[comp_high]
		cs_tip.trTeCompPInput[comp_low]             = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_IADDR;
		cs_tip.trTeCompPInput[comp_high]            = ct_cs_cpuif__te__trTeComp__Control__trTeCompInput_e__TR_COMP_INPUT_IADDR;
		cs_tip.trTeCompPFunction[comp_low]          = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_GREATER_EQUAL;
		cs_tip.trTeCompPFunction[comp_high]         = ct_cs_cpuif__te__trTeComp__Control__trTeCompPFunction_e__TR_COMP_PFUNC_LESS_EQUAL;
		cs_tip.trTeCompMatchMode[comp_low]          = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0;
		cs_tip.trTeCompMatchMode[comp_high]         = ct_cs_cpuif__te__trTeComp__Control__trTeCompMatchMode_e__TR_COMP_MATCH_MODE0;
		cs_tip.trTeCompPMatchLow[comp_low]          = iaddr_low;
		cs_tip.trTeCompPMatchLow[comp_high]         = iaddr_high;
		cs_tip.trTeFilterEnable[filter]             = 1'h1;
		cs_tip.trTeInstFilters                      = cs_tip.trTeInstFilters | (16'h1 << filter);
	endtask

endpackage
