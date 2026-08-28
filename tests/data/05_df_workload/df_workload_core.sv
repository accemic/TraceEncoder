// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Large DF workload (P3 step 6, D-P3-8): >= 10 000 data accesses.
 *
 * @details
 *   Shared scenario core for the DF-address-compression bandwidth
 *   measurement. The two thin tops (df_workload_tb = XOR,
 *   df_workload_full_tb = FULL) elaborate this module with USE_XOR 1/0 --
 *   the ACCESS SEQUENCE is parameter-independent by construction, so the
 *   two ATB streams differ only in the DF address encoding and are
 *   byte-comparable (Plan P3.4: absolute numbers on a real-sized workload;
 *   the existing DF testbenches have < 25 events and are Denominator-
 *   artefact territory).
 *
 *   Workload (deterministic, LFSR-seeded, 10 336 accesses):
 *     Phase 1 sequential : 4096 word stores walking BUF_SEQ upward in
 *                          4-byte steps (small XOR deltas -- the win case).
 *     Phase 2 scattered  : 3072 loads at 31-bit LFSR addresses with
 *                          rotating access size incl. odd byte addresses
 *                          (large deltas -- the loss case; data addresses
 *                          are byte-granular, no PC shift).
 *     Phase 3 stack mix  : 1536 push/pop pairs walking DOWN from STACK_TOP
 *                          in 8-byte steps (store+load on the same slot,
 *                          alternating direction pattern) plus one
 *                          scattered store every 16th pair.
 *   Pacing: idle(16) after every 4 accesses -- keeps the eTIP FIFO ahead of
 *   the producer so the stream stays overflow-free (a TCODE 8 in either leg
 *   is a gate FAIL: lost events would corrupt the byte comparison).
 *
 *   Data-only stream (InstTracing=0), same rationale as test 03: the DF
 *   share IS the stream, so the byte accounting in
 *   scripts/cli_dfworkload_test.sh attributes cleanly.
 *
 *   Verification (scripts/cli_dfworkload_test.sh):
 *     - both legs: decode_and_check --data (hard oracle compare, 10 336
 *       events), no ERROR message, dump-vs-Stat byte-sum validation;
 *     - XOR leg: leading TCODE 13 anchor (stream evidence), equal DFEVT
 *       count against the FULL leg;
 *     - absolute byte numbers (ATB file / message bytes / DF bytes) are
 *       REPORTED, not asserted -- they are the P3 step-6 measurement and
 *       live in the handoff with raw-data paths (no ratio headlines).
 */

