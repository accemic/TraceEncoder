// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    signal_ack_lock_fsm.sv
 * @brief   Handshake-locked signal pulse with optional CDC.
 *
 * @details
 *   This module implements a handshake-locked pulse generator using a finite state machine.
 *   When the input signal (`in`) rises, the output (`out`) is asserted and remains high until an acknowledge (`ack`) is received.
 *   After `ack`, the module waits for the input to fall before resetting and readying for the next pulse.
 *   Optional clock domain crossing (CDC) can be enabled for the input using the `DO_CDC` parameter.
 *
 * @tparam DO_CDC         Enables input CDC processing if set (default: 0).
 *
 * @ports
 *   clk                  Clock input for synchronous operation.
 *   rst                  Asynchronous reset.
 *   in                   Input signal to trigger the lock.
 *   ack                  Acknowledge signal to deassert output.
 *   out                  Output pulse; asserted during handshake; deasserted after ack until in falls.
 *
 * @notes
 *   - The handshake ensures one output pulse per input activation.
 *   - Output remains high after input until acknowledgement and is reset only after input returns low.
 *   - CDC (clock domain crossing) logic for input is optional via `DO_CDC`.
 *   - Designed for robust, glitch-free handshaked signaling across clock domains as required.
 */

module signal_ack_lock_fsm #(
	logic DO_CDC = 1'b0
)(
	input   logic clk,
	input   logic rst,
	input   logic in,
	input   logic ack,
	output  uwire out
);

	// CDC block if enabled
	uwire in_cdc;
	logic Out;

	generate
	if (DO_CDC) begin
		signal_cdc #() signal_cdc_inst (
			.clk (clk),
			.rst (rst),
			.in  (in),
			.out (in_cdc)
		);
	end else begin
		assign in_cdc = in;
	end
	endgenerate

	// FSM states
	typedef enum logic [1:0] {
		S_IDLE          = 2'd0,
		S_WAIT_ACK      = 2'd1,
		S_WAIT_RELEASE  = 2'd2
	} state_t;

	state_t State;

	// State register
	always_ff @(posedge clk) begin
		if (rst) begin
			State <= S_IDLE;
			Out   <= 1'b0;
		end
		else begin
			case (State)
				S_IDLE: begin
					if (in_cdc) begin
						State <= S_WAIT_ACK;
						Out   <= 1'b1;
					end
				end
				S_WAIT_ACK: begin
					if (ack) begin
						State <= S_WAIT_RELEASE;
						Out   <= 1'b0;
					end
				end
				S_WAIT_RELEASE: begin
					if (!in_cdc) begin
						State <= S_IDLE;
					end
				end
				default: begin
					State <= S_IDLE;
					Out   <= 1'b0;
				end
			endcase
		end
	end

	assign out = Out;

endmodule : signal_ack_lock_fsm
