// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    PIB trace sink: parallel off-chip trace port for the
 *           (funnel-merged) N-Trace byte stream.
 *
 * @details
 *   Additive observer like ct_soc_ddr_sink -- never back-pressures the trace
 *   path; overflow of the small internal FIFO drops whole beats (counted).
 *
 *   Wire format (5 pins, PMOD): matches the CTTE reference PIB in
 *   trPibMode = PIB_PAR_4 "4-bit DDR" (ct_pib.adoc / RISC-V Trace Control
 *   Interface spec 148 ch. 9) so the existing KR260 PMOD adapter of the
 *   reference implementation can be used 1:1. No frame pin -- receivers
 *   align on the all-ones idle between messages (Nexus MSEO structure),
 *   exactly like the reference.
 *     pib_clk    forwarded source-synchronous port clock, period =
 *                2^(div_i+1) core clocks (div_i=1 @75 MHz -> 18.75 MHz)
 *     pib_data   TRC_DATA[3:0], LSB first (TRC_DATA[0] = LSB): LOW nibble
 *                of each byte is stable around the RISING pib_clk edge,
 *                HIGH nibble around the FALLING edge (each nibble driven a
 *                half period, toggling at the opposite edge -> half-period
 *                setup/hold)
 *
 *   Bytes are emitted in ATB beat order, byte 0 = bits [7:0] first (the same
 *   order CTTD consumes from the URAM ring), so a captured PIB stream is
 *   byte-identical to the ring content. Idle: pib_clk keeps running while
 *   enable_i=1 (receivers can lock), pib_data holds 0xF (all-ones idle).
 *
 *   Calibration (calib_i=1, reference trPibCalibrate/trPibCalibPattern):
 *   the port emits a repeating pattern instead of trace -- STANDARD
 *   (AA 55 00 FF, spec table 55 for 4-bit), MOVING_ONE or MOVING_ZERO
 *   (walking set/cleared lane, one step per TRC_CLK edge) -- while the
 *   trace input is not consumed.
 *   frame_dbg (internal, no pin) marks the LOW-nibble half period of byte 0
 *   of each beat -- verification hook for the testbench monitor only.
 *
 *   div_i contract: >= 1 (port clock at most core/4) so nibble switching
 *   stays comfortably inside the core-clock raster. div_i=0 is clamped to 1.
 */
