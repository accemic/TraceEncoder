// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Sync-cadence PRODUCTION DEFAULT: sustained run with the
 *           InstSyncMax RESET value (P0-02).
 *
 * @details
 *   The question this scenario answers is not "does periodic sync work" --
 *   tests 04/29/30 cover that -- but "is the value the encoder comes out of
 *   reset with a value a product can ship". The natural programming path is
 *   ONE write to trTeControl ("periodic sync, counted in instructions"),
 *   which takes InstSyncMode from software and InstSyncMax from the reset.
 *   This testbench walks exactly that path, deliberately WITHOUT writing
 *   InstSyncMax (WRITE_MAX = 0).
 *
 *   Regime: equal-rate drain (ATB/PROC_CLK_HALF_NS = tip half period,
 *   CYCLES_PER_INSTR = 1) -- the KV260/MBV integration shape where all
 *   encoder clocks hang off one PL clock and the drain does NOT outpace the
 *   retire side. That is the only regime in which the eTIP path can overflow
 *   naturally (see tests/overflow/02_natural_overflow), i.e. the only regime
 *   in which a too-tight cadence is visible as trace LOSS rather than as
 *   mere bandwidth.
 *
 *   Workload: a compact scheduler-shaped loop, 40 retires per iteration with
 *   6 control-flow events (15 % CF density -- the measured band of real
 *   programs), held inside [0x1000, 0x1320] so the dense NexRv PCInfo stays
 *   small. Every PC keeps ONE role across all iterations (a NexRv PCInfo
 *   requirement).
 *
 *   Legs (scripts/cli_synccadence_test.sh):
 *     sync_default_tb  WRITE_MAX=0 -> the RESET cadence, as shipped.
 *                      Gate: ZERO Nexus Error messages (TCODE 8) and a
 *                      lossless NexRv decode over the whole run.
 *     sync_cadence_sweep_tb
 *                      WRITE_MAX=1, period from +SYNCMAX=<n> (default 0).
 *                      +SYNCMAX=0 is the NEGATIVE counter-proof: the
 *                      minimum period must still reproduce the stress case
 *                      (Nexus Error messages present). The other values are
 *                      the bandwidth sweep behind the choice of the reset
 *                      value.
 *
 *   The two tops share this core, so both legs retire the SAME instruction
 *   sequence and their byte counts are directly comparable.
 */

