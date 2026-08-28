// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    AXIS watchpoint testbed top: 2x TGC5B, each with its own CTTE
 *           instance, one ct_axis_wp_shim per encoder AXIS, ct_L1_funnel +
 *           trace ring as the N-Trace capture (package C1,
 *           docs/PLAN_axis_wp_testbed.md §3a).
 *
 * @details
 *   Built after the duo_soc_top pattern (AXI4-Lite front end, loader mux and
 *   segment decode carried over 1:1), but both branches are TGC5B:
 *
 *     soc0/soc1  tgc5b_rvcfi_synth_wrap  TGC5B + H2E adapter + ct_encoder
 *                                     (SPLIT=1), local wrapper copy with an
 *                                     external time_i (shared time base)
 *     shim0/1    ct_axis_wp_shim      CORE_ID 0/1, FIFO_DEPTH 256; 96-bit
 *                                     encoder AXIS -> 4x32-bit records with
 *                                     drop counter (the encoder never samples
 *                                     tready)
 *     funnel     ct_L1_funnel         N_STREAMS=2, MDO_WIDTH=6, EN_TE_RAW=0;
 *                                     source: rtl/ct_L1_funnel.sv (this
 *                                     repository's own copy, the delta version
 *                                     with chan_te_raw/te_tag_*; instantiation
 *                                     pattern: cva6_2_soc_synth_wrap).
 *                                     The predecessor repository also carried
 *                                     a second, upstream copy with
 *                                     LOGICAL_CHUNK_W=32 that still merged
 *                                     incorrectly -- that copy does not exist
 *                                     in this tree.
 *     sinks      ct_trace_sinks       T2: the shared three-sink subsystem at
 *                                     the funnel output -- 1 MiB URAM ring
 *                                     (like duo; before T2 only 256 KiB) +
 *                                     DDR4 sink (D2, AXI4 master m_axi_*) +
 *                                     PIB (parallel 4-bit DDR port pib_clk/
 *                                     pib_data, KV260 PMOD J2); additive
 *                                     observers, reset-inert
 *
 *   Shared time base: ONE free-running 64-bit fabric counter feeds both
 *   time_i inputs (-> tip._time -> TR_TS_CORE of both encoders) -- FINDINGS
 *   Teil C0 §4. Each core keeps its own mtime (CLINT in the wrapper).
 *
 *   The shim master AXIS (32 bit) plus drop_count/overflow_sticky/fill_level
 *   go out as flat top ports -- the MM-FIFO attachment (axi_fifo_mm_s) is
 *   package D1, the sim testbench hangs directly off the ports.
 *
 *   Address map (22-bit aperture, like duo_soc_top but without the AXIS
 *   capture window -- the AXIS path runs through the shims, not through a
 *   capture BRAM):
 *     0x00_0000  CTRL   CONTROL, STATUS, TRACE_BEATS/BYTES/BUFSZ
 *                       + RV/CFI observation bank at 0x40..0x5C (read-only)
 *     0x01_0000  ENC0   CTTE CSRs, encoder core 0   (ct_axil_to_wb)
 *     0x02_0000  ENC1   CTTE CSRs, encoder core 1   (ct_axil_to_wb)
 *     0x04_0000  SHARED shared memory, SHARED_KIB (RV/CFI; only while BOTH
 *                       cores are held -- see the mux note at the instance)
 *     0x08_0000  RAM1   TGC5B-1 program/data RAM (64 KiB; load while core1_run=0)
 *     0x10_0000  RAM0   TGC5B-0 program/data RAM (64 KiB; load while core0_run=0)
 *     0x20_0000  TRACE  merged ATB ring
 *
 *   Core-side map, both cores (deviation (d) of tgc5b_rvcfi_synth_wrap):
 *     0x0000_0000  RAM      own program/data
 *     0x1000_0000  PERIPH   own CLINT/INTC
 *     0x2000_0000  ENCODER  own CTTE CSRs
 *     0x3000_0000  SHARED   the shared memory -- SAME view from both cores
 *     0x4000_0000  ACTCAP   own ACT-CAP doorbell (write the command word)
 *
 *   RV/CFI observation bank (CTRL 0x40.., read-only; writes there are
 *   ignored and do NOT reach CONTROL or the sink window):
 *     0x40 DB0_HITS   doorbell stores accepted, core 0 (saturating)
 *     0x44 DB0_LAST   last command word written, core 0
 *     0x48 DB1_HITS   doorbell stores accepted, core 1
 *     0x4C DB1_LAST   last command word written, core 1
 *     0x50 ACTCAP0    TIP beats CONVERTED by the adapter, core 0
 *     0x54 ACTCAP1    TIP beats CONVERTED by the adapter, core 1
 *     0x58 SHARED_SZ  shared memory size in bytes
 *     0x5C MAGIC      0x5256_4349 ("RVCI") -- the app-loaded probe
 *
 *   Why both a doorbell count and an adapter count: they are taken at two
 *   different places on the same path. DBx_HITS says software issued the
 *   store; ACTCAPx says the adapter turned it into an ACT-CAP beat. Together
 *   with the shim's drop counter they separate three failure modes that
 *   otherwise all look like "records are missing": the program never
 *   instrumented, the conversion did not happen, or the record was dropped
 *   downstream.
 *
 *   CTRL:
 *     0x00 CONTROL (rw) b0 core_run (collective bit: BOTH cores)  b1 trace_clear
 *                       b2 trace_flush (global funnel flush)
 *                       b8 core0_run  b9 core1_run (U1: per-core, individually;
 *                       effective run state is b0 OR the core bit -- the two
 *                       cores have nothing to do with each other, no SMP)
 *                       Loader contract PER CORE: only write RAM_i while
 *                       core_i_run=0; an access to a RUNNING core's RAM never
 *                       gets ready and hangs the transaction (behavior
 *                       unchanged, just now per-core -- SPEC_axis_wp_memory_map.md §10)
 *     0x04 STATUS  (ro) b0 trace_overflow (ring wrapped)
 *                       b8 core0 running  b9 core1 running (effective state)
 *     0x08 TRACE_BEATS  (ro)
 *     0x0C TRACE_BYTES  (ro)
 *     0x10 TRACE_BUFSZ  (ro) bytes
 *
 *   CTRL extension T2 (shared sink window 0x18..0x38 in ct_trace_sinks, same
 *   offsets as duo_soc_top; SPEC_axis_wp_memory_map.md §9; replaces the D2
 *   single-sink wiring -- BREAKING vs. the C0B_DDR build: DDR_BEATS moved
 *   from 0x30 to 0x38, 0x30 is now PIB_DROPS):
 *     0x18 SINK_CTRL  (rw) b0 ddr_en  b1 ddr_clear (pulse)  b2 ddr_circ
 *                          b3 uram_oneshot  b4 pib_en  b5 pib_clear (pulse)
 *                          b6 pib_calib  b[10:8] pib_div  b[13:12] pib_pattern
 *     0x1C DDR_BASE   (rw) Reset 0x5000_0000 (resmem window, no-map;
 *                          address plan v4 = rocket2 window, U6)
 *     0x20 DDR_SIZE   (rw) Reset 0x1000_0000 (256 MiB, U6); ddr_en stays 0.
 *                          Base/size writable only while ddr_en=0
 *     0x24 DDR_WPTR   (ro) bytes written TOTAL (monotonic)
 *     0x28 SINK_STAT  (ro) b0 ddr_full  b1 ddr_axi_err  b2 ddr_wrapped
 *                          b3 uram_stopped  b4 ddr_cfg_rej (window write
 *                          rejected while the sink is armed, U6)
 *     0x2C DDR_DROPS  (ro) dropped beats (saturating)
 *     0x30 PIB_DROPS  (ro) dropped beats (saturating)
 *     0x38 DDR_BEATS  (ro) ATB beats offered to the sink since ddr_en (proof
 *                          that "beats reach the sink"; clear via ddr_clear)
 *
 *   N3 record rings (2 x 128 MiB in the 256-MiB resmem window; the T2 DDR
 *   leg above is compiled away, EN_DDR=0 -- its 0x1C..0x2C/0x38 fields read
 *   zero and ddr_en/ddr_circ are write-masked). Bank at 0x80 (core 0) and
 *   0xA0 (core 1), stride 0x20:
 *     +0x00 RING_CTRL  (rw) b0 en  b1 clear (W1 pulse, use while en=0)
 *                           b2 circ (reset 1)  b3 route_ddr (reset 0)
 *                           route_ddr=0: records -> MM-FIFO (pre-N3 path,
 *                           bit-identical); route_ddr=1: records -> DDR ring,
 *                           shim sees an always-ready consumer. Switch the
 *                           route only with the cores stopped + clear pulse
 *                           (a mid-record switch tears a record in two).
 *     +0x04 RING_BASE  (rw) WARL: 32-byte aligned, inside
 *                           [0x5000_0000,0x6000_0000); rejected while en=1
 *                           -> cfg_rej. Reset 0x5000_0000 / 0x5800_0000.
 *     +0x08 RING_SIZE  (rw) WARL: multiple of 32, >0, base+size inside the
 *                           window; rejected while en=1. Reset 0x0800_0000.
 *     +0x0C RING_WPTR  (ro) TOTAL bytes written, monotonic. Ring offset =
 *                           wptr % size; when wrapped, oldest data starts
 *                           there.
 *     +0x10 RING_STAT  (ro) b0 full (one-shot only)  b1 axi_err  b2 wrapped
 *                           b3 cfg_rej_sticky (clear pulse resets)
 *     +0x14 RING_DROPS (ro) saturating (ct_soc_ddr_sink FIFO overflow --
 *                           never expected at record rates)
 *     +0x18 RING_BEATS (ro) words offered to the sink while enabled
 *                           (proof-of-feed; clear pulse resets)
 *     +0x1C            (ro) reserved, reads 0
 *
 *   Source separation in the merged stream: Nexus SRC field via CSR
 *   (trTeControl.InhibitSrc=0 + trTeInstFeatures.SrcID/SrcBits per instance,
 *   pure software). Funnel priority is fixed round-robin (both 1) -- this
 *   testbed does not need the duo top's FUNNEL_CTRL runtime control.
 */
