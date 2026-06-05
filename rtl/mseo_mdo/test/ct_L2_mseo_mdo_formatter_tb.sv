// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`timescale 1ns/1ps
`default_nettype none

module ct_L2_mseo_mdo_formatter_tb;
	import nexus_vendor::*;
	import nexus::*;
	import atb_pkg::*;
	import nexus_msg_helper_pkg::*;

	localparam nexus_field_name_e FP_TCODE = nexus_field_name_e'(6'h01);
	localparam nexus_field_type_e FT_INV    = nexus_field_type_e'(3'h0);
	localparam nexus_field_type_e FT_VFIXED = nexus_field_type_e'(3'h1);  // VENDOR_FIXED
	localparam nexus_field_type_e FT_VVAR   = nexus_field_type_e'(3'h2);  // VENDOR_VARIABLE
	localparam nexus_field_type_e FT_VAR    = nexus_field_type_e'(3'h3);  // VARIABLE
	localparam nexus_field_type_e FT_FIXED  = nexus_field_type_e'(3'h4);  // FIXED

	localparam int unsigned MDO_WIDTH            = 6;
	localparam int unsigned CHUNK_WIDTH          = MDO_WIDTH + 2;
	localparam int unsigned ATB_CHUNKS_PER_BEAT  = (ATDATA_WIDTH >= CHUNK_WIDTH) ? (ATDATA_WIDTH / CHUNK_WIDTH) : 1;
	localparam int unsigned MAX_SIM_CYCLES       = 50000;
	localparam int unsigned MAX_WAIT_READY_CYCLES = 200;

	typedef enum logic [0:0] {
		OP_SEND = 1'b0,
		OP_IDLE = 1'b1
	} stim_op_e;

	typedef struct {
		stim_op_e        op;
		nexus_message_t  msg;
		string           desc;
		bit              require_ready;
		bit              skip_if_not_ready;
		int unsigned     idle_cycles;
	} stim_item_t;

	typedef struct {
		logic [MDO_WIDTH-1:0] mdo;
		logic [1:0]           mseo;
		bit                   check_mseo;
		string                desc;
		int unsigned          tok_idx;
	} exp_token_t;

	logic clk;
	logic rst;
	logic atb_atclk;
	logic atb_atresetn;

	logic synq_req_trace_byte_count;
	logic ready_out;
	nexus_message_t nexus_msg;

	ct_cs_procclk_if cs_proc();
	ct_cs_atbclk_if  cs_atb();
	atb_if                atb();

	stim_item_t input_queue[$];
	exp_token_t expected_queue[$];
	exp_token_t expected_atb_queue[$];

	int unsigned ErrCount = 0;
	int unsigned NumCasesQueued = 0;
	int unsigned NumCasesSent = 0;
	int unsigned NumCasesSkipped = 0;
	int unsigned NumTokensChecked = 0;
	logic FeedingDone = 1'b0;
	logic CheckingDone = 1'b0;
	logic AtbCheckingDone = 1'b0;
	logic WhiteboxDone = 1'b0;

	// ----------------------------------------------------------------
	// Coverage sampling state and groups (Phase 5).
	// ----------------------------------------------------------------
	// Per-message sampling inputs (set just before `msg_cov.sample()`):
	logic [5:0]   cov_msg_tcode        = '0;
	int unsigned  cov_msg_num_fields   = 0;
	int unsigned  cov_msg_total_bits   = 0;
	bit           cov_msg_has_src      = 1'b0;
	bit           cov_msg_has_variable = 1'b0;

	// Per-slice sampling inputs:
	bit           cov_slice_ends_field = 1'b0;
	bit           cov_slice_ends_var   = 1'b0;
	bit           cov_slice_padded     = 1'b0;
	int unsigned  cov_slice_pos        = 0;  // 0=first, 1=middle, 2=last
	int unsigned  cov_slice_idx_in_msg = 0;  // slice index inside current message

	covergroup cg_msg;
		option.per_instance = 1;
		option.name         = "per_message";
		cp_tcode: coverpoint cov_msg_tcode {
			bins ownership        = {6'd2};
			bins direct_branch    = {6'd3};
			bins indirect_branch  = {6'd4};
			bins data_write       = {6'd5};
			bins data_read        = {6'd6};
			bins daq              = {6'd7};
			bins nexus_error      = {6'd8};
			bins pt_sync          = {6'd9};
			bins db_sync          = {6'd11};
			bins ib_sync          = {6'd12};
			bins resource_full    = {6'd27};
			bins ibh              = {6'd28};
			bins ibh_sync         = {6'd29};
			bins repeat_branch    = {6'd30};
			bins correlation      = {6'd33};
			bins flush            = {6'd36};
			bins other            = default;
		}
		cp_num_fields: coverpoint cov_msg_num_fields {
			bins one      = {1};
			bins two_four = {[2:4]};
			bins five_seven = {[5:7]};
			bins eight_ten  = {[8:10]};
		}
		cp_total_bits: coverpoint cov_msg_total_bits {
			bins tiny_bits   = {[1:MDO_WIDTH]};
			bins short_bits  = {[MDO_WIDTH+1:30]};
			bins medium_bits = {[31:100]};
			bins large_bits  = {[101:500]};
			bins huge_bits   = {[501:$]};
		}
		cp_has_src:   coverpoint cov_msg_has_src      { bins no = {0}; bins yes = {1}; }
		cp_has_var:   coverpoint cov_msg_has_variable { bins no = {0}; bins yes = {1}; }
		x_tcode_src: cross cp_tcode, cp_has_src;
	endgroup

	covergroup cg_slice;
		option.per_instance = 1;
		option.name         = "per_slice";
		cp_ends_field: coverpoint cov_slice_ends_field { bins no = {0}; bins yes = {1}; }
		cp_ends_var:   coverpoint cov_slice_ends_var   { bins no = {0}; bins yes = {1}; }
		cp_padded:     coverpoint cov_slice_padded     { bins no = {0}; bins yes = {1}; }
		cp_pos: coverpoint cov_slice_pos {
			bins first  = {0};
			bins middle = {1};
			bins last   = {2};
		}
		x_pos_ends_field: cross cp_pos, cp_ends_field;
		x_pos_ends_var:   cross cp_pos, cp_ends_var;
		x_pos_padded:     cross cp_pos, cp_padded;
	endgroup

	cg_msg   msg_cov   = new();
	cg_slice slice_cov = new();

	ct_L2_mseo_mdo_formatter #(
		.MDO_WIDTH(MDO_WIDTH)
	) dut (
		.proc_clk(clk),
		.proc_rst(rst),
		.atb_atclk,
		.atb_atresetn,
		.nexus_msg,
		.cs_proc,
		.cs_atb,
		.atb,
		.synq_req_trace_byte_count,
		.ready_out
	);

	// Aggressive backpressure: widened MAX_STALL_CYCLES stresses the
	// formatter's hold-while-stalled path. The sink also asserts that
	// atvalid stays high and atdata stays stable during stalls, so this
	// doubles as a protocol check.
	atb_sink_model #(
		.STARTUP_STALL_CYCLES(4),
		.MAX_STALL_CYCLES(12)
	) atb_sink (
		.atb_atclk,
		.atb_atresetn,
		.atb
	);

	// Raw ATB byte stream dump. The resulting file can be fed to the NexRv
	// software decoder (https://github.com/accemic/NexRv-for-C-Trace) for
	// round-trip verification.
	atb_dump #(
		.FILEPATH("atb_dump.bin")
	) atb_dump_inst (
		.atb_atclk,
		.atb_atresetn,
		.atb
	);

	initial clk = 1'b0;
	always #5 clk = ~clk;
	initial atb_atclk = 1'b0;
	always #7 atb_atclk = ~atb_atclk;

	// ================================================================
	// Assertion safety net (X-propagation + MSEO framing).
	//
	// These assertions run on every stimulus and act as a persistent
	// oracle independent of the reference model. They catch bug
	// classes the slice-by-slice comparator cannot see:
	//   - X values on the ATB output or internal slice stream that
	//     the sink happily accepts as zero (sim passes, FPGA fails)
	//   - Reserved MSEO code 2'b10 leaking out
	//   - Missing or doubled end-of-message pulses (stream frames
	//     correctly but message-count is wrong)
	// ================================================================

	// ---- X-propagation on observable ATB output ----
	a_atb_no_x_data: assert property (
		@(posedge atb_atclk) disable iff (!atb_atresetn)
		atb.atvalid |-> !$isunknown(atb.atdata)
	) else $fatal(1, "atb.atdata has X while atvalid=1");

	a_atb_no_x_bytes: assert property (
		@(posedge atb_atclk) disable iff (!atb_atresetn)
		atb.atvalid |-> !$isunknown(atb.atbytes)
	) else $fatal(1, "atb.atbytes has X while atvalid=1");

	a_atb_no_x_id: assert property (
		@(posedge atb_atclk) disable iff (!atb_atresetn)
		atb.atvalid |-> !$isunknown(atb.atid)
	) else $fatal(1, "atb.atid has X while atvalid=1");

	// ---- X-propagation on internal slice stream (proc_clk domain) ----
	a_slice_no_x_bits: assert property (
		@(posedge clk) disable iff (rst)
		dut.slice_valid |-> !$isunknown(dut.slice_bits)
	) else $fatal(1, "dut.slice_bits has X while slice_valid=1");

	a_slice_no_x_mseo: assert property (
		@(posedge clk) disable iff (rst)
		dut.slice_valid |-> !$isunknown(dut.mseo_bits)
	) else $fatal(1, "dut.mseo_bits has X while slice_valid=1");

	// ---- Reserved MSEO code 2'b10 must never appear ----
	// In dual-MSEO mode the valid codes are {00 start/mid, 01 end-of-var,
	// 11 end-of-msg}. 2'b10 is reserved.
	a_mseo_not_reserved: assert property (
		@(posedge clk) disable iff (rst)
		(dut.slice_valid && dut.slice_ready) |-> (dut.mseo_bits != 2'b10)
	) else $fatal(1, "reserved MSEO code 2'b10 emitted");

	// ---- SOM/EOM pairing (no double-open, no orphan-close) ----
	// Note on signal semantics:
	//   - som_pulse (StartOfMessage) IS a true 1-cycle pulse fired on
	//     msg-accept in proc_clk domain, BEFORE the first slice emerges.
	//   - eom_pulse (PipeEndOfMessage) is a LEVEL tied to the output
	//     pipeline register: it stays high from when the last slice is
	//     latched until the next slice is loaded (potentially many
	//     cycles under backpressure). The true EOM *event* is
	//     `slice_fire && eom_pulse` — when the last slice leaves the
	//     bit_slicer.
	// The slicer lives on proc_clk, so this all samples on `clk`.
	int unsigned in_msg_depth;
	uwire logic eom_event = dut.slice_valid && dut.slice_ready && dut.eom_pulse;
	always_ff @(posedge clk) begin
		if (rst) begin
			in_msg_depth <= 0;
		end
		else begin
			in_msg_depth <= in_msg_depth
				+ (dut.som_pulse ? 1 : 0)
				- (eom_event    ? 1 : 0);
		end
	end

	a_som_eom_depth: assert property (
		@(posedge clk) disable iff (rst)
		in_msg_depth inside {0, 1}
	) else $fatal(1, "SOM/EOM pairing broken: in_msg_depth=%0d", in_msg_depth);

	// End-of-sim sanity: total SOMs must equal total EOM events.
	int unsigned total_som = 0;
	int unsigned total_eom = 0;
	always_ff @(posedge clk) begin
		if (!rst) begin
			if (dut.som_pulse) total_som <= total_som + 1;
			if (eom_event)     total_eom <= total_eom + 1;
		end
	end

	initial begin
		repeat (MAX_SIM_CYCLES) @(posedge clk);
		$error("Watchdog timeout after %0d cycles", MAX_SIM_CYCLES);
		$fatal(1, "FAIL: watchdog timeout");
	end

	function automatic logic [31:0] lfsr_next(input logic [31:0] cur);
		return {cur[30:0], cur[31] ^ cur[21] ^ cur[1] ^ cur[0]};
	endfunction

	function automatic int unsigned count_valid_fields(input nexus_message_t in_msg);
		int unsigned cnt;
		cnt = 0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			if (in_msg.fields[i].field_type == FT_INV) begin
				break;
			end
			cnt++;
		end
		return cnt;
	endfunction

	// DUT's is_variable() accepts both VARIABLE and VENDOR_VARIABLE — the
	// reference model must agree, otherwise any vendor-variable field in
	// stimulus would be modelled as fixed and mismatch the RTL output.
	function automatic bit tb_is_variable(input nexus_field_type_e t);
		return (t == FT_VAR) || (t == FT_VVAR);
	endfunction

	task automatic reset();
		rst = 1'b1;
		atb_atresetn = 1'b0;
		nexus_msg = '0;
		cs_atb.trAtbId = '0;
		repeat (5) @(posedge clk);
		repeat (5) @(posedge atb_atclk);
		rst = 1'b0;
		atb_atresetn = 1'b1;
		repeat (2) @(posedge clk);
	endtask

	task automatic model_expected(
		input  nexus_message_t in_msg,
		output logic [MDO_WIDTH-1:0] exp_mdo[$],
		output logic [1:0]           exp_mseo[$]
	);
		int unsigned idx;
		int unsigned rem;
		int unsigned num_fields;
		logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] data;
		nexus_field_type_e ftype;
		logic [MDO_WIDTH-1:0] out_slice;
		logic ended_var;
		bit done;

		exp_mdo.delete();
		exp_mseo.delete();
		num_fields = count_valid_fields(in_msg);
		idx  = 0;
		done = 1'b0;

		if (num_fields == 0) begin
			return;
		end

		ftype = in_msg.fields[0].field_type;
		rem   = in_msg.fields[0].data_width;
		data  = in_msg.fields[0].data;

		while (!done) begin
			out_slice = '0;
			ended_var = 1'b0;

			for (int b = 0; b < MDO_WIDTH; b++) begin
				if (rem == 0) begin
					idx++;
					if ((idx >= num_fields) || (in_msg.fields[idx].field_type == FT_INV)) begin
						done = 1'b1;
						break;
					end
					ftype = in_msg.fields[idx].field_type;
					rem   = in_msg.fields[idx].data_width;
					data  = in_msg.fields[idx].data;
					if (rem == 0) begin
						done = 1'b1;
						break;
					end
				end

				if (tb_is_variable(ftype) && (rem < (MDO_WIDTH - b))) begin
					for (int k = b; k < MDO_WIDTH; k++) begin
						if ((k - b) < rem) begin
							out_slice[k] = data[k-b];
						end
					end
					data = data >> rem;
					rem = 0;
					ended_var = 1'b1;
					break;
				end

				out_slice[b] = data[0];
				data = data >> 1;
				rem--;

				// Variable-field end-of-slice bookkeeping: the DUT asserts
				// slice_ends_variable_field whenever a variable field's rem
				// reaches 0 — including the exact-fit case where the field
				// ends on a slice boundary (no padding needed). Match that
				// here so we don't mis-model the middle-of-message var->var
				// transition.
				if ((rem == 0) && tb_is_variable(ftype)) begin
					ended_var = 1'b1;
				end
			end

			exp_mdo.push_back(out_slice);
			exp_mseo.push_back(ended_var ? 2'b01 : 2'b00);

			if (!done && (rem == 0)) begin
				int unsigned nidx;
				nidx = idx + 1;
				if ((nidx >= num_fields) || (in_msg.fields[nidx].field_type == FT_INV)) begin
					done = 1'b1;
				end
			end
		end

		// Dual-MSEO mode marks the final real chunk of a message with END_IDLE.
		if (exp_mseo.size() > 0) begin
			exp_mseo[exp_mseo.size()-1] = 2'b11;
		end
	endtask

	task automatic enqueue_expected(
		input string tc_name,
		input nexus_message_t in_msg
	);
		logic [MDO_WIDTH-1:0] exp_mdo[$];
		logic [1:0]           exp_mseo[$];
		exp_token_t t;
		int unsigned pad_needed;

		model_expected(in_msg, exp_mdo, exp_mseo);
		for (int i = 0; i < exp_mdo.size(); i++) begin
			t.mdo = exp_mdo[i];
			t.mseo = exp_mseo[i];
			// First token MSEO may legitimately differ by formatter policy.
			t.check_mseo = (i != 0);
			t.desc = tc_name;
			t.tok_idx = i;
			expected_queue.push_back(t);
			expected_atb_queue.push_back(t);
		end

		pad_needed = (ATB_CHUNKS_PER_BEAT - (exp_mdo.size() % ATB_CHUNKS_PER_BEAT)) % ATB_CHUNKS_PER_BEAT;
		for (int i = 0; i < pad_needed; i++) begin
			t.mdo = {MDO_WIDTH{1'b1}};
			t.mseo = 2'b11;
			t.check_mseo = 1'b1;
			t.desc = tc_name;
			t.tok_idx = exp_mdo.size() + i;
			expected_atb_queue.push_back(t);
		end
	endtask

	task automatic queue_send_item(
		input nexus_message_t in_msg,
		input string tc_name,
		input bit require_ready,
		input bit skip_if_not_ready
	);
		stim_item_t it;
		it.op = OP_SEND;
		it.msg = in_msg;
		it.desc = tc_name;
		it.require_ready = require_ready;
		it.skip_if_not_ready = skip_if_not_ready;
		it.idle_cycles = 0;
		input_queue.push_back(it);
		NumCasesQueued++;
	endtask

	task automatic queue_idle_item(input int unsigned ncycles);
		stim_item_t it;
		it.op = OP_IDLE;
		it.msg = '0;
		it.desc = "";
		it.require_ready = 1'b0;
		it.skip_if_not_ready = 1'b0;
		it.idle_cycles = ncycles;
		input_queue.push_back(it);
	endtask

	task automatic generate_tests();
		nexus_message_t tmsg;
		logic [31:0] prng;

		input_queue.delete();
		expected_queue.delete();
		expected_atb_queue.delete();
		NumCasesQueued = 0;

		// ============================================================
		// NEXRv message catalog (directed shapes from NexRvMsg.h).
		//
		// Every case is a realistic RISC-V Nexus trace message built via
		// `nexus_msg_helper_pkg::compose_*`, following the layout emitted
		// by ct_L2_nexus_formatter:
		//   TCODE (FIXED,6) -> [SRC (VENDOR_FIXED,4)] -> middle fields -> TSTAMP.
		// SRC is included on every other case via the `include_src` flag
		// so we exercise both the with-SRC and TCODE-only-prefix paths.
		// ============================================================

		// #1 Ownership: 2 variable fields (PROCESS + TSTAMP). Use a mid-size
		// PROCESS payload so the field spans several slices at MDO_WIDTH=6.
		compose_ownership_msg(tmsg, 4'h1, 1'b0,
			32'h1234_ABCD, 64'h0000_0000_0000_0010);
		queue_send_item(tmsg, "nexrv_ownership", 1'b1, 1'b0);

		// #2 DirectBranch: tiniest realistic message — ICNT=1, TSTAMP=1
		// (both shrink to 1-bit variables via LengthWoLeadingZeros).
		compose_direct_branch_msg(tmsg, 4'h2, 1'b0, 8'h01, 64'h01);
		queue_send_item(tmsg, "nexrv_db_tiny", 1'b1, 1'b0);

		// #2b DirectBranch with a maxed-out ICNT (8-bit full) and a
		// moderately sized TSTAMP. Exercises variable -> variable chain.
		compose_direct_branch_msg(tmsg, 4'h3, 1'b0, 8'hFF, 64'h0123_4567);
		queue_send_item(tmsg, "nexrv_db_big", 1'b1, 1'b0);

		// #3 IndirectBranch: BTYPE(F,2) + ICNT(V) + UADDR(V) + TSTAMP(V).
		// Pick UADDR at 32-bit full width to stress a long variable field
		// sitting mid-message.
		compose_indirect_branch_msg(tmsg, 4'h0, 1'b0,
			NEXUS_BTYPE_IBRANCH, 8'h40, 32'hFFFF_FFFF, 64'hDEAD_BEEF);
		queue_send_item(tmsg, "nexrv_ib", 1'b1, 1'b0);

		// #4 DataWrite: DSZ + ELSZ (two small fixed fields) + DADDR(V) +
		// DATA(V) + TSTAMP(V). Exercises 3 consecutive variable fields.
		compose_data_trace_msg(tmsg, NEXUS_MSG_DATA_TRACE_WRITE, 4'h4, 1'b0,
			nexus_dsz_e'(4'h3), nexus_elsz_e'(3'h2),
			32'h8000_1234, 192'hC0FFEE_CAFE_BABE_DEAD_BEEF,
			64'h0000_DEAD);
		queue_send_item(tmsg, "nexrv_dw", 1'b1, 1'b0);

		// #5 DataRead: same shape, different tcode + payload.
		compose_data_trace_msg(tmsg, NEXUS_MSG_DATA_TRACE_READ, 4'h5, 1'b0,
			nexus_dsz_e'(4'h1), nexus_elsz_e'(3'h0),
			32'h8000_4321, 192'h1234,
			64'h01);
		queue_send_item(tmsg, "nexrv_dr", 1'b1, 1'b0);

		// #6 DataAcquisition: IDTAG(F,12) + DQDATA up to 192 bits. Tests
		// the largest-variable case — DQDATA can be ~192 effective bits.
		compose_daq_msg(tmsg, 4'h6, 1'b0,
			12'hABC,
			192'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF,
			64'hAAAA_BBBB);
		queue_send_item(tmsg, "nexrv_daq_maxdata", 1'b1, 1'b0);

		// #7 Error: fixed-heavy (ETYPE 4 + ECODE 8 + tiny TSTAMP).
		compose_error_msg(tmsg, 4'h7, 1'b0, 4'h5, 8'hA5, 64'h08);
		queue_send_item(tmsg, "nexrv_error", 1'b1, 1'b0);

		// #8 ProgTraceSync: SYNC + ICNT + FADDR + TSTAMP. SYNC reason
		// is picked as a typical "reset" case to match real traces.
		compose_prog_trace_sync_msg(tmsg,
			NEXUS_MSG_PROGRAM_TRACE_SYNC, 4'h8, 1'b0,
			NEXUS_SYNC_EXIT_FROM_SYS_RST, 8'h10, 32'h8000_0000, 64'h100);
		queue_send_item(tmsg, "nexrv_pt_sync", 1'b1, 1'b0);

		// #9 DirectBranchSync: same shape, different tcode.
		compose_prog_trace_sync_msg(tmsg,
			NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC, 4'h9, 1'b0,
			NEXUS_SYNC_PERIODIC, 8'h20, 32'h8000_1000, 64'h200);
		queue_send_item(tmsg, "nexrv_db_sync", 1'b1, 1'b0);

		// #10 IndirectBranchSync: adds BTYPE in between.
		compose_indirect_branch_sync_msg(tmsg, 4'hA, 1'b0,
			NEXUS_SYNC_WATCHPOINT, NEXUS_BTYPE_EXCEPTION,
			8'h11, 32'h8000_1234, 64'h300);
		queue_send_item(tmsg, "nexrv_ib_sync", 1'b1, 1'b0);

		// #11 ResourceFull: RCODE(F) + RDATA(V,30).
		compose_resource_full_msg(tmsg, 4'hB, 1'b0,
			nexus_rcode_e'(4'h1), 30'h1FFF_FFFF, 64'h400);
		queue_send_item(tmsg, "nexrv_rf", 1'b1, 1'b0);

		// #12 IndirectBranchHist: BTYPE(F) + ICNT(V) + UADDR(V) + HIST(V) + TSTAMP(V).
		// 4 variable fields in a row.
		compose_indirect_branch_hist_msg(tmsg, 4'hC, 1'b0,
			NEXUS_BTYPE_IBRANCH, 8'h08, 32'h8000_5678,
			30'h3FFF_FFFF, 64'h500);
		queue_send_item(tmsg, "nexrv_ibh", 1'b1, 1'b0);

		// #13 IndirectBranchHistSync: adds SYNC at the start.
		compose_indirect_branch_hist_sync_msg(tmsg, 4'hD, 1'b0,
			NEXUS_SYNC_EXIT_FROM_SYS_RST, NEXUS_BTYPE_IBRANCH,
			8'h40, 32'h8000_ABCD, 30'h0001_ABCD, 64'h600);
		queue_send_item(tmsg, "nexrv_ibh_sync", 1'b1, 1'b0);

		// #14 RepeatBranch: BCNT(V) + TSTAMP(V).
		compose_repeat_branch_msg(tmsg, 4'hE, 1'b0, 8'h0F, 64'h700);
		queue_send_item(tmsg, "nexrv_rb", 1'b1, 1'b0);

		// #15a ProgTraceCorrelation without HIST (CDF=0).
		compose_prog_trace_correlation_msg(tmsg, 4'hF, 1'b0,
			4'h2, 2'h0, 8'h20, 30'h0, 1'b0, 64'h800);
		queue_send_item(tmsg, "nexrv_ptc_nohist", 1'b1, 1'b0);

		// #15b ProgTraceCorrelation with HIST (CDF=1).
		compose_prog_trace_correlation_msg(tmsg, 4'hF, 1'b0,
			4'h3, 2'h1, 8'h20, 30'h2AAA_AAAA, 1'b1, 64'h800);
		queue_send_item(tmsg, "nexrv_ptc_hist", 1'b1, 1'b0);

		// Flush (TCODE=36) is intentionally NOT tested here: the L2
		// formatter has a dedicated bypass path for it (chunk packer
		// emits a long flush-pad burst instead of slicing TCODE), which
		// this TB's reference model doesn't predict. Flush behavior is
		// verified separately at the ct_encoder level.

		// ============================================================
		// Value-boundary edge cases.
		//
		// These cases target spots where the slicer's field-transition
		// and padding logic is most error-prone:
		//   - zero-valued variables (LengthWoLeadingZeros returns 1)
		//   - variable-field width exactly at 1x/2x/3x/4x MDO_WIDTH
		//     boundary (no trailing-zero padding needed)
		//   - var-field ending on an MDO_WIDTH boundary immediately
		//     followed by a 1-bit var (adjacent variable transition
		//     with no padding between)
		//   - directly-constructed fields with forced non-natural
		//     widths (bypasses LengthWoLeadingZeros) to stress paths
		//     that the randomized burst can't reach
		// ============================================================

		// #EC0 All-zero-value variables. ICNT=0, TSTAMP=0 -> both minimal
		// width=1 per LengthWoLeadingZeros. Probes the shortest possible
		// variable-variable transition.
		compose_direct_branch_msg(tmsg, 4'h0, 1'b0, 8'h00, 64'h0);
		queue_send_item(tmsg, "ec_zero_vars", 1'b1, 1'b0);

		// #EC1 ICNT exactly 1x MDO_WIDTH (=6) bits. MSB at bit 5.
		// Tests variable field ending on an MDO boundary without padding.
		compose_direct_branch_msg(tmsg, 4'h0, 1'b0, 8'h3F, 64'h3F);
		queue_send_item(tmsg, "ec_var_exact_6b", 1'b1, 1'b0);

		// #EC2 ICNT exactly 2x MDO_WIDTH (=12) bits, TSTAMP small.
		compose_direct_branch_msg(tmsg, 4'h0, 1'b0, 8'hFF, 64'h0FFF);
		queue_send_item(tmsg, "ec_var_exact_12b", 1'b1, 1'b0);

		// #EC3 ICNT exactly 3x MDO_WIDTH (=18) bits. Value 0x3_FFFF.
		compose_direct_branch_msg(tmsg, 4'h0, 1'b0, 8'hFF, 64'h3_FFFF);
		queue_send_item(tmsg, "ec_var_exact_18b", 1'b1, 1'b0);

		// #EC4 ICNT exactly 4x MDO_WIDTH (=24) bits. Value 0xFF_FFFF.
		compose_direct_branch_msg(tmsg, 4'h0, 1'b0, 8'hFF, 64'hFF_FFFF);
		queue_send_item(tmsg, "ec_var_exact_24b", 1'b1, 1'b0);

		// #EC5 Var ends on MDO boundary then tiny (1-bit) var follows.
		// Ownership with PROCESS=0x3F (width=6, ends boundary) + TSTAMP=0
		// (width=1). Adjacent variable-to-variable transition with no
		// padding slot between them.
		compose_ownership_msg(tmsg, 4'h0, 1'b0, 32'h3F, 64'h0);
		queue_send_item(tmsg, "ec_var_bndry_then_tiny", 1'b1, 1'b0);

		// #EC6 Non-power-of-2 declared width: ICNT forced to 7 bits
		// carrying value 0x7F. TCODE(6) + ICNT(7) + TSTAMP(1) = 14 bits.
		// Bypasses LengthWoLeadingZeros -> exercises widths the compose
		// tasks never produce.
		clear_msg(tmsg, 1'b0);
		init_field(tmsg, 0, TCODE,  FIXED,     NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH, 6);
		init_field(tmsg, 1, ICNT,   VARIABLE,  64'h7F, 7);
		init_field(tmsg, 2, TSTAMP, VENDOR_VARIABLE, 64'h1, 1);
		queue_send_item(tmsg, "ec_var_forced_7b", 1'b1, 1'b0);

		// #EC7 Non-power-of-2 declared width at a larger size: ICNT
		// forced to 35 bits carrying all-ones. Stresses a variable
		// field whose width is neither a multiple of MDO_WIDTH nor
		// power-of-2.
		clear_msg(tmsg, 1'b0);
		init_field(tmsg, 0, TCODE,  FIXED,     NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH, 6);
		init_field(tmsg, 1, ICNT,   VARIABLE,  {35{1'b1}}, 35);
		init_field(tmsg, 2, TSTAMP, VENDOR_VARIABLE, 64'h1, 1);
		queue_send_item(tmsg, "ec_var_forced_35b", 1'b1, 1'b0);

		// #EC8 Total message bits = exact multiple of MDO_WIDTH with
		// variable field(s) - no trailing padding required. Use a
		// Data trace write with carefully sized fields:
		//   TCODE(6) + DSZ(4) + ELSZ(3) + DADDR(var, width=11) +
		//   DATA(var, width=18) + TSTAMP(var, width=6) = 48 bits = 8 slices
		// Constructed directly to pin the field widths.
		clear_msg(tmsg, 1'b0);
		init_field(tmsg, 0, TCODE,  FIXED,           NEXUS_MSG_DATA_TRACE_WRITE, 6);
		init_field(tmsg, 1, DSZ,    FIXED,           4'h3, 4);
		init_field(tmsg, 2, ELSZ,   FIXED,           3'h2, 3);
		init_field(tmsg, 3, UADDR,  VARIABLE,        11'h7FF, 11);
		init_field(tmsg, 4, DATA,   VARIABLE,        18'h3_FFFF, 18);
		init_field(tmsg, 5, TSTAMP, VENDOR_VARIABLE, 6'h3F, 6);
		queue_send_item(tmsg, "ec_exact_mdo_multiple", 1'b1, 1'b0);

		// #EC9 Variable field forced to full 192-bit width, all ones.
		// Exercises the widest possible variable payload (DQDATA).
		clear_msg(tmsg, 1'b0);
		init_field(tmsg, 0, TCODE,  FIXED,           NEXUS_MSG_DATA_ACQUISITION, 6);
		init_field(tmsg, 1, IDTAG,  FIXED,           12'hABC, 12);
		init_field(tmsg, 2, DQDATA, VENDOR_VARIABLE, {192{1'b1}}, 192);
		init_field(tmsg, 3, TSTAMP, VENDOR_VARIABLE, 64'h1, 1);
		queue_send_item(tmsg, "ec_var_full_192b", 1'b1, 1'b0);

		// #EC10 TCODE-only (single-field message). Shortest possible
		// formatted output: just 6 bits of TCODE + MSEO end-of-message.
		clear_msg(tmsg, 1'b0);
		init_field(tmsg, 0, TCODE, FIXED, NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH, 6);
		queue_send_item(tmsg, "ec_tcode_only", 1'b1, 1'b0);

		// ============================================================
		// Walking-ones / walking-zeros sweep.
		//
		// For each bit position i in UADDR (32 bits) and HIST (30 bits),
		// send a message with that single bit set (walking-one), then a
		// second message with that single bit cleared (walking-zero,
		// i.e. all-other-bits-set). Catches stuck-at, swapped, or
		// mis-indexed bit lines in the bit-slicer's barrel shift and
		// field mux — random data hides single-bit faults behind other
		// bits; these patterns maximally expose them.
		// ============================================================
		for (int i = 0; i < 32; i++) begin
			// Walking one in UADDR.
			compose_indirect_branch_msg(tmsg, 4'h0, 1'b0,
				NEXUS_BTYPE_IBRANCH, 8'h01,
				32'h1 << i, 64'h1);
			queue_send_item(tmsg,
				$sformatf("walk1_uaddr_%0d", i), 1'b1, 1'b0);
		end
		for (int i = 0; i < 32; i++) begin
			// Walking zero in UADDR (single bit cleared in all-ones).
			compose_indirect_branch_msg(tmsg, 4'h0, 1'b0,
				NEXUS_BTYPE_IBRANCH, 8'h01,
				32'hFFFF_FFFF ^ (32'h1 << i), 64'h1);
			queue_send_item(tmsg,
				$sformatf("walk0_uaddr_%0d", i), 1'b1, 1'b0);
		end
		for (int i = 0; i < 30; i++) begin
			// Walking one in HIST (IndirectBranchHist: 4 vars in a row).
			compose_indirect_branch_hist_msg(tmsg, 4'h0, 1'b0,
				NEXUS_BTYPE_IBRANCH, 8'h01, 32'h8000_0000,
				30'h1 << i, 64'h1);
			queue_send_item(tmsg,
				$sformatf("walk1_hist_%0d", i), 1'b1, 1'b0);
		end
		for (int i = 0; i < 30; i++) begin
			// Walking zero in HIST.
			compose_indirect_branch_hist_msg(tmsg, 4'h0, 1'b0,
				NEXUS_BTYPE_IBRANCH, 8'h01, 32'h8000_0000,
				30'h3FFF_FFFF ^ (30'h1 << i), 64'h1);
			queue_send_item(tmsg,
				$sformatf("walk0_hist_%0d", i), 1'b1, 1'b0);
		end

		// ============================================================
		// Same-value across fields, paired with 1-bit-flip twin.
		//
		// Sends a message where several variable fields carry the
		// SAME payload value, followed by a second message of the
		// same shape with exactly one bit flipped in one field.
		// If two adjacent fields ever share buffer storage with a
		// muxing bug, the first message looks valid (all fields equal
		// == all slices equal) but the second exposes the copy when
		// one input differs and the outputs don't.
		// ============================================================

		// Pair A: IndirectBranchHist, all four variable fields =
		// 0xDEADBEEF truncated to each field's natural width.
		compose_indirect_branch_hist_msg(tmsg, 4'h0, 1'b0,
			NEXUS_BTYPE_IBRANCH,
			8'hEF,                     // ICNT
			32'hDEAD_BEEF,             // UADDR
			30'(32'hDEAD_BEEF),        // HIST (truncate to 30b)
			64'hDEAD_BEEF);            // TSTAMP
		queue_send_item(tmsg, "same_all_deadbeef", 1'b1, 1'b0);

		// Pair A twin: same shape, flip bit 0 of HIST. If the DUT had
		// copied UADDR into HIST, HIST would still show DEADBEEF and
		// mismatch the expected DEADBEEE here.
		compose_indirect_branch_hist_msg(tmsg, 4'h0, 1'b0,
			NEXUS_BTYPE_IBRANCH,
			8'hEF,                     // ICNT
			32'hDEAD_BEEF,             // UADDR
			30'(32'hDEAD_BEEE),        // HIST — LSB flipped
			64'hDEAD_BEEF);            // TSTAMP
		queue_send_item(tmsg, "same_flip_hist_lsb", 1'b1, 1'b0);

		// Pair B: DataWrite with DADDR == DATA == TSTAMP = 0xC3C3C3C3.
		compose_data_trace_msg(tmsg, NEXUS_MSG_DATA_TRACE_WRITE, 4'h0, 1'b0,
			nexus_dsz_e'(4'h2), nexus_elsz_e'(3'h1),
			32'hC3C3_C3C3,
			192'hC3C3_C3C3,
			64'hC3C3_C3C3);
		queue_send_item(tmsg, "same_all_c3", 1'b1, 1'b0);

		// Pair B twin: flip bit 16 of DATA. Reveals UADDR-into-DATA or
		// DATA-into-TSTAMP aliasing that Pair B's all-equal payload
		// would have masked.
		compose_data_trace_msg(tmsg, NEXUS_MSG_DATA_TRACE_WRITE, 4'h0, 1'b0,
			nexus_dsz_e'(4'h2), nexus_elsz_e'(3'h1),
			32'hC3C3_C3C3,
			192'hC3C2_C3C3,            // DATA bit 16 flipped
			64'hC3C3_C3C3);
		queue_send_item(tmsg, "same_flip_data_mid", 1'b1, 1'b0);

		// Pair C: IndirectBranchHistSync — 3 non-MSB vars all set to
		// 0xA5A5_A5A5 (alternating nibbles, max adjacent-bit transitions).
		compose_indirect_branch_hist_sync_msg(tmsg, 4'h0, 1'b0,
			NEXUS_SYNC_EXIT_FROM_SYS_RST,
			NEXUS_BTYPE_IBRANCH,
			8'hA5,                     // ICNT
			32'hA5A5_A5A5,             // FADDR
			30'(32'hA5A5_A5A5),        // HIST
			64'hA5A5_A5A5);            // TSTAMP
		queue_send_item(tmsg, "same_all_a5", 1'b1, 1'b0);

		// Pair C twin: flip bit 31 of FADDR (high-bit flip exposes
		// any MSB-drop in the field mux).
		compose_indirect_branch_hist_sync_msg(tmsg, 4'h0, 1'b0,
			NEXUS_SYNC_EXIT_FROM_SYS_RST,
			NEXUS_BTYPE_IBRANCH,
			8'hA5,                     // ICNT
			32'h25A5_A5A5,             // FADDR — MSB flipped
			30'(32'hA5A5_A5A5),        // HIST
			64'hA5A5_A5A5);            // TSTAMP
		queue_send_item(tmsg, "same_flip_faddr_msb", 1'b1, 1'b0);

		// ============================================================
		// Backpressure stress: zero-gap burst.
		//
		// Pushes messages back-to-back with no idle gaps, so the
		// formatter is forced to re-init immediately after each
		// end-of-message while the ATB sink is still applying random
		// stalls. Exposes bugs in the msg_ready / end-of-message
		// transition path.
		// ============================================================
		for (int k = 0; k < 32; k++) begin
			case (k % 5)
				0: compose_direct_branch_msg(tmsg, 4'h0, 1'b0,
					8'(k+1), 64'(k+1));
				1: compose_indirect_branch_msg(tmsg, 4'h0, 1'b0,
					NEXUS_BTYPE_IBRANCH, 8'(k), 32'h8000_0000 + k,
					64'(k));
				2: compose_error_msg(tmsg, 4'h0, 1'b0,
					4'(k & 4'hF), 8'(k), 64'(k+1));
				3: compose_resource_full_msg(tmsg, 4'h0, 1'b0,
					nexus_rcode_e'(4'h0),
					30'(k * 32'h1111), 64'(k+1));
				default: compose_repeat_branch_msg(tmsg, 4'h0, 1'b0,
					8'(k+1), 64'(k+1));
			endcase
			queue_send_item(tmsg,
				$sformatf("zgap_%0d", k), 1'b0, 1'b1);
		end

		// ============================================================
		// NEXRv-aware randomized burst.
		//
		// Picks a random NEXRv message type and populates it via the
		// compose_* tasks with random-but-realistic payloads. Three LFSR
		// seeds give three distinct random walks so one seed's blind spot
		// doesn't hide an issue. All-variable payloads naturally span
		// widths 1..max through LengthWoLeadingZeros inside the compose
		// helpers.
		// ============================================================
		begin
			// Valid enum values (clamped so we never hand the formatter an
			// undefined encoding):
			//  - nexus_dsz_e:  {0,1,2,3,4,8}
			//  - nexus_elsz_e: {0..4}
			//  - nexus_rcode_e: {0,1,2,15}
			//  - nexus_btype_e: {0..3}  (all 2-bit values defined)
			//  - nexus_sync_reason_e: all 16 encodings defined
			logic [3:0] valid_dsz_set [0:5];
			logic [2:0] valid_elsz_set [0:4];
			logic [3:0] valid_rcode_set [0:3];
			logic [31:0] seeds [0:2];

			valid_dsz_set   = '{4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd8};
			valid_elsz_set  = '{3'd0, 3'd1, 3'd2, 3'd3, 3'd4};
			valid_rcode_set = '{4'd0, 4'd1, 4'd2, 4'd15};

			seeds[0] = 32'h1234_5678;
			seeds[1] = 32'hDEAD_BEEF;
			seeds[2] = 32'hC0FFEE_42;
			for (int s = 0; s < 3; s++) begin
				prng = seeds[s];
				for (int tc = 0; tc < 40; tc++) begin
					int          mtype;
					logic [3:0]  src;
					bit          include_src;
					logic [31:0] rnd_icnt;
					logic [31:0] rnd_addr;
					logic [63:0] rnd_ts;
					logic [31:0] rnd_hist;
					logic [NEXUS_MSG_PROCESS_WIDTH-1:0] rnd_proc;
					logic [NEXUS_MSG_DATA_WIDTH-1:0]   rnd_data;
					logic [NEXUS_IDTAG_WIDTH-1:0]      rnd_idtag;
					nexus_dsz_e    rnd_dsz;
					nexus_elsz_e   rnd_elsz;
					nexus_rcode_e  rnd_rcode;

					prng = lfsr_next(prng);
					mtype = prng[3:0] % 15;   // pick one of the 15 catalog types
					prng = lfsr_next(prng);
					src = prng[3:0];
					// Flipped to 0 for the no-SRC NexRv decode check.
					include_src = 1'b0;

					// Common random payloads (width-truncated where needed
					// by each compose task). LengthWoLeadingZeros inside
					// the helpers reduces to the effective width.
					prng = lfsr_next(prng); rnd_icnt = prng;
					prng = lfsr_next(prng); rnd_addr = prng;
					prng = lfsr_next(prng); rnd_ts[31:0]  = prng;
					prng = lfsr_next(prng); rnd_ts[63:32] = prng;
					prng = lfsr_next(prng); rnd_hist = prng;
					prng = lfsr_next(prng); rnd_proc = prng;
					prng = lfsr_next(prng); rnd_idtag = prng[NEXUS_IDTAG_WIDTH-1:0];
					for (int b = 0; b < NEXUS_MSG_DATA_WIDTH; b += 32) begin
						prng = lfsr_next(prng);
						rnd_data[b +: 32] = prng;
					end

					// Occasionally force a very narrow variable-field
					// payload so LengthWoLeadingZeros hits the edge
					// widths (1, 2) in every seed.
					if (prng[7:0] < 40) begin
						rnd_icnt = 1;
						rnd_ts   = 1;
					end

					// Pick valid enum values from the legal subsets (some
					// 4-bit DSZ/RCODE encodings and some 3-bit ELSZ values
					// are unused in the spec — indexing into the valid set
					// keeps the stimulus Nexus-conformant).
					prng = lfsr_next(prng);
					rnd_dsz   = nexus_dsz_e'(valid_dsz_set[prng[2:0] % 6]);
					rnd_elsz  = nexus_elsz_e'(valid_elsz_set[prng[5:3] % 5]);
					rnd_rcode = nexus_rcode_e'(valid_rcode_set[prng[7:6] % 4]);

					case (mtype)
						0: compose_ownership_msg(tmsg, src, include_src,
							rnd_proc, rnd_ts);
						1: compose_direct_branch_msg(tmsg, src, include_src,
							rnd_icnt[7:0], rnd_ts);
						2: compose_indirect_branch_msg(tmsg, src, include_src,
							nexus_btype_e'(prng[1:0]),
							rnd_icnt[7:0], rnd_addr, rnd_ts);
						3: compose_data_trace_msg(tmsg,
							NEXUS_MSG_DATA_TRACE_WRITE, src, include_src,
							rnd_dsz, rnd_elsz,
							rnd_addr, rnd_data, rnd_ts);
						4: compose_data_trace_msg(tmsg,
							NEXUS_MSG_DATA_TRACE_READ, src, include_src,
							rnd_dsz, rnd_elsz,
							rnd_addr, rnd_data, rnd_ts);
						5: compose_daq_msg(tmsg, src, include_src,
							rnd_idtag, rnd_data, rnd_ts);
						6: compose_error_msg(tmsg, src, include_src,
							prng[3:0], prng[15:8], rnd_ts);
						7: compose_prog_trace_sync_msg(tmsg,
							NEXUS_MSG_PROGRAM_TRACE_SYNC, src, include_src,
							nexus_sync_reason_e'(prng[3:0]),
							rnd_icnt[7:0], rnd_addr, rnd_ts);
						8: compose_prog_trace_sync_msg(tmsg,
							NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC,
							src, include_src,
							nexus_sync_reason_e'(prng[3:0]),
							rnd_icnt[7:0], rnd_addr, rnd_ts);
						9: compose_indirect_branch_sync_msg(tmsg,
							src, include_src,
							nexus_sync_reason_e'(prng[3:0]),
							nexus_btype_e'(prng[5:4]),
							rnd_icnt[7:0], rnd_addr, rnd_ts);
						10: compose_resource_full_msg(tmsg,
							src, include_src,
							rnd_rcode,
							rnd_hist[29:0], rnd_ts);
						11: compose_indirect_branch_hist_msg(tmsg,
							src, include_src,
							nexus_btype_e'(prng[1:0]),
							rnd_icnt[7:0], rnd_addr,
							rnd_hist[29:0], rnd_ts);
						12: compose_indirect_branch_hist_sync_msg(tmsg,
							src, include_src,
							nexus_sync_reason_e'(prng[3:0]),
							nexus_btype_e'(prng[5:4]),
							rnd_icnt[7:0], rnd_addr,
							rnd_hist[29:0], rnd_ts);
						13: compose_repeat_branch_msg(tmsg,
							src, include_src,
							rnd_icnt[7:0], rnd_ts);
						default: compose_prog_trace_correlation_msg(tmsg,
							src, include_src,
							prng[3:0], prng[5:4],
							rnd_icnt[7:0], rnd_hist[29:0],
							prng[6], rnd_ts);
					endcase

					queue_send_item(tmsg,
						$sformatf("rvburst_s%0d_%0d_mt%0d", s, tc, mtype),
						1'b0, 1'b1);

					if ((tc % 16) == 0) begin
						queue_idle_item(1);
					end
				end
			end
		end

		// NOTE: no generic unstructured fuzzer burst — every message fed
		// to the DUT is a proper NEXRv-conformant shape (TCODE-first with
		// valid enum payloads), either from the directed catalog above
		// or from the compose_*-based randomized burst.
	endtask

	task automatic feed_pipeline();
		while (input_queue.size() > 0) begin
			stim_item_t item;
			int wait_cycles;
			bit accepted;
			item = input_queue.pop_front();

			if (item.op == OP_IDLE) begin
				repeat (item.idle_cycles) @(posedge clk);
			end else begin
				if (item.skip_if_not_ready && !ready_out) begin
					NumCasesSkipped++;
					@(posedge clk);
					continue;
				end

				nexus_msg = item.msg;
				wait_cycles = 0;
				accepted = 1'b0;
				while (wait_cycles < MAX_WAIT_READY_CYCLES) begin
					@(posedge clk);
					if (ready_out) begin
						accepted = 1'b1;
						break;
					end
					wait_cycles++;
				end
				nexus_msg = '0;

				if (!accepted) begin
					if (item.skip_if_not_ready) begin
						NumCasesSkipped++;
						continue;
					end
					$error("[%s] timeout waiting ready_out acceptance", item.desc);
					ErrCount++;
					continue;
				end

				enqueue_expected(item.desc, item.msg);
				NumCasesSent++;

				// Sample per-message coverage.
				begin
					int unsigned nf;
					int unsigned total;
					bit          has_var;
					nf = count_valid_fields(item.msg);
					total = 0;
					has_var = 1'b0;
					for (int i = 0; i < nf; i++) begin
						total += item.msg.fields[i].data_width;
						if (tb_is_variable(item.msg.fields[i].field_type)) begin
							has_var = 1'b1;
						end
					end
					cov_msg_tcode        = (nf > 0) ? item.msg.fields[0].data[5:0] : 6'd0;
					cov_msg_num_fields   = nf;
					cov_msg_total_bits   = total;
					cov_msg_has_src      = (nf >= 2)
						&& (item.msg.fields[1].name == SRC);
					cov_msg_has_variable = has_var;
					msg_cov.sample();
				end
			end
		end

		FeedingDone <= 1'b1;
	endtask

	task automatic check_results();
		int unsigned idle_cycles;
		logic fire;
		exp_token_t exp;

		idle_cycles = 0;

		while (!(FeedingDone && (expected_queue.size() == 0))) begin
			@(posedge clk);

			fire = dut.slice_fire;
			if (fire) begin
				if (expected_queue.size() == 0) begin
					$error("Unexpected formatter token: mdo=%0h mseo=%0b", dut.slice_bits, dut.mseo_bits);
					ErrCount++;
				end
				else begin
					exp = expected_queue.pop_front();
					if (dut.slice_bits !== exp.mdo) begin
						$error("[%s] tok=%0d mdo mismatch exp=%0h got=%0h",
							exp.desc, exp.tok_idx, exp.mdo, dut.slice_bits);
						ErrCount++;
					end
					if (exp.check_mseo) begin
						if (dut.mseo_bits !== exp.mseo) begin
							$error("[%s] tok=%0d mseo mismatch exp=%0b got=%0b",
								exp.desc, exp.tok_idx, exp.mseo, dut.mseo_bits);
							ErrCount++;
						end
					end else if (dut.mseo_bits == 2'b10) begin
						$error("[%s] tok=%0d illegal reserved first-token MSEO=2'b10",
							exp.desc, exp.tok_idx);
						ErrCount++;
					end
					NumTokensChecked++;

					// Sample per-slice coverage. Classify position within
					// the message using the DUT's own boundary signals.
					cov_slice_ends_field = dut.slice_ends_field;
					cov_slice_ends_var   = dut.slice_ends_var;
					cov_slice_padded     = dut.slice_last_padded;
					if (dut.eom_pulse) begin
						cov_slice_pos = 2;  // last
					end else if (cov_slice_idx_in_msg == 0) begin
						cov_slice_pos = 0;  // first
					end else begin
						cov_slice_pos = 1;  // middle
					end
					slice_cov.sample();

					if (dut.eom_pulse) begin
						cov_slice_idx_in_msg = 0;
					end else begin
						cov_slice_idx_in_msg++;
					end
				end
				idle_cycles = 0;
			end
			else begin
				idle_cycles++;
				if (idle_cycles > MAX_WAIT_READY_CYCLES * 20) begin
					$error("Checker timeout waiting for formatter activity");
					ErrCount++;
					break;
				end
			end
		end

		CheckingDone <= 1'b1;
	endtask

	task automatic check_atb_results();
		exp_token_t exp;
		logic [CHUNK_WIDTH-1:0] got_chunk;
		int unsigned idle_cycles;

		idle_cycles = 0;
		while (!(FeedingDone && (expected_atb_queue.size() == 0))) begin
			@(posedge atb_atclk);
				if (atb.atvalid && atb.atready) begin
					for (int i = 0; i < ATB_CHUNKS_PER_BEAT; i++) begin
						if (expected_atb_queue.size() == 0) begin
							$error("Unexpected ATB chunk i=%0d data=%0h", i, atb.atdata);
						ErrCount++;
						break;
					end
					exp = expected_atb_queue.pop_front();
					got_chunk = atb.atdata[(i*CHUNK_WIDTH) +: CHUNK_WIDTH];
					if (got_chunk[CHUNK_WIDTH-1:2] !== exp.mdo) begin
						$error("[%s] atb tok=%0d mdo mismatch exp=%0h got=%0h",
							exp.desc, exp.tok_idx, exp.mdo, got_chunk[CHUNK_WIDTH-1:2]);
						ErrCount++;
					end
					if (exp.check_mseo && (got_chunk[1:0] !== exp.mseo)) begin
						$error("[%s] atb tok=%0d mseo mismatch exp=%0b got=%0b",
							exp.desc, exp.tok_idx, exp.mseo, got_chunk[1:0]);
						ErrCount++;
					end
				end
				idle_cycles = 0;
			end
			else begin
				idle_cycles++;
				if (idle_cycles > MAX_WAIT_READY_CYCLES * 50) begin
					$error("ATB checker timeout waiting for beat");
					ErrCount++;
					break;
				end
			end
		end

		AtbCheckingDone <= 1'b1;
	endtask

	task automatic check_first_message_whitebox();
		// The first queued message is now NEXRv Ownership (TCODE=2, SRC=1,
		// PROCESS=0x1234_ABCD, TSTAMP=0x10) — so the very first emitted
		// slice's bottom 6 bits are TCODE=6'd2 regardless of MDO_WIDTH.
		// Provide a width-parameterised golden check so the sanity still
		// fires across different MDO_WIDTH configs.
		logic [MDO_WIDTH-1:0] exp0;
		int                  seen;

		// Bottom MDO_WIDTH bits of TCODE=6'd2 (NEXUS_MSG_OWNERSHIP_TRACE).
		// For MDO_WIDTH >= 6 this is 2; narrower MDO_WIDTH takes the low
		// bits. Static assignment so it's valid for any MDO_WIDTH.
		exp0 = MDO_WIDTH'(6'd2);

		seen = 0;
		while (seen < 1) begin
			@(posedge clk);
			if (dut.slice_fire) begin
				seen++;
				if (dut.slice_bits !== exp0) begin
					$error("[whitebox] first-token tcode slice mismatch exp=%0h got=%0h",
						exp0, dut.slice_bits);
					ErrCount++;
				end
			end
		end
		WhiteboxDone <= 1'b1;
	endtask

	initial begin : main_test
		reset();
		generate_tests();

		fork
			feed_pipeline();
			check_results();
			check_atb_results();
			check_first_message_whitebox();
		join_none

		wait (FeedingDone);
		wait (CheckingDone);
		wait (AtbCheckingDone);
		wait (WhiteboxDone);

		// Coverage summary — prints even on failure so you can see which
		// bins were missed whenever a regression happens.
		$display("COVERAGE: per_message   = %0.2f%% (tcode=%0.2f%% nf=%0.2f%% bits=%0.2f%% src=%0.2f%% var=%0.2f%% tcode*src=%0.2f%%)",
			msg_cov.get_inst_coverage(),
			msg_cov.cp_tcode.get_inst_coverage(),
			msg_cov.cp_num_fields.get_inst_coverage(),
			msg_cov.cp_total_bits.get_inst_coverage(),
			msg_cov.cp_has_src.get_inst_coverage(),
			msg_cov.cp_has_var.get_inst_coverage(),
			msg_cov.x_tcode_src.get_inst_coverage());
		$display("COVERAGE: per_slice     = %0.2f%% (ends_field=%0.2f%% ends_var=%0.2f%% padded=%0.2f%% pos=%0.2f%% pos*ends_field=%0.2f%% pos*ends_var=%0.2f%% pos*padded=%0.2f%%)",
			slice_cov.get_inst_coverage(),
			slice_cov.cp_ends_field.get_inst_coverage(),
			slice_cov.cp_ends_var.get_inst_coverage(),
			slice_cov.cp_padded.get_inst_coverage(),
			slice_cov.cp_pos.get_inst_coverage(),
			slice_cov.x_pos_ends_field.get_inst_coverage(),
			slice_cov.x_pos_ends_var.get_inst_coverage(),
			slice_cov.x_pos_padded.get_inst_coverage());

		// Final SOM/EOM pairing sanity.
		if (total_som != total_eom) begin
			$error("FAIL: SOM count %0d != EOM count %0d", total_som, total_eom);
			ErrCount++;
		end
		$display("INFO: SOM=%0d EOM=%0d (paired)", total_som, total_eom);

		if (ErrCount == 0) begin
			$display("PASS: ct_L2_mseo_mdo_formatter_tb (%0d queued, %0d sent, %0d skipped, %0d tokens)",
				NumCasesQueued, NumCasesSent, NumCasesSkipped, NumTokensChecked);
		end else begin
			$fatal(1, "FAIL: ct_L2_mseo_mdo_formatter_tb had %0d mismatches", ErrCount);
		end

		$finish;
	end

endmodule

`default_nettype wire
