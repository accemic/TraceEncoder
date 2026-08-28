// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @file    ct_L2_nexus_formatter_err_tb.sv
 * @brief   Unit test for ct_L2_nexus_formatter -- error / edge paths.
 *
 * @details Tests backpressure hold/release, reset mid-stream, the
 *   FLUSH message (TCODE-only, no SRC, no TSTAMP), and the ERROR message.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 * Copyright (C) 2026 Accemic Technologies GmbH
 */
module ct_L2_nexus_formatter_err_tb;

	timeunit 1ns;
	timeprecision 1ps;

	import tt::*;
	import nexus_vendor::*;
	import nexus::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import tip_pkg::*;

	// --------------------------------------------------------------------
	// Clock, reset, wiring
	// --------------------------------------------------------------------
	localparam realtime CLK_PERIOD = 5.0;
	localparam int MAX_SIM_CYCLES = 2000;

	logic clk = 0;
	always #CLK_PERIOD clk = ~clk;

	logic rst;
	logic ready_in;
	uwire ready_out;

	nexus_msg_struct_t  trace_msg;
	nexus_message_t     nexus_msg;

	ct_cs_procclk_if cs_proc ();

	// --------------------------------------------------------------------
	// DUT
	// --------------------------------------------------------------------
	ct_L2_nexus_formatter dut (
		.proc_clk  (clk),
		.proc_rst  (rst),
		.cs_proc,
		.trace_msg,
		.nexus_msg,
		.ready_in,
		.ready_out
	);

	// --------------------------------------------------------------------
	// Static config
	// --------------------------------------------------------------------
	initial begin
		cs_proc.trTeActive       = 1'b1;
		cs_proc.trTeInhibitSrc   = 1'b0;
		cs_proc.trTeSrcID        = 4'hA;
		cs_proc.trTeSrcBits      = 4'd4;
		cs_proc.trTsEnable       = 1'b1;
		cs_proc.trTeInstMode     = ct_cs_cpuif__te__trTeControl__trTeInstMode_e__ITR_BRANCH_HIST;
		cs_proc.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_MSG;
		cs_proc.trTeInstSyncMax  = '0;
		cs_proc.trTeContext      = '0;
		cs_proc.trTeDataAddrCompress = ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e__DTR_ADDR_FULL;
		cs_proc.trTeNexusMdoBits = 5'd6;
	end

	// --------------------------------------------------------------------
	// Watchdog
	// --------------------------------------------------------------------
	initial begin
		repeat (MAX_SIM_CYCLES) @(posedge clk);
		$fatal(1, "Watchdog timeout after %0d cycles", MAX_SIM_CYCLES);
	end

	// --------------------------------------------------------------------
	// Helpers
	// --------------------------------------------------------------------
	int msg_id = 0;

	function automatic nexus_msg_struct_t make_cf_sync(
		input nexus_addr_t curr_iaddr,
		input logic [63:0] ts
	);
		nexus_msg_struct_t m = '0;
		nexus_cf_msg_struct_t cf = '0;
		m.sub_type     = SUB_MSG_CF;
		m.tcode        = NEXUS_MSG_PROGRAM_TRACE_SYNC;
		m.ts           = ts;
		m.id           = msg_id++;
		cf.sync_reason = NEXUS_SYNC_EXIT_FROM_SYS_RST;
		cf.curr_iaddr  = curr_iaddr;
		cf.icnt        = 8'd1;
		m.sub.cf       = cf;
		return m;
	endfunction

	function automatic nexus_msg_struct_t make_flush();
		nexus_msg_struct_t m = '0;
		m.sub_type = SUB_MSG_CF;
		m.tcode    = NEXUS_MSG_FLUSH;
		m.ts       = 64'hFFFF;
		m.id       = msg_id++;
		return m;
	endfunction

	function automatic nexus_msg_struct_t make_error(
		input nexus_etype_e          etype,
		input nexus_vendor_ecode_t   ecode,
		input logic [63:0]           ts
	);
		nexus_msg_struct_t m = '0;
		nexus_error_msg_struct_t err = '0;
		m.sub_type = SUB_MSG_OTHER;
		m.tcode    = NEXUS_MSG_ERROR;
		m.ts       = ts;
		m.id       = msg_id++;
		err.etype  = etype;
		err.ecode  = ecode;
		m.sub.err  = err;
		return m;
	endfunction

	function automatic nexus_msg_struct_t make_none();
		nexus_msg_struct_t m = '0;
		m.sub_type = SUB_MSG_NONE;
		return m;
	endfunction

	task automatic drive(input nexus_msg_struct_t m);
		trace_msg <= m;
		@(posedge clk);
		@(posedge clk);
	endtask

	task automatic check_field(
		input tt_testcase       tc,
		input string            ctx,
		input int               idx,
		input nexus_field_name_e exp_name,
		input nexus_field_type_e exp_type,
		input logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] exp_data,
		input int               exp_width
	);
		automatic nexus_field_t f = nexus_msg.fields[idx];
		void'(tc.tt_assert(f.name === exp_name,
			$sformatf("%s field[%0d] name: exp %s got %s", ctx, idx, exp_name.name(), f.name.name())));
		void'(tc.tt_assert(f.field_type === exp_type,
			$sformatf("%s field[%0d] type: exp %s got %s", ctx, idx, exp_type.name(), f.field_type.name())));
		void'(tc.tt_assert_eq_int(f.data_width, exp_width,
			$sformatf("%s field[%0d] width", ctx, idx)));
		if (exp_width > 0) begin
			automatic logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] mask = (1 << exp_width) - 1;
			void'(tc.tt_assert((f.data & mask) === (exp_data & mask),
				$sformatf("%s field[%0d] data: exp 0x%0h got 0x%0h", ctx, idx, exp_data & mask, f.data & mask)));
		end
	endtask

	task automatic check_invalid_from(
		input tt_testcase tc,
		input string      ctx,
		input int         from_idx
	);
		for (int i = from_idx; i < NEXUS_MAX_FIELDS; i++) begin
			void'(tc.tt_assert(nexus_msg.fields[i].field_type === FIELD_INVALID,
				$sformatf("%s field[%0d] should be FIELD_INVALID", ctx, i)));
		end
	endtask

	// --------------------------------------------------------------------
	// Main test sequence
	// --------------------------------------------------------------------
	initial begin
		tt_testcase tc;
		nexus_message_t held_msg;

		rst      = 1'b1;
		ready_in = 1'b1;
		trace_msg = make_none();

		repeat (5) @(posedge clk);
		rst = 1'b0;
		@(posedge clk);

		// ================================================================
		// E1: FLUSH -- TCODE only (no SRC, no TSTAMP despite both enabled)
		// ================================================================
		tc = create_testcase("FLUSH");
		drive(make_flush());
		// FLUSH: only TCODE, SRC is suppressed, TSTAMP is suppressed
		check_field(tc, "FLUSH", 0, TCODE, FIXED, NEXUS_MSG_FLUSH, 6);
		check_invalid_from(tc, "FLUSH", 1);

		drive(make_none());

		// ================================================================
		// E2: ERROR message
		// ================================================================
		tc = create_testcase("ERROR");
		drive(make_error(
			.etype(NEXUS_ETYPE_QUEUE_OVERRUN),
			.ecode(NEXUS_ECODE_CF_MSG_LOST),
			.ts(64'h500)
		));
		check_field(tc, "ERR", 0, TCODE, FIXED,       NEXUS_MSG_ERROR, 6);
		check_field(tc, "ERR", 1, SRC,   VENDOR_FIXED, cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
		check_field(tc, "ERR", 2, ETYPE, FIXED,        NEXUS_ETYPE_QUEUE_OVERRUN, $size(nexus_etype_e));
		check_field(tc, "ERR", 3, ECODE, VENDOR_FIXED,  NEXUS_ECODE_CF_MSG_LOST, NEXUS_MSG_ECODE_WIDTH);
		check_field(tc, "ERR", 4, TSTAMP, VENDOR_VARIABLE, 64'h500, LengthWoLeadingZeros(64'h500));
		check_invalid_from(tc, "ERR", 5);

		drive(make_none());

		// ================================================================
		// E3: Backpressure -- output held stable when ready_in=0
		// ================================================================
		tc = create_testcase("BACKPRESSURE_HOLD");
		begin
			// Drive a SYNC message normally
			drive(make_cf_sync(32'h0000_8000, 64'hBB));
			// Capture the output
			held_msg = nexus_msg;

			// Now deassert ready_in and change the input
			ready_in <= 1'b0;
			trace_msg <= make_cf_sync(32'hFFFF_0000, 64'hCC);
			repeat (5) @(posedge clk);

			// Output must still match the held message
			for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
				void'(tc.tt_assert(nexus_msg.fields[i] === held_msg.fields[i],
					$sformatf("HOLD field[%0d] changed during backpressure", i)));
			end

			// Verify ready_out is deasserted
			void'(tc.tt_assert(ready_out === 1'b0, "ready_out should be 0 during backpressure"));
		end

		// ================================================================
		// E4: Backpressure -- release consumes new message
		// ================================================================
		tc = create_testcase("BACKPRESSURE_RELEASE");
		begin
			// Release backpressure (trace_msg still has the new SYNC from E3)
			ready_in <= 1'b1;
			@(posedge clk);
			@(posedge clk);

			// Output should now reflect the new message (curr_iaddr=0xFFFF_0000)
			check_field(tc, "REL", 0, TCODE,    FIXED,        NEXUS_MSG_PROGRAM_TRACE_SYNC, 6);
			check_field(tc, "REL", 4, PC_FADDR, VARIABLE,     32'hFFFF_0000 >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(32'hFFFF_0000 >> NEXUS_MSG_PC_ADDR_SHIFT));
			void'(tc.tt_assert(ready_out === 1'b1, "ready_out should be 1 after release"));
		end

		drive(make_none());

		// ================================================================
		// E5: Reset mid-stream -- all fields cleared, RefAddr zeroed
		// ================================================================
		tc = create_testcase("RESET_MID_STREAM");
		begin
			// Drive a message to set RefAddr
			drive(make_cf_sync(32'hAAAA_0000, 64'h1));

			// Assert reset
			rst <= 1'b1;
			repeat (3) @(posedge clk);

			// All fields should be FIELD_INVALID
			check_invalid_from(tc, "RST", 0);

			// Release reset
			rst <= 1'b0;
			@(posedge clk);

			// Drive a new SYNC -- RefAddr should be 0 again, so PC_FADDR
			// is the full address (no XOR corruption from previous RefAddr)
			drive(make_cf_sync(32'h0000_5000, 64'h2));
			check_field(tc, "RST_SYNC", 4, PC_FADDR, VARIABLE, 32'h0000_5000 >> NEXUS_MSG_PC_ADDR_SHIFT, LengthWoLeadingZeros(32'h0000_5000 >> NEXUS_MSG_PC_ADDR_SHIFT));
		end

		// ================================================================
		// Done
		// ================================================================
		repeat (5) @(posedge clk);
		tt_evaluate();
		$finish();
	end

endmodule
`default_nettype wire