module ct_soc_pib #(
	int unsigned FIFO_WORDS = 64
) (
	input  uwire logic        clk,
	input  uwire logic        rst,

	input  uwire logic        enable_i,
	input  uwire logic        clear_i,      // pulse while enable_i=0: reset drops
	input  uwire logic [2:0]  div_i,        // port clock = clk / 2^(div+1), min 1
	input  uwire logic        calib_i,      // 1: emit calibration pattern, do not
	                                        //    consume trace (ref trPibCalibrate)
	input  uwire logic [1:0]  pattern_i,    // 0 STANDARD (AA 55 00 FF)
	                                        // 1 MOVING_ONE (walking 1 across lanes)
	                                        // 2 MOVING_ZERO (walking 0)

	input  uwire logic        beat_valid_i,
	input  uwire logic [31:0] beat_data_i,

	output logic [31:0]       drops_o,

	output logic              pib_clk,
	output logic [3:0]        pib_data
);

	// Verification-only beat-start marker (byte 0, LOW-nibble phase). Not a
	// pin: the KR260 adapter contract has no frame lane; the TB samples this
	// hierarchically.
	logic frame_dbg;

	localparam int unsigned AW = $clog2(FIFO_WORDS);

	uwire logic [2:0] div_eff = (div_i == 3'd0) ? 3'd1 : div_i;

	// ------------------------------------------------------------------
	// Beat FIFO
	// ------------------------------------------------------------------
	logic [31:0] fifo_mem [0:FIFO_WORDS-1];
	logic [AW:0] wr_ptr, rd_ptr;
	uwire logic [AW:0] fill = wr_ptr - rd_ptr;
	uwire logic fifo_full  = (fill == FIFO_WORDS[AW:0]);
	uwire logic fifo_empty = (fill == 0);

	uwire logic accept  = beat_valid_i && enable_i && !fifo_full;
	uwire logic dropped = beat_valid_i && enable_i && fifo_full;

	always_ff @(posedge clk) begin
		if (rst) begin
			wr_ptr <= '0;
		end
		else if (accept) begin
			fifo_mem[wr_ptr[AW-1:0]] <= beat_data_i;
			wr_ptr <= wr_ptr + 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// Port clock divider: half-period = 2^div_eff core clocks.
	// ------------------------------------------------------------------
	logic [7:0] divcnt;
	uwire logic [7:0] half = (8'd1 << div_eff);
	uwire logic half_tick = (divcnt == half - 1);

	always_ff @(posedge clk) begin
		if (rst || !enable_i) begin
			divcnt <= '0;
			pib_clk <= 1'b0;
		end
		else if (half_tick) begin
			divcnt <= '0;
			pib_clk <= ~pib_clk;
		end
		else divcnt <= divcnt + 1'b1;
	end

	// ------------------------------------------------------------------
	// Byte serializer. State advances at every half_tick that ENDS a half
	// period; the nibble for the NEXT half period is driven exactly then, so
	// it is stable for the whole half period around its sampling edge:
	//   next pib_clk phase = 1 (rising edge)  -> drive LOW nibble
	//   next pib_clk phase = 0 (falling edge) -> drive HIGH nibble
	// ------------------------------------------------------------------
	logic [31:0] shift_q;
	logic [1:0]  byte_ix;      // 0..3 within the beat
	logic        have_beat;
	logic        cur_low;      // 1 = currently driving LOW nibble (phase pib_clk=1)

	// Calibration pattern generator (reference PIB trPibCalibPattern): one
	// nibble per TRC_CLK edge. STANDARD = spec pattern AA 55 00 FF for the
	// 4-bit mode; MOVING_ONE/MOVING_ZERO walk a set/cleared lane across
	// TRC_DATA for scope/LA bring-up and de-skew.
	logic [2:0] pat_ix;
	function automatic logic [3:0] pat_nib(input logic [1:0] pat,
	                                       input logic [2:0] ix);
		case (pat)
			2'd1:    pat_nib = 4'b0001 << ix[1:0];        // MOVING_ONE
			2'd2:    pat_nib = ~(4'b0001 << ix[1:0]);     // MOVING_ZERO
			default: case (ix[2:1])                       // STANDARD AA 55 00 FF
				2'd0: pat_nib = 4'hA;
				2'd1: pat_nib = 4'h5;
				2'd2: pat_nib = 4'h0;
				2'd3: pat_nib = 4'hF;
			endcase
		endcase
	endfunction

	always_ff @(posedge clk) begin
		if (rst) begin
			rd_ptr <= '0;
			shift_q <= '0; byte_ix <= '0; have_beat <= 1'b0; cur_low <= 1'b0;
			pat_ix <= '0;
			pib_data <= 4'hF; frame_dbg <= 1'b0;
			drops_o <= '0;
		end
		else begin
			if (clear_i && !enable_i) drops_o <= '0;
			if (dropped && drops_o != 32'hFFFF_FFFF) drops_o <= drops_o + 1'b1;

			if (!enable_i) begin
				pib_data <= 4'hF; frame_dbg <= 1'b0;
				have_beat <= 1'b0; byte_ix <= '0; cur_low <= 1'b0;
				pat_ix <= '0;
				rd_ptr <= wr_ptr;              // drain while disabled
			end
			else if (calib_i && half_tick) begin
				// Calibration: continuous pattern, one nibble per edge; the
				// trace input is NOT consumed (FIFO holds, drops count).
				pib_data <= pat_nib(pattern_i, pat_ix);
				pat_ix <= pat_ix + 1'b1;
				frame_dbg <= 1'b0;
				have_beat <= 1'b0; byte_ix <= '0; cur_low <= 1'b0;
			end
			else if (half_tick) begin
				if (!pib_clk) begin
					// pib_clk is about to RISE -> drive a LOW nibble now
					if (!have_beat) begin
						if (!fifo_empty) begin
							shift_q <= fifo_mem[rd_ptr[AW-1:0]];
							rd_ptr <= rd_ptr + 1'b1;
							have_beat <= 1'b1;
							byte_ix <= 2'd0;
							pib_data <= fifo_mem[rd_ptr[AW-1:0]][3:0];
							frame_dbg <= 1'b1;             // byte 0 marker
							cur_low <= 1'b1;
						end
						else begin
							pib_data <= 4'hF;              // idle
							frame_dbg <= 1'b0;
							cur_low <= 1'b0;
						end
					end
					else begin
						pib_data <= shift_q[8*byte_ix +: 4];
						frame_dbg <= (byte_ix == 2'd0);
						cur_low <= 1'b1;
					end
				end
				else begin
					// pib_clk is about to FALL -> drive the HIGH nibble
					if (cur_low) begin
						pib_data <= shift_q[8*byte_ix + 4 +: 4];
						frame_dbg <= 1'b0;
						cur_low <= 1'b0;
						if (byte_ix == 2'd3) begin
							have_beat <= 1'b0;
							byte_ix <= 2'd0;
						end
						else byte_ix <= byte_ix + 1'b1;
					end
					else begin
						pib_data <= 4'hF;                  // idle high phase
						frame_dbg <= 1'b0;
					end
				end
			end
		end
	end

endmodule

`default_nettype wire
