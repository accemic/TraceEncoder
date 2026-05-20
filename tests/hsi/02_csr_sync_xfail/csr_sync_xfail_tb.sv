// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    ACT-CAP CF_SYNC (instruction-sync command) — KNOWN-FAILING.
*
* @details
*   Regression gate for the currently UNIMPLEMENTED ACT-CAP command
*   ACT_CAP_ST_CF_SYNC (= 12). Per its register description it should
*   "Transmit instruction synchronization message (Nexus message only)"
*   — i.e. issuing it via the ACT-CAP CSR (RISC-V CSR 0x0B10) should make
*   the encoder emit an extra instruction-synchronization message into
*   the Nexus trace. The RTL has no case arm for it (see
*   rdl/ct_cs_cpuif.rdl: ACT_CAP_ST_CF_SYNC ... [NOT IMPLEMENTED]); it
*   falls through and emits a bogus empty DAQ message instead, so no
*   additional sync is produced.
*
*   This test is therefore EXPECTED TO FAIL today. It is wired into the
*   Makefile as a separate, NON-GATING target (`make sim-hsi-csr-sync`)
*   and is NOT part of `make sim`. When CF_SYNC is implemented it flips
*   to PASS — that is its purpose as a pending-feature gate.
*
*   How the gate works (scripts/decode_and_check_sync.sh):
*     - Instruction trace ON, periodic sync OFF, timestamps OFF, so the
*       only synchronization message in the trace is the single startup
*       ProgTraceSync (emitted when tracing is enabled).
*     - The scenario issues exactly one ACT_CAP_ST_CF_SYNC mid-stream.
*     - The trace is drained with afvalid (force_flush) ONLY — NO sync
*       request and NO atb_force_sync — so nothing else injects a sync.
*     - The offline NexRv decode counts synchronization messages and
*       requires >= 2 (startup + the one CF_SYNC should produce). Today
*       there is exactly 1, so the check fails (XFAIL).
*
*   The startup ProgTraceSync is emitted before the CF_SYNC point, so the
*   count is robust even if NexRv stumbles on the bogus vendor DAQ
*   message that the unimplemented command currently emits.
*/

module csr_sync_xfail_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (4),
		.ATB_DUMP_PATH       ("csr_sync_xfail_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("csr_sync_xfail_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("csr_sync_xfail_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("csr_sync_xfail_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC    = 32'h0000_1000;
	localparam logic [5:0]  CMD_CF_SYNC = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC;
	localparam logic [1:0]  SINK_NEXUS  = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;

	initial begin
		$display("[csr_sync_xfail_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[csr_sync_xfail_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		// Periodic sync OFF (InstSyncMode defaults to OFF after clear) and
		// timestamps OFF so the ONLY sync message is the startup one.
		env.csr.Set_te_trTsControl_Active      (1'b0);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.wait_cycles(20);
		$display("[csr_sync_xfail_tb] %0t: starting scenario", $time);

		// ============================================================
		// Scenario: linear run, one CF_SYNC (should emit an instruction
		// sync message — currently does not), linear run.
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(16);                                      // 0x1000..0x100c

		env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC),
		                    .sink(SINK_NEXUS),
		                    .direct_data(24'h0));             // csrw 0xB10 @ 0x1010

		env.cpu.run(16);                                      // 0x1014..0x1020
		env.cpu.exit_trace();

		// ---- Drain: flush ONLY (no sync request, no force_sync), so no
		//      extra synchronization message is injected by the drain. ----
		env.wait_cycles(200);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		if (env.cpu.event_count() == 0)
			$error("[csr_sync_xfail_tb] cpu_model event log empty");
		else
			$display("[csr_sync_xfail_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[csr_sync_xfail_tb] no ATB bytes observed");
		else
			$display("[csr_sync_xfail_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[csr_sync_xfail_tb] sim done; sync-count gate run from the Makefile");
		$display("[csr_sync_xfail_tb] ATB binary trace:");
		$system("realpath csr_sync_xfail_tb.atb.bin");
		$finish;
	end

	// Hard timeout
	initial begin
		#10ms;
		$error("[csr_sync_xfail_tb] TIMEOUT - test exceeded 10 ms wall time");
		$finish;
	end

endmodule : csr_sync_xfail_tb

`default_nettype wire
