// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
 * @file    vector_binary_search_2clk.sv
 * @brief   Pipelined vector search over a perfect binary decision tree.
 * @date    2025-10-31
 * @author  Alexander Weiss
 *
 * @details
 *   This module compares an input key against a sorted set of unique keys stored
 *   in per-level on-chip RAMs and returns a match flag and associated payload.
 *   It supports exact value matches or inclusive range matches depending on
 *   SEARCH_MODE. The design sustains one key per cycle (II=1) once the pipeline
 *   is primed, assuming each level can serve one read per cycle.
 *
 *   Architecture:
 *   - Perfect tree with DIM levels; total inner nodes: N = 2^DIM - 1.
 *     Each level i holds 2^i entries addressed by the local node index.
 *   - Each level is split into four pipeline phases:
 *       0) request (issue read), 1) wait0, 2) wait1/seed, 3) process (compare/route).
 *   - Match handling:
 *       - SEARCH_MODE == "VALUE": exact equality match (data_in == key[0]).
 *       - SEARCH_MODE == "RANGE": inclusive interval match (key[0] <= data_in <= key[1]).
 *     On match, the item is marked found and the value is propagated to the tail
 *     where hit/hit_value are produced.
 *
 *   Latency and alignment:
 *   - The design aligns requests and responses via a per-level context pipeline so
 *     comparisons occur exactly when the corresponding memory output is valid.
 *
 *   Address progression:
 *   - On mismatch at level i, the next local address is computed as:
 *       local_addr_next = (data_in < mem[i].key[0]) ? (2*local_addr) : (2*local_addr+1)
 *     which maps StageData i to StageData i+1 in the perfect tree.
 *   - In RANGE mode, the left/right decision still compares data_in to key.
 *
 * @tparam K               Data type of the compared key (scalar or packed vector).
 *                         Example: logic [31:0]
 * @tparam R               Payload type returned on hit (valid when hit==1).
 *                         Example: logic [23:0]
 * @param  DIM             Tree depth (levels). Number of inner nodes: N = 2^DIM - 1.
 * @param  SEARCH_MODE     Match mode: "VALUE" (exact equality) or "RANGE" (inclusive bounds).
 * @param  RETURN_VALUE    0: return value always '0; 1: return value read from memory on match.
 *
 * @derived
 *   NUM_KEYS              Number of key lanes per node: 1 for VALUE, 2 for RANGE.
 *   N                     Number of inner nodes = 2^DIM - 1.
 *   NUM_MEMS              Equals DIM (one memory per tree level).
 *   STAGES                4 * NUM_MEMS (request, wait0, wait1/seed, process).
 *
 * @memory_format
 *   Memory entries are stored as packed structs with the following bit layout:
 *   - SystemVerilog packed structs place the LAST declared field in the LSBs.
 *
 *   For SEARCH_MODE == "VALUE" && RETURN_VALUE == 1:
 *     Bit layout: [key | value]
 *       - value: bits [0 +: $bits(R)]
 *       - key:   bits [$bits(R) +: $bits(K)]
 *
 *   For SEARCH_MODE == "VALUE" && RETURN_VALUE == 0:
 *     Bit layout: [key]
 *       - key: bits [0 +: $bits(K)]
 *
 *   For SEARCH_MODE == "RANGE" && RETURN_VALUE == 1:
 *     Bit layout: [key[1] | key[0] | value]
 *       - value:  bits [0 +: $bits(R)]
 *       - key[0]: bits [$bits(R) +: $bits(K)]
 *       - key[1]: bits [$bits(R) + $bits(K) +: $bits(K)]
 *
 *   For SEARCH_MODE == "RANGE" && RETURN_VALUE == 0:
 *     Bit layout: [key[1] | key[0]]
 *       - key[0]: bits [0 +: $bits(K)]
 *       - key[1]: bits [$bits(K) +: $bits(K)]
 *
 * @ports
 *   wr_clk                Write Clock.
 *   rd_clk                Read Clock.
 *   rst                   Synchronous reset (synchronous to wr_clk).
 *   valid                 Input key valid (accepts one key per cycle when high).
 *   data_in               Input key (compared against per-level keys).
 *   wext                  Flat write port to initialize per-level memories (inner-node entries).
 *   hit_valid             Valid signal for hit output.
 *   hit                   Match indicator (1 on match; equality in VALUE mode, inclusive bounds in RANGE mode).
 *   hit_value             Payload associated with the matched key (valid when hit==1).
 *   internal_delay        Pipeline latency in cycles (STAGES - 1).
 *
 * @throughput
 *   - Initiation interval (II): 1 key/cycle after pipeline priming, assuming each level serves one read/cycle.
 *
 * @notes
 *   - The design assumes sorted, unique keys per level (VALUE) or non-overlapping, ordered ranges (RANGE).
 *   - For RANGE mode, traversal decision uses key[0] for left/right branching.
 *   - READ_LATENCY > 1 has not been validated in this version.
 *
 * @performance_template
 *   Target: Xilinx Kria K26 (Zynq UltraScale+ MPSoC)
 *   Configuration: K = 32-bit, R = 48-bit, DIM = 14, RANGE mode (16k Ranges)
 *   Clock: 250 MHz
 *   Resource utilization (estimates, out-of-context, post-synthesis):
 *   - CLB LUTs:       4181 / 117120 =  3.6%
 *   - CLB registers:  7313 / 234240 =  3.1%
 *   - CLB:             941 /  14640 =  6.4%
 *   - LUTs as Logic:  2333 / 117120 =  2.0%
 *   - LUTs as Memory: 1848 /  57600 =  3.2%
 *   - BRAMs:          54.5 /    144 = 37.8%
 *   - URAMs:             3 /     64 =  4.7%
 *   Timing:
 *     - Fmax:       250 MHz
 *     - Latency:    STAGES - 1 cycles (= 4*DIM - 1 = 55 cycles for DIM=14)
 *   Notes for reproducibility:
 *     - Synthesis:  Vivado 2024.1
 *     - Constraints: create_clock -name clk -period 4.0
 *     - RAM_STYLE:   "auto" (may be overridden by synthesis attributes/pragmas)
 */


