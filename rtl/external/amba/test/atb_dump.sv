// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
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
	string  FILEPATH = ""
) (
	input uwire logic atb_atclk,    // ATB clock
	input uwire logic atb_atresetn, // ATB reset (low active)
	atb_if.monitor    atb
);

	import file_pkg::*;
	import ct_pkg::*;

	int     fd_dump     = -1;   // file handle for raw dump
	int     dump_bytes  = 0;

	initial begin
		file_open(FILEPATH, "wb", fd_dump);
	end

	// Capture every accepted beat. Using always_ff (not initial+forever+@posedge)
	// avoids a race where a posedge fires while the forever body is still mid
	// $fwrite -- buffered disk I/O is not guaranteed to return inside a 4 ns
	// clock period, and any missed edge silently drops a beat from the file.
	// Symptom: atb.bin shorter than the live atvalid&&atready event count, and
	// downstream Nexus decode looks like a phase-shifted byte stream (e.g.
	// NexRv reports "TCODE=63 is not defined" because the missing beat 0 of a
	// 2-beat message leaves only beat 1, whose mid-message chunks happen to
	// have MDO=0x3F).
	always_ff @(posedge atb_atclk) begin
		if (atb_atresetn && atb.atvalid && atb.atready) begin
			for (int i = 0; i < (atb.atbytes+1); i++) begin
				logic [7:0] byte_val;
				byte_val = atb.atdata[i*8 +: 8];
				$fwrite(fd_dump, "%c", byte_val);
			end
			dump_bytes <= dump_bytes + (atb.atbytes+1);
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
