// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Data-address compression (P3): XOR mode + TCODE 13/14 re-anchors.
 *
 * @details
 *   System test for CT_EN_DF_ADDR_COMPRESS with trTeDataAddrCompress = XOR
 *   (E-P3-2: the only implemented mode). Data-trace ONLY (InstTracing=0),
 *   for two reasons: the strict --ctxp line diff applies only to
 *   pure-memory streams (see the sim-combined note in the Makefile), and a
 *   data-only stream isolates the DF re-anchor triggers that do NOT come
 *   from CF syncs.
 *
 *   Scenario:
 *     - WARL probes before Enable: writing the unimplemented modes 2
 *       (DIFF) / 3 (XOR_DIFF) must legalize to 0 (FULL); writing 1 (XOR)
 *       must stick. $fatal on any mismatch (negative gate, E-P3-2).
 *     - Block accesses: four word stores at BUF_BLK+0/4/8/12 (small XOR
 *       deltas -- the compression win case).
 *     - Scatter accesses: loads at widely separated addresses including an
 *       odd byte address (large deltas, byte-granularity -- the worst
 *       case; XOR may be LONGER than LZS on the full address here, which
 *       is fine: correctness leg, measurement is P3 step 6).
 *     - DataTracing OFF window WITH accesses inside: they must NOT reach
 *       the wire (negative gate "no DF while DataTracing=0").
 *     - DataTracing ON again: the rising edge is re-anchor trigger T2(b),
 *       so the first DF message after it is the synchronizing 13/14 form.
 *
 *   DataTracing-edge alignment guard (P3-F1, red-proven -- see below): the
 *   two CSR edges are placed DELIBERATELY WITHOUT a quiesce, i.e. inside
 *   the preproc pipeline latency (max_delay-1 tip cycles) after the
 *   neighbouring access. That is the exact window in which the pre-fix
 *   encoder qualified DELAYED tip beats with the LIVE trTeDataTracing:
 *     (a) off edge  -> the last traced access before it (the BLK+8 load)
 *                      was silently dropped;
 *     (b) on edge   -> the last off-window access (the 0xBBBB_0000 load)
 *                      leaked onto the wire AS the 13/14 re-anchor, and the
 *                      next access XOR'd against that bogus reference.
 *   Fixed by DtaPipe/data_trace_active_q (ct_L23_preproc /
 *   ct_L23_preproc_df -- the DF twin of the existing ItaPipe fix). Both
 *   directions are gated here: (a) by the exact TCODE sequence (the BLK+8
 *   load must be present -> 10 data messages), (b) by --data/--ctxp
 *   (0xAAAA_0000 / 0xBBBB_0000 must appear NOWHERE) plus the sequence
 *   (exactly two 13/14). Pre-fix evidence: 9 messages, LOAD 0x00020008
 *   missing (2026-08-04 08:50 run); leak variant: MSG#8 TCODE 14
 *   DADDR=0xbbbb0000 with MSG#9 XOR'd against it.
 *
 *   Expected stream structure (checked by scripts/cli_dfcompress_test.sh):
 *   exactly two 13/14 messages -- one at the stream head (initial
 *   DataTracing edge; a data-only run has no CF sync and no config
 *   message, so this leading 13/14 is the decoder's ONLY anchor:
 *   stream-evidence auto-enable in NexRv), one directly after the OFF->ON
 *   edge (the first post-edge access, full address) -- and every other
 *   data message is a plain XOR-compressed 5/6.
 *
 *   Verification (scripts/cli_dfcompress_test.sh):
 *     decode_and_check.sh --data --ctxp --sync 2 addr_compress_tb
 *   --ctxp is the primary value-aware round-trip (MEMREAD/MEMWRITE with
 *   reconstructed FULL addresses + data values), --data the sequence
 *   check; --sync 2 demonstrates that 13/14 count as synchronizing
 *   messages. Structural TCODE-sequence checks live in the cli script.
 */

