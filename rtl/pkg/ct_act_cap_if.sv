// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    Accemic CEDARtools CSR Access Protocol (ACT-CAP) Interface
 */

interface ct_act_cap_if ();

	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import ct_pkg::*;

	logic                             valid;
	ct_cs_cpuif__trActCapStCmd__out_t cmd;
	ct_act_cap_data_t                 addr;
	ct_act_cap_data_t                 data;

	modport master (
		output  valid, cmd, addr, data
	);

	modport slave (
		input   valid, cmd, addr, data
	);

endinterface // ct_act_cap_if

`default_nettype wire
