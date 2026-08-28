// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Memory path of the Linux CVA6: atomics resolution + address demux.
 *
 * @details
 *   Between the CVA6's AXI4 master and the outside world sit two things:
 *
 *   1. **axi_riscv_atomics_wrap** (PULP, already vendored). The PS HP port
 *      does NOT know AXI4 `atop`, but Linux and its locking primitives use
 *      the A extension. This block resolves `AMO*` into read-modify-write
 *      and runs the reservation table for `LR`/`SC`. Without it no
 *      standard kernel boots (trio finding 2026-07-24: axi_ram_sim asserts
 *      atop == 0).
 *
 *   2. **axi_demux_intf** (PULP): an address boundary separates the DRAM
 *      region (window in the PS DDR) from the PL peripheral registers
 *      (CLINT + console). The demux itself does NOT decode -- the
 *      selection comes from the address comparison here.
 *
 *   Ports are kept flat (like cva6_soc_synth_wrap), so the block fits into
 *   a board top without interface types; the AXI_BUS interfaces live
 *   exclusively internally.
 *
 *   Deliberately NOT included: burst splitting or width conversion. The
 *   peripheral branch goes through axi_to_axi_lite (bursts there are
 *   length 1 by construction, because CLINT/UART only see word accesses);
 *   an assertion catches the case if a burst arrives anyway.
 */
