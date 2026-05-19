// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab
/**
 * Copyright (c) 2020 by Accemic Technologies GmbH Kiefersfelden Germany
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * @brief	Generic interface for a counted vector sink.
 * @author	Thomas B. Preußer <tpreusser@accemic.com>
 */
interface cvsink_if #(type T = logic[7:0], int unsigned P, bit STOP_ON_OVERRUN = 1)(
	input	logic clk,
	input	logic rst
);

	// Basic Sink Interface with Backpressure Capability
	typedef logic [$clog2(P+1)-1:0]  cnt_t;
	logic      full;
	T [P-1:0]  d;
	cnt_t      cnt;

	// Overrun Detection
	logic	Overrun = 0;
	always_ff @(posedge clk) begin
		if(rst)  Overrun <= 0;
		else if(cnt && full) begin
			Overrun <= 1;
			if(STOP_ON_OVERRUN) begin
				$display("ERROR: Sink overrun in Interface: %m");
				$stop;
			end
		end
	end

	// Implementation View
	modport impl (
		input clk, rst,
		output full, input d, input cnt,
		input Overrun
	);

	// Client View
	modport client (
		input clk, rst,
		input full, output d, output cnt,
		input Overrun
	);

endinterface : cvsink_if
