// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2018 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*/

/**
* @brief    OnChip RAM Write Interface
*
* @details  Generic Write Interface for a synchronous OnChip RAM comprising the a client (master) & slave (implementation) view
*
*           Client should provide data (`d`) and address (`addr`) in the same cycle.
*           Chip- & Write-Enable should be high-active and enabled during a write.
*
*           The implementing memory should make sure to write the data properly.
*           The time until the data can be read from the memory is implementation dependent.
*
* @author   Albert Schulz <aschulz@accemic.com>
*/
interface ocram_write_if #(
	/// Number of Address Bits
	int A_BITS,

	/// Type of Data which is written to RAM
	type T = logic[7:0]
) (
	input uwire logic clk
);
	/// Chip Enable: Indicates that the RAM should be enabled
	logic ce;

	/// Write Enable: Indicates the data `d` is valid and should be written to memory
	logic we;

	/// Address to which the data should be written
	logic [A_BITS-1:0] addr;

	/// Data which is written to Address `addr`
	T d;

	/// Client View
	modport client (
		output ce, output we, output addr,
		output d
	);

	/// Implementation View
	modport impl (
		input clk,
		input ce, input we, input addr, input d
	);

endinterface
