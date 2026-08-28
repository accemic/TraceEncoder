// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @file    ct_L2_nexus_formatter_tb.sv
 * @brief   Unit test for ct_L2_nexus_formatter -- normal operation.
 *
 * @details Drives a realistic message sequence through the formatter
 *   and verifies every output field (name, type, data, width) for each
 *   supported tcode.  RefAddr / UADDR compression is verified across the
 *   sequence since each address-bearing message updates RefAddr.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 * Copyright (C) 2026 Accemic Technologies GmbH
 */
module ct_L2_nexus_formatter_tb;

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
	// Static config -- set once, never changed (mirrors real usage)
	// --------------------------------------------------------------------
	initial begin
		cs_proc.trTeActive       = 1'b1;
		cs_proc.trTeInhibitSrc   = 1'b0;   // SRC enabled
		cs_proc.trTeSrcID        = 4'hA;
		cs_proc.trTeSrcBits      = 4'd4;
		cs_proc.trTsEnable       = 1'b1;   // timestamps enabled
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

	// The formatter emits TSTAMP as:
	//   - absolute for sync messages (PROGRAM_TRACE_SYNC / *_BRANCH_SYNC), and
	//   - delta vs. the last emitted TSTAMP for all other messages.
	// Track the previous ts here so each test can assert the expected value.
	// Both helpers update tb_prev_ts because the DUT updates its baseline on
	// every TSTAMP emission, regardless of sync vs. non-sync.
	logic [63:0] tb_prev_ts = '0;
	function automatic logic [63:0] ts_delta(input logic [63:0] ts);
		ts_delta = ts - tb_prev_ts;
		tb_prev_ts = ts;
	endfunction
	function automatic logic [63:0] ts_abs(input logic [63:0] ts);
		ts_abs = ts;
		tb_prev_ts = ts;
	endfunction

	function automatic nexus_msg_struct_t make_cf(
		input nexus_tcode_e          tcode,
		input nexus_sync_reason_e    sync_reason,
		input nexus_btype_e          btype,
		input nexus_rcode_e          rcode,
		input nexus_addr_t           curr_iaddr,
		input nexus_addr_t           next_iaddr,
		input nexus_icnt_t           icnt,
		input nexus_rdata_t          rdata0,
		input nexus_rdata_t          rdata1,
		input logic [63:0]           ts
	);
		nexus_msg_struct_t m = '0;
		nexus_cf_msg_struct_t cf = '0;
		m.sub_type   = SUB_MSG_CF;
		m.tcode      = tcode;
		m.ts         = ts;
		m.id         = msg_id++;
		cf.sync_reason = sync_reason;
		cf.btype       = btype;
		cf.rcode       = rcode;
		cf.curr_iaddr  = curr_iaddr;
		cf.next_iaddr  = next_iaddr;
		cf.icnt        = icnt;
		cf.rdata0      = rdata0;
		cf.rdata1      = rdata1;
		m.sub.cf       = cf;
		return m;
	endfunction

	function automatic nexus_msg_struct_t make_df_daq(
		input nexus_tcode_e          tcode,
		input nexus_dsz_e            dsz,
		input nexus_elsz_e           elsz,
		input nexus_addr_t           addr_idtag,
		input logic [NEXUS_MSG_DATA_WIDTH-1:0] data,
		input logic [63:0]           ts
	);
		nexus_msg_struct_t m = '0;
		nexus_df_daq_msg_struct_t df = '0;
		m.sub_type      = (tcode == NEXUS_MSG_DATA_ACQUISITION) ? SUB_MSG_DAQ : SUB_MSG_DF;
		m.tcode         = tcode;
		m.ts            = ts;
		m.id            = msg_id++;
		df.dsz          = dsz;
		df.elsz         = elsz;
		df.addr_idtag   = addr_idtag;
		df.data         = data;
		m.sub.df_daq    = df;
		return m;
	endfunction

	function automatic nexus_msg_struct_t make_none();
		nexus_msg_struct_t m = '0;
		m.sub_type = SUB_MSG_NONE;
		return m;
	endfunction

	// Drive trace_msg, wait one cycle for the registered output
	task automatic drive(input nexus_msg_struct_t m);
		trace_msg <= m;
		@(posedge clk);   // DUT samples
		@(posedge clk);   // registered output available
	endtask

	// Check a single field
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

	// Check that remaining fields are invalid
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
		int idx;
		nexus_addr_t expected_ref_addr;

		rst      = 1'b1;
		ready_in = 1'b1;
		trace_msg = make_none();

		repeat (5) @(posedge clk);
		rst = 1'b0;
		@(posedge clk);

		// ================================================================
		// T1: PROGRAM_TRACE_SYNC  (RefAddr starts at 0)
		// ================================================================
		tc = create_testcase("SYNC");
		drive(make_cf(
			.tcode(NEXUS_MSG_PROGRAM_TRACE_SYNC),
			.sync_reason(NEXUS_SYNC_EXIT_FROM_SYS_RST),
			.btype(NEXUS_BTYPE_IBRANCH), .rcode(NEXUS_RCODE_NONE),
			.curr_iaddr(32'h0000_1000), .next_iaddr(32'h0),
			.icnt(8'd5), .rdata0('0), .rdata1('0),
			.ts(64'hDEAD)
		));
		// fields: TCODE, SRC, SYNC, ICNT, PC_FADDR, TSTAMP
		check_field(tc, "SYNC", 0, TCODE,    FIXED,           NEXUS_MSG_PROGRAM_TRACE_SYNC, 6);
		check_field(tc, "SYNC", 1, SRC,      VENDOR_FIXED,    cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
		check_field(tc, "SYNC", 2, SYNC,     VENDOR_FIXED,    NEXUS_SYNC_EXIT_FROM_SYS_RST, $size(nexus_sync_reason_e));
		check_field(tc, "SYNC", 3, ICNT,     VARIABLE,        8'd5, LengthWoLeadingZeros(8'd5));
		begin
			automatic nexus_addr_t faddr = 32'h0000_1000 >> NEXUS_MSG_PC_ADDR_SHIFT;
			check_field(tc, "SYNC", 4, PC_FADDR, VARIABLE,    faddr, LengthWoLeadingZeros(faddr));
		end
		begin
			automatic logic [63:0] d = ts_abs(64'hDEAD);
			check_field(tc, "SYNC", 5, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
		end
		check_invalid_from(tc, "SYNC", 6);
		// DUT stores RefAddr in the shifted domain (post NEXUS_MSG_PC_ADDR_SHIFT).
		expected_ref_addr = 32'h0000_1000 >> NEXUS_MSG_PC_ADDR_SHIFT;

		// idle between messages
		drive(make_none());

		// ================================================================
		// T2: INDIRECT_BRANCH  (UADDR = next_iaddr ^ RefAddr)
		// ================================================================
		tc = create_testcase("INDIRECT_BRANCH");
		begin
			automatic nexus_addr_t next_addr = 32'h0000_2080;
			automatic nexus_addr_t exp_uaddr = (next_addr >> NEXUS_MSG_PC_ADDR_SHIFT) ^ expected_ref_addr;
			drive(make_cf(
				.tcode(NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH),
				.sync_reason(NEXUS_SYNC_NONE),
				.btype(NEXUS_BTYPE_IBRANCH), .rcode(NEXUS_RCODE_NONE),
				.curr_iaddr('0), .next_iaddr(next_addr),
				.icnt(8'd12), .rdata0('0), .rdata1('0),
				.ts(64'h1)
			));
			check_field(tc, "IB", 0, TCODE, FIXED,       NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH, 6);
			check_field(tc, "IB", 1, SRC,   VENDOR_FIXED, cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
			check_field(tc, "IB", 2, BTYPE, VENDOR_FIXED, NEXUS_BTYPE_IBRANCH, $size(nexus_btype_e));
			check_field(tc, "IB", 3, ICNT,  VARIABLE,     8'd12, LengthWoLeadingZeros(8'd12));
			check_field(tc, "IB", 4, UADDR, VARIABLE,     exp_uaddr, LengthWoLeadingZeros(exp_uaddr));
			begin
				automatic logic [63:0] d = ts_delta(64'h1);
				check_field(tc, "IB", 5, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
			end
			check_invalid_from(tc, "IB", 6);
			expected_ref_addr = next_addr >> NEXUS_MSG_PC_ADDR_SHIFT;
		end

		drive(make_none());

		// ================================================================
		// T3: DIRECT_BRANCH  (ICNT only, no address)
		// ================================================================
		tc = create_testcase("DIRECT_BRANCH");
		drive(make_cf(
			.tcode(NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH),
			.sync_reason(NEXUS_SYNC_NONE),
			.btype(NEXUS_BTYPE_IBRANCH), .rcode(NEXUS_RCODE_NONE),
			.curr_iaddr('0), .next_iaddr('0),
			.icnt(8'd0), .rdata0('0), .rdata1('0),   // icnt=0: tests LengthWoLeadingZeros minimum (width=1)
			.ts(64'hABCD_0000_0000_0000)              // large ts: tests width at MSB
		));
		check_field(tc, "DB", 0, TCODE, FIXED,       NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH, 6);
		check_field(tc, "DB", 1, SRC,   VENDOR_FIXED, cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
		check_field(tc, "DB", 2, ICNT,  VARIABLE,     8'd0, 1);  // LengthWoLeadingZeros(0) == 1
		begin
			automatic logic [63:0] d = ts_delta(64'hABCD_0000_0000_0000);
			check_field(tc, "DB", 3, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
		end
		check_invalid_from(tc, "DB", 4);
		// RefAddr unchanged (no address field)

		drive(make_none());

		// ================================================================
		// T4: DIRECT_BRANCH_SYNC
		// ================================================================
		tc = create_testcase("DIRECT_BRANCH_SYNC");
		begin
			automatic nexus_addr_t next_addr = 32'h0000_3000;
			drive(make_cf(
				.tcode(NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC),
				.sync_reason(NEXUS_SYNC_PERIODIC),
				.btype(NEXUS_BTYPE_IBRANCH), .rcode(NEXUS_RCODE_NONE),
				.curr_iaddr('0), .next_iaddr(next_addr),
				.icnt(8'd1), .rdata0('0), .rdata1('0),
				.ts(64'h42)
			));
			check_field(tc, "DBS", 0, TCODE,    FIXED,           NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC, 6);
			check_field(tc, "DBS", 1, SRC,      VENDOR_FIXED,    cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
			check_field(tc, "DBS", 2, SYNC,     VENDOR_FIXED,    NEXUS_SYNC_PERIODIC, $size(nexus_sync_reason_e));
			check_field(tc, "DBS", 3, ICNT,     VARIABLE,        8'd1, LengthWoLeadingZeros(8'd1));
			begin
				automatic nexus_addr_t faddr = next_addr >> NEXUS_MSG_PC_ADDR_SHIFT;
				check_field(tc, "DBS", 4, PC_FADDR, VARIABLE,    faddr, LengthWoLeadingZeros(faddr));
			end
			begin
				automatic logic [63:0] d = ts_abs(64'h42);
				check_field(tc, "DBS", 5, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
			end
			check_invalid_from(tc, "DBS", 6);
			expected_ref_addr = next_addr >> NEXUS_MSG_PC_ADDR_SHIFT;
		end

		drive(make_none());

		// ================================================================
		// T5: INDIRECT_BRANCH_SYNC
		// ================================================================
		tc = create_testcase("INDIRECT_BRANCH_SYNC");
		begin
			automatic nexus_addr_t next_addr = 32'hFFFF_FFFC;
			drive(make_cf(
				.tcode(NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC),
				.sync_reason(NEXUS_SYNC_TRACE_ENABLE),
				.btype(NEXUS_BTYPE_EXCEPTION_INTERRUPT), .rcode(NEXUS_RCODE_NONE),
				.curr_iaddr('0), .next_iaddr(next_addr),
				.icnt(8'hFF), .rdata0('0), .rdata1('0),  // max icnt
				.ts(64'h0)                                // zero ts: tests LengthWoLeadingZeros min
			));
			check_field(tc, "IBS", 0, TCODE,    FIXED,           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC, 6);
			check_field(tc, "IBS", 1, SRC,      VENDOR_FIXED,    cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
			check_field(tc, "IBS", 2, SYNC,     VENDOR_FIXED,    NEXUS_SYNC_TRACE_ENABLE, $size(nexus_sync_reason_e));
			check_field(tc, "IBS", 3, BTYPE,    VENDOR_FIXED,    NEXUS_BTYPE_EXCEPTION_INTERRUPT, $size(nexus_btype_e));
			check_field(tc, "IBS", 4, ICNT,     VARIABLE,        8'hFF, LengthWoLeadingZeros(8'hFF));
			begin
				automatic nexus_addr_t faddr = next_addr >> NEXUS_MSG_PC_ADDR_SHIFT;
				check_field(tc, "IBS", 5, PC_FADDR, VARIABLE,    faddr, LengthWoLeadingZeros(faddr));
			end
			begin
				automatic logic [63:0] d = ts_abs(64'h0);
				check_field(tc, "IBS", 6, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
			end
			check_invalid_from(tc, "IBS", 7);
			expected_ref_addr = next_addr >> NEXUS_MSG_PC_ADDR_SHIFT;
		end

		drive(make_none());

		// ================================================================
		// T5b: INDIRECT_BRANCH_SYNC at the TOP of the address space (X2a).
		// T5 above pins the 32-bit corner (0xFFFF_FFFC) in EVERY build; this
		// one is its 64-bit sibling and therefore only runs when the address
		// path is that wide -- at CT_XLEN = 32 it would be a duplicate of T5
		// that shifts the reference address and every field index after it,
		// i.e. it would change the 32-bit run for nothing.
		// What it actually catches: an F-ADDR field whose leading-zero
		// suppression still assumes 32 bits emits 32 bits here and the whole
		// upper half of the address vanishes without a single failing
		// comparison downstream.
		// ================================================================
		if (ct_pkg::CT_ADDR64) begin
			tc = create_testcase("INDIRECT_BRANCH_SYNC_TOP64");
			begin
				automatic nexus_addr_t next_addr = ~nexus_addr_t'(3); // all ones, 4-byte aligned
				drive(make_cf(
					.tcode(NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC),
					.sync_reason(NEXUS_SYNC_TRACE_ENABLE),
					.btype(NEXUS_BTYPE_EXCEPTION_INTERRUPT), .rcode(NEXUS_RCODE_NONE),
					.curr_iaddr('0), .next_iaddr(next_addr),
					.icnt(8'hFF), .rdata0('0), .rdata1('0),
					.ts(64'h0)
				));
				check_field(tc, "IBS64", 0, TCODE,    FIXED,           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC, 6);
				check_field(tc, "IBS64", 1, SRC,      VENDOR_FIXED,    cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
				check_field(tc, "IBS64", 2, SYNC,     VENDOR_FIXED,    NEXUS_SYNC_TRACE_ENABLE, $size(nexus_sync_reason_e));
				check_field(tc, "IBS64", 3, BTYPE,    VENDOR_FIXED,    NEXUS_BTYPE_EXCEPTION_INTERRUPT, $size(nexus_btype_e));
				check_field(tc, "IBS64", 4, ICNT,     VARIABLE,        8'hFF, LengthWoLeadingZeros(8'hFF));
				begin
					automatic nexus_addr_t faddr = next_addr >> NEXUS_MSG_PC_ADDR_SHIFT;
					check_field(tc, "IBS64", 5, PC_FADDR, VARIABLE,    faddr, LengthWoLeadingZeros(faddr));
				end
				begin
					automatic logic [63:0] d = ts_abs(64'h0);
					check_field(tc, "IBS64", 6, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
				end
				check_invalid_from(tc, "IBS64", 7);
				expected_ref_addr = next_addr >> NEXUS_MSG_PC_ADDR_SHIFT;
			end

			drive(make_none());
		end

		// ================================================================
		// T6: INDIRECT_BRANCH_HISTORY
		// ================================================================
		tc = create_testcase("INDIRECT_BRANCH_HISTORY");
		begin
			automatic nexus_addr_t next_addr = 32'h0000_4000;
			automatic nexus_addr_t exp_uaddr = (next_addr >> NEXUS_MSG_PC_ADDR_SHIFT) ^ expected_ref_addr;
			automatic nexus_rdata_t hist = 30'h1555_5555;  // alternating pattern with stop bit
			drive(make_cf(
				.tcode(NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY),
				.sync_reason(NEXUS_SYNC_NONE),
				.btype(NEXUS_BTYPE_IBRANCH), .rcode(NEXUS_RCODE_NONE),
				.curr_iaddr('0), .next_iaddr(next_addr),
				.icnt(8'd20), .rdata0(hist), .rdata1('0),
				.ts(64'h100)
			));
			check_field(tc, "IBH", 0, TCODE,  FIXED,           NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY, 6);
			check_field(tc, "IBH", 1, SRC,    VENDOR_FIXED,    cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
			check_field(tc, "IBH", 2, BTYPE,  VENDOR_FIXED,    NEXUS_BTYPE_IBRANCH, $size(nexus_btype_e));
			check_field(tc, "IBH", 3, ICNT,   VARIABLE,        8'd20, LengthWoLeadingZeros(8'd20));
			check_field(tc, "IBH", 4, UADDR,  VARIABLE,        exp_uaddr, LengthWoLeadingZeros(exp_uaddr));
			check_field(tc, "IBH", 5, RDATA0, VENDOR_VARIABLE, hist, LengthWoLeadingZeros(hist));
			begin
				automatic logic [63:0] d = ts_delta(64'h100);
				check_field(tc, "IBH", 6, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
			end
			check_invalid_from(tc, "IBH", 7);
			expected_ref_addr = next_addr >> NEXUS_MSG_PC_ADDR_SHIFT;
		end

		drive(make_none());

		// ================================================================
		// T7: RESOURCE_FULL -- ICNT overflow (no RDATA1)
		// ================================================================
		tc = create_testcase("RESOURCE_FULL_ICNT");
		drive(make_cf(
			.tcode(NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL),
			.sync_reason(NEXUS_SYNC_NONE),
			.btype(NEXUS_BTYPE_IBRANCH),
			.rcode(NEXUS_RCODE_ICNT_OVERFLOW),
			.curr_iaddr('0), .next_iaddr('0),
			.icnt('0), .rdata0(30'd255), .rdata1('0),
			.ts(64'hFF)
		));
		check_field(tc, "RF_ICNT", 0, TCODE,  FIXED,           NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL, 6);
		check_field(tc, "RF_ICNT", 1, SRC,    VENDOR_FIXED,    cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
		check_field(tc, "RF_ICNT", 2, RCODE,  VENDOR_FIXED,    NEXUS_RCODE_ICNT_OVERFLOW, $size(nexus_rcode_e));
		check_field(tc, "RF_ICNT", 3, RDATA0, VENDOR_VARIABLE, 30'd255, LengthWoLeadingZeros(30'd255));
		begin
			automatic logic [63:0] d = ts_delta(64'hFF);
			check_field(tc, "RF_ICNT", 4, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
		end
		check_invalid_from(tc, "RF_ICNT", 5);

		drive(make_none());

		// ================================================================
		// T8: RESOURCE_FULL -- hist overflow repeated (with RDATA1)
		// ================================================================
		tc = create_testcase("RESOURCE_FULL_HIST_REPEATED");
		drive(make_cf(
			.tcode(NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL),
			.sync_reason(NEXUS_SYNC_NONE),
			.btype(NEXUS_BTYPE_IBRANCH),
			.rcode(NEXUS_RCODE_HIST_OVERFLOW_REPEATED),
			.curr_iaddr('0), .next_iaddr('0),
			.icnt('0), .rdata0(30'h3FFF_FFFF), .rdata1(30'h0000_0001),
			.ts(64'h10)
		));
		check_field(tc, "RF_HR", 0, TCODE,  FIXED,           NEXUS_MSG_PROGRAM_TRACE_RESOURCE_FULL, 6);
		check_field(tc, "RF_HR", 1, SRC,    VENDOR_FIXED,    cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
		check_field(tc, "RF_HR", 2, RCODE,  VENDOR_FIXED,    NEXUS_RCODE_HIST_OVERFLOW_REPEATED, $size(nexus_rcode_e));
		check_field(tc, "RF_HR", 3, RDATA0, VENDOR_VARIABLE, 30'h3FFF_FFFF, LengthWoLeadingZeros(30'h3FFF_FFFF));
		check_field(tc, "RF_HR", 4, RDATA1, VENDOR_VARIABLE, 30'h0000_0001, LengthWoLeadingZeros(30'h0000_0001));
		begin
			automatic logic [63:0] d = ts_delta(64'h10);
			check_field(tc, "RF_HR", 5, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
		end
		check_invalid_from(tc, "RF_HR", 6);

		drive(make_none());

		// ================================================================
		// T9: DATA_TRACE_WRITE
		// ================================================================
		tc = create_testcase("DATA_TRACE_WRITE");
		drive(make_df_daq(
			.tcode(NEXUS_MSG_DATA_TRACE_WRITE),
			.dsz(NEXUS_DSZ_4), .elsz(NEXUS_ELSZ_4),
			.addr_idtag(32'hA000_0010),
			.data({192{1'b0}} | 192'hDEAD_BEEF),
			.ts(64'h200)
		));
		check_field(tc, "DTW", 0, TCODE,  FIXED,       NEXUS_MSG_DATA_TRACE_WRITE, 6);
		check_field(tc, "DTW", 1, SRC,    VENDOR_FIXED, cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
		check_field(tc, "DTW", 2, DSZ,    VENDOR_FIXED, NEXUS_DSZ_4, $size(nexus_dsz_e));
		check_field(tc, "DTW", 3, ELSZ,   VENDOR_FIXED, NEXUS_ELSZ_4, $size(nexus_elsz_e));
		check_field(tc, "DTW", 4, UADDR,  VARIABLE,     32'hA000_0010, LengthWoLeadingZeros(32'hA000_0010));
		check_field(tc, "DTW", 5, DQDATA, VARIABLE,     192'hDEAD_BEEF, LengthWoLeadingZeros(192'hDEAD_BEEF));
		begin
			automatic logic [63:0] d = ts_delta(64'h200);
			check_field(tc, "DTW", 6, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
		end
		check_invalid_from(tc, "DTW", 7);

		drive(make_none());

		// ================================================================
		// T10: DATA_TRACE_READ
		// ================================================================
		tc = create_testcase("DATA_TRACE_READ");
		drive(make_df_daq(
			.tcode(NEXUS_MSG_DATA_TRACE_READ),
			.dsz(NEXUS_DSZ_1), .elsz(NEXUS_ELSZ_1),
			.addr_idtag(32'h0000_0004),
			.data({192{1'b0}} | 192'hFF),
			.ts(64'h300)
		));
		check_field(tc, "DTR", 0, TCODE,  FIXED,       NEXUS_MSG_DATA_TRACE_READ, 6);
		check_field(tc, "DTR", 1, SRC,    VENDOR_FIXED, cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
		check_field(tc, "DTR", 2, DSZ,    VENDOR_FIXED, NEXUS_DSZ_1, $size(nexus_dsz_e));
		check_field(tc, "DTR", 3, ELSZ,   VENDOR_FIXED, NEXUS_ELSZ_1, $size(nexus_elsz_e));
		check_field(tc, "DTR", 4, UADDR,  VARIABLE,     32'h0000_0004, LengthWoLeadingZeros(32'h0000_0004));
		check_field(tc, "DTR", 5, DQDATA, VARIABLE,     192'hFF, LengthWoLeadingZeros(192'hFF));
		begin
			automatic logic [63:0] d = ts_delta(64'h300);
			check_field(tc, "DTR", 6, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
		end
		check_invalid_from(tc, "DTR", 7);

		drive(make_none());

		// ================================================================
		// T11: DATA_ACQUISITION
		// ================================================================
		tc = create_testcase("DATA_ACQUISITION");
		drive(make_df_daq(
			.tcode(NEXUS_MSG_DATA_ACQUISITION),
			.dsz(NEXUS_DSZ_0), .elsz(NEXUS_ELSZ_DSZ),
			.addr_idtag(32'h0000_00A6),   // IDTAG (12 bits used)
			.data({192{1'b0}} | {32'h0000_00A6, 32'h0000_00A6}),
			.ts(64'h400)
		));
		check_field(tc, "DAQ", 0, TCODE,  FIXED,           NEXUS_MSG_DATA_ACQUISITION, 6);
		check_field(tc, "DAQ", 1, SRC,    VENDOR_FIXED,    cs_proc.trTeSrcID, cs_proc.trTeSrcBits);
		check_field(tc, "DAQ", 2, IDTAG,  VENDOR_FIXED,    32'h0000_00A6, NEXUS_IDTAG_WIDTH);
		check_field(tc, "DAQ", 3, DQDATA, VENDOR_VARIABLE, {32'h0000_00A6, 32'h0000_00A6},
			LengthWoLeadingZeros({32'h0000_00A6, 32'h0000_00A6}));
		begin
			automatic logic [63:0] d = ts_delta(64'h400);
			check_field(tc, "DAQ", 4, TSTAMP, VENDOR_VARIABLE, d, LengthWoLeadingZeros(d));
		end
		check_invalid_from(tc, "DAQ", 5);

		drive(make_none());

		// ================================================================
		// T12: SUB_MSG_NONE passthrough (no fields emitted)
		// ================================================================
		tc = create_testcase("NONE_PASSTHROUGH");
		drive(make_none());
		check_invalid_from(tc, "NONE", 0);

		// ================================================================
		// Done
		// ================================================================
		repeat (5) @(posedge clk);
		tt_evaluate();
		$finish();
	end

endmodule
`default_nettype wire
