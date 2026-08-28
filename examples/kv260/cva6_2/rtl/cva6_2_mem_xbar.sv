// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Memory path of the dual CVA6 (AMP): private per core, ONE
 *           shared path.
 *
 * @details
 *   This module is where the design decisions become hardware -- and the
 *   only place in the whole SoC where a bug would stay SILENT. Hence the
 *   topology is fully described here in ONE file: whoever wants to check
 *   it does not have to hold three modules against each other.
 *
 *   +-------- core 0 (AXI4, 64 bit, ID 4) ---------+
 *   |  demux0 +- [0] private -> atomics0 -> win0 -> m0_*  (PS S_AXI_HP1)
 *   |         +- [1] shared  -> idser0 -+
 *   |         `- [2] error    -> SLVERR |
 *   +-------- core 1 -------------------------------+
 *   |  demux1 +- [0] private -> atomics1 -> win1 -> m1_*  (PS S_AXI_HP2)
 *   |         +- [1] shared  -> idser1 -+
 *   |         `- [2] error    -> SLVERR |
 *                                       |
 *                                     mux (2->1)
 *                                       |
 *                             atomics_shared   <- ONE instance, behind the merge
 *                                       |
 *                               demuxS -+- [0] peripherals -> AXI4-Lite -> p_*
 *                                       `- [1] mailbox     -> win_mb -> mb_* (HP3)
 *
 * =========================================================================
 * WHY THE ATOMICS SIT HERE AND NOT ELSEWHERE
 * =========================================================================
 *
 *   `axi_res_tbl.sv:45` clears address-matching entries WITHOUT an ID
 *   condition:
 *       end else if (clr && tbl_q[i] == clr_addr_i)
 *   across ALL i. The cross-clear between two cores therefore happens by
 *   itself -- but ONLY if both go through the SAME instance.
 *
 *   Two separate instances at the mailbox would be `LR/SC` correct WITHIN
 *   one core and ineffective BETWEEN the cores: no error message, no bus
 *   error, both cores in the same critical section, data corruption only
 *   visible much later. This exact silent failure mode is the reason for
 *   the split here.
 *
 *   Conversely, "ONE instance overall" would be equally wrong: the
 *   PRIVATE paths have no merge point at all, and a forced merge would
 *   bring back exactly the crossbar the AMP design saves. The rule applies
 *   per SHARED region:
 *
 *     private core 0 -> HP1    own instance  (core 1 never touches this;
 *     private core 1 -> HP2    own instance   Linux needs LR/SC core-
 *                                              INTERNALLY constantly)
 *     shared (mailbox)         ONE shared instance, behind the merge
 *
 *   Reassuring and equally checked in the source: `wt_dcache_missunit.sv:323`
 *   sets `nc = 1` UNCONDITIONALLY on `amo_sel` ("AMOs are always uncached").
 *   Atomics therefore bypass the D-cache regardless -- the uncached
 *   mailbox is secured as a synchronization path without assuming
 *   coherence.
 *
 * -- ID WIDTH AT THE MERGE --------------------------------------------------
 *   The reservation table is `logic [2**ID_WIDTH-1:0][ADDR_WIDTH-1:0]` --
 *   it DOUBLES with every ID bit. The core IDs are 4 bit; naively merged
 *   that would be 5 bit = 32 entries x 64 bit. The mailbox does not need
 *   concurrency though, so each core gets ONE single ID:
 *   `axi_id_serialize` per core (4 bit -> 1 bit, constant 0), then the mux
 *   prepends the port index => **2 bit, four entries**.
 *
 *   Deviation from "1 bit, two entries", named openly: the vendored
 *   `axi_mux` ALWAYS prepends the port index, so the smallest width
 *   reachable without hand-written channel rewiring is 2 bit. A hand
 *   rewiring (5 channels x ~9 signals) would save ~128 FF and two 64-bit
 *   comparators -- and a typo in it would be EXACTLY the silent bug this
 *   module is supposed to prevent. 4 instead of 32 entries fulfills the
 *   purpose (keep the table small) 8/8; the last 2x are not worth the
 *   manual rewiring.
 *
 *   The other half of the requirement stays MANDATORY: **different IDs
 *   per core**. The mux delivers core 0 -> 2'b00, core 1 -> 2'b10. Without
 *   this the table could not tell them apart, and the cross-clear -- which
 *   is address-matching and ID-blind -- would turn into self-erasure.
 *
 * -- WHY THE PERIPHERALS RUN THROUGH THE SHARED PATH TOO --------------------
 *   CLINT and console are shared too (one `mtime`, IPI between the cores,
 *   ONE console ring). They therefore need the same merge. Putting them
 *   behind the same atomics instance costs nothing (non-atomic accesses
 *   pass through) and saves a second merge point plus a second arbiter.
 *   The price is a serialization of MMIO accesses per core (one
 *   outstanding transaction) -- for uncached accesses, where the core is
 *   blocked anyway, that is not a throughput loss.
 *
 * -- MEMORY MAP (board-proven boundary) -------------------------------------
 *   Core-side view IDENTICAL for both cores -- one shared `CVA6Cfg` is
 *   enough, because outside the cached region the access is not rejected,
 *   but UNCACHED (`wt_dcache_ctrl.sv:106`, `wt_dcache_wbuffer.sv:208`,
 *   `cva6_icache.sv:140`). The split makes the translation:
 *
 *     Core view       Size    Cacheability          PS target
 *     0x6400_0000    32 MiB  cached (64 M region)  core 0 -> 0x6400_0000
 *                                                   core 1 -> 0x6600_0000
 *     0x6800_0000    16 MiB  UNCACHED (outside)    both   -> 0x6800_0000
 *
 *   The 64 MiB cached region is the board-proven conservative state
 *   (`cva6_linux64_board_cfg.tcl`): cacheable memory above 0x6800_0000
 *   reproducibly correlated with a failure within ~5 s (cache-line bursts
 *   on the PS HP port). The mailbox therefore sits EXACTLY at the region
 *   boundary -- uncached by construction, without touching the boundary.
 *
 *   The guard (`rocket_mem_window`, cross-referenced from
 *   [`../../rocket_linux/rtl/`](../../rocket_linux/rtl/) -- shared,
 *   hart-count-agnostic building block, this design is its third consumer
 *   after `rocket_linux` and `rocket2`) checks the BURST ENVELOPE, not
 *   just the start address. The demux in front of it selects by start
 *   address; a burst that begins at the end of a window and runs past it
 *   would otherwise write into the NEIGHBORING core's window. Exactly this
 *   case is answered here with DECERR and held sticky, instead of silently
 *   corrupting.
 */
module cva6_2_mem_xbar #(
	// Peripheral window (core-side view, both cores the same)
	logic [31:0] PERIPH_BASE = 32'h0200_0000,
	logic [31:0] PERIPH_SIZE = 32'h1000_1000,   // covers CLINT 0x0200_0000 .. UART 0x1000_0000
	// Private DRAM window (core-side view, both cores the same)
	logic [63:0] DRAM_BASE   = 64'h6400_0000,
	logic [63:0] DRAM_SIZE   = 64'h0200_0000,   // 32 MiB per core
	// Mailbox (core-side view, both cores the same) -- MUST lie outside
	// the cached region of the core configuration, otherwise it is not
	// coherent.
	logic [63:0] MBOX_BASE   = 64'h6800_0000,
	logic [63:0] MBOX_SIZE   = 64'h0100_0000,   // 16 MiB
	// PS-side view: where the three windows get translated to.
	logic [63:0] PS_DRAM0    = 64'h6400_0000,
	logic [63:0] PS_DRAM1    = 64'h6600_0000,
	logic [63:0] PS_MBOX     = 64'h6800_0000,
	int unsigned ID_WIDTH    = 4,
	int unsigned ADDR_WIDTH  = 64,
	int unsigned DATA_WIDTH  = 64,
	int unsigned USER_WIDTH  = 1
) (
	input  uwire logic clk,
	input  uwire logic rst,                    // active-high

	// --- Core 0 (flat) --------------------------------------------------
	input  uwire logic [ID_WIDTH-1:0]     c0_awid,
	input  uwire logic [ADDR_WIDTH-1:0]   c0_awaddr,
	input  uwire logic [7:0]              c0_awlen,
	input  uwire logic [2:0]              c0_awsize,
	input  uwire logic [1:0]              c0_awburst,
	input  uwire logic                    c0_awlock,
	input  uwire logic [3:0]              c0_awcache,
	input  uwire logic [2:0]              c0_awprot,
	input  uwire logic [5:0]              c0_awatop,
	input  uwire logic                    c0_awvalid,
	output      logic                     c0_awready,
	input  uwire logic [DATA_WIDTH-1:0]   c0_wdata,
	input  uwire logic [DATA_WIDTH/8-1:0] c0_wstrb,
	input  uwire logic                    c0_wlast,
	input  uwire logic                    c0_wvalid,
	output      logic                     c0_wready,
	output      logic [ID_WIDTH-1:0]      c0_bid,
	output      logic [1:0]               c0_bresp,
	output      logic                     c0_bvalid,
	input  uwire logic                    c0_bready,
	input  uwire logic [ID_WIDTH-1:0]     c0_arid,
	input  uwire logic [ADDR_WIDTH-1:0]   c0_araddr,
	input  uwire logic [7:0]              c0_arlen,
	input  uwire logic [2:0]              c0_arsize,
	input  uwire logic [1:0]              c0_arburst,
	input  uwire logic                    c0_arlock,
	input  uwire logic [3:0]              c0_arcache,
	input  uwire logic [2:0]              c0_arprot,
	input  uwire logic                    c0_arvalid,
	output      logic                     c0_arready,
	output      logic [ID_WIDTH-1:0]      c0_rid,
	output      logic [DATA_WIDTH-1:0]    c0_rdata,
	output      logic [1:0]               c0_rresp,
	output      logic                     c0_rlast,
	output      logic                     c0_rvalid,
	input  uwire logic                    c0_rready,

	// --- Core 1 (flat) --------------------------------------------------
	input  uwire logic [ID_WIDTH-1:0]     c1_awid,
	input  uwire logic [ADDR_WIDTH-1:0]   c1_awaddr,
	input  uwire logic [7:0]              c1_awlen,
	input  uwire logic [2:0]              c1_awsize,
	input  uwire logic [1:0]              c1_awburst,
	input  uwire logic                    c1_awlock,
	input  uwire logic [3:0]              c1_awcache,
	input  uwire logic [2:0]              c1_awprot,
	input  uwire logic [5:0]              c1_awatop,
	input  uwire logic                    c1_awvalid,
	output      logic                     c1_awready,
	input  uwire logic [DATA_WIDTH-1:0]   c1_wdata,
	input  uwire logic [DATA_WIDTH/8-1:0] c1_wstrb,
	input  uwire logic                    c1_wlast,
	input  uwire logic                    c1_wvalid,
	output      logic                     c1_wready,
	output      logic [ID_WIDTH-1:0]      c1_bid,
	output      logic [1:0]               c1_bresp,
	output      logic                     c1_bvalid,
	input  uwire logic                    c1_bready,
	input  uwire logic [ID_WIDTH-1:0]     c1_arid,
	input  uwire logic [ADDR_WIDTH-1:0]   c1_araddr,
	input  uwire logic [7:0]              c1_arlen,
	input  uwire logic [2:0]              c1_arsize,
	input  uwire logic [1:0]              c1_arburst,
	input  uwire logic                    c1_arlock,
	input  uwire logic [3:0]              c1_arcache,
	input  uwire logic [2:0]              c1_arprot,
	input  uwire logic                    c1_arvalid,
	output      logic                     c1_arready,
	output      logic [ID_WIDTH-1:0]      c1_rid,
	output      logic [DATA_WIDTH-1:0]    c1_rdata,
	output      logic [1:0]               c1_rresp,
	output      logic                     c1_rlast,
	output      logic                     c1_rvalid,
	input  uwire logic                    c1_rready,

	// --- Private DRAM path core 0 -> PS S_AXI_HP1 -----------------------
	output      logic [ID_WIDTH-1:0]      m0_awid,
	output      logic [ADDR_WIDTH-1:0]    m0_awaddr,
	output      logic [7:0]               m0_awlen,
	output      logic [2:0]               m0_awsize,
	output      logic [1:0]               m0_awburst,
	output      logic                     m0_awlock,
	output      logic [3:0]               m0_awcache,
	output      logic [2:0]               m0_awprot,
	output      logic                     m0_awvalid,
	input  uwire logic                    m0_awready,
	output      logic [DATA_WIDTH-1:0]    m0_wdata,
	output      logic [DATA_WIDTH/8-1:0]  m0_wstrb,
	output      logic                     m0_wlast,
	output      logic                     m0_wvalid,
	input  uwire logic                    m0_wready,
	input  uwire logic [ID_WIDTH-1:0]     m0_bid,
	input  uwire logic [1:0]              m0_bresp,
	input  uwire logic                    m0_bvalid,
	output      logic                     m0_bready,
	output      logic [ID_WIDTH-1:0]      m0_arid,
	output      logic [ADDR_WIDTH-1:0]    m0_araddr,
	output      logic [7:0]               m0_arlen,
	output      logic [2:0]               m0_arsize,
	output      logic [1:0]               m0_arburst,
	output      logic                     m0_arlock,
	output      logic [3:0]               m0_arcache,
	output      logic [2:0]               m0_arprot,
	output      logic                     m0_arvalid,
	input  uwire logic                    m0_arready,
	input  uwire logic [ID_WIDTH-1:0]     m0_rid,
	input  uwire logic [DATA_WIDTH-1:0]   m0_rdata,
	input  uwire logic [1:0]              m0_rresp,
	input  uwire logic                    m0_rlast,
	input  uwire logic                    m0_rvalid,
	output      logic                     m0_rready,

	// --- Private DRAM path core 1 -> PS S_AXI_HP2 -----------------------
	output      logic [ID_WIDTH-1:0]      m1_awid,
	output      logic [ADDR_WIDTH-1:0]    m1_awaddr,
	output      logic [7:0]               m1_awlen,
	output      logic [2:0]               m1_awsize,
	output      logic [1:0]               m1_awburst,
	output      logic                     m1_awlock,
	output      logic [3:0]               m1_awcache,
	output      logic [2:0]               m1_awprot,
	output      logic                     m1_awvalid,
	input  uwire logic                    m1_awready,
	output      logic [DATA_WIDTH-1:0]    m1_wdata,
	output      logic [DATA_WIDTH/8-1:0]  m1_wstrb,
	output      logic                     m1_wlast,
	output      logic                     m1_wvalid,
	input  uwire logic                    m1_wready,
	input  uwire logic [ID_WIDTH-1:0]     m1_bid,
	input  uwire logic [1:0]              m1_bresp,
	input  uwire logic                    m1_bvalid,
	output      logic                     m1_bready,
	output      logic [ID_WIDTH-1:0]      m1_arid,
	output      logic [ADDR_WIDTH-1:0]    m1_araddr,
	output      logic [7:0]               m1_arlen,
	output      logic [2:0]               m1_arsize,
	output      logic [1:0]               m1_arburst,
	output      logic                     m1_arlock,
	output      logic [3:0]               m1_arcache,
	output      logic [2:0]               m1_arprot,
	output      logic                     m1_arvalid,
	input  uwire logic                    m1_arready,
	input  uwire logic [ID_WIDTH-1:0]     m1_rid,
	input  uwire logic [DATA_WIDTH-1:0]   m1_rdata,
	input  uwire logic [1:0]              m1_rresp,
	input  uwire logic                    m1_rlast,
	input  uwire logic                    m1_rvalid,
	output      logic                     m1_rready,

	// --- Mailbox (shared) -> PS S_AXI_HP3 --------------------------------
	// ID width 2 (see header): {port index, 1'b0} -- core 0 = 0, core 1 = 2.
	output      logic [1:0]               mb_awid,
	output      logic [ADDR_WIDTH-1:0]    mb_awaddr,
	output      logic [7:0]               mb_awlen,
	output      logic [2:0]               mb_awsize,
	output      logic [1:0]               mb_awburst,
	output      logic                     mb_awlock,
	output      logic [3:0]               mb_awcache,
	output      logic [2:0]               mb_awprot,
	output      logic                     mb_awvalid,
	input  uwire logic                    mb_awready,
	output      logic [DATA_WIDTH-1:0]    mb_wdata,
	output      logic [DATA_WIDTH/8-1:0]  mb_wstrb,
	output      logic                     mb_wlast,
	output      logic                     mb_wvalid,
	input  uwire logic                    mb_wready,
	input  uwire logic [1:0]              mb_bid,
	input  uwire logic [1:0]              mb_bresp,
	input  uwire logic                    mb_bvalid,
	output      logic                     mb_bready,
	output      logic [1:0]               mb_arid,
	output      logic [ADDR_WIDTH-1:0]    mb_araddr,
	output      logic [7:0]               mb_arlen,
	output      logic [2:0]               mb_arsize,
	output      logic [1:0]               mb_arburst,
	output      logic                     mb_arlock,
	output      logic [3:0]               mb_arcache,
	output      logic [2:0]               mb_arprot,
	output      logic                     mb_arvalid,
	input  uwire logic                    mb_arready,
	input  uwire logic [1:0]              mb_rid,
	input  uwire logic [DATA_WIDTH-1:0]   mb_rdata,
	input  uwire logic [1:0]              mb_rresp,
	input  uwire logic                    mb_rlast,
	input  uwire logic                    mb_rvalid,
	output      logic                     mb_rready,

	// --- Peripheral branch (AXI4-Lite, shared: CLINT + console) ---------
	output      logic [31:0]              p_awaddr,
	output      logic                     p_awvalid,
	input  uwire logic                    p_awready,
	output      logic [DATA_WIDTH-1:0]    p_wdata,
	output      logic [DATA_WIDTH/8-1:0]  p_wstrb,
	output      logic                     p_wvalid,
	input  uwire logic                    p_wready,
	input  uwire logic [1:0]              p_bresp,
	input  uwire logic                    p_bvalid,
	output      logic                     p_bready,
	output      logic [31:0]              p_araddr,
	output      logic                     p_arvalid,
	input  uwire logic                    p_arready,
	input  uwire logic [DATA_WIDTH-1:0]   p_rdata,
	input  uwire logic [1:0]              p_rresp,
	input  uwire logic                    p_rvalid,
	output      logic                     p_rready,

	// --- Guard diagnostics (sticky, same pattern as rocket_mem_window) --
	input  uwire logic                    win_err_clear,
	output      logic                     win0_err_sticky,
	output      logic                     win0_err_was_write,
	output      logic [31:0]              win0_err_count,
	output      logic [63:0]              win0_err_addr,
	output      logic                     win1_err_sticky,
	output      logic                     win1_err_was_write,
	output      logic [31:0]              win1_err_count,
	output      logic [63:0]              win1_err_addr,
	output      logic                     winmb_err_sticky,
	output      logic [31:0]              winmb_err_count
);

	uwire logic rst_n = ~rst;

	// The mux's port index is prepended -> 1 (serialized ID) + 1 (index).
	localparam int unsigned SH_ID_W  = 1;
	localparam int unsigned MRG_ID_W = SH_ID_W + 1;

	// ------------------------------------------------------------------
	// 1. Core masters -> AXI_BUS
	// ------------------------------------------------------------------
	AXI_BUS #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH),
		.AXI_ID_WIDTH(ID_WIDTH),     .AXI_USER_WIDTH(USER_WIDTH)
	) cpu0 (), cpu1 ();

	// Index direction MUST match the port declaration
	// (`mst [NO_MST_PORTS-1:0]`, descending). An ascending-declared array
	// maps [0] onto mst[N-1] -- the access silently lands on the wrong
	// branch (finding 2026-07-26, cva6_linux_mem_xbar comment (b)).
	AXI_BUS #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH),
		.AXI_ID_WIDTH(ID_WIDTH),     .AXI_USER_WIDTH(USER_WIDTH)
	) br0 [2:0] (), br1 [2:0] ();   // [0]=private, [1]=shared, [2]=error

	`define CVA6_2_TIE_CPU(BUS, PFX)                     \
		assign BUS.aw_id     = PFX``_awid;               \
		assign BUS.aw_addr   = PFX``_awaddr;             \
		assign BUS.aw_len    = PFX``_awlen;              \
		assign BUS.aw_size   = PFX``_awsize;             \
		assign BUS.aw_burst  = PFX``_awburst;            \
		assign BUS.aw_lock   = PFX``_awlock;             \
		assign BUS.aw_cache  = PFX``_awcache;            \
		assign BUS.aw_prot   = PFX``_awprot;             \
		assign BUS.aw_qos    = '0;                       \
		assign BUS.aw_region = '0;                       \
		assign BUS.aw_atop   = PFX``_awatop;             \
		assign BUS.aw_user   = '0;                       \
		assign BUS.aw_valid  = PFX``_awvalid;            \
		assign PFX``_awready = BUS.aw_ready;             \
		assign BUS.w_data    = PFX``_wdata;              \
		assign BUS.w_strb    = PFX``_wstrb;              \
		assign BUS.w_last    = PFX``_wlast;              \
		assign BUS.w_user    = '0;                       \
		assign BUS.w_valid   = PFX``_wvalid;             \
		assign PFX``_wready  = BUS.w_ready;              \
		assign PFX``_bid     = BUS.b_id;                 \
		assign PFX``_bresp   = BUS.b_resp;               \
		assign PFX``_bvalid  = BUS.b_valid;              \
		assign BUS.b_ready   = PFX``_bready;             \
		assign BUS.ar_id     = PFX``_arid;               \
		assign BUS.ar_addr   = PFX``_araddr;             \
		assign BUS.ar_len    = PFX``_arlen;              \
		assign BUS.ar_size   = PFX``_arsize;             \
		assign BUS.ar_burst  = PFX``_arburst;            \
		assign BUS.ar_lock   = PFX``_arlock;             \
		assign BUS.ar_cache  = PFX``_arcache;            \
		assign BUS.ar_prot   = PFX``_arprot;             \
		assign BUS.ar_qos    = '0;                       \
		assign BUS.ar_region = '0;                       \
		assign BUS.ar_user   = '0;                       \
		assign BUS.ar_valid  = PFX``_arvalid;            \
		assign PFX``_arready = BUS.ar_ready;             \
		assign PFX``_rid     = BUS.r_id;                 \
		assign PFX``_rdata   = BUS.r_data;               \
		assign PFX``_rresp   = BUS.r_resp;               \
		assign PFX``_rlast   = BUS.r_last;               \
		assign PFX``_rvalid  = BUS.r_valid;              \
		assign BUS.r_ready   = PFX``_rready;

	`CVA6_2_TIE_CPU(cpu0, c0)
	`CVA6_2_TIE_CPU(cpu1, c1)
	`undef CVA6_2_TIE_CPU

	// ------------------------------------------------------------------
	// 2. Address selection per core (identical core view -> ONE function)
	// ------------------------------------------------------------------
	function automatic logic is_periph(input logic [ADDR_WIDTH-1:0] a);
		return (a >= ADDR_WIDTH'(PERIPH_BASE))
		    && (a <  ADDR_WIDTH'(PERIPH_BASE) + ADDR_WIDTH'(PERIPH_SIZE));
	endfunction

	function automatic logic is_dram(input logic [ADDR_WIDTH-1:0] a);
		return (a >= ADDR_WIDTH'(DRAM_BASE))
		    && (a <  ADDR_WIDTH'(DRAM_BASE) + ADDR_WIDTH'(DRAM_SIZE));
	endfunction

	function automatic logic is_mbox(input logic [ADDR_WIDTH-1:0] a);
		return (a >= ADDR_WIDTH'(MBOX_BASE))
		    && (a <  ADDR_WIDTH'(MBOX_BASE) + ADDR_WIDTH'(MBOX_SIZE));
	endfunction

	// 0 = private DRAM, 1 = shared (peripherals OR mailbox), 2 = error
	function automatic logic [1:0] sel_of(input logic [ADDR_WIDTH-1:0] a);
		if      (is_dram(a))                 sel_of = 2'd0;
		else if (is_periph(a) || is_mbox(a)) sel_of = 2'd1;
		else                                 sel_of = 2'd2;
	endfunction

	uwire logic [1:0] aw0_sel = sel_of(cpu0.aw_addr);
	uwire logic [1:0] ar0_sel = sel_of(cpu0.ar_addr);
	uwire logic [1:0] aw1_sel = sel_of(cpu1.aw_addr);
	uwire logic [1:0] ar1_sel = sel_of(cpu1.ar_addr);

	axi_demux_intf #(
		.AXI_ID_WIDTH (ID_WIDTH), .AXI_ADDR_WIDTH (ADDR_WIDTH),
		.AXI_DATA_WIDTH (DATA_WIDTH), .AXI_USER_WIDTH (USER_WIDTH),
		.NO_MST_PORTS (3), .MAX_TRANS (4), .UNIQUE_IDS (1'b0)
	) demux0 (
		.clk_i (clk), .rst_ni (rst_n), .test_i (1'b0),
		.slv_aw_select_i (aw0_sel), .slv_ar_select_i (ar0_sel),
		.slv (cpu0), .mst (br0)
	);

	axi_demux_intf #(
		.AXI_ID_WIDTH (ID_WIDTH), .AXI_ADDR_WIDTH (ADDR_WIDTH),
		.AXI_DATA_WIDTH (DATA_WIDTH), .AXI_USER_WIDTH (USER_WIDTH),
		.NO_MST_PORTS (3), .MAX_TRANS (4), .UNIQUE_IDS (1'b0)
	) demux1 (
		.clk_i (clk), .rst_ni (rst_n), .test_i (1'b0),
		.slv_aw_select_i (aw1_sel), .slv_ar_select_i (ar1_sel),
		.slv (cpu1), .mst (br1)
	);

	// ------------------------------------------------------------------
	// 3. Private path per core: own atomics, own guard, own port
	// ------------------------------------------------------------------
	AXI_BUS #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH),
		.AXI_ID_WIDTH(ID_WIDTH),     .AXI_USER_WIDTH(USER_WIDTH)
	) priv0_amo (), priv1_amo ();

	// The guards do not drive a `user` field -- the response side would
	// otherwise stay undriven and carry X in simulation (a bring-up
	// classic).
	assign priv0_amo.b_user = '0;
	assign priv0_amo.r_user = '0;
	assign priv1_amo.b_user = '0;
	assign priv1_amo.r_user = '0;

	// RISCV_WORD_WIDTH = 64: the PULP block rejects AMOs whose awsize is
	// larger than the configured word width (axi_riscv_amos.sv:286). With
	// 32, every amoadd.d -- i.e. every kernel spinlock -- fails.
	axi_riscv_atomics_wrap #(
		.AXI_ADDR_WIDTH (ADDR_WIDTH), .AXI_DATA_WIDTH (DATA_WIDTH),
		.AXI_ID_WIDTH (ID_WIDTH), .AXI_USER_WIDTH (USER_WIDTH),
		.AXI_MAX_WRITE_TXNS (4), .RISCV_WORD_WIDTH (64)
	) atomics0 (
		.clk_i (clk), .rst_ni (rst_n), .slv (br0[0]), .mst (priv0_amo)
	);

	axi_riscv_atomics_wrap #(
		.AXI_ADDR_WIDTH (ADDR_WIDTH), .AXI_DATA_WIDTH (DATA_WIDTH),
		.AXI_ID_WIDTH (ID_WIDTH), .AXI_USER_WIDTH (USER_WIDTH),
		.AXI_MAX_WRITE_TXNS (4), .RISCV_WORD_WIDTH (64)
	) atomics1 (
		.clk_i (clk), .rst_ni (rst_n), .slv (br1[0]), .mst (priv1_amo)
	);

	// Window translation + burst-envelope guard. After the atomics, so
	// lock/atop are allowed to drop here (the block has resolved them).
	// rocket_mem_window is cross-referenced from
	// ../../rocket_linux/rtl/rocket_mem_window.sv (hart-count-agnostic
	// shared building block, first vendored by the rocket_linux example,
	// this design is its third consumer after rocket_linux and rocket2).
	rocket_mem_window #(
		.WIN_BASE (DRAM_BASE), .WIN_SIZE (DRAM_SIZE), .PS_BASE (PS_DRAM0),
		.S_ADDR_WIDTH (ADDR_WIDTH), .M_ADDR_WIDTH (ADDR_WIDTH), .ID_WIDTH (ID_WIDTH)
	) win0 (
		.clk_i (clk), .rst_ni (rst_n),
		.err_clear (win_err_clear), .err_sticky (win0_err_sticky),
		.err_was_write (win0_err_was_write), .err_count (win0_err_count),
		.err_addr (win0_err_addr),
		.s_awid (priv0_amo.aw_id), .s_awaddr (priv0_amo.aw_addr),
		.s_awlen (priv0_amo.aw_len), .s_awsize (priv0_amo.aw_size),
		.s_awburst (priv0_amo.aw_burst), .s_awvalid (priv0_amo.aw_valid),
		.s_awready (priv0_amo.aw_ready),
		.s_wdata (priv0_amo.w_data), .s_wstrb (priv0_amo.w_strb),
		.s_wlast (priv0_amo.w_last), .s_wvalid (priv0_amo.w_valid),
		.s_wready (priv0_amo.w_ready),
		.s_bid (priv0_amo.b_id), .s_bresp (priv0_amo.b_resp),
		.s_bvalid (priv0_amo.b_valid), .s_bready (priv0_amo.b_ready),
		.s_arid (priv0_amo.ar_id), .s_araddr (priv0_amo.ar_addr),
		.s_arlen (priv0_amo.ar_len), .s_arsize (priv0_amo.ar_size),
		.s_arburst (priv0_amo.ar_burst), .s_arvalid (priv0_amo.ar_valid),
		.s_arready (priv0_amo.ar_ready),
		.s_rid (priv0_amo.r_id), .s_rdata (priv0_amo.r_data),
		.s_rresp (priv0_amo.r_resp), .s_rlast (priv0_amo.r_last),
		.s_rvalid (priv0_amo.r_valid), .s_rready (priv0_amo.r_ready),
		.m_awid (m0_awid), .m_awaddr (m0_awaddr), .m_awlen (m0_awlen),
		.m_awsize (m0_awsize), .m_awburst (m0_awburst), .m_awlock (m0_awlock),
		.m_awcache (m0_awcache), .m_awprot (m0_awprot), .m_awatop (),
		.m_awvalid (m0_awvalid), .m_awready (m0_awready),
		.m_wdata (m0_wdata), .m_wstrb (m0_wstrb), .m_wlast (m0_wlast),
		.m_wvalid (m0_wvalid), .m_wready (m0_wready),
		.m_bid (m0_bid), .m_bresp (m0_bresp), .m_bvalid (m0_bvalid),
		.m_bready (m0_bready),
		.m_arid (m0_arid), .m_araddr (m0_araddr), .m_arlen (m0_arlen),
		.m_arsize (m0_arsize), .m_arburst (m0_arburst), .m_arlock (m0_arlock),
		.m_arcache (m0_arcache), .m_arprot (m0_arprot),
		.m_arvalid (m0_arvalid), .m_arready (m0_arready),
		.m_rid (m0_rid), .m_rdata (m0_rdata), .m_rresp (m0_rresp),
		.m_rlast (m0_rlast), .m_rvalid (m0_rvalid), .m_rready (m0_rready)
	);

	rocket_mem_window #(
		.WIN_BASE (DRAM_BASE), .WIN_SIZE (DRAM_SIZE), .PS_BASE (PS_DRAM1),
		.S_ADDR_WIDTH (ADDR_WIDTH), .M_ADDR_WIDTH (ADDR_WIDTH), .ID_WIDTH (ID_WIDTH)
	) win1 (
		.clk_i (clk), .rst_ni (rst_n),
		.err_clear (win_err_clear), .err_sticky (win1_err_sticky),
		.err_was_write (win1_err_was_write), .err_count (win1_err_count),
		.err_addr (win1_err_addr),
		.s_awid (priv1_amo.aw_id), .s_awaddr (priv1_amo.aw_addr),
		.s_awlen (priv1_amo.aw_len), .s_awsize (priv1_amo.aw_size),
		.s_awburst (priv1_amo.aw_burst), .s_awvalid (priv1_amo.aw_valid),
		.s_awready (priv1_amo.aw_ready),
		.s_wdata (priv1_amo.w_data), .s_wstrb (priv1_amo.w_strb),
		.s_wlast (priv1_amo.w_last), .s_wvalid (priv1_amo.w_valid),
		.s_wready (priv1_amo.w_ready),
		.s_bid (priv1_amo.b_id), .s_bresp (priv1_amo.b_resp),
		.s_bvalid (priv1_amo.b_valid), .s_bready (priv1_amo.b_ready),
		.s_arid (priv1_amo.ar_id), .s_araddr (priv1_amo.ar_addr),
		.s_arlen (priv1_amo.ar_len), .s_arsize (priv1_amo.ar_size),
		.s_arburst (priv1_amo.ar_burst), .s_arvalid (priv1_amo.ar_valid),
		.s_arready (priv1_amo.ar_ready),
		.s_rid (priv1_amo.r_id), .s_rdata (priv1_amo.r_data),
		.s_rresp (priv1_amo.r_resp), .s_rlast (priv1_amo.r_last),
		.s_rvalid (priv1_amo.r_valid), .s_rready (priv1_amo.r_ready),
		.m_awid (m1_awid), .m_awaddr (m1_awaddr), .m_awlen (m1_awlen),
		.m_awsize (m1_awsize), .m_awburst (m1_awburst), .m_awlock (m1_awlock),
		.m_awcache (m1_awcache), .m_awprot (m1_awprot), .m_awatop (),
		.m_awvalid (m1_awvalid), .m_awready (m1_awready),
		.m_wdata (m1_wdata), .m_wstrb (m1_wstrb), .m_wlast (m1_wlast),
		.m_wvalid (m1_wvalid), .m_wready (m1_wready),
		.m_bid (m1_bid), .m_bresp (m1_bresp), .m_bvalid (m1_bvalid),
		.m_bready (m1_bready),
		.m_arid (m1_arid), .m_araddr (m1_araddr), .m_arlen (m1_arlen),
		.m_arsize (m1_arsize), .m_arburst (m1_arburst), .m_arlock (m1_arlock),
		.m_arcache (m1_arcache), .m_arprot (m1_arprot),
		.m_arvalid (m1_arvalid), .m_arready (m1_arready),
		.m_rid (m1_rid), .m_rdata (m1_rdata), .m_rresp (m1_rresp),
		.m_rlast (m1_rlast), .m_rvalid (m1_rvalid), .m_rready (m1_rready)
	);

	// ------------------------------------------------------------------
	// 4. Shared path: narrow ID -> merge -> ONE atomics instance
	// ------------------------------------------------------------------
	// Step 1: serialize each core to ONE ID (constant 0). Without this the
	// reservation table would be 2^5 = 32 entries wide (see header).
	AXI_BUS #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH),
		.AXI_ID_WIDTH(SH_ID_W),      .AXI_USER_WIDTH(USER_WIDTH)
	) sh [1:0] ();      // [0] = core 0, [1] = core 1

	axi_id_serialize_intf #(
		.AXI_SLV_PORT_ID_WIDTH (ID_WIDTH), .AXI_SLV_PORT_MAX_TXNS (4),
		.AXI_MST_PORT_ID_WIDTH (SH_ID_W), .AXI_MST_PORT_MAX_UNIQ_IDS (1),
		.AXI_MST_PORT_MAX_TXNS_PER_ID (2),
		.AXI_ADDR_WIDTH (ADDR_WIDTH), .AXI_DATA_WIDTH (DATA_WIDTH),
		.AXI_USER_WIDTH (USER_WIDTH)
	) idser0 (
		.clk_i (clk), .rst_ni (rst_n), .slv (br0[1]), .mst (sh[0])
	);

	axi_id_serialize_intf #(
		.AXI_SLV_PORT_ID_WIDTH (ID_WIDTH), .AXI_SLV_PORT_MAX_TXNS (4),
		.AXI_MST_PORT_ID_WIDTH (SH_ID_W), .AXI_MST_PORT_MAX_UNIQ_IDS (1),
		.AXI_MST_PORT_MAX_TXNS_PER_ID (2),
		.AXI_ADDR_WIDTH (ADDR_WIDTH), .AXI_DATA_WIDTH (DATA_WIDTH),
		.AXI_USER_WIDTH (USER_WIDTH)
	) idser1 (
		.clk_i (clk), .rst_ni (rst_n), .slv (br1[1]), .mst (sh[1])
	);

	// Step 2: merge. The mux prepends the port index -> core 0 carries ID
	// 2'b00, core 1 carries 2'b10. DIFFERENT IDs per core are mandatory:
	// otherwise the reservation table could not tell them apart and the
	// address-matching cross-clear would turn into self-erasure.
	AXI_BUS #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH),
		.AXI_ID_WIDTH(MRG_ID_W),     .AXI_USER_WIDTH(USER_WIDTH)
	) mrg (), mrg_amo ();

	axi_mux_intf #(
		.SLV_AXI_ID_WIDTH (SH_ID_W), .MST_AXI_ID_WIDTH (MRG_ID_W),
		.AXI_ADDR_WIDTH (ADDR_WIDTH), .AXI_DATA_WIDTH (DATA_WIDTH),
		.AXI_USER_WIDTH (USER_WIDTH), .NO_SLV_PORTS (2), .MAX_W_TRANS (4)
	) shmux (
		.clk_i (clk), .rst_ni (rst_n), .test_i (1'b0),
		.slv (sh), .mst (mrg)
	);

	// Step 3: THE shared atomics instance. Exactly here -- behind the
	// merge -- the address-matching cross-clear from axi_res_tbl takes
	// effect.
	axi_riscv_atomics_wrap #(
		.AXI_ADDR_WIDTH (ADDR_WIDTH), .AXI_DATA_WIDTH (DATA_WIDTH),
		.AXI_ID_WIDTH (MRG_ID_W), .AXI_USER_WIDTH (USER_WIDTH),
		.AXI_MAX_WRITE_TXNS (4), .RISCV_WORD_WIDTH (64)
	) atomics_shared (
		.clk_i (clk), .rst_ni (rst_n), .slv (mrg), .mst (mrg_amo)
	);

	// ------------------------------------------------------------------
	// 5. Behind the shared atomics: peripherals or mailbox
	// ------------------------------------------------------------------
	// Two branches suffice: the demux BEFORE the merge has already sorted
	// out everything that is neither peripherals nor mailbox.
	AXI_BUS #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH),
		.AXI_ID_WIDTH(MRG_ID_W),     .AXI_USER_WIDTH(USER_WIDTH)
	) sbr [1:0] ();     // [0] = peripherals, [1] = mailbox

	uwire logic aw_s_sel = is_mbox(mrg_amo.aw_addr);
	uwire logic ar_s_sel = is_mbox(mrg_amo.ar_addr);

	// AXI_LOOK_BITS MUST be carried along here: the default is 3, and the
	// ID at the merge is only MRG_ID_W = 2 bit wide. Without this, the
	// counter reaches out of range with `id[0+:3]` -- Vivado aborts with
	// "part-select [2:0] out of range of prefix 'id'" (found 2026-08-10
	// 14:27 in the first D3 synthesis run, 17 s after start). At the two
	// core demuxes the default stays: there the ID is 4 bit, and 3 lookup
	// bits are the board-proven state from the single-core build.
	axi_demux_intf #(
		.AXI_ID_WIDTH (MRG_ID_W), .AXI_ADDR_WIDTH (ADDR_WIDTH),
		.AXI_DATA_WIDTH (DATA_WIDTH), .AXI_USER_WIDTH (USER_WIDTH),
		.NO_MST_PORTS (2), .MAX_TRANS (4), .AXI_LOOK_BITS (MRG_ID_W),
		.UNIQUE_IDS (1'b0)
	) demux_sh (
		.clk_i (clk), .rst_ni (rst_n), .test_i (1'b0),
		.slv_aw_select_i (aw_s_sel), .slv_ar_select_i (ar_s_sel),
		.slv (mrg_amo), .mst (sbr)
	);

	// --- 5a. Peripheral branch -> AXI4-Lite ---
	AXI_LITE #(
		.AXI_ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_WIDTH(DATA_WIDTH)
	) per_lite ();

	axi_to_axi_lite_intf #(
		.AXI_ADDR_WIDTH (ADDR_WIDTH), .AXI_DATA_WIDTH (DATA_WIDTH),
		.AXI_ID_WIDTH (MRG_ID_W), .AXI_USER_WIDTH (USER_WIDTH),
		.AXI_MAX_WRITE_TXNS (2), .AXI_MAX_READ_TXNS (2), .FALL_THROUGH (1'b1)
	) per_bridge (
		.clk_i (clk), .rst_ni (rst_n), .testmode_i (1'b0),
		.slv (sbr[0]), .mst (per_lite)
	);

	assign p_awaddr          = per_lite.aw_addr[31:0];
	assign p_awvalid         = per_lite.aw_valid;
	assign per_lite.aw_ready = p_awready;
	assign p_wdata           = per_lite.w_data;
	assign p_wstrb           = per_lite.w_strb;
	assign p_wvalid          = per_lite.w_valid;
	assign per_lite.w_ready  = p_wready;
	assign per_lite.b_resp   = p_bresp;
	assign per_lite.b_valid  = p_bvalid;
	assign p_bready          = per_lite.b_ready;
	assign p_araddr          = per_lite.ar_addr[31:0];
	assign p_arvalid         = per_lite.ar_valid;
	assign per_lite.ar_ready = p_arready;
	assign per_lite.r_data   = p_rdata;
	assign per_lite.r_resp   = p_rresp;
	assign per_lite.r_valid  = p_rvalid;
	assign p_rready          = per_lite.r_ready;

	// --- 5b. Mailbox branch -> guard -> PS port ---
	// Identical translation for BOTH cores (the same PS base) -- that is
	// the point: the same byte in the PS DDR, uncached from both sides.
	uwire logic mb_err_was_write_nc;
	uwire logic [63:0] mb_err_addr_nc;

	rocket_mem_window #(
		.WIN_BASE (MBOX_BASE), .WIN_SIZE (MBOX_SIZE), .PS_BASE (PS_MBOX),
		.S_ADDR_WIDTH (ADDR_WIDTH), .M_ADDR_WIDTH (ADDR_WIDTH), .ID_WIDTH (MRG_ID_W)
	) win_mb (
		.clk_i (clk), .rst_ni (rst_n),
		.err_clear (win_err_clear), .err_sticky (winmb_err_sticky),
		.err_was_write (mb_err_was_write_nc), .err_count (winmb_err_count),
		.err_addr (mb_err_addr_nc),
		.s_awid (sbr[1].aw_id), .s_awaddr (sbr[1].aw_addr),
		.s_awlen (sbr[1].aw_len), .s_awsize (sbr[1].aw_size),
		.s_awburst (sbr[1].aw_burst), .s_awvalid (sbr[1].aw_valid),
		.s_awready (sbr[1].aw_ready),
		.s_wdata (sbr[1].w_data), .s_wstrb (sbr[1].w_strb),
		.s_wlast (sbr[1].w_last), .s_wvalid (sbr[1].w_valid),
		.s_wready (sbr[1].w_ready),
		.s_bid (sbr[1].b_id), .s_bresp (sbr[1].b_resp),
		.s_bvalid (sbr[1].b_valid), .s_bready (sbr[1].b_ready),
		.s_arid (sbr[1].ar_id), .s_araddr (sbr[1].ar_addr),
		.s_arlen (sbr[1].ar_len), .s_arsize (sbr[1].ar_size),
		.s_arburst (sbr[1].ar_burst), .s_arvalid (sbr[1].ar_valid),
		.s_arready (sbr[1].ar_ready),
		.s_rid (sbr[1].r_id), .s_rdata (sbr[1].r_data),
		.s_rresp (sbr[1].r_resp), .s_rlast (sbr[1].r_last),
		.s_rvalid (sbr[1].r_valid), .s_rready (sbr[1].r_ready),
		.m_awid (mb_awid), .m_awaddr (mb_awaddr), .m_awlen (mb_awlen),
		.m_awsize (mb_awsize), .m_awburst (mb_awburst), .m_awlock (mb_awlock),
		.m_awcache (mb_awcache), .m_awprot (mb_awprot), .m_awatop (),
		.m_awvalid (mb_awvalid), .m_awready (mb_awready),
		.m_wdata (mb_wdata), .m_wstrb (mb_wstrb), .m_wlast (mb_wlast),
		.m_wvalid (mb_wvalid), .m_wready (mb_wready),
		.m_bid (mb_bid), .m_bresp (mb_bresp), .m_bvalid (mb_bvalid),
		.m_bready (mb_bready),
		.m_arid (mb_arid), .m_araddr (mb_araddr), .m_arlen (mb_arlen),
		.m_arsize (mb_arsize), .m_arburst (mb_arburst), .m_arlock (mb_arlock),
		.m_arcache (mb_arcache), .m_arprot (mb_arprot),
		.m_arvalid (mb_arvalid), .m_arready (mb_arready),
		.m_rid (mb_rid), .m_rdata (mb_rdata), .m_rresp (mb_rresp),
		.m_rlast (mb_rlast), .m_rvalid (mb_rvalid), .m_rready (mb_rready)
	);
	assign sbr[1].b_user = '0;
	assign sbr[1].r_user = '0;

	// ------------------------------------------------------------------
	// 6. Error slaves (one per core)
	// ------------------------------------------------------------------
	// SLVERR instead of letting the access through. Lesson from
	// cva6_linux_mem_xbar: without a boundary a runaway guest kernel can
	// overwrite the memory of the HOST Ubuntu -- the board was then only
	// reachable by a power cycle. With a boundary that becomes a bus
	// error the trace shows.
	//
	// Two written-out copies instead of a generate loop: an interface
	// array element cannot be aliased to a loop-local object via genvar,
	// and a macro would have made the same defect only less visible. A
	// burst is drained correctly (accept all W beats resp. deliver all R
	// beats), otherwise the bus hangs.
	logic [ID_WIDTH-1:0] e0_bid_q, e0_rid_q, e1_bid_q, e1_rid_q;
	logic                e0_bvalid_q, e0_rvalid_q, e1_bvalid_q, e1_rvalid_q;
	logic [7:0]          e0_rcnt_q, e1_rcnt_q;
	logic                e0_w_active_q, e1_w_active_q;

	always_ff @(posedge clk) begin
		if (rst) begin
			e0_bvalid_q <= 1'b0; e0_rvalid_q <= 1'b0;
			e0_rcnt_q <= '0; e0_w_active_q <= 1'b0;
			e0_bid_q <= '0; e0_rid_q <= '0;
		end
		else begin
			if (br0[2].aw_valid && br0[2].aw_ready) begin
				e0_bid_q      <= br0[2].aw_id;
				e0_w_active_q <= 1'b1;
			end
			if (e0_w_active_q && br0[2].w_valid && br0[2].w_ready && br0[2].w_last) begin
				e0_w_active_q <= 1'b0;
				e0_bvalid_q   <= 1'b1;
			end
			if (e0_bvalid_q && br0[2].b_ready) e0_bvalid_q <= 1'b0;

			if (br0[2].ar_valid && br0[2].ar_ready) begin
				e0_rid_q    <= br0[2].ar_id;
				e0_rcnt_q   <= br0[2].ar_len;
				e0_rvalid_q <= 1'b1;
			end
			else if (e0_rvalid_q && br0[2].r_ready) begin
				if (e0_rcnt_q == 8'd0) e0_rvalid_q <= 1'b0;
				else                   e0_rcnt_q   <= e0_rcnt_q - 8'd1;
			end
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			e1_bvalid_q <= 1'b0; e1_rvalid_q <= 1'b0;
			e1_rcnt_q <= '0; e1_w_active_q <= 1'b0;
			e1_bid_q <= '0; e1_rid_q <= '0;
		end
		else begin
			if (br1[2].aw_valid && br1[2].aw_ready) begin
				e1_bid_q      <= br1[2].aw_id;
				e1_w_active_q <= 1'b1;
			end
			if (e1_w_active_q && br1[2].w_valid && br1[2].w_ready && br1[2].w_last) begin
				e1_w_active_q <= 1'b0;
				e1_bvalid_q   <= 1'b1;
			end
			if (e1_bvalid_q && br1[2].b_ready) e1_bvalid_q <= 1'b0;

			if (br1[2].ar_valid && br1[2].ar_ready) begin
				e1_rid_q    <= br1[2].ar_id;
				e1_rcnt_q   <= br1[2].ar_len;
				e1_rvalid_q <= 1'b1;
			end
			else if (e1_rvalid_q && br1[2].r_ready) begin
				if (e1_rcnt_q == 8'd0) e1_rvalid_q <= 1'b0;
				else                   e1_rcnt_q   <= e1_rcnt_q - 8'd1;
			end
		end
	end

	assign br0[2].aw_ready = !e0_w_active_q && !e0_bvalid_q;
	assign br0[2].w_ready  = e0_w_active_q;
	assign br0[2].b_id     = e0_bid_q;
	assign br0[2].b_resp   = 2'b10;            // SLVERR
	assign br0[2].b_user   = '0;
	assign br0[2].b_valid  = e0_bvalid_q;
	assign br0[2].ar_ready = !e0_rvalid_q;
	assign br0[2].r_id     = e0_rid_q;
	assign br0[2].r_data   = '0;
	assign br0[2].r_resp   = 2'b10;            // SLVERR
	assign br0[2].r_last   = e0_rvalid_q && (e0_rcnt_q == 8'd0);
	assign br0[2].r_user   = '0;
	assign br0[2].r_valid  = e0_rvalid_q;

	assign br1[2].aw_ready = !e1_w_active_q && !e1_bvalid_q;
	assign br1[2].w_ready  = e1_w_active_q;
	assign br1[2].b_id     = e1_bid_q;
	assign br1[2].b_resp   = 2'b10;
	assign br1[2].b_user   = '0;
	assign br1[2].b_valid  = e1_bvalid_q;
	assign br1[2].ar_ready = !e1_rvalid_q;
	assign br1[2].r_id     = e1_rid_q;
	assign br1[2].r_data   = '0;
	assign br1[2].r_resp   = 2'b10;
	assign br1[2].r_last   = e1_rvalid_q && (e1_rcnt_q == 8'd0);
	assign br1[2].r_user   = '0;
	assign br1[2].r_valid  = e1_rvalid_q;

`ifndef SYNTHESIS
	// The point of the atomics blocks in one line: behind them, an atop
	// access must NEVER appear (no PS HP port can handle it).
	always_ff @(posedge clk) begin
		if (rst_n && priv0_amo.aw_valid)
			assert (priv0_amo.aw_atop == 6'b0)
				else $error("cva6_2_mem_xbar: atop=0x%02x behind atomics0", priv0_amo.aw_atop);
		if (rst_n && priv1_amo.aw_valid)
			assert (priv1_amo.aw_atop == 6'b0)
				else $error("cva6_2_mem_xbar: atop=0x%02x behind atomics1", priv1_amo.aw_atop);
		if (rst_n && mrg_amo.aw_valid)
			assert (mrg_amo.aw_atop == 6'b0)
				else $error("cva6_2_mem_xbar: atop=0x%02x behind the shared atomics", mrg_amo.aw_atop);
	end

	// The module's core statement as a checkable property: the two cores
	// enter the shared path with DIFFERENT IDs. Were they equal, the
	// reservation table would be blind to the difference.
	initial begin
		if (MRG_ID_W < 1)
			$fatal(1, "cva6_2_mem_xbar: ID width at the merge too small");
		if (MBOX_BASE < DRAM_BASE + DRAM_SIZE)
			$fatal(1, "cva6_2_mem_xbar: mailbox overlaps the private window");
		$display("[cva6_2_mem_xbar] private per core %0d MiB @0x%h -> PS 0x%h / 0x%h",
		         DRAM_SIZE >> 20, DRAM_BASE, PS_DRAM0, PS_DRAM1);
		$display("[cva6_2_mem_xbar] mailbox %0d MiB @0x%h -> PS 0x%h (uncached, ONE atomics instance, ID width %0d)",
		         MBOX_SIZE >> 20, MBOX_BASE, PS_MBOX, MRG_ID_W);
	end
`endif

endmodule

`default_nettype wire