module sync_cadence_core #(
	// 0 = leave trTeControl.InstSyncMax at its RESET value (the product
	//     default under test). 1 = program it explicitly from +SYNCMAX.
	parameter bit    WRITE_MAX = 1'b0,
	parameter string PFX       = "sync_default_tb"
);

	// ---- Finite sink -----------------------------------------------------
	// The env's ATB sink is always-ready, i.e. infinitely fast, and under an
	// infinite sink NO cadence can ever announce an overflow: the encoder
	// simply emits more bytes. M4 measured its 221-359 Error messages on a
	// board, i.e. against a sink of finite bandwidth, so an infinite sink
	// cannot answer the product question at all.
	//
	// SINK_DIV throttles the sink to one accepted beat per SINK_DIV ATB
	// cycles (+SINKDIV=<n>, 0 = the env default of always-ready), making the
	// two legs a ONE-FACTOR experiment: same workload, same sink, only the
	// sync period differs.
	//
	// The default 10 = 4 B / 10 / 10 ns = 40 MB/s is CHOSEN FROM THE
	// MEASUREMENT, not guessed. Against an unthrottled sink this workload
	// demands 20.0 MB/s with the periodic sync effectively off and 48.9 MB/s
	// at the minimum period (P0-02 sweep, 100 010 retires): 40 MB/s therefore
	// leaves the shipped cadence a factor 2 of headroom -- its byte stream is
	// bit-for-bit the same as against an infinite sink -- while the minimum
	// period is a factor 1.2 short and loses trace. Measured threshold at
	// this sink: lossless from InstSyncMax = 2 (period 64) upwards.
	localparam int SINK_DIV_DEFAULT = 10;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (5),      // == tip half period: equal-rate drain
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ({PFX, ".atb.bin"}),
		.TIP_DUMP_TXT_PATH   ({PFX, ".tip.txt"}),
		.NEXRV_INFO_PATH     ({PFX, ".nexrv.info"}),
		.EXPECTED_PCS_PATH   ({PFX, ".expected.pcs"})
	) env ();

	// ---- Program image (compact: 0x1000 .. 0x1320) ----------------------
	localparam logic [31:0] WORK_PC  = 32'h0000_1000;  // loop top
	localparam logic [31:0] SKIP_PC  = 32'h0000_1060;  // taken-branch target
	localparam logic [31:0] LEAF_PC  = 32'h0000_1200;  // leaf function
	localparam logic [31:0] DISP_PC  = 32'h0000_1300;  // indirect dispatch target

	localparam logic [3:0] ITR_SYNC_INSTRUCTIONS = 4'd6;
	localparam logic [1:0] CFG_ONCE              = 2'd1;

	// Iterations of the 40-retire loop. Plusarg-overridable so the same
	// build serves the short smoke run and the sustained run.
	localparam int N_ITER_DEFAULT = 2500;   // -> 100 000 retires

	int          n_iter   = N_ITER_DEFAULT;
	int          sync_max = 0;              // only used when WRITE_MAX
	int          sink_div = SINK_DIV_DEFAULT;
	logic [31:0] ctrl_rb;

	// Sink throttle: hold the ATB stall high for (sink_div - 1) of every
	// sink_div cycles. Released for the end-of-scenario drain so the tail
	// always flushes (an overflow, if any, has been announced long before).
	int  sink_cnt   = 0;
	bit  sink_gate  = 1'b1;   // 0 = throttle off (drain / SINK_DIV < 2)

	always_ff @(posedge env.atb_atclk) begin : sink_throttle
		automatic int nxt = (sink_div >= 2)
			? ((sink_cnt >= sink_div - 1) ? 0 : sink_cnt + 1) : 0;
		sink_cnt            <= nxt;
		env.atb_force_stall <= sink_gate && (sink_div >= 2) && (nxt != 0);
	end

	// One iteration: 40 retires, 6 control-flow events.
	//   10 linear | BNT | 4 linear | CALL -> 6 linear + RET | 4 linear
	//   | BT -> 5 linear | UJ -> 5 linear | BT (loop back)
	// `last` drains the loop by NOT taking the loop-back branch (same PC,
	// same static target -- a conditional branch has exactly one).
	task automatic iteration(input bit last);
		env.cpu.run(40);                                   // 10 linear
		env.cpu.branch_not_taken(.target(SKIP_PC));        // BD, falls through
		env.cpu.run(16);                                   // 4 linear
		env.cpu.call_to(LEAF_PC);                          // CD
		env.cpu.run(24);                                   // 6 linear (leaf body)
		env.cpu.ret();                                     // RI
		env.cpu.run(16);                                   // 4 linear
		env.cpu.branch_taken(SKIP_PC);                     // BD taken
		env.cpu.run(20);                                   // 5 linear
		env.cpu.uninferable_jump(DISP_PC);                 // JI
		env.cpu.run(20);                                   // 5 linear
		if (last) env.cpu.branch_not_taken(.target(WORK_PC));
		else      env.cpu.branch_taken(WORK_PC);
	endtask

	initial begin
		void'($value$plusargs("NITER=%d",   n_iter));
		void'($value$plusargs("SYNCMAX=%d", sync_max));
		void'($value$plusargs("SINKDIV=%d", sink_div));

		$display("[%s] %0t: waiting for reset release", PFX, $time);
		env.wait_for_reset_release();
		env.csr.clear();

		// ---- The natural programming path -------------------------------
		// Sync fields are write-locked while Enable=1: program first.
		env.csr.Set_te_trTsControl_Active      (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_INSTRUCTIONS);
		env.csr.Set_te_trTeControl_SendConfig   (CFG_ONCE);
		if (WRITE_MAX)
			env.csr.Set_te_trTeControl_InstSyncMax (4'(sync_max));
		// else: InstSyncMax stays at its RESET value -- THE POINT OF THIS TEST.

		// Read the control word back and print it: the cadence actually
		// flown is evidence, not an assumption (the reset value reaches the
		// stream through the config message, VendorConfig PARAM1[10:7]).
		env.csr.Read_te_trTeControl(ctrl_rb);
		$display("[%s] trTeControl = 0x%08x | InstSyncMode = %0d | InstSyncMax = %0d -> sync every %0d instructions%s",
			PFX, ctrl_rb, ctrl_rb[19:16], ctrl_rb[23:20],
			1 << (ctrl_rb[23:20] + 4),
			WRITE_MAX ? " (PROGRAMMED)" : " (RESET VALUE)");

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		$display("[%s] sink: 1 accepted beat per %0d ATB cycles (%0d MB/s at 4 B / 10 ns)%s",
			PFX, (sink_div >= 2) ? sink_div : 1,
			(sink_div >= 2) ? (400 / sink_div) : 400,
			(sink_div >= 2) ? "" : " -- env default, always ready");
		$display("[%s] %0t: starting %0d iterations (%0d retires)",
			PFX, $time, n_iter, 40 * n_iter);

		env.cpu.enter(.start_pc(WORK_PC));
		for (int k = 0; k < n_iter; k++)
			iteration(.last(k == n_iter - 1));

		// CF-quiet tail so trace-off lands after a linear instruction.
		env.cpu.run(32);
		env.cpu.exit_trace();

		// ---- Trace-off drain --------------------------------------------
		// Sink back to full rate: the tail must flush in every leg, and an
		// overflow (if the cadence provoked one) was announced long before.
		sink_gate = 1'b0;
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.cpu.idle(4000);
		env.atb_force_flush = 1'b0;
		env.cpu.idle(500);
		env.csr.Set_te_trTeControl_Active      (1'b0);
		env.cpu.idle(1000);

		if (env.cpu.event_count() == 0) $error("[%s] cpu_model event log empty", PFX);
		if (env.atb_bytes_seen == 0)    $error("[%s] no ATB bytes observed", PFX);
		$display("[%s] retired %0d instructions, observed %0d ATB transfers",
			PFX, env.cpu.event_count(), env.atb_bytes_seen);
		$display("[%s] PASS (sim); decode gates in scripts/cli_synccadence_test.sh", PFX);
		$finish;
	end

	// Hard timeout. The sustained run is ~100 000 retires at 10 ns/retire
	// plus drain, so the bound is generous but finite.
	initial begin
		#400ms;
		$error("[%s] TIMEOUT - test exceeded 400 ms sim time", PFX);
		$finish;
	end

endmodule : sync_cadence_core

`default_nettype wire
