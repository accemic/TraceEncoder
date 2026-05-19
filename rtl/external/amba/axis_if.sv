// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    AXI4 Stream Interface Definition
* @author   Albert Schulz <aschulz@accemic.com>, Alexander Weiss <aweiss@accemic.com>
*/

interface axis_if #(
	parameter int TDATA_WIDTH  = 32,                // width of tdata in bits
	parameter int TSTRB_WIDTH  = TDATA_WIDTH/8,     // width of tstrb in bits
	parameter int TKEEP_WIDTH  = TDATA_WIDTH/8,     // width of tkeep in bits
	parameter int TID_WIDTH    = 8,                 // width of tid in bits
	parameter int TDEST_WIDTH  = 8,                 // width of tdest in bits
	parameter int TUSER_WIDTH  = 1                  // width of tuser in bits
) (
	input  uwire logic aclk,       // global clock
	input  uwire logic aresetn     // active-low reset
);

	// data and control signals
	logic                   tvalid; // transfer valid handshake
	logic                   tready; // transfer ready handshake
	logic [TDATA_WIDTH-1:0] tdata;  // main data payload
	logic [TSTRB_WIDTH-1:0] tstrb;  // byte qualifier (optional)
	logic [TKEEP_WIDTH-1:0] tkeep;  // byte qualifier (optional)
	logic                   tlast;  // end-of-packet flag (optional)
	logic [TID_WIDTH-1:0]   tid;    // packet identifier (optional)
	logic [TDEST_WIDTH-1:0] tdest;  // destination identifier (optional)
	logic [TUSER_WIDTH-1:0] tuser;  // user-defined sideband (optional)

	// master modport: source drives data & valid, samples ready
	modport master (
		input  aclk, aresetn,
		output tdata, tstrb, tkeep, tlast, tid, tdest, tuser, tvalid,
		input  tready
	);

	// slave modport: sink drives ready, samples data & valid
	modport slave (
		input  aclk, aresetn,
		input tdata, tstrb, tkeep, tlast, tid, tdest, tuser, tvalid,
		output  tready
	);

	// monitor modport: passive observer, drives nothing
	modport monitor (
		input aclk, aresetn,
		input tdata, tstrb, tkeep, tlast, tid, tdest, tuser, tvalid, tready
	);

endinterface
