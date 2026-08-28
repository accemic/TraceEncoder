// SPDX-FileCopyrightText: 2018-2024 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @brief   Generic interface for a data source.
 * @author  Thomas B. Preußer <tpreusser@accemic.com>
 *
 * @details
 *
 * The interface of a templated data source providing an implementation
 * view (modport impl) and a client view (modport client).
 *
 * Implementations signal new data and its validity through the pair
 * {valid/empty, q}. Clients signal the consumption of the data by asserting
 * {ack} and are, thus, able to induce backpressure. The implementation must
 * hold a valid data output until {ack} has been asserted.
 *
 * Implementations are further encouraged to disclose the number of readily
 * available data items. The interface leverages this information to derive
 * status signals such as "almost empty" {aempty} for the client. The number of
 * items reported by the implementation is a guarantee and may, as such, never
 * be greater than the actually available number of items. Simple
 * implementations may choose to report fewer items or even the default of
 * constantly zero (0). If provided a static ALMOST_THRESHOLD can be configured
 * to derive {aempty}, and a dynamic availability test may be performed through
 * the have_available interface function.
 */

interface source_if #(
	type         T                = logic [7:0],
	int unsigned ALMOST_THRESHOLD = 0,
	logic        STOP_ON_UNDERRUN = 1
)(
	input uwire logic clk,
	input uwire logic rst
);

	// Basic Source Interface with Backpressure Capability
	logic   valid;
	T       q;
	logic   ack;

	// Derived Availability Status
	//  Notes:  - Do NOT merge assignments.
	//            Vivado wrongly trims the associated logic then (2018.1).
	//          - Leave the status flags as uwires to lock out competing drivers.
	var int unsigned  cnt_avail;

	uwire   empty;
	assign  empty = !valid;
	uwire   aempty;
	assign  aempty = cnt_avail < ALMOST_THRESHOLD;  // static

	function logic have_available(input int unsigned  threshold);
		return  threshold <= cnt_avail;
	endfunction // have_available

	// Underrun Detection
	logic   Underrun = 0;
	always_ff @(posedge clk) begin
		if(rst)  Underrun <= 0;
		else if(empty && ack) begin
			Underrun <= 1;
			if(STOP_ON_UNDERRUN) begin
				$display("ERROR: Source underrun in Interface: %m");
				$stop;
			end
		end
	end

	// Implementation View
	modport impl (
		input  clk, input rst,
		output valid, output q, input ack,
		output cnt_avail
	);

	// Client View
	modport client (
		input  clk, input rst,
		input valid, input q, output ack,
		input empty, input aempty,
		input Underrun,
		input cnt_avail,
		import have_available
	);

endinterface : source_if
