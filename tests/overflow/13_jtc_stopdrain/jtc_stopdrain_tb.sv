// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    JTC, periodic sync, overflow pressure and InstTracing going low on
 *           a running core: stop-drain ordering of the message paths.
 *
 * @details
 *   Found in a KV260 soak run: the second-to-last message of the stream is a
 *   VendorJTC carrying the inner-loop signature (ICNT=8, JIDX=15, HIST=3),
 *   even though the two messages immediately before it -- ResourceFull and
 *   DirectBranchSync -- describe LATER execution. The JTC message overtook
 *   the sync, or was presented again at the stop drain; the decoder re-bases
 *   on the sync and then runs with the stale ICNT ("resolved source PC to a
 *   non-indirect instruction"). The decode dies on the LAST edge of the
 *   stream.
 *
 *   Suspected mechanism in msg_gen: TraceMsg is a hold register (stable under
 *   backpressure), while the drain chains (repeated history, ResourceFull,
 *   sync-carrying eTIP items) and the disable-correlation path are driven
 *   from separate places. Under backpressure at the InstTracing-off edge
 *   their order can invert.
 *
 *   This leg forces the collision: JTC-only configuration, a call ring with a
 *   constant return target (so JTC hits have an identical signature), a dense
 *   periodic sync, an ATB throttle (backpressure plus natural overflows), and
 *   InstTracing driven to 0 IN THE MIDDLE of the storm while the core keeps
 *   running -- repeated across several phase alignments, because a single
 *   edge does not reliably hit the colliding phase.
 *
 *   Gates: scripts/cli_jtcstopdrain_test.sh
 *     J0  Control run (throttle off): "Decoded OK" and transition-exact
 *     J1  >=1 error message  -> overflow / backpressure pressure present
 *     J2  >=100 VendorJTC    -> the JTC path carries the stream
 *     J3  "Decoded OK" and every transition legal -- the actual guard; this is
 *         where the hardware class dies
 */
module jtc_stopdrain_tb #(parameter int ATB_HALF_NS = 40,
						  parameter int N_EDGES     = 6);

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (ATB_HALF_NS),
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("jtc_stopdrain_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("jtc_stopdrain_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("jtc_stopdrain_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("jtc_stopdrain_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC     = 32'h0000_7000;
	localparam logic [31:0] LEAF_PC     = 32'h0002_0000;  // single target -> constant JTC hits
	localparam logic [31:0] SITES_BASE  = 32'h0011_0000;
	localparam int unsigned LAPS_PER_BURST = 400;

	// One burst: an inner call loop in which every iteration makes an indirect
	// call to the SAME leaf, so from lap 2 on every call is a JTC hit with an
	// identical signature. Interleaved calm sections with conditional branches
	// provide HIST traffic and carry the ResourceFull messages. Call sites
	// advance monotonically (one role per address); the leaf is re-entered
	// repeatedly in the same role.
	task automatic jtc_burst(input logic [31:0] sites_base, input int unsigned laps);
		env.cpu.uninferable_jump(.target(sites_base));
		for (int i = 0; i < laps; i++) begin
			env.cpu.indirect_call_to(.target(LEAF_PC));
			env.cpu.run(8);                                   // leaf body
			env.cpu.ret();
			env.cpu.run(4);
			if (i[1:0] == 2'b11) begin
				// Calm insert: two not-taken branches, for HIST traffic
				env.cpu.branch_not_taken(.target(env.cpu.cur_pc + 32'h10));
				env.cpu.run(8);
				env.cpu.branch_not_taken(.target(env.cpu.cur_pc + 32'h10));
				env.cpu.run(4);
			end
		end
	endtask

	initial begin
		$display("[jtc_stopdrain_tb] %0t: waiting for reset release (ATB_HALF_NS=%0d)",
		         $time, ATB_HALF_NS);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active (1'b0);
		// JTC only (the hardware configuration of this class) plus a dense periodic sync
		env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache (1'b1);
		// Exactly as configured on hardware: mode 6 counts instructions and
		// Max 0 gives a sync every 2^(0+4) = 16 instructions, the DENSEST
		// setting. An earlier version using clock cycles with Max 7 had a sync
		// rate orders of magnitude sparser and never hit the
		// sync / JTC / edge collision.
		env.csr.Set_te_trTeControl_InstSyncMode (4'd6);
		env.csr.Set_te_trTeControl_InstSyncMax  (4'd0);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);

		// N edges: storm -> InstTracing=0 while the core keeps RUNNING (the
		// stop-drain case) -> core continues untraced -> InstTracing=1
		// (resume). Odd burst lengths per edge shift the phase of the off edge
		// against both the sync period and the backpressure pattern.
		//
		// The edge has to be surgical: the hardware constellation needs the
		// off edge to fall WHILE the next_iaddr pairing of the last ret is
		// still OPEN, meaning no retire between the ret and the edge, only
		// idle. The sweep e=0..N-1 moves the edge in idle-sized steps across
		// the pairing window. A purely statistical version with run(4) after
		// the burst always closed the pairing before the edge and stayed
		// green.
		for (int e = 0; e < N_EDGES; e++) begin
			jtc_burst(SITES_BASE + 32'(e) * 32'h1_0000,
			          LAPS_PER_BURST + 32'(e) * 37);
			// Last lap: a ret with a JTC hit, then keep the pairing OPEN.
			env.cpu.indirect_call_to(.target(LEAF_PC));
			env.cpu.run(8);
			env.cpu.ret();
			env.cpu.idle(e);                                  // Phasen-Sweep
			env.csr.Set_te_trTeControl_InstTracing (1'b0);   // the core keeps running
			env.cpu.run(64);                                  // untraced (S7-Capture-Futter)
			env.cpu.idle(200);                                // drain window
			if (e < N_EDGES - 1) begin
				env.csr.Set_te_trTeControl_InstTracing (1'b1);
				env.cpu.run(16);
			end
		end

		env.cpu.exit_trace();
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_Enable (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(8000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(1000);

		if (env.cpu.event_count() == 0) $error("[jtc_stopdrain_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[jtc_stopdrain_tb] no ATB bytes observed");
		$display("[jtc_stopdrain_tb] PASS (sim); decode gates in scripts/cli_jtcstopdrain_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#80ms;
		$error("[jtc_stopdrain_tb] TIMEOUT - test exceeded 80 ms wall time");
		$finish;
	end

endmodule
`default_nettype wire
