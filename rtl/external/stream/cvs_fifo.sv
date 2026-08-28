// SPDX-FileCopyrightText: 2020 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @author  Thomas B. Preußer <tpreusser@accemic.com>
 *
 * @brief   A compacting FIFO for a counted vector stream.
 * @details
 *  Implements a FIFO capable to buffer data in the presence of backpressure.
 *
 *  If any data has been input to the FIFO, it will eventually be offered
 *  on the source side unconditionally and possibly as a partially utilized
 *  vector.
 *
 *  Under the presence of backpressure, the input data will be compacted
 *  before resorting to the backing memory. This memory will only contain
 *  compact data so as to provide a predictable buffer capacity of
 *  P*MIN_DEPTH data items.
 *
 * @example
 *  T = byte; P = 4; MIN_DEPTH > 1
 *
 *        Input          Output Offer   Ack
 *  ---------------------------------------------------------
 *  |       $01 00 |   |       $01 00 | 1 - take from bypass
 *  |             $|   |             $| x
 *  |          $02 |   |          $02 | 0
 *  | $06 05 04 03 |   | $05 04 03 02 | 1 - take from bypass
 *  |       $08 07 |   |    $08 07 06 | 0
 *  | $0C 0B 0A 09 |   | $09 08 07 06 | 0 - push to FIFO
 *  |          $0D |   |             $| x - push to FIFO
 *  |          $0E |   | $09 08 07 06 | 1 - take from FIFO
 *  |             $|   | $0D 0C 0B 0A | 1 - take from FIFO
 *  |             $|   |          $0E | 1 - take from bypass
 *
 *    $ - end of right-aligned valid byte vector (as by associated count)
 */

module cvs_fifo #(
	type         T          = logic [7:0],
	int unsigned P, // Input parallelism
	int unsigned MIN_DEPTH,
	parameter    FIFO_STYLE = "auto"
)(
	input   logic                           clk,
	input   logic                           rst,

	cvsink_if.impl                          d,
	cvsource_if.impl                        q,

	output  logic [$clog2(MIN_DEPTH+1)-1:0] cnt_avail // Available Px T FIFO slots
);

	//-----------------------------------------------------------------------
	// Compacting Input Buffer
	//  - Capacity of 2*P-1 items.
	//  - Vector input is appended in each cycle without backpressure.
	//  - Any full prefix of P items is either acked directly or forced into
	//    the backing memory.
	T [2*P-2:0]             Buf = 'x;
	logic [$clog2(2*P)-1:0] Cnt =  0;
	logic  Push = 0;    // iff Cnt >= P: needs to go out or into FIFO

	uwire ack_fast;  // Direct ack bypassing the empty FIFO
	uwire fifo_full; // from Bypass FIFO

	// Load Buf with new items:
	//  - preserve cnt_chop items possibly shifted by P positions after Push
	//  - append rotated periodic pattern of input data beyond cnt_chop
	uwire [$clog2(P+1)-1:0] cnt_chop = (ack_fast && !Push)? 0 : Cnt%P;
	for(genvar  i = 0; i < P-1; i++) begin
		uwire T  mux[0:P-1];
		for(genvar  j = 0; j < P; j++)  assign  mux[j] = j <= i? d.d[i-j] : Buf[i+P];
		(* DIRECT_ENABLE = "YES" *) uwire  en = !fifo_full && ((cnt_chop <= i) || Push);
		always_ff @(posedge clk) begin
			if(en)  Buf[i] <= mux[cnt_chop];
		end
	end
	for(genvar  i = P-1; i <= 2*P-2; i++) begin
		uwire T  mux[0:P-1];
		for(genvar  j = 0; j < P; j++) begin
			assign  mux[j] = i-j < P? d.d[i-j] : 'x;
		end
		always_ff @(posedge clk) begin
			if (!fifo_full) Buf[i] <= mux[cnt_chop];    // never hold beyond first (P-1) items
		end
	end

	// Update Buffer Fill Count
	always_ff @(posedge clk) begin
		if(rst) begin
			Cnt  <=  0;
			Push <=  0;
		end
		else if (!fifo_full) begin
			// `var` here is not cosmetics but required by the LRM: a
			// declaration whose type comes from a type reference `type(...)`
			// carries NO implicit data type from which the lifetime class
			// could be derived -- IEEE 1800-2023 6.8 demands the explicit
			// `var` for that. Vivado tolerates leaving it out, LRM-strict
			// frontends do not: yosys-slang aborts with
			// "a type reference cannot be used in a variable declaration
			// without a preceeding 'var' keyword" -- the only genuine source
			// defect in the whole encoder (2026-08-08, while setting up the
			// ASIC area flow).
			// Mind the order: `var` MUST come before `automatic`.
			// Nothing changes semantically -- an automatic variable in a
			// procedural block, as before.
			var automatic type(Cnt)  cnt_nxt = cnt_chop + d.cnt;
			Cnt  <= cnt_nxt;
			Push <= cnt_nxt >= P;
		end
	end

	//-----------------------------------------------------------------------
	// Bypass FIFO
	//  - only used when Push is required without having an ack
	//  - exclusively contains full compacted item vectors
	typedef T[P-1:0] fifo_t;

	// Write
	sink_if   #(.T(fifo_t)) fifo_d(.clk, .rst);
	assign  fifo_full = fifo_d.full;
	assign  fifo_d.wr = Push && !ack_fast && !fifo_d.full;
	assign  fifo_d.d  = Buf[P-1:0];
	assign  d.full    = fifo_d.full;
	always_ff @(posedge clk iff !rst) begin
		assert(!fifo_d.Overrun) else begin
			$error("Internal FIFO overrun must not occur without external overrun.");
			$stop;
		end
		assert(d.cnt <= P) else begin
			$error("Trying to write more items than possible: %0d. Must be less or equal %0d. %m", d.cnt, P);
			$stop;
		end
	end
	assign  cnt_avail = fifo_d.cnt_avail;

	// Backing FIFO
	source_if #(.T(fifo_t)) fifo_q(.clk, .rst);
	fifo1clk_fwft #(
		.T(fifo_t),
		.DATA_WIDTH(P*$bits(T)),
		.MIN_DEPTH(MIN_DEPTH),
		.FIFO_STYLE(FIFO_STYLE)
	) fifo (
		.d(fifo_d), .q(fifo_q)
	);

	// Track exact FIFO use without any availability latency
	logic [$clog2(MIN_DEPTH+1)+1:0] FifoCnt = 0;    // neg. count, sign bit -> non-zero
	uwire fifo_empty = !FifoCnt[$left(FifoCnt)];
	always_ff @(posedge clk) begin
		if(rst) begin
			FifoCnt <= 0;
		end
		else if(fifo_d.wr != fifo_q.ack) begin
			FifoCnt <= FifoCnt + (fifo_q.ack? 1 : -1);
		end
	end

	// Readout selection: bypass from input register vs. FIFO
	assign  q.cnt = fifo_empty? (Push? P : Cnt%P) : (fifo_q.valid? P : 0);
	assign  q.q   = fifo_empty? Buf[P-1:0] : fifo_q.q;
	assign  fifo_q.ack  = q.ack && fifo_q.valid; // tolerate Acks for cnt == 0
	assign  ack_fast    = q.ack && fifo_empty;

endmodule : cvs_fifo
