// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    ACT-CAP CF_SYNC — CSR-requested instruction synchronization.
*
* @details
*   Exercises the ACT-CAP command ACT_CAP_ST_CF_SYNC (= 12): issuing it
*   via the ACT-CAP CSR (RISC-V CSR 0x0B10) makes the encoder transmit an
*   instruction synchronization message (Nexus only) — see
*   rdl/ct_cs_cpuif.rdl `trActCapStCmd_e`. The command rides on the
*   retiring `csrw 0x0B10` (a functional NOP, itype=OTHER) and is turned
*   into a ProgTraceSync exactly like a periodic sync landing on a
*   non-control-flow instruction (sync reason NEXUS_SYNC_REQ_CSR).
*
*   How it is verified (scripts/decode_and_check_sync.sh):
*     - Instruction trace ON, periodic sync OFF, timestamps OFF, so the
*       only synchronization message that would otherwise appear is the
*       single startup ProgTraceSync (emitted when tracing is enabled).
*     - The scenario issues exactly one ACT_CAP_ST_CF_SYNC mid-stream.
*     - The trace is drained with afvalid (force_flush) ONLY — NO sync
*       request and NO atb_force_sync — so nothing else injects a sync.
*     - The offline NexRv decode counts synchronization messages and
*       requires >= 2 (startup + the one CF_SYNC produces).
*
*   History: this command was previously unimplemented and this test was
*   a known-failing xfail gate. CF_SYNC is now implemented in the RTL
*   (ct_L23_preproc_act_proc forwards it; ct_L23_preproc_composer_etip
*   turns it into a NEXUS_SYNC_REQ_CSR control-flow message and suppresses
*   the DAQ message for it), so this test passes and is part of `make sim`.
*/

module csr_sync_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (4),
		.ATB_DUMP_PATH       ("csr_sync_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("csr_sync_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("csr_sync_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("csr_sync_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC     = 32'h0000_1000;
	localparam logic [5:0]  CMD_CF_SYNC = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC;
	localparam logic [1:0]  SINK_NEXUS  = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;

	initial begin
		$display("[csr_sync_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[csr_sync_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		// Periodic sync OFF (InstSyncMode defaults to OFF after clear) and
		// timestamps OFF so the ONLY syncs are the startup one and the
		// one the CF_SYNC command produces.
		env.csr.Set_te_trTsControl_Active      (1'b0);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.wait_cycles(20);
		$display("[csr_sync_tb] %0t: starting scenario", $time);

		// ============================================================
		// Scenario: linear run, one CF_SYNC (emits an instruction sync
		// message), linear run.
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(16);                                      // 0x1000..0x100c

		env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC),
		                    .sink(SINK_NEXUS),
		                    .direct_data(24'h0));             // csrw 0xB10 @ 0x1010

		env.cpu.run(16);                                      // 0x1014..0x1020
		env.cpu.exit_trace();

		// ---- Trace-off: flush ONLY (no sync request, no force_sync), so no
		//      extra *synchronization* message is injected by the drain.
		//      Disabling instruction tracing emits a Program Trace Correlation
		//      Message (TCODE 33) — NOT a sync — so the sync count is
		//      unaffected; Enable=0 then only flushes queued trace data. A short
		//      drain first lets the trace tail propagate through the
		//      pipeline-delayed composer while tracing is still effectively on. ----
		env.wait_cycles(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.wait_cycles(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		if (env.cpu.event_count() == 0)
			$error("[csr_sync_tb] cpu_model event log empty");
		else
			$display("[csr_sync_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[csr_sync_tb] no ATB bytes observed");
		else
			$display("[csr_sync_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[csr_sync_tb] sim done; sync-count gate run from the Makefile");
		$display("[csr_sync_tb] ATB binary trace:");
		$system("realpath csr_sync_tb.atb.bin");
		$finish;
	end

	// Hard timeout
	initial begin
		#10ms;
		$error("[csr_sync_tb] TIMEOUT - test exceeded 10 ms wall time");
		$finish;
	end

endmodule : csr_sync_tb

`default_nettype wire
