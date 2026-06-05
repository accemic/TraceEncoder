// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab
/**
 * Copyright (c) 2019 by Accemic Technologies GmbH Kiefersfelden Germany
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * @brief	2-FF clock-domain crossing for a slow-changing sampled single bit.
 * @author	Alexander Lange <alange@accemic.com>
 * @author	Thomas B. Preußer <tpreusser@accemic.com>
 */
module signal_cdc #(
	logic INIT = 1'b0
)(
	input	logic clk,
	input	logic rst,
	input	logic in,
	output	logic out
);

	(* ASYNC_REG = "TRUE" *)(* SHREG_EXTRACT = "NO" *)
	logic [1:0]	Sync = {2{INIT}};
	always_ff @(posedge clk)	Sync <= rst? {2{INIT}} : { in, Sync[1] };
	assign	out = Sync[0];

endmodule : signal_cdc