module cva6_linux_mem_xbar #(
	// Peripheral window: [PERIPH_BASE, PERIPH_BASE + PERIPH_SIZE)
	logic [31:0] PERIPH_BASE = 32'h0200_0000,
	logic [31:0] PERIPH_SIZE = 32'h1000_0000,  // covers CLINT 0x0200_0000 + UART 0x1000_0000
	// DRAM window: [DRAM_BASE, DRAM_BASE + DRAM_SIZE). EVERYTHING outside
	// both the DRAM and the peripheral window gets a SLVERR response and
	// NEVER reaches the PS HP port.
	//
	// This is not a luxury but a lesson from 2026-07-27: the CVA6 hangs
	// directly off the PS DDR via HP1 and has NO boundary there -- OpenSBI
	// grants S/U mode the whole 4 GiB address space (Domain0 Region04) and
	// PMP is not populated on this core (PMP Count: 0). A runaway guest
	// kernel could thus overwrite the memory of the HOST Ubuntu; that is
	// exactly what happened next, and the board was no longer reachable
	// and had to be hard power-cycled. With this boundary in place, that
	// becomes a clean bus error the trace shows instead of silent foreign
	// corruption.
	logic [31:0] DRAM_BASE   = 32'h6000_0000,
	logic [31:0] DRAM_SIZE   = 32'h1000_0000,  // reserved PL window v3 (256 MiB)
	int unsigned ID_WIDTH    = 4,
	int unsigned ADDR_WIDTH  = 64,
	int unsigned DATA_WIDTH  = 64,
	int unsigned USER_WIDTH  = 1,
	// XLEN of the attached core (32 = RV32 as before, 64 = RV64). The PULP
	// atomics block derives the AMO operand width from this and REJECTS
	// LARGER ACCESSES (axi_riscv_amos.sv:286:
	// `slv_aw_size_i > $clog2(RISCV_WORD_WIDTH/8)` -> error path). With 32
	// on an RV64 core every `amoadd.d`/`amoswap.d` -- i.e. every kernel
	// spinlock -- then fails. The default stays 32; the RV32 instance in
	// cva6_linux_soc_top is unaffected by this (the RV64 mirror is
	// cva6_linux64_soc_top).
	int unsigned RISCV_WORD_WIDTH = 32
) (
	input  uwire logic clk,
	input  uwire logic rst,                    // active-high

	// --- CVA6 master (flat) --------------------------------------------
	input  uwire logic [ID_WIDTH-1:0]    c_awid,
	input  uwire logic [ADDR_WIDTH-1:0]  c_awaddr,
	input  uwire logic [7:0]             c_awlen,
	input  uwire logic [2:0]             c_awsize,
	input  uwire logic [1:0]             c_awburst,
	input  uwire logic                   c_awlock,
	input  uwire logic [3:0]             c_awcache,
	input  uwire logic [2:0]             c_awprot,
	input  uwire logic [5:0]             c_awatop,
	input  uwire logic                   c_awvalid,
	output      logic                    c_awready,
	input  uwire logic [DATA_WIDTH-1:0]  c_wdata,
	input  uwire logic [DATA_WIDTH/8-1:0] c_wstrb,
	input  uwire logic                   c_wlast,
	input  uwire logic                   c_wvalid,
	output      logic                    c_wready,
	output      logic [ID_WIDTH-1:0]     c_bid,
	output      logic [1:0]              c_bresp,
	output      logic                    c_bvalid,
	input  uwire logic                   c_bready,
	input  uwire logic [ID_WIDTH-1:0]    c_arid,
	input  uwire logic [ADDR_WIDTH-1:0]  c_araddr,
	input  uwire logic [7:0]             c_arlen,
	input  uwire logic [2:0]             c_arsize,
	input  uwire logic [1:0]             c_arburst,
	input  uwire logic                   c_arlock,
	input  uwire logic [3:0]             c_arcache,
	input  uwire logic [2:0]             c_arprot,
	input  uwire logic                   c_arvalid,
	output      logic                    c_arready,
	output      logic [ID_WIDTH-1:0]     c_rid,
	output      logic [DATA_WIDTH-1:0]   c_rdata,
	output      logic [1:0]              c_rresp,
	output      logic                    c_rlast,
	output      logic                    c_rvalid,
	input  uwire logic                   c_rready,

	// --- DRAM branch (flat, to PS HP resp. axi_ram_sim) -------------------
	output      logic [ID_WIDTH-1:0]     m_awid,
	output      logic [ADDR_WIDTH-1:0]   m_awaddr,
	output      logic [7:0]              m_awlen,
	output      logic [2:0]              m_awsize,
	output      logic [1:0]              m_awburst,
	output      logic                    m_awlock,
	output      logic [3:0]              m_awcache,
	output      logic [2:0]              m_awprot,
	output      logic [5:0]              m_awatop,   // is 0 by construction
	output      logic                    m_awvalid,
	input  uwire logic                   m_awready,
	output      logic [DATA_WIDTH-1:0]   m_wdata,
	output      logic [DATA_WIDTH/8-1:0] m_wstrb,
	output      logic                    m_wlast,
	output      logic                    m_wvalid,
	input  uwire logic                   m_wready,
	input  uwire logic [ID_WIDTH-1:0]    m_bid,
	input  uwire logic [1:0]             m_bresp,
	input  uwire logic                   m_bvalid,
	output      logic                    m_bready,
	output      logic [ID_WIDTH-1:0]     m_arid,
	output      logic [ADDR_WIDTH-1:0]   m_araddr,
	output      logic [7:0]              m_arlen,
	output      logic [2:0]              m_arsize,
	output      logic [1:0]              m_arburst,
	output      logic                    m_arlock,
	output      logic [3:0]              m_arcache,
	output      logic [2:0]              m_arprot,
	output      logic                    m_arvalid,
	input  uwire logic                   m_arready,
	input  uwire logic [ID_WIDTH-1:0]    m_rid,
	input  uwire logic [DATA_WIDTH-1:0]  m_rdata,
	input  uwire logic [1:0]             m_rresp,
	input  uwire logic                   m_rlast,
	input  uwire logic                   m_rvalid,
	output      logic                    m_rready,

	// --- Peripheral branch (AXI4-Lite, to cva6_linux_periph) --------------
	output      logic [31:0]             p_awaddr,
	output      logic                    p_awvalid,
	input  uwire logic                   p_awready,
	output      logic [DATA_WIDTH-1:0]   p_wdata,
	output      logic [DATA_WIDTH/8-1:0] p_wstrb,
	output      logic                    p_wvalid,
	input  uwire logic                   p_wready,
	input  uwire logic [1:0]             p_bresp,
	input  uwire logic                   p_bvalid,
	output      logic                    p_bready,
	output      logic [31:0]             p_araddr,
	output      logic                    p_arvalid,
	input  uwire logic                   p_arready,
	input  uwire logic [DATA_WIDTH-1:0]  p_rdata,
	input  uwire logic [1:0]             p_rresp,
	input  uwire logic                   p_rvalid,
	output      logic                    p_rready
);

	uwire logic rst_n = ~rst;

	// ------------------------------------------------------------------
	// 1. CVA6 master -> AXI_BUS
	// ------------------------------------------------------------------
	AXI_BUS #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH),
		.AXI_ID_WIDTH(ID_WIDTH),     .AXI_USER_WIDTH(USER_WIDTH)
	) cpu (), cpu_amo ();

	// The demux's master ports are an interface ARRAY. Two pitfalls here,
	// both found 2026-07-26 in the unit TB:
	//   (a) a concatenation {br_per, br_mem} is NOT a valid connection --
	//       it compiles, but does not connect.
	//   (b) the index direction MUST match the port declaration. The port
	//       is `mst [NO_MST_PORTS-1:0]` (descending); an ascending-declared
	//       `br [2]` then maps br[0] onto mst[1] -- the access silently
	//       landed on the wrong branch (select 0 = DRAM, data went to the
	//       peripheral). Hence explicitly descending here.
	AXI_BUS #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH),
		.AXI_ID_WIDTH(ID_WIDTH),     .AXI_USER_WIDTH(USER_WIDTH)
	) br [2:0] ();   // [0]=DRAM, [1]=peripheral, [2]=error slave

	assign cpu.aw_id     = c_awid;
	assign cpu.aw_addr   = c_awaddr;
	assign cpu.aw_len    = c_awlen;
	assign cpu.aw_size   = c_awsize;
	assign cpu.aw_burst  = c_awburst;
	assign cpu.aw_lock   = c_awlock;
	assign cpu.aw_cache  = c_awcache;
	assign cpu.aw_prot   = c_awprot;
	assign cpu.aw_qos    = '0;
	assign cpu.aw_region = '0;
	assign cpu.aw_atop   = c_awatop;
	assign cpu.aw_user   = '0;
	assign cpu.aw_valid  = c_awvalid;
	assign c_awready     = cpu.aw_ready;
	assign cpu.w_data    = c_wdata;
	assign cpu.w_strb    = c_wstrb;
	assign cpu.w_last    = c_wlast;
	assign cpu.w_user    = '0;
	assign cpu.w_valid   = c_wvalid;
	assign c_wready      = cpu.w_ready;
	assign c_bid         = cpu.b_id;
	assign c_bresp       = cpu.b_resp;
	assign c_bvalid      = cpu.b_valid;
	assign cpu.b_ready   = c_bready;
	assign cpu.ar_id     = c_arid;
	assign cpu.ar_addr   = c_araddr;
	assign cpu.ar_len    = c_arlen;
	assign cpu.ar_size   = c_arsize;
	assign cpu.ar_burst  = c_arburst;
	assign cpu.ar_lock   = c_arlock;
	assign cpu.ar_cache  = c_arcache;
	assign cpu.ar_prot   = c_arprot;
	assign cpu.ar_qos    = '0;
	assign cpu.ar_region = '0;
	assign cpu.ar_user   = '0;
	assign cpu.ar_valid  = c_arvalid;
	assign c_arready     = cpu.ar_ready;
	assign c_rid         = cpu.r_id;
	assign c_rdata       = cpu.r_data;
	assign c_rresp       = cpu.r_resp;
	assign c_rlast       = cpu.r_last;
	assign c_rvalid      = cpu.r_valid;
	assign cpu.r_ready   = c_rready;

	// ------------------------------------------------------------------
	// 2. Atomics: AMO -> RMW, LR/SC reservation table
	// ------------------------------------------------------------------
	axi_riscv_atomics_wrap #(
		.AXI_ADDR_WIDTH     (ADDR_WIDTH),
		.AXI_DATA_WIDTH     (DATA_WIDTH),
		.AXI_ID_WIDTH       (ID_WIDTH),
		.AXI_USER_WIDTH     (USER_WIDTH),
		// Only AXI_MAX_WRITE_TXNS exists here (read accesses bypass the
		// atomics block) -- an extra AXI_MAX_READ_TXNS was silently
		// swallowed by XSIM, Vivado rightly rejects it (Synth 8-7136).
		// Only synthesis found the typo.
		.AXI_MAX_WRITE_TXNS (4),
		.RISCV_WORD_WIDTH   (RISCV_WORD_WIDTH)   // 32 = RV32, 64 = RV64
	) atomics (
		.clk_i  (clk),
		.rst_ni (rst_n),
		.slv    (cpu),
		.mst    (cpu_amo)
	);

	// ------------------------------------------------------------------
	// 3. Address demux: peripheral window vs. DRAM
	// ------------------------------------------------------------------
	function automatic logic is_periph(input logic [ADDR_WIDTH-1:0] a);
		return (a >= ADDR_WIDTH'(PERIPH_BASE))
		    && (a <  ADDR_WIDTH'(PERIPH_BASE) + ADDR_WIDTH'(PERIPH_SIZE));
	endfunction

	function automatic logic is_dram(input logic [ADDR_WIDTH-1:0] a);
		return (a >= ADDR_WIDTH'(DRAM_BASE))
		    && (a <  ADDR_WIDTH'(DRAM_BASE) + ADDR_WIDTH'(DRAM_SIZE));
	endfunction

	// 0 = DRAM, 1 = peripheral, 2 = error slave (everything outside both windows)
	function automatic logic [1:0] sel_of(input logic [ADDR_WIDTH-1:0] a);
		if      (is_periph(a)) sel_of = 2'd1;
		else if (is_dram(a))   sel_of = 2'd0;
		else                   sel_of = 2'd2;
	endfunction

	uwire logic [1:0] aw_sel = sel_of(cpu_amo.aw_addr);
	uwire logic [1:0] ar_sel = sel_of(cpu_amo.ar_addr);

	axi_demux_intf #(
		.AXI_ID_WIDTH   (ID_WIDTH),
		.AXI_ADDR_WIDTH (ADDR_WIDTH),
		.AXI_DATA_WIDTH (DATA_WIDTH),
		.AXI_USER_WIDTH (USER_WIDTH),
		.NO_MST_PORTS   (3),
		.MAX_TRANS      (4),
		.UNIQUE_IDS     (1'b0)
	) demux (
		.clk_i           (clk),
		.rst_ni          (rst_n),
		.test_i          (1'b0),
		.slv_aw_select_i (aw_sel),
		.slv_ar_select_i (ar_sel),
		.slv             (cpu_amo),
		.mst             (br)   // br[0]=DRAM, br[1]=peripheral, br[2]=error
	);

	// Error slave: responds with SLVERR instead of letting the access
	// through. PULP only supplies axi_err_slv in the struct variant, we
	// need it at the AXI_BUS interface -- hence written directly here,
	// small and fully under our own control. A burst is correctly drained
	// (accept all W beats resp. deliver all R beats), otherwise the bus
	// hangs.
	logic [ID_WIDTH-1:0] err_bid_q, err_rid_q;
	logic                err_bvalid_q, err_rvalid_q;
	logic [7:0]          err_rcnt_q;
	logic                err_w_active_q;

	always_ff @(posedge clk) begin
		if (rst) begin
			err_bvalid_q <= 1'b0; err_rvalid_q <= 1'b0;
			err_rcnt_q <= '0; err_w_active_q <= 1'b0;
			err_bid_q <= '0; err_rid_q <= '0;
		end
		else begin
			// --- write: accept AW, swallow W beats, then B ---
			if (br[2].aw_valid && br[2].aw_ready) begin
				err_bid_q      <= br[2].aw_id;
				err_w_active_q <= 1'b1;
			end
			if (err_w_active_q && br[2].w_valid && br[2].w_ready && br[2].w_last) begin
				err_w_active_q <= 1'b0;
				err_bvalid_q   <= 1'b1;
			end
			if (err_bvalid_q && br[2].b_ready) err_bvalid_q <= 1'b0;

			// --- read: accept AR, deliver arlen+1 beats with SLVERR ---
			if (br[2].ar_valid && br[2].ar_ready) begin
				err_rid_q    <= br[2].ar_id;
				err_rcnt_q   <= br[2].ar_len;
				err_rvalid_q <= 1'b1;
			end
			else if (err_rvalid_q && br[2].r_ready) begin
				if (err_rcnt_q == 8'd0) err_rvalid_q <= 1'b0;
				else                    err_rcnt_q   <= err_rcnt_q - 8'd1;
			end
		end
	end

	assign br[2].aw_ready = !err_w_active_q && !err_bvalid_q;
	assign br[2].w_ready  = err_w_active_q;
	assign br[2].b_id     = err_bid_q;
	assign br[2].b_resp   = 2'b10;            // SLVERR
	assign br[2].b_user   = '0;
	assign br[2].b_valid  = err_bvalid_q;
	assign br[2].ar_ready = !err_rvalid_q;
	assign br[2].r_id     = err_rid_q;
	assign br[2].r_data   = '0;
	assign br[2].r_resp   = 2'b10;            // SLVERR
	assign br[2].r_last   = err_rvalid_q && (err_rcnt_q == 8'd0);
	assign br[2].r_user   = '0;
	assign br[2].r_valid  = err_rvalid_q;

`ifndef SYNTHESIS
	always_ff @(posedge clk) begin
		if (rst_n && br[2].aw_valid && br[2].aw_ready)
			$display("[xbar] SLVERR: write access outside the windows @0x%h", br[2].aw_addr);
		if (rst_n && br[2].ar_valid && br[2].ar_ready)
			$display("[xbar] SLVERR: read access outside the windows @0x%h", br[2].ar_addr);
	end
`endif

	// ------------------------------------------------------------------
	// 4a. DRAM branch -> flat ports
	// ------------------------------------------------------------------
	assign m_awid       = br[0].aw_id;
	assign m_awaddr     = br[0].aw_addr;
	assign m_awlen      = br[0].aw_len;
	assign m_awsize     = br[0].aw_size;
	assign m_awburst    = br[0].aw_burst;
	assign m_awlock     = br[0].aw_lock;
	assign m_awcache    = br[0].aw_cache;
	assign m_awprot     = br[0].aw_prot;
	assign m_awatop     = br[0].aw_atop;
	assign m_awvalid    = br[0].aw_valid;
	assign br[0].aw_ready = m_awready;
	assign m_wdata      = br[0].w_data;
	assign m_wstrb      = br[0].w_strb;
	assign m_wlast      = br[0].w_last;
	assign m_wvalid     = br[0].w_valid;
	assign br[0].w_ready = m_wready;
	assign br[0].b_id   = m_bid;
	assign br[0].b_resp = m_bresp;
	assign br[0].b_user = '0;
	assign br[0].b_valid = m_bvalid;
	assign m_bready     = br[0].b_ready;
	assign m_arid       = br[0].ar_id;
	assign m_araddr     = br[0].ar_addr;
	assign m_arlen      = br[0].ar_len;
	assign m_arsize     = br[0].ar_size;
	assign m_arburst    = br[0].ar_burst;
	assign m_arlock     = br[0].ar_lock;
	assign m_arcache    = br[0].ar_cache;
	assign m_arprot     = br[0].ar_prot;
	assign m_arvalid    = br[0].ar_valid;
	assign br[0].ar_ready = m_arready;
	assign br[0].r_id   = m_rid;
	assign br[0].r_data = m_rdata;
	assign br[0].r_resp = m_rresp;
	assign br[0].r_last = m_rlast;
	assign br[0].r_user = '0;
	assign br[0].r_valid = m_rvalid;
	assign m_rready     = br[0].r_ready;

	// ------------------------------------------------------------------
	// 4b. Peripheral branch -> AXI4-Lite
	// ------------------------------------------------------------------
	AXI_LITE #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH)
	) per_lite ();

	axi_to_axi_lite_intf #(
		.AXI_ADDR_WIDTH     (ADDR_WIDTH),
		.AXI_DATA_WIDTH     (DATA_WIDTH),
		.AXI_ID_WIDTH       (ID_WIDTH),
		.AXI_USER_WIDTH     (USER_WIDTH),
		.AXI_MAX_WRITE_TXNS (2),
		.AXI_MAX_READ_TXNS  (2),
		.FALL_THROUGH       (1'b1)
	) per_bridge (
		.clk_i     (clk),
		.rst_ni    (rst_n),
		.testmode_i(1'b0),
		.slv       (br[1]),
		.mst       (per_lite)
	);

	assign p_awaddr      = per_lite.aw_addr[31:0];
	assign p_awvalid     = per_lite.aw_valid;
	assign per_lite.aw_ready = p_awready;
	assign p_wdata       = per_lite.w_data;
	assign p_wstrb       = per_lite.w_strb;
	assign p_wvalid      = per_lite.w_valid;
	assign per_lite.w_ready = p_wready;
	assign per_lite.b_resp = p_bresp;
	assign per_lite.b_valid = p_bvalid;
	assign p_bready      = per_lite.b_ready;
	assign p_araddr      = per_lite.ar_addr[31:0];
	assign p_arvalid     = per_lite.ar_valid;
	assign per_lite.ar_ready = p_arready;
	assign per_lite.r_data = p_rdata;
	assign per_lite.r_resp = p_rresp;
	assign per_lite.r_valid = p_rvalid;
	assign p_rready      = per_lite.r_ready;

`ifndef SYNTHESIS
	// The point of the atomics adapter in one line: behind it, an atop
	// access must NEVER appear (the PS's HP port cannot handle it).
	always_ff @(posedge clk) begin
		if (rst_n && m_awvalid) begin
			assert (m_awatop == 6'b0)
				else $error("cva6_linux_mem_xbar: atop=0x%02x reached the DRAM port -- atomics adapter ineffective", m_awatop);
		end
	end
`endif

endmodule

`default_nettype wire
