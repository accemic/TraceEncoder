// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_L23_preproc_sync_tb.sv
 * @brief   Directed sync-generation testbench for ct_L23_preproc_sync.
 * @details Checks reset-exit sync generation, periodic syncs driven by
 *   tip and wall clocks, and both explicitly requested syncs (ATB input and
 *   the TE register field trTeControl.InstSyncReq, P8) including their
 *   collision, their negative case and the pause behaviour.
 * @environment Runs the DUT with independent tip and wall clocks and measures
 *   sync spacing with a simple stopwatch.
 * @stimulus Reconfigures the sync mode between reset-exit, tip-clock
 *   periodic, wall-clock periodic, and trace-byte-triggered cases.
 * @checking Asserts sync.reason values and wall-clock timing windows for the
 *   generated periodic sync events.
 *
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Copyright (C) 2026 Accemic Technologies GmbH
 */

module ct_L23_preproc_sync_tb;

	import tt::*;
	import tip_pkg::*;
	import tip_utils_pkg::*;
	import nexus::*;
	import ct_cs_cpuif_pkg::*;

	localparam int DELAY_CYCLES = 2;
	localparam TIP_CLK_PERIOD       =  1.0;
	localparam DO_SYNC_CLK_PERIOD   =  5.0;
	localparam WALL_CLK_PERIOD      = 12.0;

	logic tip_rst;
	tip_t tipt;
	logic wall_clk_rst;
	int   StopwatchStart;
	int   StopwatchDiff;
	logic sync_req_atb_synq;
	logic synq_req_trace_byte_count;
	logic synq_req_trace_msg_count;
	logic [7:0] idelay_sync;
	logic [7:0] extra_delay_sync;

	logic tip_clk     = 0; always #(TIP_CLK_PERIOD    /2.0)  tip_clk       = ~tip_clk;
	logic wall_clk    = 0; always #(WALL_CLK_PERIOD/2.0)     wall_clk      = ~wall_clk;
	// P2: independent egress-quota clock domain (exercises the two
	// vector_cdc2 pairs at a non-integer ratio to tip_clk).
	logic proc_clk    = 0; always #(DO_SYNC_CLK_PERIOD/2.0)  proc_clk      = ~proc_clk;
	uwire logic proc_rst = tip_rst;

	uwire logic quota_cnt_clr;

	// Instantiate interfaces
	tip_if          tip   ();
	ct_cs_tipclk_if cs_tip();
	ct_sync_if      sync();

	// Instantiate DUT
	ct_L23_preproc_sync sync_inst (
		.clk (tip_clk),
		.rst (tip_rst),
		.tip,
		.wall_clk_rst,
		.wall_clk,
		.proc_clk,
		.proc_rst,
		.sync_req_atb_synq,
		.synq_req_trace_byte_count,
		.synq_req_trace_msg_count,
		.quota_cnt_clr,
		.quota_byte_ovf_tip (),
		.quota_msg_ovf_tip  (),
		.sync,
		.cs_tip,
		.internal_delay (idelay_sync),
		.extra_delay (extra_delay_sync)
	);

	// ----------------------------------------------------------------
	// Egress-quota counter model (P2): the stimulus arms a level; it
	// HOLDS until the crossed SyncCntClr (quota_cnt_clr) clears it --
	// exactly the real egress counter's held-level/rearm contract.
	// ----------------------------------------------------------------
	logic quota_byte_arm = 0;
	logic quota_msg_arm  = 0;
	always_ff @(posedge proc_clk) begin
		if (proc_rst || quota_cnt_clr) begin
			synq_req_trace_byte_count <= 1'b0;
			synq_req_trace_msg_count  <= 1'b0;
		end
		else begin
			if (quota_byte_arm) synq_req_trace_byte_count <= 1'b1;
			if (quota_msg_arm)  synq_req_trace_msg_count  <= 1'b1;
		end
	end

	// ----------------------------------------------------------------
	// CSR-shim pacing (P8): what reaches the DUT is not the CSR write but
	// the paced REQUEST LEVEL -- ct_cs_cpuif_wb.sv keeps one request up at
	// a time and withdraws it only after the DUT's acknowledgement, holding
	// the next one back until the handshake has closed. Driving the port
	// through the pacer (rather than poking it directly) is what makes the
	// acknowledgement path part of the test: a DUT that never acknowledged
	// would starve after the first request.
	//
	// The REAL module, not a model of it (P8 audit B-2, P8 closing audit
	// B-N1): this testbench used to carry a hand-copied mirror of the pacing
	// equations, which is a second truth that drifts -- and it would have
	// drifted right here, when the handshake changed from paced strobes to
	// four-phase levels. Single clock in this environment, so the two
	// crossings the shim wires around it are plain wires.
	// ----------------------------------------------------------------
	logic te_req_write = 0; // "software writes 1 to bit 27"
	uwire logic te_req_lvl;
	ct_sync_req_pacer te_pacer (
		.clk   (tip_clk),
		.rst   (tip_rst),
		.write (te_req_write),
		.ack   (cs_tip.trTeInstSyncReqAck),
		.req   (te_req_lvl)
	);
	assign cs_tip.trTeInstSyncReq = te_req_lvl;
	// "The CSR side is still waiting": the handshake has not closed, i.e. the
	// request is still up or its acknowledgement has not been withdrawn yet.
	uwire logic te_req_busy = te_req_lvl || cs_tip.trTeInstSyncReqAck;

	// One "CSR write of 1 to bit 27".
	task automatic te_sync_write();
		te_req_write = 1;
		@(posedge tip_clk);
		te_req_write = 0;
	endtask

	// Windowed sync counters for the negative/rearm legs. Plain `always`
	// (not always_ff): the stimulus process also resets the counters.
	logic sync_count_en = 0;
	int   NPeriodic     = 0;
	int   NAnySync      = 0;
	int   NReq          = 0;

	// D1 (B-R13-1): direct readout of the half-word cadence counter. The
	// counter value never reaches the wire -- its only sink is the saturation
	// overflow flag that arms the periodic sync -- so the only way to state
	// what it COUNTS is to read it.
	int   HwBase        = 0;
	int   HwDelta       = 0;
	int   D1CadRvc      = 0;
	int   D1Cad32       = 0;
	always @(posedge tip_clk) begin
		if (sync_count_en) begin
			if (sync.reason == NEXUS_SYNC_PERIODIC) NPeriodic <= NPeriodic + 1;
			if (sync.reason == NEXUS_SYNC_REQ)      NReq      <= NReq      + 1;
			if (sync.reason != NEXUS_SYNC_NONE)     NAnySync  <= NAnySync  + 1;
		end
	end

	always_ff @(posedge tip_clk) begin
		if (tip_rst) begin
			StopwatchStart <= $realtime;
		end
		else begin
			if (sync.reason == NEXUS_SYNC_PERIODIC) begin
				StopwatchDiff  <= $realtime - StopwatchStart;
				StopwatchStart <= $realtime;
			end
		end
	end

	// Gentle watchdog: aborts the run if the DUT never produces the expected
	// sync events (e.g. after a control-signal rename/addition on the
	// ct_cs_tipclk_if). Keep the timeout comfortably above the longest
	// legitimate wait in the tests (Test 3 waits multiple wall-clock-based
	// periodic syncs; WALL_CLK_PERIOD * 2**(trTeInstSyncMax+4) ~= 192 ns, so
	// 50 us gives ~2 orders of magnitude of headroom).
	localparam realtime WATCHDOG_TIMEOUT_NS = 50_000.0;
	initial begin
		#(WATCHDOG_TIMEOUT_NS);
		$fatal(1, "%0.2f: ct_L23_preproc_sync_tb watchdog timeout after %0.0f ns -- DUT did not produce the expected sync events",
			$realtime, WATCHDOG_TIMEOUT_NS);
	end

	// D1 (B-R13-1) cadence helper: drive `n` retirements of one instruction
	// size in the HALF-WORD cadence mode with a REACHABLE threshold
	// (InstSyncMax = 0 -> 2**4 = 16 half-words) and report how many periodic
	// syncs came out. Each leg starts from a reset so the counter, the
	// SyncCntClr rearm and the reset one-shot are in a known state.
	task automatic d1_periodic_over (input tip_ilastsize_t ils,
	                                 input int             n,
	                                 output int            n_periodic);
		cs_tip.trTeEnable       = 1;
		cs_tip.trTeInstTracing  = 1;
		cs_tip.trTeInstSyncMax  = 0;
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_HALFWORDS;
		tip_rst = 1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		TipSendMsg (tip, tip_clk, tipt, 3);   // consumes EXIT_FROM_SYS_RST
		// Warm-up and drain WITHOUT retirements: the clear/overflow state
		// machine runs every cycle (so SyncCntClr falls), but nothing is
		// counted and nothing can be emitted -- a sync is retire-qualified.
		// That keeps the leg's half-word budget exactly `n * 2**ils`.
		tipt.iretire = '0;
		repeat (10) TipSendMsg (tip, tip_clk, tipt, 0);
		tipt.ilastsize = ils;
		tipt.iretire   = '1;
		NPeriodic = 0; NAnySync = 0; sync_count_en = 1;
		repeat (n) TipSendMsg (tip, tip_clk, tipt, 0);
		tipt.iretire = '0;
		repeat (10) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en  = 0;
		n_periodic     = NPeriodic;
		tipt.iretire   = '1;
		tipt.ilastsize = tip_ilastsize_t'(TIP_DEFAULT_ILASTSIZE);
	endtask

	// Test stimulus
	initial begin
		wall_clk_rst = 1;
		sync_req_atb_synq = 0;
		quota_byte_arm = 0;
		quota_msg_arm  = 0;
		extra_delay_sync = 2;
		// The DUT requires both the master enable and the instruction-tracing
		// flag to produce any sync message; leaving trTeEnable at its default
		// makes every `while (sync.reason != ...)` loop hang forever.
		cs_tip.trTeEnable       = 1;
		cs_tip.trTeInstTracing  = 1;
		cs_tip.trTeInstSyncMax  = 0; // sync after 2**4 tip.clk cycles
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_CLK_CYCLES;

		tip_rst = 1;
		TipTSetDefault(tipt);
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		@(posedge tip_clk);
		wall_clk_rst = 0;

		// ------------------------------------------------------------
		// Test 1: Check for NEXUS_SYNC_EXIT_FROM_SYS_RST
		// ------------------------------------------------------------
		tipt.iretire = '1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		void'(tt_assert((sync.reason == NEXUS_SYNC_EXIT_FROM_SYS_RST), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_EXIT_FROM_SYS_RST expected", $realtime, `__LINE__)));

		// ------------------------------------------------------------
		// Test 2: Check for NEXUS_SYNC_PERIODIC (count tip.clk)
		// ------------------------------------------------------------
		cs_tip.trTeInstSyncMax  = 0; // sync after 2**4 tip.clk cycles
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_CLK_CYCLES;
		tip_rst = 1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_PERIODIC), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (tip.clk) expected", $realtime, `__LINE__)));
		// ------------------------------------------------------------
		// Test 3: Check for NEXUS_SYNC_PERIODIC (count wall_clk)
		// ------------------------------------------------------------
		wall_clk_rst = 1;
		cs_tip.trTeInstSyncMax  = 0; // sync after 2**4 tip.clk cycles
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_WALL_CLK;
		tip_rst = 1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		@(posedge tip_clk);
		wall_clk_rst = 0;
		TipSendMsg (tip, tip_clk, tipt, 3);
		void'(tt_assert((sync.reason == NEXUS_SYNC_EXIT_FROM_SYS_RST), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_EXIT_FROM_SYS_RST expected", $realtime, `__LINE__)));
		// measure time between this synq and periodic wallclock sync
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		TipSendMsg (tip, tip_clk, tipt, 0);
		void'(tt_assert( (StopwatchDiff > 250) && (StopwatchDiff < 450), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (wall_clk) expected, StopwatchDiff: %0d", $realtime, `__LINE__, StopwatchDiff)));
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		TipSendMsg (tip, tip_clk, tipt, 0);
		void'(tt_assert( (StopwatchDiff > 250) && (StopwatchDiff < 450), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (wall_clk) expected, StopwatchDiff: %0d", $realtime, `__LINE__, StopwatchDiff)));

		// ------------------------------------------------------------
		// Test 4: trace-output quota (P2) + ATB request (E-P2-1)
		// ------------------------------------------------------------
		// Test 4a: byte quota (mode 4) -- a held egress overflow level
		// produces a PERIODIC sync (SYNC=2, D4) through the CDC pair.
		wall_clk_rst = 1;
		cs_tip.trTeInstSyncMax  = 0; // sync after 2**4 tip.clk cycles
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES;
		tip_rst = 1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		TipSendMsg (tip, tip_clk, tipt, 3);
		void'(tt_assert((sync.reason == NEXUS_SYNC_EXIT_FROM_SYS_RST), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_EXIT_FROM_SYS_RST expected", $realtime, `__LINE__)));
		repeat (20) TipSendMsg (tip, tip_clk, tipt, 0);
		quota_byte_arm = 1;
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_PERIODIC), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (trace bytes) expected", $realtime, `__LINE__)));

		// Test 4c: rearm -- drop the arm so the crossed SyncCntClr clears
		// the level (egress-counter model above); after the level fell
		// there must be NO second PERIODIC (no double sync).
		quota_byte_arm = 0;
		// Let the clr round-trip settle (2x vector_cdc2 handshake).
		repeat (100) TipSendMsg (tip, tip_clk, tipt, 0);
		void'(tt_assert(!synq_req_trace_byte_count, $sformatf("%0.2f: Line %0d: Test failed: quota level did not fall via SyncCntClr rearm", $realtime, `__LINE__)));
		NPeriodic = 0; NAnySync = 0; sync_count_en = 1;
		repeat (200) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en = 0;
		void'(tt_assert((NPeriodic == 0), $sformatf("%0.2f: Line %0d: Test failed: %0d PERIODIC after rearm (double sync)", $realtime, `__LINE__, NPeriodic)));

		// Test 4b: message quota (mode 1) -- same path, TRACE_MSG level.
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_MSG;
		repeat (20) TipSendMsg (tip, tip_clk, tipt, 0);
		quota_msg_arm = 1;
		while (sync.reason != NEXUS_SYNC_PERIODIC) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_PERIODIC), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_PERIODIC (trace msgs) expected", $realtime, `__LINE__)));
		quota_msg_arm = 0;
		repeat (100) TipSendMsg (tip, tip_clk, tipt, 0);
		void'(tt_assert(!synq_req_trace_msg_count, $sformatf("%0.2f: Line %0d: Test failed: msg quota level did not fall via SyncCntClr rearm", $realtime, `__LINE__)));

		// Test 4n1 (NEGATIVE): InstSyncMode=OFF -- held quota levels must
		// produce NO sync at all (mode gate in is_overflow).
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_OFF;
		quota_byte_arm = 1;
		quota_msg_arm  = 1;
		repeat (30) TipSendMsg (tip, tip_clk, tipt, 0); // levels rise + cross
		NPeriodic = 0; NAnySync = 0; sync_count_en = 1;
		repeat (200) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en = 0;
		void'(tt_assert((NAnySync == 0), $sformatf("%0.2f: Line %0d: Test failed: %0d syncs with InstSyncMode=OFF (quota leak)", $realtime, `__LINE__, NAnySync)));

		// Test 4n2 (NEGATIVE): InstSyncMode=INSTRUCTIONS, Max=15 (2^19
		// instructions -- unreachable here): the held quota levels must not
		// leak into the periodic arm of a NON-quota mode.
		cs_tip.trTeInstSyncMax  = 15;
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_INSTRUCTIONS;
		repeat (30) TipSendMsg (tip, tip_clk, tipt, 0);
		NPeriodic = 0; NAnySync = 0; sync_count_en = 1;
		repeat (200) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en = 0;
		void'(tt_assert((NPeriodic == 0), $sformatf("%0.2f: Line %0d: Test failed: %0d PERIODIC in INSTRUCTIONS mode from quota level (leak)", $realtime, `__LINE__, NPeriodic)));
		quota_byte_arm = 0;
		quota_msg_arm  = 0;

		// Test 4d (E-P2-1, 2026-08-03): the ATB sync request (mode 7)
		// emits the explicit-request code SYNC=14 (NEXUS_SYNC_REQ), NOT
		// PERIODIC -- wait for the first non-NONE reason and check it.
		cs_tip.trTeInstSyncMax  = 0;
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_ATB;
		repeat (100) TipSendMsg (tip, tip_clk, tipt, 0); // drain stale clr/levels
		NPeriodic = 0; NAnySync = 0; NReq = 0; sync_count_en = 1;
		sync_req_atb_synq = 1;
		while (sync.reason == NEXUS_SYNC_NONE) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_REQ), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_REQ (14) expected for the ATB request, got %0d", $realtime, `__LINE__, sync.reason)));
		// Test 4e (P8 regression guard, found while wiring the second
		// request source): ONE held ATB request must produce exactly ONE
		// SYNC=14. The arm is only left when the handshake FSM drops its
		// output, and that takes one cycle after the acknowledgement --
		// without the in-flight-ack guard in the arm the very next
		// qualifying retire emits a SECOND explicit sync for the same
		// request. Red before the guard (measured: 2).
		repeat (30) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en = 0;
		void'(tt_assert((NReq == 1), $sformatf("%0.2f: Line %0d: Test failed: %0d SYNC_REQ for ONE ATB request, expected exactly 1 (double request)", $realtime, `__LINE__, NReq)));
		sync_req_atb_synq = 0;
		repeat (50)     TipSendMsg (tip, tip_clk, tipt, 0);

		// Test 4f: the same guard under BACK-TO-BACK retires, which is
		// where the one-cycle window actually opens (see test 5f for the
		// mechanism). TipSendMsg raises tip.iretire for one cycle at a
		// time and can never reach it; a real core can.
		NPeriodic = 0; NAnySync = 0; NReq = 0; sync_count_en = 1;
		sync_req_atb_synq = 1;
		tip.itype   <= OTHER;
		tip.iretire <= 1'b1;
		repeat (40) @(posedge tip_clk);
		tip.iretire <= 1'b0;
		repeat (20) @(posedge tip_clk);
		sync_count_en = 0;
		void'(tt_assert((NReq == 1), $sformatf("%0.2f: Line %0d: Test failed: %0d SYNC_REQ for ONE ATB request under back-to-back retires, expected exactly 1", $realtime, `__LINE__, NReq)));
		sync_req_atb_synq = 0;
		repeat (50)     TipSendMsg (tip, tip_clk, tipt, 0);

		// ------------------------------------------------------------
		// Test 5 (P8): explicit sync request over the TE register
		// (trTeControl.InstSyncReq). Same arm, same on-wire code as the
		// ATB request -- but NOT mode-gated: the field is the trigger.
		// ------------------------------------------------------------
		// Test 5a: InstSyncMode = OFF (no cadence at all) -- the request
		// must still produce SYNC=14. This is the mode-independence claim
		// D-P8-5; in mode OFF nothing else can generate a sync, so the
		// event cannot be confused with a periodic one.
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_OFF;
		repeat (100) TipSendMsg (tip, tip_clk, tipt, 0); // drain stale state
		// The counting window opens BEFORE the request on purpose: the sync
		// output is three cycles behind the generator, so a window opened at
		// the moment the sync is observed would count that very message again.
		NPeriodic = 0; NAnySync = 0; NReq = 0; sync_count_en = 1;
		te_sync_write();
		while (sync.reason == NEXUS_SYNC_NONE) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_REQ), $sformatf("%0.2f: Line %0d: Test failed: NEXUS_SYNC_REQ (14) expected for the TE request in mode OFF, got %0d", $realtime, `__LINE__, sync.reason)));

		// Test 5b: exactly ONE sync per request -- and the request was
		// acknowledged, so the CSR side is free to launch the next one.
		// (A DUT that emitted the sync but never acknowledged would leave
		// the shim model busy for ever and starve every later request.)
		void'(tt_assert(!te_req_busy, $sformatf("%0.2f: Line %0d: Test failed: request not acknowledged (CSR side still busy)", $realtime, `__LINE__)));
		repeat (200) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en = 0;
		void'(tt_assert((NReq == 1), $sformatf("%0.2f: Line %0d: Test failed: %0d SYNC_REQ for one TE request, expected exactly 1 (double request)", $realtime, `__LINE__, NReq)));
		void'(tt_assert((NAnySync == 1), $sformatf("%0.2f: Line %0d: Test failed: %0d syncs in total for one TE request in mode OFF, expected exactly 1", $realtime, `__LINE__, NAnySync)));

		// Test 5c (NEGATIVE): no request -> no explicit sync, ever. The
		// counterpart to 5a: same configuration, only the write missing.
		NPeriodic = 0; NAnySync = 0; NReq = 0; sync_count_en = 1;
		repeat (200) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en = 0;
		void'(tt_assert((NReq == 0), $sformatf("%0.2f: Line %0d: Test failed: %0d SYNC_REQ without a request", $realtime, `__LINE__, NReq)));

		// Test 5d: COLLISION with the ATB request (mode 7). Two INDEPENDENT
		// requests are raised in the same window, and they do not reach the
		// generator in the same cycle (the ATB level crosses through the
		// handshake FSM, the TE strobe through one latch), so each gets its
		// own anchor: exactly TWO SYNC=14 -- one per request, which is the
		// invariant that matters. Neither is lost, and neither produces two.
		// The case where two requests DO fall on the same retire is covered
		// deterministically by the cfsync leg of
		// tests/instruction/33_te_sync_req (one message serves both).
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_ATB;
		repeat (50) TipSendMsg (tip, tip_clk, tipt, 0);
		NPeriodic = 0; NAnySync = 0; NReq = 0; sync_count_en = 1;
		sync_req_atb_synq = 1;
		te_sync_write();
		repeat (200) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en = 0;
		void'(tt_assert((NReq == 2), $sformatf("%0.2f: Line %0d: Test failed: %0d SYNC_REQ for two independent requests (TE + ATB), expected exactly 2", $realtime, `__LINE__, NReq)));
		void'(tt_assert(!te_req_busy, $sformatf("%0.2f: Line %0d: Test failed: TE request not acknowledged by the collision sync", $realtime, `__LINE__)));
		sync_req_atb_synq = 0;
		repeat (50) TipSendMsg (tip, tip_clk, tipt, 0);

		// Test 5e: a request written while instruction tracing is PAUSED
		// is deferred, not dropped (D-P8-6) -- and the resume anchor keeps
		// its precedence: TRACE_ENABLE (5) first, the deferred request
		// (14) after it.
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_OFF;
		cs_tip.trTeInstTracing  = 0;
		repeat (50) TipSendMsg (tip, tip_clk, tipt, 0);
		te_sync_write();
		NPeriodic = 0; NAnySync = 0; NReq = 0; sync_count_en = 1;
		repeat (100) TipSendMsg (tip, tip_clk, tipt, 0);
		sync_count_en = 0;
		void'(tt_assert((NAnySync == 0), $sformatf("%0.2f: Line %0d: Test failed: %0d syncs while instruction tracing is paused", $realtime, `__LINE__, NAnySync)));
		void'(tt_assert(te_req_busy, $sformatf("%0.2f: Line %0d: Test failed: pending request lost during the pause (acknowledged without a sync)", $realtime, `__LINE__)));
		cs_tip.trTeInstTracing = 1;
		while (sync.reason == NEXUS_SYNC_NONE) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_TRACE_ENABLE), $sformatf("%0.2f: Line %0d: Test failed: resume anchor must be TRACE_ENABLE (5), got %0d", $realtime, `__LINE__, sync.reason)));
		TipSendMsg (tip, tip_clk, tipt, 0);
		while (sync.reason == NEXUS_SYNC_NONE) begin
			TipSendMsg (tip, tip_clk, tipt, 0);
		end
		void'(tt_assert((sync.reason == NEXUS_SYNC_REQ), $sformatf("%0.2f: Line %0d: Test failed: deferred TE request expected after the resume anchor, got %0d", $realtime, `__LINE__, sync.reason)));
		repeat (50) TipSendMsg (tip, tip_clk, tipt, 0);

		// Test 5f: BACK-TO-BACK retires. TipSendMsg raises tip.iretire for a
		// single cycle at a time, so it can never expose an arm that stays
		// eligible for one more cycle after it fired -- and that is exactly
		// the window the handshake leaves open (the FSM drops its output one
		// cycle AFTER the acknowledgement). A real core retires on
		// consecutive cycles, so this leg drives iretire continuously and
		// counts: one request, one SYNC=14. Guards both request sources.
		repeat (30) TipSendMsg (tip, tip_clk, tipt, 0);
		NPeriodic = 0; NAnySync = 0; NReq = 0; sync_count_en = 1;
		te_sync_write();
		tip.itype   <= OTHER;
		tip.iretire <= 1'b1;
		repeat (40) @(posedge tip_clk);
		tip.iretire <= 1'b0;
		repeat (20) @(posedge tip_clk);
		sync_count_en = 0;
		void'(tt_assert((NReq == 1), $sformatf("%0.2f: Line %0d: Test failed: %0d SYNC_REQ for ONE TE request under back-to-back retires, expected exactly 1", $realtime, `__LINE__, NReq)));

		// ------------------------------------------------------------
		// Test 6 (D1 / B-R13-1): the HALF-WORD cadence must count
		// HALF-WORDS -- not instructions, and not "instructions whose
		// ilastsize happens to be odd".
		//
		// Regression guard for the defect class "mixed instruction widths":
		// cnt_tiphalfword.inc was `tip.iretire ? tip.ilastsize : '0` and
		// counter_if.inc is ONE bit adding exactly 1, so a compressed
		// instruction moved the counter by 0 and a 48-bit one by 0 as well.
		// Measured on the defective RTL (HEAD 8abc2d265): +0 / +10 / +5 for
		// the three legs below, and 0 periodic syncs for RVC-only code that
		// retired four times the programmed half-word budget.
		// ------------------------------------------------------------
		// Test 6a: read the counter directly. Its value never reaches the
		// wire -- the only sink is the saturation overflow flag -- so this
		// is the only way to state what it counts.
		// InstSyncMax = 15 puts the threshold at 2**19 half-words, i.e. out
		// of reach, so the counter just counts and SyncCntClr stays low --
		// no overflow, no rearm, nothing to disturb the readout.
		cs_tip.trTeInstTracing  = 1;
		cs_tip.trTeInstSyncMax  = 15;
		cs_tip.trTeInstSyncMode = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_HALFWORDS;
		tip_rst = 1;
		TipSendMsg (tip, tip_clk, tipt, 3);
		tip_rst = 0;
		TipSendMsg (tip, tip_clk, tipt, 3);   // consumes EXIT_FROM_SYS_RST
		repeat (10) TipSendMsg (tip, tip_clk, tipt, 0); // let SyncCntClr fall

		// 10 compressed (RVC) instructions: 10 half-words.
		tipt.ilastsize = 2'd0;
		HwBase = sync_inst.cnt_tiphalfword.value;
		repeat (10) TipSendMsg (tip, tip_clk, tipt, 0);
		HwDelta = sync_inst.cnt_tiphalfword.value - HwBase;
		$display("D1-MEASURE: 10 x RVC (ilastsize=0)     -> counter +%0d (half-words retired: 10)", HwDelta);
		void'(tt_assert((HwDelta == 10), $sformatf("%0.2f: Line %0d: Test failed: 10 RVC retirements are 10 half-words, counter moved by %0d (B-R13-1: RVC counted as 0)", $realtime, `__LINE__, HwDelta)));

		// 10 uncompressed (32-bit) instructions: 20 half-words.
		tipt.ilastsize = 2'd1;
		HwBase = sync_inst.cnt_tiphalfword.value;
		repeat (10) TipSendMsg (tip, tip_clk, tipt, 0);
		HwDelta = sync_inst.cnt_tiphalfword.value - HwBase;
		$display("D1-MEASURE: 10 x 32-bit (ilastsize=1)  -> counter +%0d (half-words retired: 20)", HwDelta);
		void'(tt_assert((HwDelta == 20), $sformatf("%0.2f: Line %0d: Test failed: 10 32-bit retirements are 20 half-words, counter moved by %0d (B-R13-1: counted instructions, not half-words)", $realtime, `__LINE__, HwDelta)));

		// A mixed run, which is what real RVC code looks like: 5 + 5.
		HwBase = sync_inst.cnt_tiphalfword.value;
		for (int i = 0; i < 5; i++) begin
			tipt.ilastsize = 2'd0; TipSendMsg (tip, tip_clk, tipt, 0);
			tipt.ilastsize = 2'd1; TipSendMsg (tip, tip_clk, tipt, 0);
		end
		HwDelta = sync_inst.cnt_tiphalfword.value - HwBase;
		$display("D1-MEASURE: 5 x RVC + 5 x 32-bit mixed -> counter +%0d (half-words retired: 15)", HwDelta);
		void'(tt_assert((HwDelta == 15), $sformatf("%0.2f: Line %0d: Test failed: 5 RVC + 5 32-bit are 15 half-words, counter moved by %0d (B-R13-1, mixed-width case)", $realtime, `__LINE__, HwDelta)));
		tipt.ilastsize = tip_ilastsize_t'(TIP_DEFAULT_ILASTSIZE);

		// Test 6b: the cadence itself, at a REACHABLE threshold
		// (InstSyncMax = 0 -> 2**4 = 16 half-words). 68 half-words are
		// driven as RVC and again as 32-bit code.
		//
		// Expected counts, and where they come from: a window is 16
		// half-words PLUS the beat that carries the sync out, whose
		// half-words the SyncCntClr rearm eats (clr has priority 1 in
		// counter.sv). So the effective spacing is 17 half-words for RVC
		// (step 1) and 18 for 32-bit code (step 2):
		//   RVC     68 / 17 = 4 periodic syncs
		//   32-bit  68 / 18 = 3 periodic syncs
		// On the defective RTL the RVC leg produced 0 -- RVC-only code
		// never synchronized at all, which is the class this guards.
		d1_periodic_over (2'd0, 68, D1CadRvc); // 68 RVC      = 68 half-words
		d1_periodic_over (2'd1, 34, D1Cad32);  // 34 x 32-bit = 68 half-words
		$display("D1-MEASURE: 68 half-words as RVC    -> %0d periodic sync(s)", D1CadRvc);
		$display("D1-MEASURE: 68 half-words as 32-bit -> %0d periodic sync(s)", D1Cad32);
		void'(tt_assert((D1CadRvc == 4), $sformatf("%0.2f: Line %0d: Test failed: 68 half-words of RVC code must give 4 periodic syncs at a 16-half-word cadence, got %0d (B-R13-1: was 0 -- RVC never synchronized)", $realtime, `__LINE__, D1CadRvc)));
		void'(tt_assert((D1Cad32 == 3), $sformatf("%0.2f: Line %0d: Test failed: 68 half-words of 32-bit code must give 3 periodic syncs at a 16-half-word cadence, got %0d (B-R13-1: was 2 -- the cadence counted instructions)", $realtime, `__LINE__, D1Cad32)));

		tt_evaluate();
		$finish();
	end

endmodule
