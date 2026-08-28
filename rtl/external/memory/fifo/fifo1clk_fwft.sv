// SPDX-FileCopyrightText: 2018-2021 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
 * @author  Alexander Lange   <alange@accemic.com>, Thomas B. Preußer <tpreusser@accemic.com>
 *
 * @brief FIFO - an elastic buffer within a single clock region with generic
 *               data source semantics offering a first word fall through (FWFT)
 *               output interface.
 *
 * @implements  sink_if
 * @implements  source_if
 * @remark
 *    Ensure that the {clk,rst} signals of both connected interface instances
 *    are identical.
 */
module fifo1clk_fwft #(
	type         T                 = logic [7:0], // Element Type
	int unsigned MIN_DEPTH,                       // Minimum FIFO Depth
	bit          STATE_REGS        = 1,           // ful/vld directly from Registers
	bit          EXTRA_FABRIC_REGS = 0,           // Extra data output regs in fabric for more flexible routing

	parameter    NAME              = "",          // Optional name for easier instance identification.

	/**
	 * Type of backing on-chip memory.
	 *   Options: "distributed", "register(s)", "block", "ultra", and
	 *          "shift" as a custom extension for typically small SRL-based FIFOs.
	 */
	parameter    FIFO_STYLE        = "auto",

	/**
	 * Permit an explicit data width override in cases where Vivado has trouble
	 * inferring the bit width of T. Use carefully.
	 */
	int unsigned DATA_WIDTH        = $bits(T)
)(
  sink_if.impl   d,
  source_if.impl q
);

	// "auto" considers the TOTAL storage (depth x width), not depth alone:
	// a shallow-but-wide FIFO (e.g. 128 x 237 bit) belongs in block RAM,
	// which the depth-only rule used to map into thousands of LUTRAMs.
	localparam STYLE =
		FIFO_STYLE != "auto"? FIFO_STYLE :
		MIN_DEPTH <=   4? "registers"   :
		(MIN_DEPTH <= 32 && MIN_DEPTH*DATA_WIDTH <= 4096)? "shift" :
		(MIN_DEPTH*DATA_WIDTH >= 8192)? "block" :
		MIN_DEPTH <= 128? "distributed" :
		/* else */        "block";

	//-----------------------------------------------------------------------
	// Parameter Sanity Checks
	initial begin
		if(DATA_WIDTH == 0) begin
			// This is fine for implementing abstract flow control
			//  but is worth a warning nonetheless.
			$warning("** FIFO %s: WIDTH of element type (%s) is zero.",
					 NAME, $typename(T));
		end
		if(MIN_DEPTH < 2) begin
			$error("** FIFO %s: DEPTH of %d must be, at least, four (4).",
				   NAME, MIN_DEPTH);
			$finish;
		end
		if(DATA_WIDTH != $bits(d.d)) begin
			$error("** FIFO %s: Incompatible input width of %d instead of %d.",
				   NAME, $bits(d.d), DATA_WIDTH);
			$finish;
		end
		if(DATA_WIDTH != $bits(q.q)) begin
			$error("** FIFO %s: Incompatible output width of %d instead of %d.",
				   NAME, $bits(q.q), DATA_WIDTH);
			$finish;
		end
	end

	//-----------------------------------------------------------------------
	// Clock and Reset Extraction
	uwire  clk = d.clk;
	uwire  rst = d.rst;

	//-----------------------------------------------------------------------
	// Minimal Pointer-Free Register-Based FIFO Separating Enable Domains
	if(MIN_DEPTH == 2) begin : genMinimal
		T       A   = 'x;   // Output Reg
		logic   Vld =  0;
		T       B   = 'x;   // Buffer Reg
		logic   Ful =  0;

		always_ff @(posedge clk) begin
			if(rst) begin
				A   <= 'x;
				Vld <=  0;
				B   <= 'x;
				Ful <=  0;
			end
			else begin
				if(q.ack || !Vld)   A <= Ful? B : d.d;
				Vld <= (Vld && !q.ack) || Ful || d.wr;

				if(!Ful)            B <= d.d;
				Ful <= (Ful || (Vld && d.wr)) && !q.ack;
			end
		end
		assign  d.full      = Ful;
		assign  d.cnt_avail = Ful? 0 : Vld? 1 : 2;

		assign  q.q         = A;
		assign  q.valid     = Vld;
		assign  q.cnt_avail = Ful? 2 : Vld? 1 : 0;

		// Sanity Check
		always_ff @(posedge clk) begin
			assert(!Ful || Vld) else begin
				$error("%m: FULL must imply VALID.");
				$stop;
			end
		end
	end : genMinimal
	//-----------------------------------------------------------------------
	// Regular Memory-Based FIFO ("block" / "distributed"): MIN_DEPTH > 2
	else if((DATA_WIDTH) && (STYLE != "SHIFT") && (STYLE != "shift")) begin : genRegular

		// Memory State
		uwire   ful;    // all space taken
		uwire   avl;    // data available but not yet in memory output register

		// Match Readout Latency with appropriate valid Signal Propagation
		//  Stages: #(READOUT_LATENCY-1) .. #0
		localparam int unsigned READOUT_LATENCY = (STYLE == "BLOCK") || (STYLE == "ULTRA") || (STYLE == "block") || (STYLE == "ultra")? 2+EXTRA_FABRIC_REGS : 1;
		logic [READOUT_LATENCY-1:0] Vld = 0;
		uwire [READOUT_LATENCY-1:0] load;
		for(genvar  i = 0; i < READOUT_LATENCY; i++) begin
			assign  load[i] = |{ ~Vld[i:0], q.ack };
			always_ff @(posedge clk) begin
				if(rst) Vld[i] <= 0;
				else    Vld[i] <= !load[i] || (i == READOUT_LATENCY-1? avl : Vld[i+1]);
			end
		end
		assign  q.valid = Vld[0];
		assign  d.full  = ful;

		// Memory Control
		localparam int unsigned A_BITS  = $clog2(MIN_DEPTH - READOUT_LATENCY);
		localparam int unsigned DEPTH   = 2**A_BITS + READOUT_LATENCY;
		uwire  we = !ful && d.wr;               // Write Data
		uwire  re =  avl && load[$left(load)];  // Read Data to Output Latch

		// Write and Read Pointers
		logic [A_BITS-1:0]  WPtr = 0;
		logic [A_BITS-1:0]  RPtr = 0;
		// ... and their Increments
		uwire [A_BITS-1:0]  WPtr_inc = WPtr + 1;
		uwire [A_BITS-1:0]  RPtr_inc = RPtr + 1;

		always_ff @(posedge clk) begin
			if(rst) begin
				WPtr <= 0;
				RPtr <= 0;
			end
			else begin
				if(we)  WPtr <= WPtr_inc;
				if(re)  RPtr <= RPtr_inc;
			end
		end

		// Memory Instantiation
		if(1) begin : blkMemory
			typedef logic [$bits(T)-1:0] data_t;

			/*
			 * Note: Memory Entries should not be defined with type T like `T mem[2**A_BITS]`
			 * If the type would be a struct, this results in one RAM module for every field of the struct in synthesis
			 * Synthesized with Vivado 2018.1
			 */
			(* RAM_STYLE = STYLE *)
			data_t Mem[2**A_BITS];

			// Output Register of the value read
			data_t ReadLatch[READOUT_LATENCY] = '{ default: 'x };
			always_ff @(posedge clk)    if(we)  Mem[WPtr]                       <= d.d;
			always_ff @(posedge clk)    if(re)  ReadLatch[READOUT_LATENCY-1]    <= Mem[RPtr];

			for(genvar  i = 0; i < READOUT_LATENCY-1; i++) begin
				always_ff @(posedge clk) begin
