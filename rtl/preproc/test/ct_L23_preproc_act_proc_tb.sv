// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_L23_preproc_act_proc_tb.sv
 * @brief   Directed routing and TE side-effect testbench for ct_L23_preproc_act_proc.
 * @details Validates ACT_ST priority over ACT_CAP, DAQ forwarding to
 *   act_cap_st, dropping of unsupported commands, and trace-enable side
 *   effects on cs_tip.
 * @stimulus Drives simultaneous ACT_CAP and ACT_ST inputs, AXIS-routed and
 *   unsupported commands, and TE set/clear operations for instruction and
 *   data tracing.
 * @checking Compares act_cap_st outputs against a queue-based scoreboard and
 *   verifies cs_tip trace-enable pulses against an expected TE-event queue.
 * @scoring Separate output and TE expectation queues must drain before the
 *   testbench finishes.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_act_proc_tb;

	import tt::*;
	import tip_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import nexus_vendor::*;

	localparam time TIP_CLK_PERIOD = 1.0;
	localparam delay_t EXTRA_DELAY = 2;

	logic tip_clk = 0;
	always #(TIP_CLK_PERIOD/2.0) tip_clk = ~tip_clk;

	logic tip_rst;

	// Interfaces
	ct_act_cap_if act_cap();
	ct_act_cap_if act_st();
	ct_act_cap_if act_cap_st();
	ct_cs_tipclk_if cs_tip();

	delay_t internal_delay;

	// DUT
	ct_L23_preproc_act_proc dut (
		.clk (tip_clk),
		.rst (tip_rst),
		.act_cap,
		.act_st,
		.act_cap_st,
		.cs_tip,
		.internal_delay,
		.extra_delay (EXTRA_DELAY)
	);

	// --------------------------------------------------------------------
	// Scoreboards
	// --------------------------------------------------------------------
	// NOTE: keep this as an *unpacked* struct because cmd/data/addr types may
	// contain unpacked members (Vivado disallows unpacked members in packed structs).
	typedef struct {
		ct_cs_cpuif__trActCapStCmd__out_t cmd;
		ct_act_cap_data_t            data;
		// ct_act_cap_if defines addr as ct_act_cap_data_t
		ct_act_cap_data_t            addr;
	} exp_out_t;

	exp_out_t exp_out_q[$];

	typedef enum int {
		TE_INST_SET,
		TE_INST_CLR,
		TE_DATA_SET,
		TE_DATA_CLR
	} exp_te_kind_e;

	exp_te_kind_e exp_te_q[$];

	// --------------------------------------------------------------------
	// Helpers
	// --------------------------------------------------------------------
	// We intentionally accept sink/cmd as plain integers (enum values) to avoid
	// depending on internal enum type names (which can differ between PeakRDL generations).
	task automatic set_cmd(
		output ct_cs_cpuif__trActCapStCmd__out_t c,
		input  int sink_value,
		input  int cmd_value,
		input  ct_act_cap_te_t te
	);
		// Vivado treats ct_cs_cpuif__trActCapStCmd__out_t as an *unpacked* type,
		// so assigning a packed literal ('0) is rejected.
		c = '{default:'0};
		c.Sink.value       = sink_value;
		c.Cmd.value        = cmd_value;
		c.DirectData.value = te;
	endtask

		task automatic drive_cap(
		input bit                        is_st,
		input ct_cs_cpuif__trActCapStCmd__out_t cmd,
		input ct_act_cap_data_t           data,
		input ct_act_cap_data_t           addr
	);
		if (is_st) begin
			act_st.valid <= 1'b1;
			act_st.cmd   <= cmd;
			act_st.data  <= data;
			act_st.addr  <= addr;
		end else begin
			act_cap.valid <= 1'b1;
			act_cap.cmd   <= cmd;
			act_cap.data  <= data;
			act_cap.addr  <= addr;
		end
	endtask

	task automatic clear_inputs();
		act_cap.valid <= 1'b0;
		act_st.valid  <= 1'b0;
		act_cap.cmd   <= '{default:'0};
		act_st.cmd    <= '{default:'0};
		act_cap.data  <= '{default:'0};
		act_st.data   <= '{default:'0};
		act_cap.addr  <= '{default:'0};
		act_st.addr   <= '{default:'0};
	endtask

	// --------------------------------------------------------------------
	// Stimulus
	// --------------------------------------------------------------------
	initial begin
		clear_inputs();
		tip_rst <= 1'b1;
		repeat (3) @(posedge tip_clk);
		tip_rst <= 1'b0;
		repeat (2) @(posedge tip_clk);

		// (1) Priority test: ACT_ST overrides ACT_CAP in same cycle
		begin
			ct_act_cap_te_t te0;
			ct_cs_cpuif__trActCapStCmd__out_t cmd_cap;
			ct_cs_cpuif__trActCapStCmd__out_t cmd_st;
			ct_act_cap_data_t data_cap;
			ct_act_cap_data_t data_st;
			ct_act_cap_addr_t addr_cap;
			ct_act_cap_addr_t addr_st;

			te0 = '0;
			set_cmd(cmd_cap,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS,
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR,
				te0);
			set_cmd(cmd_st,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS,
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR,
				te0);

			data_cap = 'hCA11;
			addr_cap = 'h10;
			data_st  = 'hBEEF;
			addr_st  = 'h22;

			drive_cap(0, cmd_cap, data_cap, addr_cap);
			drive_cap(1, cmd_st,  data_st,  addr_st);
			exp_out_q.push_back('{cmd:cmd_st, data:data_st, addr:addr_st});
			@(posedge tip_clk);
			clear_inputs();
		end

		// (2) CAP forward DAQ (AXIS)
		begin
			ct_act_cap_te_t te0;
			ct_cs_cpuif__trActCapStCmd__out_t cmd;
			ct_act_cap_data_t data;
			ct_act_cap_addr_t addr;
			te0 = '0;
			set_cmd(cmd,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS,
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA,
				te0);
			data = 'h1234;
			addr = 'h33;
			drive_cap(0, cmd, data, addr);
			exp_out_q.push_back('{cmd:cmd, data:data, addr:addr});
			@(posedge tip_clk);
			clear_inputs();
		end

		// (3) Drop unsupported command (AXIS sink but TE cmd)
		begin
			ct_act_cap_te_t te0;
			ct_cs_cpuif__trActCapStCmd__out_t cmd;
			te0 = '0;
			set_cmd(cmd,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS,
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_TE,
				te0);
			drive_cap(0, cmd, 'h9999, 'h44);
			@(posedge tip_clk);
			clear_inputs();
		end

		// (4) TE side effects (INSTR set/clear + DATA set/clear)
		begin
			ct_act_cap_te_t te;
			ct_cs_cpuif__trActCapStCmd__out_t cmd;

			// INSTR set
			te = '0;
			te.ctrl = ACT_CAP_TE_INSTR_TRACING;
			te.data = 16'h0001; // bit0 => set
			set_cmd(cmd,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_TE,
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_TE,
				te);
			drive_cap(0, cmd, '0, '0);
			exp_te_q.push_back(TE_INST_SET);
			@(posedge tip_clk);
			clear_inputs();

			// INSTR clear
			te = '0;
			te.ctrl = ACT_CAP_TE_INSTR_TRACING;
			te.data = 16'h0000;
			set_cmd(cmd,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_TE,
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_TE,
				te);
			drive_cap(0, cmd, '0, '0);
			exp_te_q.push_back(TE_INST_CLR);
			@(posedge tip_clk);
			clear_inputs();

			// DATA set
			te = '0;
			te.ctrl = ACT_CAP_TE_DATA_TRACING;
			te.data = 16'h0002; // bit1 => set
			set_cmd(cmd,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_TE,
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_TE,
				te);
			drive_cap(0, cmd, '0, '0);
			exp_te_q.push_back(TE_DATA_SET);
			@(posedge tip_clk);
			clear_inputs();

			// DATA clear
			te = '0;
			te.ctrl = ACT_CAP_TE_DATA_TRACING;
			te.data = 16'h0000;
			set_cmd(cmd,
				ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_TE,
				ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_TE,
				te);
			drive_cap(0, cmd, '0, '0);
			exp_te_q.push_back(TE_DATA_CLR);
			@(posedge tip_clk);
			clear_inputs();
		end

		// Let pipeline drain
		repeat (50) @(posedge tip_clk);
	end

	// --------------------------------------------------------------------
	// Checkers
	// --------------------------------------------------------------------
	initial begin : CHECK_OUTPUT
		automatic int timeout = 0;
		automatic exp_out_t exp;

		// wait reset deassert
		@(negedge tip_rst);
		#1ps;

		// Don't start checking before stimulus has queued expectations.
		// Otherwise the checker would immediately fall through into the
		// "no more outputs" section and flag valid outputs as unexpected.
		wait (exp_out_q.size() > 0);

		// We expect exactly exp_out_q.size output pulses
		while (exp_out_q.size() > 0) begin
			@(posedge tip_clk);
			#1ps; // sample after DUT NBAs
			if (act_cap_st.valid) begin
				exp = exp_out_q.pop_front();
				void'(tt_assert(act_cap_st.cmd  == exp.cmd,  $sformatf("%0.2f: act_cap_st.cmd mismatch",  $realtime)));
				void'(tt_assert(act_cap_st.data == exp.data, $sformatf("%0.2f: act_cap_st.data mismatch", $realtime)));
				void'(tt_assert(act_cap_st.addr == exp.addr, $sformatf("%0.2f: act_cap_st.addr mismatch", $realtime)));
				timeout = 0;
			end else begin
				timeout++;
				if (timeout > 2000) begin
					void'(tt_assert(1'b0, "Timeout waiting for act_cap_st outputs"));
					break;
				end
			end
		end

		// after all expected outputs consumed, ensure no more outputs
		repeat (30) begin
			@(posedge tip_clk);
			#1ps;
			void'(tt_assert(!act_cap_st.valid, "Unexpected extra act_cap_st.valid"));
		end
	end

	initial begin : CHECK_TE
		automatic int timeout = 0;
		automatic exp_te_kind_e exp;
		@(negedge tip_rst);
		#1ps;

		// Wait until stimulus scheduled at least one TE expectation.
		wait (exp_te_q.size() > 0);

		while (exp_te_q.size() > 0) begin
			@(posedge tip_clk);
			#1ps;
			if (cs_tip.trTeInstTracingSet || cs_tip.trTeInstTracingClr || cs_tip.trTeDataTracingSet || cs_tip.trTeDataTracingClr) begin
				exp = exp_te_q.pop_front();
				unique case (exp)
					TE_INST_SET: begin
						void'(tt_assert(cs_tip.trTeInstTracingSet, "Expected trTeInstTracingSet pulse"));
						void'(tt_assert(!cs_tip.trTeInstTracingClr, "Unexpected trTeInstTracingClr pulse"));
					end
					TE_INST_CLR: begin
						void'(tt_assert(cs_tip.trTeInstTracingClr, "Expected trTeInstTracingClr pulse"));
						void'(tt_assert(!cs_tip.trTeInstTracingSet, "Unexpected trTeInstTracingSet pulse"));
					end
					TE_DATA_SET: begin
						void'(tt_assert(cs_tip.trTeDataTracingSet, "Expected trTeDataTracingSet pulse"));
						void'(tt_assert(!cs_tip.trTeDataTracingClr, "Unexpected trTeDataTracingClr pulse"));
					end
					TE_DATA_CLR: begin
						void'(tt_assert(cs_tip.trTeDataTracingClr, "Expected trTeDataTracingClr pulse"));
						void'(tt_assert(!cs_tip.trTeDataTracingSet, "Unexpected trTeDataTracingSet pulse"));
					end
					default: begin
						void'(tt_assert(1'b0, "Unknown TE expectation"));
					end
				endcase
				timeout = 0;
			end else begin
				timeout++;
				if (timeout > 2000) begin
					void'(tt_assert(1'b0, "Timeout waiting for cs_tip TE pulses"));
					break;
				end
			end
		end
	end

	initial begin : FINISH
		@(negedge tip_rst);
		#1ps;
		// Wait for both queues to drain and some extra cycles
		wait (exp_out_q.size() == 0 && exp_te_q.size() == 0);
		repeat (50) begin
			@(posedge tip_clk);
			#1ps;
		end
		tt_evaluate();
		$finish;
	end

endmodule
