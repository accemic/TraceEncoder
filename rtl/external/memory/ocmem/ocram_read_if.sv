// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2018 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*/

/**
* @brief    OnChip RAM Read Interface
*
* @details  Generic Read Interface for a synchronous OnChip RAM comprising the a client (master) & slave (implementation) view
*
*           The client is required to provide the read address (`addr`) synchronous to the clock.
*           The Chip-Enable signal (`ce`) is high-active and must be enabled in this case.
*           The time until the requested data is available at the `q` port is implementation dependent.
*
* @author   Albert Schulz <aschulz@accemic.com>
*/
interface ocram_read_if #(
	/// Number of Address Bits
	int A_BITS,

	/// Type of Data which is read from RAM
	type T = logic [7:0]
) (
	input uwire logic clk
);

	/// Clock Enable: Indicates that the Address is valid to enable memory read
	logic ce;

	/// Clock Enable for (optional) additional output register
	logic regce;

	/// Address from which the data should be read
	logic [A_BITS-1:0] addr;

	/// Data which is read at Address `addr`
	T q;

	/// Client View
	modport client (
		output ce, output addr, output regce,
		input q
	);

	/// Implementation View
	modport impl (
		input clk,
		input ce, input addr, input regce,
		output q
	);

endinterface
