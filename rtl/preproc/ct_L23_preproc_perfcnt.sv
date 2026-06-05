// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * Address: Kiefersfelden, Germany
 *
 * @file    ct_L23_preproc_perfcnt.sv
 * @brief   Accemic C-Trace performance counter preprocessing unit.
 *
 * @description
 *   This module implements a preprocessing unit for performance counter measurement
 *   within the C-Trace architecture. It tracks read and write accesses to data address
 *   ranges and fetches within instruction address ranges.
 *   Internal counters are instantiated for each monitored range, counting hits and misses,
 *   with saturation mode for overflow protection. Threshold handling and range selection
 *   logic enable detailed latency and range-specific statistics collection.
 *   Synchronous reset and clear signals maintain precise counter states.
 *
 * @tparam IADDR_RANGES    Number of instruction address ranges monitored.
 * @tparam DADDR_RANGES    Number of data address ranges monitored.
 *
 * @ports
 *   clk                  Trace input clock.
 *   rst                  Synchronous reset.
 *   tip                  TIP interface for retired data stream from CPU.
 *   cs_tip               Control/status interface in TIP clock domain.
 *   perfcnt              Performance counter output interface with range-specific values and control signals.
 *   internal_delay        Pipeline/processing delay of the module and submodules.
 *
 * @notes
 *   - Each access type (read, write, instruction fetch) is matched against configured address ranges.
 *   - Counters operate in saturation mode; no wrapping is performed on overflow.
 *   - Internal clear and reset signals ensure robust, glitch-free operation.
 *   - No mode or option for down-counting; all counters increment only.
 *   - Module is designed for integration into C-Trace stage 2 preprocessing of performance metrics.
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

module ct_L23_preproc_perfcnt
	import tip_pkg::*;
	import ct_pkg::*;
	import counter_pkg::*;
	import ct_cs_cpuif_pkg::*;