module tgc5b2_rvcfi_soc_top #(
	int unsigned MEM_WORDS      = 16384,     // per core: 64 KiB
	int unsigned TRACE_DEPTH    = 262144,    // ring capacity in beats (1 MiB URAM, like duo -- T2)
	int unsigned SHIM_FIFO_DEPTH = 256,      // records per shim (D0 contract)
	// RV/CFI: shared memory size in KiB. Lives in URAM, so it costs no BRAM
	// tile -- 256 KiB is 16 of the 32 URAM288 blocks the design leaves free.
	int unsigned SHARED_KIB      = 256,
	// RV/CFI: software instrumentation on/off. 0 turns the ACT-CAP doorbell
	// conversion off in BOTH wrappers, which is how the demo measures the
	// probe effect of the 50 software sites -- and how a bring-up isolates
	// the ACT-CAP path from everything else in one run.
	bit          EN_ACTCAP       = 1'b1,
	string       MEM_INIT_FILE0 = "",        // $readmemh image, core 0
	string       MEM_INIT_FILE1 = ""         // $readmemh image, core 1
) (
	input  uwire logic        clk,
	input  uwire logic        resetn,

	input  uwire logic [21:0] s_axi_awaddr,
	input  uwire logic [2:0]  s_axi_awprot,
	input  uwire logic        s_axi_awvalid,
	output      logic         s_axi_awready,
	input  uwire logic [31:0] s_axi_wdata,
	input  uwire logic [3:0]  s_axi_wstrb,
	input  uwire logic        s_axi_wvalid,
	output      logic         s_axi_wready,
	output      logic [1:0]   s_axi_bresp,
	output      logic         s_axi_bvalid,
	input  uwire logic        s_axi_bready,
	input  uwire logic [21:0] s_axi_araddr,
	input  uwire logic [2:0]  s_axi_arprot,
	input  uwire logic        s_axi_arvalid,
	output      logic         s_axi_arready,
	output      logic [31:0]  s_axi_rdata,
	output      logic [1:0]   s_axi_rresp,
	output      logic         s_axi_rvalid,
	input  uwire logic        s_axi_rready,

	// -- WP record streams of both shims (D1 hangs axi_fifo_mm_s here) --
	output      logic         m0_axis_tvalid,
	input  uwire logic        m0_axis_tready,
	output      logic [31:0]  m0_axis_tdata,
	output      logic [3:0]   m0_axis_tkeep,
	output      logic         m0_axis_tlast,
	output      logic [31:0]  shim0_drop_count,
	output      logic         shim0_overflow_sticky,
	output      logic [31:0]  shim0_fill_level,

	output      logic         m1_axis_tvalid,
	input  uwire logic        m1_axis_tready,
	output      logic [31:0]  m1_axis_tdata,
	output      logic [3:0]   m1_axis_tkeep,
	output      logic         m1_axis_tlast,
	output      logic [31:0]  shim1_drop_count,
	output      logic         shim1_overflow_sticky,
	output      logic [31:0]  shim1_fill_level,

	// -- DDR4 record ring, core 0: AXI4 write-only master (N3). Historically
	// this port pair carried the ATB observer of ct_trace_sinks; since the
	// N3 split the 256-MiB resmem window belongs to the two RECORD rings
	// (128 MiB per core) and the ATB observer is compiled away (EN_DDR=0) --
	// the ATB stream keeps its always-ready URAM ring as primary sink. -------
	output      logic [31:0]  m_axi_awaddr,
	output      logic [7:0]   m_axi_awlen,
	output      logic [2:0]   m_axi_awsize,
	output      logic [1:0]   m_axi_awburst,
	output      logic         m_axi_awvalid,
	input  uwire logic        m_axi_awready,
	output      logic [31:0]  m_axi_wdata,
	output      logic [3:0]   m_axi_wstrb,
	output      logic         m_axi_wlast,
	output      logic         m_axi_wvalid,
	input  uwire logic        m_axi_wready,
	input  uwire logic [1:0]  m_axi_bresp,
	input  uwire logic        m_axi_bvalid,
	output      logic         m_axi_bready,

	// -- DDR4 record ring, core 1: second write-only master (own PS HP port,
	// no arbiter -- two 32-bit HPs at 75 MHz outrun both shims combined) ----
	output      logic [31:0]  m1_axi_awaddr,
	output      logic [7:0]   m1_axi_awlen,
	output      logic [2:0]   m1_axi_awsize,
	output      logic [1:0]   m1_axi_awburst,
	output      logic         m1_axi_awvalid,
	input  uwire logic        m1_axi_awready,
	output      logic [31:0]  m1_axi_wdata,
	output      logic [3:0]   m1_axi_wstrb,
	output      logic         m1_axi_wlast,
	output      logic         m1_axi_wvalid,
	input  uwire logic        m1_axi_wready,
	input  uwire logic [1:0]  m1_axi_bresp,
	input  uwire logic        m1_axi_bvalid,
	output      logic         m1_axi_bready,

	// -- PIB: parallel trace port (source-synchronous, DDR nibbles; T2) -------
	output      logic         pib_clk,
	output      logic [3:0]   pib_data
);

	localparam logic [1:0] RESP_OKAY = 2'b00;

	uwire logic rst = ~resetn;

	// -- Control / status --------------------------------------------------
	logic [31:0] control_reg;
	uwire logic  core_run    = control_reg[0];
	uwire logic  trace_clear = control_reg[1];
	uwire logic  trace_flush = control_reg[2];

	// U1: one run bit per core (b8/b9). The two TGC5Bs have nothing to do
	// with each other (own RAM, own CLINT, own encoder), so they may start
	// and stop independently. The old collective bit b0 remains valid and
	// acts as "both" (OR) -- any existing software that writes CONTROL=1
	// keeps starting both cores. A single core is stopped by leaving b0=0
	// and setting only its own bit.
	uwire logic  core0_run = core_run | control_reg[8];
	uwire logic  core1_run = core_run | control_reg[9];
	uwire logic  core0_rst_hold = ~core0_run;
	uwire logic  core1_rst_hold = ~core1_run;

	// -- Sink-window wiring (0x18..0x38 lives in ct_trace_sinks, T2) --------
	logic        sinks_reg_wr;                 // strobe: CTRL-segment write (assigned below)
	logic [3:0]  sinks_wr_ix, sinks_rd_ix;     // word indices awaddr/araddr[5:2]
	logic [31:0] sinks_wr_data, sinks_rd_data;

	// -- Shared time base: ONE free-running 64-bit fabric counter -----------
	// feeds both encoders' time_i (tip._time -> TR_TS_CORE), FINDINGS Teil
	// C0 §4: the cores' own mcycle counters would drift apart from each
	// other (per-core core_rst_hold already shifts the start).
	logic [63:0] fabric_time;
	always_ff @(posedge clk) begin
		if (rst) fabric_time <= '0;
		else     fabric_time <= fabric_time + 64'd1;
	end

	// -- Sub-slave wiring (1:1 duo_soc_top) ----------------------------
	logic        e0_awvalid, e0_awready, e0_wvalid, e0_wready, e0_bvalid, e0_bready;
	logic [1:0]  e0_bresp;
	logic        e0_arvalid, e0_arready, e0_rvalid, e0_rready;
	logic [31:0] e0_rdata;
	logic [1:0]  e0_rresp;
	logic        e1_awvalid, e1_awready, e1_wvalid, e1_wready, e1_bvalid, e1_bready;
	logic [1:0]  e1_bresp;
	logic        e1_arvalid, e1_arready, e1_rvalid, e1_rready;
	logic [31:0] e1_rdata;
	logic [1:0]  e1_rresp;
	logic [31:0] sub_addr, sub_wdata;   // ENC bridges: lower 16 bit, region-local
	logic [31:0] ram_addr;              // RAM loader: lower 20 bit, region-local
	logic [3:0]  sub_wstrb;

	// RAM loader windows of both SoCs.
	logic        r0_awvalid, r0_awready, r0_wvalid, r0_wready, r0_bvalid, r0_bready;
	logic [1:0]  r0_bresp;
	logic        r0_arvalid, r0_arready, r0_rvalid, r0_rready;
	logic [31:0] r0_rdata;
	logic [1:0]  r0_rresp;
	logic        r1_awvalid, r1_awready, r1_wvalid, r1_wready, r1_bvalid, r1_bready;
	logic [1:0]  r1_bresp;
	logic        r1_arvalid, r1_arready, r1_rvalid, r1_rready;
	logic [31:0] r1_rdata;
	logic [1:0]  r1_rresp;

	// -- RV/CFI additions: shared memory + ACT-CAP doorbells ---------------
	// x0/x1  : each core's external dBus segment (nibbles 3 and 4)
	// c0sh   : core 0's half of the shared memory, before the PS mux
	// sha/shb: the shared memory's two ports
	// s0     : the PS window onto the shared memory (SEG_SHARED)
	// db0/db1: the per-core ACT-CAP doorbells
	logic        x0_awvalid, x0_awready, x0_wvalid, x0_wready, x0_bvalid, x0_bready;
	logic [31:0] x0_awaddr, x0_wdata, x0_araddr, x0_rdata;
	logic [3:0]  x0_wstrb;
	logic [1:0]  x0_bresp, x0_rresp;
	logic        x0_arvalid, x0_arready, x0_rvalid, x0_rready;
	logic        x1_awvalid, x1_awready, x1_wvalid, x1_wready, x1_bvalid, x1_bready;
	logic [31:0] x1_awaddr, x1_wdata, x1_araddr, x1_rdata;
	logic [3:0]  x1_wstrb;
	logic [1:0]  x1_bresp, x1_rresp;
	logic        x1_arvalid, x1_arready, x1_rvalid, x1_rready;

	logic        c0sh_awvalid, c0sh_awready, c0sh_wvalid, c0sh_wready, c0sh_bvalid, c0sh_bready;
	logic [31:0] c0sh_awaddr, c0sh_wdata, c0sh_araddr, c0sh_rdata;
	logic [3:0]  c0sh_wstrb;
	logic [1:0]  c0sh_bresp, c0sh_rresp;
	logic        c0sh_arvalid, c0sh_arready, c0sh_rvalid, c0sh_rready;

	logic        sha_awvalid, sha_awready, sha_wvalid, sha_wready, sha_bvalid, sha_bready;
	logic [31:0] sha_awaddr, sha_wdata, sha_araddr, sha_rdata;
	logic [3:0]  sha_wstrb;
	logic [1:0]  sha_bresp, sha_rresp;
	logic        sha_arvalid, sha_arready, sha_rvalid, sha_rready;

	logic        shb_awvalid, shb_awready, shb_wvalid, shb_wready, shb_bvalid, shb_bready;
	logic [31:0] shb_awaddr, shb_wdata, shb_araddr, shb_rdata;
	logic [3:0]  shb_wstrb;
	logic [1:0]  shb_bresp, shb_rresp;
	logic        shb_arvalid, shb_arready, shb_rvalid, shb_rready;

	logic        s0_awvalid, s0_awready, s0_wvalid, s0_wready, s0_bvalid, s0_bready;
	logic [1:0]  s0_bresp, s0_rresp;
	logic        s0_arvalid, s0_arready, s0_rvalid, s0_rready;
	logic [31:0] s0_rdata;
	logic [31:0] shared_addr;               // PS side, region-local

	logic        db0_awvalid, db0_awready, db0_wvalid, db0_wready, db0_bvalid, db0_bready;
	logic [31:0] db0_awaddr, db0_wdata, db0_araddr, db0_rdata;
	logic [3:0]  db0_wstrb;
	logic [1:0]  db0_bresp, db0_rresp;
	logic        db0_arvalid, db0_arready, db0_rvalid, db0_rready;
	logic        db1_awvalid, db1_awready, db1_wvalid, db1_wready, db1_bvalid, db1_bready;
	logic [31:0] db1_awaddr, db1_wdata, db1_araddr, db1_rdata;
	logic [3:0]  db1_wstrb;
	logic [1:0]  db1_bresp, db1_rresp;
	logic        db1_arvalid, db1_arready, db1_rvalid, db1_rready;

	logic [31:0] db0_last, db0_hits, db1_last, db1_hits;
	logic [31:0] actcap0_count, actcap1_count;

	// -- RV/CFI console (N1): second demux level + per-core char FIFOs -----
	// dbNi_*: the doorbell behind the second demux (addr bit 8 = 0)
	// ccN_* : the console's core-side port          (addr bit 8 = 1)
	logic        db0i_awvalid, db0i_awready, db0i_wvalid, db0i_wready, db0i_bvalid, db0i_bready;
	logic [31:0] db0i_awaddr, db0i_wdata, db0i_araddr, db0i_rdata;
	logic [3:0]  db0i_wstrb;
	logic [1:0]  db0i_bresp, db0i_rresp;
	logic        db0i_arvalid, db0i_arready, db0i_rvalid, db0i_rready;
	logic        db1i_awvalid, db1i_awready, db1i_wvalid, db1i_wready, db1i_bvalid, db1i_bready;
	logic [31:0] db1i_awaddr, db1i_wdata, db1i_araddr, db1i_rdata;
	logic [3:0]  db1i_wstrb;
	logic [1:0]  db1i_bresp, db1i_rresp;
	logic        db1i_arvalid, db1i_arready, db1i_rvalid, db1i_rready;

	logic        cc0_awvalid, cc0_awready, cc0_wvalid, cc0_wready, cc0_bvalid, cc0_bready;
	logic [31:0] cc0_awaddr, cc0_wdata, cc0_araddr, cc0_rdata;
	logic [3:0]  cc0_wstrb;
	logic [1:0]  cc0_bresp, cc0_rresp;
	logic        cc0_arvalid, cc0_arready, cc0_rvalid, cc0_rready;
	logic        cc1_awvalid, cc1_awready, cc1_wvalid, cc1_wready, cc1_bvalid, cc1_bready;
	logic [31:0] cc1_awaddr, cc1_wdata, cc1_araddr, cc1_rdata;
	logic [3:0]  cc1_wstrb;
	logic [1:0]  cc1_bresp, cc1_rresp;
	logic        cc1_arvalid, cc1_arready, cc1_rvalid, cc1_rready;

	logic [15:0] con0_tx_cnt, con0_rx_free, con0_rx_drops;
	logic        con0_tx_valid;
	logic [7:0]  con0_tx_data;
	logic [15:0] con1_tx_cnt, con1_rx_free, con1_rx_drops;
	logic        con1_tx_valid;
	logic [7:0]  con1_tx_data;
	logic        con0_tx_pop, con0_rx_push, con1_tx_pop, con1_rx_push;

	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) cfg0();
	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) cfg1();

	ct_axil_to_wb enc0_bridge (
		.clk (clk), .rst (rst),
		.s_awvalid (e0_awvalid), .s_awready (e0_awready), .s_awaddr (sub_addr),
		.s_wvalid  (e0_wvalid),  .s_wready  (e0_wready),  .s_wdata  (sub_wdata), .s_wstrb (sub_wstrb),
		.s_bvalid  (e0_bvalid),  .s_bready  (e0_bready),  .s_bresp  (e0_bresp),
		.s_arvalid (e0_arvalid), .s_arready (e0_arready), .s_araddr (sub_addr),
		.s_rvalid  (e0_rvalid),  .s_rready  (e0_rready),  .s_rdata  (e0_rdata), .s_rresp (e0_rresp),
		.wb (cfg0.master)
	);

	ct_axil_to_wb enc1_bridge (
		.clk (clk), .rst (rst),
		.s_awvalid (e1_awvalid), .s_awready (e1_awready), .s_awaddr (sub_addr),
		.s_wvalid  (e1_wvalid),  .s_wready  (e1_wready),  .s_wdata  (sub_wdata), .s_wstrb (sub_wstrb),
		.s_bvalid  (e1_bvalid),  .s_bready  (e1_bready),  .s_bresp  (e1_bresp),
		.s_arvalid (e1_arvalid), .s_arready (e1_arready), .s_araddr (sub_addr),
		.s_rvalid  (e1_rvalid),  .s_rready  (e1_rready),  .s_rdata  (e1_rdata), .s_rresp (e1_rresp),
		.wb (cfg1.master)
	);

	// -- SoC branches ----------------------------------------------------------
	logic [31:0] atb0_atdata,  atb1_atdata;
	logic [1:0]  atb0_atbytes, atb1_atbytes;
	logic [6:0]  atb0_atid,    atb1_atid;
	logic        atb0_atvalid, atb1_atvalid;
	logic        atb0_atready, atb1_atready;
	logic        atb0_afready, atb1_afready;
	logic        atb0_afvalid, atb1_afvalid;
	logic        atb0_syncreq, atb1_syncreq;
	logic        atb0_te_raw,  atb1_te_raw;

	logic [95:0] axis0_tdata,  axis1_tdata;
	logic [11:0] axis0_tstrb,  axis1_tstrb;
	logic [7:0]  axis0_tid,    axis1_tid;
	logic        axis0_tvalid, axis1_tvalid;

	logic [31:0] core0_trace_pc,  core1_trace_pc;
	logic        core0_trace_valid, core1_trace_valid;

	tgc5b_rvcfi_synth_wrap #(.MEM_WORDS(MEM_WORDS), .MEM_INIT_FILE(MEM_INIT_FILE0),
	                         .EN_ACTCAP(EN_ACTCAP)) soc0 (
		.clk (clk), .rst (rst),
		.core_rst_hold (core0_rst_hold),
		.time_i (fabric_time),
		.atb_atdata (atb0_atdata), .atb_atbytes (atb0_atbytes), .atb_atid (atb0_atid),
		.atb_atvalid (atb0_atvalid), .atb_atready (atb0_atready),
		.atb_afready (atb0_afready), .atb_te_raw (atb0_te_raw),
		.atb_afvalid (atb0_afvalid), .atb_syncreq (atb0_syncreq),
		.axis_tdata (axis0_tdata), .axis_tstrb (axis0_tstrb), .axis_tid (axis0_tid),
		.axis_tvalid (axis0_tvalid), .axis_tready (1'b1),
		.cfg_wb_en (1'b1),
		.cfg_wb_cyc (cfg0.cyc), .cfg_wb_stb (cfg0.stb), .cfg_wb_we (cfg0.we),
		.cfg_wb_addr (cfg0.addr), .cfg_wb_data_m2s (cfg0.data_m2s), .cfg_wb_sel (cfg0.sel),
		.cfg_wb_data_s2m (cfg0.data_s2m), .cfg_wb_ack (cfg0.ack), .cfg_wb_err (cfg0.err),
		.ldr_awvalid (r0_awvalid), .ldr_awready (r0_awready), .ldr_awaddr (ram_addr),
		.ldr_wvalid (r0_wvalid), .ldr_wready (r0_wready), .ldr_wdata (sub_wdata), .ldr_wstrb (sub_wstrb),
		.ldr_bvalid (r0_bvalid), .ldr_bready (r0_bready), .ldr_bresp (r0_bresp),
		.ldr_arvalid (r0_arvalid), .ldr_arready (r0_arready), .ldr_araddr (ram_addr),
		.ldr_rvalid (r0_rvalid), .ldr_rready (r0_rready), .ldr_rdata (r0_rdata), .ldr_rresp (r0_rresp),
		.ext_awvalid (x0_awvalid), .ext_awready (x0_awready), .ext_awaddr (x0_awaddr),
		.ext_wvalid (x0_wvalid), .ext_wready (x0_wready), .ext_wdata (x0_wdata), .ext_wstrb (x0_wstrb),
		.ext_bvalid (x0_bvalid), .ext_bready (x0_bready), .ext_bresp (x0_bresp),
		.ext_arvalid (x0_arvalid), .ext_arready (x0_arready), .ext_araddr (x0_araddr),
		.ext_rvalid (x0_rvalid), .ext_rready (x0_rready), .ext_rdata (x0_rdata), .ext_rresp (x0_rresp),
		.actcap_count (actcap0_count),
		.core_trace_pc (core0_trace_pc), .core_trace_valid (core0_trace_valid)
	);

	tgc5b_rvcfi_synth_wrap #(.MEM_WORDS(MEM_WORDS), .MEM_INIT_FILE(MEM_INIT_FILE1),
	                         .EN_ACTCAP(EN_ACTCAP)) soc1 (
		.clk (clk), .rst (rst),
		.core_rst_hold (core1_rst_hold),
		.time_i (fabric_time),
		.atb_atdata (atb1_atdata), .atb_atbytes (atb1_atbytes), .atb_atid (atb1_atid),
		.atb_atvalid (atb1_atvalid), .atb_atready (atb1_atready),
		.atb_afready (atb1_afready), .atb_te_raw (atb1_te_raw),
		.atb_afvalid (atb1_afvalid), .atb_syncreq (atb1_syncreq),
		.axis_tdata (axis1_tdata), .axis_tstrb (axis1_tstrb), .axis_tid (axis1_tid),
		.axis_tvalid (axis1_tvalid), .axis_tready (1'b1),
		.cfg_wb_en (1'b1),
		.cfg_wb_cyc (cfg1.cyc), .cfg_wb_stb (cfg1.stb), .cfg_wb_we (cfg1.we),
		.cfg_wb_addr (cfg1.addr), .cfg_wb_data_m2s (cfg1.data_m2s), .cfg_wb_sel (cfg1.sel),
		.cfg_wb_data_s2m (cfg1.data_s2m), .cfg_wb_ack (cfg1.ack), .cfg_wb_err (cfg1.err),
		.ldr_awvalid (r1_awvalid), .ldr_awready (r1_awready), .ldr_awaddr (ram_addr),
		.ldr_wvalid (r1_wvalid), .ldr_wready (r1_wready), .ldr_wdata (sub_wdata), .ldr_wstrb (sub_wstrb),
		.ldr_bvalid (r1_bvalid), .ldr_bready (r1_bready), .ldr_bresp (r1_bresp),
		.ldr_arvalid (r1_arvalid), .ldr_arready (r1_arready), .ldr_araddr (ram_addr),
		.ldr_rvalid (r1_rvalid), .ldr_rready (r1_rready), .ldr_rdata (r1_rdata), .ldr_rresp (r1_rresp),
		.ext_awvalid (x1_awvalid), .ext_awready (x1_awready), .ext_awaddr (x1_awaddr),
		.ext_wvalid (x1_wvalid), .ext_wready (x1_wready), .ext_wdata (x1_wdata), .ext_wstrb (x1_wstrb),
		.ext_bvalid (x1_bvalid), .ext_bready (x1_bready), .ext_bresp (x1_bresp),
		.ext_arvalid (x1_arvalid), .ext_arready (x1_arready), .ext_araddr (x1_araddr),
		.ext_rvalid (x1_rvalid), .ext_rready (x1_rready), .ext_rdata (x1_rdata), .ext_rresp (x1_rresp),
		.actcap_count (actcap1_count),
		.core_trace_pc (core1_trace_pc), .core_trace_valid (core1_trace_valid)
	);

	// =====================================================================
	// Shared memory + ACT-CAP doorbells (the RV/CFI additions)
	// =====================================================================
	// Each core's external segment splits into SHARED (0x3xxx_xxxx) and its
	// own doorbell (0x4xxx_xxxx). The shared memory's port A is additionally
	// reachable from the PS window -- but ONLY while both cores are held.
	//
	// That restriction is not politeness, it is the same contract the RAM
	// loader already has: a PS access to the memory of a RUNNING core would
	// compete with the core for the port. Here it would be worse than a
	// stall, because the PS would be a third writer in a memory whose whole
	// purpose is to make two writers observable. `rvmon` refuses the access
	// when STATUS says a core is running; the mux below is the hardware half
	// of the same rule, and a combinational select is safe precisely because
	// no core transaction can be in flight while both are in reset.

	ct_axil_demux2 xdm0 (
		.clk (clk), .rst (rst),
		.s_awvalid (x0_awvalid), .s_awready (x0_awready), .s_awaddr (x0_awaddr),
		.s_wvalid (x0_wvalid), .s_wready (x0_wready), .s_wdata (x0_wdata), .s_wstrb (x0_wstrb),
		.s_bvalid (x0_bvalid), .s_bready (x0_bready), .s_bresp (x0_bresp),
		.s_arvalid (x0_arvalid), .s_arready (x0_arready), .s_araddr (x0_araddr),
		.s_rvalid (x0_rvalid), .s_rready (x0_rready), .s_rdata (x0_rdata), .s_rresp (x0_rresp),
		.m0_awvalid (c0sh_awvalid), .m0_awready (c0sh_awready), .m0_awaddr (c0sh_awaddr),
		.m0_wvalid (c0sh_wvalid), .m0_wready (c0sh_wready), .m0_wdata (c0sh_wdata), .m0_wstrb (c0sh_wstrb),
		.m0_bvalid (c0sh_bvalid), .m0_bready (c0sh_bready), .m0_bresp (c0sh_bresp),
		.m0_arvalid (c0sh_arvalid), .m0_arready (c0sh_arready), .m0_araddr (c0sh_araddr),
		.m0_rvalid (c0sh_rvalid), .m0_rready (c0sh_rready), .m0_rdata (c0sh_rdata), .m0_rresp (c0sh_rresp),
		.m1_awvalid (db0_awvalid), .m1_awready (db0_awready), .m1_awaddr (db0_awaddr),
		.m1_wvalid (db0_wvalid), .m1_wready (db0_wready), .m1_wdata (db0_wdata), .m1_wstrb (db0_wstrb),
		.m1_bvalid (db0_bvalid), .m1_bready (db0_bready), .m1_bresp (db0_bresp),
		.m1_arvalid (db0_arvalid), .m1_arready (db0_arready), .m1_araddr (db0_araddr),
		.m1_rvalid (db0_rvalid), .m1_rready (db0_rready), .m1_rdata (db0_rdata), .m1_rresp (db0_rresp)
	);

	ct_axil_demux2 xdm1 (
		.clk (clk), .rst (rst),
		.s_awvalid (x1_awvalid), .s_awready (x1_awready), .s_awaddr (x1_awaddr),
		.s_wvalid (x1_wvalid), .s_wready (x1_wready), .s_wdata (x1_wdata), .s_wstrb (x1_wstrb),
		.s_bvalid (x1_bvalid), .s_bready (x1_bready), .s_bresp (x1_bresp),
		.s_arvalid (x1_arvalid), .s_arready (x1_arready), .s_araddr (x1_araddr),
		.s_rvalid (x1_rvalid), .s_rready (x1_rready), .s_rdata (x1_rdata), .s_rresp (x1_rresp),
		.m0_awvalid (shb_awvalid), .m0_awready (shb_awready), .m0_awaddr (shb_awaddr),
		.m0_wvalid (shb_wvalid), .m0_wready (shb_wready), .m0_wdata (shb_wdata), .m0_wstrb (shb_wstrb),
		.m0_bvalid (shb_bvalid), .m0_bready (shb_bready), .m0_bresp (shb_bresp),
		.m0_arvalid (shb_arvalid), .m0_arready (shb_arready), .m0_araddr (shb_araddr),
		.m0_rvalid (shb_rvalid), .m0_rready (shb_rready), .m0_rdata (shb_rdata), .m0_rresp (shb_rresp),
		.m1_awvalid (db1_awvalid), .m1_awready (db1_awready), .m1_awaddr (db1_awaddr),
		.m1_wvalid (db1_wvalid), .m1_wready (db1_wready), .m1_wdata (db1_wdata), .m1_wstrb (db1_wstrb),
		.m1_bvalid (db1_bvalid), .m1_bready (db1_bready), .m1_bresp (db1_bresp),
		.m1_arvalid (db1_arvalid), .m1_arready (db1_arready), .m1_araddr (db1_araddr),
		.m1_rvalid (db1_rvalid), .m1_rready (db1_rready), .m1_rdata (db1_rdata), .m1_rresp (db1_rresp)
	);

	// Port A: core 0 while it runs, the PS window while both cores are held.
	uwire logic ps_owns_shared = !core0_run && !core1_run;

	assign sha_awvalid = ps_owns_shared ? s0_awvalid : c0sh_awvalid;
	assign sha_awaddr  = ps_owns_shared ? shared_addr : c0sh_awaddr;
	assign sha_wvalid  = ps_owns_shared ? s0_wvalid  : c0sh_wvalid;
	assign sha_wdata   = ps_owns_shared ? sub_wdata  : c0sh_wdata;
	assign sha_wstrb   = ps_owns_shared ? sub_wstrb  : c0sh_wstrb;
	assign sha_bready  = ps_owns_shared ? s0_bready  : c0sh_bready;
	assign sha_arvalid = ps_owns_shared ? s0_arvalid : c0sh_arvalid;
	assign sha_araddr  = ps_owns_shared ? shared_addr : c0sh_araddr;
	assign sha_rready  = ps_owns_shared ? s0_rready  : c0sh_rready;

	assign c0sh_awready = ps_owns_shared ? 1'b0 : sha_awready;
	assign c0sh_wready  = ps_owns_shared ? 1'b0 : sha_wready;
	assign c0sh_bvalid  = ps_owns_shared ? 1'b0 : sha_bvalid;
	assign c0sh_bresp   = sha_bresp;
	assign c0sh_arready = ps_owns_shared ? 1'b0 : sha_arready;
	assign c0sh_rvalid  = ps_owns_shared ? 1'b0 : sha_rvalid;
	assign c0sh_rdata   = sha_rdata;
	assign c0sh_rresp   = sha_rresp;

	assign s0_awready = ps_owns_shared ? sha_awready : 1'b0;
	assign s0_wready  = ps_owns_shared ? sha_wready  : 1'b0;
	assign s0_bvalid  = ps_owns_shared ? sha_bvalid  : 1'b0;
	assign s0_bresp   = sha_bresp;
	assign s0_arready = ps_owns_shared ? sha_arready : 1'b0;
	assign s0_rvalid  = ps_owns_shared ? sha_rvalid  : 1'b0;
	assign s0_rdata   = sha_rdata;
	assign s0_rresp   = sha_rresp;

	ct_soc_shared_mem #(.SHARED_KIB(SHARED_KIB)) shared_mem (
		.clk (clk), .rst (rst),
		.a_awvalid (sha_awvalid), .a_awready (sha_awready), .a_awaddr (sha_awaddr),
		.a_wvalid (sha_wvalid), .a_wready (sha_wready), .a_wdata (sha_wdata), .a_wstrb (sha_wstrb),
		.a_bvalid (sha_bvalid), .a_bready (sha_bready), .a_bresp (sha_bresp),
		.a_arvalid (sha_arvalid), .a_arready (sha_arready), .a_araddr (sha_araddr),
		.a_rvalid (sha_rvalid), .a_rready (sha_rready), .a_rdata (sha_rdata), .a_rresp (sha_rresp),
		.b_awvalid (shb_awvalid), .b_awready (shb_awready), .b_awaddr (shb_awaddr),
		.b_wvalid (shb_wvalid), .b_wready (shb_wready), .b_wdata (shb_wdata), .b_wstrb (shb_wstrb),
		.b_bvalid (shb_bvalid), .b_bready (shb_bready), .b_bresp (shb_bresp),
		.b_arvalid (shb_arvalid), .b_arready (shb_arready), .b_araddr (shb_araddr),
		.b_rvalid (shb_rvalid), .b_rready (shb_rready), .b_rdata (shb_rdata), .b_rresp (shb_rresp)
	);

	// Second demux level inside the 0x4xxx segment: addr bit 8 separates the
	// doorbell (0x4000_0000) from the console (0x4000_0100). Reuses the same
	// verified module as the segment split -- no new decode logic to get
	// wrong, just a different SEL_BIT.
	ct_axil_demux2 #(.SEL_BIT(8)) xdm0b (
		.clk (clk), .rst (rst),
		.s_awvalid (db0_awvalid), .s_awready (db0_awready), .s_awaddr (db0_awaddr),
		.s_wvalid (db0_wvalid), .s_wready (db0_wready), .s_wdata (db0_wdata), .s_wstrb (db0_wstrb),
		.s_bvalid (db0_bvalid), .s_bready (db0_bready), .s_bresp (db0_bresp),
		.s_arvalid (db0_arvalid), .s_arready (db0_arready), .s_araddr (db0_araddr),
		.s_rvalid (db0_rvalid), .s_rready (db0_rready), .s_rdata (db0_rdata), .s_rresp (db0_rresp),
		.m0_awvalid (db0i_awvalid), .m0_awready (db0i_awready), .m0_awaddr (db0i_awaddr),
		.m0_wvalid (db0i_wvalid), .m0_wready (db0i_wready), .m0_wdata (db0i_wdata), .m0_wstrb (db0i_wstrb),
		.m0_bvalid (db0i_bvalid), .m0_bready (db0i_bready), .m0_bresp (db0i_bresp),
		.m0_arvalid (db0i_arvalid), .m0_arready (db0i_arready), .m0_araddr (db0i_araddr),
		.m0_rvalid (db0i_rvalid), .m0_rready (db0i_rready), .m0_rdata (db0i_rdata), .m0_rresp (db0i_rresp),
		.m1_awvalid (cc0_awvalid), .m1_awready (cc0_awready), .m1_awaddr (cc0_awaddr),
		.m1_wvalid (cc0_wvalid), .m1_wready (cc0_wready), .m1_wdata (cc0_wdata), .m1_wstrb (cc0_wstrb),
		.m1_bvalid (cc0_bvalid), .m1_bready (cc0_bready), .m1_bresp (cc0_bresp),
		.m1_arvalid (cc0_arvalid), .m1_arready (cc0_arready), .m1_araddr (cc0_araddr),
		.m1_rvalid (cc0_rvalid), .m1_rready (cc0_rready), .m1_rdata (cc0_rdata), .m1_rresp (cc0_rresp)
	);

	ct_axil_demux2 #(.SEL_BIT(8)) xdm1b (
		.clk (clk), .rst (rst),
		.s_awvalid (db1_awvalid), .s_awready (db1_awready), .s_awaddr (db1_awaddr),
		.s_wvalid (db1_wvalid), .s_wready (db1_wready), .s_wdata (db1_wdata), .s_wstrb (db1_wstrb),
		.s_bvalid (db1_bvalid), .s_bready (db1_bready), .s_bresp (db1_bresp),
		.s_arvalid (db1_arvalid), .s_arready (db1_arready), .s_araddr (db1_araddr),
		.s_rvalid (db1_rvalid), .s_rready (db1_rready), .s_rdata (db1_rdata), .s_rresp (db1_rresp),
		.m0_awvalid (db1i_awvalid), .m0_awready (db1i_awready), .m0_awaddr (db1i_awaddr),
		.m0_wvalid (db1i_wvalid), .m0_wready (db1i_wready), .m0_wdata (db1i_wdata), .m0_wstrb (db1i_wstrb),
		.m0_bvalid (db1i_bvalid), .m0_bready (db1i_bready), .m0_bresp (db1i_bresp),
		.m0_arvalid (db1i_arvalid), .m0_arready (db1i_arready), .m0_araddr (db1i_araddr),
		.m0_rvalid (db1i_rvalid), .m0_rready (db1i_rready), .m0_rdata (db1i_rdata), .m0_rresp (db1i_rresp),
		.m1_awvalid (cc1_awvalid), .m1_awready (cc1_awready), .m1_awaddr (cc1_awaddr),
		.m1_wvalid (cc1_wvalid), .m1_wready (cc1_wready), .m1_wdata (cc1_wdata), .m1_wstrb (cc1_wstrb),
		.m1_bvalid (cc1_bvalid), .m1_bready (cc1_bready), .m1_bresp (cc1_bresp),
		.m1_arvalid (cc1_arvalid), .m1_arready (cc1_arready), .m1_araddr (cc1_araddr),
		.m1_rvalid (cc1_rvalid), .m1_rready (cc1_rready), .m1_rdata (cc1_rdata), .m1_rresp (cc1_rresp)
	);

	ct_soc_doorbell db0 (
		.clk (clk), .rst (rst),
		.s_awvalid (db0i_awvalid), .s_awready (db0i_awready), .s_awaddr (db0i_awaddr),
		.s_wvalid (db0i_wvalid), .s_wready (db0i_wready), .s_wdata (db0i_wdata), .s_wstrb (db0i_wstrb),
		.s_bvalid (db0i_bvalid), .s_bready (db0i_bready), .s_bresp (db0i_bresp),
		.s_arvalid (db0i_arvalid), .s_arready (db0i_arready), .s_araddr (db0i_araddr),
		.s_rvalid (db0i_rvalid), .s_rready (db0i_rready), .s_rdata (db0i_rdata), .s_rresp (db0i_rresp),
		.last_o (db0_last), .hits_o (db0_hits)
	);

	ct_soc_doorbell db1 (
		.clk (clk), .rst (rst),
		.s_awvalid (db1i_awvalid), .s_awready (db1i_awready), .s_awaddr (db1i_awaddr),
		.s_wvalid (db1i_wvalid), .s_wready (db1i_wready), .s_wdata (db1i_wdata), .s_wstrb (db1i_wstrb),
		.s_bvalid (db1i_bvalid), .s_bready (db1i_bready), .s_bresp (db1i_bresp),
		.s_arvalid (db1i_arvalid), .s_arready (db1i_arready), .s_araddr (db1i_araddr),
		.s_rvalid (db1i_rvalid), .s_rready (db1i_rready), .s_rdata (db1i_rdata), .s_rresp (db1i_rresp),
		.last_o (db1_last), .hits_o (db1_hits)
	);

	ct_soc_console con0 (
		.clk (clk), .rst (rst),
		.s_awvalid (cc0_awvalid), .s_awready (cc0_awready), .s_awaddr (cc0_awaddr),
		.s_wvalid (cc0_wvalid), .s_wready (cc0_wready), .s_wdata (cc0_wdata), .s_wstrb (cc0_wstrb),
		.s_bvalid (cc0_bvalid), .s_bready (cc0_bready), .s_bresp (cc0_bresp),
		.s_arvalid (cc0_arvalid), .s_arready (cc0_arready), .s_araddr (cc0_araddr),
		.s_rvalid (cc0_rvalid), .s_rready (cc0_rready), .s_rdata (cc0_rdata), .s_rresp (cc0_rresp),
		.ps_tx_cnt (con0_tx_cnt), .ps_tx_valid (con0_tx_valid), .ps_tx_data (con0_tx_data),
		.ps_tx_pop (con0_tx_pop),
		.ps_rx_free (con0_rx_free), .ps_rx_push (con0_rx_push), .ps_rx_data (wdata_q[7:0]),
		.ps_rx_drops (con0_rx_drops)
	);

	ct_soc_console con1 (
		.clk (clk), .rst (rst),
		.s_awvalid (cc1_awvalid), .s_awready (cc1_awready), .s_awaddr (cc1_awaddr),
		.s_wvalid (cc1_wvalid), .s_wready (cc1_wready), .s_wdata (cc1_wdata), .s_wstrb (cc1_wstrb),
		.s_bvalid (cc1_bvalid), .s_bready (cc1_bready), .s_bresp (cc1_bresp),
		.s_arvalid (cc1_arvalid), .s_arready (cc1_arready), .s_araddr (cc1_araddr),
		.s_rvalid (cc1_rvalid), .s_rready (cc1_rready), .s_rdata (cc1_rdata), .s_rresp (cc1_rresp),
		.ps_tx_cnt (con1_tx_cnt), .ps_tx_valid (con1_tx_valid), .ps_tx_data (con1_tx_data),
		.ps_tx_pop (con1_tx_pop),
		.ps_rx_free (con1_rx_free), .ps_rx_push (con1_rx_push), .ps_rx_data (wdata_q[7:0]),
		.ps_rx_drops (con1_rx_drops)
	);

	// PS-side console strobes: one B_WR/B_RD cycle of the CTRL bank each.
	// The pop rides the READ of CON*_POP (FWFT: the datum is latched from the
	// head in the same cycle, the pointer advances at the edge).
	// !bit7: the N3 ring bank lives at 0x80.. -- without the guard an access
	// to unused 0xE4/0xE8 would alias onto a console pop/push side effect.
	assign con0_rx_push = (bstate == B_WR) && (seg == SEG_CTRL)
	                   && !awaddr_q[7] && awaddr_q[6] && (awaddr_q[5:2] == 4'd10);
	assign con1_rx_push = (bstate == B_WR) && (seg == SEG_CTRL)
	                   && !awaddr_q[7] && awaddr_q[6] && (awaddr_q[5:2] == 4'd14);
	assign con0_tx_pop  = (bstate == B_RD) && (seg == SEG_CTRL)
	                   && !araddr_q[7] && araddr_q[6] && (araddr_q[5:2] == 4'd9);
	assign con1_tx_pop  = (bstate == B_RD) && (seg == SEG_CTRL)
	                   && !araddr_q[7] && araddr_q[6] && (araddr_q[5:2] == 4'd13);

	// -- WP record shims: encoder AXIS (no tready!) -> 32-bit records ------
	// N3: the shim master no longer goes straight to the top ports. A route
	// mux per core sends the record words EITHER to the external MM-FIFO
	// (route_ddr=0, the pre-N3 behaviour, bit-identical) OR to the DDR ring
	// sink (route_ddr=1). In ring mode the shim sees an ALWAYS-READY
	// consumer -- this is the whole point: with the FIFO path, a host that
	// drains slowly backpressures the shim and the records are lost BEFORE
	// any sink sees them; the ring sink instead absorbs at DDR speed and
	// counts its own (never-expected) drops. Switch the route only with the
	// cores stopped and a clear pulse issued -- switching mid-record would
	// tear a record across the two consumers (documented order, enforced by
	// rvmon, exercised by the TB).
	uwire logic        sh0_tvalid, sh0_tlast, sh1_tvalid, sh1_tlast;
	uwire logic [31:0] sh0_tdata,  sh1_tdata;
	uwire logic [3:0]  sh0_tkeep,  sh1_tkeep;
	logic              ring_route [2];              // registered in the ring bank
	uwire logic        ring0_route = ring_route[0];
	uwire logic        ring1_route = ring_route[1];

	ct_axis_wp_shim #(.CORE_ID(4'd0), .FIFO_DEPTH(SHIM_FIFO_DEPTH)) shim0 (
		.clk (clk), .rst (rst),
		.s_tvalid (axis0_tvalid), .s_tdata (axis0_tdata),
		.s_tstrb (axis0_tstrb), .s_tid (axis0_tid),
		.m_tvalid (sh0_tvalid), .m_tready (ring0_route ? 1'b1 : m0_axis_tready),
		.m_tdata (sh0_tdata), .m_tkeep (sh0_tkeep), .m_tlast (sh0_tlast),
		.drop_count (shim0_drop_count),
		.overflow_sticky (shim0_overflow_sticky),
		.fill_level (shim0_fill_level)
	);
	assign m0_axis_tvalid = ring0_route ? 1'b0 : sh0_tvalid;
	assign m0_axis_tdata  = sh0_tdata;
	assign m0_axis_tkeep  = sh0_tkeep;
	assign m0_axis_tlast  = sh0_tlast;

	ct_axis_wp_shim #(.CORE_ID(4'd1), .FIFO_DEPTH(SHIM_FIFO_DEPTH)) shim1 (
		.clk (clk), .rst (rst),
		.s_tvalid (axis1_tvalid), .s_tdata (axis1_tdata),
		.s_tstrb (axis1_tstrb), .s_tid (axis1_tid),
		.m_tvalid (sh1_tvalid), .m_tready (ring1_route ? 1'b1 : m1_axis_tready),
		.m_tdata (sh1_tdata), .m_tkeep (sh1_tkeep), .m_tlast (sh1_tlast),
		.drop_count (shim1_drop_count),
		.overflow_sticky (shim1_overflow_sticky),
		.fill_level (shim1_fill_level)
	);
	assign m1_axis_tvalid = ring1_route ? 1'b0 : sh1_tvalid;
	assign m1_axis_tdata  = sh1_tdata;
	assign m1_axis_tkeep  = sh1_tkeep;
	assign m1_axis_tlast  = sh1_tlast;

	// ======================================================================
	// N3: per-core DDR4 record rings -- 2 x 128 MiB in the 256-MiB resmem
	// window, one ct_soc_ddr_sink per core, one PS HP port each (m_axi /
	// m1_axi; no arbiter). Register bank at CTRL 0x80 (core 0) / 0xA0
	// (core 1), layout in the header. WARL keeps base/size inside the
	// window -- the lesson behind U6 and the interconnect wedge: a stray
	// address on S_AXI_HP does not error, it hangs the PS until the power
	// switch, so the hardware refuses to aim outside the reservation.
	// ======================================================================
	localparam logic [31:0] RING_WIN_LO   = 32'h5000_0000;
	localparam logic [31:0] RING_WIN_HI   = 32'h6000_0000;   // exclusive
	localparam logic [31:0] RING0_BASE_RST = 32'h5000_0000;
	localparam logic [31:0] RING1_BASE_RST = 32'h5800_0000;
	localparam logic [31:0] RING_SIZE_RST  = 32'h0800_0000;  // 128 MiB

	logic        ring_en      [2];
	logic        ring_circ    [2];
	logic        ring_cfg_rej [2];
	logic [31:0] ring_base    [2];
	logic [31:0] ring_size    [2];
	logic [31:0] ring_beats   [2];
	uwire logic  ring_clear_pulse [2];
	uwire logic [31:0] ring_wptr  [2];
	uwire logic  ring_full  [2], ring_wrapped [2], ring_axi_err [2];
	uwire logic [31:0] ring_drops [2];

	// The beat feed: accepted record words. In FIFO mode the sinks see
	// nothing (route is the qualifier), so an enabled-but-unrouted ring
	// simply stays empty instead of stealing words from the FIFO path.
	uwire logic        ring_feed_v [2];
	uwire logic [31:0] ring_feed_d [2];
	assign ring_feed_v[0] = ring0_route && sh0_tvalid;
	assign ring_feed_d[0] = sh0_tdata;
	assign ring_feed_v[1] = ring1_route && sh1_tvalid;
	assign ring_feed_d[1] = sh1_tdata;

	// Write/clear strobes come from the CTRL decode below (bit 7 bank).
	uwire logic ring_bank_wr   = (bstate == B_WR) && (seg == SEG_CTRL)
	                          && awaddr_q[7] && !awaddr_q[6];
	uwire logic ring_wr_sel    = awaddr_q[5];          // 0: core 0 bank, 1: core 1
	uwire logic [2:0] ring_wr_ix = awaddr_q[4:2];

	for (genvar gi = 0; gi < 2; gi++) begin : g_ringcfg
		uwire logic sel = ring_bank_wr && (int'(ring_wr_sel) == gi);
		// WARL acceptance: 32-byte aligned, inside the window, and -- for
		// size -- still inside it from the chosen base. Rejected writes set
		// the sticky cfg_rej instead of half-taking effect.
		uwire logic base_ok = (wdata_q >= RING_WIN_LO) && (wdata_q < RING_WIN_HI)
		                   && (wdata_q[4:0] == 5'b0);
		uwire logic size_ok = (wdata_q != 32'd0) && (wdata_q[4:0] == 5'b0)
		                   && ({1'b0, ring_base[gi]} + {1'b0, wdata_q} <= {1'b0, RING_WIN_HI});
		assign ring_clear_pulse[gi] = sel && (ring_wr_ix == 3'd0) && wdata_q[1];

		always_ff @(posedge clk) begin
			if (rst) begin
				ring_en[gi]      <= 1'b0;
				ring_circ[gi]    <= 1'b1;
				ring_route[gi]   <= 1'b0;           // FIFO path: pre-N3 behaviour
				ring_cfg_rej[gi] <= 1'b0;
				ring_base[gi]    <= (gi == 0) ? RING0_BASE_RST : RING1_BASE_RST;
				ring_size[gi]    <= RING_SIZE_RST;
				ring_beats[gi]   <= '0;
			end
			else begin
				if (ring_feed_v[gi] && ring_en[gi]) ring_beats[gi] <= ring_beats[gi] + 1;
				if (sel) begin
					unique case (ring_wr_ix)
						3'd0: begin
							ring_en[gi] <= wdata_q[0];
							if (wdata_q[1]) begin       // clear pulse
								ring_beats[gi]   <= '0;
								ring_cfg_rej[gi] <= 1'b0;
							end
							ring_circ[gi]  <= wdata_q[2];
							ring_route[gi] <= wdata_q[3];
						end
						3'd1: begin   // BASE: only while disabled, only legal
							if (!ring_en[gi] && base_ok) ring_base[gi] <= wdata_q;
							else                         ring_cfg_rej[gi] <= 1'b1;
						end
						3'd2: begin   // SIZE
							if (!ring_en[gi] && size_ok) ring_size[gi] <= wdata_q;
							else                         ring_cfg_rej[gi] <= 1'b1;
						end
						default: ;   // 0x0C.. read-only
					endcase
				end
			end
		end
	end

	ct_soc_ddr_sink ring_sink0 (
		.clk (clk), .rst (rst),
		.enable_i (ring_en[0]), .clear_i (ring_clear_pulse[0]),
		.base_i (ring_base[0]), .size_i (ring_size[0]), .circ_i (ring_circ[0]),
		.beat_valid_i (ring_feed_v[0] && ring_en[0]), .beat_data_i (ring_feed_d[0]),
		.wptr_o (ring_wptr[0]), .full_o (ring_full[0]), .wrapped_o (ring_wrapped[0]),
		.axi_err_o (ring_axi_err[0]), .drops_o (ring_drops[0]),
		.m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
		.m_axi_awvalid, .m_axi_awready,
		.m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid, .m_axi_wready,
		.m_axi_bresp, .m_axi_bvalid, .m_axi_bready
	);

	ct_soc_ddr_sink ring_sink1 (
		.clk (clk), .rst (rst),
		.enable_i (ring_en[1]), .clear_i (ring_clear_pulse[1]),
		.base_i (ring_base[1]), .size_i (ring_size[1]), .circ_i (ring_circ[1]),
		.beat_valid_i (ring_feed_v[1] && ring_en[1]), .beat_data_i (ring_feed_d[1]),
		.wptr_o (ring_wptr[1]), .full_o (ring_full[1]), .wrapped_o (ring_wrapped[1]),
		.axi_err_o (ring_axi_err[1]), .drops_o (ring_drops[1]),
		.m_axi_awaddr (m1_axi_awaddr), .m_axi_awlen (m1_axi_awlen),
		.m_axi_awsize (m1_axi_awsize), .m_axi_awburst (m1_axi_awburst),
		.m_axi_awvalid (m1_axi_awvalid), .m_axi_awready (m1_axi_awready),
		.m_axi_wdata (m1_axi_wdata), .m_axi_wstrb (m1_axi_wstrb),
		.m_axi_wlast (m1_axi_wlast), .m_axi_wvalid (m1_axi_wvalid),
		.m_axi_wready (m1_axi_wready),
		.m_axi_bresp (m1_axi_bresp), .m_axi_bvalid (m1_axi_bvalid),
		.m_axi_bready (m1_axi_bready)
	);

	// -- Funnel: 2x ATB -> 1x ATB (message-atomic, MDO=6 wire format) ------
	// Instantiation pattern: cva6_2_soc_synth_wrap (delta
	// version with chan_te_raw/te_tag_*; duo_soc_top leaves these inputs
	// open -- here it does NOT).
	atb_if atb_in [2] ();
	atb_if atb_mrg ();

	assign atb_in[0].atdata  = atb0_atdata;
	assign atb_in[0].atbytes = atb0_atbytes;
	assign atb_in[0].atid    = atb0_atid;
	assign atb_in[0].atvalid = atb0_atvalid;
	assign atb_in[0].afready = atb0_afready;
	assign atb0_atready = atb_in[0].atready;
	assign atb0_afvalid = atb_in[0].afvalid;
	assign atb0_syncreq = atb_in[0].syncreq;

	assign atb_in[1].atdata  = atb1_atdata;
	assign atb_in[1].atbytes = atb1_atbytes;
	assign atb_in[1].atid    = atb1_atid;
	assign atb_in[1].atvalid = atb1_atvalid;
	assign atb_in[1].afready = atb1_afready;
	assign atb1_atready = atb_in[1].atready;
	assign atb1_afvalid = atb_in[1].afvalid;
	assign atb1_syncreq = atb_in[1].syncreq;

	uwire logic [1:0] funnel_prio [2];
	assign funnel_prio[0] = 2'd1;            // both 1 = round-robin
	assign funnel_prio[1] = 2'd1;
	uwire logic funnel_participate [2];
	assign funnel_participate[0] = 1'b1;
	assign funnel_participate[1] = 1'b1;
	uwire logic funnel_chan_flush_req [2];
	assign funnel_chan_flush_req[0] = 1'b0;
	assign funnel_chan_flush_req[1] = 1'b0;
	uwire logic funnel_chan_te_raw [2];
	assign funnel_chan_te_raw[0] = atb0_te_raw;
	assign funnel_chan_te_raw[1] = atb1_te_raw;
	uwire logic funnel_flush_done_u [2];
	uwire logic global_flush_done_u;

	ct_L1_funnel #(
		.N_STREAMS  (2),
		.MAX_PRIO   (3),
		.MSEO_WIDTH (2),
		// 6 = four byte chunks per 32-bit beat = this encoder's real wire
		// format (NOT the default 30).
		.MDO_WIDTH  (6),
		.EN_TE_RAW  (0)
	) funnel (
		.atclk    (clk),
		.atresetn (resetn),
		.chan_prio              (funnel_prio),
		.chan_flush_participate (funnel_participate),
		.chan_flush_req         (funnel_chan_flush_req),
		.chan_te_raw            (funnel_chan_te_raw),
		.te_tag_always          (1'b0),
		.te_tag_resync          (1'b0),
		.global_flush_req       (trace_flush),
		.chan_flush_done        (funnel_flush_done_u),
		.global_flush_done      (global_flush_done_u),
		.atb_in  (atb_in),
		.atb_out (atb_mrg)
	);

	assign atb_mrg.atready = 1'b1;    // the ring is always ready to accept
	assign atb_mrg.afvalid = 1'b0;    // global flush runs via global_flush_req
	assign atb_mrg.syncreq = 1'b0;

	// -- Three-sink subsystem (T2): URAM ring + DDR4 + PIB at the funnel output --
	// (atready is constant 1, every atvalid cycle is an accepted beat).
	// Reset: all extra sinks off -> inert; the ring remains the primary sink.
	logic [31:0] trace_beats, trace_bytes, trace_rdata;
	logic        trace_overflow;
	logic [31:0] trace_rd_word;

	// EN_DDR=0 (N3): the ATB observer leg is compiled away -- the resmem
	// window belongs to the two record rings below, and the top's AXI
	// masters are theirs. URAM ring + PIB behave exactly as before; the
	// sink window's ddr_en/ddr_circ bits are WARL-masked to zero inside
	// ct_trace_sinks, so software probing 0x18 sees the leg is gone.
	ct_trace_sinks #(.TRACE_DEPTH(TRACE_DEPTH), .EN_DDR(1'b0)) sinks (
		.clk (clk), .rst (rst),
		.trace_clear (trace_clear),
		.atb_atvalid (atb_mrg.atvalid),
		.atb_atdata (atb_mrg.atdata),
		.atb_atbytes (atb_mrg.atbytes),
		.reg_wr_i (sinks_reg_wr), .reg_wr_ix_i (sinks_wr_ix), .reg_wr_data_i (sinks_wr_data),
		.reg_rd_ix_i (sinks_rd_ix), .reg_rd_data_o (sinks_rd_data),
		.trace_beats_o (trace_beats), .trace_bytes_o (trace_bytes),
		.trace_wrapped_o (trace_overflow),
		.trace_rd_word (trace_rd_word), .trace_rd_data (trace_rdata),
		.m_axi_awaddr (), .m_axi_awlen (), .m_axi_awsize (), .m_axi_awburst (),
		.m_axi_awvalid (), .m_axi_awready (1'b0),
		.m_axi_wdata (), .m_axi_wstrb (), .m_axi_wlast (), .m_axi_wvalid (),
		.m_axi_wready (1'b0),
		.m_axi_bresp (2'b00), .m_axi_bvalid (1'b0), .m_axi_bready (),
		.pib_clk, .pib_data
	);

	// -- Region decode (duo_soc_top without an AXIS window) -----------------
	typedef enum logic [2:0] { SEG_CTRL, SEG_ENC0, SEG_ENC1, SEG_RAM0, SEG_RAM1, SEG_TRACE, SEG_SHARED } seg_e;

	function automatic seg_e seg_of(input logic [21:0] a);
		if      (a[21])          seg_of = SEG_TRACE;
		else if (a[20])          seg_of = SEG_RAM0;
		else if (a[19])          seg_of = SEG_RAM1;
		else if (a[18])          seg_of = SEG_SHARED;   // 0x04_0000 (RV/CFI)
		else if (a[17])          seg_of = SEG_ENC1;
		else if (a[16])          seg_of = SEG_ENC0;
		else                     seg_of = SEG_CTRL;
	endfunction

	// ======================================================================
	// AXI4-Lite front end (1:1 from mbv_soc_top/duo_soc_top)
	// ======================================================================
	logic        axi_awready, axi_wready, axi_bvalid, axi_arready, axi_rvalid;
	logic        aw_en;
	logic        rd_busy;
	logic [21:0] awaddr_q, araddr_q;
	logic [31:0] wdata_q, rdata_q;
	logic [3:0]  wstrb_q;

	assign s_axi_awready = axi_awready;
	assign s_axi_wready  = axi_wready;
	assign s_axi_bvalid  = axi_bvalid;
	assign s_axi_bresp   = RESP_OKAY;
	assign s_axi_arready = axi_arready;
	assign s_axi_rvalid  = axi_rvalid;
	assign s_axi_rdata   = rdata_q;
	assign s_axi_rresp   = RESP_OKAY;

	always_ff @(posedge clk) begin
		if (rst) begin
			axi_awready <= 1'b0;
			aw_en       <= 1'b1;
			awaddr_q    <= '0;
		end
		else if (!axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
			axi_awready <= 1'b1;
			awaddr_q    <= s_axi_awaddr;
			aw_en       <= 1'b0;
		end
		else if (axi_bvalid && s_axi_bready) begin
			aw_en       <= 1'b1;
			axi_awready <= 1'b0;
		end
		else begin
			axi_awready <= 1'b0;
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			axi_wready <= 1'b0;
			wdata_q    <= '0;
			wstrb_q    <= '0;
		end
		else if (!axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en) begin
			axi_wready <= 1'b1;
			wdata_q    <= s_axi_wdata;
			wstrb_q    <= s_axi_wstrb;
		end
		else begin
			axi_wready <= 1'b0;
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			axi_arready <= 1'b0;
			araddr_q    <= '0;
		end
		else if (!axi_arready && s_axi_arvalid && !rd_busy) begin
			axi_arready <= 1'b1;
			araddr_q    <= s_axi_araddr;
		end
		else begin
			axi_arready <= 1'b0;
		end
	end

	uwire logic wr_fire = axi_awready && s_axi_awvalid && axi_wready && s_axi_wvalid;
	uwire logic rd_fire = axi_arready && s_axi_arvalid;

	// ======================================================================
	// Backend (region service; 4 sub-slaves: ENC0/ENC1/RAM0/RAM1)
	// ======================================================================
	typedef enum logic [3:0] {
		B_IDLE, B_WR, B_SUB_AW, B_SUB_B, B_RD, B_SUB_AR, B_SUB_R, B_TRACE0, B_TRACE1
	} bstate_e;

	bstate_e     bstate;
	seg_e        seg;

	// Sub-slave return path of the currently selected target.
	logic sub_awready, sub_wready, sub_bvalid, sub_arready, sub_rvalid;
	logic [31:0] sub_rdata;
	always_comb begin
		unique case (seg)
			SEG_ENC0: begin sub_awready = e0_awready; sub_wready = e0_wready; sub_bvalid = e0_bvalid;
			                sub_arready = e0_arready; sub_rvalid = e0_rvalid; sub_rdata = e0_rdata; end
			SEG_ENC1: begin sub_awready = e1_awready; sub_wready = e1_wready; sub_bvalid = e1_bvalid;
			                sub_arready = e1_arready; sub_rvalid = e1_rvalid; sub_rdata = e1_rdata; end
			SEG_RAM0: begin sub_awready = r0_awready; sub_wready = r0_wready; sub_bvalid = r0_bvalid;
			                sub_arready = r0_arready; sub_rvalid = r0_rvalid; sub_rdata = r0_rdata; end
			SEG_RAM1: begin sub_awready = r1_awready; sub_wready = r1_wready; sub_bvalid = r1_bvalid;
			                sub_arready = r1_arready; sub_rvalid = r1_rvalid; sub_rdata = r1_rdata; end
			SEG_SHARED: begin sub_awready = s0_awready; sub_wready = s0_wready; sub_bvalid = s0_bvalid;
			                sub_arready = s0_arready; sub_rvalid = s0_rvalid; sub_rdata = s0_rdata; end
			default:  begin sub_awready = 1'b0; sub_wready = 1'b0; sub_bvalid = 1'b0;
			                sub_arready = 1'b0; sub_rvalid = 1'b0; sub_rdata = '0; end
		endcase
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			bstate <= B_IDLE; seg <= SEG_CTRL; rd_busy <= 1'b0;
			axi_bvalid <= 1'b0; axi_rvalid <= 1'b0; rdata_q <= '0;
			control_reg <= '0;
		end
		else begin
			if (axi_bvalid && s_axi_bready) axi_bvalid <= 1'b0;
			if (axi_rvalid && s_axi_rready) begin axi_rvalid <= 1'b0; rd_busy <= 1'b0; end

			case (bstate)
				B_IDLE: begin
					if (wr_fire) begin seg <= seg_of(awaddr_q); bstate <= B_WR; end
					else if (rd_fire) begin seg <= seg_of(araddr_q); rd_busy <= 1'b1; bstate <= B_RD; end
				end

				B_WR: begin
					unique case (seg)
						SEG_CTRL: begin
							// RV/CFI: 0x40..0x7C is a READ-ONLY observation
							// bank (bit 6 of the offset). Writes there must
							// not fall through to the 0x00..0x3C decode,
							// which would alias 0x40 onto CONTROL and hand
							// the sink window a matching index -- so the
							// write case is gated on !awaddr_q[6] and the
							// sinks strobe is gated the same way below.
							// 0x80..0xBC (bit 7) is the N3 ring bank: its
							// writes land in the g_ringcfg registers via the
							// ring_bank_wr strobe THIS cycle and must not
							// alias onto CONTROL either.
							if (!awaddr_q[7] && !awaddr_q[6]) begin
								case (awaddr_q[5:2])
									4'd0: control_reg <= wdata_q;
									// 0x18..0x38: sink window in ct_trace_sinks
									// (sinks_reg_wr strobes in this cycle).
									default: ;
								endcase
							end
							axi_bvalid <= 1'b1; bstate <= B_IDLE;
						end
						SEG_ENC0, SEG_ENC1, SEG_RAM0, SEG_RAM1, SEG_SHARED: bstate <= B_SUB_AW;
						default: begin axi_bvalid <= 1'b1; bstate <= B_IDLE; end   // TRACE write ignored
					endcase
				end
				B_SUB_AW: if (sub_awready && sub_wready) bstate <= B_SUB_B;
				B_SUB_B:  if (sub_bvalid) begin axi_bvalid <= 1'b1; bstate <= B_IDLE; end

				B_RD: begin
					unique case (seg)
						SEG_CTRL: if (araddr_q[7]) begin
							// -- N3 ring bank, 0x80 (core 0) / 0xA0 (core 1) --
							// bit 6 set (0xC0..) is OUTSIDE the bank and
							// reads zero -- unguarded it would alias.
							if (araddr_q[6]) rdata_q <= '0;
							else case ({araddr_q[5], araddr_q[4:2]})
								{1'b0, 3'd0}: rdata_q <= {28'b0, ring_route[0], ring_circ[0], 1'b0, ring_en[0]};
								{1'b0, 3'd1}: rdata_q <= ring_base[0];
								{1'b0, 3'd2}: rdata_q <= ring_size[0];
								{1'b0, 3'd3}: rdata_q <= ring_wptr[0];
								{1'b0, 3'd4}: rdata_q <= {28'b0, ring_cfg_rej[0], ring_wrapped[0], ring_axi_err[0], ring_full[0]};
								{1'b0, 3'd5}: rdata_q <= ring_drops[0];
								{1'b0, 3'd6}: rdata_q <= ring_beats[0];
								{1'b1, 3'd0}: rdata_q <= {28'b0, ring_route[1], ring_circ[1], 1'b0, ring_en[1]};
								{1'b1, 3'd1}: rdata_q <= ring_base[1];
								{1'b1, 3'd2}: rdata_q <= ring_size[1];
								{1'b1, 3'd3}: rdata_q <= ring_wptr[1];
								{1'b1, 3'd4}: rdata_q <= {28'b0, ring_cfg_rej[1], ring_wrapped[1], ring_axi_err[1], ring_full[1]};
								{1'b1, 3'd5}: rdata_q <= ring_drops[1];
								{1'b1, 3'd6}: rdata_q <= ring_beats[1];
								default:      rdata_q <= '0;
							endcase
							axi_rvalid <= 1'b1; bstate <= B_IDLE;
						end
						else if (araddr_q[6]) begin
							// -- RV/CFI observation bank, read-only, 0x40.. --
							// Everything a host needs to tell "the record was
							// dropped" from "the instrumentation never fired":
							// the doorbell counts the STORES software issued,
							// the adapter counts the beats it CONVERTED, and
							// the shim (elsewhere) counts what it had to drop.
							// Three numbers, three different failure modes.
							case (araddr_q[5:2])
								4'd0:    rdata_q <= db0_hits;              // 0x40
								4'd1:    rdata_q <= db0_last;              // 0x44
								4'd2:    rdata_q <= db1_hits;              // 0x48
								4'd3:    rdata_q <= db1_last;              // 0x4C
								4'd4:    rdata_q <= actcap0_count;         // 0x50
								4'd5:    rdata_q <= actcap1_count;         // 0x54
								4'd6:    rdata_q <= 32'(SHARED_KIB * 1024);// 0x58 bytes
								4'd7:    rdata_q <= 32'h5256_4349;         // 0x5C "RVCI"
								// -- console (N1), 0x60.. --------------------
								4'd8:    rdata_q <= {con0_tx_cnt, con0_rx_free};       // 0x60 CON0_STAT
								4'd9:    rdata_q <= {con0_tx_valid, 23'b0, con0_tx_data}; // 0x64 CON0_POP (pops)
								4'd10:   rdata_q <= 32'(con0_rx_drops);                // 0x68 (W: push)
								4'd12:   rdata_q <= {con1_tx_cnt, con1_rx_free};       // 0x70 CON1_STAT
								4'd13:   rdata_q <= {con1_tx_valid, 23'b0, con1_tx_data}; // 0x74 CON1_POP (pops)
								4'd14:   rdata_q <= 32'(con1_rx_drops);                // 0x78 (W: push)
								default: rdata_q <= '0;
							endcase
							axi_rvalid <= 1'b1; bstate <= B_IDLE;
						end
						else begin
							case (araddr_q[5:2])
								4'd0:    rdata_q <= control_reg;
								// U1: b8/b9 = EFFECTIVE run state per core
								// (b0 OR b8/b9) -- one read suffices to see
								// which core is really running.
								4'd1:    rdata_q <= {22'b0, core1_run, core0_run,
								                     7'b0, trace_overflow};
								4'd2:    rdata_q <= trace_beats;
								4'd3:    rdata_q <= trace_bytes;
								4'd4:    rdata_q <= 32'(TRACE_DEPTH * 4);
								4'd5:    rdata_q <= '0;
								// 0x18..0x38: sink window (ct_trace_sinks, T2)
								default: rdata_q <= sinks_rd_data;
							endcase
							axi_rvalid <= 1'b1; bstate <= B_IDLE;
						end
						SEG_TRACE: bstate <= B_TRACE0;
						default:   bstate <= B_SUB_AR;
					endcase
				end
				B_TRACE0: bstate <= B_TRACE1;
				B_TRACE1: begin rdata_q <= trace_rdata; axi_rvalid <= 1'b1; bstate <= B_IDLE; end
				B_SUB_AR: if (sub_arready) bstate <= B_SUB_R;
				B_SUB_R:  if (sub_rvalid) begin
					rdata_q <= sub_rdata;
					axi_rvalid <= 1'b1; bstate <= B_IDLE;
				end
				default: bstate <= B_IDLE;
			endcase
		end
	end

	// Region-local byte address to all sub-slaves (valids select the target).
	uwire logic [21:0] acc_addr = (bstate == B_SUB_AR || bstate == B_SUB_R) ? araddr_q : awaddr_q;
	assign sub_addr  = {16'b0, acc_addr[15:0]};
	assign sub_wdata = wdata_q;
	assign sub_wstrb = wstrb_q;

	assign e0_awvalid = (bstate == B_SUB_AW) && (seg == SEG_ENC0);
	assign e0_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_ENC0);
	assign e0_bready  = (bstate == B_SUB_B)  && (seg == SEG_ENC0);
	assign e0_arvalid = (bstate == B_SUB_AR) && (seg == SEG_ENC0);
	assign e0_rready  = (bstate == B_SUB_R)  && (seg == SEG_ENC0);

	assign e1_awvalid = (bstate == B_SUB_AW) && (seg == SEG_ENC1);
	assign e1_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_ENC1);
	assign e1_bready  = (bstate == B_SUB_B)  && (seg == SEG_ENC1);
	assign e1_arvalid = (bstate == B_SUB_AR) && (seg == SEG_ENC1);
	assign e1_rready  = (bstate == B_SUB_R)  && (seg == SEG_ENC1);

	assign r0_awvalid = (bstate == B_SUB_AW) && (seg == SEG_RAM0);
	assign r0_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_RAM0);
	assign r0_bready  = (bstate == B_SUB_B)  && (seg == SEG_RAM0);
	assign r0_arvalid = (bstate == B_SUB_AR) && (seg == SEG_RAM0);
	assign r0_rready  = (bstate == B_SUB_R)  && (seg == SEG_RAM0);

	assign r1_awvalid = (bstate == B_SUB_AW) && (seg == SEG_RAM1);
	assign r1_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_RAM1);
	assign r1_bready  = (bstate == B_SUB_B)  && (seg == SEG_RAM1);
	assign r1_arvalid = (bstate == B_SUB_AR) && (seg == SEG_RAM1);
	assign r1_rready  = (bstate == B_SUB_R)  && (seg == SEG_RAM1);

	assign s0_awvalid = (bstate == B_SUB_AW) && (seg == SEG_SHARED);
	assign s0_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_SHARED);
	assign s0_bready  = (bstate == B_SUB_B)  && (seg == SEG_SHARED);
	assign s0_arvalid = (bstate == B_SUB_AR) && (seg == SEG_SHARED);
	assign s0_rready  = (bstate == B_SUB_R)  && (seg == SEG_SHARED);

	assign trace_rd_word = {12'b0, araddr_q[21:2]};

	// Sink-window accesses (0x18..0x38) delegated to ct_trace_sinks: the
	// strobe fires in exactly the one B_WR cycle of the CTRL segment; the
	// module decodes its own indices (0x00/0x04.. stay here).
	assign sinks_reg_wr  = (bstate == B_WR) && (seg == SEG_CTRL)
	                    && !awaddr_q[7] && !awaddr_q[6];
	assign sinks_wr_ix   = awaddr_q[5:2];
	assign sinks_wr_data = wdata_q;
	assign sinks_rd_ix   = araddr_q[5:2];

	// RAM loader: 20 region-local address bits (like duo; both RAMs are
	// 64 KiB, the higher bits run idle in the RAM). ENC bridges only the
	// lower 16.
	assign ram_addr = {12'b0, acc_addr[19:0]};

	// Shared-memory window: 18 region-local address bits (256 KiB at the
	// default SHARED_KIB; a larger array simply uses more of them, a smaller
	// one aliases -- see ct_soc_shared_mem's contract).
	assign shared_addr = {14'b0, acc_addr[17:0]};

endmodule

`default_nettype wire
