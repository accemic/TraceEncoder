// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Device ID (TCODE 1) + Watchpoint (TCODE 15) status messages -- P4.
 *
 * @details
 *   One workload, seven CSR legs -- identical cpu_model stimulus, identical
 *   expected PCs (the two message types are PC-neutral: they carry no ICNT
 *   and move no address reference):
 *
 *     off    : reset defaults (SendDeviceId = DID_NONE, trWpMask.WEM = 0).
 *              NO TCODE 1 and NO TCODE 15 anywhere -- the runtime-reset
 *              byte-neutrality of both features, on a build that HAS them.
 *     did    : SendDeviceId = DID_ONCE -> exactly ONE TCODE 1, and it is
 *              MSG #0, i.e. before the config message (TCODE 58) and
 *              before the first synchronizing message (contract DO-1).
 *              The decoded ID must equal the DEVICE_ID elaboration
 *              parameter below.
 *     didoff : negative control for the WARL path -- SendDeviceId is
 *              written with the ILLEGAL encoding 2. The wrapper legalizes
 *              it to DID_NONE, the field reads back 0 (checked here) and
 *              no TCODE 1 is emitted (checked by the cli script).
 *     wp     : WEM = 0xFFFF -> every watchpoint command reports; the three
 *              commands below produce WPHIT 0x1, 0x2 and 0x8001.
 *     wpmask : negative control for the mask -- WEM = 0x0002 lets only the
 *              second command through (0x1 & 0x2 = 0, 0x8001 & 0x2 = 0),
 *              so exactly ONE TCODE 15 with WPHIT 0x2 survives.
 *     both   : DID_ONCE + WEM = 0xFFFF + Context = 1. Device ID, Config,
 *              the sync CF and an Ownership message all appear in the
 *              stream, and the watchpoint messages ride the same stream.
 *              The eTIP SLOT pressure of that leg is MEASURED, not assumed:
 *              the composer prints "ONE beat carries Device ID (slot 0) AND
 *              Config (slot 1), beat uses 2 of N slots" plus the per-run
 *              watermark "eTIP max slots per beat". The sync CF and the
 *              Ownership message land in LATER beats -- the earlier claim
 *              that one trace-start beat carries all four was a confusion
 *              of stream order with beat identity (P4 audit finding A-2).
 *     src    : like `both`, but with InhibitSrc = 0 (SrcBits = 4): both new
 *              messages must decode with the optional SRC field in front of
 *              their payload -- the field-index discipline of the two new
 *              formatter arms.
 *     didtwice: DID_ONCE with a trace pause in the middle of the workload
 *              (between two idle windows, so no retire is lost) -- the
 *              SECOND trace-on edge must emit the Device ID again. DID_ONCE
 *              is "once per trace-on edge", not "once per session".
 *     wpdaq  : like `wp`, but the SECOND command is a DAQ command
 *              (ACT_CAP_ST_DAQ_DIRECT_DATA) -- two watchpoint messages AND
 *              one Data Acquisition message in ONE run. The only leg that
 *              exercises the composer's a_p4_wp_daq_exclusive property with
 *              a true antecedent AND a design that really raises DAQ slots;
 *              without it the "watchpoint shares the DAQ slot" cost
 *              argument would rest on a vacuously true assertion.
 *     wpaxis : like `wp`, but the THIRD watchpoint command is issued on
 *              ACT_CAP_ST_SINK_AXIS_NEXUS instead of ..._SINK_NEXUS. The
 *              sink selects the ACT payload's destination, NOT the Nexus
 *              message -- so the emitted stream must be byte-identical to
 *              the `wp` leg (checked in the cli script).
 *
 *   A watchpoint command must NOT additionally produce a Data Acquisition
 *   message (TCODE 7); the cli script checks that separately.
 *
 *   Timestamps stay at their reset default (ON) so both new messages carry
 *   a delta TSTAMP -- that is what the decoder must accumulate.
 *
 *   Gates in scripts/cli_status_test.sh (NexRv is the reference decoder).
 */