#(  int IADDR_RANGES = 4,
	int DADDR_RANGES = 4
)(  input uwire logic           clk,                    // trace input clock
	input uwire logic           rst,                    // reset
	tip_if.slave                tip,                    // TIP from CPU
	ct_cs_tipclk_if.slave       cs_tip,                 // control / status interface
	ct_perfcnt_if.master        perfcnt,
	output delay_t              internal_delay          // delay of this component including all submodules
);

	//----------------------------------------------------------------------------
	// Data access performance
	// count reads/writes within / outside daddr ranges
	// count of [clock cycles per read access above threshold] per range
	//----------------------------------------------------------------------------

	logic [7:0] IThCnt, DThCnt;

	typedef enum logic [1:0] {
		TH_IDLE         = 0,
		TH_CNT_IRETIRE  = 1,
		TH_ITH_OVERFLOW = 2
	} th_state_e;

	th_state_e ThState = TH_IDLE;

	// this sm prevents multiple identical ThCnt values within a single dretire cycle
	always_ff @(posedge clk) begin
		if (rst) begin
			DThCnt      <= '0;
			IThCnt      <= '0;
			ThState    <= TH_IDLE;
		end
		else begin
			case (ThState)
				TH_IDLE: begin
					if (tip.iretire) begin
						DThCnt      <= '0;
						IThCnt      <= '0;
					end
					else if (tip.dretire) begin
						IThCnt      <= '0;
						DThCnt      <= '0;
						ThState    <= TH_CNT_IRETIRE;
					end
					else begin
						IThCnt      <= IThCnt+1;
						DThCnt      <= DThCnt+1;
						if (IThCnt == '1) begin
							ThState <= TH_ITH_OVERFLOW;
						end
					end
				end
				TH_CNT_IRETIRE: begin               // count cycles bewteen dretire nad next iretire
					IThCnt  <= IThCnt+1;
					if (tip.iretire) begin
						ThState    <= TH_IDLE;
					end
					else begin
						if (IThCnt == '1) begin
							ThState <= TH_ITH_OVERFLOW;
						end
					end
				end
				TH_ITH_OVERFLOW: begin                  // wait for next dretire after DThCnt overflow
					if (tip.dretire) begin
						ThState    <= TH_IDLE;
					end
				end
				default begin
					ThState    <= TH_IDLE;
				end
			endcase
		end
	end

	generate

		// RD
		begin: gen_rd
			typedef tip_daddr_t T;
			localparam int  N           = NUM_PERFCNT_DATA_RD_RANGES;
			uwire logic     valid       = tip.dretire && (tip.dtype == LOAD);
			uwire T         data_in     = tip.daddr;
			uwire T [N:0]   refs_low    = cs_tip.trTePerfCntDataRdRangeLow;
			uwire T [N:0]   refs_high   = cs_tip.trTePerfCntDataRdRangeHigh;

			uwire logic hit, no_hit;
			uwire logic [$clog2(N)-1:0] hit_index;
			if (N>0) begin
				perfcnt_range_unit #(.T(T), .N(N+1), .EXTRA_DELAY(0)) perfcnt_range_unit_rd_inst (
					.clk, .rst, .valid, .data_in, .refs_low, .refs_high, .hit, .no_hit, .hit_index
				);
				for (genvar i = 0; i <= N; i++) begin
					counter_if #(.T(T)) cnt_rd ();
					counter #(.T(T), .MODE(MODE_SATURATION)) cnt_rd_inst (.clk, .rst, .cnt (cnt_rd));
					assign cnt_rd.inc = (i < N) ? hit && (hit_index == i) : no_hit;
					assign cnt_rd.dec = '0;
					assign cnt_rd.add = '0;
					assign cnt_rd.overflow_value  = '1;
					assign cnt_rd.clr = perfcnt.data_rd_counter_clr_axis[i] || perfcnt.data_rd_counter_clr_etip[i];
					assign perfcnt.data_rd_counter_value[i] = cnt_rd.value;
				end
			end
		end

		// WR
		begin: gen_wr
			typedef tip_daddr_t T;
			localparam int  N           = NUM_PERFCNT_DATA_WR_RANGES;
			uwire logic     valid       = tip.dretire && (tip.dtype == STORE);
			uwire T         data_in     = tip.daddr;
			uwire T [N:0]   refs_low    = cs_tip.trTePerfCntDataWrRangeLow;
			uwire T [N:0]   refs_high   = cs_tip.trTePerfCntDataWrRangeHigh;

			uwire logic hit, no_hit;
			uwire logic [$clog2(N)-1:0] hit_index;

			if (N>0) begin
				perfcnt_range_unit #(.T(T), .N(N+1), .EXTRA_DELAY(0)) perfcnt_range_unit_rd_inst (
					.clk, .rst, .valid, .data_in, .refs_low, .refs_high, .hit, .no_hit, .hit_index
				);
				for (genvar i = 0; i <= N; i++) begin
					counter_if #(.T(T)) cnt_wr ();
					counter #(.T(T), .MODE(MODE_SATURATION)) cnt_wr_inst (.clk, .rst, .cnt (cnt_wr));
					assign cnt_wr.inc = (i < N) ? hit && (hit_index == i) : no_hit;
					assign cnt_wr.dec = '0;
					assign cnt_wr.add = '0;
					assign cnt_wr.overflow_value  = '1;
					assign cnt_wr.clr = perfcnt.data_wr_counter_clr_axis[i] || perfcnt.data_wr_counter_clr_etip[i];
					assign perfcnt.data_wr_counter_value[i] = cnt_wr.value;
				end
			end
		end

		// IFETCH_TH
		begin: gen_ifetch_th
			typedef tip_iaddr_t T;
			localparam int N            = NUM_PERFCNT_IFETCH_TH_RANGES;
			uwire logic     valid       = tip.iretire && (IThCnt == cs_tip.trPcIFetchThreshold);
			uwire T         data_in     = tip.iaddr;
			uwire T [N:0]   refs_low    = cs_tip.trTePerfCntIFetchRangeLow;
			uwire T [N:0]   refs_high   = cs_tip.trTePerfCntIFetchRangeHigh;

			uwire logic hit, no_hit;
			uwire logic [$clog2(N)-1:0] hit_index;

			if (N>0) begin
				perfcnt_range_unit #(.T(T), .N(N+1), .EXTRA_DELAY(0)) perfcnt_range_unit_ifetch_th_inst (
					.clk, .rst, .valid, .data_in, .refs_low, .refs_high, .hit, .no_hit, .hit_index
				);
				for (genvar i = 0; i <= N; i++) begin
					counter_if #(.T(T)) cnt_ifetch_th ();
					counter #(.T(T), .MODE(MODE_SATURATION)) cnt_ifetch_th_inst(.clk, .rst, .cnt (cnt_ifetch_th));
					assign cnt_ifetch_th.inc = (i < N) ? hit && (hit_index == i) : no_hit;
					assign cnt_ifetch_th.dec = '0;
					assign cnt_ifetch_th.add = '0;
					assign cnt_ifetch_th.overflow_value  = '1;
					assign cnt_ifetch_th.clr = perfcnt.ifetch_th_counter_clr_axis[i] || perfcnt.ifetch_th_counter_clr_etip[i];
					assign perfcnt.ifetch_th_counter_value[i] = cnt_ifetch_th.value;
				end
			end
		end

		// RD_TH
		begin: gen_rd_th
			typedef tip_daddr_t T;
			localparam int  N           = NUM_PERFCNT_DATA_RD_TH_RANGES;
			uwire logic     valid       = tip.dretire && (tip.dtype == LOAD) && (DThCnt == cs_tip.trPcDataRdThreshold);  // TODO Add threshold
			uwire T         data_in     = tip.daddr;
			uwire T [N:0]   refs_low    = cs_tip.trTePerfCntDataRdThRangeLow;
			uwire T [N:0]   refs_high   = cs_tip.trTePerfCntDataRdThRangeHigh;

			uwire logic hit, no_hit;
			uwire logic [$clog2(N)-1:0] hit_index;

			if (N>0) begin
				perfcnt_range_unit #(.T(T), .N(N+1), .EXTRA_DELAY(0)) perfcnt_range_unit_rd_inst (
						.clk, .rst, .valid, .data_in, .refs_low, .refs_high, .hit, .no_hit, .hit_index
					);
				for (genvar i = 0; i <= N; i++) begin: rd_th_inst
					counter_if #(.T(T)) cnt_rd_th ();
					counter #(.T(T), .MODE(MODE_SATURATION)) cnt_rd_th_inst (.clk, .rst, .cnt (cnt_rd_th));
					assign cnt_rd_th.inc = (i < N) ? hit && (hit_index == i) : no_hit;
					assign cnt_rd_th.dec = '0;
					assign cnt_rd_th.add = '0;
					assign cnt_rd_th.overflow_value = '1;
					assign cnt_rd_th.clr = perfcnt.data_rd_th_counter_clr_axis[i] || perfcnt.data_rd_th_counter_clr_etip[i];
					assign perfcnt.data_rd_th_counter_value[i] = cnt_rd_th.value;
				end
			end
		end
	endgenerate

	assign  internal_delay = 1;

endmodule // ct_L23_preproc_perfcnt

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
