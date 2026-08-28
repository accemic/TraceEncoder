// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief   Formal wrapper for the MDO/MSEO generation chain (P-MDO-1..7).
 *
 * @details
 *   Composite of the four proc-side stages of ct_L2_mseo_mdo_formatter —
 *   msg_buffer -> bit_slicer(MDO=6) -> mseo_controller(dual) ->
 *   atb_chunk_packer — glued EXACTLY as in the formatter top (the glue
 *   equations are copied 1:1 from ct_L2_mseo_mdo_formatter.sv @ 43f7be68;
 *   sv2v cannot pass the top's interface instances through two inlining
 *   levels, see formal/README.md). The CDC seam is modeled as an explicit
 *   occupancy queue with the real depth (8): `full` at capacity, drained
 *   by a free sink. NOT in scope of this gate (sim-covered): the CDC
 *   library FIFO itself, the ATB drive/flush-detect stage and the
 *   chain_empty/I8 path in the ATB domain.
 *
 *   Assumption budget (formal/README.md):
 *     ASM-MDO-1: reset in cycle 0.
 *     ASM-MDO-2: producer contract (nexus_formatter): contiguous valid
 *                fields, every valid field has data_width >= 1, message
 *                stable until accepted.
 *     ASM-MDO-3: bounded shape abstraction — <= 3 valid fields, each
 *                data_width <= 12, data above bit 15 zero (the slice
 *                datapath is width-generic; the bound keeps EOM latency
 *                inside BMC depth).
 *     ASM-MDO-4: seam model — ideal FWFT queue of depth 8 (the real
 *                ATB_CDC_FIFO_DEPTH); the library FIFO is a separately
 *                hardened component outside this gate.
 *
 *   Properties: P-MDO-1 MSEO legality (reserved 2'b10 never fired),
 *   P-MDO-2 encoding table (EOM=11, end-of-var=01, data=00; dual-pin,
 *   IEEE-ISTO-5001-2012 Table 5-1), P-MDO-3 conservation (accepted
 *   non-flush message <-> exactly one EOM), P-MDO-4 seam never overruns,
 *   P-MDO-5 beat alignment (no message starts mid-beat; lanes after an
 *   EOM lane are align pads), P-MDO-6 stall stability, P-MDO-7 flush
 *   isolation (marker beats only from idle path; a flush reaching the
 *   slicer would underflow the P-MDO-3 counter).
 */

`default_nettype none

module f_mdo_check (
	input wire logic        clk,
	input wire logic        rst,
	input wire logic        in_drain, // free sink behaviour at the seam
	// abstracted message input (3 fields; the rest is INVALID)
	input wire logic [2:0]  in_type0,
	input wire logic [2:0]  in_type1,
	input wire logic [2:0]  in_type2,
	input wire logic [7:0]  in_w0,
	input wire logic [7:0]  in_w1,
	input wire logic [7:0]  in_w2,
	input wire logic [15:0] in_d0,
	input wire logic [15:0] in_d1,
	input wire logic [15:0] in_d2,
	// Exported observers for the liveness top — PORTS, not hierarchical
	// references: yosys leaves module-instance XMRs silently unbound (the
	// documented phantom-signal trap; it bit this very gate's first
	// liveness formulation — f_lat ran against a free chk.m_diff).
	output wire logic [2:0] o_diff,
	output wire logic       o_eom_fire,
	output wire logic       o_past_valid
);
	import nexus::*;
	import nexus_vendor::*;

	localparam int unsigned MDO_W  = 6;                    // product config
	localparam int unsigned LANES  = 4;                    // ATDATA 32 / chunk 8
	localparam int unsigned DEPTH  = 8;                    // ATB_CDC_FIFO_DEPTH
	localparam int unsigned WFLD   = $clog2(NEXUS_MAX_FIELD_DATA_WIDTH) + 1;
	localparam int unsigned FCW    = $clog2(NEXUS_MAX_FIELDS) + 1;
	localparam logic [7:0]  LANE_PAD = 8'hFF;              // {6'h3F, MSEO 11}

	// ------------------------------------------------------------------
	// Message assembly (abstracted producer)
	// ------------------------------------------------------------------
	nexus_message_t f_msg;
	always_comb begin
		f_msg = '0;
		f_msg.fields[0].field_type = nexus_field_type_e'(in_type0);
		f_msg.fields[0].data_width = WFLD'(in_w0);
		f_msg.fields[0].data       = {{(NEXUS_MAX_FIELD_DATA_WIDTH-16){1'b0}}, in_d0};
		f_msg.fields[1].field_type = nexus_field_type_e'(in_type1);
		f_msg.fields[1].data_width = WFLD'(in_w1);
		f_msg.fields[1].data       = {{(NEXUS_MAX_FIELD_DATA_WIDTH-16){1'b0}}, in_d1};
		f_msg.fields[2].field_type = nexus_field_type_e'(in_type2);
		f_msg.fields[2].data_width = WFLD'(in_w2);
		f_msg.fields[2].data       = {{(NEXUS_MAX_FIELD_DATA_WIDTH-16){1'b0}}, in_d2};
	end

	uwire f_v0 = (nexus_field_type_e'(in_type0) != FIELD_INVALID);
	uwire f_v1 = (nexus_field_type_e'(in_type1) != FIELD_INVALID);
	uwire f_v2 = (nexus_field_type_e'(in_type2) != FIELD_INVALID);
	uwire f_in_is_flush = f_v0 && !f_v1
		&& (nexus_field_type_e'(in_type0) == FIXED)
		&& (in_d0[5:0] == 6'(NEXUS_MSG_FLUSH));

	// ------------------------------------------------------------------
	// Seam model (ASM-MDO-4): ideal FWFT occupancy of the CDC FIFO
	// ------------------------------------------------------------------
	logic [4:0] m_occ = '0;
	uwire       f_full = (m_occ >= 5'(DEPTH));
	uwire       f_atb_fire = (m_occ != '0) && in_drain;

	// ------------------------------------------------------------------
	// Generation chain: glue copied 1:1 from ct_L2_mseo_mdo_formatter
	// ------------------------------------------------------------------
	uwire logic msg_valid = (f_msg.fields[0].field_type != FIELD_INVALID);
	wire  logic msg_ready;

	logic [FCW-1:0] msg_num_fields;
	always_comb begin
		msg_num_fields = '0;
		for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
			if (f_msg.fields[i].field_type == FIELD_INVALID) break;
			msg_num_fields = msg_num_fields + 1'b1;
		end
	end

	wire logic           buf_valid;
	logic                buf_ready;
	nexus_message_t      buf_msg;
	wire logic [FCW-1:0] buf_num_fields;
	wire logic           slicer_msg_ready;
	wire logic [MDO_W-1:0] slice_bits;
	wire logic           slice_valid;
	wire logic           slice_ready;
	wire logic           slice_ends_field;
	wire logic           slice_ends_var;
	wire logic           slice_last_padded;
	wire logic           som_pulse;
	wire logic           eom_pulse;
	wire logic           stall_data;
	wire logic [1:0]     mseo_bits;
	wire logic           packer_idle;
	wire logic           packer_wr;
	wire logic [31:0]    packer_payload;

	uwire logic buf_is_flush = (buf_num_fields == 1)
		&& (buf_msg.fields[0].field_type == FIXED)
		&& (buf_msg.fields[0].data[($bits(nexus_tcode_e)-1):0] == NEXUS_MSG_FLUSH);
	uwire logic flush_ready = buf_valid
		&& buf_is_flush
		&& packer_idle
		&& !slice_valid
		&& !stall_data
		&& !f_full;
	uwire logic flush_start = buf_valid && buf_ready && buf_is_flush;
	uwire logic slice_fire  = slice_valid && slice_ready;
	uwire logic [MDO_W+1:0] out_chunk = {slice_bits, mseo_bits};
	always_comb buf_ready = buf_is_flush ? flush_ready : slicer_msg_ready;

	ct_L2_mseo_mdo_formatter_msg_buffer #(
		.NEXUS_MAX_FIELDS (NEXUS_MAX_FIELDS)
	) u_buf (
		.clk                (clk),
		.rst                (rst),
		.msg_valid          (msg_valid),
		.msg_ready          (msg_ready),
		.msg_in             (f_msg),
		.msg_num_fields     (msg_num_fields),
		.buf_valid          (buf_valid),
		.buf_ready          (buf_ready),
		.msg_out            (buf_msg),
		.msg_num_fields_out (buf_num_fields)
	);

	// NEXUS_MAX_FIELD_DATA_WIDTH=16 is part of ASM-MDO-3 (bounded shape,
	// fields <= 12 bits): the slice algorithm is width-generic; the full
	// 192-bit datapath only blows the SMT expression depth past the
	// solver frontend's parser limit (measured: nesting 2122).
	ct_L2_mseo_mdo_formatter_bit_slicer #(
		.NEXUS_MAX_FIELDS           (NEXUS_MAX_FIELDS),
		.NEXUS_MAX_FIELD_DATA_WIDTH (16),
		.MDO_WIDTH                  (MDO_W)
	) u_slicer (
		.clk                       (clk),
		.rst                       (rst),
		.msg_valid                 (buf_valid && !buf_is_flush),
		.msg_ready                 (slicer_msg_ready),
		.msg_in                    (buf_msg),
		.msg_num_fields            (buf_num_fields),
		.slice_bits                (slice_bits),
		.slice_valid               (slice_valid),
		.slice_ready               (slice_ready),
		.slice_ends_field          (slice_ends_field),
		.slice_ends_variable_field (slice_ends_var),
		.slice_last_padded         (slice_last_padded),
		.start_of_message          (som_pulse),
		.end_of_message            (eom_pulse)
	);

	ct_L2_mseo_mdo_formatter_mseo_controller #(
		.USE_DUAL_MSEO (1'b1),
		.MSEO_WIDTH    (2)
	) u_mseo (
		.clk                       (clk),
		.rst                       (rst),
		.start_of_message          (som_pulse),
		.end_of_message            (eom_pulse),
		.slice_valid               (slice_valid),
		.slice_fire                (slice_fire),
		.slice_ends_variable_field (slice_ends_var),
		.slice_ends_field          (slice_ends_field),
		.stall_data                (stall_data),
		.mseo_bits                 (mseo_bits)
	);

	ct_L2_mseo_mdo_formatter_atb_chunk_packer #(
		.NEXUS_MAX_FIELDS (NEXUS_MAX_FIELDS),
		.MDO_WIDTH        (MDO_W),
		.MSEO_WIDTH       (2)
	) u_chunk_packer (
		.clk            (clk),
		.rst            (rst),
		.atb_full       (f_full),
		.flush_start    (flush_start),
		.slice_valid    (slice_valid),
		.end_of_message (eom_pulse),
		.chunk_in       (out_chunk),
		.slice_ready    (slice_ready),
		.idle           (packer_idle),
		.wr             (packer_wr),
		.payload_out    (packer_payload)
	);

	uwire f_accept = msg_valid && msg_ready;

	// ------------------------------------------------------------------
	// Environment assumptions
	// ------------------------------------------------------------------
	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;
	always_comb if (!f_past_valid) assume (rst);   // ASM-MDO-1

	always_comb begin                              // ASM-MDO-2/3
		assume (in_type0 <= 3'(FIXED));
		assume (in_type1 <= 3'(FIXED));
		assume (in_type2 <= 3'(FIXED));
		if (f_v1) assume (f_v0);
		if (f_v2) assume (f_v1);
		if (f_v0) assume ((in_w0 >= 1) && (in_w0 <= 12));
		if (f_v1) assume ((in_w1 >= 1) && (in_w1 <= 12));
		if (f_v2) assume ((in_w2 >= 1) && (in_w2 <= 12));
	end

	logic        p_stall_q = 1'b0;
	logic [80:0] p_shape_q = '0;
	uwire [80:0] f_shape = {in_type0, in_type1, in_type2,
	                        in_w0, in_w1, in_w2, in_d0, in_d1, in_d2};
	always_ff @(posedge clk) begin
		p_stall_q <= msg_valid && !msg_ready && !rst;
		p_shape_q <= f_shape;
	end
	always_comb if (f_past_valid && p_stall_q) assume (f_shape == p_shape_q);

	// ------------------------------------------------------------------
	// Helper state
	// ------------------------------------------------------------------
	logic p_rst_q = 1'b1;
	logic [2:0] m_diff = '0;        // accepted non-flush msgs minus EOMs
	logic m_slice_active = 1'b0;    // SOM/EOM pairing
	logic       p_stalled_q = 1'b0; // slice stall shadows
	logic [5:0] p_bits_q = '0;
	logic [2:0] p_flags_q = '0;

	always_ff @(posedge clk) begin
		p_rst_q <= rst;
		if (rst) begin
			m_diff         <= '0;
			m_slice_active <= 1'b0;
			m_occ          <= '0;
		end
		else begin
			m_diff <= m_diff + 3'(f_accept && !f_in_is_flush)
			                 - 3'(slice_fire && eom_pulse);
			if (som_pulse)                       m_slice_active <= 1'b1;
			else if (slice_fire && eom_pulse)    m_slice_active <= 1'b0;
			m_occ <= m_occ + 5'(packer_wr) - 5'(f_atb_fire);
		end
		p_stalled_q <= slice_valid && !slice_ready && !rst;
		p_bits_q    <= slice_bits;
		p_flags_q   <= {eom_pulse, slice_ends_var, slice_ends_field};
	end

	// ------------------------------------------------------------------
	// Assertions
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (f_past_valid && !p_rst_q && !rst) begin
			// P-MDO-1/2 — MSEO legality + dual-pin encoding table
			if (slice_fire) begin
				assert (mseo_bits != 2'b10);                           // A_mseo_legal
				if (eom_pulse)           begin assert (mseo_bits == 2'b11); end // A_mseo_eom
				else if (slice_ends_var) begin assert (mseo_bits == 2'b01); end // A_mseo_eovf
				else                     begin assert (mseo_bits == 2'b00); end // A_mseo_data
			end

			// P-MDO-3 — conservation
			assert (m_diff != 3'b111);                                 // A_conserve_underflow
			assert (m_diff <= 3'd2);                                   // A_conserve_bound
			assert (!(som_pulse && m_slice_active));                   // A_som_nested
			if (slice_fire && eom_pulse)
				assert (m_slice_active);                               // A_eom_needs_som

			// P-MDO-4 — seam never overruns (model full at DEPTH=8)
			assert (m_occ <= 5'(DEPTH));                               // A_sink_occ
			assert (!(packer_wr && f_full));                           // A_sink_gate

			// P-MDO-5 — beat alignment
			if (packer_wr) begin
				for (int li = 0; li < LANES - 1; li++) begin
					if (packer_payload[li*8 +: 2] == 2'b11) begin
						for (int lj = li + 1; lj < LANES; lj++)
							assert (packer_payload[lj*8 +: 8] == LANE_PAD); // A_beat_align
					end
				end
			end

			// P-MDO-6 — stall stability
			if (p_stalled_q) begin
				assert (slice_valid);                                  // A_stall_valid
				assert (slice_bits == p_bits_q);                       // A_stall_bits
				assert ({eom_pulse, slice_ends_var, slice_ends_field} == p_flags_q); // A_stall_flags
			end

			// P-MDO-7 — flush isolation
			if (flush_start)
				assert (packer_idle && !slice_valid);                  // A_flush_idle
		end
	end

	assign o_diff       = m_diff;
	assign o_eom_fire   = slice_fire && eom_pulse;
	assign o_past_valid = f_past_valid;

	// ------------------------------------------------------------------
	// Cover (non-vacuity witnesses)
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (f_past_valid && !p_rst_q && !rst) begin
			cover (slice_fire && eom_pulse);                           // C_eom
			cover (slice_fire && !eom_pulse && slice_ends_var);        // C_var_end
			cover (packer_wr && (packer_payload[1:0] == 2'b11)
			       && (packer_payload[15:8] == LANE_PAD));             // C_eom_unaligned_pad
			cover (flush_start);                                       // C_flush
			cover (m_diff == 3'd2);                                    // C_diff2
			cover (p_stalled_q && slice_valid);                        // C_stall
			cover (f_accept && f_v2);                                  // C_three_fields
			cover (f_full);                                            // C_seam_full
		end
	end

endmodule : f_mdo_check


// Bounded-liveness top: free-flowing seam (in_drain=1) — every accepted
// message completes within 64 cycles (EOM emitted, counter drains).
module f_mdo_live (
	input wire logic        clk,
	input wire logic        rst,
	input wire logic [2:0]  in_type0,
	input wire logic [2:0]  in_type1,
	input wire logic [2:0]  in_type2,
	input wire logic [7:0]  in_w0,
	input wire logic [7:0]  in_w1,
	input wire logic [7:0]  in_w2,
	input wire logic [15:0] in_d0,
	input wire logic [15:0] in_d1,
	input wire logic [15:0] in_d2
);
	wire logic [2:0] w_diff;
	wire logic       w_eom_fire;
	wire logic       w_past_valid;

	f_mdo_check chk (
		.clk          (clk),
		.rst          (rst),
		.in_drain     (1'b1),
		.in_type0     (in_type0),
		.in_type1     (in_type1),
		.in_type2     (in_type2),
		.in_w0        (in_w0),
		.in_w1        (in_w1),
		.in_w2        (in_w2),
		.in_d0        (in_d0),
		.in_d1        (in_d1),
		.in_d2        (in_d2),
		.o_diff       (w_diff),
		.o_eom_fire   (w_eom_fire),
		.o_past_valid (w_past_valid)
	);

	// No-starvation bound: while work is pending (w_diff != 0), the NEXT
	// end-of-message arrives within 64 cycles. (First formulation counted
	// the whole in-flight period — under a gapless back-to-back stream the
	// counter grew without any starvation; and its second formulation read
	// chk.* hierarchically — yosys left those references silently unbound,
	// the phantom-signal trap. Hence ports.)
	logic [7:0] f_lat = '0;
	always_ff @(posedge clk) begin
		if (rst || (w_diff == 3'd0) || w_eom_fire)
			f_lat <= '0;
		else
			f_lat <= f_lat + 1'b1;
	end
	always @(posedge clk) begin
		if (w_past_valid && !rst) begin
			assert (f_lat <= 8'd64);                                   // A_live_eom
			cover (f_lat > 8'd20);                                     // C_live_deep
		end
	end

endmodule : f_mdo_live

`default_nettype wire
