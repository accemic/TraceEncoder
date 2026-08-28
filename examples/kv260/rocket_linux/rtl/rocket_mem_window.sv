// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Address-window translation with guard for the Rocket memory path.
 *
 * @details
 *   L4 point 2. The Rocket sees its memory at **0x8000_0000**, the board has
 *   it at **0x6400_0000** -- this block sits in between.
 *
 *   WHY THE GUEST BASE IS NOT RELOCATABLE (L2 D-L2-1, three findings):
 *     1. The generat's bus decoder: `mem_axi4` only accepts
 *        0x8000_0000..0x3_FFFF_FFFF (`system-nexys-video.v:616-629`).
 *     2. The bootrom jump target `_ram` = 0x8000_0000 (materialized in ROM).
 *     3. The Chisel config only sets the SIZE (`WithExtMemSize`); the base is
 *        the rocket-chip default.
 *   And why the board base cannot be 0x8000_0000: on the ZynqMP, that is
 *   where the PL slave window starts, and the PS DDR sits either low at
 *   0x0..0x7FFF_FFFF or high starting at 0x8_0000_0000 -- the latter does not
 *   fit into the 34-bit-wide `mem_axi4` address port. So the subtraction has
 *   to stay in the AXI path.
 *
 *   WHY THE GUARD IS MANDATORY (examples/kv260/SPEC_board_memory_map.md):
 *   The Rocket bus forwards EVERYTHING from 0x8000_0000 upward to `mem_axi4`
 *   -- 14 GiB, not just our 192 MiB. Without a guard, a wild address would
 *   hit the PS DDR unthrottled:
 *     * 0x8C00_0000 (directly above the window) -> 0x7000_0000 = **Ubuntu**;
 *     * 0x3_7C00_0000 -> 0x3_6000_0000, seen on the 32-bit PS port as
 *       **0x6000_0000** = **base of the DDR trace sink**. A single silent
 *       write there destroys the running capture -- and unnoticed, because
 *       the sink carries no checksum.
 *   That is why accesses outside [WIN_BASE, WIN_BASE+WIN_SIZE) are **not
 *   forwarded**, are answered with DECERR, and are latched in a sticky
 *   diagnosis word (pattern: C6 observation channel `trio_soc_top.sv:214-227`
 *   -- a single devmem is enough to distinguish this case from a reset or
 *   hang problem). The error response is the correct reaction: the guest
 *   gets a load/store access fault instead of silent data corruption.
 *
 *   CHECKING THE BURST ENVELOPE, not just the start address: checked is
 *   [lo, hi] with `total = (len+1) << size`; for WRAP bursts the aligned
 *   block a WRAP burst stays inside of by definition. A burst that starts at
 *   the end of the window and runs past it is thereby rejected completely
 *   (not partially executed).
 *
 *   THROUGHPUT: the allowed path is a pure pass-through (no register, no
 *   serialization) -- multiple outstanding transactions remain possible.
 *   Only once a REJECTION is pending does the block wait until the master
 *   side has drained, then generates the error response itself. That keeps
 *   per-ID ordering trivially correct, and the cost is incurred only in the
 *   error case (which never occurs in normal operation).
 */
