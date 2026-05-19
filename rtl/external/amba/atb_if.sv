// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
* @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
*
* @brief   ATB-C (Advanced Trace Bus) Interface Definition
* 			   according AMBA® ATB Protocol Specification
*/

interface atb_if ();

  logic [atb_pkg::ATBYTES_WIDTH-1:0] 	atbytes;  // ATB data byte lanes
  logic [atb_pkg::ATDATA_WIDTH-1:0]		atdata;   // ATB data
  logic [atb_pkg::ATID_WIDTH-1:0]		  atid;     // ATB ID
  logic 								              atready;  // ATB ready
  logic 								              atvalid;  // ATB valid
  logic 								              afvalid;  // ATB flush valid
  logic 								              afready;  // ATB flush ready
  logic 								              syncreq;  // ATB sync request

  // Modport for ATB master
  modport master (input  atready, afvalid, syncreq,
						  output atbytes, atdata, atid, atvalid, afready);

  // Modport for ATB slave
  modport slave (output atready, afvalid, syncreq,
				 input  atbytes, atdata, atid, atvalid, afready);

  // Modport for passive observers (dumps, scoreboards).
  // Read-only on all signals; must not drive atready/afvalid/syncreq.
  modport monitor (input  atbytes, atdata, atid, atvalid, afready,
				   input  atready, afvalid, syncreq);

endinterface // atb_if