module status_msgs_tb;

	import cpu_model_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import ct_cs_cpuif_wb_pkg::*;

	// Device ID of this encoder instance (elaboration parameter of
	// ct_encoder, layout per IEEE-ISTO 5001 Table B-5). Test value only --
	// recognizable in the decoded stream, LSB set like a JTAG-IDCODE-shaped
	// identifier.
	localparam logic [31:0] DEVICE_ID = 32'hACCE_5001;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (2),
		.ATB_DUMP_PATH       ("status_msgs_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("status_msgs_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("status_msgs_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("status_msgs_tb.expected.pcs"),
		.DEVICE_ID           (DEVICE_ID)
	) env ();

	localparam logic [3:0] ITR_SYNC_CLK_CYCLES = 4'd2;
	localparam logic [3:0] INST_SYNC_MAX       = 4'd4; // sparse periodic syncs

	localparam logic [1:0] SINK_NEXUS      = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS;
	localparam logic [1:0] SINK_AXIS_NEXUS = ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS;
	localparam logic [5:0] CMD_WATCHPOINT = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_WATCHPOINT;
	localparam logic [5:0] CMD_DAQ_DIRECT = ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA;

	localparam logic [31:0] MAIN_PC = 32'h0000_7000;

	initial begin
		logic [31:0] ctrl;

		$display("[status_msgs_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[status_msgs_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTeControl_InstSyncMode (ITR_SYNC_CLK_CYCLES);
		env.csr.Set_te_trTeControl_InstSyncMax  (INST_SYNC_MAX);
		// Timestamps RUNNING: free-running SYSTEM counter, prescale 0 (same
		// word as tests/data/04_data_sync; trTsControl is swwel-gated by
		// Enable, so it goes first). Both new messages are
		// NON-synchronizing, so they carry a TSTAMP DELTA the decoder has to
		// accumulate -- with a standing-still counter every delta would be 0
		// and the accumulation path would be vacuously "correct". That is
		// exactly the defect class the decoder's Ownership arm carried until
		// 2026-08-04.
		env.csr.Write_te_trTsControl (32'h3F00_8023);

		// Both new fields are Enable-locked (swwel), so they are programmed
		// here, before trTeControl.Enable goes high.
		if ($test$plusargs("DIDLEG") || $test$plusargs("BOTHLEG") || $test$plusargs("SRCLEG")
		    || $test$plusargs("DIDTWICELEG")) begin
			env.csr.Set_te_trTeControl_SendDeviceId(2'd1);   // DID_ONCE
			$display("[status_msgs_tb] %0t: SendDeviceId=DID_ONCE", $time);
		end
		if ($test$plusargs("DIDOFFLEG")) begin
			// WARL negative control: 2 is not a legal encoding.
			env.csr.Set_te_trTeControl_SendDeviceId(2'd2);
			env.csr.Read_te_trTeControl(ctrl);
			if (ctrl[BITPOS_te_trTeControl_SendDeviceId_MSB:BITPOS_te_trTeControl_SendDeviceId_LSB] != 2'd0)
				$error("[status_msgs_tb] WARL: SendDeviceId read back %0d, expected DID_NONE",
					ctrl[BITPOS_te_trTeControl_SendDeviceId_MSB:BITPOS_te_trTeControl_SendDeviceId_LSB]);
			else
				$display("[status_msgs_tb] %0t: WARL OK -- illegal SendDeviceId=2 legalized to DID_NONE", $time);
		end
		if ($test$plusargs("WPLEG") || $test$plusargs("BOTHLEG") || $test$plusargs("SRCLEG")
		    || $test$plusargs("WPAXISLEG") || $test$plusargs("WPDAQLEG")) begin
			env.csr.Set_trWpMask_WEM(16'hFFFF);
			$display("[status_msgs_tb] %0t: trWpMask.WEM=0xFFFF", $time);
		end
		if ($test$plusargs("WPMASKLEG")) begin
			env.csr.Set_trWpMask_WEM(16'h0002);
			$display("[status_msgs_tb] %0t: trWpMask.WEM=0x0002 (mask negative control)", $time);
		end
		if ($test$plusargs("BOTHLEG") || $test$plusargs("SRCLEG")) begin
			env.csr.Set_te_trTeControl_Context(1'b1);
			$display("[status_msgs_tb] %0t: Context=1 (ownership adds a slot)", $time);
		end
		if ($test$plusargs("SRCLEG")) begin
			env.csr.Set_te_trTeInstFeatures_SrcBits(4'd4);
			env.csr.Set_te_trTeInstFeatures_SrcID  (12'd5);
			env.csr.Set_te_trTeControl_InhibitSrc  (1'b0);
			$display("[status_msgs_tb] %0t: InhibitSrc=0, SrcBits=4, SrcID=5", $time);
		end

		env.csr.Set_te_trTeControl_Enable       (1'b1);
		env.csr.Set_te_trTeControl_InstTracing  (1'b1);
		env.csr.Set_te_trTeControl_Active       (1'b1);
		env.cpu.idle(20);
		$display("[status_msgs_tb] %0t: scenario start", $time);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(16);

		// ---- watchpoint command 1: slot bit 0 --------------------------
		env.cpu.act_cap_cmd(.cmd(CMD_WATCHPOINT), .sink(SINK_NEXUS), .direct_data(24'h00_0001));
		env.cpu.run(12);
		env.cpu.branch_taken(.target(MAIN_PC + 32'h100));
		env.cpu.run(12);

		// ---- watchpoint command 2: slot bit 1 --------------------------
		// wpdaq leg: the SAME command slot carries a DAQ command instead.
		// This is what makes the composer's a_p4_wp_daq_exclusive property
		// NON-vacuous: in every other leg the design produces no DAQ message
		// at all, so "no watchpoint and DAQ in one beat" holds trivially.
		// Here the run contains BOTH message kinds, which is the measured
		// side of the slot-sharing cost argument (CT_EN_WATCHPOINT_MSG does
		// not widen ETIP_PAR_MSG because the two arms are selected by the
		// same beat qualifier with mutually exclusive command codes).
		// Again a command SWAP, not an extra command -- the program, and
		// with it the expected PC list, must stay the same in every leg.
		env.cpu.act_cap_cmd(
			.cmd($test$plusargs("WPDAQLEG") ? CMD_DAQ_DIRECT : CMD_WATCHPOINT),
			.sink(SINK_NEXUS), .direct_data(24'h00_0002));
		env.cpu.run(12);
		env.cpu.branch_not_taken();
		env.cpu.run(24);

		// ---- didtwice leg: SECOND trace-on edge -------------------------
		// DID_ONCE fires on the RISING edge of effective instruction
		// tracing, not once per session -- documented behaviour that was
		// unverified until the P4 audit asked for it. The pause happens
		// between two idle windows, so NO retire is lost and the leg keeps
		// the same expected PC sequence as every other leg (the decoder
		// re-anchors on the TRACE_ENABLE sync after the correlation
		// message).
		if ($test$plusargs("DIDTWICELEG")) begin
			env.cpu.idle(40);
			env.csr.Set_te_trTeControl_InstTracing (1'b0);
			env.cpu.idle(120);
			env.csr.Set_te_trTeControl_InstTracing (1'b1);
			env.cpu.idle(40);
			$display("[status_msgs_tb] %0t: second trace-on edge (expects a second TCODE 1)", $time);
		end


		// ---- watchpoint command 3: slot bits 0 and 15 ------------------
		// wpaxis leg: the SAME command on the OTHER legal sink.
		// ACT_CAP_ST_SINK_AXIS_NEXUS ("AXIS to internal CPU, and Nexus
		// message") must produce the identical watchpoint message --
		// the composer arm accepts both sinks and nothing tested the second
		// one. Deliberately a sink SWAP, not an extra command: every leg of
		// this test must retire the SAME program (they share one
		// cpu_model stimulus, one expected-PC list and one .nexrv.info --
		// the last leg's pcinfo is what the end-of-script CTXP check
		// decodes with).
		env.cpu.act_cap_cmd(.cmd(CMD_WATCHPOINT),
			.sink($test$plusargs("WPAXISLEG") ? SINK_AXIS_NEXUS : SINK_NEXUS),
			.direct_data(24'h00_8001));
		env.cpu.run(12);
		env.cpu.uninferable_jump(.target(MAIN_PC + 32'h200));
		env.cpu.run(40);

		env.cpu.branch_not_taken();
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

		if (env.cpu.event_count() == 0)
			$error("[status_msgs_tb] cpu_model event log empty");
		else
			$display("[status_msgs_tb] cpu_model logged %0d events", env.cpu.event_count());
		if (env.atb_bytes_seen == 0)
			$error("[status_msgs_tb] no ATB bytes observed");
		else
			$display("[status_msgs_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[status_msgs_tb] PASS (sim); decode verified by scripts/cli_status_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[status_msgs_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : status_msgs_tb

`default_nettype wire
