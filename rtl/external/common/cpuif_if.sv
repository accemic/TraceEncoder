// -*- indent-tabs-mode:t; tab-width:4 -*-
// vim: tabstop=4:noexpandtab
/**
 * Copyright (c) 2024 by Accemic Technologies GmbH Kiefersfelden Germany
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * @brief   PeakRDL Internal CPUIF Passthrough Interface
 * @note    Compatible with PeakRDL-regblock generated code using --cpuif passthrough
 * @author  Based on PeakRDL Internal CPUIF Protocol specification
 */

interface cpuif_if #(
	parameter DATA_WIDTH = 32,
	parameter ADDR_WIDTH = 32,
	parameter BITEN_WIDTH = DATA_WIDTH  // Bit-enable width (typically same as DATA_WIDTH)
);
	// Request signals
	logic                       req;
	logic [ADDR_WIDTH-1:0]      addr;
	logic                       req_is_wr;
	logic [DATA_WIDTH-1:0]      wr_data;
	logic [BITEN_WIDTH-1:0]     wr_biten;

	// Flow control (stall signals)
	logic                       req_stall_rd;
	logic                       req_stall_wr;

	// Response signals
	logic                       rd_ack;
	logic [DATA_WIDTH-1:0]      rd_data;
	logic                       rd_err;
	logic                       wr_ack;
	logic                       wr_err;

	// Master modport (e.g., bus bridge driving register block)
	modport master (
		output req,
		output addr,
		output req_is_wr,
		output wr_data,
		output wr_biten,

		input  req_stall_rd,
		input  req_stall_wr,

		input  rd_ack,
		input  rd_data,
		input  rd_err,
		input  wr_ack,
		input  wr_err
	);

	// Slave modport (e.g., PeakRDL-generated register block)
	modport slave (
		input  req,
		input  addr,
		input  req_is_wr,
		input  wr_data,
		input  wr_biten,

		output req_stall_rd,
		output req_stall_wr,

		output rd_ack,
		output rd_data,
		output rd_err,
		output wr_ack,
		output wr_err
	);

endinterface
