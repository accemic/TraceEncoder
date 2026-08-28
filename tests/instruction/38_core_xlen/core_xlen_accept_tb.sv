// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    P0-07 accepting leg: a declaration that MATCHES the netlist
 *           elaborates and traces (see core_xlen_body.sv for the contract).
 */
module core_xlen_accept_tb;
	core_xlen_body #(.DECLARED_XLEN(ct_pkg::CT_XLEN)) body ();
endmodule
