// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
*
* @brief    Writes ATB traffic to a binary dump file
* @details
*   Captures ATB bytes on each *accepted* beat (atvalid && atready) and
*   writes them to `FILEPATH` in binary mode. The final dump path and byte
*   count are printed at end of simulation so the output location is visible
*   even when no ATB flush occurs.
*/

module atb_dump #(
	string	FILEPATH = ""
) (
	input uwire logic		atb_atclk, 					// ATB clock
	input uwire logic		atb_atresetn,				// ATB reset (low active)
	atb_if.monitor			atb
);

	import file_pkg::*;
	import ct_pkg::*;

	int		fd_dump		= -1;	// file handle for raw dump
	int		dump_bytes	= 0;

	initial begin
		file_open(FILEPATH, "wb", fd_dump);
		forever begin
			@(posedge atb_atclk iff atb_atresetn);
			#5ps;
			if (atb.atvalid && atb.atready) begin
				for (int i = 0; i < (atb.atbytes+1); i++) begin
					automatic logic [7:0] byte_val = atb.atdata[i*8 +: 8];
					$fwrite(fd_dump, "%c", byte_val);
					dump_bytes += 1;
				end
			end
			// NOTE: do NOT close the file on `atb.afready`. afready is a normal
			// flush-handshake pulse from the ATB master and may fire many times
			// during a long run; closing here truncates the dump. The final
			// block below handles clean-up at $finish.
		end
	end

	final begin
		if (fd_dump != -1) begin
			$fclose(fd_dump);
			fd_dump = -1;
		end
		$display("*** INFO (%m, line %0d) atb_dump saved to %s (%0d bytes)", `__LINE__, FILEPATH, dump_bytes);
	end

endmodule // atb_dump
`default_nettype wire
