// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    FIFO_OVERRUN anchor inside a trap window: the third case of the
 *           anchor assumption, after CF and NOT_TAKEN_BRANCH.
 *
 * @details
 *   Found in a KV260 soak run: a recovery anchor `PrevIAddr+size` landed on
 *   an ecall address. The trapping instruction NEVER retires (iretire=0,
 *   one-to-one retire rule) -- execution continues in the handler. The
 *   decoder anchors on never-executed code, walks linearly and dies
 *   ("indirect address encountered in ICNT", 150k PCs into the run).
 *
 *   Mechanism: `inject_hold` covered PrevRetireWasCf plus CF and not-taken
 *   retires in the emission cycle -- but the trap marker beat (iretire=0) and
 *   the window up to the handler retire were invisible, and there
 *   `PrevIAddr+size` names the trapping instruction that never retires. Fix:
 *   `PrevEventWasTrap` tracking plus a hold on trap beats, in both injector
 *   instances.
 *
 *   This leg forces the collision statistically: an indirect call ring (IBH
 *   dense, ATB throttled, hence hundreds of natural recoveries) in which
 *   EVERY FOURTH iteration traps synchronously (no-retire ecall, handler,
 *   mret). The trap windows are then dense enough for drop-episode ends to
 *   fall inside them repeatedly.
 *
 *   Gates: scripts/cli_trapanchor_test.sh
 *     T0  Control run (throttle off, same workload): "Decoded OK" and
 *         transition-exact -- the trap path itself is clean.
 *     T1  >=1 Nexus error message -> a natural overflow was reached
 *     T2  >=10 exception IBHs     -> trap windows present inside the storm
 *     T3  "Decoded OK" and every transition legal (check_transitions)
 *   Counter-proof: without the PrevEventWasTrap hold, T3 fails with the
 *   original symptom (anchor on the trap address).
 */
module trap_anchor_tb #(parameter int ATB_HALF_NS = 40, parameter int TRAP_EVERY_P = 4);

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (ATB_HALF_NS),
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("trap_anchor_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("trap_anchor_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("trap_anchor_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("trap_anchor_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC      = 32'h0000_7000;
	localparam logic [31:0] HANDLER_PC   = 32'h0004_0000;
	localparam int unsigned RING_TARGETS = 14;
	localparam logic [31:0] RING_BASE    = 32'h0020_0000;
	localparam logic [31:0] RING_STRIDE  = 32'h400;
	localparam logic [31:0] SITES_STORM  = 32'h0011_0000;
	localparam int unsigned STORM_CALLS  = 3000;
	localparam int unsigned TRAP_EVERY   = TRAP_EVERY_P;

	// Storm: an indirect call ring with one call site per iteration, advancing
	// monotonically. Every TRAP_EVERY-th iteration traps synchronously (the
	// no-retire form) into the fixed handler and returns through mret. Roles:
	// each ecall address in the monotonic call-site band carries the trap role
	// exactly once; the handler is re-entered repeatedly in the same role.
	task automatic trap_storm(input logic [31:0] sites_base, input int unsigned n);
		env.cpu.uninferable_jump(.target(sites_base));
		for (int i = 0; i < n; i++) begin
			logic [31:0] fn = RING_BASE + 32'((i % RING_TARGETS) + 1) * RING_STRIDE;
			env.cpu.indirect_call_to(.target(fn));    // call site (4 B per iteration)
			env.cpu.run(8);                           // fn body (2 instructions)
			env.cpu.ret();
			if ((i % TRAP_EVERY) == (TRAP_EVERY - 1)) begin
				// Testbench pitfall: the collision needs a NON-CF instruction
				// IMMEDIATELY before the trap. With a ret or jump there, the
				// existing PrevRetireWasCf hold already covers the anchor and
				// the leg tests nothing -- three throttle settings stayed green
				// for exactly that reason. The hardware shape was: an addi
				// retires, the following ecall traps, and the anchor
				// (addi address + 4) points at the ecall.
				env.cpu.run(4);                       // non-CF instruction right before the trap
				// Synchronous exception at the current site position: the
				// faulting instruction NEVER retires.
				env.cpu.exception_trap(.cause(tip_ecause_e'(11)),   // ECALL_M
				                       .handler(HANDLER_PC),
				                       .no_retire(1));
				env.cpu.run(12);                      // handler body (3 instructions)
				env.cpu.mret();
			end
			env.cpu.run(4);                           // 1 Fuellinstr je Iteration
		end
	endtask

	initial begin
		$display("[trap_anchor_tb] %0t: waiting for reset release (ATB_HALF_NS=%0d)",
		         $time, ATB_HALF_NS);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active (1'b0);
		// Full compression suite, as configured in the hardware soak runs (periodic sync off).
		env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn   (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache  (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory  (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt         (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch     (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnIbhs             (1'b1);
		env.csr.Set_te_trTeInstFeatures_InstEnRepeatInstr      (1'b1);
		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);

		trap_storm(SITES_STORM, STORM_CALLS);

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

		if (env.cpu.event_count() == 0) $error("[trap_anchor_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[trap_anchor_tb] no ATB bytes observed");
		$display("[trap_anchor_tb] PASS (sim); decode gates in scripts/cli_trapanchor_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#80ms;
		$error("[trap_anchor_tb] TIMEOUT - test exceeded 80 ms wall time");
		$finish;
	end

endmodule
`default_nettype wire
