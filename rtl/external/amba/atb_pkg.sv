// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
* @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
*
* @brief    ATB Package
*/

package atb_pkg;
	localparam ATDATA_WIDTH     = 32;			// Trace data width
	localparam ATBYTES_WIDTH     = 2;			// # of bytes on ATDATA to be captured
	localparam ATID_WIDTH		 = 7; 			// ID width (fixed to 7)

	task automatic do_flush(input logic atclk, input logic afready, output logic afvalid);

		afvalid = '1;

		// wait afready == 0
		while (1) begin
			@(posedge atclk);
			if (!afready) begin
			  break;
			end
		end

		// wait afready == 1
		while (1) begin
			@(posedge atclk);
			if (afready) begin
			  afvalid     = '0;
			  break;
			end
		end

	endtask


endpackage
