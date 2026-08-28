// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Explicit sync request over the TE register (P8 / G11) --
 *           trTeControl.InstSyncReq, the TCI standard path.
 *
 * @details
 *   Writing 1 to bit 27 of trTeControl requests one instruction
 *   synchronization message. On the wire it is the explicit-request code
 *   SYNC = 14 -- the same code the ACT-CAP CF_SYNC command and the ATB
 *   sync-request input produce, because the source is irrelevant to a
 *   decoder. The source IS relevant for diagnosis and is read back from
 *   trTeSyncStatus.SyncReqSource (4 = SYNC_REQ_TE).
 *
 *   One workload, one leg per scenario. Every leg is PC-lossless against
 *   its OWN cpu_model reference -- an explicit sync adds a message, it
 *   never changes which instructions are traced:
 *
 *     off    : no request at all -- the negative leg. No SYNC = 14, and
 *              SyncReqSource must still read 0 (nothing ever requested).
 *     req    : one write mid-stream -> exactly ONE SYNC = 14, and
 *              SyncReqSource reads 4 right after it.
 *     reqnop : the ACTIVITY control for req -- the identical stimulus with
 *              the write left out. req and reqnop differ by exactly that
 *              one write, which is what makes "the feature changes the
 *              stream, and only by its anchor" a measurement instead of an
 *              assertion.
 *     req2   : TWO writes back to back (no read cycle in between, so the
 *              second lands while the first request is still outstanding).
 *              The queue is one deep, so the second is not swallowed -- it
 *              becomes its own request and gets its own message.
 *     req3   : THREE writes back to back. The third has nothing new to ask
 *              for: it collapses into the one already queued. This leg and
 *              req2 together are the measurement behind the queue-depth
 *              sentence in the register documentation (P8 audit A-1).
 *     qcoll  : one write in the MIDDLE of a running byte quota -- the two
 *              sources in the same window, neither swallowing the other.
 *     cfsync : the write immediately followed by an ACT-CAP CF_SYNC
 *              command -- a deliberate COLLISION. Expectation from the
 *              contract, fixed before the first run: the request is served
 *              on the first qualifying retire, and that retire is the
 *              csrw carrying the CF_SYNC command, so BOTH requests are
 *              satisfied by ONE message (a synchronization message is a
 *              full re-anchor). SyncReqSource then reads 1 -- the
 *              documented priority is CSR > TE > ATB > quota, and both
 *              sources are active in that cycle.
 *     quota  : the same request while the trace-BYTE quota (InstSyncMode 4,
 *              P2) is running -- the two must not interfere: the periodic
 *              quota syncs (SYNC = 2) keep coming AND the request produces
 *              its own SYNC = 14. The request is placed at the end of the
 *              traced region, so SyncReqSource reads 4 (the quota sets 3 on
 *              every window).
 *     ovf    : a request placed inside an eTIP overflow storm. The stream
 *              loses messages by construction there, so this leg does not
 *              claim losslessness -- it claims that the encoder does not
 *              wedge, that the stream still decodes and that the request is
 *              recorded (SyncReqSource = 4).
 *
 *   +TESYNC_RO switches the expectations to the COMPILED-OUT build
 *   (CT_EN_INST_SYNC_REQ = 0): the write is still accepted and still
 *   auto-clears -- the pre-P8 behaviour -- but nothing consumes it, so
 *   SyncReqSource must stay 0 and no SYNC = 14 may appear. Driven by
 *   scripts/cli_tesyncreq_test.sh ro in a switched-off worktree.
 *
 *   The CSR read-back checks are self-checking in sim ($fatal); the
 *   message accounting is done offline by scripts/cli_tesyncreq_test.sh.
 *   Timestamps OFF, drain via env.cpu.idle().
 */

