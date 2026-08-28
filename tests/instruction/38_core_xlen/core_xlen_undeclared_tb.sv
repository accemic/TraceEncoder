// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    P0-07 rejecting leg 2: nothing declared (CORE_XLEN = 0).
 *
 * @details
 *   The common case -- an integrator who never considered the width. It has
 *   to abort for the same reason the mismatch does: treating "said nothing"
 *   as "agrees" would put the failure back into the default. Elaboration MUST
 *   abort with the ct_encoder "undeclared" message.
 */
module core_xlen_undeclared_tb;
	core_xlen_body #(.DECLARED_XLEN(0)) body ();
endmodule
