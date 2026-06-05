// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    A compacting FIFO with CDC for a counted vector stream
*           which allows to acknowledge parts of the offered vector
*
* @author   Albert Schulz <aschulz@accemic.com>
* @author   Alexander Weiss <aweiss@accemic.com>
*/
module cvs_cdc_fifo2 #(
	type			T=logic[7:0],
	int unsigned	P,								// Input parallelism
	int unsigned	PO = P,							// Output parallelism
	int unsigned	CVS_MIN_DEPTH = 4,
	int unsigned	CDC_MIN_DEPTH = 4,
	parameter 		CVS_FIFO_STYLE = "auto",		// auto, distributed, registers, block, ultra, shift
	parameter 		CDC_FIFO_STYLE = "distributed",	// distributed, block
	bit				SAFE_RESETS = 0,				// Ensure resets are safe: must be set to '1' explicitly
	bit				EXTRA_FABRIC_REGS = 0,			// Extra data output regs in fabric for more flexible routing
	parameter 		NAME = ""						// Optional name for easier instance identification.
)(
	cvsink_if.impl	d,
	source_if.impl	q,

	// Instantaneous fill level of the CVS FIFO in d.clk domain (0..CVS_MIN_DEPTH).
	// Useful for a max-fill watermark register. Not CDC'd - consumer decides.
	output uwire [$clog2(CVS_MIN_DEPTH+1)-1:0]  cvs_fill
);

	cvsource_if2 #(.T(T), .P(P)) cvs_q (.clk (d.clk), .rst (d.rst));

	// Compacting FIFO
	uwire [$clog2(CVS_MIN_DEPTH+1)-1:0] cvs_cnt_avail;
	cvs_fifo2 #(
		.T(T),
		.P(P),	     	                            // max # of T elements @ input
		.PO(PO),	                                // max # of T elements @ output
		.MIN_DEPTH (CVS_MIN_DEPTH),
		.CVS_FIFO_STYLE(CVS_FIFO_STYLE))
	cvs_fifo2_inst (
		.clk (d.clk),								// TODO: change cvs_fifo2 implementation and use d.clk here?
		.rst (d.rst),								// TODO: change cvs_fifo2 implementation and use d.rst here?
		.d,
		.q	 (cvs_q),
		.cnt_avail (cvs_cnt_avail)
	);

	// Note: the inner fifo1clk_fwft's cnt_avail can transiently exceed
	// CVS_MIN_DEPTH (DEPTH is MIN_DEPTH+READOUT_LATENCY internally), so guard
	// against an underflow on the subtraction.
	assign cvs_fill = (cvs_cnt_avail >= CVS_MIN_DEPTH[$clog2(CVS_MIN_DEPTH+1)-1:0])
		? '0
		: CVS_MIN_DEPTH[$clog2(CVS_MIN_DEPTH+1)-1:0] - cvs_cnt_avail;

	typedef T [PO-1:0] T_vec;
	sink_if  #(.T(T_vec)) cdc_d (.clk (d.clk), .rst (d.rst));

	assign cdc_d.d    =   cvs_q.q;
	assign cdc_d.wr   = ((cvs_q.cnt > PO-1) && !(cdc_d.full)) ?  1 : 0; 	// write PO values to CDC FIFO
	assign cvs_q.ack  = ((cvs_q.cnt > PO-1) && !(cdc_d.full)) ? PO : 0; 	// ack PO values to CVS FIFO

	// CDC FIFO (clk -> q.clk)
	fifo2clk_fwft #(
		.T(T_vec),
		.MIN_DEPTH  (CDC_MIN_DEPTH),
		.FIFO_STYLE (CDC_FIFO_STYLE),
		.SAFE_RESETS(SAFE_RESETS),
		.EXTRA_FABRIC_REGS(EXTRA_FABRIC_REGS),
		.NAME(NAME))
	fifo2clk_fwft_inst (
		.d(cdc_d),
		.q(q)
	);

endmodule : cvs_cdc_fifo2
`default_nettype wire
