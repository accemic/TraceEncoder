// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief  E-Trace DAQ leg (cli_etrace_test.sh daq).
 *
 * @details
 *   Drives the deterministic DAQ commands (DIRECT_DATA, DATA, DADDR,
 *   DATA_DADDR, PC_CURR) via the ACT-CAP CSR protocol to SINK_NEXUS and
 *   writes the expected vendor packet content (idtag + 3x64-bit element
 *   concat, element 0 in the LSBs) per command. Each Prev*-consuming
 *   command is preceded by a fresh store so the Prev* capture (which
 *   updates on EVERY dretire, including the csrw itself) is known.
 *   Byte-exact compare via etrace_data_check.py --daq; the interleaved
 *   PC trace stays lossless (the csrw beats retire as OTHER).
 */

module etrace_daq_tb;

	import cpu_model_pkg::*;
	import tip_pkg::*;
	import ct_cs_cpuif_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("etrace_daq_tb.atb.bin"),
		.NEXRV_INFO_PATH     ("etrace_daq_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("etrace_daq_tb.expected.pcs")
	) env ();

	localparam logic [1:0] SINK_NEXUS =
		ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
	localparam logic [5:0] CMD_PC_CURR     = 6'd1;
	localparam logic [5:0] CMD_DIRECT_DATA = 6'd3;
	localparam logic [5:0] CMD_DATA        = 6'd4;
	localparam logic [5:0] CMD_DADDR       = 6'd5;
	localparam logic [5:0] CMD_DATA_DADDR  = 6'd6;

	int daq_fd;

	function automatic logic [191:0] elems(input logic [63:0] e0,
	                                       input logic [63:0] e1,
	                                       input logic [63:0] e2);
		return {e2, e1, e0};
	endfunction

	// {DirectData, dtype_dsize} zero-extended -- mirror of the composer's
	// pack_daq_context_direct().
	function automatic logic [63:0] ctx_direct(input tip_dtype_dsize_t dd,
	                                           input logic [23:0] direct);
		return 64'({direct, dd});
	endfunction

	task automatic exp_daq(input logic [5:0] cmd, input logic [191:0] data);
		$fwrite(daq_fd, "%02x %048x\n", cmd, data);
	endtask

	initial begin
		automatic tip_dtype_dsize_t dd;
		automatic tip_iaddr_t pc_at_cmd;

		env.wait_for_reset_release();
		env.csr.clear();

		daq_fd = $fopen("etrace_daq_tb.expected.daq", "w");

		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(32'h0000_1000));
		env.cpu.run(16);

		// 1) DIRECT_DATA: element 0 = 24-bit DirectData, zero-extended
		env.cpu.act_cap_cmd(.cmd(CMD_DIRECT_DATA), .sink(SINK_NEXUS),
		                    .direct_data(24'hABCDEF));
		exp_daq(CMD_DIRECT_DATA, elems(64'h00AB_CDEF, '0, '0));

		env.cpu.branch_taken(.target(32'h0000_1200));
		env.cpu.run(8);

		// 2) DATA: fresh store -> Prev* known
		env.cpu.store_data(32'h0000_4000, 2, 64'h0000_0000_1122_3344);
		dd = '{dtype: STORE, dsize: tip_dsize_t'(2)};
		env.cpu.act_cap_cmd(.cmd(CMD_DATA), .sink(SINK_NEXUS),
		                    .direct_data(24'h000042));
		exp_daq(CMD_DATA, elems(64'h0000_0000_1122_3344,
		                        64'(dd), 64'h0000_0000_0000_0042));

		// 3) DADDR: fresh store
		env.cpu.store_data(32'h0000_5008, 3, 64'hDEAD_BEEF_0BAD_F00D);
		dd = '{dtype: STORE, dsize: tip_dsize_t'(3)};
		env.cpu.act_cap_cmd(.cmd(CMD_DADDR), .sink(SINK_NEXUS),
		                    .direct_data(24'h000007));
		exp_daq(CMD_DADDR, elems(64'h0000_0000_0000_5008,
		                         64'(dd), 64'h0000_0000_0000_0007));

		// 4) DATA_DADDR: fresh load (LOAD dtype in the context element)
		env.cpu.load_data(32'h0000_6010, 1, 64'h0000_0000_0000_BEEF);
		dd = '{dtype: LOAD, dsize: tip_dsize_t'(1)};
		env.cpu.act_cap_cmd(.cmd(CMD_DATA_DADDR), .sink(SINK_NEXUS),
		                    .direct_data(24'h123456));
		exp_daq(CMD_DATA_DADDR, elems(64'h0000_0000_0000_BEEF,
		                              64'h0000_0000_0000_6010,
		                              ctx_direct(dd, 24'h123456)));

		env.cpu.branch_not_taken();
		env.cpu.run(8);

		// 5) PC_CURR: element 0 = the csrw's own iaddr (cur_pc before call)
		pc_at_cmd = env.cpu.cur_pc;
		env.cpu.act_cap_cmd(.cmd(CMD_PC_CURR), .sink(SINK_NEXUS),
		                    .direct_data(24'h5A5A5A));
		exp_daq(CMD_PC_CURR, elems(64'(pc_at_cmd), 64'h0000_0000_005A_5A5A, '0));

		env.cpu.run(8);

		// enough reportable CF activity for the >= 20-PC prefix floor
		env.cpu.branch_taken(.target(32'h0000_1400));
		env.cpu.run(16);
		env.cpu.branch_not_taken();
		env.cpu.run(16);
		env.cpu.idle(50);

		env.cpu.exit_trace();
		env.csr.Set_te_trTeControl_Enable(1'b0);
		env.cpu.idle(400);

		$fclose(daq_fd);
		$display("[etrace_daq_tb] done");
		$finish;
	end

endmodule

`default_nettype wire
