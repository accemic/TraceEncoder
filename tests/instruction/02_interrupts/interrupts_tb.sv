// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Instruction-trace test with interrupts, exceptions, and mret.
*
* @details
*   Walks the encoder through the scenarios called out in
*   `tests/instruction/README.md` for the 02_interrupts group:
*     - single interrupt with mret
*     - exception with mret
*     - nested interrupts (interrupt taken while a handler is running)
*     - back-to-back interrupts
*     - exception followed by an interrupt
*
*   Configuration: instruction trace ON, timestamps implicit. Data
*   trace, HSI, address filters all OFF — those are exercised in
*   their own groups.
*/

module interrupts_tb;

	import cpu_model_pkg::*;

	ctrace_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("interrupts_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("interrupts_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("interrupts_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("interrupts_tb.expected.pcs")
	) env ();

	// Memory map. PCs are laid out **contiguously** because NexRv's
	// PCInfo lookup wants the address space packed (no large gaps).
	// Each ISR invocation gets a distinct, non-overlapping slot so
	// every PC has exactly one pcinfo type.
	//
	//   0x1000 .. 0x103c : main (16 word slots, traps fired from
	//                      0x1010, 0x101c, 0x1028, 0x102c, 0x1030)
	//   0x1040 ..        : ISR_A   (3 L + R)
	//   0x1050 ..        : ISR_B   (2 L + R)
	//   0x1060 ..        : ISR_C   (1 L, then nested E, 1 L, R)
	//   0x1070 ..        : ISR_D   (2 L + R)
	//   0x1080 ..        : ISR_E   (1 L + R)
	//   0x1090 ..        : ISR_F   (1 L + R)
	//   0x10a0 ..        : ISR_G   (1 L + R) — async (iretire=0) entry
	//   0x10b0 ..        : ISR_H   (1 L + R) — async (iretire=0) entry
	localparam logic [31:0] MAIN_PC = 32'h0000_1000;
	localparam logic [31:0] ISR_A   = 32'h0000_1040;
	localparam logic [31:0] ISR_B   = 32'h0000_1050;
	localparam logic [31:0] ISR_C   = 32'h0000_1060;
	localparam logic [31:0] ISR_D   = 32'h0000_1070;
	localparam logic [31:0] ISR_E   = 32'h0000_1080;
	localparam logic [31:0] ISR_F   = 32'h0000_1090;
	localparam logic [31:0] ISR_G   = 32'h0000_10a0;
	localparam logic [31:0] ISR_H   = 32'h0000_10b0;

	initial begin
		$display("[interrupts_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		$display("[interrupts_tb] %0t: reset released", $time);

		env.csr.clear();
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.wait_cycles(20);
		$display("[interrupts_tb] %0t: starting scenario", $time);

		// ============================================================
		// Scenario
		//
		// Each interrupt/exception trap event uses a fresh handler
		// base address to keep every PC's pcinfo type unique.
		// ============================================================
		env.cpu.enter(.start_pc(MAIN_PC));

		// --- 1) plain run, single timer interrupt, mret -------------
		env.cpu.run(16);                                              // 0x1000..0x100c (4 L)
		env.cpu.interrupt(.cause(7), .handler(ISR_A));                // E @0x1010, resumes at 0x1014
		env.cpu.run(12);                                              // ISR_A body: 0x9000..0x9008 (3 L)
		env.cpu.mret();                                               // R @0x900c -> resume at 0x1014

		// --- 2) more linear, then a second interrupt --------------
		//   (a dedicated synchronous-exception test belongs in its
		//    own scenario; the NexRv decoder treats EXCEPTION_TRAP
		//    messages differently from INTERRUPT and would emit the
		//    trap PC several times here, which is a separate concern.)
		env.cpu.run(8);                                               // 0x1014, 0x1018 (2 L)
		env.cpu.interrupt(.cause(11), .handler(ISR_B));               // E @0x101c
		env.cpu.run(8);                                               // ISR_B body: 0x1050, 0x1054 (2 L)
		env.cpu.mret();                                               // R @0x1058 -> resume at 0x1020

		// --- 3) nested: ISR_C interrupted by ISR_D ---------------
		env.cpu.run(8);                                               // 0x1020, 0x1024 (2 L)
		env.cpu.interrupt(.cause(7), .handler(ISR_C));                // outer trap @0x1028
		env.cpu.run(4);                                               // ISR_C: 0xb000 (1 L)
		env.cpu.interrupt(.cause(11), .handler(ISR_D));               // inner trap @0xb004
		env.cpu.run(8);                                               // ISR_D body: 0xc000, 0xc004 (2 L)
		env.cpu.mret();                                               // R @0xc008 -> back inside ISR_C
		env.cpu.run(4);                                               // 0xb008 (1 L)
		env.cpu.mret();                                               // R @0xb00c -> back to main

		// --- 4) back-to-back interrupts ----------------------------
		env.cpu.interrupt(.cause(7), .handler(ISR_E));                // E @0x102c
		env.cpu.run(4);                                               // ISR_E: 0xd000 (1 L)
		env.cpu.mret();                                               // R @0xd004 -> back to 0x1030
		env.cpu.interrupt(.cause(11), .handler(ISR_F));               // E @0x1030
		env.cpu.run(4);                                               // ISR_F: 0xe000 (1 L)
		env.cpu.mret();                                               // R @0xe004 -> back to 0x1034

		// --- 5) async-marker trap (iretire=0 + itype=INTERRUPT) ---
		//   Spec-conformant shape: the trap fires BETWEEN instructions,
		//   so the cur_pc instruction does NOT retire this beat. The
		//   encoder must still emit an IndirectBranchHistory with
		//   BTYPE=INTERRUPT, ICNT exclusive of the trap pc, and
		//   UADDR=handler. After mret, execution resumes AT cur_pc
		//   (re-runs the not-yet-executed instruction). This is the
		//   shape the EMSA5 actually drives on real hardware; the
		//   default `interrupt()` (iretire=1) shape models the
		//   co-reported alternative.
		env.cpu.run(8);                                               // 0x1034, 0x1038 (2 L)
		env.cpu.interrupt(.cause(7),  .handler(ISR_G), .async(1));    // async @0x103c — pc does not retire here
		env.cpu.run(4);                                               // ISR_G: 0x10a0 (1 L)
		env.cpu.mret();                                               // R @0x10a4 -> resume AT 0x103c (re-run)
		env.cpu.run(4);                                               // 0x103c retires (was deferred by the async trap)

		// --- 6) async trap immediately after another CF (no main-path retire between) ---
		//   Tests the pending_cf_next_iaddr carry-over case in the
		//   composer: the previous CF (mret here) sets
		//   pending_cf_next_iaddr; the async trap arrives next with
		//   iretire=0 and tip.iaddr undefined. The composer must
		//   capture next_iaddr from a *later* iretire=1 beat, not from
		//   the async-marker beat. (If it captures from the marker,
		//   the previous CF's next_iaddr ends up undefined.)
		env.cpu.interrupt(.cause(11), .handler(ISR_H), .async(1));    // async @0x1040 — back-to-back with prior mret
		env.cpu.run(4);                                               // ISR_H: 0x10b0 (1 L)
		env.cpu.mret();                                               // R @0x10b4 -> resume AT 0x1040 (re-run)
		env.cpu.run(4);                                               // 0x1040 retires

		// Final linear to give the encoder a CF-quiet tail
		env.cpu.run(8);                                               // 0x1044, 0x1048 (2 L)
		env.cpu.exit_trace();

		// ---- Trace-off ----
		// Quiesce first so the trace tail drains through the (pipeline-delayed)
		// composer while instruction tracing is still effectively on -- the
		// InstTracing gate acts on the undelayed control signal, so an
		// in-flight instruction at the disable edge would otherwise be
		// mis-gated. Disabling instruction tracing then emits a Program Trace
		// Correlation Message (EVCODE=Program Trace Disabled) that flushes the
		// residual ICNT/HIST, so the offline decode resolves the final
		// instructions. Enable=0 then only flushes queued trace data;
		// atb_force_flush pushes the last ATB bytes to the sink.
		env.wait_cycles(50);
		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.wait_cycles(200);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.atb_force_flush = 1'b1;
		env.wait_cycles(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.wait_cycles(10000);

		// ---- Result placeholder check ----
		if (env.cpu.event_count() == 0) begin
			$error("[interrupts_tb] cpu_model event log empty");
		end else begin
			$display("[interrupts_tb] cpu_model logged %0d events", env.cpu.event_count());
		end
		if (env.atb_bytes_seen == 0) begin
			$error("[interrupts_tb] no ATB bytes observed");
		end else begin
			$display("[interrupts_tb] observed %0d ATB transfers", env.atb_bytes_seen);
		end

		$display("[interrupts_tb] PASS");
		$display("[interrupts_tb] ATB binary trace:");
		$system("realpath interrupts_tb.atb.bin");
		$display("[interrupts_tb] TIP text dump:");
		$system("realpath interrupts_tb.tip.txt");
		$display("[interrupts_tb] NexRv PCInfo:");
		$system("realpath interrupts_tb.nexrv.info");
		$finish;
	end

	// Hard timeout
	initial begin
		#10ms;
		$error("[interrupts_tb] TIMEOUT - test exceeded 10 ms wall time");
		$finish;
	end

endmodule : interrupts_tb

`default_nettype wire
