// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Flush-clobber guard: ATB flush pulses in the middle of a dense JTC
 *           stream under backpressure -- the silent single-message-loss class.
 *
 * @details
 *   Found on hardware under heavy ATB stalling: of 2 745 JTC hits on one ring
 *   hop, 2 744 carry JIDX=16 and EXACTLY ONE carries JIDX=44. The JIDX=16
 *   message of that hop is MISSING on the wire, the ring slips by one
 *   position and 287 PCs are mispaired until the next re-anchor. The framing
 *   stayed intact, so the loss is MESSAGE-granular, ahead of byte
 *   serialization.
 *
 *   Mechanism (ct_L2_msg_gen): `if (FlushRequest) send_flush_msg()` sat as a
 *   TRAILING if behind the arm chain. When the flush service cycle collides
 *   with a consume_etip beat, send_flush_msg() overwrites the message just
 *   composed (sub_type/tcode become NEXUS_MSG_FLUSH, which is internal use
 *   only and for which the formatter emits no wire bytes), so exactly one
 *   message disappears. do_flush comes from atb_afvalid OR an Enable fall OR
 *   a trace-off correlation, which makes the same mechanism the candidate
 *   behind the losses observed at enable-off edges. The collision depends on
 *   the backpressure phase, which is why narrowly targeted reproducers stayed
 *   green.
 *
 *   This leg forces the collision statistically: a ping-pong indirect-jump
 *   ring in which every hop is a single jalr, giving a JTC hit density of
 *   roughly one message per one to two instructions, crossed with branch
 *   prediction and JTC, a half-word periodic sync, an ATB throttle, and MANY
 *   atb_force_flush pulses at prime-swept intervals in mid-stream.
 *
 *   Gates: scripts/cli_flushclobber_test.sh
 *     F0  Control leg (+NO_FLUSH): ring x throttle x periodic sync without
 *         mid-stream pulses -> green (single-factor falsification)
 *     F1  Flush leg: >=1 VendorJTC and >=1 VendorBP -> stimulus active
 *     F2  NexRv "Decoded OK" (-bp) AND check_transitions legal. The class is
 *         fixed; red -- a ring slip or an illegal transition -- means it has
 *         regressed.
 */
module flush_clobber_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (40),     // throttle: reproduces the observed backpressure phase space
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("flush_clobber_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("flush_clobber_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("flush_clobber_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("flush_clobber_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC   = 32'h0000_7000;
	localparam logic [31:0] RING_LO   = 32'h0010_0000;  // low half of the ping-pong ring
	localparam logic [31:0] RING_HI   = 32'h0011_0000;  // high half of the ping-pong ring
	localparam logic [31:0] CALM_PC   = 32'h0030_0000;
	localparam int unsigned HOPS      = 7;              // per side
	localparam int unsigned LAPS      = 2500;
	localparam int unsigned N_FLUSH   = 60;

	bit no_flush;
	bit driver_done = 1'b0;
	int flush_pulses = 0;

	// One lap: ping-pong lo[0] -> hi[0] -> lo[1] -> hi[1] -> ... and back to
	// lo[0]. Every node is a SINGLE jalr (uninferable_jump). After lap 1 all
	// targets are installed in the JTC, so what follows is pure hit density,
	// roughly one JTC message per instruction. Each node has a fixed target,
	// keeping one role per address.
	task automatic one_lap(input int lap);
		for (int h = 0; h < HOPS; h++) begin
			env.cpu.uninferable_jump(.target(RING_HI + 32'(h) * 32'h400));
			env.cpu.uninferable_jump(.target((h == HOPS - 1)
			                                 ? ((lap == LAPS - 1) ? CALM_PC
			                                                       : RING_LO)
			                                 : (RING_LO + 32'(h + 1) * 32'h400)));
		end
	endtask

	initial begin
		no_flush = $test$plusargs("NO_FLUSH");
		$display("[flush_clobber_tb] %0t: waiting for reset release (NO_FLUSH=%0d)", $time, no_flush);
		env.wait_for_reset_release();

		env.csr.clear();
		// Board-Konfiguration soak/00008: bpjtc + TS + sync_hw10 (Mode 3/Max 6).
		env.csr.Set_te_trTsControl_Active       (1'b1);
		env.csr.Set_te_trTeControl_InstSyncMode (4'd3);
		env.csr.Set_te_trTeControl_InstSyncMax  (4'd6);
		env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache  (1'b1);
		$display("[flush_clobber_tb] BP+JTC + timestamps + half-word sync, ATB throttled to 40 ns");
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);
		env.cpu.uninferable_jump(.target(RING_LO));

		fork
			begin : driver
				for (int lap = 0; lap < LAPS; lap++) one_lap(lap);
				env.cpu.run(16);
				driver_done = 1'b1;
			end
			// Flusher: atb_afvalid pulses (the do_flush_atb path) in mid-stream,
			// prime-swept intervals (phase sweep against the ring period
			// and the backpressure pattern).
			begin : flusher
				if (!no_flush) begin
					#2100ns;
					for (int p = 0; p < N_FLUSH; p++) begin
						if (driver_done) break;
						env.atb_force_flush = 1'b1;
						#150ns;
						env.atb_force_flush = 1'b0;
						flush_pulses++;
						#(1700ns + 130ns * (p % 23));
					end
				end
			end
		join

		env.cpu.run(400);                                  // Calm-Region
		env.cpu.exit_trace();
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(8000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(1000);

		$display("[flush_clobber_tb] flush_pulses=%0d", flush_pulses);
		if (env.cpu.event_count() == 0) $error("[flush_clobber_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[flush_clobber_tb] no ATB bytes observed");
		$display("[flush_clobber_tb] PASS (sim); decode gates in scripts/cli_flushclobber_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#60ms;
		$error("[flush_clobber_tb] TIMEOUT - test exceeded 60 ms wall time");
		$finish;
	end

endmodule
`default_nettype wire
