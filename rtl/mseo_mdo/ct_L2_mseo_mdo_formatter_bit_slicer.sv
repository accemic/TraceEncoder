// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief Nexus message bit-slicer -- MDO-width dispatch wrapper.
 * @author   Albert Schulz, Accemic (MDO-Spezialisierung 2026-07-19)
 *
 * The supported MDO widths are bound as HARD-WIRED modules via generate
 * (decided 2026-07-19): `_mdo6` and `_mdo14` pin their width at the
 * module boundary; the former generic MDO=30 support is REMOVED (an
 * unsupported width fails elaboration). Both shells share one tuned core
 * (`_impl`) so the slice algorithm cannot drift between widths; the
 * area/throughput knob ct_pkg::CT_SLICER_STEPS applies to both.
 */
module ct_L2_mseo_mdo_formatter_bit_slicer_mdo6 #(
	int unsigned NEXUS_MAX_FIELDS           = nexus_vendor::NEXUS_MAX_FIELDS,
	int unsigned NEXUS_MAX_FIELD_DATA_WIDTH = nexus_vendor::NEXUS_MAX_FIELD_DATA_WIDTH
) (
	input  var logic                              clk,
	input  var logic                              rst,
	input  var logic                              msg_valid,
	output logic                                  msg_ready,
	input  var nexus::nexus_message_t             msg_in,
	input  var logic [$clog2(NEXUS_MAX_FIELDS):0] msg_num_fields,
	output logic [5:0]                            slice_bits,
	output logic                                  slice_valid,
	input  var logic                              slice_ready,
	output logic                                  slice_ends_field,
	output logic                                  slice_ends_variable_field,
	output logic                                  slice_last_padded,
	output logic                                  start_of_message,
	output logic                                  end_of_message
);
	ct_L2_mseo_mdo_formatter_bit_slicer_impl #(
		.NEXUS_MAX_FIELDS           (NEXUS_MAX_FIELDS),
		.NEXUS_MAX_FIELD_DATA_WIDTH (NEXUS_MAX_FIELD_DATA_WIDTH),
		.MDO_WIDTH                  (6)
	) u_impl (.*);
endmodule

module ct_L2_mseo_mdo_formatter_bit_slicer_mdo14 #(
	int unsigned NEXUS_MAX_FIELDS           = nexus_vendor::NEXUS_MAX_FIELDS,
	int unsigned NEXUS_MAX_FIELD_DATA_WIDTH = nexus_vendor::NEXUS_MAX_FIELD_DATA_WIDTH
) (
	input  var logic                              clk,
	input  var logic                              rst,
	input  var logic                              msg_valid,
	output logic                                  msg_ready,
	input  var nexus::nexus_message_t             msg_in,
	input  var logic [$clog2(NEXUS_MAX_FIELDS):0] msg_num_fields,
	output logic [13:0]                           slice_bits,
	output logic                                  slice_valid,
	input  var logic                              slice_ready,
	output logic                                  slice_ends_field,
	output logic                                  slice_ends_variable_field,
	output logic                                  slice_last_padded,
	output logic                                  start_of_message,
	output logic                                  end_of_message
);
	ct_L2_mseo_mdo_formatter_bit_slicer_impl #(
		.NEXUS_MAX_FIELDS           (NEXUS_MAX_FIELDS),
		.NEXUS_MAX_FIELD_DATA_WIDTH (NEXUS_MAX_FIELD_DATA_WIDTH),
		.MDO_WIDTH                  (14)
	) u_impl (.*);
endmodule

module ct_L2_mseo_mdo_formatter_bit_slicer #(
	int unsigned NEXUS_MAX_FIELDS           = nexus_vendor::NEXUS_MAX_FIELDS,
	int unsigned NEXUS_MAX_FIELD_DATA_WIDTH = nexus_vendor::NEXUS_MAX_FIELD_DATA_WIDTH,
	int unsigned MDO_WIDTH                  = 6
) (
	input  var logic                              clk,
	input  var logic                              rst,
	input  var logic                              msg_valid,
	output logic                                  msg_ready,
	input  var nexus::nexus_message_t             msg_in,
	input  var logic [$clog2(NEXUS_MAX_FIELDS):0] msg_num_fields,
	output logic [MDO_WIDTH-1:0]                  slice_bits,
	output logic                                  slice_valid,
	input  var logic                              slice_ready,
	output logic                                  slice_ends_field,
	output logic                                  slice_ends_variable_field,
	output logic                                  slice_last_padded,
	output logic                                  start_of_message,
	output logic                                  end_of_message
);
	if (MDO_WIDTH == 6) begin : genMdo6
		ct_L2_mseo_mdo_formatter_bit_slicer_mdo6 #(
			.NEXUS_MAX_FIELDS           (NEXUS_MAX_FIELDS),
			.NEXUS_MAX_FIELD_DATA_WIDTH (NEXUS_MAX_FIELD_DATA_WIDTH)
		) u_slicer (.*);
	end
	else if (MDO_WIDTH == 14) begin : genMdo14
		ct_L2_mseo_mdo_formatter_bit_slicer_mdo14 #(
			.NEXUS_MAX_FIELDS           (NEXUS_MAX_FIELDS),
			.NEXUS_MAX_FIELD_DATA_WIDTH (NEXUS_MAX_FIELD_DATA_WIDTH)
		) u_slicer (.*);
	end
	else begin : genUnsupported
		// MDO=30 (and any other width) intentionally removed (2026-07-19):
		// no product configuration uses it and dropping it keeps the two
		// remaining widths as explicitly bound, hard-wired modules.
		$fatal(1, "ct_L2_mseo_mdo_formatter_bit_slicer: MDO_WIDTH=%0d not supported (6 and 14 only; 30 removed 2026-07-19)", MDO_WIDTH);
	end
endmodule

`default_nettype wire