// synthesis translate_off
					if(rst)     ReadLatch[i] <= 'x; else
// synthesis translate_on
					if(load[i]) ReadLatch[i] <= ReadLatch[i+1];
				end
			end
			uwire data_t    rd = ReadLatch[0];
			assign  q.q = rd[$bits(T)-1:0];
		end : blkMemory

		// Ring Buffer State Computation
		if(STATE_REGS) begin
			// Registered Ring Buffer State (default)
			//  requires an extra comparator over the combinational computation
			//  but improves the timing of state-derived signals significantly.
			logic Ful = 0;
			logic Avl = 0;

			always_ff @(posedge clk) begin
				if(rst) begin
					Ful <= 0;
					Avl <= 0;
				end
				else if(we != re) begin
					Ful <= (WPtr_inc == RPtr) && we;
					Avl <= (RPtr_inc != WPtr) || we;
				end
			end
			assign  ful = Ful;
			assign  avl = Avl;
		end
		else begin
			// Combinational Ring Buffer State
			//  A single direction flag DF differentiates full vs. empty
			//  when both pointers coincide.
			logic  DF = 0;
			always_ff @(posedge clk) begin
				if(rst)             DF <= 0;
				else if(we != re)   DF <= we;
			end

			uwire  peq = WPtr == RPtr;
			assign  ful = DF &&  peq;
			assign  avl = DF || !peq;
		end

		// Statistics State - will be trimmed if availability outputs are not used
		if(1) begin : blkStats
			localparam int unsigned S_BITS = $clog2(DEPTH+1);
			logic [S_BITS-1:0]  WAvail = DEPTH;
			logic [S_BITS-1:0]  RAvail = 0;

			// Match READOUT_LATENCY in making writes visible
			logic [READOUT_LATENCY-1:0] WeZ = 0;
			uwire wr_eff = WeZ[$left(WeZ)];
			uwire rd_eff = q.valid && q.ack;
			always_ff @(posedge clk) begin
				if(rst) begin
					WAvail  <= DEPTH;
					RAvail  <= 0;
					WeZ     <= 0;
				end
				else begin
					automatic logic signed [1:0] w_inc = (we?    -1 : 0) + (rd_eff?  1 : 0);
					automatic logic signed [1:0] r_inc = (wr_eff? 1 : 0) + (rd_eff? -1 : 0);
					WAvail <= $signed(WAvail) + $signed(w_inc);
					RAvail <= $signed(RAvail) + $signed(r_inc);
					WeZ <= (WeZ << 1) | we;
				end
			end

			// Produce Exact Availability Data
			assign  d.cnt_avail = WAvail;
			assign  q.cnt_avail = RAvail;

		end : blkStats
	end : genRegular
	//-----------------------------------------------------------------------
	//- Shift Register FIFO
	else begin : genShift

		localparam int unsigned A_BITS  = $clog2(MIN_DEPTH);

		uwire   re;
		uwire   we;

		// Contents Pointer: Ptr = <item count> - 1
		localparam logic [A_BITS-1:0]  FULL_ANTIMASK = ~(MIN_DEPTH-2);

		logic [A_BITS:0]  Ptr = '{ A_BITS: 0, default: 1 };
		logic             Ful = 0;
		always_ff @(posedge clk) begin
			if(rst) begin
				Ptr <= '{ A_BITS: 0, default: 1 };
				Ful <= 0;
			end
			else if(re != we) begin
				Ptr <= Ptr + (we? 1 : -1);
				Ful <= !re && we && &(Ptr|FULL_ANTIMASK);
			end
		end // always_ff
		uwire   ful = Ful;
		uwire   avl = Ptr[$left(Ptr)];

		always_comb begin
			d.cnt_avail[A_BITS:0] = $unsigned(~Ptr[A_BITS:0]);
			q.cnt_avail[A_BITS:0] = { ~Ptr[A_BITS], Ptr[A_BITS-1:0]} + 1;
		end

		// Registered (delayed) output valid for FWFT semantics
		logic  Vld = 0;
		always_ff @(posedge clk)  Vld <= rst? 0 : avl || (Vld && !q.ack);
		assign  q.valid = Vld;
		assign  d.full  = ful;

		assign  re = (!Vld || q.ack) && avl;
		assign  we = d.wr  && !ful;

		// Shift register memory only for true data storage
		if(DATA_WIDTH) begin
			T  SR[MIN_DEPTH];
			T  Buf;  // output buffer
			always_ff @(posedge clk) begin
				if(we)  SR  <= { d.d, SR[0:$right(SR)-1] };
				if(re)  Buf <= SR[Ptr[$left(Ptr)-1:0]];
			end
			assign  q.q = Buf;
		end

	end : genShift // Shift FIFO

endmodule : fifo1clk_fwft