module te_sync_req_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("te_sync_req_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("te_sync_req_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("te_sync_req_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("te_sync_req_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES  = 4'd2;
	localparam logic [3:0] ITR_SYNC_TRACE_BYTES = 4'd4;
	localparam logic [3:0] INST_SYNC_MAX_SPARSE = 4'd6; // 2^10 cycles
	localparam logic [3:0] INST_SYNC_MAX_QUOTA  = 4'd2; // 2^6 = 64 ATB bytes

	localparam logic [31:0] MAIN_PC = 32'h0000_6000;
	localparam logic [31:0] JI_BASE = 32'h0009_0000;

	localparam logic [1:0] SINK_NEXUS  = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
	localparam logic [5:0] CMD_CF_SYNC = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC;

	// SyncReqSource encoding (RDL trTeSyncReqSource_e).
	localparam logic [2:0] SRC_NONE = 3'd0;
	localparam logic [2:0] SRC_CSR  = 3'd1;
	localparam logic [2:0] SRC_TE   = 3'd4;

	// The qcoll tail must outlast the quota FEEDBACK LOOP, and that loop is
	// one alignment-pipe deeper than the retires that fill it: the byte
	// counter sits at the L2 egress, BEHIND the SyncReasonPipe, so a quota
	// window closes -- and the next SYNC = 2 finds its carrier retire --
	// a full pipe depth after the messages that filled it were retired.
	// Four stanzas were the historical tail, calibrated on the 20-stage
	// pipe; the depth is a build parameter (ct_pkg::PREPROC_DELAY_MAX, 44
	// with CT_EN_ACT), so the tail scales with it instead of pinning that
	// literal: one 18-retire stanza per started 18 stages, plus one stanza
	// of margin. Displacement is all this covers -- a sync the scheduler
	// LOSES stays red no matter how long the tail runs (the SyncCntClr
	// wedge mutation is the measured counter-proof).
	localparam int QCOLL_TAIL_STANZAS = 4 + (ct_pkg::PREPROC_DELAY_MAX + 17) / 18 + 1;

	logic [31:0] rd;
	bit          ro;   // +TESYNC_RO: the compiled-out build

	// ------------------------------------------------------------------
	// One "write 1 to trTeControl.InstSyncReq". The field is
	// `sw = w; singlepulse;` and clears itself, so it must always read back
	// 0 -- in EVERY build, with the feature compiled in or out. That
	// read-back is itself a negative check: a field that latched the write
	// would be a different (and wrong) register contract.
	// ------------------------------------------------------------------
	task automatic te_sync_request();
		env.csr.Set_te_trTeControl_InstSyncReq(1'b1);
		env.csr.Read_te_trTeControl(rd);
		if (rd[27] !== 1'b0)
			$fatal(1, "[te_sync_req_tb] InstSyncReq read back as %0b, expected 0 (write-1, self-clearing)", rd[27]);
	endtask

	// ------------------------------------------------------------------
	// N writes as close together as the bus allows -- the QUEUE DEPTH
	// measurement (P8 audit A-1). The field helper above does a
	// read-modify-write and would put a read cycle between two writes; here
	// the register word is fetched ONCE and then written back n times with
	// bit 27 set, so the later writes really do land while the first request
	// is still outstanding. Every other field keeps the value it just read,
	// so the burst changes nothing but the request bit.
	// ------------------------------------------------------------------
	task automatic te_sync_request_burst(input int n);
		logic [31:0] word;
		env.csr.Read_te_trTeControl(word);
		word[27] = 1'b1;
		for (int i = 0; i < n; i++) env.csr.Write_te_trTeControl(word);
		env.csr.Read_te_trTeControl(rd);
		if (rd[27] !== 1'b0)
			$fatal(1, "[te_sync_req_tb] InstSyncReq read back as %0b after a burst of %0d, expected 0", rd[27], n);
	endtask

	// Read the diagnosis register and compare. `want` is the expectation
	// for the build under test; the compiled-out build always expects 0.
	task automatic check_sync_source(input logic [2:0] want, input string where);
		logic [2:0] expect_now;
		expect_now = ro ? SRC_NONE : want;
		env.csr.Read_te_trTeSyncStatus(rd);
		if (rd[2:0] !== expect_now)
			$fatal(1, "[te_sync_req_tb] %s: SyncReqSource=%0d, expected %0d", where, rd[2:0], expect_now);
		$display("[te_sync_req_tb] %0t: %s: SyncReqSource=%0d (as expected)", $time, where, rd[2:0]);
	endtask

	// Branch-dense stanza: keeps messages flowing so the byte quota of the
	// quota leg actually completes windows.
	task automatic stanza(input int idx);
		env.cpu.run(8);
		env.cpu.branch_taken(.target(env.cpu.cur_pc + 32'h10));
		env.cpu.run(8);
		env.cpu.uninferable_jump(.target(JI_BASE + 32'h80 * idx));
	endtask

	initial begin
		bit leg_req, leg_cfsync, leg_quota, leg_ovf, leg_cfonly;
		bit leg_req2, leg_req3, leg_qcoll, leg_reqnop;

		$display("[te_sync_req_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[te_sync_req_tb] %0t: reset released", $time);

		ro         = $test$plusargs("TESYNC_RO");
		leg_req    = $test$plusargs("REQLEG");
		leg_cfsync = $test$plusargs("CFSYNCLEG");
		leg_quota  = $test$plusargs("QUOTALEG");
		leg_ovf    = $test$plusargs("OVFLEG");
		leg_cfonly = $test$plusargs("CFONLYLEG");
		leg_req2   = $test$plusargs("REQ2LEG");
		leg_req3   = $test$plusargs("REQ3LEG");
		leg_qcoll  = $test$plusargs("QCOLLLEG");
		leg_reqnop = $test$plusargs("REQNOPLEG");

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		if (leg_quota || leg_qcoll) begin
			env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_TRACE_BYTES);
			env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX_QUOTA);
		end
		else begin
			env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
			env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX_SPARSE);
		end

		// Nothing has requested anything yet -- in every leg and in every
		// build. This is the reset expectation of the diagnosis register.
		check_sync_source(SRC_NONE, "after reset");

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[te_sync_req_tb] %0t: scenario start", $time);

		env.cpu.enter(.start_pc(MAIN_PC));
		for (int i = 0; i < 8; i++) stanza(i);

		// ---- the request: the single event the legs differ in ----------
		// reqnop is the ACTIVITY control: byte-for-byte the same stimulus as
		// req, only without the write. The pair is what shows that the
		// feature, switched on AND asked, changes the stream in exactly the
		// documented way -- the byte-neutrality gate can only show that it
		// stays quiet when nobody asks (P8 audit B-7).
		if (leg_req || leg_reqnop) begin
			if (leg_req) te_sync_request();
			env.cpu.run(16);              // the serving retire is in here
			check_sync_source(leg_req ? SRC_TE : SRC_NONE, "after the TE request");
		end

		// ---- queue depth: two and three writes back to back -------------
		// The contract measured here is what the register documentation
		// states (P8 audit A-1): a write landing while a request is still
		// outstanding is NOT swallowed, it becomes its own request. One
		// queue slot means the THIRD write of a burst has nothing new to
		// ask for and collapses into the queued one.
		if (leg_req2 || leg_req3) begin
			te_sync_request_burst(leg_req3 ? 3 : 2);
			env.cpu.run(64);              // room for BOTH serving retires
			check_sync_source(SRC_TE, "after the request burst");
		end

		if (leg_cfonly) begin
			// CONTROL leg for cfsync: the ACT-CAP CF_SYNC command ALONE.
			// Without it, "the collision produced one message" would also be
			// true if the CF_SYNC path did nothing at all. Its expectation is
			// therefore the OPPOSITE of the collision leg's: one SYNC = 14
			// and SyncReqSource = 1, with no TE request in sight.
			// The idle(200) before the read is settling margin for the
			// tip -> wb diagnosis crossing, deliberately generous. An earlier
			// version of this comment claimed a shorter idle had been
			// measured to still read 0; no such leg exists, so the claim is
			// withdrawn (P8 audit C-7) rather than dressed up.
			env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC), .sink(SINK_NEXUS), .direct_data(24'h0));
			env.cpu.run(16);
			env.cpu.idle(200);
			check_sync_source(SRC_CSR, "after the CF_SYNC control command");
		end

		if (leg_cfsync) begin
			// COLLISION: the request is raised, and the very next retire is
			// the csrw that carries the ACT-CAP CF_SYNC command. Both
			// requests are then satisfied by ONE synchronization message.
			//
			// SyncReqSource ends at 1: both terms are one-cycle events (the
			// paced request strobe and the retiring csrw), and the csrw is
			// the later of the two, so the CSR source is the most recent
			// request. See the source-capture comment in ct_L23_preproc.sv.
			te_sync_request();
			env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC), .sink(SINK_NEXUS), .direct_data(24'h0));
			env.cpu.run(16);
			env.cpu.idle(200);   // diagnosis snapshot settling (see cfonly)
			check_sync_source(SRC_CSR, "after the TE x CF_SYNC collision");
		end

		if (leg_ovf) begin
			// eTIP overflow with the request placed INSIDE the storm.
			// Recipe from tests/overflow/01_overrun_recovery: ATB
			// backpressure plus a storm of INDIRECT jumps (each raises a CF
			// slot AND a next_iaddr sideband entry, so the sideband FIFO
			// saturates -- direct branches compact away in HIST and never
			// get there). The storm ping-pongs on a dedicated pad so it
			// cannot create pcinfo conflicts with the shared workload.
			env.cpu.uninferable_jump(.target(JI_BASE + 32'h4000));
			env.atb_force_stall = 1'b1;
			repeat (150) begin
				env.cpu.uninferable_jump(.target(JI_BASE + 32'h4400));
				env.cpu.uninferable_jump(.target(JI_BASE + 32'h4000));
			end
			te_sync_request();
			repeat (150) begin
				env.cpu.uninferable_jump(.target(JI_BASE + 32'h4400));
				env.cpu.uninferable_jump(.target(JI_BASE + 32'h4000));
			end
			env.atb_force_stall = 1'b0;
			env.cpu.uninferable_jump(.target(JI_BASE + 32'h4800)); // leave pad
			env.cpu.run(600);             // calm: the encoder must recover
			check_sync_source(SRC_TE, "after the request during overflow");
		end

		// ---- the request INSIDE a running byte quota (collision) --------
		// The quota leg below places the request at the very end, where the
		// two merely coexist. Here it goes into the middle of the dense
		// stanza stream, with the 64-byte quota firing continuously, so the
		// request is raised while a quota window is in flight. What the
		// simulation can show is that neither swallows the other: the
		// request gets its one SYNC = 14 and the periodic cadence keeps
		// running. That the two land on the SAME retire -- and that the
		// request wins that beat -- is not something a testbench can
		// schedule; it is proven in formal/preproc_sync (P-SYNC-11,
		// task reqcoll, cover C_coll_on_one_beat).
		if (leg_qcoll) begin
			for (int i = 8; i < 12; i++) stanza(i);
			te_sync_request();
			for (int i = 12; i < 12 + QCOLL_TAIL_STANZAS; i++) stanza(i);
		end
		else begin
			for (int i = 8; i < 16; i++) stanza(i);
		end

		if (leg_quota) begin
			// The quota keeps running through the whole leg; the request
			// goes LAST so the diagnosis register ends on the TE source.
			te_sync_request();
			env.cpu.run(16);
			check_sync_source(SRC_TE, "after the TE request under quota");
		end

		// CF-quiet tail so trace-off lands on a non-CF instruction.
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

		// The negative leg states it once more at the end: no request was
		// ever made, so the diagnosis register never moved.
		if (!(leg_req || leg_cfsync || leg_quota || leg_ovf || leg_cfonly
		      || leg_req2 || leg_req3 || leg_qcoll || leg_reqnop))
			check_sync_source(SRC_NONE, "end of the negative leg");

		if (env.cpu.event_count() == 0)
			$error("[te_sync_req_tb] cpu_model event log empty");
		else
			$display("[te_sync_req_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[te_sync_req_tb] no ATB bytes observed");
		else
			$display("[te_sync_req_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[te_sync_req_tb] PASS (sim); decode verified by scripts/cli_tesyncreq_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[te_sync_req_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : te_sync_req_tb

`default_nettype wire
