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

package ct_perfcnt_pkg;

	import tip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;

	//------------------------------------------------------------------------
	// Performance Counter and Comparator /Filter Helper
	//------------------------------------------------------------------------
	// Example usage:
	// The following example configures the C‑Trace control/status interface
	// to count all instructions executed within the address range
	// from 0x1000 to 0x1100.
	//
	// PerfCntInit(cs_tip);
	// PerfCntSetRange(cs_tip, INSTR_FETCH_TH, 0, 32'h1000, 32'h1100);
	//
	// At runtime, the C‑Trace will now count all instructions fetched
	// from addresses between 0x1000 and 0x1100 (inclusive).
	//------------------------------------------------------------------------

	//------------------------------------------------------------------------
	// Task: PerfCntInit
	// Initializes all performance counter range registers
	// (read, write, instruction fetch, and data read thresholds)
	// to zero in the connected C‑Trace control/status interface.
	// Parameter:
	//   cs_tip - Virtual C‑Trace control/status interface.
	// Example usage:
	//   PerfCntInit(cs_tip);
	//   This call resets all performance counter ranges to 0x0,
	//   effectively disabling all address-based performance
	//   counting until ranges are explicitly configured.
	//------------------------------------------------------------------------
	task automatic PerfCntInit (
		virtual ct_cs_tipclk_if.master	cs_tip);

		for (int i = 0; i < NUM_PERFCNT_DATA_RD_RANGES; i++) begin
			cs_tip.trTePerfCntDataRdRangeLow[i]  = '0;
			cs_tip.trTePerfCntDataRdRangeHigh[i] = '0;
		end
		for (int i = 0; i < NUM_PERFCNT_DATA_WR_RANGES; i++) begin
			cs_tip.trTePerfCntDataWrRangeLow[i]  = '0;
			cs_tip.trTePerfCntDataWrRangeHigh[i] = '0;
		end
		for (int i = 0; i < NUM_PERFCNT_IFETCH_TH_RANGES; i++) begin
			cs_tip.trTePerfCntIFetchRangeLow[i]  = '0;
			cs_tip.trTePerfCntIFetchRangeHigh[i] = '0;
		end
		for (int i = 0; i < NUM_PERFCNT_DATA_RD_TH_RANGES; i++) begin
			cs_tip.trTePerfCntDataRdThRangeLow[i]  = '0;
			cs_tip.trTePerfCntDataRdThRangeHigh[i] = '0;
		end
	endtask

	//------------------------------------------------------------------------
	// Task: PerfCntSetRange
	// Sets the lower and upper address limits of a specific
	// performance counter range in the connected C‑Trace
	// control/status interface for a selected counter type.
	// Parameters:
	//   cs_tip        - Virtual C‑Trace control/status interface.
	//   perfcnt_type  - Counter type (DATA_RD, DATA_WR,
	//                   DATA_RD_TH, INSTR_FETCH_TH).
	//   idx           - Index of the range (must be valid).
	//   range_low     - Lower address boundary.
	//   range_high    - Upper address boundary.
	// Example usage:
	//   PerfCntSetRange(cs_tip, DATA_RD, 0, 32'h1000, 32'h1FFF);
	//   This configuration enables counter 0 to count all
	//   data read accesses in the address range from 0x1000
	//   to 0x1FFF (inclusive). Every read operation to an address
	//   within this range will increment counter 0.
	//------------------------------------------------------------------------
	task automatic PerfCntSetRange (
		virtual ct_cs_tipclk_if.master	cs_tip,
		input ct_perfcnt_type_e perfcnt_type,
			  integer     idx,
			  tip_xaddr_t range_low,
			  tip_xaddr_t range_high);

		case (perfcnt_type)
			DATA_RD: begin
				if (idx >= NUM_PERFCNT_DATA_RD_RANGES) begin
					$error("NUM_PERFCNT_DATA_RD_RANGES > idx"); $finish();
				end
				cs_tip.trTePerfCntDataRdRangeLow[idx]  = tip_daddr_t' (range_low);
				cs_tip.trTePerfCntDataRdRangeHigh[idx] = tip_daddr_t' (range_high);
			end
			DATA_WR: begin
				if (idx >= NUM_PERFCNT_DATA_WR_RANGES) begin
					$error("NUM_PERFCNT_DATA_WR_RANGES > idx"); $finish();
				end
				cs_tip.trTePerfCntDataWrRangeLow[idx]  = tip_daddr_t' (range_low);
				cs_tip.trTePerfCntDataWrRangeHigh[idx] = tip_daddr_t' (range_high);
			end
			DATA_RD_TH: begin
				if (idx >= NUM_PERFCNT_DATA_RD_TH_RANGES) begin
					$error("NUM_PERFCNT_DATA_RD_TH_RANGES > idx"); $finish();
				end
				cs_tip.trTePerfCntDataRdThRangeLow[idx]  = tip_daddr_t' (range_low);
				cs_tip.trTePerfCntDataRdThRangeHigh[idx] = tip_daddr_t' (range_high);
			end
			INSTR_FETCH_TH: begin
				if (idx >= NUM_PERFCNT_IFETCH_TH_RANGES) begin
					$error("NUM_PERFCNT_IFETCH_TH_RANGES > idx"); $finish();
				end
				cs_tip.trTePerfCntIFetchRangeLow[idx]  = tip_iaddr_t' (range_low);
				cs_tip.trTePerfCntIFetchRangeHigh[idx] = tip_iaddr_t' (range_high);
			end
		endcase
	endtask

endpackage
