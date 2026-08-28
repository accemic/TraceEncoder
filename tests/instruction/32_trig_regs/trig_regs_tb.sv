// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    TCI trigger configuration registers (P7 / G9) -- 0x050 / 0x054 / 0x058.
 *
 * @details
 *   CTTE owns exactly ONE external trigger input: the generic tip.trigger
 *   event port. trTeTrigExtInControl.ExtInAction0 selects what a pulse on it
 *   does (TCI Table 20); every other trigger field is the read-only 0 the
 *   spec prescribes for a trigger that does not exist.
 *
 *   One workload, six CSR legs (identical cpu_model stimulus except for the
 *   two on/off legs, which deliberately change what is traced):
 *
 *     off    : reset defaults -- Action0 = 0, InstTrigEnable = 0. The trigger
 *              pulse does nothing at all (baseline).
 *     legacy : InstTrigEnable = 1, Action0 = 0 -- the HISTORICAL path: the
 *              pulse upgrades the next retire to SYNC = 6. This leg is the
 *              regression guard for decision E-P7-2 ("InstTrigEnable
 *              behaviour unchanged").
 *     notify : Action0 = 4, InstTrigEnable = 0 -- the NEW register-driven
 *              route to the very same marker. TCI does not gate the notify
 *              action on InstTrigEnable, so this must work with the legacy
 *              enable OFF.
 *     both   : Action0 = 4 AND InstTrigEnable = 1 -- de-duplication: exactly
 *              ONE marker per pulse, not two (both sources feed the same
 *              one-shot latch).
 *     off_act: Action0 = 3 (trace-off) + InstTrigEnable = 1 -- the pulse
 *              stops instruction tracing; the tail of the workload is not
 *              traced and the stream carries the trace-off correlation.
 *     on_act : Action0 = 2 (trace-on) + InstTrigEnable = 1, started with
 *              InstTracing = 0 -- the pulse STARTS instruction tracing; only
 *              the tail of the workload is traced.
 *
 *   The WARL / "trigger does not exist" probes run IN SIM ($fatal on
 *   mismatch, every leg): illegal action values legalize to 0, the action
 *   fields of inputs #1..7 stay 0, and the debug-trigger / trigger-output
 *   registers ignore writes entirely.
 *
 *   +TRIGREGS_RO switches the expectation to the COMPILED-OUT build
 *   (CT_EN_TRIG_REGS = 0): there even the three legal actions must read
 *   back 0, and the notify leg -- same stimulus as the ON build, where it
 *   produces exactly one SYNC = 6 marker -- must produce none at all.
 *   Driven by scripts/cli_trigregs_test.sh ro in a switched-off worktree.
 *
 *   Marker counting and PC losslessness are checked offline by
 *   scripts/cli_trigregs_test.sh. Timestamps OFF, drain via env.cpu.idle().
 */

module trig_regs_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("trig_regs_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("trig_regs_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("trig_regs_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("trig_regs_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd6; // 2^10 cycles: sparse periodic syncs

	localparam logic [31:0] MAIN_PC = 32'h0000_6000;

	localparam logic [3:0] ACT_NONE   = 4'd0;
	localparam logic [3:0] ACT_ON     = 4'd2;
	localparam logic [3:0] ACT_OFF    = 4'd3;
	localparam logic [3:0] ACT_NOTIFY = 4'd4;
	localparam logic [3:0] LEGAL_ACTIONS [3] = '{ACT_ON, ACT_OFF, ACT_NOTIFY};

	logic [31:0] rd;

	// ------------------------------------------------------------------
	// Register probes. Every one of them is a NEGATIVE test: it writes a
	// value the hardware must refuse and checks the read-back.
	// ------------------------------------------------------------------
	task automatic probe_warl_and_nonexistent();
		// (a) reserved action 1 -> legalized to 0
		env.csr.Set_te_trTeTrigExtInControl_ExtInAction0(4'd1);
		env.csr.Read_te_trTeTrigExtInControl(rd);
		if (rd[3:0] !== ACT_NONE)
			$fatal(1, "[trig_regs_tb] WARL: action 1 read back as %0d, expected 0", rd[3:0]);

		// (b) reserved actions 5..15 -> legalized to 0
		for (int a = 5; a <= 15; a++) begin
			env.csr.Set_te_trTeTrigExtInControl_ExtInAction0(4'(a));
			env.csr.Read_te_trTeTrigExtInControl(rd);
			if (rd[3:0] !== ACT_NONE)
				$fatal(1, "[trig_regs_tb] WARL: action %0d read back as %0d, expected 0", a, rd[3:0]);
		end

		// (c) external trigger inputs #1..7 do not exist -> action fields
		//     stay 0 no matter what is written (TCI Table 20).
		env.csr.Write_te_trTeTrigExtInControl(32'hFFFF_FFF0);
		env.csr.Read_te_trTeTrigExtInControl(rd);
		if (rd[31:4] !== 28'd0)
			$fatal(1, "[trig_regs_tb] ExtInActionN read back as 0x%07x, expected 0", rd[31:4]);

		// (d) the trigger OUTPUT register does not exist -> all bits fixed
		//     at 0 (TCI Table 21).
		env.csr.Write_te_trTeTrigExtOutControl(32'hFFFF_FFFF);
		env.csr.Read_te_trTeTrigExtOutControl(rd);
		if (rd !== 32'd0)
			$fatal(1, "[trig_regs_tb] trTeTrigExtOutControl read back as 0x%08x, expected 0", rd);

		// (e) no debug-trigger interface -> vendor setup field fixed at 0
		//     (TCI Table 19).
		env.csr.Write_te_trTeTrigDbgControl(32'hFFFF_FFFF);
		env.csr.Read_te_trTeTrigDbgControl(rd);
		if (rd !== 32'd0)
			$fatal(1, "[trig_regs_tb] trTeTrigDbgControl read back as 0x%08x, expected 0", rd);

		// (f) compiled-out profile only (+TRIGREGS_RO, run by the
		//     CT_EN_TRIG_REGS = 0 build): even the three LEGAL actions are
		//     refused. Two independent mechanisms must agree -- the RDL
		//     profile turns ExtInAction0 into a read-only constant 0
		//     (CT_PROFILE_NO_TRIG_REGS) and the WARL wrapper legalizes
		//     every write to 0 -- and the CSR must still answer, not fault.
		if ($test$plusargs("TRIGREGS_RO")) begin
			foreach (LEGAL_ACTIONS[i]) begin
				env.csr.Set_te_trTeTrigExtInControl_ExtInAction0(LEGAL_ACTIONS[i]);
				env.csr.Read_te_trTeTrigExtInControl(rd);
				if (rd !== 32'd0)
					$fatal(1, "[trig_regs_tb] compiled out: legal action %0d stuck (read 0x%08x)",
						LEGAL_ACTIONS[i], rd);
			end
			$display("[trig_regs_tb] compiled-out RO probes: OK");
		end

		// Leave the register at its reset value; the leg below programs it.
		env.csr.Set_te_trTeTrigExtInControl_ExtInAction0(ACT_NONE);
		env.csr.Read_te_trTeTrigExtInControl(rd);
		if (rd !== 32'd0)
			$fatal(1, "[trig_regs_tb] trTeTrigExtInControl not clean after probes: 0x%08x", rd);
		$display("[trig_regs_tb] WARL / non-existent-trigger probes: OK");
	endtask

	// A programmed action must survive the read-back -- otherwise the leg
	// below would silently test the reset value.
	// In the compiled-out build (+TRIGREGS_RO) the SAME programming must be
	// refused -- the leg then runs with the register at 0, which is what
	// makes "no marker in that build" a statement about the feature and not
	// about the stimulus.
	task automatic set_action_checked(input logic [3:0] act);
		logic [3:0] want;
		want = $test$plusargs("TRIGREGS_RO") ? ACT_NONE : act;
		env.csr.Set_te_trTeTrigExtInControl_ExtInAction0(act);
		env.csr.Read_te_trTeTrigExtInControl(rd);
		if (rd[3:0] !== want)
			$fatal(1, "[trig_regs_tb] ExtInAction0 = %0d read back as %0d, expected %0d",
				act, rd[3:0], want);
		$display("[trig_regs_tb] %0t: ExtInAction0 = %0d (read back %0d)", $time, act, rd[3:0]);
	endtask

	initial begin
		bit leg_on_act;
		$display("[trig_regs_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[trig_regs_tb] %0t: reset released", $time);

		leg_on_act = $test$plusargs("ONACTLEG");

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);

		// Negative probes first: they run while Enable = 0, which is also
		// the only window in which ExtInAction0 is writable (swwel).
		probe_warl_and_nonexistent();

		if ($test$plusargs("LEGACYLEG")) begin
			env.csr.Set_te_trTeControl_InstTrigEnable(1'b1);
			$display("[trig_regs_tb] %0t: legacy leg -- InstTrigEnable=1, Action0=0", $time);
		end
		if ($test$plusargs("NOTIFYLEG")) begin
			set_action_checked(ACT_NOTIFY);
			$display("[trig_regs_tb] %0t: notify leg -- InstTrigEnable=0, Action0=4", $time);
		end
		if ($test$plusargs("BOTHLEG")) begin
			env.csr.Set_te_trTeControl_InstTrigEnable(1'b1);
			set_action_checked(ACT_NOTIFY);
			$display("[trig_regs_tb] %0t: both leg -- InstTrigEnable=1, Action0=4", $time);
		end
		if ($test$plusargs("OFFACTLEG")) begin
			env.csr.Set_te_trTeControl_InstTrigEnable(1'b1);
			set_action_checked(ACT_OFF);
			$display("[trig_regs_tb] %0t: trace-off leg -- Action0=3", $time);
		end
		if (leg_on_act) begin
			env.csr.Set_te_trTeControl_InstTrigEnable(1'b1);
			set_action_checked(ACT_ON);
			$display("[trig_regs_tb] %0t: trace-on leg -- Action0=2", $time);
		end

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		// The trace-on leg starts with instruction tracing OFF -- the
		// trigger pulse is what turns it on.
		env.csr.Set_te_trTeControl_InstTracing  (leg_on_act ? 1'b0 : 1'b1);
		env.cpu.set_inst_traced                 (leg_on_act ? 1'b0 : 1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[trig_regs_tb] %0t: scenario start", $time);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);
		env.cpu.branch_taken(.target(MAIN_PC + 32'h100));
		env.cpu.run(64);

		// ---- the trigger pulse: the single event every leg reacts to ----
		env.cpu.trigger_pulse();
		if (leg_on_act) begin
			// Trace-on: the CSR side follows one cycle later, so give the
			// hwset path time before the model starts expecting PCs again.
			env.cpu.idle(20);
			env.cpu.set_inst_traced(1'b1);
		end
		env.cpu.run(16);
		if ($test$plusargs("OFFACTLEG")) begin
			// Trace-off: the CSR clear needs the same settling time before
			// the model stops expecting PCs.
			env.cpu.idle(20);
			env.cpu.set_inst_traced(1'b0);
		end

		env.cpu.branch_taken(.target(MAIN_PC + 32'h200));
		env.cpu.run(64);
		env.cpu.branch_not_taken();
		env.cpu.run(16);
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

		if (env.cpu.event_count() == 0)
			$error("[trig_regs_tb] cpu_model event log empty");
		else
			$display("[trig_regs_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[trig_regs_tb] no ATB bytes observed");
		else
			$display("[trig_regs_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[trig_regs_tb] PASS (sim); decode verified by scripts/cli_trigregs_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[trig_regs_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : trig_regs_tb

`default_nettype wire
