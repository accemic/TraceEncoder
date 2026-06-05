// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author	Albert Schulz <aschulz@accemic.com>
* @author	Alexander Lange <alange@accemic.com>
*
* @brief  Dump AXI Stream signals
* @details
* 	Dump mode: RAW
*/

module axis_dump #(
	string  FILEPATH_AXIS_DUMP_RAW   	= "",
	int 	DUMP_COUNT_MAX				= 500			// Number of transactions to observe
) (
	axis_if.slave			axis
);

	int 											fd_dump_raw			= 0;	// file handle for raw dump
	int												dump_raw_bytes 		= 0;
	int 											dump_count 			= 0;

	assign axis.tready = 1;

	initial begin

	// open files
	file_pkg::file_open(FILEPATH_AXIS_DUMP_RAW, "wb", fd_dump_raw);

	forever begin
		@(posedge axis.aclk iff axis.aresetn);

		if (axis.tvalid) begin
			dump_count++;
			$fwrite(fd_dump_raw, "%c: %c", axis.tid, axis.tdata);
		end

		if(dump_count >= DUMP_COUNT_MAX) begin
			if (fd_dump_raw != 0) 		begin
				dump_raw_bytes = $ftell(fd_dump_raw);
				$fclose(fd_dump_raw);
				if (fd_dump_raw != 0)    	 $error  ("*** ERROR (%m, line %0d) axis_dump_raw %s closing failed.", `__LINE__, FILEPATH_AXIS_DUMP_RAW);
				$display("*** INFO  (%m, line %0d) axis_dump_raw %s written: %0d transactions", `__LINE__, FILEPATH_AXIS_DUMP_RAW, dump_raw_bytes);
			end
			break;	// break the forever loop
		end
	end
end

endmodule // axis_dump
`default_nettype wire
