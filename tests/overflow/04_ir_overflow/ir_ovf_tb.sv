// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Implicit-return stack across a NATURAL overflow recovery.
 *
 * @details
 *   Regression guard for the "Not enough entries on callstack" class found on
 *   hardware during soak runs with the full compression suite: calls and
 *   returns inside the discarded overflow window mutate the encoder's return
 *   stack while the decoder sees none of them (and clears its own call stack
 *   on the error message). A stale encoder frame that still predicts the real
 *   target correctly flags the return as "implicit" -- the decoder pops a
 *   wrong or missing frame and desynchronizes:
 *
 *     ERROR: Expected an indirect branch (jalr/ret/jr) at the source ...
 *     ERROR: Not enough entires on callstack
 *
 *   Fix, in the same family and at the same anchor point as the JtcValid /
 *   BpEpoch clears: ct_L23_preproc_composer_etip clears ret_sp at the
 *   FIFO_OVERRUN anchor (etip_ovf_inject_done). An empty encoder stack is
 *   always SAFE -- it only forces explicit returns, costing bandwidth but not
 *   correctness, until post-recovery calls refill both sides in lockstep.
 *
 *   Structure follows 03_jtc_overflow, whose four testbench rules apply here
 *   as well: one role per address; blocks between CF events; a calm region is
 *   never re-entered; the storm is large enough to produce a real overflow.
 *   A RING of RING_TARGETS functions is called through function pointers
 *   (indirect_call_to, one IBH per iteration) in a continuous loop. Each
 *   function contains a not-taken branch (a HIST bit) and a nested call to a
 *   shared leaf function, giving a return depth of 2. The call sites advance
 *   monotonically (8 B per iteration), so every address keeps exactly one
 *   role. During the storm, pushes and pops fall into the drop windows; the
 *   returns that follow are the trap.
 *
 *   Gates: scripts/cli_irovf_test.sh
 *     I0  Control run (CALM_ONLY=1): ring traffic without an overflow decodes
 *         cleanly
 *     I1  >=1 Nexus error message   -> a natural overflow was reached
 *     I2  InstEnImplicitReturn=1 in the simulation log -> the feature was on
 *     I3  NexRv "Decoded OK"        -> the actual guard: ret_sp cleared at the
 *                                      anchor
 */

