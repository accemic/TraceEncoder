// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author	Albert Schulz <aschulz@accemic.com>
* @author	Alexander Lange <alange@accemic.com>
*
* @brief    Accemic C-Trace CSR Access Protocol (ACT-CAP) Interface
*/

interface ct_act_cap_if  ();

	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import ct_pkg::*;

	logic							valid;
	ct_cs_cpuif__trActCapStCmd__out_t	cmd;
	ct_act_cap_data_t				addr;
	ct_act_cap_data_t				data;

	modport master (
		output	valid, cmd, addr, data
	);

	modport slave (
		input	valid, cmd, addr, data
	);
endinterface
