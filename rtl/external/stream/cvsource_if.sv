// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab
/**
 * Copyright (c) 2020 by Accemic Technologies GmbH Kiefersfelden Germany
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * @brief	Generic interface for a counted vector source
 *          with acknowledge for the whole vector.
 *
 * @author	Thomas B. Preußer <tpreusser@accemic.com>
 */
interface cvsource_if #(type T = logic[7:0], int unsigned P)();

	// Basic Source Interface with Backpressure Capability
	typedef logic [$clog2(P+1)-1:0]  cnt_t;
	T [P-1:0]  q;
	cnt_t      cnt;
	logic      ack;

	// Implementation View
	modport impl (
		output q, output cnt, input ack
	);

	// Client View
	modport client (
		input q, input cnt, output ack
	);

endinterface : cvsource_if
