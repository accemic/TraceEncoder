// SPDX-FileCopyrightText: 2024 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @brief   Wishbone to PeakRDL CPUIF Passthrough Bridge
 * @note    Supports both combinatorial and sequential implementations
 *          Select via IMPLEMENTATION parameter: "COMB" or "SEQ"
 *          Uses individual signals (not interface) for CPUIF
 * @author  Based on PeakRDL Internal CPUIF Protocol specification
 */

module wb_to_cpuif #(
	parameter int    ADDR_WIDTH     = 32,
	parameter int    DATA_WIDTH     = 32,
	parameter string IMPLEMENTATION = "SEQ" // "COMB" or "SEQ"
)
(
	input uwire logic                   clk,        // Required for SEQ, unused for COMB
	input uwire logic                   rst,        // Required for SEQ, unused for COMB
	wb_if.slave                         wb,         // Wishbone Slave Interface

	// CPUIF Request signals (outputs from bridge)
	output logic                        s_cpuif_req,
	output logic                        s_cpuif_req_is_wr,
	output logic [ADDR_WIDTH-1:0]       s_cpuif_addr,
	output logic [DATA_WIDTH-1:0]       s_cpuif_wr_data,
	output logic [DATA_WIDTH-1:0]       s_cpuif_wr_biten,

	// CPUIF Flow control (inputs to bridge)
	input uwire logic                   s_cpuif_req_stall_wr,
	input uwire logic                   s_cpuif_req_stall_rd,

	// CPUIF Response signals (inputs to bridge)
	input uwire logic                   s_cpuif_rd_ack,
	input uwire logic                   s_cpuif_rd_err,
	input uwire logic [DATA_WIDTH-1:0]  s_cpuif_rd_data,
	input uwire logic                   s_cpuif_wr_ack,
	input uwire logic                   s_cpuif_wr_err
);

	//==========================================================================
	// Implementation Selection via Generate
	//==========================================================================

	generate
		if (IMPLEMENTATION == "COMB") begin : gen_comb_impl

			//------------------------------------------------------------------
			// COMBINATORIAL IMPLEMENTATION
			//------------------------------------------------------------------
			// NOTE: Only works if PeakRDL register block has 0-cycle response
			//       latency! For complex registers, use SEQ implementation.
			//------------------------------------------------------------------

			// Request mapping (combinatorial)
			assign s_cpuif_req        = wb.cyc && wb.stb;
			assign s_cpuif_addr       = wb.addr;
			assign s_cpuif_req_is_wr  = wb.we;
			assign s_cpuif_wr_data    = wb.data_m2s;

			// Convert Wishbone byte select to PeakRDL bit-enable
			always_comb begin
				for (int i = 0; i < DATA_WIDTH/8; i++) begin
					s_cpuif_wr_biten[i*8 +: 8] = {8{wb.sel[i]}};
				end
			end

			// Response mapping (combinatorial)
			// Assumes 0-cycle latency from PeakRDL!
			assign wb.ack       = s_cpuif_rd_ack | s_cpuif_wr_ack;
			assign wb.err       = s_cpuif_rd_err | s_cpuif_wr_err;
			assign wb.data_s2m  = s_cpuif_rd_data;

			// WARNING: Stall signals are ignored in combinatorial implementation!
			// If PeakRDL asserts stall, this will cause protocol violations.

		end else if (IMPLEMENTATION == "SEQ") begin : gen_seq_impl

			//------------------------------------------------------------------
			// SEQUENTIAL IMPLEMENTATION
			//------------------------------------------------------------------
			// Handles stalls and multi-cycle latency.
			// Compatible with all PeakRDL register types.
			//------------------------------------------------------------------

			// State machine
			typedef enum logic [1:0] {
				IDLE    = 2'b00,
				REQ     = 2'b01,
				WAIT    = 2'b10
			} state_t;

			state_t State, NextState;

			// Registered signals (PascalCase for non-blocking assignments)
			logic                       RegReqIsWr;
			logic [ADDR_WIDTH-1:0]      RegAddr;
			logic [DATA_WIDTH-1:0]      RegWrData;
			logic [DATA_WIDTH-1:0]      RegWrBiten;

			//------------------------------------------------------------------
			// State register
			//------------------------------------------------------------------
			always_ff @(posedge clk) begin
				if (rst) begin
					State <= IDLE;
				end else begin
					State <= NextState;
				end
			end

			//------------------------------------------------------------------
			// Capture Wishbone request signals
			//------------------------------------------------------------------
			always_ff @(posedge clk) begin
				if (rst) begin
					RegReqIsWr  <= '0;
					RegAddr     <= '0;
					RegWrData   <= '0;
					RegWrBiten  <= '0;
				end else if (State == IDLE && wb.cyc && wb.stb) begin
					RegReqIsWr  <= wb.we;
					RegAddr     <= wb.addr;
					RegWrData   <= wb.data_m2s;
					// Convert byte select to bit-enable
					for (int i = 0; i < DATA_WIDTH/8; i++) begin
						RegWrBiten[i*8 +: 8] <= {8{wb.sel[i]}};
					end
				end
			end

			//------------------------------------------------------------------
			// Check if request is stalled
			//------------------------------------------------------------------
			logic req_stalled;

			always_comb begin
				req_stalled = (RegReqIsWr && s_cpuif_req_stall_wr) ||
							  (!RegReqIsWr && s_cpuif_req_stall_rd);
			end

			//------------------------------------------------------------------
			// Next state logic
			//------------------------------------------------------------------
			always_comb begin
				NextState = State;

				case (State)
					IDLE: begin
						if (wb.cyc && wb.stb) begin
							NextState = REQ;
						end
					end

					REQ: begin
						// Stay in REQ if stalled
						if (req_stalled) begin
							NextState = REQ;
						end else begin
							// Request accepted, wait for response
							NextState = WAIT;
						end
					end

					WAIT: begin
						// Wait for ack
						if (s_cpuif_rd_ack || s_cpuif_wr_ack) begin
							NextState = IDLE;
						end
					end

					default: NextState = IDLE;
				endcase
			end

			//------------------------------------------------------------------
			// CPUIF request signals
			//------------------------------------------------------------------
			always_comb begin
				s_cpuif_req       = (State == REQ);
				s_cpuif_addr      = RegAddr;
				s_cpuif_req_is_wr = RegReqIsWr;
				s_cpuif_wr_data   = RegWrData;
				s_cpuif_wr_biten  = RegWrBiten;
			end

			//------------------------------------------------------------------
			// Wishbone response signals
			//------------------------------------------------------------------
			always_comb begin
				wb.ack      = (State == WAIT) && (s_cpuif_rd_ack | s_cpuif_wr_ack);
				wb.err      = (State == WAIT) && (s_cpuif_rd_err | s_cpuif_wr_err);
				wb.data_s2m = s_cpuif_rd_data;
			end

		end else begin : gen_invalid_impl

			//------------------------------------------------------------------
			// INVALID IMPLEMENTATION PARAMETER
			//------------------------------------------------------------------
			initial begin
				$error("Invalid IMPLEMENTATION parameter: '%s'. Must be 'COMB' or 'SEQ'.",
					   IMPLEMENTATION);
				$finish;
			end

		end
	endgenerate

endmodule
