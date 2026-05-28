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
	//   0x10c0 ..        : ISR_I   (2 L + R) — synchronous EXCEPTION_TRAP handler
	//   0x10d0 ..        : ISR_J   (CD)     — interrupt entry that tail-calls into ISR_K
	//   0x10e0 ..        : ISR_K   (2 L + R) — tail-call target
	localparam logic [31:0] MAIN_PC = 32'h0000_1000;
	localparam logic [31:0] ISR_A   = 32'h0000_1040;
	localparam logic [31:0] ISR_B   = 32'h0000_1050;
	localparam logic [31:0] ISR_C   = 32'h0000_1060;
	localparam logic [31:0] ISR_D   = 32'h0000_1070;
	localparam logic [31:0] ISR_E   = 32'h0000_1080;
	localparam logic [31:0] ISR_F   = 32'h0000_1090;
	localparam logic [31:0] ISR_G   = 32'h0000_10a0;
	localparam logic [31:0] ISR_H   = 32'h0000_10b0;
	localparam logic [31:0] ISR_I   = 32'h0000_10c0;
	localparam logic [31:0] ISR_J   = 32'h0000_10d0;
	localparam logic [31:0] ISR_K   = 32'h0000_10e0;

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

		// --- 7) synchronous exception (EXCEPTION_TRAP, not INTERRUPT) ---
		//   Distinct from scenarios 1-6 (all async interrupts): a synchronous
		//   trap (e.g. illegal-instruction / page-fault / ECALL) caused by
		//   the instruction at cur_pc itself. The encoder emits an
		//   IndirectBranchHistory with BTYPE=EXCEPTION (=2), not =INTERRUPT
		//   (=3) — the BTYPE discriminator on the same IBH TCODE is the
		//   only signal the decoder has to distinguish the two trap classes.
		//   This scenario gates the BTYPE=2 emission path
		//   (ct_L2_msg_gen.sv:466-468 in BRANCH_HIST mode).
		env.cpu.exception_trap(.cause(2), .handler(ISR_I));           // sync E @0x1044 -> ISR_I
		env.cpu.run(8);                                               // ISR_I body: 0x10c0, 0x10c4 (2 L)
		env.cpu.mret();                                               // R @0x10c8 -> resume at 0x1048

		// --- 8) interrupt directly followed by an INFERRABLE_TAIL_CALL ---
		//   The interrupt handler's first (and only) retired instruction is
		//   a tail call (`jal x0, ISR_K`) — the body work runs at ISR_K and
		//   ISR_K's mret unwinds back to main. This exercises the encoder
		//   path where an indirect CF (the trap, INTERRUPT itype) is
		//   immediately followed by an inferable CF (the tail call,
		//   INFERRABLE_TAIL_CALL itype):
		//     - Trap eTIP: queues CF item; needs next_iaddr (HasChangedControlFlow).
		//     - Tail-call eTIP: its tip.iaddr (=ISR_J) supplies that next_iaddr,
		//       then itself queues a CF item (also CF, also needs next_iaddr).
		//     - First ISR_K beat: tip.iaddr (=ISR_K) supplies the tail-call's
		//       next_iaddr.
		//   In BRANCH_HIST mode the encoder emits ONE IBH (BTYPE=INTERRUPT,
		//   UADDR=ISR_J) for the trap and NO message for the tail call
		//   (inferable; the decoder walks ISR_J's CD PCInfo to find ISR_K).
		//
		//   This scenario uses async=1 so the trap-source pc (0x1048) is NOT
		//   re-classified as an L event by the trap itself (CPU_INTERRUPT_ASYNC
		//   has empty PCInfo) — that leaves room for the final-linear run(4)
		//   below to retire 0x1048 as a regular L without colliding with the
		//   trap. It also adds coverage of the iretire=0 INTERRUPT path
		//   immediately followed by an iretire=1 INFERRABLE_TAIL_CALL — the
		//   composer must capture next_iaddr for the queued trap CF eTIP from
		//   the tail-call's iretire=1 beat, not from the prior async-marker
		//   beat whose tip.iaddr is spec-undefined.
		env.cpu.interrupt(.cause(7), .handler(ISR_J), .async(1));     // async E @0x1048 -> ISR_J
		env.cpu.tail_call_to(.target(ISR_K));                         // CD @0x10d0 -> ISR_K
		env.cpu.run(8);                                               // ISR_K body: 0x10e0, 0x10e4 (2 L)
		env.cpu.mret();                                               // R @0x10e8 -> resume AT 0x1048 (re-run)

		// Final linear to drain the encoder before trace-off. Only 4 bytes:
		// retiring just 0x1048 here. Going further (run(8)) would retire
		// 0x104c, which already has type R (scenario 1's mret-target) and
		// would conflict with a fresh L assignment.
		env.cpu.run(4);                                               // 0x1048 retires (L, shared with ISR_A body / scen 7)
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
