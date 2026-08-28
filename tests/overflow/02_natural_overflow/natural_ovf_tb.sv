// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    NATURAL eTIP overflow (no ovf_injector forcing) — reproducer.
 *
 * @details
 *   Models the equal-clock integration (MBV KV260 SoC: every encoder clock
 *   tied to one PL clock while CT_SINGLE_CLOCK=0) where the proc/atb drain
 *   does NOT outpace the retire side: ATB/PROC_CLK_HALF_NS = tip half
 *   period. Under back-to-back uninferable jumps (1 IndirectBranchHist per
 *   retire, CYCLES_PER_INSTR=1) the eTIP path then overflows NATURALLY —
 *   a regime the injector-forced overrun tests never enter (the 180-jump
 *   fifo_hist pressure run at default 250 MHz drain peaked at fill 16/128).
 *
 *   Observed defect (first found on a KV260 SoC integration flow): after the
 *   FIRST natural
 *   overflow the encoder stays in a persistent drop-recover cycle (ERROR +
 *   SYNC(FIFO_OVERFLOW) pairs continue load-invariantly even through calm
 *   phases), and the first surviving post-sync CF carries the ICNT of its
 *   private predecessor instead of the distance from the recovery anchor —
 *   NexRv aborts ("resolved source ... to a non-indirect instruction").
 *
 *   Structure: 2 storm bursts (700 back-to-back uninferable jumps each,
 *   disjoint fresh targets) separated by a calm linear phase; clean tail.
 *   Gates (scripts/cli_natovf_test.sh):
 *     1. >=1 Nexus Error message   -> natural overflow actually reached
 *     2. NexRv "Decoded OK"        -> the regression guard
 *     3. errors stop after the last burst (no drop-recover wedge)
 */

module natural_ovf_tb;

	import cpu_model_pkg::*;

	ct_env #(
		.SPLIT_DATA_ACCESS   (0),
		.CYCLES_PER_INSTR    (1),
		.ATB_CLK_HALF_NS     (5),      // == tip half period: equal-rate drain
		.PROC_CLK_HALF_NS    (5),
		.ATB_DUMP_PATH       ("natural_ovf_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH   ("natural_ovf_tb.tip.txt"),
		.NEXRV_INFO_PATH     ("natural_ovf_tb.nexrv.info"),
		.EXPECTED_PCS_PATH   ("natural_ovf_tb.expected.pcs")
	) env ();

	localparam logic [31:0] MAIN_PC = 32'h0000_7000;
	localparam int unsigned STORM_JUMPS = 700;

	task automatic storm(input logic [31:0] base);
		for (int i = 0; i < STORM_JUMPS; i++) begin
			env.cpu.uninferable_jump(.target(base + 32'(i + 1) * 32'h40));
		end
	endtask

	initial begin
		$display("[natural_ovf_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();

		env.csr.clear();
		env.csr.Set_te_trTsControl_Active      (1'b0);
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		env.cpu.enter(.start_pc(MAIN_PC));
		env.cpu.run(64);

		// Burst 1: natural overflow (needs ~hundreds of back-to-back CFs to
		// fill the 128-deep eTIP CVS at equal-rate drain).
		storm(MAIN_PC + 32'h0001_0000);
		// Calm: linear retires only — a healthy encoder drains its backlog
		// here and the drop-recover pairs MUST stop.
		env.cpu.run(1600);

		// Burst 2 + clean tail.
		storm(MAIN_PC + 32'h0004_0000);
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

		if (env.cpu.event_count() == 0) $error("[natural_ovf_tb] cpu_model event log empty");
		if (env.atb_bytes_seen == 0)    $error("[natural_ovf_tb] no ATB bytes observed");
		$display("[natural_ovf_tb] PASS (sim); decode gates in scripts/cli_natovf_test.sh");
		$finish;
	end

	// Hard timeout
	initial begin
		#40ms;
		$error("[natural_ovf_tb] TIMEOUT - test exceeded 40 ms wall time");
		$finish;
	end

endmodule : natural_ovf_tb

`default_nettype wire
