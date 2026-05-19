// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    AXIS "decoder" for verification
*
* This module is intentionally simple: it converts one AXIS beat into a
* structured record so testbenches can assert on fields without manually
* slicing tdata/tid/tstrb.
*/

module ct_axis_decoder (
	input  uwire logic                  clk,
	input  uwire logic                  rst,
	axis_if.slave                       axis,
	output uwire                        dec_axis_valid,
	output uwire                        dec_axis_error,
	output ct_axis_decoder_pkg::ct_axis_msg_t dec_axis_msg
);

	import ct_axis_decoder_pkg::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;

	// Always ready: verification sink
	assign axis.tready = 1'b1;

	localparam int STRB_WIDTH = ACT_CAP_AXIS_TDATA_WIDTH/8;

	ct_axis_msg_t Msg;
	logic MsgValid;
	logic MsgError;
	logic [31:0] msg_id;

	// Extract 3x32b elements from tdata (LSB-first)
	function automatic ct_axis_elem_t get_elem(input logic [ACT_CAP_AXIS_TDATA_WIDTH-1:0] tdata, input int idx);
		ct_axis_elem_t r;
		r = tdata[idx*32 +: 32];
		return r;
	endfunction

	function automatic logic elem_is_valid(input logic [STRB_WIDTH-1:0] tstrb, input int idx);
		// each element is 4 bytes => valid if all 4 strb bits are 1
		return &tstrb[idx*4 +: 4];
	endfunction

	always_ff @(posedge clk) begin
		MsgValid <= 1'b0;
		MsgError <= 1'b0;
		Msg      <= '0;

		if (rst) begin
			msg_id <= '0;
		end else begin
			if (axis.tvalid && axis.tready) begin
				msg_id <= msg_id + 1;
				MsgValid <= 1'b1;
				Msg.id   <= msg_id;
				Msg.raw_tid   <= axis.tid;
				Msg.raw_tdata <= axis.tdata;
				Msg.raw_tstrb <= axis.tstrb;

				// cmd from tid
				Msg.cmd <= ct_cs_cpuif__trActCapStCmd_e_e'(axis.tid);

				// elements + valid mask
				for (int i = 0; i < 3; i++) begin
					Msg.elem[i] <= get_elem(axis.tdata, i);
					Msg.elem_valid[i] <= elem_is_valid(axis.tstrb, i);
				end

				// Basic error checks:
				// - if any element has partial strobes -> error
				for (int i = 0; i < 3; i++) begin
					logic [3:0] s;
					s = axis.tstrb[i*4 +: 4];
					if ((s != 4'h0) && (s != 4'hF)) begin
						MsgError <= 1'b1;
					end
				end
			end
		end
	end

	assign dec_axis_valid = MsgValid;
	assign dec_axis_error = MsgError;
	assign dec_axis_msg   = Msg;

endmodule

`default_nettype wire
