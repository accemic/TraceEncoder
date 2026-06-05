// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief  Dump C-Trace DAQ AXI Stream (AXIS) transactions
 *
 * @details
 * This module is meant for SIMULATION ONLY.
 *
 * Files written:
 *   - Text dump: <CT_DATE_TIME>_<realtime>_ct_axis.txt
 *   - Raw  dump: <CT_DATE_TIME>_<realtime>_ct_axis.raw
 *
 * The dump is unconditional: both text and raw files are written whenever this
 * module is instantiated. Presence of the instance is the gate.
 *
 * ---------------------------------------------------------------------------
 * RAW FILE FORMAT (little-endian, fixed record size)
 * ---------------------------------------------------------------------------
 * Each record corresponds to one AXIS beat when (tvalid && tready) is true.
 *
 * Record layout (total 1 + 12 + 12 = 25 bytes):
 *   Byte  0      : tid
 *   Byte  1..12  : tdata[ 95:0] as 12 bytes, little-endian
 *                 (byte0 = tdata[ 7:0], byte11 = tdata[95:88])
 *   Byte 13..24  : tstrb[11:0] expanded to 12 bytes (0x00 or 0x01)
 *                 (byte13 corresponds to tstrb[0])
 *
 * Notes:
 *   - The payload width is fixed to ACT_CAP_AXIS_TDATA_WIDTH == 96.
 *   - The strobe width is fixed to 12.
 *   - If you change AXIS widths in ct_pkg, update this module accordingly.
 *
 * Reference C structure for one record (packed):
 *
 *   #include <stdint.h>
 *   #pragma pack(push, 1)
 *   typedef struct {
 *     uint8_t  tid;
 *     uint8_t  tdata[12];   // little-endian byte array
 *     uint8_t  tstrb[12];   // 0/1 per byte lane
 *   } ct_axis_raw_record_t;
 *   #pragma pack(pop)
 *
 * ---------------------------------------------------------------------------
 */

module ct_axis_dump #(
	// Output directory for the dump files, relative to the simulator's
	// working directory (note: Vivado XSim runs from a nested build dir, not
	// the repo root). The default writes to a local `runs/` directory; pass
	// +CT_OUT_DIR=<path> at runtime, or override OUT_DIR, to redirect it.
	string  OUT_DIR                  = "runs",
	int     DUMP_COUNT_MAX           = 500000
) (
	axis_if.monitor       axis
);

	import ct_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import file_pkg::*;

	int fd_txt = 0;
	int fd_raw = 0;
	int dump_count = 0;
	string filepath_txt;
	string filepath_raw;
	string date_time = "unknown";
	string out_dir;

	function automatic string mk_path(input string ext);
		// Use $realtime to avoid collisions within one sim session.
		// Prefix with CT_DATE_TIME (provided by abc-flow via plusarg).
		mk_path = $sformatf("%s/%s_%0.0f_ct_axis.%s", out_dir, date_time, $realtime, ext);
	endfunction

	function automatic int elem_valid_from_tstrb(input logic [ACT_CAP_AXIS_TDATA_WIDTH/8-1:0] tstrb, input int elem_idx);
		automatic int base = elem_idx * (ACT_CAP_INT_ELEMENT_WIDTH/8);
		automatic int ok = 1;
		for (int i = 0; i < (ACT_CAP_INT_ELEMENT_WIDTH/8); i++) begin
			ok &= tstrb[base+i];
		end
		return ok;
	endfunction

	initial begin
		if (!$value$plusargs("CT_DATE_TIME=%s", date_time)) begin
			date_time = "unknown";
		end

		// Default output directory comes from module parameter.
		// We keep this in a runtime variable so we can override it via plusarg.
		out_dir = OUT_DIR;

		// Optional: override output directory with absolute path injected by flow.
		// This avoids dependence on simulator working directory (Vivado may run
		// simulations e.g. under <repo>/ct_tb.vivado/... or <repo>/work/ct_tb.vivado/...).
		if ($value$plusargs("CT_OUT_DIR=%s", out_dir)) begin
			// out_dir already updated
		end

		filepath_txt = mk_path("txt");
		filepath_raw = mk_path("raw");

		file_open(filepath_txt, "w", fd_txt);
		$fwrite(fd_txt, "# C-Trace AXIS dump (txt)\n");
		$fwrite(fd_txt, "# Columns: time tid cmd_name tstrb elem_valid[2:0] elem0 elem1 elem2 tdata_hex\n");
		file_open(filepath_raw, "wb", fd_raw);

		forever begin
			@(posedge axis.aclk);
			if (!axis.aresetn) begin
				continue;
			end

			if (axis.tvalid && axis.tready) begin
				dump_count++;

				// TXT
				if (fd_txt != 0) begin
					automatic ct_cs_cpuif__trActCapStCmd_e_e cmd_e = ct_cs_cpuif__trActCapStCmd_e_e'(axis.tid);
					automatic int ev0 = elem_valid_from_tstrb(axis.tstrb, 0);
					automatic int ev1 = elem_valid_from_tstrb(axis.tstrb, 1);
					automatic int ev2 = elem_valid_from_tstrb(axis.tstrb, 2);
					$fwrite(fd_txt,
						"%0t 0x%02x %s 0x%03x %0d%0d%0d 0x%08x 0x%08x 0x%08x 0x%024x\n",
						$time,
						axis.tid,
						cmd_e.name(),
						axis.tstrb,
						ev2, ev1, ev0,
						axis.tdata[31:0],
						axis.tdata[63:32],
						axis.tdata[95:64],
						axis.tdata);
				end

				// RAW
				if (fd_raw != 0) begin
					// tid
					$fwrite(fd_raw, "%c", axis.tid);
					// tdata bytes (little endian)
					for (int b = 0; b < (ACT_CAP_AXIS_TDATA_WIDTH/8); b++) begin
						automatic logic [7:0] d = axis.tdata[b*8 +: 8];
						$fwrite(fd_raw, "%c", d);
					end
					// tstrb expanded to bytes
					for (int b = 0; b < (ACT_CAP_AXIS_TDATA_WIDTH/8); b++) begin
						automatic logic [7:0] s = {7'b0, axis.tstrb[b]};
						$fwrite(fd_raw, "%c", s);
					end
				end
			end

			if (dump_count >= DUMP_COUNT_MAX) begin
				break;
			end
		end

		if (fd_txt != 0) begin
			$fclose(fd_txt);
			fd_txt = 0;
		end
		if (fd_raw != 0) begin
			$fclose(fd_raw);
			fd_raw = 0;
		end
		$display("*** INFO (%m): ct_axis_dump wrote %0d records", dump_count);
		$display("*** INFO (%m): txt=%s", filepath_txt);
		$display("*** INFO (%m): raw=%s", filepath_raw);
	end

endmodule

`default_nettype wire
