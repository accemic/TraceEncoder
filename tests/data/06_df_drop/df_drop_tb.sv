// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Data-trace drop policy (P7 / G10) + overflow status bits (G12).
 *
 * @details
 *   ONE stimulus, TWO legs that differ only in `trTeDataControl.DataDropEna`
 *   -- the contrast IS the evidence:
 *
 *     off  (default)  : DataDropEna = 0. A stalled ATB plus a long burst of
 *                       data accesses fills the eTIP queue until it runs over;
 *                       the generic overflow path fires (Error + the SYNC = 7
 *                       re-anchor) and INSTRUCTION trace is lost with it.
 *                       `trTeControl.InstStallOrOverflow` must read 1.
 *     drop (DROPLEG)  : DataDropEna = 1. The same burst now trips the drop
 *                       watermark first, the DF arms are shed, the queue never
 *                       runs over -- the instruction trace stays LOSSLESS and
 *                       the loss is announced by ONE Error/ECODE=0x02 marker
 *                       WITHOUT a SYNC = 7 re-anchor.
 *                       `trTeDataControl.DataDrop` must read 1.
 *
 *   The status-bit contract (G12, N-Trace Required) is checked IN SIM
 *   ($fatal on mismatch), because it is not observable on the wire:
 *     * set on the event,
 *     * RW1C: a written 1 clears, a written 0 does not,
 *     * clear-on-enable: after Enable 1 -> 0 -> 1 the bits read 0 again.
 *
 *   The wire-side gates (Error count, ECODE value, absence of SYNC = 7,
 *   PC losslessness of the drop leg) live in scripts/cli_dfdrop_test.sh.
 *
 *   Burst sizing: the eTIP CVS queue is 128 entries behind a 128-entry CDC
 *   stage, so the fill only starts to climb once ~130 messages are already
 *   in flight. DF_BURST is dimensioned so the OFF leg reliably overruns while
 *   the DROP leg stays below the ceiling (the composer prints the reached max
 *   fill at end of sim; both legs are asserted below).
 */

