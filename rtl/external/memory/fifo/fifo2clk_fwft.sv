// -*- indent-tabs-mode:t; tab-width:4
// vim: tabstop=4:noexpandtab
/**
 * Copyright (c) 2018-2024 by Accemic Technologies GmbH Kiefersfelden Germany
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * @author	Thomas B. Preußer <tpreusser@accemic.com>
 *
 * @brief FIFO - an elastic buffer across clock regions with generic
 *               data source semantics offering a first word fall through (FWFT)
 *               output interface.
 *
 * @implements  sink_if
 * @implements  source_if
 */

`undef MY_DEBUG

module fifo2clk_fwft #(
	type	T = logic [7:0],	// Element Type
	int		MIN_DEPTH,			// Minimum FIFO Depth
	bit		SAFE_RESETS = 0,	// Ensure resets are safe: must be set to '1' explicitly
	bit		EXTRA_FABRIC_REGS = 0,	// Extra data output regs in fabric for more flexible routing

	/**
	 * Type of backing on-chip RAM.
	 *   Options: "distributed", "register(s)", "block", and "ultra"
	 */
	parameter FIFO_STYLE = "block",
	parameter NAME = ""	// Optional name for easier instance identification.
)(
	sink_if.impl	d,
	source_if.impl	q
);
	import  math::gray2bin;

	//-----------------------------------------------------------------------
	// Parameter Sanity Checks
	localparam int unsigned  DATA_WIDTH = $bits(T);
	localparam int unsigned  A_BITS     = $clog2(MIN_DEPTH);
	localparam int unsigned  READOUT_LATENCY = (FIFO_STYLE == "BLOCK") || (FIFO_STYLE == "block")? 2+EXTRA_FABRIC_REGS : 1;

	initial begin
		if(DATA_WIDTH == 0) begin
			// This is fine for implementing abstract flow control
			//  but is worth a warning nonetheless.
			$warning("%m '%s': WIDTH of element type (%s) is zero.",
					 NAME, $typename(T));
		end
		if(MIN_DEPTH < 4) begin
			$error("%m '%s': DEPTH of %d must be, at least, four (4).",
				   NAME, MIN_DEPTH);
			$finish;
		end
		if(DATA_WIDTH != $bits(d.d)) begin
			$error("%m '%s': Incompatible input width of %d instead of %d.",
				   NAME, $bits(d.d), DATA_WIDTH);
			$finish;
		end
		if(DATA_WIDTH != $bits(q.q)) begin
			$error("%m '%s': Incompatible output width of %d instead of %d.",
				   NAME, $bits(q.q), DATA_WIDTH);
			$finish;
		end
	end

	//-----------------------------------------------------------------------
	// Clock and Reset Extraction
	uwire  wclk = d.clk;
	uwire  wrst;
	uwire  rclk = q.clk;
	uwire  rrst;

	/*initial begin
		if(!SAFE_RESETS) begin
			$display("%m '%s': Synchronize resets appropriately (cross_reset) and assert SAFE_RESETS.", NAME);
			$finish;
		end
	end*/
	if(SAFE_RESETS)begin:genSafeReset
		assign  wrst = d.rst;
		assign  rrst = q.rst;
	end
	else begin:genNonSafeReset
		cross_reset #(.N(2)) cross_reset_inst (
		.rst0(d.rst || q.rst),

		.hold({  1'b0, rrst  }),
		.clk({ q.clk, d.clk }),
		.rst({ rrst,wrst })
		);
	end
	//-----------------------------------------------------------------------
	// FIFO Memory Control
	uwire				we;	// Write Data
	uwire [A_BITS-1:0]	wa;
	uwire				re;	// Read Data to Output Register
	uwire [A_BITS-1:0]	ra;

	//-----------------------------------------------------------------------
	// Original GRAY-Coded Address Counters: with a leading generation bit
	//	- FIFO pointers in GRAY code with a cycle of length 2*DEPTH.
	//	- The memory address cycle is reduced to a length of DEPTH by XORing
	//	  the top two pointer bits.
	//	- Only the capacity computations require a somewhat costly GRAY to
	//	  binary conversion.
	logic [A_BITS:0]  WPtr = 0;
	logic [A_BITS:0]  RPtr = 0;

	// Writing Side
	if(1) begin : blkWrite
		logic [1:0][A_BITS:0]  RPtr_sync = '{ 0, 0 };

		logic [A_BITS:0]  Cnt = 1; // backing binary counter
		uwire [A_BITS:0]  wptr_next = Cnt ^ { 2'b0, Cnt[A_BITS:1] };

		logic  Full = 1;

		always_ff @(posedge wclk) begin
			if(wrst) begin
				RPtr_sync <= '{ 0, 0 };

				Cnt		<= 1;
				WPtr	<= 0;
				Full	<= 1;
			end
			else begin
				RPtr_sync <= '{ RPtr, RPtr_sync[$left(RPtr_sync):1] };

				if(we) begin
					Cnt		<= Cnt + 1;
					WPtr	<= wptr_next;
				end
				Full	<= (we? wptr_next : WPtr) == { ~RPtr_sync[0][A_BITS:A_BITS-1], RPtr_sync[0][A_BITS-2:0] };
			end
		end
		uwire	[A_BITS:0]	space = gray2bin({ ~RPtr_sync[0][A_BITS:A_BITS-1], RPtr_sync[0][A_BITS-2:0] }) - gray2bin(WPtr);
		assign	d.cnt_avail = space;

		assign  d.full	= Full;
		assign  we		= d.wr && !Full;
		assign  wa		= { WPtr[A_BITS]^WPtr[A_BITS-1], WPtr[A_BITS-2:0] };

	end : blkWrite

	// Reading Side
	uwire [READOUT_LATENCY-1:0]	load;
	if(1) begin : blkRead
		logic [1:0][A_BITS:0]  WPtr_sync = '{ 0, 0 };

		logic [A_BITS:0]  Cnt = 1; // backing binary counter
		uwire [A_BITS:0]  rptr_next = Cnt ^ { 2'b0, Cnt[A_BITS:1] };

		logic  Empty = 1;

		always_ff @(posedge rclk) begin
			if(rrst) begin
				WPtr_sync <= '{ 0, 0 };

				Cnt		<= 1;
				RPtr	<= 0;
				Empty	<= 1;
			end
			else begin
				WPtr_sync <= '{ WPtr, WPtr_sync[$left(WPtr_sync):1] };

				if (re) begin
					Cnt		<= Cnt + 1;
					RPtr	<= rptr_next;
				end
				Empty <= (re? rptr_next : RPtr) == WPtr_sync[0];
			end
		end
		uwire [A_BITS:0] avail = gray2bin(WPtr_sync[0]) - gray2bin(RPtr);
		assign	q.cnt_avail = avail;

		//---------------------------------------------------------------------
		// Match Readout Latency with appropriate valid Signal Propagation
		//	Stages: #(READOUT_LATENCY-1) .. #0
		logic [READOUT_LATENCY-1:0]	Vld = 0;
		for(genvar	i = 0; i < READOUT_LATENCY; i++) begin
			assign	load[i] = |{ ~Vld[i:0], q.ack };
			always_ff @(posedge rclk) begin
				if(rrst)	Vld[i] <= 0;
				else		Vld[i] <= !load[i] || (i == READOUT_LATENCY-1? !Empty : Vld[i+1]);
			end
		end
		assign	q.valid	= Vld[0];
		assign	re		= !Empty && load[$left(load)];	// Read Data to Output Latch
		assign	ra		= { RPtr[A_BITS]^RPtr[A_BITS-1], RPtr[A_BITS-2:0] };

	end : blkRead

	always_comb begin
		if (!d.rst && !q.rst)
			assert(d.cnt_avail + q.cnt_avail <= 2**A_BITS) else begin
				if(d.cnt_avail > 2**A_BITS) begin
					$error("FIFO %s: Computed illegal value of d.cnt_avail=%0d",NAME, d.cnt_avail);
				end
				if(q.cnt_avail > 2**A_BITS) begin
					$error("FIFO %s: Computed illegal value of q.cnt_avail=%0d",NAME, q.cnt_avail);
				end
				$error("FIFO %s: Reported capacities %0d+%0d exceed size of %0d",NAME, d.cnt_avail, q.cnt_avail, 2**A_BITS);
				$stop;
			end
	end

	//-----------------------------------------------------------------------
	// FIFO Memory
	if(DATA_WIDTH) begin : genMemory
		/*
		 * Note: Memory Entries should not be defined with type T like `T mem[2**A_BITS]`
		 * If the type would be a struct, this results in one RAM module for every field of the struct in synthesis
		 * Synthesized with Vivado 2018.1
		 */

`ifdef MY_DEBUG
		typedef logic [$bits(T)+1:0] data_t;

		logic [1:0] WrCheck = 0;
		always_ff @(posedge wclk) begin
			if(wrst)	WrCheck <= 0;
			else if(we)	WrCheck <= WrCheck + WrCheck[1] + 1; // Mod-3 Count
		end
		uwire data_t wd = { WrCheck, d.d };
