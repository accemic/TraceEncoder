// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab
/**
 * Copyright (c) 2019 by Accemic Technologies GmbH Kiefersfelden Germany
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * @brief	Clock-domain crossing for a strobed signal.
 * @author	Thomas B. Preußer <tpreusser@accemic.com>
 */
module strobe_cdc (

	// Source Clock Domain
	input	logic	clk1,
	input	logic	rst1,
	input	logic	stb1,

	// Destination Clock Domain
	input	logic	clk2,
	input	logic	rst2,
	output	logic	stb2
);

	// Src: Strobe to Edge
	logic Edge1 = 0;
	always_ff @(posedge clk1) Edge1 <= rst1? 0 : Edge1 ^ stb1;

	// Edge: Clock Domain Crossing
	uwire	edge2;
	signal_cdc sync_edge (.clk(clk2), .rst(rst2), .in(Edge1), .out(edge2));

	// Dst: Edge to Strobe
	logic Edge2 = 0;
	always_ff @(posedge clk2) Edge2 <= rst2? 0 : edge2;
	assign	stb2 = Edge2 ^ edge2;

endmodule : strobe_cdc
