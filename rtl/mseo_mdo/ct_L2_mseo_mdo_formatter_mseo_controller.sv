// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief Generates MSEO patterns and stalls data slices during control-only
 *        cycles required by IEEE-ISTO-5001-2012 Section 5.
 *
 * Single-pin MSEO sequences (Table 5-1):
 *  - Idle: 1
 *  - Start of message: 1,1,0
 *  - End of variable-length packet: 0,1,0
 *  - End of message: 0,1,1,1,1,...
 *
 * Dual-pin MSEO sequences (Table 5-1):
 *  - Idle: 11
 *  - Start of message: 11 -> 00
 *  - End of variable-length packet: 00 -> 01
 *  - End of message: 00 or 01 -> 11
 */
module ct_L2_mseo_mdo_formatter_mseo_controller #(
	parameter bit          USE_DUAL_MSEO = 1'b0,
	parameter int unsigned MSEO_WIDTH    = (USE_DUAL_MSEO ? 2 : 1)
) (
	input  var logic clk,
	input  var logic rst,

	input  var logic start_of_message,
	input  var logic end_of_message,

	input  var logic slice_valid,
	input  var logic slice_fire,
	input  var logic slice_ends_variable_field,
	input  var logic slice_ends_field,

	output logic                 stall_data,
	output logic [MSEO_WIDTH-1:0] mseo_bits
);
	typedef enum logic [2:0] {
		S_IDLE        = 3'd0,
		// single-pin start sequence: 1,1,0
		S_SOM_1       = 3'd1,
		S_SOM_2       = 3'd2,
		S_IN_MSG      = 3'd3,
		// single-pin insert 1 after 0 to form 0,1,0 (end packet) or 0,1,1 (end msg)
		S_CTRL_1      = 3'd4,
		// single-pin insert final 0 for end-of-packet
		S_EOP_0       = 3'd5
	} state_e;

	state_e State = S_IDLE;
	logic   PendingEop = 1'b0;
	logic   PendingEom = 1'b0;

		generate
			if (USE_DUAL_MSEO) begin : gen_dual
				always_comb begin
					stall_data = 1'b0;
					mseo_bits  = 2'b11; // idle

					// Dual-pin has no extra control-only cycles. Real data slices carry:
					// - 00 for normal in-message chunks
					// - 01 when a variable-length field ends but the message continues
					// - 11 on the final chunk of a message
					//
					// Using 11 on the last chunk keeps the stream compatible with the
					// external Nexus decoders used in this repo, which terminate the
					// current packet as soon as they see END_IDLE after a variable field.
					if (State == S_IN_MSG) begin
						if (slice_valid && end_of_message) begin
							mseo_bits = 2'b11;
						end
						else if (slice_valid && slice_ends_variable_field) begin
							mseo_bits = 2'b01;
						end
						else begin
							mseo_bits = 2'b00;
						end
					end
				end
			end else begin : gen_single
			always_comb begin
				stall_data = 1'b0;
				mseo_bits  = 1'b1; // default idle

				unique case (State)
					S_IDLE:   begin mseo_bits = 1'b1; end
					S_SOM_1:  begin mseo_bits = 1'b1; stall_data = 1'b1; end
					S_SOM_2:  begin mseo_bits = 1'b1; stall_data = 1'b1; end
					S_IN_MSG: begin mseo_bits = 1'b0; end
					S_CTRL_1: begin mseo_bits = 1'b1; stall_data = 1'b1; end
					S_EOP_0:  begin mseo_bits = 1'b0; stall_data = 1'b1; end
					default: begin mseo_bits = 1'b1; end
				endcase
			end
		end
	endgenerate

	always_ff @(posedge clk) begin
		if (rst) begin
			State       <= S_IDLE;
			PendingEop <= 1'b0;
			PendingEom <= 1'b0;
		end else begin
			// Latch pending end events on the cycle where the data slice is emitted.
			if (!USE_DUAL_MSEO) begin
				if (slice_fire && slice_ends_variable_field) PendingEop <= 1'b1;
				if (slice_fire && end_of_message)           PendingEom <= 1'b1;
			end

			unique case (State)
				S_IDLE: begin
					if (USE_DUAL_MSEO) begin
						if (start_of_message) State <= S_IN_MSG;
					end else begin
						// Start pattern 1,1,0 => two idle-like cycles then enter IN_MSG.
						if (start_of_message) State <= S_SOM_1;
					end
				end

				S_SOM_1: State <= S_SOM_2;
				S_SOM_2: State <= S_IN_MSG;

				S_IN_MSG: begin
					if (USE_DUAL_MSEO) begin
						// Dual-pin: end-of-message is simply the first idle cycle after data.
						if (slice_fire && end_of_message) State <= S_IDLE;
					end else begin
						// For single-pin, if a slice ended var-field or message, insert control cycles.
						if (PendingEop || PendingEom) State <= S_CTRL_1;
					end
				end

				S_CTRL_1: begin
					// This cycle is the middle '1' of both 0,1,0 and 0,1,1.
					if (PendingEop) begin
						PendingEop <= 1'b0;
						State <= S_EOP_0;
					end else begin
						// End-of-message: after 0,1 we go to idle (idle provides the final '1').
						PendingEom <= 1'b0;
						State <= S_IDLE;
					end
				end

				S_EOP_0: begin
					// Finish 0,1,0 then return to streaming.
					State <= S_IN_MSG;
				end

				default: State <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
