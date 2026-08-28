// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief Synthesis/implementation wrapper for ct_L2_mseo_mdo_formatter_bit_slicer.
 *
 * @note Standalone probe with flat ports — instantiated by no gate and by no
 *       file list; its purpose is to give the slicer a synthesizable top for an
 *       out-of-context area/timing run. Because nothing exercises it, a stale
 *       default here goes unnoticed: until 2026-08-08 it still defaulted to
 *       MDO_WIDTH = 30, a width the core has rejected with $fatal since the
 *       2026-07-19 rework ("6 and 14 only; 30 removed"), so the wrapper could
 *       not elaborate with its own default. Found while elaborating the tree in
 *       an LRM-strict frontend, where $fatal fires at elaboration time.
 *       If you add a supported width, keep the default among them.
 */
module ct_L2_mseo_mdo_formatter_bit_slicer_top #(
	parameter int unsigned NEXUS_MAX_FIELDS           = nexus_vendor::NEXUS_MAX_FIELDS,
	parameter int unsigned NEXUS_MAX_FIELD_DATA_WIDTH = nexus_vendor::NEXUS_MAX_FIELD_DATA_WIDTH,
	parameter int unsigned MDO_WIDTH                  = 14
) (
	input  var logic             clk,
	input  var logic             rst,
	input  var logic             atb_atclk,
	input  var logic             atb_atresetn,
	output logic [MDO_WIDTH-1:0] slice_bits,
	output logic                 slice_valid,
	output logic                 slice_ends_field,
	output logic                 slice_ends_variable_field,
	output logic                 slice_last_padded,
	output logic                 start_of_message,
	output logic                 end_of_message,
	output logic                 atb_heartbeat
);
	import nexus::*;

	logic                                  msg_valid = 1'b0;
	logic                                  msg_ready;
	nexus_message_t                        msg_in = '0;
	logic [$clog2(NEXUS_MAX_FIELDS):0]     msg_num_fields = '0;
	logic                                  slice_ready = 1'b1;
	logic [31:0]                           MsgSeed = '0;
	(* DONT_TOUCH = "true" *) logic [7:0]  AtbCnt = '0;

	always_ff @(posedge clk) begin
		if (rst) begin
			msg_valid      <= 1'b0;
			msg_in         <= '0;
			msg_num_fields <= NEXUS_MAX_FIELDS;
			slice_ready    <= 1'b1;
			MsgSeed        <= 32'h1;
		end else begin
			MsgSeed <= {MsgSeed[30:0], MsgSeed[31] ^ MsgSeed[21] ^ MsgSeed[1] ^ MsgSeed[0]};

			// Backpressure modulation keeps handshake logic active.
			slice_ready <= MsgSeed[0];

			// One-cycle valid pulse when slicer is idle/ready.
			if (!msg_valid && msg_ready) begin
				msg_valid      <= 1'b1;
				msg_num_fields <= ((MsgSeed[$clog2(NEXUS_MAX_FIELDS)-1:0] %
					NEXUS_MAX_FIELDS) + 1);
				msg_in.id      <= MsgSeed;

				for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
					msg_in.fields[i].name <= nexus::nexus_field_name_e'(i[5:0]);
					msg_in.fields[i].field_type <= (i[0]) ? nexus::FIXED : nexus::VARIABLE;
					msg_in.fields[i].data_width <= (i % (NEXUS_MAX_FIELD_DATA_WIDTH - 1)) + 1;
					msg_in.fields[i].data <= {{(NEXUS_MAX_FIELD_DATA_WIDTH-32){1'b0}}, MsgSeed} ^
						(NEXUS_MAX_FIELD_DATA_WIDTH'(i) << (i % 5));
				end
			end else begin
				msg_valid <= 1'b0;
			end
		end
	end

	always_ff @(posedge atb_atclk) begin
		if (!atb_atresetn) begin
			AtbCnt <= '0;
		end else begin
			AtbCnt <= AtbCnt + 1'b1;
		end
	end

	assign atb_heartbeat = AtbCnt[7];

	ct_L2_mseo_mdo_formatter_bit_slicer #(
		.NEXUS_MAX_FIELDS(NEXUS_MAX_FIELDS),
		.NEXUS_MAX_FIELD_DATA_WIDTH(NEXUS_MAX_FIELD_DATA_WIDTH),
		.MDO_WIDTH(MDO_WIDTH)
	) dut (
		.clk,
		.rst,
		.msg_valid,
		.msg_ready,
		.msg_in,
		.msg_num_fields,
		.slice_bits,
		.slice_valid,
		.slice_ready,
		.slice_ends_field,
		.slice_ends_variable_field,
		.slice_last_padded,
		.start_of_message,
		.end_of_message
	);

endmodule

`default_nettype wire
