// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief Nexus message bit-slicer for parallel AUX (MDO).
 * @author   Albert Schulz
 *
 * This module consumes a full `nexus_message_t` (already ordered list of fields)
 * and produces a per-cycle `slice_bits` word of width `MDO_WIDTH`.
 *
 * Key behaviors (IEEE-ISTO-5001-2012, Section 5):
 *  - Fields are transmitted LSB-first.
 *  - A single MDO slice may include bits from multiple *fixed* fields.
 *  - A variable-length field must end on a port boundary. If the last bit does
 *    not align, the remaining slice bits are zero-padded and the next field
 *    begins on the following cycle.
 */
module ct_L2_mseo_mdo_formatter_bit_slicer #(
	int unsigned NEXUS_MAX_FIELDS           = nexus_vendor::NEXUS_MAX_FIELDS,
	int unsigned NEXUS_MAX_FIELD_DATA_WIDTH = nexus_vendor::NEXUS_MAX_FIELD_DATA_WIDTH,
	int unsigned MDO_WIDTH                  = 4
) (
	input  var logic clk,
	input  var logic rst,

	// Message input (from message buffer)
	input  var logic                              msg_valid,
	output logic                                  msg_ready,
	input  var nexus::nexus_message_t             msg_in,
	input  var logic [$clog2(NEXUS_MAX_FIELDS):0] msg_num_fields,

	// Slice output
	output logic [MDO_WIDTH-1:0]                 slice_bits,
	output logic                                 slice_valid,
	input  var logic                             slice_ready,

	// Slice boundary indications
	output logic                                 slice_ends_field,
	output logic                                 slice_ends_variable_field,
	output logic                                 slice_last_padded,

	// Message boundary events
	output logic                                 start_of_message,
	output logic                                 end_of_message
);
	import nexus::*;

	typedef logic [$clog2(NEXUS_MAX_FIELDS):0] field_idx_t;
	typedef logic [$clog2(NEXUS_MAX_FIELD_DATA_WIDTH):0] rem_t;
	localparam int unsigned FIELD_ARR_IDX_W = (NEXUS_MAX_FIELDS > 1) ? $clog2(NEXUS_MAX_FIELDS) : 1;
	localparam int unsigned DATA_COPY_W =
		(MDO_WIDTH < NEXUS_MAX_FIELD_DATA_WIDTH) ? MDO_WIDTH : NEXUS_MAX_FIELD_DATA_WIDTH;
	localparam int unsigned ACC_POS_W = (MDO_WIDTH > 1) ? $clog2(MDO_WIDTH + 1) : 1;
	localparam int unsigned MAX_STEPS_PER_CYCLE = 2;
	typedef logic [ACC_POS_W-1:0] acc_pos_t;

	function automatic logic is_variable(input nexus_field_type_e t);
		return (t == nexus::VARIABLE) || (t == nexus::VENDOR_VARIABLE);
	endfunction

	function automatic logic [MDO_WIDTH-1:0] mdo_low_mask(input int unsigned nbits);
		logic [MDO_WIDTH-1:0] mask;
		if (nbits == 0) begin
			mask = '0;
		end else if (nbits >= MDO_WIDTH) begin
			mask = '1;
		end else begin
			mask = ({MDO_WIDTH{1'b1}} >> (MDO_WIDTH - nbits));
		end
		return mask;
	endfunction

	function automatic logic has_valid_field(
		input field_idx_t idx,
		input field_idx_t field_count,
		input nexus_message_t msg
	);
		if (idx >= field_count) begin
			return 1'b0;
		end
		return ((msg.fields[idx[FIELD_ARR_IDX_W-1:0]].field_type != nexus::FIELD_INVALID)
			&& (msg.fields[idx[FIELD_ARR_IDX_W-1:0]].data_width != '0));
	endfunction

	// --------------------------------------------------------------------
	// State
	// --------------------------------------------------------------------
	logic           Active = 1'b0;
	logic           StartOfMessage = 1'b0;
	field_idx_t     FieldIdx = '0;
	field_idx_t     FieldCount = '0;
	nexus_message_t Msg = '0;

	nexus_field_type_e CurType = nexus::FIELD_INVALID;
	logic [$clog2(NEXUS_MAX_FIELD_DATA_WIDTH):0] CurRem = '0;
	logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0]      CurData = '0;

	// One-entry output pipeline. This cuts the long combinational path from
	// current state (FieldCount/FieldIdx/CurData) into next state registers.
	logic [MDO_WIDTH-1:0]                       PipeSliceBits = '0;
	logic                                       PipeEndsField = 1'b0;
	logic                                       PipeEndsVariableField = 1'b0;
	logic                                       PipeLastPadded = 1'b0;
	logic                                       PipeEndOfMessage = 1'b0;
	logic                                       PipeDropActive = 1'b0;
	logic                                       PipeValid = 1'b0;

	// In-progress slice accumulation state.
	logic [MDO_WIDTH-1:0] AccBits = '0;
	acc_pos_t             AccPos = '0;
	logic                 AccEndedField = 1'b0;
	logic                 AccEndedVariableField = 1'b0;
	logic                 AccPadded = 1'b0;

	// Ready when idle.
	assign msg_ready                 = !Active;
	assign slice_valid               = PipeValid;
	assign slice_bits                = PipeSliceBits;
	assign slice_ends_field          = PipeEndsField;
	assign slice_ends_variable_field = PipeEndsVariableField;
	assign slice_last_padded         = PipeLastPadded;
	assign end_of_message            = PipeEndOfMessage;
	assign start_of_message          = StartOfMessage;

	// --------------------------------------------------------------------
	// Slice handshake
	// --------------------------------------------------------------------
	uwire slice_fire = slice_valid && slice_ready;

	// --------------------------------------------------------------------
	// Sequential state update and one-entry output pipeline.
	//
	// Architecture:
	// - Incrementally build one output slice in Acc* registers.
	// - Each cycle consumes up to MAX_STEPS_PER_CYCLE field-steps.
	//   This speculative continuation into the next field increases throughput
	//   for messages with many short fixed fields.
	// - Emit to Pipe* only when slice is complete or message ends.
	// --------------------------------------------------------------------
	always_ff @(posedge clk) begin
		if (rst) begin
			Active            <= 1'b0;
			FieldIdx          <= '0;
			FieldCount        <= '0;
			Msg               <= '0;
			CurType           <= nexus::FIELD_INVALID;
			CurRem            <= '0;
			CurData           <= '0;
			AccBits           <= '0;
			AccPos            <= '0;
			AccEndedField     <= 1'b0;
			AccEndedVariableField <= 1'b0;
			AccPadded         <= 1'b0;
			PipeSliceBits     <= '0;
			PipeEndsField     <= 1'b0;
			PipeEndsVariableField <= 1'b0;
			PipeLastPadded    <= 1'b0;
			PipeEndOfMessage  <= 1'b0;
			PipeDropActive    <= 1'b0;
			PipeValid         <= 1'b0;
			StartOfMessage    <= 1'b0;
		end else begin
			StartOfMessage <= 1'b0;

			if (msg_valid && msg_ready) begin
				Msg        <= msg_in;
				FieldCount <= msg_num_fields;
				FieldIdx   <= '0;
				Active     <= 1'b1;
				CurType    <= msg_in.fields[0].field_type;
				CurRem     <= msg_in.fields[0].data_width;
				CurData    <= msg_in.fields[0].data;
				AccBits    <= '0;
				AccPos     <= '0;
				AccEndedField <= 1'b0;
				AccEndedVariableField <= 1'b0;
				AccPadded  <= 1'b0;
				PipeValid  <= 1'b0;
				StartOfMessage <= 1'b1;
			end else begin
				if (slice_fire) begin
					PipeValid <= 1'b0;
					if (PipeDropActive) begin
						Active   <= 1'b0;
						FieldIdx <= '0;
						CurRem   <= '0;
						CurData  <= '0;
						CurType  <= nexus::FIELD_INVALID;
						AccBits  <= '0;
						AccPos   <= '0;
						AccEndedField <= 1'b0;
						AccEndedVariableField <= 1'b0;
						AccPadded <= 1'b0;
					end
				end

				// Build when active and no pending output slice.
				// Also allow a same-cycle pop+build when the current slice is consumed,
				// so we avoid a fixed bubble on every accepted output beat.
				if (Active && (!PipeValid || (slice_fire && !PipeDropActive))) begin
					field_idx_t        idx;
					field_idx_t        cand_idx;
					field_idx_t        check_idx;
					int unsigned       step_i;
					nexus_field_type_e ftype;
					rem_t              rem;
					logic [NEXUS_MAX_FIELD_DATA_WIDTH-1:0] data;
					logic [MDO_WIDTH-1:0]                   acc_bits;
					acc_pos_t                                acc_pos;
					logic                                    acc_end_f;
					logic                                    acc_end_v;
					logic                                    acc_padded;
					logic                                    no_more_fields;
					logic                                    emit_slice;
					logic [MDO_WIDTH-1:0]                   part_bits;
					logic [MDO_WIDTH-1:0]                   part_mask;
					int unsigned                             avail_i;
					int unsigned                             take_i;
					logic                                    stop_steps;

					idx            = FieldIdx;
					ftype          = CurType;
					rem            = CurRem;
					data           = CurData;
					acc_bits       = AccBits;
					acc_pos        = AccPos;
					acc_end_f      = AccEndedField;
					acc_end_v      = AccEndedVariableField;
					acc_padded     = AccPadded;
					no_more_fields = 1'b0;
					stop_steps     = 1'b0;

					for (step_i = 0; step_i < MAX_STEPS_PER_CYCLE; step_i++) begin
						if (!stop_steps && (acc_pos < acc_pos_t'(MDO_WIDTH))) begin
							// Move to next field if current one is exhausted.
							if (rem == '0) begin
								cand_idx = idx + 1;
								if (!has_valid_field(cand_idx, FieldCount, Msg)) begin
									no_more_fields = 1'b1;
									stop_steps = 1'b1;
								end else begin
									// The previously ended field was internal to the
									// in-progress slice. Only the final boundary of the
									// emitted slice may drive the boundary flags.
									acc_end_f = 1'b0;
									acc_end_v = 1'b0;
									idx   = cand_idx;
									ftype = Msg.fields[cand_idx[FIELD_ARR_IDX_W-1:0]].field_type;
									rem   = Msg.fields[cand_idx[FIELD_ARR_IDX_W-1:0]].data_width;
									data  = Msg.fields[cand_idx[FIELD_ARR_IDX_W-1:0]].data;
								end
							end

							if (!stop_steps && !no_more_fields && (rem != '0)) begin
								avail_i = MDO_WIDTH - acc_pos;

								if (is_variable(ftype) && (rem < avail_i)) begin
									take_i = rem;
									part_mask = mdo_low_mask(take_i);
									part_bits = MDO_WIDTH'(data);
									part_bits &= part_mask;
									acc_bits |= (part_bits << acc_pos);

									data       = data >> take_i;
									rem        = '0;
									acc_end_f  = 1'b1;
									acc_end_v  = 1'b1;
									acc_padded = 1'b1;
									acc_pos    = acc_pos_t'(MDO_WIDTH);
									stop_steps = 1'b1;
								end else begin
									if (rem < avail_i) begin
										take_i = rem;
									end else begin
										take_i = avail_i;
									end

									part_mask = mdo_low_mask(take_i);
									part_bits = MDO_WIDTH'(data);
									part_bits &= part_mask;
									acc_bits |= (part_bits << acc_pos);

									data    = data >> take_i;
									rem     = rem - rem_t'(take_i);
									acc_pos = acc_pos + acc_pos_t'(take_i);

									if (rem == '0) begin
										acc_end_f = 1'b1;
										if (is_variable(ftype)) begin
											acc_end_v = 1'b1;
										end
									end
								end
							end
						end
					end

					// End-of-message detection after this step.
					if (!no_more_fields && (rem == '0)) begin
						check_idx = idx + 1;
						if (!has_valid_field(check_idx, FieldCount, Msg)) begin
							no_more_fields = 1'b1;
						end
					end

					emit_slice = ((acc_pos == acc_pos_t'(MDO_WIDTH))
						|| (no_more_fields && acc_end_f && (acc_pos != '0)));

					if (emit_slice) begin
						FieldIdx <= idx;
						CurType  <= ftype;
						CurRem   <= rem;
						CurData  <= data;

						PipeSliceBits         <= acc_bits;
						PipeEndsField         <= acc_end_f;
						PipeEndsVariableField <= acc_end_v;
						PipeLastPadded        <= acc_padded;
						PipeEndOfMessage      <= no_more_fields && acc_end_f;
						PipeDropActive        <= no_more_fields && acc_end_f;
						PipeValid             <= 1'b1;

						AccBits               <= '0;
						AccPos                <= '0;
						AccEndedField         <= 1'b0;
						AccEndedVariableField <= 1'b0;
						AccPadded             <= 1'b0;
					end else if (no_more_fields && (acc_pos == '0)) begin
						// Nothing left to emit.
						Active                <= 1'b0;
						FieldIdx              <= '0;
						CurType               <= nexus::FIELD_INVALID;
						CurRem                <= '0;
						CurData               <= '0;
						AccBits               <= '0;
						AccPos                <= '0;
						AccEndedField         <= 1'b0;
						AccEndedVariableField <= 1'b0;
						AccPadded             <= 1'b0;
					end else begin
						FieldIdx              <= idx;
						CurType               <= ftype;
						CurRem                <= rem;
						CurData               <= data;
						AccBits               <= acc_bits;
						AccPos                <= acc_pos;
						AccEndedField         <= acc_end_f;
						AccEndedVariableField <= acc_end_v;
						AccPadded             <= acc_padded;
					end
				end
			end
		end
	end

endmodule

`default_nettype wire
