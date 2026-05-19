// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief Single-entry message buffer with valid/ready handshake.
 */
module ct_L2_mseo_mdo_formatter_msg_buffer #(
	parameter int unsigned NEXUS_MAX_FIELDS = nexus_vendor::NEXUS_MAX_FIELDS
) (
	input  var logic clk,
	input  var logic rst,

	input  var logic                             msg_valid,
	output logic                                 msg_ready,
	input  var nexus::nexus_message_t  msg_in,
	input  var logic [$clog2(NEXUS_MAX_FIELDS):0] msg_num_fields,

	output logic                                 buf_valid,
	input  var logic                             buf_ready,
	output nexus::nexus_message_t       msg_out,
	output logic [$clog2(NEXUS_MAX_FIELDS):0]     msg_num_fields_out
);
	import nexus::*;

	logic Full = 1'b0;
	assign buf_valid = Full;
	assign msg_ready = !Full || (buf_ready && buf_valid);

	always_ff @(posedge clk) begin
		if (rst) begin
			Full               <= 1'b0;
			msg_out            <= '0;
			msg_num_fields_out <= '0;
		end else begin
			// Pop when downstream accepts.
			if (buf_valid && buf_ready) begin
				Full <= 1'b0;
			end

			// Push (may coincide with pop -> behaves like bypass but still registered).
			if (msg_valid && msg_ready) begin
				Full               <= 1'b1;
				msg_out            <= msg_in;
				msg_num_fields_out <= msg_num_fields;
			end
		end
	end

endmodule

`default_nettype wire
