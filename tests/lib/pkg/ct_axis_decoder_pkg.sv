// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Types for ct_axis_decoder (verification helper)
 */

package ct_axis_decoder_pkg;

	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	typedef logic [31:0] ct_axis_elem_t;

	typedef struct packed {
		logic [31:0]              id;            // monotonic counter
		ct_cs_cpuif__trActCapStCmd_e_e cmd;           // decoded from TID
		logic [2:0]               elem_valid;    // one bit per 32-bit element
		ct_axis_elem_t [2:0]      elem;          // packed array: 3x32b payload (as on AXIS)
		logic [7:0]               raw_tid;
		logic [ACT_CAP_AXIS_TDATA_WIDTH-1:0] raw_tdata;
		logic [ACT_CAP_AXIS_TDATA_WIDTH/8-1:0] raw_tstrb;
	} ct_axis_msg_t;

endpackage

`default_nettype wire
