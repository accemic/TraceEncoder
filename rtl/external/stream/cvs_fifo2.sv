// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2021 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    A compacting FIFO for a counted vector stream
*           which allows to acknowledge parts of the offered vector
*
* @author   Albert Schulz <aschulz@accemic.com>
*/
module cvs_fifo2 #(
	type			T = logic[7:0],
	int unsigned	P,               // Input parallelism
	int unsigned	PO = P,          // Output parallelism
	int unsigned	MIN_DEPTH,       // Number of P elements to buffer
	parameter		CVS_FIFO_STYLE = "auto"
)(
	input	uwire	clk,
	input	uwire	rst,

	cvsink_if.impl		d,
	cvsource_if2.impl	q,

	output	uwire [$clog2(MIN_DEPTH+1)-1:0]  cnt_avail	// Available Px T FIFO slots
);
	import math::min;

	cvsource_if #(.T(T), .P(P)) qq ();
	cvs_fifo #(
		.T(T), .P(P),
		.MIN_DEPTH (MIN_DEPTH),
		.FIFO_STYLE(CVS_FIFO_STYLE)
	) fifo (
		.clk, .rst,
		.d, .q (qq),
		.cnt_avail
	);

	localparam int unsigned B = P+PO-1;

	generate
		if (PO == 1) begin // output width = 1
			T     [P-1:0]   Buf = 'x;
			logic [$clog2(P+1)-1:0] sel = '0;
			logic [$clog2(P+1)-1:0] buf_cnt = '0;

			uwire load  = (buf_cnt == 0) && (qq.cnt != 0);
			uwire valid = sel < buf_cnt;
			uwire last  = valid && ((sel + 1'b1) == buf_cnt);
			uwire take  = valid && q.ack;

			always_ff @(posedge clk) begin
				if (rst) begin
					Buf     <= 'x;
					buf_cnt <= '0;
					sel     <= '0;
				end
				else if (load) begin
					for (int unsigned i = 0; i < P; i++) begin
						Buf[i] <= qq.q[i];
					end
					buf_cnt <= qq.cnt;
					sel     <= '0;
				end
				else if (take) begin
					if (last) begin
						buf_cnt <= '0;
						sel     <= '0;
					end
					else begin
						sel <= sel + 1'b1;
					end
				end
			end

			assign q.q[0] = valid ? Buf[sel] : 'x;
			assign q.cnt  = valid;

			assign qq.ack = load;
		end
		else begin // / output width > 1
			localparam int unsigned PTR_W = (P > 1)? $clog2(P) : 1;

			T              [B-1:0] Buf    = 'x;
			logic unsigned [$clog2(B+1)-1:0] Free   = B; // # of space left in buffer
			logic unsigned [$clog2(B+1)-1:0] Having = 0; // # of elements in buffer
			logic unsigned [$clog2(PO+1)-1:0] SrcCnt = 0;
			logic unsigned [PTR_W-1:0]        Ptr    = 0;

			// Free all acknowledged elements and append fresh data from cvs_fifo.
			uwire [$clog2(B+1)-1:0] free   = Free   + q.ack;
			uwire [$clog2(B+1)-1:0] having = Having - q.ack;

			always_ff @(posedge clk) begin
				if (rst) begin
					Buf    <= 'x;
					Free   <= B;
					Having <= 0;
					SrcCnt <= 0;
					Ptr    <= 0;
				end
				else begin
					automatic logic unsigned [$clog2(B+1)-1:0] added = qq.ack? min(qq.cnt, free) : 0;
					automatic T [B-1:0] buf_ = Buf;
					automatic T [B-1:0] mask = ({B*$bits(T){1'b1}} >> (free*$bits(T)));
					automatic T [B-1:0] dat  = (qq.q >> Ptr*$bits(T)) << having*$bits(T);

					buf_ >>= (q.ack*$bits(T));
					buf_ &= mask;
					buf_ |= dat;

					Buf    <= buf_;
					Free   <= free - added;
					Having <= having + added;
					Ptr    <= qq.ack? 0 : Ptr + added;

					SrcCnt <= math::min(having + added, PO);
				end
			end

			assign qq.ack = free >= (qq.cnt-Ptr);

			assign q.q   = Buf[PO-1:0];
			assign q.cnt = SrcCnt;
		end
	endgenerate

endmodule : cvs_fifo2
`default_nettype wire