module rocket_mem_window #(
	// Guest view (Rocket) and size of the allowed window.
	parameter longint unsigned WIN_BASE = 64'h8000_0000,
	parameter longint unsigned WIN_SIZE = 64'h0C00_0000,   // 192 MiB, == DTS memory@80000000
	// Board view (PS DDR, examples/kv260/SPEC_board_memory_map.md v3: CVA6/Rocket share).
	parameter longint unsigned PS_BASE  = 64'h6400_0000,
	parameter int unsigned     S_ADDR_WIDTH = 34,          // the generat's mem_axi4
	parameter int unsigned     M_ADDR_WIDTH = 64,          // like cva6_soc_synth_wrap
	parameter int unsigned     ID_WIDTH     = 4,
	// AXI attributes the generat port does not expose (it only drives
	// id/addr/len/size/burst). Defaults = "normal, non-cacheable, bufferable,
	// unprivileged, non-secure, data" -- fitting for the PS HP port.
	parameter logic [3:0]      M_CACHE = 4'b0011,
	parameter logic [2:0]      M_PROT  = 3'b010
) (
	input  uwire logic clk_i,
	input  uwire logic rst_ni,

	// --- Diagnosis (sticky, pattern trio_soc_top C6) ----------------------
	input  uwire logic        err_clear,
	output logic              err_sticky,   // 1 = at least one access rejected
	output logic              err_was_write,// direction of the FIRST faulting access
	output logic [31:0]       err_count,    // saturating
	output logic [63:0]       err_addr,     // GUEST address of the FIRST faulting access

	// --- AXI4 slave (Rocket mem_axi4_0) -----------------------------------
	input  uwire logic [ID_WIDTH-1:0]     s_awid,
	input  uwire logic [S_ADDR_WIDTH-1:0] s_awaddr,
	input  uwire logic [7:0]              s_awlen,
	input  uwire logic [2:0]              s_awsize,
	input  uwire logic [1:0]              s_awburst,
	input  uwire logic                    s_awvalid,
	output logic                          s_awready,
	input  uwire logic [63:0]             s_wdata,
	input  uwire logic [7:0]              s_wstrb,
	input  uwire logic                    s_wlast,
	input  uwire logic                    s_wvalid,
	output logic                          s_wready,
	output logic [ID_WIDTH-1:0]           s_bid,
	output logic [1:0]                    s_bresp,
	output logic                          s_bvalid,
	input  uwire logic                    s_bready,
	input  uwire logic [ID_WIDTH-1:0]     s_arid,
	input  uwire logic [S_ADDR_WIDTH-1:0] s_araddr,
	input  uwire logic [7:0]              s_arlen,
	input  uwire logic [2:0]              s_arsize,
	input  uwire logic [1:0]              s_arburst,
	input  uwire logic                    s_arvalid,
	output logic                          s_arready,
	output logic [ID_WIDTH-1:0]           s_rid,
	output logic [63:0]                   s_rdata,
	output logic [1:0]                    s_rresp,
	output logic                          s_rlast,
	output logic                          s_rvalid,
	input  uwire logic                    s_rready,

	// --- AXI4 master (board: PS S_AXI_HP; sim: RAM model) -----------------
	output logic [ID_WIDTH-1:0]           m_awid,
	output logic [M_ADDR_WIDTH-1:0]       m_awaddr,
	output logic [7:0]                    m_awlen,
	output logic [2:0]                    m_awsize,
	output logic [1:0]                    m_awburst,
	output logic                          m_awlock,
	output logic [3:0]                    m_awcache,
	output logic [2:0]                    m_awprot,
	output logic [5:0]                    m_awatop,
	output logic                          m_awvalid,
	input  uwire logic                    m_awready,
	output logic [63:0]                   m_wdata,
	output logic [7:0]                    m_wstrb,
	output logic                          m_wlast,
	output logic                          m_wvalid,
	input  uwire logic                    m_wready,
	input  uwire logic [ID_WIDTH-1:0]     m_bid,
	input  uwire logic [1:0]              m_bresp,
	input  uwire logic                    m_bvalid,
	output logic                          m_bready,
	output logic [ID_WIDTH-1:0]           m_arid,
	output logic [M_ADDR_WIDTH-1:0]       m_araddr,
	output logic [7:0]                    m_arlen,
	output logic [2:0]                    m_arsize,
	output logic [1:0]                    m_arburst,
	output logic                          m_arlock,
	output logic [3:0]                    m_arcache,
	output logic [2:0]                    m_arprot,
	output logic                          m_arvalid,
	input  uwire logic                    m_arready,
	input  uwire logic [ID_WIDTH-1:0]     m_rid,
	input  uwire logic [63:0]             m_rdata,
	input  uwire logic [1:0]              m_rresp,
	input  uwire logic                    m_rlast,
	input  uwire logic                    m_rvalid,
	output logic                          m_rready
);

	localparam logic [1:0] RESP_OKAY   = 2'b00;
	localparam logic [1:0] RESP_DECERR = 2'b11;
	localparam logic [1:0] BURST_WRAP  = 2'b10;
	// A recognizable pattern in the error response: a plain 0 would not be
	// distinguishable from real memory content in a dump.
	localparam logic [63:0] ERR_DATA   = 64'hBAD0_ADD0_BAD0_ADD0;

	// ------------------------------------------------------------------
	// Window check (burst envelope)
	// ------------------------------------------------------------------
	function automatic logic in_window(input logic [63:0] addr,
	                                   input logic [7:0]  len,
	                                   input logic [2:0]  size,
	                                   input logic [1:0]  burst);
		logic [63:0] total, lo, hi;
		total = (64'(len) + 64'd1) << size;
		// WRAP stays inside the aligned block of the burst length; INCR/FIXED
		// run upward from addr (FIXED is even shorter -- conservative).
		lo = (burst == BURST_WRAP) ? (addr & ~(total - 64'd1)) : addr;
		hi = lo + total - 64'd1;
		return (lo >= WIN_BASE) && (hi < WIN_BASE + WIN_SIZE) && (hi >= lo);
	endfunction

	function automatic logic [M_ADDR_WIDTH-1:0] xlate(input logic [63:0] addr);
		return M_ADDR_WIDTH'((addr - WIN_BASE) + PS_BASE);
	endfunction

	uwire logic [63:0] aw_addr64 = 64'(s_awaddr);
	uwire logic [63:0] ar_addr64 = 64'(s_araddr);
	uwire logic        aw_allow  = in_window(aw_addr64, s_awlen, s_awsize, s_awburst);
	uwire logic        ar_allow  = in_window(ar_addr64, s_arlen, s_arsize, s_arburst);

	// ------------------------------------------------------------------
	// Counters of outstanding master-side transactions (error case only)
	// ------------------------------------------------------------------
	logic [7:0] w_out;    // AW forwarded, data phase not yet finished
	logic [7:0] b_out;    // AW forwarded, B not yet back
	logic [7:0] r_out;    // AR forwarded, RLAST not yet back

	// ------------------------------------------------------------------
	// Write path
	// ------------------------------------------------------------------
	typedef enum logic [1:0] { WJ_IDLE, WJ_SWALLOW, WJ_RESP } wrej_e;
	wrej_e               wrej;
	logic [ID_WIDTH-1:0] wrej_id;

	uwire logic w_drained  = (w_out == 8'd0) && (b_out == 8'd0);
	uwire logic aw_take_ok = (wrej == WJ_IDLE) && aw_allow;
	uwire logic aw_take_rj = (wrej == WJ_IDLE) && !aw_allow && w_drained;

	always_comb begin
		// Address/control channel
		m_awid    = s_awid;
		m_awaddr  = xlate(aw_addr64);
		m_awlen   = s_awlen;
		m_awsize  = s_awsize;
		m_awburst = s_awburst;
		m_awlock  = 1'b0;
		m_awcache = M_CACHE;
		m_awprot  = M_PROT;
		m_awatop  = 6'b0;                       // Rocket resolves the A-extension internally
		m_awvalid = s_awvalid && aw_take_ok;
		s_awready = aw_take_ok ? m_awready : aw_take_rj;

		// Data channel. `w_out != 0` enforces AW-BEFORE-data on the master
		// side: were data beats allowed to run ahead of the address, a beat
		// of a later-REJECTED access could already have gone through and get
		// attributed to the next (allowed) AW -- exactly the silent data
		// corruption the guard is meant to prevent. AXI allows the slave to
		// withhold wready; a master must not make awvalid depend on wready,
		// so no deadlock results from this.
		m_wdata  = s_wdata;
		m_wstrb  = s_wstrb;
		m_wlast  = s_wlast;
		m_wvalid = s_wvalid && (wrej == WJ_IDLE) && (w_out != 8'd0);
		s_wready = (wrej == WJ_SWALLOW) ? 1'b1
		         : ((wrej == WJ_IDLE) && (w_out != 8'd0)) ? m_wready : 1'b0;

		// Response channel
		if (wrej == WJ_RESP) begin
			s_bvalid = 1'b1;
			s_bid    = wrej_id;
			s_bresp  = RESP_DECERR;
			m_bready = 1'b0;
		end
		else begin
			s_bvalid = m_bvalid;
			s_bid    = m_bid;
			s_bresp  = m_bresp;
			m_bready = s_bready;
		end
	end

	// ------------------------------------------------------------------
	// Read path
	// ------------------------------------------------------------------
	typedef enum logic [0:0] { RJ_IDLE, RJ_DATA } rrej_e;
	rrej_e               rrej;
	logic [ID_WIDTH-1:0] rrej_id;
	logic [7:0]          rrej_cnt;

	uwire logic ar_take_ok = (rrej == RJ_IDLE) && ar_allow;
	uwire logic ar_take_rj = (rrej == RJ_IDLE) && !ar_allow && (r_out == 8'd0);

	always_comb begin
		m_arid    = s_arid;
		m_araddr  = xlate(ar_addr64);
		m_arlen   = s_arlen;
		m_arsize  = s_arsize;
		m_arburst = s_arburst;
		m_arlock  = 1'b0;
		m_arcache = M_CACHE;
		m_arprot  = M_PROT;
		m_arvalid = s_arvalid && ar_take_ok;
		s_arready = ar_take_ok ? m_arready : ar_take_rj;

		if (rrej == RJ_DATA) begin
			s_rvalid = 1'b1;
			s_rid    = rrej_id;
			s_rdata  = ERR_DATA;
			s_rresp  = RESP_DECERR;
			s_rlast  = (rrej_cnt == 8'd0);
			m_rready = 1'b0;
		end
		else begin
			s_rvalid = m_rvalid;
			s_rid    = m_rid;
			s_rdata  = m_rdata;
			s_rresp  = m_rresp;
			s_rlast  = m_rlast;
			m_rready = s_rready;
		end
	end

	// ------------------------------------------------------------------
	// State advance + diagnosis
	// ------------------------------------------------------------------
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			wrej      <= WJ_IDLE;
			wrej_id   <= '0;
			rrej      <= RJ_IDLE;
			rrej_id   <= '0;
			rrej_cnt  <= '0;
			w_out     <= '0;
			b_out     <= '0;
			r_out     <= '0;
			err_sticky    <= 1'b0;
			err_was_write <= 1'b0;
			err_count     <= '0;
			err_addr      <= '0;
		end
		else begin
			// --- Counters of outstanding master-side transactions ---
			// One if/else pair per counter: simultaneous increment and
			// decrement would otherwise leave the value at whatever the last
			// assignment wins to (and it would drift).
			if      ((m_awvalid && m_awready) && !(m_wvalid && m_wready && m_wlast)) w_out <= w_out + 8'd1;
			else if (!(m_awvalid && m_awready) && (m_wvalid && m_wready && m_wlast)) w_out <= w_out - 8'd1;

			if      ((m_awvalid && m_awready) && !(m_bvalid && m_bready)) b_out <= b_out + 8'd1;
			else if (!(m_awvalid && m_awready) && (m_bvalid && m_bready)) b_out <= b_out - 8'd1;

			if      ((m_arvalid && m_arready) && !(m_rvalid && m_rready && m_rlast)) r_out <= r_out + 8'd1;
			else if (!(m_arvalid && m_arready) && (m_rvalid && m_rready && m_rlast)) r_out <= r_out - 8'd1;

			// --- Write rejection ---
			unique case (wrej)
				WJ_IDLE: if (s_awvalid && aw_take_rj) begin
					wrej    <= WJ_SWALLOW;
					wrej_id <= s_awid;
				end
				WJ_SWALLOW: if (s_wvalid && s_wlast) wrej <= WJ_RESP;
				WJ_RESP:    if (s_bready)            wrej <= WJ_IDLE;
				default:                             wrej <= WJ_IDLE;
			endcase

			// --- Read rejection ---
			unique case (rrej)
				RJ_IDLE: if (s_arvalid && ar_take_rj) begin
					rrej     <= RJ_DATA;
					rrej_id  <= s_arid;
					rrej_cnt <= s_arlen;
				end
				RJ_DATA: if (s_rready) begin
					if (rrej_cnt == 8'd0) rrej     <= RJ_IDLE;
					else                  rrej_cnt <= rrej_cnt - 8'd1;
				end
				default: rrej <= RJ_IDLE;
			endcase

			// --- Diagnosis ---
			if (err_clear) begin
				err_sticky    <= 1'b0;
				err_was_write <= 1'b0;
				err_count     <= '0;
				err_addr      <= '0;
			end
			else if ((s_awvalid && aw_take_rj) || (s_arvalid && ar_take_rj)) begin
				if (!err_sticky) begin
					err_sticky    <= 1'b1;
					err_was_write <= (s_awvalid && aw_take_rj);
					err_addr      <= (s_awvalid && aw_take_rj) ? aw_addr64 : ar_addr64;
				end
				if (err_count != 32'hFFFF_FFFF) err_count <= err_count + 32'd1;
			end
		end
	end

	// pragma translate_off
	// A rejected access is a FINDING, not the normal case -- it must show up
	// in the sim log, otherwise it gets chased later in a kernel oops instead
	// of here.
	always_ff @(posedge clk_i) begin
		if (rst_ni) begin
			if (s_awvalid && aw_take_rj)
				$display("### WIN_REJECT WRITE addr=%016h len=%0d size=%0d burst=%0d @%0t",
				         aw_addr64, s_awlen, s_awsize, s_awburst, $time);
			if (s_arvalid && ar_take_rj)
				$display("### WIN_REJECT READ  addr=%016h len=%0d size=%0d burst=%0d @%0t",
				         ar_addr64, s_arlen, s_arsize, s_arburst, $time);
		end
	end

	initial begin
		if (PS_BASE + WIN_SIZE > 64'h7000_0000)
			$warning("rocket_mem_window: target window extends past 0x6FFF_FFFF -- SPEC_board_memory_map v3 only reserves 0x6000_0000..0x6FFF_FFFF");
		if (PS_BASE < 64'h6400_0000)
			$warning("rocket_mem_window: target window overlaps the DDR trace sink (starting at 0x6000_0000)");
	end
	// pragma translate_on

endmodule

`default_nettype wire
