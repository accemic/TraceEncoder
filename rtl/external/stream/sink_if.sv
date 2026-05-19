// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab
/**
 * Copyright (c) 2018-2024 by Accemic Technologies GmbH Kiefersfelden Germany
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * This source code is provided by Accemic Technologies GmbH ("Accemic")
 * for evaluation purposes only and is distributed on an "as-is" basis
 * without warranties of any kind, either express or implied, including
 * but not limited to fitness for a particular purpose. Accemic retains
 * all intellectual property rights in this code.
 * This code is provided for non-commercial, educational, or internal
 * research purposes only. Any other use, including incorporation into
 * a commercial product, reproduction, distribution, or modification,
 * is strictly prohibited without prior written consent and an explicit
 * licensing agreement with Accemic.
 * By using this code, you acknowledge that any use beyond the limited
 * rights granted here will require a licensing agreement. Accemic will
 * not be liable for any damages arising from the use or misuse of this
 * code.
 *
 * @brief	Generic interface for a data sink.
 * @author	Thomas B. Preußer <tpreusser@accemic.com>
 *
 * @details
 *
 * The interface of a templated data sink providing an implementation
 * view (modport impl) and a client view (modport client).
 *
 * Implementations refuse further data input by asserting {ful}. Otherwise,
 * clients are able to submit new data items using the {wr/d} input pair.
 *
 * Implementations are encouraged to disclose the remaining available buffer
 * capacity before {ful} might have to be asserted. The interface leverages
 * this information to derive status signals such as "almost full" {afull}
 * for the client. The number of slots reported by the implementation is a
 * guarantee and may, as such, never be greater than the actually available
 * capacity. Simple implementations may choose to report fewer slots or even
 * the default of constantly zero (0). If provided a static ALMOST_THRESHOLD
 * can be configured to derive {afull}, and a dynamic availability test may
 * be performed through the have_available interface function.
 */

interface sink_if #(
	type T = logic [7:0],
	int unsigned ALMOST_THRESHOLD = 0,
	logic		 STOP_ON_OVERRUN  = 1
)(
	input uwire logic clk,
	input uwire logic rst
);

	// Basic Sink Interface with Backpressure Capability
	logic	full;
	T		d;
	logic	wr;

	// Derived Availability Status
	//	Notes: 	- Do NOT merge assignments.
	//			  Vivado wrongly trims the associated logic then (2018.1).
	//			- Leave status flags as uwires to lock out competing drivers.
	var int unsigned  cnt_avail;

	uwire	afull;
	assign	afull = cnt_avail < ALMOST_THRESHOLD;  // static

	function logic have_available(input int unsigned  threshold);
		return  threshold <= cnt_avail;
	endfunction // have_available

	// Overrun Detection
	logic	Overrun = 0;
	always_ff @(posedge clk) begin
		if(rst)  Overrun <= 0;
		else if(full && wr) begin
			Overrun <= 1;
			if(STOP_ON_OVERRUN) begin
				$display("ERROR: Sink overrun in Interface: %m");
				$stop;
			end
		end
	end

	// Implementation View
	modport impl (
		input  clk, input rst,
		output full, input d, input wr,
		output cnt_avail,
		input .overrun(Overrun),
		import have_available
	);

	// Client View
	modport client (
		input  clk, input rst,
		input full, output d, output wr,
		input afull,
		input .overrun(Overrun),
		input cnt_avail,
		import have_available
	);

endinterface : sink_if