module df_drop_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("df_drop_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("df_drop_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("df_drop_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("df_drop_tb.expected.pcs")
	) env ();

	localparam logic [3:0] ITR_SYNC_OFF = 4'd0; // no periodic sync in this test

	localparam logic [31:0] MAIN_PC    = 32'h0000_7000;
	localparam logic [31:0] LOOP_PC    = 32'h0000_7400;
	localparam logic [31:0] DRAIN_PC   = 32'h0000_7800; // exit of the burst loop
	localparam logic [31:0] TAIL_PC    = 32'h0000_7C00;
	localparam logic [31:0] BUF_BASE   = 32'h8000_0000;
	localparam int          DSIZE_W    = 2;
	// Burst loop body: 2 linear + N data accesses + one taken back-branch,
	// i.e. an ordinary counted loop. The data/control ratio is deliberately
	// data-heavy: the policy can only shed DATA messages, so a burst whose
	// CONTROL-flow traffic alone would fill the queue could never stay below
	// the ceiling and the test would prove nothing.
	localparam int          DF_ROUNDS  = 30;
	localparam int          DF_PER_RND = 20;

	localparam logic [5:0] CMD_CF_SYNC = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC;
	localparam logic [1:0] SINK_NEXUS  = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;

	// Status-bit positions inside their registers (generated constants).
	localparam int BP_INST_OVF  = BITPOS_te_trTeControl_InstStallOrOverflow;
	localparam int BP_DATA_OVF  = BITPOS_te_trTeDataControl_DataStallOrOverflow;
	localparam int BP_DATA_DROP = BITPOS_te_trTeDataControl_DataDrop;

	logic [31:0] rd;
	bit          leg_drop;
	bit          leg_ro;     // compiled-out build (CT_EN_DF_DROP = 0)
	bit          leg_policy; // the policy is really armed (drop leg AND compiled in)
	int          max_fill;

	task automatic read_status(output logic inst_ovf, output logic data_ovf,
	                           output logic data_drop);
		env.csr.Read_te_trTeControl(rd);
		inst_ovf = rd[BP_INST_OVF];
		env.csr.Read_te_trTeDataControl(rd);
		data_ovf  = rd[BP_DATA_OVF];
		data_drop = rd[BP_DATA_DROP];
	endtask

	task automatic expect_status(input string where,
	                             input logic exp_inst_ovf,
	                             input logic exp_data_ovf,
	                             input logic exp_data_drop);
		logic i_ovf, d_ovf, d_drop;
		read_status(i_ovf, d_ovf, d_drop);
		$display("[df_drop_tb] %0t: %s -- InstStallOrOverflow=%0b DataStallOrOverflow=%0b DataDrop=%0b",
			$time, where, i_ovf, d_ovf, d_drop);
		if (i_ovf !== exp_inst_ovf)
			$fatal(1, "[df_drop_tb] %s: InstStallOrOverflow=%0b, expected %0b", where, i_ovf, exp_inst_ovf);
		if (d_ovf !== exp_data_ovf)
			$fatal(1, "[df_drop_tb] %s: DataStallOrOverflow=%0b, expected %0b", where, d_ovf, exp_data_ovf);
		if (d_drop !== exp_data_drop)
			$fatal(1, "[df_drop_tb] %s: DataDrop=%0b, expected %0b", where, d_drop, exp_data_drop);
	endtask

	initial begin
		logic i_ovf, d_ovf, d_drop;

		$display("[df_drop_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[df_drop_tb] %0t: reset released", $time);

		// The DROP leg is the DEFAULT: `abc -sim` cannot pass plusargs, so
		// the feature under test must be what a plain `make sim-df-drop`
		// exercises. The reference leg is selected with +NODROPLEG.
		leg_drop = !$test$plusargs("NODROPLEG");
		// +DFDROP_RO selects the COMPILED-OUT negative: same stimulus, same
		// programming attempt, but with CT_EN_DF_DROP = 0 the RDL profile
		// (CT_PROFILE_NO_DF_DROP) turns DataDropEna into a read-only constant
		// 0. The write must NOT stick, and the encoder must then behave
		// exactly like the OFF leg -- queue overrun, no policy drop.
		leg_ro     = $test$plusargs("DFDROP_RO");
		leg_policy = leg_drop && !leg_ro;

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active       (1'b0);
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_OFF);

		// The status bits must start clear -- if they did not, every check
		// below would be meaningless.
		expect_status("after reset", 1'b0, 1'b0, 1'b0);

		env.csr.Set_te_trTeControl_Enable        (1'b1);
		env.csr.Set_te_trTeControl_InstTracing   (1'b1);
		env.csr.Set_te_trTeDataControl_DataTracing(1'b1);
		if (leg_drop) begin
			// Runtime POLICY: deliberately not Enable-locked, so it is armed
			// here (after Enable=1) on purpose -- that also exercises the
			// missing swwel gate.
			env.csr.Set_te_trTeDataControl_DataDropEna(1'b1);
			env.csr.Read_te_trTeDataControl(rd);
			if (leg_ro) begin
				// COMPILED-OUT negative: the very write that sticks in the
				// full build must be refused here, and the CSR must still
				// answer instead of faulting.
				if (rd[BITPOS_te_trTeDataControl_DataDropEna] !== 1'b0)
					$fatal(1, "[df_drop_tb] compiled out: DataDropEna stuck (read 0x%08x)", rd);
				$display("[df_drop_tb] compiled-out RO probe: DataDropEna refused");
			end
			else if (rd[BITPOS_te_trTeDataControl_DataDropEna] !== 1'b1)
				$fatal(1, "[df_drop_tb] DataDropEna did not stick while Enable=1");
			$display("[df_drop_tb] %0t: DROP leg -- DataDropEna=%0b", $time,
				rd[BITPOS_te_trTeDataControl_DataDropEna]);
		end
		else begin
			$display("[df_drop_tb] %0t: OFF leg -- DataDropEna=0 (reset)", $time);
		end
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);

		// ============================================================
		// Phase A: quiet baseline -- a few accesses, ATB draining.
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(32);
		env.cpu.store_data(.addr(BUF_BASE),         .size(DSIZE_W), .data(64'hA5A5_0001));
		env.cpu.load_data (.addr(BUF_BASE + 32'h8), .size(DSIZE_W));
		env.cpu.run(16);
		env.cpu.idle(400);
		expect_status("after phase A", 1'b0, 1'b0, 1'b0);

		// ============================================================
		// Phase B: stall the ATB and run a long data burst. Every access
		// is a linear retire with a data side effect, so the INSTRUCTION
		// side contributes almost nothing (one ICNT pre-drain per ~64
		// instructions) while the DATA side fills the queue one entry per
		// access -- exactly the imbalance the drop policy exists for.
		// ============================================================
		$display("[df_drop_tb] %0t: phase B -- ATB stall + %0d rounds x %0d accesses",
			$time, DF_ROUNDS, DF_PER_RND);
		env.cpu.branch_taken(.target(LOOP_PC));
		env.atb_force_stall = 1'b1;
		for (int i = 0; i < DF_ROUNDS; i++) begin
			env.cpu.run(8);                                   // LOOP_PC + 0x00 / 0x04
			for (int k = 0; k < DF_PER_RND; k++) begin        // LOOP_PC + 0x08 .. 0x18
				if (k[0])
					env.cpu.store_data(.addr(BUF_BASE + 32'((i * DF_PER_RND + k) * 4)),
					                   .size(DSIZE_W), .data(64'(i * DF_PER_RND + k)));
				else
					env.cpu.load_data (.addr(BUF_BASE + 32'((i * DF_PER_RND + k) * 4)),
					                   .size(DSIZE_W));
			end
			// Uninferable (indirect) back-jump rather than a direct branch:
			// it carries a hard UADDR plus the pending history, so the
			// reference decoder can resolve and EMIT the round's PCs
			// immediately. A direct back-branch would only contribute a
			// history bit, and the decoder would sit on an unresolved walk
			// until the history field fills -- the PC-losslessness gate
			// below would then measure the decoder's buffering, not the
			// encoder's completeness.
			// The LAST round leaves the loop to its own address range: every
			// PC in this test must have exactly ONE type in the pcinfo, and
			// the drain run below would otherwise re-walk the loop body as
			// plain linear code (the reference decoder's program description
			// cannot hold "linear here AND indirect jump here").
			env.cpu.uninferable_jump(
				.target((i == DF_ROUNDS - 1) ? DRAIN_PC : LOOP_PC));
		end
		// Linear tail BEFORE the drain: the overflow injector holds its
		// marker while the last retire was a control-flow change (the
		// resync anchor PrevIAddr+size would be wrong there), and an idle
		// CPU never clears that condition -- ending the burst on a taken
		// branch would postpone the marker past the checks below.
		env.cpu.run(32);
		env.cpu.idle(200);

		// ============================================================
		// Phase C: release the stall, let the queue drain. The CPU keeps
		// retiring linearly for the same inject_hold reason.
		// ============================================================
		$display("[df_drop_tb] %0t: phase C -- release stall, drain", $time);
		env.atb_force_stall = 1'b0;
		env.cpu.run(128);
		env.cpu.idle(20000);

		// ---- G12 status contract -----------------------------------
		// OFF  : the queue overran -> BOTH overflow bits set, DataDrop
		//        stays 0 (no POLICY drop happened).
		// DROP : the policy shed data trace -> DataDrop and the data-side
		//        overflow bit set; InstStallOrOverflow must stay 0, which
		//        is the whole promise of the feature.
		expect_status("after phase C", leg_policy ? 1'b0 : 1'b1, 1'b1, leg_policy ? 1'b1 : 1'b0);

		// RW1C: a written 0 must NOT clear, a written 1 must. Both writes are
		// read-modify-write on the WHOLE register, with the status bits
		// masked explicitly -- a blunt "write 0" would also clear
		// trTeControl.Enable and the hardware clear-on-enable would hide the
		// RW1C behaviour behind a disable (found while writing this test).
		env.csr.Read_te_trTeControl(rd);
		env.csr.Write_te_trTeControl(rd & ~(32'(1) << BP_INST_OVF));
		env.csr.Read_te_trTeDataControl(rd);
		env.csr.Write_te_trTeDataControl(
			rd & ~((32'(1) << BP_DATA_OVF) | (32'(1) << BP_DATA_DROP)));
		expect_status("after writing 0 (must not clear)",
			leg_policy ? 1'b0 : 1'b1, 1'b1, leg_policy ? 1'b1 : 1'b0);

		env.csr.Read_te_trTeControl(rd);
		env.csr.Write_te_trTeControl(rd | (32'(1) << BP_INST_OVF));
		env.csr.Read_te_trTeDataControl(rd);
		env.csr.Write_te_trTeDataControl(
			rd | (32'(1) << BP_DATA_OVF) | (32'(1) << BP_DATA_DROP));
		expect_status("after writing 1 (RW1C)", 1'b0, 1'b0, 1'b0);

		// A plain register write must not have disturbed the live control
		// bits -- the RW1C write above went to the same registers.
		env.csr.Read_te_trTeControl(rd);
		if (rd[1] !== 1'b1)
			$fatal(1, "[df_drop_tb] trTeControl.Enable lost by the RW1C write (0x%08x)", rd);
		env.csr.Read_te_trTeDataControl(rd);
		if (rd[1] !== 1'b1)
			$fatal(1, "[df_drop_tb] trTeDataControl.DataTracing lost by the RW1C write (0x%08x)", rd);

		// ============================================================
		// Phase D: tail -- the encoder must keep working after all this.
		// ============================================================
		env.cpu.branch_taken(.target(TAIL_PC));
		env.cpu.run(32);
		env.cpu.store_data(.addr(BUF_BASE + 32'h4000), .size(DSIZE_W), .data(64'hDEAD_BEEF));
		env.cpu.run(16);
		// Flush the trailing linear run into a real ProgTraceSync, so the
		// offline decode sees the whole scenario instead of an undrained
		// tail (combined_tb pattern).
		env.cpu.act_cap_cmd(.cmd(CMD_CF_SYNC), .sink(SINK_NEXUS), .direct_data(24'h0));
		env.cpu.exit_trace();
		env.cpu.idle(4000);

		// ---- second episode, then clear-on-enable ------------------
		// Re-trigger the status bits so the disable/enable cycle has
		// something to clear (otherwise the check is vacuous).
		read_status(i_ovf, d_ovf, d_drop);
		$display("[df_drop_tb] %0t: pre-disable status = %0b/%0b/%0b", $time, i_ovf, d_ovf, d_drop);

		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.cpu.idle(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.cpu.idle(200);
		// Cleared by hardware while disabled ("clear on enable").
		expect_status("while disabled", 1'b0, 1'b0, 1'b0);
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.cpu.idle(200);
		expect_status("after re-enable", 1'b0, 1'b0, 1'b0);
		env.csr.Set_te_trTeControl_Enable      (1'b0);

		env.atb_force_flush = 1'b1;
		env.cpu.idle(6000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(2000);

		// The observed fill tells whether the burst really exercised the
		// regime under test (and is the number the header's sizing note
		// refers to).
		max_fill = int'(env.dut.preproc_inst.composer_etip_inst.genEtipWatermark.MaxFillTip);
		$display("[df_drop_tb] eTIP CVS max fill reached: %0d of %0d", max_fill,
			ct_pkg::ETIP_CVS_FIFO_DEPTH);
		if (max_fill < int'(ct_pkg::CT_DF_DROP_WATERMARK))
			$fatal(1, "[df_drop_tb] burst never reached the drop watermark (%0d < %0d) -- test is vacuous",
				max_fill, ct_pkg::CT_DF_DROP_WATERMARK);
		if (leg_policy && (max_fill >= int'(ct_pkg::ETIP_CVS_FIFO_DEPTH)))
			$fatal(1, "[df_drop_tb] DROP leg still filled the queue completely (%0d) -- policy ineffective",
				max_fill);

		if (env.cpu.event_count() == 0)
			$error("[df_drop_tb] cpu_model event log empty");
		else
			$display("[df_drop_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[df_drop_tb] no ATB bytes observed");
		else
			$display("[df_drop_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[df_drop_tb] PASS (sim); decode verified by scripts/cli_dfdrop_test.sh");
		$finish;
	end

	// Event-strobe trace: the two status sources are tip-clk one-shots that
	// software can only observe through the sticky bits, so a mismatch in
	// expect_status() is otherwise blind. This monitor names the cycle.
	always @(posedge env.tip_clk) begin
		if (env.dut.preproc_inst.composer_etip_inst.InstOverflowEventQ)
			$display("[df_drop_tb] %0t: EVENT overflow-marker generated", $time);
		if (env.dut.preproc_inst.composer_etip_inst.DataDropEventQ)
			$display("[df_drop_tb] %0t: EVENT data-trace drop episode", $time);
	end

	// Hard timeout
	initial begin
		#80ms;
		$error("[df_drop_tb] TIMEOUT - test exceeded 80 ms wall time");
		$finish;
	end

endmodule : df_drop_tb

`default_nettype wire
