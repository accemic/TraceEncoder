// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Trigger-Sync (SYNC=6) + Seq-Sync (SYNC=4) + Ownership (TCODE 2) -- B4/B5/B6.
 *
 * @details
 *   One workload, four CSR legs (identical cpu_model stimulus -> identical
 *   expected-PC reference; unused event inputs are simply inert):
 *
 *     off : reset defaults -- no SYNC 4/6, no TCODE 2; the long linear run
 *           drains via ResourceFull(RCODE=0).
 *     trig: +InstTrigEnable -- the tip.trigger pulse upgrades the next
 *           retire to a SYNC=6 marker (Trace Event, B4).
 *     seq : +InstSeqSyncEnable -- the ICNT-cap pre-drain becomes a full
 *           re-anchor with SYNC=4 instead of RCODE=0 (B5; documented
 *           Accemic extension, N-Trace binds SYNC=4 to BTM).
 *     own : +Context -- Ownership messages after every synchronizing
 *           message (FORMAT=0) and for the context-report retire
 *           (ctype=2 -> FORMAT=2 with the scontext value) (B6, N-Trace 7.1).
 *           NOTE: the on-wire CONTEXT width equals TIP_CONTEXT_WIDTH (2 in
 *           the vendored TIP profile) -- an integration parameter of the
 *           core; the encoder path itself carries up to 44 bits
 *           (nexus_process_t). This TB drives all-ones so the expected
 *           PROCESS values stay width-honest: FORMAT=0 -> 0xC, FORMAT=2
 *           with ctx='1 -> 0x6E at width 2.
 *
 *   All legs must decode PC-lossless against the same reference
 *   (scripts/cli_tso_test.sh). Timestamps OFF, drain via env.cpu.idle().
 */

module trig_seq_own_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("trig_seq_own_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("trig_seq_own_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("trig_seq_own_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("trig_seq_own_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd6; // 2^10 = 1024-cycle window (sparse periodic syncs)

	localparam logic [31:0] MAIN_PC = 32'h0000_5000;

	initial begin
		$display("[trig_seq_own_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[trig_seq_own_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		if ($test$plusargs("TRIGLEG")) begin
			env.csr.Set_te_trTeControl_InstTrigEnable(1'b1);
			$display("[trig_seq_own_tb] %0t: InstTrigEnable=1", $time);
		end
		if ($test$plusargs("SEQLEG")) begin
			env.csr.Set_te_trTeControl_InstSeqSyncEnable(1'b1);
			$display("[trig_seq_own_tb] %0t: InstSeqSyncEnable=1", $time);
		end
		if ($test$plusargs("OWNLEG")) begin
			env.csr.Set_te_trTeControl_Context(1'b1);
			$display("[trig_seq_own_tb] %0t: Context=1", $time);
		end
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[trig_seq_own_tb] %0t: scenario start", $time);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(16);
		env.cpu.branch_taken(.target(MAIN_PC + 32'h100));

		// Long linear run: 140 instructions = 280 halfwords > the 255
		// narrow-ICNT cap -> at least one pre-drain (RCODE=0 or SYNC=4).
		env.cpu.run(560);

		// Watchpoint/trigger pulse -> SYNC=6 on the next retire (trig leg).
		env.cpu.trigger_pulse();
		env.cpu.run(8);

		// Context report -> Ownership FORMAT=2 (own leg). All-ones fills
		// whatever TIP_CONTEXT_WIDTH the profile provides (2 -> ctx=3).
		env.cpu.context_report('1);
		env.cpu.run(8);

		env.cpu.branch_not_taken();
		env.cpu.run(8);
		env.cpu.exit_trace();

		// ---- Trace-off drain (cpu.idle -- wait_cycles XSIM anomaly) ----
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(2000);

		if (env.cpu.event_count() == 0)
			$error("[trig_seq_own_tb] cpu_model event log empty");
		else
			$display("[trig_seq_own_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[trig_seq_own_tb] no ATB bytes observed");
		else
			$display("[trig_seq_own_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[trig_seq_own_tb] PASS (sim); decode verified by scripts/cli_tso_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[trig_seq_own_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : trig_seq_own_tb

`default_nettype wire
