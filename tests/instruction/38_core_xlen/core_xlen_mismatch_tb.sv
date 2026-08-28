// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    P0-07 rejecting leg 1: the DEFECT itself -- a hart of the other
 *           architectural width on this netlist's trace ingress.
 *
 * @details
 *   Elaboration MUST abort with the ct_encoder CORE_XLEN mismatch message. A
 *   run that reaches simulation is a guard failure, not a pass; the body
 *   prints "GUARD DID NOT FIRE" in that case. Derived from ct_pkg::CT_XLEN so
 *   the leg is wrong in BOTH builds of the knob (64 against a 32-bit netlist,
 *   32 against a 64-bit one).
 */
module core_xlen_mismatch_tb;
	localparam int unsigned OTHER_XLEN = (ct_pkg::CT_XLEN == 32) ? 64 : 32;
	core_xlen_body #(.DECLARED_XLEN(OTHER_XLEN)) body ();
endmodule