`else
		typedef logic [$bits(T)-1:0] data_t;
		uwire data_t wd = d.d;
`endif
		(* RAM_STYLE = FIFO_STYLE *)
		data_t Mem[2**A_BITS];

		// Output Register of the value read
		data_t ReadReg[READOUT_LATENCY] = '{ default: 'x };
		always_ff @(posedge wclk)	if(we)	Mem[wa]						<= wd;
		always_ff @(posedge rclk)	if(re)	ReadReg[READOUT_LATENCY-1]	<= Mem[ra];
		for(genvar	i = 0; i < READOUT_LATENCY-1; i++) begin
			always_ff @(posedge rclk) begin
// synthesis translate_off
				if(rrst) ReadReg[i] <= 'x; else
// synthesis translate_on
				if(load[i])	ReadReg[i] <= ReadReg[i+1];
			end
		end
		uwire data_t	rd = ReadReg[0];
		assign	q.q = rd[$bits(T)-1:0];

`ifdef MY_DEBUG
		//-------------------------------------------------------------------
		// Debug Input/Output Glitches
		//	- A 2-bit modulo-3 count accompanies the data stream through the FIFO.
		//	- A glitch by lost or inserted data is detected on this basis.
		//	- SyncErr will be asserted at the first occurence of such a glitch.
		(* MARK_DEBUG = "TRUE" *) logic [1:0]	RdCheck = 0;
		(* MARK_DEBUG = "TRUE" *) logic			SyncErr = 0;
		always_ff @(posedge rclk) begin
			if(rrst) begin
				RdCheck <= 0;
				SyncErr <= 0;
			end
			else if(q.valid) begin
				if(rd[$bits(T)+:2] != RdCheck)	SyncErr <= 1;
				if(q.ack)	RdCheck <= RdCheck + RdCheck[1] + 1; // Mod-3 Count
			end
		end
		always_comb assert(SyncErr === 1'b0) else begin
			$error("FIFO %s: Output out of sync.", NAME);
			$stop;
		end
`endif

	end : genMemory

endmodule : fifo2clk_fwft
`undef MY_DEBUG
