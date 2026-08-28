// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Core/encoder address-width agreement (P0-07): shared body of the
 *           three legs.
 *
 * @details
 *   A hart wider than the netlist that traces it loses its upper address bits
 *   in the adapter -- silently, and with no downstream symptom: the
 *   assignment to the narrower tip_if.iaddr truncates without a warning, the
 *   encoder emits a well-formed stream of plausible low addresses, the config
 *   message honestly advertises the netlist's OWN width (CAPS bit 23), and
 *   the decoder reconstructs exactly what it was handed. No capture, no
 *   assertion and no decoder check downstream can recover the difference.
 *
 *   ct_encoder therefore refuses to elaborate unless the integrator DECLARES
 *   the width of the attached hart (parameter CORE_XLEN) and the declaration
 *   matches ct_pkg::CT_XLEN. This module is instantiated by three one-line
 *   tops, one per leg:
 *
 *     core_xlen_accept_tb      declares the truth               -> must RUN
 *     core_xlen_mismatch_tb    declares the other width         -> must ABORT
 *     core_xlen_undeclared_tb  declares nothing (CORE_XLEN = 0) -> must ABORT
 *
 *   Separate top FILES, not `ifdef` legs in one: the rejecting legs must not
 *   be reachable by accident, and a top that is never instantiated is never
 *   elaborated -- an elaboration guard cannot be tested by a module the tool
 *   skipped.
 *
 *   The verdict is read off the tool OUTPUT, never off the exit code: an
 *   elaboration `$fatal` does not reliably set one (xsim returns 0 for it),
 *   so a zero exit proves nothing here. scripts/cli_core_xlen_test.sh does
 *   that reading and is the thing to run; it also proves the ACCEPTING leg,
 *   because a guard that rejects everything would pass a negative test alone.
 */

module core_xlen_body #(
	// The width declaration handed to the DUT -- see the three tops.
	int unsigned DECLARED_XLEN = 0
) ();

	import cpu_model_pkg::*;
	import tip_pkg::*;

	ct_env #(
		.CORE_XLEN          (DECLARED_XLEN),
		.ATB_DUMP_PATH      ("core_xlen_tb.atb.bin"),
		.TIP_DUMP_TXT_PATH  ("core_xlen_tb.tip.txt"),
		.NEXRV_INFO_PATH    ("core_xlen_tb.nexrv.info"),
		.EXPECTED_PCS_PATH  ("core_xlen_tb.expected.pcs")
	) env ();

	initial begin
		$display("[core_xlen_tb] declared CORE_XLEN = %0d, netlist ct_pkg::CT_XLEN = %0d",
		         DECLARED_XLEN, ct_pkg::CT_XLEN);
		if (DECLARED_XLEN != ct_pkg::CT_XLEN) begin
			// Reaching a RUNNING simulation on a rejecting leg means the
			// guard did not fire. Say so in the words the checker greps for,
			// so it cannot be mistaken for a pass.
			$display("[core_xlen_tb] GUARD DID NOT FIRE: elaboration accepted CORE_XLEN=%0d against a %0d-bit netlist",
			         DECLARED_XLEN, ct_pkg::CT_XLEN);
		end

		env.wait_for_reset_release();
		env.csr.clear();
		env.csr.Set_te_trTeControl_Enable      (1'b1);
		env.csr.Set_te_trTeControl_InstTracing (1'b1);
		env.csr.Set_te_trTeControl_Active      (1'b1);
		env.cpu.idle(20);

		// Minimal traced scenario -- the point of the accepting leg is that
		// a matching declaration reaches a RUNNING encoder and produces
		// bytes, not what those bytes contain (01_basic covers the content).
		env.cpu.enter(.start_pc(tip_iaddr_t'(32'h0000_1000)));
		env.cpu.run(16);
		env.cpu.exit_trace();
		env.cpu.idle(64);

		env.csr.Set_te_trTeControl_InstTracing (1'b0);
		env.csr.Set_te_trTeControl_Enable      (1'b0);
		env.cpu.idle(64);

		if (env.atb_bytes_seen == 0)
			$error("[core_xlen_tb] no ATB bytes -- the accepting leg has to TRACE, not just elaborate");
		else
			$display("[core_xlen_tb] observed %0d ATB transfers", env.atb_bytes_seen);

		$display("[core_xlen_tb] PASS");
		$finish;
	end

	// Global timeout -- never let a broken DUT hang the regression.
	initial begin
		#5ms;
		$error("[core_xlen_tb] TIMEOUT - test exceeded 5 ms wall time");
		$finish;
	end

endmodule
