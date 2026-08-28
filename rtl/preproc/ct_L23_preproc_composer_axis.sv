// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder layer 2/3 AXIS composer (internal trace/instrumentation sink).
 *
 * @details
 *   Composes the AXI-Stream output that serves as an internal trace and
 *   instrumentation sink for the preprocessing stage.
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import ct_cs_cpuif_pkg::*;
import ct_cs_cpuif_types_pkg::*;
import ct_pkg::*;
import tip_pkg::*;

module ct_L23_preproc_composer_axis (
	input uwire logic        clk,      // trace input clock
	input uwire logic        rst,      // reset
	input uwire tip_time_t   ts_value, // selected timestamp from timestamp unit
	ct_act_cap_if.slave      act_cap_st,
	tip_if.slave             tip,
	ct_perfcnt_if.slave_axis perfcnt,
	axis_if.master           axis, // (wide) AXI Stream to watchdog CPU
	output delay_t           internal_delay
);

	localparam TDATA_WIDTH  = axis.TDATA_WIDTH;
	localparam TSTRB_WIDTH  = axis.TSTRB_WIDTH;
	localparam NUM_ELEMENTS = TDATA_WIDTH / ACT_CAP_DATA_WIDTH;

	// ----------------------------------------------------------------
	// Profile guards (C0a): the AXIS timestamp element is meaningless
	// without the timestamp unit (ts_value would be a constant 0 marked
	// valid), and the AXIS sink itself is fed exclusively by the ACT-CAP
	// command path (same elaboration-$fatal pattern as the etip
	// composer's watchpoint guard).
	// ----------------------------------------------------------------
	if (CT_EN_AXIS_TS && !CT_EN_TIMESTAMP) begin : genAxisTsNeedsTs
		$fatal(1, "ct_L23_preproc_composer_axis: CT_EN_AXIS_TS requires CT_EN_TIMESTAMP (ts_value has no source without the timestamp unit)");
		// Structural poison (C0a audit B-1): abc hard-wires -Wno-fatal into
		// every Verilator run, demoting the $fatal above to %Warning-USERFATAL.
		// An undeclared module in the taken branch fails elaboration on
		// EVERY backend; the branch is pruned in legal configurations.
		ct_elab_guard_violation poison ();
	end
	if (CT_EN_AXIS_TS && !CT_EN_ACT) begin : genAxisTsNeedsAct
		$fatal(1, "ct_L23_preproc_composer_axis: CT_EN_AXIS_TS requires CT_EN_ACT (the AXIS sink is fed by the ACT-CAP command path)");
		ct_elab_guard_violation poison (); // see genAxisTsNeedsTs
	end

	logic                               Valid;
	logic [ACT_CAP_DATA_WIDTH-1:0]      DataElements[NUM_ELEMENTS-1:0];
	logic [TSTRB_WIDTH-1:0]             Strb;

	typedef logic [axis.TID_WIDTH-1:0]  Id_t;

	Id_t                                Id;
	logic [ACT_CAP_DATA_WIDTH-1:0]      DirectDataElem;

	tip_iaddr_t                         PrevIAddr;                      // previous iaddr
	tip_iaddr_t                         LastIAddrBeforeException;       // last iaddr before exception or interrupt
	tip_daddr_t                         PrevDAddr;                      // previous daddr
	tip_data_t                          PrevData;                       // previous data
	tip_dtype_dsize_t                   PrevDtypeDsize;

	assign DirectDataElem = {{(ACT_CAP_DATA_WIDTH-24){1'b0}}, act_cap_st.cmd.DirectData.value};

	always_ff @(posedge clk) begin
		Valid <= 0;
		if (rst) begin
		  PrevIAddr                 <= '0;
		  PrevDAddr                 <= '0;
		  PrevData                  <= '0;
		  PrevDtypeDsize            <= '0;
		  LastIAddrBeforeException  <= '0;
		end
		else begin
			perfcnt.data_rd_counter_clr_axis     <= '0;
			perfcnt.data_wr_counter_clr_axis     <= '0;
			perfcnt.data_rd_th_counter_clr_axis  <= '0;
			perfcnt.ifetch_th_counter_clr_axis   <= '0;

			if (tip.iretire) begin
				PrevIAddr <= tip.iaddr;
				if ((tip.itype == EXCEPTION_TRAP) || (tip.itype == INTERRUPT)) begin
					LastIAddrBeforeException <= PrevIAddr;
				end
			end
			if (tip.dretire) begin
				PrevDAddr       <= tip.daddr;
				PrevData        <= tip.data;
				PrevDtypeDsize  <= {tip.dtype, tip.dsize};
			end

			if (   (act_cap_st.valid)
				&& (  (act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS)
					||(act_cap_st.cmd.Sink.value == ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS))) begin
					Valid  <= 1;
					Id     <= Id_t'(act_cap_st.cmd.Cmd.value);
				// see ct_cs_cpuif.trActCapStCmd (RDL addrmap) for Cmd details
				case (act_cap_st.cmd.Cmd.value)
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR: begin
						DataElements[0] <= tip.iaddr;
						DataElements[1] <= DirectDataElem;
						if (CT_EN_AXIS_TS) begin
							// C0a: element 2 = the selected timestamp
							// (ts_value, i.e. trTsControl.Type/Active/
							// Count/Prescale -- NOT the delayed
							// tip._time), so both sinks of an AXIS_NEXUS
							// command carry the same time base as the
							// eTIP composer's TSTAMP.
							DataElements[2] <= ts_value[31:0];
							Strb            <= 12'hFFF;
						end
						else begin
							Strb            <= 8'hFF;
						end
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR_LAST: begin
						DataElements[0] <= tip.iaddr;
						DataElements[1] <= LastIAddrBeforeException;
						DataElements[2] <= DirectDataElem;
						Strb            <= 12'hFFF;
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA: begin
						DataElements[0] <= act_cap_st.cmd.DirectData.value;
						Strb            <= 4'hF;
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA: begin
						DataElements[0] <= PrevData;
						DataElements[1] <= PrevDtypeDsize;
						Strb            <= 8'hFF;
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR: begin
						DataElements[0] <= PrevDAddr;
						DataElements[1] <= PrevDtypeDsize;
						Strb            <= 8'hFF;
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR: begin
						DataElements[0] <= PrevData;
						DataElements[1] <= PrevDAddr;
						DataElements[2] <= PrevDtypeDsize;
						Strb            <= 12'hFFF;
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0] <=  NUM_PERFCNT_DATA_RD_RANGES) begin
							DataElements[0] <= perfcnt.data_rd_counter_value[act_cap_st.cmd.DirectData.value][NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0];
							Strb            <= 4'hF;
							perfcnt.data_rd_counter_clr_axis[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_RANGES_WIDTH:0]] <= '1;
						end
						else begin
							// Selector out of range: the beat is NOT suppressed and
							// not reported -- Valid was already raised above and
							// DataElements/Strb keep the previous beat's contents.
							// Named limitation, see doc/release-notes.adoc
							// ("ACT-CAP counter selector out of range").
						end
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_WR: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0] <=  NUM_PERFCNT_DATA_WR_RANGES) begin
							DataElements[0] <= perfcnt.data_wr_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0]];
							Strb            <= 0 | 4'hF;
							perfcnt.data_wr_counter_clr_axis[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_WR_RANGES_WIDTH:0]] <= '1;
						end
						else begin
							// Selector out of range: the beat is NOT suppressed and
							// not reported -- Valid was already raised above and
							// DataElements/Strb keep the previous beat's contents.
							// Named limitation, see doc/release-notes.adoc
							// ("ACT-CAP counter selector out of range").
						end
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_IFETCH_TH: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0]  <=  NUM_PERFCNT_IFETCH_TH_RANGES) begin
							DataElements[0] <= perfcnt.ifetch_th_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0] ];
							Strb            <= 0 | 4'hF;
							perfcnt.ifetch_th_counter_clr_axis[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH:0] ] <= '1;
						end
						else begin
							// Selector out of range: the beat is NOT suppressed and
							// not reported -- Valid was already raised above and
							// DataElements/Strb keep the previous beat's contents.
							// Named limitation, see doc/release-notes.adoc
							// ("ACT-CAP counter selector out of range").
						end
					end
					ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD_TH: begin
						if (act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0] <=  NUM_PERFCNT_DATA_RD_TH_RANGES) begin
							DataElements[0] <= perfcnt.data_rd_th_counter_value[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0]];
							Strb            <= 0 | 4'hF;
							perfcnt.data_rd_th_counter_clr_axis[act_cap_st.cmd.DirectData.value[NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH:0]] <= '1;
						end
						else begin
							// Selector out of range: the beat is NOT suppressed and
							// not reported -- Valid was already raised above and
							// DataElements/Strb keep the previous beat's contents.
							// Named limitation, see doc/release-notes.adoc
							// ("ACT-CAP counter selector out of range").
						end
					end
					default: begin
						Valid   <= 0;
					end
				endcase
			end
		end
	end

	assign axis.tvalid  = Valid;
	assign axis.tstrb   = Strb;
	assign axis.tid     = Id;

	for (genvar i = 0; i < NUM_ELEMENTS; i++) begin : g_tdata_pack
		assign axis.tdata[i*ACT_CAP_DATA_WIDTH +: ACT_CAP_DATA_WIDTH] = DataElements[i];
	end
	assign internal_delay   = 1;

endmodule

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