module df_workload_core #(
	parameter bit    USE_XOR = 1'b1,
	parameter string PFX     = "df_workload_tb"
);

	import cpu_model_pkg::*;
	import ct_cs_cpuif_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (4),
		.ATB_DUMP_PATH       ({PFX, ".atb.bin"}),
		.TIP_DUMP_TXT_PATH   ({PFX, ".tip.txt"}),
		.NEXRV_INFO_PATH     ({PFX, ".nexrv.info"}),
		.EXPECTED_PCS_PATH   ({PFX, ".expected.pcs"}),
		.EXPECTED_DATA_PATH  ({PFX, ".expected.data"})
	) env ();

	localparam logic [31:0] MAIN_PC   = 32'h0000_1000;
	localparam logic [31:0] BUF_SEQ   = 32'h0002_0000;   // phase-1 walk base
	localparam logic [31:0] STACK_TOP = 32'h7FF0_0000;   // phase-3 descent base
	localparam int N_SEQ   = 4096;
	localparam int N_SCAT  = 3072;
	localparam int N_STACK = 1536;   // pairs -> 3072 accesses (+96 scattered)

	localparam int DSIZE_B = 0;
	localparam int DSIZE_H = 1;
	localparam int DSIZE_W = 2;
	localparam int DSIZE_D = 3;

	localparam logic [1:0] MODE_XOR =
		ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e__DTR_ADDR_XOR;

	// 32-bit Galois LFSR (taps 32,22,2,1) -- the deterministic address/data
	// source. Same seed in both legs => identical access sequences.
	function automatic logic [31:0] lfsr_next(input logic [31:0] s);
		return (s >> 1) ^ (s[0] ? 32'h8020_0003 : 32'h0);
	endfunction

	logic [31:0] lfsr = 32'hACCE_5EED;
	int          n_acc = 0;

	// Pacing wrapper: count the access, throttle every 4th.
	task automatic paced_idle();
		n_acc++;
		if ((n_acc % 4) == 0) env.cpu.idle(16);
	endtask

	initial begin
		$display("[%s] %0t: waiting for reset release", PFX, $time);
		env.wait_for_reset_release();
		env.csr.clear();

		// ---- Configure: data trace only; XOR only in the USE_XOR leg ----
		if (USE_XOR) begin
			env.csr.Set_te_trTeDataControl_DataAddrCompress(MODE_XOR);
		end
		env.csr.Set_te_trTeControl_Enable          (1'b1);
		env.csr.Set_te_trTeControl_InstTracing     (1'b0);
		env.csr.Set_te_trTeDataControl_DataTracing (1'b1);
		env.csr.Set_te_trTeControl_Active          (1'b1);
		env.cpu.idle(20);
		env.cpu.set_inst_traced(1'b0);

		$display("[%s] %0t: starting workload (USE_XOR=%0d)", PFX, $time, USE_XOR);
		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(8);

		// ---- Phase 1: sequential word stores (small XOR deltas) ----
		for (int i = 0; i < N_SEQ; i++) begin
			env.cpu.store_data(.addr(BUF_SEQ + 32'(4*i)), .size(DSIZE_W),
			                   .data({32'h0, lfsr}));
			lfsr = lfsr_next(lfsr);
			paced_idle();
		end
		$display("[%s] %0t: phase 1 done (%0d accesses)", PFX, $time, n_acc);

		// ---- Phase 2: scattered loads (large deltas, mixed sizes) ----
		for (int i = 0; i < N_SCAT; i++) begin
			automatic logic [31:0] a = {1'b0, lfsr[30:0]};
			case (i % 4)
				0: env.cpu.load_data(.addr(a),                .size(DSIZE_B));
				1: env.cpu.load_data(.addr({a[31:1], 1'b0}),  .size(DSIZE_H));
				2: env.cpu.load_data(.addr({a[31:2], 2'b0}),  .size(DSIZE_W));
				3: env.cpu.load_data(.addr({a[31:3], 3'b0}),  .size(DSIZE_D));
			endcase
			lfsr = lfsr_next(lfsr);
			paced_idle();
		end
		$display("[%s] %0t: phase 2 done (%0d accesses)", PFX, $time, n_acc);

		// ---- Phase 3: stack push/pop pairs + occasional scattered store ----
		for (int i = 0; i < N_STACK; i++) begin
			automatic logic [31:0] slot = STACK_TOP - 32'(8*(i+1));
			env.cpu.store_data(.addr(slot), .size(DSIZE_D),
			                   .data({lfsr, ~lfsr}));
			paced_idle();
			env.cpu.load_data (.addr(slot), .size(DSIZE_D));
			paced_idle();
			if ((i % 16) == 15) begin
				env.cpu.store_data(.addr({1'b0, lfsr[30:2], 2'b0}), .size(DSIZE_W),
				                   .data({32'h0, ~lfsr}));
				paced_idle();
			end
			lfsr = lfsr_next(lfsr);
		end
		$display("[%s] %0t: phase 3 done (%0d accesses total)", PFX, $time, n_acc);

		env.cpu.run(8);
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
		if (n_acc < 10000) begin
			$error("[%s] workload undersized: %0d accesses (D-P3-8 needs >= 10000)", PFX, n_acc);
		end
		if (env.cpu.event_count() == 0) begin
			$error("[%s] cpu_model event log empty", PFX);
		end else begin
			$display("[%s] cpu_model logged %0d events (%0d data accesses)",
				PFX, env.cpu.event_count(), n_acc);
		end
		if (env.atb_bytes_seen == 0) begin
			$error("[%s] no ATB bytes observed", PFX);
		end else begin
			$display("[%s] observed %0d ATB transfers", PFX, env.atb_bytes_seen);
		end

		$display("[%s] PASS (sim); decode + byte accounting run from cli_dfworkload_test.sh", PFX);
		$finish;
	end

	// Hard timeout (10 336 paced accesses ~ 100 k cycles; generous margin)
	initial begin
		#40ms;
		$error("[%s] TIMEOUT - test exceeded 40 ms wall time", PFX);
		$finish;
	end

endmodule : df_workload_core

`default_nettype wire
