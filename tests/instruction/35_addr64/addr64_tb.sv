// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Address-width emission test (X2a): the ATB bytes carry the FULL
 *           instruction address.
 *
 * @details
 *   The scenario is deliberately small and plain -- linear runs, a taken
 *   branch, a call/return pair and an indirect jump. What matters is not the
 *   control flow but WHERE it happens: the base PC is
 *
 *     CT_XLEN = 32 -> 0x0000_1000            (identical class to 01_basic)
 *     CT_XLEN = 64 -> 0xFFFF_FFC0_0000_1000  (above 2^32 -- see below)
 *
 *   so a 64-bit build has to put address bits above 31 on the wire. That is
 *   the property this test exists for, and it is checked on the RAW BYTE
 *   STREAM by scripts/check_addr64_emission.py, not on a decoder's opinion:
 *   the reference decoder's own 64-bit support is a separate work package,
 *   and a test that could only fail together with the decoder would prove
 *   nothing about the encoder.
 *
 *   Why the byte check is possible at all without a full field parser: the
 *   configuration below removes every field that would follow the address in
 *   a TCODE 9/11/12 message --
 *
 *     - InhibitSrc = 1  removes the SRC field,
 *     - trTsControl  = 0 removes the TSTAMP field,
 *
 *   so PC_FADDR is the LAST field of a synchronizing message, and the MDO
 *   nibbles between the last "end of variable-length field" (MSEO 01) and the
 *   "end of message" byte (MSEO 11) are exactly that field. No knowledge of
 *   the fixed-field widths is needed, and the reconstruction is unambiguous.
 *
 *   The high base address is 0xFFFF_FFC0_0000_1000: it has bits set in the
 *   top byte AND leaves the low 32 bits looking like an ordinary program
 *   address, so a build that truncates to 32 bit produces a plausible-looking
 *   stream rather than an obviously broken one -- exactly the failure the
 *   check has to catch.
 *
 *   Configuration: instruction trace ON, timestamps OFF, SRC inhibited,
 *   data trace OFF, compression suite at its reset defaults.
 */

module addr64_tb;

	import cpu_model_pkg::*;
	import tip_pkg::*;

	// Base of the traced program. The offsets below are relative to it, so
	// the scenario is the same shape in both builds.
	localparam tip_iaddr_t BASE = ct_pkg::CT_ADDR64
		? tip_iaddr_t'(64'hFFFF_FFC0_0000_1000)
		: tip_iaddr_t'(32'h0000_1000);

	ct_env #(
		.SPLIT_DATA_ACCESS  (0),
		.CYCLES_PER_INSTR   (4),
		.ATB_DUMP_PATH      ("addr64_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("addr64_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("addr64_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("addr64_tb.expected.pcs")
	) env ();

	initial begin
		$display("[addr64_tb] %0t: waiting for reset release", $time);
		env.wait_for_reset_release();
		env.csr.clear();

		// Timestamps OFF and SRC inhibited -- both are what makes PC_FADDR
		// the last field of a sync message (see the header). trTsControl has
		// to be written BEFORE Enable (the fields are swwel-gated).
		env.csr.Write_te_trTsControl (32'h0000_0000);
		env.csr.Set_te_trTeControl_InhibitSrc (1'b1);

		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);

		env.cpu.idle(20);
		$display("[addr64_tb] %0t: scenario start, BASE = 0x%0h", $time, BASE);

		// ---- Scenario (offsets relative to BASE) --------------------
		env.cpu.enter(.start_pc(BASE));
		env.cpu.run(16);                                   // 4 linear
		env.cpu.branch_taken(.target(BASE + 'h100));
		env.cpu.run(8);                                    // 2 linear
		env.cpu.branch_not_taken();
		env.cpu.call_to(.target(BASE + 'h1000));
		env.cpu.run(24);                                   // 6 linear in the callee
		env.cpu.ret();
		env.cpu.run(8);                                    // 2 linear
		env.cpu.uninferable_jump(.target(BASE + 'h200));
		env.cpu.run(8);                                    // 2 linear
		env.cpu.idle(50);

		env.cpu.exit_trace();
		env.cpu.idle(50);
		env.csr.Set_te_trTeControl_Enable(1'b0);           // correlation + flush
		env.atb_force_flush = 1'b1;
		env.cpu.idle(2000);
		env.atb_force_flush = 1'b0;
		env.csr.Set_te_trTeControl_Active(1'b0);
		env.cpu.idle(10000);

		if (env.cpu.event_count() == 0)
			$error("[addr64_tb] cpu_model event log is empty");
		if (env.atb_bytes_seen == 0)
			$error("[addr64_tb] no ATB bytes observed - encoder produced nothing");

		$display("[addr64_tb] %0d events, %0d ATB transfers",
			env.cpu.event_count(), env.atb_bytes_seen);
		$display("[addr64_tb] PASS");
		$finish;
	end

	// Global timeout -- never let a broken DUT hang the regression
	initial begin
		#5ms;
		$error("[addr64_tb] TIMEOUT - test exceeded 5 ms wall time");
		$finish;
	end

endmodule

`default_nettype wire