module addr_compress_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;   // BITPOS_* field positions (WARL probes)

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (4),
		.ATB_DUMP_PATH       ("addr_compress_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("addr_compress_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("addr_compress_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("addr_compress_tb.expected.pcs"),
		.EXPECTED_DATA_PATH  ("addr_compress_tb.expected.data"),
		.EXPECTED_CTXP_PATH  ("addr_compress_tb.expected.ctxp")
	) env ();

	localparam logic [31:0] MAIN_PC  = 32'h0000_1000;
	// Block-access buffer (sequential words -> small XOR deltas).
	localparam logic [31:0] BUF_BLK  = 32'h0002_0000;
	// Scatter addresses (large XOR deltas; SCAT_B is deliberately ODD --
	// data addresses are byte-granular, there is no PC-style shift).
	localparam logic [31:0] SCAT_W   = 32'h7FF0_0000;
	localparam logic [31:0] SCAT_B   = 32'h000F_FFF3;
	localparam logic [31:0] SCAT_D   = 32'h4000_1008;
	// Off-window addresses: unique bit patterns that appear NOWHERE else,
	// so a leak is unmistakable in the decoded event list (and in a raw
	// XOR delta) instead of aliasing with a legitimate access.
	localparam logic [31:0] OFF_ST   = 32'hAAAA_0000;
	localparam logic [31:0] OFF_LD   = 32'hBBBB_0000;

	localparam int DSIZE_B = 0;   // 1 byte
	localparam int DSIZE_H = 1;   // 2 bytes
	localparam int DSIZE_W = 2;   // 4 bytes
	localparam int DSIZE_D = 3;   // 8 bytes

	localparam logic [1:0] MODE_FULL     = ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e__DTR_ADDR_FULL;
	localparam logic [1:0] MODE_XOR      = ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e__DTR_ADDR_XOR;
	localparam logic [1:0] MODE_DIFF     = 2'd2;   // unimplemented (E-P3-2)
	localparam logic [1:0] MODE_XOR_DIFF = 2'd3;   // unimplemented (E-P3-2)

	logic [31:0] dc_read;

	// WARL probe: write a DataAddrCompress mode, read it back, $fatal on
	// mismatch. Runs before Enable so no stream is disturbed.
	task automatic probe_mode(input logic [1:0] wr, input logic [1:0] exp);
		env.csr.Set_te_trTeDataControl_DataAddrCompress(wr);
		env.csr.Read_te_trTeDataControl(dc_read);
		if (dc_read[BITPOS_te_trTeDataControl_DataAddrCompress_LSB +: 2] !== exp)
			$fatal(1, "[addr_compress_tb] WARL: wrote DataAddrCompress=%0d, read %0d, expected %0d",
				wr, dc_read[BITPOS_te_trTeDataControl_DataAddrCompress_LSB +: 2], exp);
		$display("[addr_compress_tb] WARL probe: write %0d -> read %0d (expected %0d) OK",
			wr, dc_read[BITPOS_te_trTeDataControl_DataAddrCompress_LSB +: 2], exp);
	endtask

	initial begin
		$display("[addr_compress_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[addr_compress_tb] %0t: reset released", $time);

		env.csr.clear();

		// ---- WARL negative gate (E-P3-2: XOR-only) ----
		probe_mode(MODE_DIFF,     MODE_FULL);  // 2 -> legalized to 0
		probe_mode(MODE_XOR_DIFF, MODE_FULL);  // 3 -> legalized to 0
		probe_mode(MODE_XOR,      MODE_XOR);   // 1 -> sticks (feature present)

		// ---- Configure: data trace only, XOR compression ----
		env.csr.Set_te_trTeControl_Enable          (1'b1);
		env.csr.Set_te_trTeControl_InstTracing     (1'b0);
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.csr.Set_te_trTeControl_Active          (1'b1);
		env.cpu.idle(20);
		$display("[addr_compress_tb] %0t: starting scenario", $time);

		// Data-only stream: no SYNC / CF records in the CTXP reference.
		env.cpu.set_inst_traced(1'b0);

		// ============================================================
		// Scenario
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(8);                                               // 2 L

		// Block accesses (sequential words, small XOR deltas). The FIRST
		// data message of the stream must be TCODE 13 (DataWriteSync):
		// initial DataTracing edge = re-anchor trigger T2(b).
		env.cpu.store_data(.addr(BUF_BLK + 32'h0), .size(DSIZE_W),
		                   .data(64'h0000_0000_1111_1111));
		env.cpu.store_data(.addr(BUF_BLK + 32'h4), .size(DSIZE_W),
		                   .data(64'h0000_0000_2222_2222));
		env.cpu.store_data(.addr(BUF_BLK + 32'h8), .size(DSIZE_W),
		                   .data(64'h0000_0000_3333_3333));
		env.cpu.store_data(.addr(BUF_BLK + 32'hC), .size(DSIZE_W),
		                   .data(64'h0000_0000_4444_4444));
		env.cpu.run(8);                                               // 2 L

		// Scatter accesses (large deltas, mixed sizes, odd byte address).
		env.cpu.load_data (.addr(SCAT_W), .size(DSIZE_W));
		env.cpu.load_data (.addr(SCAT_B), .size(DSIZE_B));
		env.cpu.load_data (.addr(SCAT_D), .size(DSIZE_D));
		// The LAST traced access before the falling DataTracing edge. NO
		// quiesce follows on purpose: the edge lands INSIDE the preproc
		// pipeline latency after this retire -- the alignment guard (a)
		// from the header. It must still reach the wire as a plain XOR 6.
		env.cpu.load_data (.addr(BUF_BLK + 32'h8), .size(DSIZE_W));
		env.cpu.run(8);                                               // 2 L

		// ---- DataTracing OFF window (accesses inside must be dropped) ----
		env.csr.Set_te_trTeDataControl_DataTracing (1'b0);
		env.cpu.set_data_traced(1'b0);   // oracle mirror
		env.cpu.idle(50);                // let the edge land tip-side
		env.cpu.store_data(.addr(OFF_ST), .size(DSIZE_W), .data(64'hDEAD_DEAD));
		env.cpu.load_data (.addr(OFF_LD), .size(DSIZE_W));
		// Again NO quiesce before the rising edge: the 0xBBBB_0000 load
		// retires inside the pipeline latency ahead of it -- alignment
		// guard (b). Neither off-window address may appear on the wire.
		env.cpu.run(8);                                               // 2 L

		// ---- DataTracing ON again: rising edge = T2(b) re-anchor. The
		// first DF message after it carries its own FULL address in the
		// synchronizing 13/14 form; the access after that XORs against it.
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.cpu.set_data_traced(1'b1);   // oracle mirror
		env.cpu.idle(50);                // let the edge land tip-side
		env.cpu.load_data (.addr(BUF_BLK + 32'h12), .size(DSIZE_B));
		env.cpu.store_data(.addr(BUF_BLK + 32'h2), .size(DSIZE_H),
		                   .data(64'h0000_0000_0000_5678));
		env.cpu.run(8);                                               // 2 L
		env.cpu.exit_trace();

		// ---- Drain (data_basic pattern) ----
		env.csr.Set_te_trTeControl_InstSyncReq (1'b1);
		env.cpu.idle(200);
		env.atb_force_sync  = 1'b1;
		env.atb_force_flush = 1'b1;
		env.cpu.idle(2000);
		env.atb_force_sync  = 1'b0;
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(10000);

		// ---- Liveness checks ----
		if (env.cpu.event_count() == 0) begin
			$error("[addr_compress_tb] cpu_model event log empty");
		end else begin
			$display("[addr_compress_tb] cpu_model logged %0d events", env.cpu.event_count());
		end
		if (env.atb_bytes_seen == 0) begin
			$error("[addr_compress_tb] no ATB bytes observed");
		end else begin
			$display("[addr_compress_tb] observed %0d ATB transfers", env.atb_bytes_seen);
		end

		$display("[addr_compress_tb] PASS (sim); decode gates run from cli_dfcompress_test.sh");
		$display("[addr_compress_tb] ATB binary trace:");
		$system("realpath addr_compress_tb.atb.bin");
		$finish;
	end

	// Hard timeout
	initial begin
		#10ms;
		$error("[addr_compress_tb] TIMEOUT - test exceeded 10 ms wall time");
		$finish;
	end

endmodule : addr_compress_tb

`default_nettype wire
