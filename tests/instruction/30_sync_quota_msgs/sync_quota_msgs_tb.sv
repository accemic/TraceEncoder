// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Message-quota sync (InstSyncMode=1, TRACE_MSG) under competing
 *           sync sources (P2 stage 4, plan test 30, collision design D8).
 *
 * @details
 *   InstSyncMode = ITR_SYNC_TRACE_MSG counts ON-WIRE message boundaries
 *   (EOM pulses in the egress module -- slice_fire && eom_pulse in the
 *   mseo/mdo formatter) and requests a periodic sync every 2^(Max+4)
 *   messages. This test exercises the message quota TOGETHER with the
 *   two other explicit sync sources, per design decision D8 (a
 *   "collision with periodic sync" is not constructible with the single
 *   InstSyncMode field -- the plan's original wording; documented plan
 *   deviation):
 *
 *     1. the message quota itself (mode 1, Max=0 -> every 16 messages),
 *     2. an ACT-CAP CF_SYNC command (-> composer emits SYNC=14 REQ;
 *        records SyncReqSource=1),
 *     3. an ATB sync-request pulse (env.atb_force_sync). In mode 1 the
 *        ATB request is ARCHITECTURALLY IGNORED as a trigger (arm 7 is
 *        mode-gated to InstSyncMode==7 -- the pre-P2 ungated-OR defect
 *        of TASK_STATE G6 would have fired here) and must neither sync
 *        nor disturb the quota. Its diagnostic capture is likewise
 *        mode-gated (sync_req_src_atb), so it must NOT touch
 *        SyncReqSource either.
 *
 *   Order of events: CF_SYNC fires mid-stream (SyncReqSource := 1),
 *   then the ATB pulse (no effect), then further message-quota windows
 *   elapse (SyncReqSource := 3 on each quota overflow). At test end
 *   the TB READS trTeSyncStatus.SyncReqSource via the CSR helper and
 *   $fatals unless it reads 3 (SYNC_REQ_QUOTA) -- P2.5 "SyncReqSource=3
 *   lebt", priority CSR > ATB > quota with quota LAST.
 *
 *   Workload: continuous branch-dense phases (taken/not-taken direct
 *   branches + uninferable jumps) so messages flow steadily and several
 *   16-message windows elapse before and after the CF_SYNC collision
 *   point.
 *
 *   Verification (Makefile / cli_syncquota_test.sh):
 *     scripts/decode_and_check.sh --pc --sync 4 : PC-lossless AND at
 *     least 4 synchronization messages. Derivation of N=4 (workload):
 *     the 48 JI stanzas force >= 48 IndirectBranchHist messages, so at
 *     worst-case window alignment >= 2 full 16-message windows MUST
 *     complete -> >= 2 quota syncs, plus the startup sync and the
 *     CF_SYNC REQ = 4 as the guaranteed floor. Measured 2026-08-04
 *     (first mint): 58 on-wire messages, 5 sync messages with SYNC
 *     reasons 1 (startup), 14 (CF_SYNC REQ -- E-P2-1 on the wire),
 *     and 3x 2 (PERIODIC quota). A dead message quota (pre-P2 state)
 *     gives exactly 2 (startup + CF_SYNC) and fails.
 *
 *   Deterministic. Instruction trace ON (BRANCH_HIST), data OFF.
 */

module sync_quota_msgs_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("sync_quota_msgs_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("sync_quota_msgs_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("sync_quota_msgs_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("sync_quota_msgs_tb.expected.pcs")
	) env ();

	// Message quota: window = 2^(0+4) = 16 on-wire messages.
	localparam logic [3:0] ITR_SYNC_TRACE_MSG = 4'd1;
	localparam logic [3:0] INST_SYNC_MAX      = 4'd0;

	localparam logic [1:0] SINK_NEXUS  = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
	localparam logic [5:0] CMD_CF_SYNC = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC;

	localparam logic [31:0] BASE_PC = 32'h0000_1000;
	localparam logic [31:0] JI_BASE = 32'h0008_0000;

	// One branch-dense stanza: 2 L + 1 BD (taken) + 2 L + 1 JI. Each JI
	// forces an IndirectBranchHist message out (message pressure); the BD
	// keeps HIST bits flowing. Distinct PCs per stanza via the ji index.
	task automatic stanza(input int idx);
		env.cpu.run(8);                                          // 2 L
		env.cpu.branch_taken(.target(env.cpu.cur_pc + 32'h10));  // BD
		env.cpu.run(8);                                          // 2 L
		env.cpu.uninferable_jump(.target(JI_BASE + 32'h80 * idx)); // JI
	endtask

	initial begin
		logic [31:0] sync_status;

		$display("[sync_quota_msgs_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[sync_quota_msgs_tb] %0t: reset released", $time);

		// Sync fields are write-locked while Enable=1: program before enabling.
		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_TRACE_MSG);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(BASE_PC));

		// -- part 1: >= 2 quota windows before the collision point --------
		for (int i = 0; i < 24; i++) stanza(i);

		// -- collision point (D8): CF_SYNC then ATB pulse -----------------
		// CF_SYNC (Nexus sink): composer emits an explicit-request sync
		// (SYNC=14, REQ); SyncReqSource := 1 (CSR, highest priority).
		env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC), .sink(SINK_NEXUS), .direct_data(24'h0));
		env.cpu.run(16);
		// ATB sync request while InstSyncMode==1: architecturally ignored
		// (arm 7 and the SyncReqSource=2 capture are both mode-gated).
		env.atb_force_sync = 1'b1;
		env.cpu.run(24);
		env.atb_force_sync = 1'b0;

		// -- part 2: further quota windows AFTER the collision ------------
		// (the LAST recorded source must be the quota: SyncReqSource := 3)
		for (int i = 24; i < 48; i++) stanza(i);

		// CF-quiet linear tail so trace-off lands on a non-CF instruction.
		env.cpu.run(8);
		env.cpu.exit_trace();

		// ---- Trace-off drain (flush residual ICNT/HIST, push last ATB bytes). ----
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(20000);

		// ---- SyncReqSource == 3 (SYNC_REQ_QUOTA) readback (P2.5) --------
		// The quota overflow was the LAST explicit sync source to fire
		// (CF_SYNC set 1 mid-test, the mode-gated ATB pulse set nothing,
		// part 2's quota windows set 3). Read via the wb CSR helper.
		env.csr.Read_te_trTeSyncStatus(sync_status);
		if (sync_status[2:0] !== 3'd3)
			$fatal(1, "[sync_quota_msgs_tb] SyncReqSource=%0d, expected 3 (SYNC_REQ_QUOTA)",
				sync_status[2:0]);
		else
			$display("[sync_quota_msgs_tb] SyncReqSource=3 (SYNC_REQ_QUOTA) -- PASS");

		// ---- Liveness checks (the real gate is decode_and_check.sh) ----
		if (env.cpu.event_count() == 0)
			$error("[sync_quota_msgs_tb] cpu_model event log empty");
		else
			$display("[sync_quota_msgs_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[sync_quota_msgs_tb] no ATB bytes observed");
		else
			$display("[sync_quota_msgs_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[sync_quota_msgs_tb] PASS (sim); decode verified by scripts/decode_and_check.sh");
		$display("[sync_quota_msgs_tb] ATB binary trace:");
		$system("realpath sync_quota_msgs_tb.atb.bin");
		$display("[sync_quota_msgs_tb] NexRv PCInfo:");
		$system("realpath sync_quota_msgs_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[sync_quota_msgs_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : sync_quota_msgs_tb

`default_nettype wire
