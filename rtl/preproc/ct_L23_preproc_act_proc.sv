// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author   Albert Schulz <aschulz@accemic.com>
* @author   Alexander Lange <alange@accemic.com>
*
* @brief    Accemic C-Trace Hardware Supported Instrumentation Processor
*			- merges ACT_CAP and ACT_ST commands
*			- ACT_ST overrides ACT_CAP in the same instruction
*			  (subsequent neutralization of the effect of ACT-CAP instrumentation)
*			- ACT processor initiates
*				- emission of configurable DAQ messages
*				- extra sync message
*				- write access to selected TE control registers
*/

`undef	MY_DEBUG
`ifdef	MY_DEBUG
`define	MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define	MY_MARK_DEBUG
`endif

import tip_pkg::*;
import ct_pkg::*;
import ct_cs_cpuif_pkg::*;
import ct_cs_cpuif_types_pkg::*;
import nexus_vendor::*;

module ct_L23_preproc_act_proc (
	input uwire logic 			clk, 				// trace input clock
	input uwire logic 			rst,				// reset

	// Input / Output
	ct_act_cap_if.slave			act_cap,
	ct_act_cap_if.slave			act_st,
	ct_act_cap_if.master		act_cap_st,
	// Local control
	ct_cs_tipclk_if.slave		cs_tip,					// control / status interface
	output delay_t           	internal_delay,         // delay of this component including all submodules
	input uwire delay_t			extra_delay             // extra delay to be added for syncronizing preproc modules
);

	typedef struct {
		logic							valid;
		ct_cs_cpuif__trActCapStCmd__out_t 	cmd;
		ct_act_cap_data_t				data;
		// ct_act_cap_if defines addr as ct_act_cap_data_t
		ct_act_cap_data_t				addr;
	} act_proc_struct_t;

	act_proc_struct_t 					ActProcPipe [EXTRA_DELAY_MAX:0];
	ct_act_cap_te_t						act_cap_te;
	ct_act_cap_data_t					act_cap_data;
	ct_act_cap_data_t					act_cap_addr;
	ct_cs_cpuif__trActCapStCmd__out_t 		act_cap_cmd;
	logic								act_cap_cmd_valid;

	always_comb begin
		act_cap_cmd_valid 	 			= '0;
		act_cap_cmd 						= '{default:'0};
		act_cap_data 						= '{default:'0};
		act_cap_addr						= '{default:'0};
		if (act_st.valid && !rst) begin
			act_cap_cmd_valid	= 1;
			act_cap_cmd 		= act_st.cmd;
			act_cap_data 		= act_st.data;
			act_cap_addr		= act_st.addr;
		end
		else if (act_cap.valid && !rst) begin
			act_cap_cmd_valid	= 1;
			act_cap_cmd 		= act_cap.cmd;
			act_cap_data 		= act_cap.data;
			act_cap_addr		= act_cap.addr;
		end
		act_cap_te = ct_act_cap_te_t'(act_cap_cmd.DirectData.value);
	end

	always_ff @(posedge clk) begin

		cs_tip.trTeDataTracingSet 	<= 0;
		cs_tip.trTeDataTracingClr 	<= 0;
		cs_tip.trTeInstTracingSet 	<= 0;
		cs_tip.trTeInstTracingClr 	<= 0;

		if (rst) begin
			foreach (ActProcPipe[i]) begin
				ActProcPipe[i].valid <= 1'b0;
			end
		end
		else begin
			ActProcPipe[0].valid <= 1'b0;
			if (act_cap_cmd_valid) begin
				case (act_cap_cmd.Sink.value)
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS,					// send AXIS
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS: begin
					case (act_cap_cmd.Cmd.value)
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR_LAST,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_IFETCH_TH,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD_TH,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_WR,
						ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD: begin
							ActProcPipe[0].valid <= 1;
							ActProcPipe[0].cmd   <= act_cap_cmd;
							ActProcPipe[0].data  <= act_cap_data;
							ActProcPipe[0].addr  <= act_cap_addr;
						end
					default: begin
					end
					endcase
				end
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_TE: begin 			// set TE register
					case (act_cap_te.ctrl)
					ACT_CAP_TE_INSTR_TRACING: begin
						cs_tip.trTeInstTracingSet  <= act_cap_te.data[0] ? 1 : 0;
						cs_tip.trTeInstTracingClr  <= act_cap_te.data[0] ? 0 : 1;
					end
					ACT_CAP_TE_DATA_TRACING: begin
						cs_tip.trTeDataTracingSet  <= act_cap_te.data[1] ? 1 : 0;
						cs_tip.trTeDataTracingClr  <= act_cap_te.data[1] ? 0 : 1;
					end
					default: begin
					end
					endcase
				end
				default: begin
					// TODO error
				end
				endcase
			end
		end
		// shift through remaining stages
		for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
			ActProcPipe[idx] <= ActProcPipe[idx-1];
		end
	end

	assign act_cap_st.valid = ActProcPipe[extra_delay].valid;
	assign act_cap_st.cmd   = ActProcPipe[extra_delay].cmd;
	assign act_cap_st.data  = ActProcPipe[extra_delay].data ;
	assign act_cap_st.addr  = ActProcPipe[extra_delay].addr ;

	assign internal_delay = 1;

endmodule // ct_L23_preproc_act_proc

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
