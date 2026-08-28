// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_cs_micro_tb.sv
 * @brief   Read-back equivalence testbench for the hand-written CF-slim CSR
 *          block (ct_cs_micro, selected by ct_pkg::CT_MICRO_CSR).
 * @details The micro block promises "byte-identical values" to the generated
 *   PeakRDL block, and until the P8 closing audit nothing measured that:
 *   no build in the repository sets CT_MICRO_CSR = 1. P8 widened
 *   trTeSyncStatus.SyncReqSource to three bits (SYNC_REQ_TE = 4), carried the
 *   generated block along and left the twin at a [1:0] slice -- so the new
 *   source read back as 0, "nobody has asked for a sync since reset", which
 *   is the ONLY software discovery the feature has (D-P8-2).
 *
 *   This testbench instantiates BOTH register blocks side by side on the
 *   same cpuif request stream and the same hwif_in, and compares what
 *   software would read. The static twin: scripts/check_micro_csr_twin.py.
 *
 * @environment One clock; both blocks combinational on the read path (the
 *   micro block acks in the same cycle, the generated one registers the read
 *   data, so the comparison samples after the generated block's ack).
 * @stimulus Drives every encoding of trTeSyncStatus.SyncReqSource (0..7 --
 *   the field is three bits wide, so all eight values must survive) and
 *   reads 0xe08 through both blocks.
 * @checking Read-back == driven value in the micro block, and micro ==
 *   generated for the same drive.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_cs_micro_tb;

	import tt::*;
	import ct_cs_cpuif_pkg::*;

	logic clk = 0; always #5 clk = ~clk;
	logic rst = 1;

	logic        cpuif_req       = 1'b0;
	logic        cpuif_req_is_wr = 1'b0;
	logic [14:0] cpuif_addr      = 15'h0;

	ct_cs_cpuif__in_t  hwif_in;
	ct_cs_cpuif__out_t hwif_out_micro;
	ct_cs_cpuif__out_t hwif_out_gen;

	// Taken from the generated interface struct, not written down: a field
	// that is widened again must widen this probe with it.
	localparam int unsigned SRC_W =
		$bits(hwif_in.te.trTeSyncStatus.SyncReqSource.next);

	uwire logic [31:0] rd_data_micro, rd_data_gen;
	uwire logic        rd_ack_micro,  rd_ack_gen;
	uwire logic        stall_rd_gen;

	ct_cs_micro dut_micro (
		.clk, .rst,
		.s_cpuif_req          (cpuif_req),
		.s_cpuif_req_is_wr    (cpuif_req_is_wr),
		.s_cpuif_addr         (cpuif_addr),
		.s_cpuif_wr_data      (32'h0),
		.s_cpuif_wr_biten     (32'hffff_ffff),
		.s_cpuif_req_stall_wr (),
		.s_cpuif_req_stall_rd (),
		.s_cpuif_rd_ack       (rd_ack_micro),
		.s_cpuif_rd_err       (),
		.s_cpuif_rd_data      (rd_data_micro),
		.s_cpuif_wr_ack       (),
		.s_cpuif_wr_err       (),
		.hwif_in              (hwif_in),
		.hwif_out             (hwif_out_micro)
	);

	// The reference: the generated block on the SAME stimulus. It is the
	// definition of what software sees in a non-slim build, so a difference
	// on a register both of them implement is drift by construction.
	ct_cs_cpuif dut_gen (
		.clk, .rst,
		.s_cpuif_req          (cpuif_req),
		.s_cpuif_req_is_wr    (cpuif_req_is_wr),
		.s_cpuif_addr         (cpuif_addr),
		.s_cpuif_wr_data      (32'h0),
		.s_cpuif_wr_biten     (32'hffff_ffff),
		.s_cpuif_req_stall_wr (),
		.s_cpuif_req_stall_rd (stall_rd_gen),
		.s_cpuif_rd_ack       (rd_ack_gen),
		.s_cpuif_rd_err       (),
		.s_cpuif_rd_data      (rd_data_gen),
		.s_cpuif_wr_ack       (),
		.s_cpuif_wr_err       (),
		.hwif_in              (hwif_in),
		.hwif_out             (hwif_out_gen)
	);

	// One read transaction through both blocks; returns when the GENERATED
	// block acks (the slower of the two -- the micro block acks combinationally
	// in the same cycle).
	task automatic csr_read(input logic [14:0] addr,
	                        output logic [31:0] d_micro,
	                        output logic [31:0] d_gen);
		@(negedge clk);
		cpuif_addr      = addr;
		cpuif_req_is_wr = 1'b0;
		cpuif_req       = 1'b1;
		@(negedge clk);
		cpuif_req       = 1'b0;
		d_micro = rd_data_micro;
		while (!rd_ack_gen) @(negedge clk);
		d_gen   = rd_data_gen;
		@(negedge clk);
	endtask

	initial begin
		automatic logic [31:0] dm, dg;

		$display("PROBE: SyncReqSource.next is %0d bit(s) wide", SRC_W);
		void'(tt_assert(SRC_W == 3, $sformatf(
			"Line %0d: Test failed: SyncReqSource is %0d bit(s) wide, expected 3 since P8",
			`__LINE__, SRC_W)));

		// Aggregate default, not '0: the hwif struct is a nest of unpacked
		// structs and xsim rejects a packed-to-unpacked assignment.
		hwif_in = '{default: '0};
		repeat (4) @(negedge clk);
		rst = 0;
		repeat (4) @(negedge clk);

		// trTeSyncStatus @0xe08 -- every encoding the three-bit field carries.
		// 4 = SYNC_REQ_TE is the P8 value the twin used to truncate to 0.
		for (int unsigned v = 0; v < (1 << SRC_W); v++) begin
			hwif_in.te.trTeSyncStatus.SyncReqSource.next = SRC_W'(v);
			csr_read(15'he08, dm, dg);
			$display("PROBE: driven SyncReqSource = %0d  ->  micro CSR readback 0xE08[2:0] = %0d  |  generated block = %0d",
			         v, dm[2:0], dg[2:0]);
			void'(tt_assert(dm[31:0] == 32'(v), $sformatf(
				"Line %0d: Test failed: micro CSR read 0x%08h for SyncReqSource = %0d",
				`__LINE__, dm, v)));
			void'(tt_assert(dm == dg, $sformatf(
				"Line %0d: Test failed: micro CSR reads 0x%08h where the generated block reads 0x%08h (SyncReqSource = %0d)",
				`__LINE__, dm, dg, v)));
		end

		// Negative control: the field is hardware-driven, so a value the
		// hardware does not present must not appear -- reading 0xe08 back to
		// back with the drive removed returns SYNC_REQ_NONE in both blocks.
		hwif_in.te.trTeSyncStatus.SyncReqSource.next = '0;
		csr_read(15'he08, dm, dg);
		$display("PROBE: drive removed              ->  micro CSR readback 0xE08[2:0] = %0d  |  generated block = %0d",
		         dm[2:0], dg[2:0]);
		void'(tt_assert((dm == 32'h0) && (dg == 32'h0), $sformatf(
			"Line %0d: Test failed: 0xe08 reads micro 0x%08h / generated 0x%08h with no source driven",
			`__LINE__, dm, dg)));

		tt_evaluate();
		$finish();
	end

endmodule