module vector_binary_search_2clk #(
	parameter type   K                    = logic [7:0], // Key data type
	parameter type   R                    = logic [7:0], // Return data type (if RETURN_VALUE == 1, valid on hit == 1)
	// Number of values (sorted, unique) to search for
	parameter int    DIM                  = 4,           // total RAM size = (2**DIM)-1
	parameter int    LOG                  = 0,           // enable log outputs
	localparam int   N                    = (2**DIM)-1,
	localparam int   NUM_MEMS             = DIM,
	localparam int   STAGES               = 4*NUM_MEMS,  // StageData 0: request (here is the RAM)
													// StageData 1: Wait memory
													// StageData 2: response
													// StageData 3: process
	parameter string SEARCH_MODE          = "VALUE",     // "VALUE", "RANGE"
	localparam int   NUM_KEYS             = (SEARCH_MODE == "VALUE") ? 1 : 2,
	parameter int    RETURN_VALUE         = 1,           // 0: return value always '0; 1: return value read from memory on match
	parameter int    INTERNAL_DELAY_WIDTH = 8
) (
	input  uwire                           wr_clk,
	input  uwire                           rd_clk,
	input  uwire                           rst,

	// Input key and valid (one per cycle)
	input  uwire                           valid,
	input  K                               data_in,

	// Flat external write port across all inner-node entries
	// Address space size = TOTAL_ENTRIES (see below)
	ocram_write_if.impl                    wext,          // external write port with data width = NUM_KEYS*$bits(K) + RETURN_VALUE*$bits(R)

	// Exact-match result
	output logic                           hit_valid,
	output logic                           hit,
	output R                               hit_value,
	output logic[INTERNAL_DELAY_WIDTH-1:0] internal_delay // delay of this component including all submodules
);

	// The report must FIT: a too-narrow INTERNAL_DELAY_WIDTH silently wraps
	// the value (DIM=10 -> 39 cast to 5 bits reads 7), the consumer then
	// budget-checks against the WRAPPED number and taps its alignment pipe
	// 32 cycles early -- a silently mis-aligned ACT-ST, not an error
	// (FINDINGS_axis_wp_analyse §1.3). Guard at elaboration; the
	// undeclared-module poison keeps the violation fatal on backends that
	// demote $fatal to a warning (Verilator under abc's blanket -Wno-fatal).
	if ((STAGES-1) > ((1 << INTERNAL_DELAY_WIDTH) - 1)) begin : genDelayWidthGuard
		$fatal(1, "vector_binary_search_2clk: internal delay %0d does not fit INTERNAL_DELAY_WIDTH=%0d bits -- widen delay_t (PREPROC_DELAY_MAX) before raising DIM", STAGES-1, INTERNAL_DELAY_WIDTH);
		ct_elab_guard_violation poison ();
	end
	assign internal_delay = INTERNAL_DELAY_WIDTH'(STAGES-1);    // DIM=4 -> internal_delay = (4*DIM)-1 = 15

	logic HitValid;
	logic Hit;
	R     HitValue;

	localparam MEM_WIDTH = NUM_KEYS*$bits(K) + RETURN_VALUE*$bits(R);  // Memory entry width, e.g. 8 bit range low, 8 bit range high, 8 bit output value (2xK + R) = 24 Bits
	typedef logic[MEM_WIDTH-1:0]    M_t;

	typedef struct packed {
		logic   valid;
		K       key;
		R       value;
		logic   found;
		int     local_addr;
	} stage_data_pipe_t;

	typedef struct packed {
	   K  [1:0] key;
	   R  value;
	} kr_t;

	typedef enum logic [1:0] {
		STAGE_REQUEST  = 2'h0,
		STAGE_WAIT0    = 2'h1,
		STAGE_WAIT1    = 2'h2,
		STAGE_PROCESS  = 2'h3
	} stage_e;

	// CDC for read reset
	logic rd_rst;
	reset_cdc reset_cdc_inst (
		.clk     (rd_clk),
		.rst_in  (rst),
		.rst_out (rd_rst)
	);

	// -----------------------------------------------------------------------------
	// Generate MEMs
	// -----------------------------------------------------------------------------
	generate

		stage_data_pipe_t   StageData  [STAGES:0];
		kr_t                kr         [NUM_MEMS];

		for (genvar i=0; i<=STAGES; i++) begin : STAGE

			localparam int   MEM_ID = (i>>2);
			localparam int   A_BITS = (i > 0) ? MEM_ID : 1;
			stage_data_pipe_t curr_stage_data;

			// STAGE_REQUEST stage with RAM and r_if, w_if
			if (i[1:0] == STAGE_REQUEST) begin      // i%4 = 0

				// memory content with return value
				ocram_write_if #(.A_BITS(A_BITS), .T(M_t)) w_if (wr_clk);
				ocram_read_if  #(.A_BITS(A_BITS), .T(M_t)) r_if (rd_clk);
				// RAM
				if (MEM_ID < NUM_MEMS) begin
					// ENABLE_INIT=1 zeros the RAM in simulation so that unwritten
					// slots read as 0, matching real-BRAM power-up on the bitfile.
					// Without this, xsim leaves contents X and search traversal
					// takes ternary(X) paths that do not reflect HW behaviour.
					ocram_sdp #(
						.A_BITS     (A_BITS),
						.T          (M_t),
						.RAM_STYLE  ("auto"),
						.USE_ADDITIONAL_OUTPUT_REG(1),
						.ENABLE_INIT(1)
					) ram (
						.write_port(w_if.impl),
						.read_port (r_if.impl)
					);
				end

				// Flat writer -> per-level writer decode
				logic wr_valid;
				int   wr_stage, wr_local;

				always_comb begin
					if (i < STAGES) begin
						// map read result to kr, according to SEARCH_MODE / RETURN_VALUE setting
						if (SEARCH_MODE == "RANGE" && RETURN_VALUE == 1) begin
							// Struct: typedef struct packed { K key[2]; R value; }
							// Bit vector: [key[1] | key[0] | value], highest Bit -> key[1],
							kr[MEM_ID].value  = R'(r_if.q[0                   +: $bits(R)]);
							kr[MEM_ID].key[0] = K'(r_if.q[$bits(R)            +: $bits(K)]);
							kr[MEM_ID].key[1] = K'(r_if.q[$bits(R) + $bits(K) +: $bits(K)]);
						end
						else if (SEARCH_MODE == "RANGE" && RETURN_VALUE == 0) begin
							kr[MEM_ID].key[0] = K'(r_if.q[0        +: $bits(K)]);
							kr[MEM_ID].key[1] = K'(r_if.q[$bits(K) +: $bits(K)]);
							kr[MEM_ID].value  = '0;
						end
						else if (SEARCH_MODE == "VALUE" && RETURN_VALUE == 1) begin
							kr[MEM_ID].value  = R'(r_if.q[0        +: $bits(R)]);
							kr[MEM_ID].key[0] = K'(r_if.q[$bits(R) +: $bits(K)]);
							kr[MEM_ID].key[1] = '0;
						end
						else if (SEARCH_MODE == "VALUE" && RETURN_VALUE == 0) begin
							kr[MEM_ID].key[0] = K'(r_if.q[0 +: $bits(K)]);
							kr[MEM_ID].key[1] = '0;
							kr[MEM_ID].value  = '0;
						end
					end
				end

				// -----------------------------------------------------------
				// write access (combinational)
				// -----------------------------------------------------------
				// Drive the per-level RAM write port directly from the flat wext interface.
				// This avoids adding extra clock cycles of latency (wext -> w_if -> RAM).
				always_comb begin
					w_if.ce   = 1'b0;
					w_if.we   = 1'b0;
					w_if.addr = '0;
					w_if.d    = '0;

					flat_to_stage_local_pow2m1(NUM_MEMS, int'(wext.addr), wr_valid, wr_stage, wr_local);
					if (!rst && wext.ce && wext.we && wr_valid && (wr_stage == MEM_ID)) begin
						w_if.ce   = 1'b1;
						w_if.we   = 1'b1;
						w_if.addr = wr_local[A_BITS-1:0];
						w_if.d    = wext.d;
					end
				end

				// -----------------------------------------------------------
				// read access
				// -----------------------------------------------------------
				always_ff @(posedge rd_clk) begin
					if (rd_rst) begin
						if ((i > 0) && (i < STAGES)) begin
							StageData[i+1] <= '0;
						end
						r_if.ce     <= '0;
						r_if.regce  <= '0;
						r_if.addr   <= '0;
					end
					else begin
						if ((i > 0) && (i < STAGES)) begin
							StageData[i+1] <= StageData[i];
						end
						if (i == 0) begin
							r_if.ce     <= '1;
							r_if.addr   <= '0;
						end
						else if (i == STAGES) begin
							HitValid    <=  StageData[i].valid;
							Hit         <= '0;
							HitValue    <= '0;
							if ((StageData[i].valid) && (StageData[i].found)) begin
								Hit      <= 1;
								HitValue <= StageData[i].value;
								if (LOG) begin $display("%0.0f: Stage %0d: Hit for key %0x / value: %0x", $realtime, i, StageData[i].key, StageData[i].value); end
							end
						end
						else begin
							if (StageData[i].valid && !StageData[i].found) begin
								r_if.ce     <= '1;
								r_if.addr  <= StageData[i].local_addr;
								if (LOG) begin $display("%0.0f: Stage %0d: key %0x read request mem%0d@%0d", $realtime, i, StageData[i].key, MEM_ID, StageData[i].local_addr); end
							end
						end
					end
				end
			end
			// STAGE_WAIT0
			else if (i[1:0] == STAGE_WAIT0) begin       // i%4 = 1
				always_ff @(posedge rd_clk) begin
					if (rd_rst) begin
						if (i>1) begin
							StageData[i+1] <= '0;
						end
					end
					else begin
						if (i>1) begin
							StageData[i+1] <= StageData[i];
						end
					end
				end
			end
			// STAGE_WAIT1
			else if (i[1:0] == STAGE_WAIT1) begin   // i%4 = 2
				always_ff @(posedge rd_clk) begin
					if (rd_rst) begin
						StageData[i+1] <= '0;
					end
					else begin
						if (i == 2) begin               // seed stage
							StageData[3].valid              <= valid;
							StageData[3].key                <= data_in;
							StageData[3].found              <= 1'b0;
							StageData[3].value              <= '0;
							StageData[3].local_addr         <= '0;     // is root
						end
						else begin
							StageData[i+1] <= StageData[i];
						end
					end
				end
			end
			// STAGE_PROCESS
			else if (i[1:0] == STAGE_PROCESS) begin     // i%4 = 3
				always_ff @(posedge rd_clk) begin
					if (rd_rst) begin
						if (i < STAGES) begin
							StageData[i+1] <= '0;
						end
					end
					else begin
						if (i < STAGES) begin
							StageData[i+1] <= StageData[i];
							if (StageData[i].valid) begin
								if (!StageData[i].found) begin
									unique if (SEARCH_MODE == "VALUE") begin     //search mode: value (data_in == key[0])
										if (StageData[i].key == kr[MEM_ID].key[0]) begin
											StageData[i+1].found <= '1;
											if (RETURN_VALUE == 1) begin
												StageData[i+1].value <= kr[MEM_ID].value;
											end
											else begin
												StageData[i+1].value <= '0;
											end
											if (LOG) begin $display("%0.0f: Stage %0d: key %0x *** VALUE FOUND ***", $realtime, i, StageData[i].key); end
										end
										else begin
											// Stage s -> Stage s+1 uses local_addr = 2 * local_addr (left) or (2 * local_addr=+1 (right)
											StageData[i+1].local_addr <= (StageData[i].key < kr[MEM_ID].key[0]) ? 2*StageData[i].local_addr : 2*StageData[i].local_addr+1;
											if (LOG) begin $display("%0.0f: Stage %0d: key %0x != %0d", $realtime, i, StageData[i].key, kr[MEM_ID].key[0]); end
										end
									end
									else if (SEARCH_MODE == "RANGE") begin        //search mode: range (key[0] <= data_in <= key[1])
										if ((kr[MEM_ID].key[0] <= StageData[i].key) && (StageData[i].key <= kr[MEM_ID].key[1]))begin
											StageData[i+1].found <= '1;
											if (RETURN_VALUE == 1) begin
												StageData[i+1].value <= kr[MEM_ID].value;
											end
											else begin
												StageData[i+1].value <= '0;
											end
											if (LOG) begin $display("%0.0f: Stage %0d: key %0x *** RANGE MATCH ***", $realtime, i, StageData[i].key); end
										end
										else begin
											// Stage s -> Stage s+1 uses local_addr = 2 * local_addr (left) or (2 * local_addr=+1 (right)
											StageData[i+1].local_addr <= (StageData[i].key < kr[MEM_ID].key[0]) ? 2*StageData[i].local_addr : 2*StageData[i].local_addr+1;
											if (LOG) begin $display("%0.0f: Stage %0d: !(%0x <= %0x <= %0x)", $realtime, i, kr[MEM_ID].key[0], StageData[i].key, kr[MEM_ID].key[1]); end
										end
									end
								end
								else begin
									if (LOG) begin $display("%0.0f: StageData %0d: key %0x skipped (already found)", $realtime, i, StageData[i].key); end
								end
							end
						end
					end
				end
			end
		end
		assign hit_valid = HitValid;
		assign hit       = Hit;
		assign hit_value = HitValue;
	endgenerate

	// -------------------------------------------------------------------------------
	// Helper
	// -------------------------------------------------------------------------------

	// Perfect tree: N = (2^stages) - 1
	// Map flat -> (stage, local_addr)
	function automatic void flat_to_stage_local_pow2m1(
		input  int   stages,      // >=1
		input  int   flat,        // 0 .. (1<<stages)-2
		output logic valid,
		output int   stage,
		output int   local_addr
	);
		int N;
		int k; // number of trailing ones (ct1)
		int w; // bit-width to scan (use 31 for int, or $bits(int))
		begin
			valid      = 1'b0;
			stage      = -1;
			local_addr = -1;

			if (stages <= 0) return;
			N = (1 << stages) - 1;
			if (flat < 0 || flat >= N) return;

			// even -> last stage
			if ((flat & 1) == 0) begin
				stage      = stages - 1;
				local_addr = flat >> 1;
				valid      = 1'b1;
				return;
			end

			// odd -> count trailing ones (ct1)
			k = 0;
			w = 31; // or: w = $bits(int)-1;
			for (int i = 0; i < w; i++) begin
				if (((flat >> i) & 1) == 1) k++;
				else break;
			end

			// stage and local
			stage      = (stages - 1) - k;
			local_addr = flat >> (k + 1);
			valid = 1'b1;
		end
	endfunction


endmodule
`default_nettype wire