// CALM_ONLY=1 runs the CONTROL leg. It is a top-level parameter rather than a
// plusarg (xelab -R, see 03_jtc_overflow). The Vivado .bat wrapper splits
// '-generic_top N=V' at the '=', so the driving script sets the parameter
// through a wrapper top instead.
module ir_ovf_tb #(parameter bit         CALM_ONLY = 1'b0,
				   parameter logic [3:0] SYNC_MODE = 4'd2,
				   parameter logic [3:0] SYNC_MAX  = 4'd7);

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (5),      // == tip half period, so the drain cannot outrun the source
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("ir_ovf_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("ir_ovf_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("ir_ovf_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("ir_ovf_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC      = 32'h0000_7000;
	// As in 03: with compression active -- here implicit returns and inferable
	// calls that emit no message -- the storm has to be LARGE, otherwise the
	// FIFO keeps up.
	localparam int unsigned STORM_CALLS  = 4000;
	localparam int unsigned RING_TARGETS = 14;
	localparam logic [31:0] RING_BASE    = 32'h0020_0000;
	localparam logic [31:0] RING_STRIDE  = 32'h400;
	localparam logic [31:0] NESTED_PC    = 32'h0002_1000;  // shared leaf function
	// Call-site regions: one per phase, monotonic, never re-entered.
	localparam logic [31:0] SITES_WARM   = 32'h0010_0000;
	localparam logic [31:0] SITES_STORM1 = 32'h0011_0000;  // 4000*8B = 32 KiB
	localparam logic [31:0] SITES_STORM2 = 32'h0013_0000;
	localparam logic [31:0] SITES_CALM   = 32'h0015_0000;  // control leg

	// One pass through the ring, kept DENSE so it can actually overflow, like
	// the jump ring in 03: roughly one IBH per three instructions. An earlier
	// version with an eight-instruction body never overflowed -- dropped=0
	// over 2x4000 iterations even with the ATB throttled.
	//
	// The common case is the minimal body in the F ring (indirect call, one
	// instruction, implicit return); every 16th iteration runs through the G
	// ring with a nested call, giving return depth 2 plus a HIST bit.
	// Separate ring bases keep every address at ONE role, and the call sites
	// advance by 4 B per iteration.
	localparam logic [31:0] RING_G_BASE = 32'h0028_0000;
	task automatic ir_storm(input logic [31:0] sites_base, input int unsigned n);
		env.cpu.uninferable_jump(.target(sites_base));
		for (int i = 0; i < n; i++) begin
			if ((i % 16) == 15) begin
				logic [31:0] gn = RING_G_BASE + 32'((i % RING_TARGETS) + 1) * RING_STRIDE;
				env.cpu.indirect_call_to(.target(gn)); // Call-Site (4 B/Iter)
				env.cpu.run(4);                       // G_i (L)
				env.cpu.branch_not_taken();           // G_i+4 BD nt (HIST-Bit)
				env.cpu.call_to(.target(NESTED_PC));  // G_i+8 CD (push Tiefe 2)
				env.cpu.run(4);                       // NESTED (L)
				env.cpu.ret();                        // NESTED+4 -> G_i+12
				env.cpu.run(4);                       // G_i+12 (L)
				env.cpu.ret();                        // G_i+16 -> Call-Site+4
			end
			else begin
				logic [31:0] fn = RING_BASE + 32'((i % RING_TARGETS) + 1) * RING_STRIDE;
				env.cpu.indirect_call_to(.target(fn)); // Call-Site (4 B/Iter)
				env.cpu.run(4);                       // F_i (L)
				env.cpu.ret();                        // F_i+4 -> Call-Site+4
			end
		end
	endtask

	initial begin
		$display("[ir_ovf_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active                    (1'b0);
		if (SYNC_MODE != 0) begin
			env.csr.Set_te_trTeControl_InstSyncMode (SYNC_MODE);
			env.csr.Set_te_trTeControl_InstSyncMax  (SYNC_MAX);
		end
		// One-factor test: ONLY ImplicitReturn on (no JTC, no BP).
		env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn (1'b1);
		$display("[ir_ovf_tb] InstEnImplicitReturn=1");
		env.csr.Set_te_trTeControl_Enable                    (1'b1);
		env.csr.Set_te_trTeControl_InstTracing               (1'b1);
		env.csr.Set_te_trTeControl_Active                    (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);

		// Quiet warm-up lap: encoder and decoder are guaranteed to agree here.
		ir_storm(SITES_WARM, RING_TARGETS);
		env.cpu.run(400);

		// CONTROL leg: ring traffic without an overflow, in its own call-site region.
		if (CALM_ONLY) begin
			ir_storm(SITES_CALM, 3 * RING_TARGETS);
			env.cpu.run(400);
			env.cpu.exit_trace();
			env.cpu.idle(50);
			env.csr.Set_te_trTeControl_InstTracing (1'b0);
			env.cpu.idle(200);
			env.csr.Set_te_trTeControl_Enable      (1'b0);
			env.atb_force_flush = 1'b1;
			env.cpu.idle(4000);
			env.atb_force_flush = 1'b0;
			env.cpu.idle(500);
			env.csr.Set_te_trTeControl_Active(1'b0);
			env.cpu.idle(1000);
			$display("[ir_ovf_tb] calm control leg finished");
			$finish;
		end

		// Storm 1: a natural overflow in the middle of call/return ring
		// traffic. The implicit-return-compressed stream (implicit returns,
		// inferable calls that emit no message, one IBH per eight
		// instructions) keeps up with a full-rate ATB drain -- measured
		// dropped=0 over 2x4000 iterations. To reach the natural overflow the
		// drain is throttled during the storms with the environment's stall
		// injector (STALL_PERIOD=32, LENGTH<=16, roughly half bandwidth).
		env.atb_stall_enable = 1'b1;
		ir_storm(SITES_STORM1, STORM_CALLS);
		env.atb_stall_enable = 1'b0;
		env.cpu.run(1600);      // calm phase: continue linearly in the storm-1 region

		// Storm 2 in its own region, followed by a clean tail.
		env.atb_stall_enable = 1'b1;
		ir_storm(SITES_STORM2, STORM_CALLS);
		env.atb_stall_enable = 1'b0;
		env.cpu.run(1600);

		env.cpu.exit_trace();
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);

		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(1000);

		if (env.cpu.event_count() == 0) $error("[ir_ovf_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[ir_ovf_tb] no ATB bytes observed");
		$display("[ir_ovf_tb] PASS (sim); decode gates in scripts/cli_irovf_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[ir_ovf_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule
