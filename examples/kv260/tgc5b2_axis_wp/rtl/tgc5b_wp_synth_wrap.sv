// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    AXIS-Watchpoint-Testbed: TGC5B + CTTE wrapper with an EXTERNAL
 *           time base (local copy of the shared TGC5B synth wrap).
 *
 * @details
 *   1:1 copy of `../../common/tgc5b/rtl/ct_soc_synth_wrap.sv`
 *   (vendored upstream example, read-only) with exactly THREE documented
 *   deviations for the dual-TGC5b AXIS watchpoint testbed (package C1,
 *   docs/PLAN_axis_wp_testbed.md §3a):
 *
 *   (a) NEW port `time_i` [63:0] feeds the TIP adapter's `h2e_inst_time`
 *       instead of the core's own `h2e_inst_time_o` (= CsrFile_cycle, the
 *       core-local mcycle). Two cores mean two drifting mcycle counters —
 *       a shared free-running fabric counter is the common time base for
 *       both encoders (`tip._time` → TR_TS_CORE), see
 *       docs/FINDINGS_axis_wp_analyse.md Teil C0 §4. The CTTE and the
 *       vendored ct_tip_adapter stay untouched; only this SoC-level
 *       wrapper rewires the source.
 *   (b) Module renamed ct_soc_synth_wrap → tgc5b_wp_synth_wrap (both the
 *       reference wrapper and this copy are compiled in the same builds).
 *   (c) The AXIS export carries `axis_tstrb` instead of the reference's
 *       `axis_tkeep`/`axis_tlast`: the encoder's AXIS master drives
 *       tvalid/tdata/tstrb/tid ONLY — tkeep and tlast are never driven
 *       (FINDINGS Teil W2 §3.2b) and would export X into the downstream
 *       ct_axis_wp_shim, which consumes the real qualifier `tstrb` for
 *       its word-3 metadata.
 *
 *   Everything else (core, TIP adapter, encoder, RAM + loader mux, CLINT/
 *   INTC, dBus decode, external Wishbone config port) is unchanged from
 *   the reference — see that file's header for the memory map and the
 *   core_rst_hold / cfg_wb_en contracts.
 */

module tgc5b_wp_synth_wrap #(
	logic [31:0] RESET_VECTOR  = 32'h0000_0000,
	int unsigned MEM_WORDS     = 16384,          // 64 KiB
	string       MEM_INIT_FILE = "",
	// Per-instance backend selection of the encoder (default = build profile):
	// 1 = build the E-Trace backend in as well (DUAL when N-Trace is on).
	bit EN_ETRACE = ct_pkg::CT_EN_ETRACE
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous
	// Hold ONLY the core in reset (encoder/peripherals run) so a host can
	// program the encoder CSRs before the first instruction retires, and thus
	// trace the program from its start. Tie 0 for normal operation.
	input  uwire logic        core_rst_hold,

	// -- Shared time base (deviation (a), see header) ----------------------
	// Free-running fabric counter, common to all encoder instances; replaces
	// the core-local CsrFile_cycle as tip._time.
	input  uwire logic [63:0] time_i,

	// -- ATB (Nexus trace) master, flat -----------------------------------
	output      logic [31:0]  atb_atdata,
	output      logic [1:0]   atb_atbytes,
	output      logic [6:0]   atb_atid,
	output      logic         atb_atvalid,
	input  uwire logic        atb_atready,
	output      logic         atb_afready,
	// ATB framing of this encoder (0 = Nexus MSEO, 1 = E-Trace raw bytes)
	output      logic         atb_te_raw,
	input  uwire logic        atb_afvalid,
	input  uwire logic        atb_syncreq,

	// -- AXIS instrumentation stream (ACT-CAP/ACT-ST DAQ sink) -------------
	// Deviation (c): tstrb exported (driven qualifier); tkeep/tlast are
	// never driven by the encoder and therefore not exported.
	output      logic [95:0]  axis_tdata,
	output      logic [11:0]  axis_tstrb,
	output      logic [7:0]   axis_tid,
	output      logic         axis_tvalid,
	input  uwire logic        axis_tready,

	// -- External encoder-CSR config port (Wishbone) -----------------------
	// Lets a host/testbench program the encoder CSRs directly, so an
	// un-instrumented program can be traced. When cfg_wb_en=1 this port drives
	// the encoder CSRs instead of the core's dBus bridge. Tie cfg_wb_en=0 (the
	// default use) to let the running program own the CSRs via 0x2000_0000.
	input  uwire logic        cfg_wb_en,
	input  uwire logic        cfg_wb_cyc,
	input  uwire logic        cfg_wb_stb,
	input  uwire logic        cfg_wb_we,
	input  uwire logic [31:0] cfg_wb_addr,
	input  uwire logic [31:0] cfg_wb_data_m2s,
	input  uwire logic [3:0]  cfg_wb_sel,
	output      logic [31:0]  cfg_wb_data_s2m,
	output      logic         cfg_wb_ack,
	output      logic         cfg_wb_err,

	// -- External RAM-load port (AXI4-Lite) --------------------------------
	// Lets a host load the program into RAM while the core is held. It drives
	// the RAM data port whenever core_rst_hold=1 (the core's dBus is idle then).
	input  uwire logic        ldr_awvalid,
	output      logic         ldr_awready,
	input  uwire logic [31:0] ldr_awaddr,
	input  uwire logic        ldr_wvalid,
	output      logic         ldr_wready,
	input  uwire logic [31:0] ldr_wdata,
	input  uwire logic [3:0]  ldr_wstrb,
	output      logic         ldr_bvalid,
	input  uwire logic        ldr_bready,
	output      logic [1:0]   ldr_bresp,
	input  uwire logic        ldr_arvalid,
	output      logic         ldr_arready,
	input  uwire logic [31:0] ldr_araddr,
	output      logic         ldr_rvalid,
	input  uwire logic        ldr_rready,
	output      logic [31:0]  ldr_rdata,
	output      logic [1:0]   ldr_rresp,

	// -- Uncompressed golden trace reference (from the core) ---------------
	output      logic [31:0]  core_trace_pc,
	output      logic         core_trace_valid
);

	uwire logic atb_atresetn = ~rst;
	uwire logic core_reset   = rst || core_rst_hold;

	// ---------------------------------------------------------------------
	// Core buses
	// ---------------------------------------------------------------------
	// iBus (AXI4-Lite, read-only) -> RAM port I
	uwire logic        ibus_arvalid;
	uwire logic        ibus_arready;
	uwire logic [31:0] ibus_araddr;
	uwire logic        ibus_rvalid;
	uwire logic        ibus_rready;
	uwire logic [31:0] ibus_rdata;
	uwire logic [1:0]  ibus_rresp;

	// dBus (AXI4-Lite, read/write) -> address decoder
	uwire logic        dbus_awvalid;
	uwire logic        dbus_awready;
	uwire logic [31:0] dbus_awaddr;
	uwire logic        dbus_wvalid;
	uwire logic        dbus_wready;
	uwire logic [31:0] dbus_wdata;
	uwire logic [3:0]  dbus_wstrb;
	uwire logic        dbus_bvalid;
	uwire logic        dbus_bready;
	uwire logic [1:0]  dbus_bresp;
	uwire logic        dbus_arvalid;
	uwire logic        dbus_arready;
	uwire logic [31:0] dbus_araddr;
	uwire logic        dbus_rvalid;
	uwire logic        dbus_rready;
	uwire logic [31:0] dbus_rdata;
	uwire logic [1:0]  dbus_rresp;

	// ---------------------------------------------------------------------
	// Core H2E trace port + interrupts
	// ---------------------------------------------------------------------
	uwire logic [3:0]  h2e_inst_itype;
	uwire logic [3:0]  h2e_inst_cause;
	uwire logic [31:0] h2e_inst_tval;
	uwire logic [2:0]  h2e_inst_priv;
	uwire logic [31:0] h2e_inst_iaddr;
	uwire logic [1:0]  h2e_inst_context;
	uwire logic [63:0] h2e_inst_time;
	uwire logic [1:0]  h2e_inst_ctype;
	uwire logic        h2e_inst_iretire;
	uwire logic [1:0]  h2e_inst_ilastsize;
	uwire logic [3:0]  h2e_data_dtype;
	uwire logic [31:0] h2e_data_daddr;
	uwire logic [7:0]  h2e_data_dsize;
	uwire logic        h2e_data_dretire;
	uwire logic [31:0] h2e_data_sdata;
	uwire logic [1:0]  h2e_data_lresp;
	uwire logic [31:0] h2e_data_ldata;

	uwire logic [63:0] mtime;
	uwire logic        tim_irq;
	uwire logic        sw_irq;
	uwire logic        ext_irq;

	// ---------------------------------------------------------------------
	// RISC-V core (MINRES TGC5B). Active-high reset; boots at RESET_VECTOR.
	// ---------------------------------------------------------------------
	TGC5B_AXI4L_H2E core_inst (
		.reset_vector_i     (RESET_VECTOR),

		.h2e_inst_itype_o   (h2e_inst_itype),
		.h2e_inst_cause_o   (h2e_inst_cause),
		.h2e_inst_tval_o    (h2e_inst_tval),
		.h2e_inst_priv_o    (h2e_inst_priv),
		.h2e_inst_iaddr_o   (h2e_inst_iaddr),
		.h2e_inst_context_o (h2e_inst_context),
		.h2e_inst_time_o    (h2e_inst_time),
		.h2e_inst_ctype_o   (h2e_inst_ctype),
		.h2e_inst_iretire_o (h2e_inst_iretire),
		.h2e_inst_ilastsize_o (h2e_inst_ilastsize),

		.h2e_data_dtype_o   (h2e_data_dtype),
		.h2e_data_daddr_o   (h2e_data_daddr),
		.h2e_data_dsize_o   (h2e_data_dsize),
		.h2e_data_dretire_o (h2e_data_dretire),
		.h2e_data_sdata_o   (h2e_data_sdata),
		.h2e_data_lresp_o   (h2e_data_lresp),
		.h2e_data_ldata_o   (h2e_data_ldata),

		.h2e_stall_req_i    (1'b0),
		.h2e_stall_gnt_o    (),
		.wfi_o              (),
		.idle_o             (),

		.mtime_i            (mtime),
		.tim_irq_i          (tim_irq),
		.sw_irq_i           (sw_irq),
		.ext_irq_i          (ext_irq),

		.core_trace_instr_o   (),
		.core_trace_pc_o      (core_trace_pc),
		.core_trace_valid_o   (core_trace_valid),
		.core_trace_irq_o     (),
		.core_trace_exc_o     (),
		.core_trace_exccode_o (),
		.core_trace_reg_addr_o(),
		.core_trace_reg_wr_o  (),
		.core_trace_reg_val_o (),

		.iBusAxiL_arvalid   (ibus_arvalid),
		.iBusAxiL_arready   (ibus_arready),
		.iBusAxiL_araddr    (ibus_araddr),
		.iBusAxiL_arprot    (),
		.iBusAxiL_rvalid    (ibus_rvalid),
		.iBusAxiL_rready    (ibus_rready),
		.iBusAxiL_rdata     (ibus_rdata),
		.iBusAxiL_rresp     (ibus_rresp),

		.dBusAxiL_awvalid   (dbus_awvalid),
		.dBusAxiL_awready   (dbus_awready),
		.dBusAxiL_awaddr    (dbus_awaddr),
		.dBusAxiL_awprot    (),
		.dBusAxiL_wvalid    (dbus_wvalid),
		.dBusAxiL_wready    (dbus_wready),
		.dBusAxiL_wdata     (dbus_wdata),
		.dBusAxiL_wstrb     (dbus_wstrb),
		.dBusAxiL_bvalid    (dbus_bvalid),
		.dBusAxiL_bready    (dbus_bready),
		.dBusAxiL_bresp     (dbus_bresp),
		.dBusAxiL_arvalid   (dbus_arvalid),
		.dBusAxiL_arready   (dbus_arready),
		.dBusAxiL_araddr    (dbus_araddr),
		.dBusAxiL_arprot    (),
		.dBusAxiL_rvalid    (dbus_rvalid),
		.dBusAxiL_rready    (dbus_rready),
		.dBusAxiL_rdata     (dbus_rdata),
		.dBusAxiL_rresp     (dbus_rresp),

		.clk                (clk),
		.reset              (core_reset)
	);

	// ---------------------------------------------------------------------
	// TIP adapter + encoder
	// ---------------------------------------------------------------------
	tip_if tip();

	ct_tip_adapter tip_adapter_inst (
		.h2e_inst_itype     (h2e_inst_itype),
		.h2e_inst_cause     (h2e_inst_cause),
		.h2e_inst_tval      (h2e_inst_tval),
		.h2e_inst_priv      (h2e_inst_priv),
		.h2e_inst_iaddr     (h2e_inst_iaddr),
		.h2e_inst_context   (h2e_inst_context),
		// Deviation (a): shared fabric counter instead of the core-local
		// CsrFile_cycle (h2e_inst_time) — common time base for both
		// encoder instances (FINDINGS Teil C0 §4).
		.h2e_inst_time      (time_i),
		.h2e_inst_ctype     (h2e_inst_ctype),
		.h2e_inst_iretire   (h2e_inst_iretire),
		.h2e_inst_ilastsize (h2e_inst_ilastsize),
		.h2e_data_dtype     (h2e_data_dtype),
		.h2e_data_daddr     (h2e_data_daddr),
		.h2e_data_dsize     (h2e_data_dsize),
		.h2e_data_dretire   (h2e_data_dretire),
		.h2e_data_sdata     (h2e_data_sdata),
		.h2e_data_lresp     (h2e_data_lresp),
		.h2e_data_ldata     (h2e_data_ldata),
		.tip                (tip.master)
	);

	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb();    // -> encoder CSRs
	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) bwb();   // <- dBus bridge
	axis_if #(.TDATA_WIDTH(96), .TID_WIDTH(8)) axis (.aclk(clk), .aresetn(~rst));
	atb_if atb();

	// Encoder CSR source select: external config host (cfg_wb_*) or the core's
	// dBus bridge (bwb). Lets an un-instrumented program be traced by a host.
	always_comb begin
		if (cfg_wb_en) begin
			wb.cyc      = cfg_wb_cyc;
			wb.stb      = cfg_wb_stb;
			wb.we       = cfg_wb_we;
			wb.addr     = cfg_wb_addr;
			wb.data_m2s = cfg_wb_data_m2s;
			wb.sel      = cfg_wb_sel;
		end
		else begin
			wb.cyc      = bwb.cyc;
			wb.stb      = bwb.stb;
			wb.we       = bwb.we;
			wb.addr     = bwb.addr;
			wb.data_m2s = bwb.data_m2s;
			wb.sel      = bwb.sel;
		end
	end

	// Responses fan back to both potential masters (harmless to the idle one).
	assign bwb.data_s2m    = wb.data_s2m;
	assign bwb.ack         = cfg_wb_en ? 1'b0 : wb.ack;
	assign bwb.err         = cfg_wb_en ? 1'b0 : wb.err;
	assign cfg_wb_data_s2m = wb.data_s2m;
	assign cfg_wb_ack      = cfg_wb_en ? wb.ack : 1'b0;
	assign cfg_wb_err      = cfg_wb_en ? wb.err : 1'b0;

	// Encoder: single clock domain (all five encoder clocks tied to clk).
	// CORE_XLEN(32): TGC5B is an RV32 hart; the synced encoder (M0, R1-era
	// guard) refuses elaboration unless the instantiator states the XLEN.
	ct_encoder #(.SPLIT_DATA_ACCESS(1), .EN_ETRACE(EN_ETRACE), .EN_NTRACE(!EN_ETRACE),
	             .CORE_XLEN(32)) ct_encoder_inst (
		.tip_clk      (clk),
		.tip_rst      (rst),
		.tip          (tip.slave),
		.wb_clk       (clk),
		.wb_rst       (rst),
		.wb           (wb.slave),
		.ct_cs_rst    (rst),
		.axis         (axis.master),
		.atb_atclk    (clk),
		.atb_atresetn (atb_atresetn),
		.atb          (atb.master),
		.atb_te_raw   (atb_te_raw),
		.proc_clk     (clk),
		.proc_rst     (rst),
		.wall_clk     (clk),
		.wall_clk_rst (rst)
	);

	// ATB master -> flat top ports; sink handshake from top inputs.
	assign atb_atdata  = atb.atdata;
	assign atb_atbytes = atb.atbytes;
	assign atb_atid    = atb.atid;
	assign atb_atvalid = atb.atvalid;
	assign atb_afready = atb.afready;
	assign atb.atready = atb_atready;
	assign atb.afvalid = atb_afvalid;
	assign atb.syncreq = atb_syncreq;

	// AXIS instrumentation export. Deviation (c): tstrb is the qualifier the
	// encoder actually drives; tkeep/tlast are never driven (would read X)
	// and are intentionally not exported.
	assign axis.tready  = axis_tready;
	assign axis_tdata   = axis.tdata;
	assign axis_tstrb   = axis.tstrb;
	assign axis_tid     = axis.tid;
	assign axis_tvalid  = axis.tvalid;

	// ---------------------------------------------------------------------
	// Peripheral block (CLINT + INTC) on dBus PERIPH segment
	// ---------------------------------------------------------------------
	logic        periph_awvalid, periph_awready, periph_wvalid, periph_wready;
	logic        periph_bvalid,  periph_bready;
	logic [1:0]  periph_bresp;
	logic        periph_arvalid, periph_arready, periph_rvalid, periph_rready;
	logic [31:0] periph_rdata;
	logic [1:0]  periph_rresp;

	ct_soc_periph periph_inst (
		.clk        (clk),
		.rst        (rst),
		.s_awvalid  (periph_awvalid),
		.s_awready  (periph_awready),
		.s_awaddr   (dbus_awaddr[12:0]),
		.s_awprot   (3'b0),
		.s_wvalid   (periph_wvalid),
		.s_wready   (periph_wready),
		.s_wdata    (dbus_wdata),
		.s_wstrb    (dbus_wstrb),
		.s_bvalid   (periph_bvalid),
		.s_bready   (periph_bready),
		.s_bresp    (periph_bresp),
		.s_arvalid  (periph_arvalid),
		.s_arready  (periph_arready),
		.s_araddr   (dbus_araddr[12:0]),
		.s_arprot   (3'b0),
		.s_rvalid   (periph_rvalid),
		.s_rready   (periph_rready),
		.s_rdata    (periph_rdata),
		.s_rresp    (periph_rresp),
		.mtime_o    (mtime),
		.tim_irq_o  (tim_irq),
		.sw_irq_o   (sw_irq),
		.ext_irq_o  (ext_irq)
	);

	// ---------------------------------------------------------------------
	// Encoder CSR bridge on dBus ENCODER segment (AXI4-Lite -> Wishbone)
	// ---------------------------------------------------------------------
	logic        enc_awvalid, enc_awready, enc_wvalid, enc_wready;
	logic        enc_bvalid,  enc_bready;
	logic [1:0]  enc_bresp;
	logic        enc_arvalid, enc_arready, enc_rvalid, enc_rready;
	logic [31:0] enc_rdata;
	logic [1:0]  enc_rresp;

	ct_axil_to_wb enc_bridge_inst (
		.clk        (clk),
		.rst        (rst),
		.s_awvalid  (enc_awvalid),
		.s_awready  (enc_awready),
		.s_awaddr   ({17'b0, dbus_awaddr[14:0]}),
		.s_wvalid   (enc_wvalid),
		.s_wready   (enc_wready),
		.s_wdata    (dbus_wdata),
		.s_wstrb    (dbus_wstrb),
		.s_bvalid   (enc_bvalid),
		.s_bready   (enc_bready),
		.s_bresp    (enc_bresp),
		.s_arvalid  (enc_arvalid),
		.s_arready  (enc_arready),
		.s_araddr   ({17'b0, dbus_araddr[14:0]}),
		.s_rvalid   (enc_rvalid),
		.s_rready   (enc_rready),
		.s_rdata    (enc_rdata),
		.s_rresp    (enc_rresp),
		.wb         (bwb.master)
	);

	// ---------------------------------------------------------------------
	// RAM (dBus RAM segment on port D, iBus on port I)
	// ---------------------------------------------------------------------
	// dBus-decoder view of the RAM data port (the decoder drives the *valid /
	// *ready-consume signals and reads the responses via these names).
	logic        ram_awvalid, ram_awready, ram_wvalid, ram_wready;
	logic        ram_bvalid,  ram_bready;
	logic [1:0]  ram_bresp;
	logic        ram_arvalid, ram_arready, ram_rvalid, ram_rready;
	logic [31:0] ram_rdata;
	logic [1:0]  ram_rresp;

	// Actual RAM data-port wires (muxed source: dBus decoder or the load port).
	uwire logic        rd_awvalid = core_rst_hold ? ldr_awvalid : ram_awvalid;
	uwire logic [31:0] rd_awaddr  = core_rst_hold ? ldr_awaddr  : dbus_awaddr;
	uwire logic        rd_wvalid  = core_rst_hold ? ldr_wvalid  : ram_wvalid;
	uwire logic [31:0] rd_wdata   = core_rst_hold ? ldr_wdata   : dbus_wdata;
	uwire logic [3:0]  rd_wstrb   = core_rst_hold ? ldr_wstrb   : dbus_wstrb;
	uwire logic        rd_bready  = core_rst_hold ? ldr_bready  : ram_bready;
	uwire logic        rd_arvalid = core_rst_hold ? ldr_arvalid : ram_arvalid;
	uwire logic [31:0] rd_araddr  = core_rst_hold ? ldr_araddr  : dbus_araddr;
	uwire logic        rd_rready  = core_rst_hold ? ldr_rready  : ram_rready;

	logic rmo_awready, rmo_wready, rmo_bvalid, rmo_arready, rmo_rvalid;
	logic [1:0]  rmo_bresp, rmo_rresp;
	logic [31:0] rmo_rdata;

	ct_soc_ram #(.MEM_WORDS(MEM_WORDS), .INIT_FILE(MEM_INIT_FILE)) ram_inst (
		.clk        (clk),
		.rst        (rst),
		.i_arvalid  (ibus_arvalid),
		.i_arready  (ibus_arready),
		.i_araddr   (ibus_araddr),
		.i_rvalid   (ibus_rvalid),
		.i_rready   (ibus_rready),
		.i_rdata    (ibus_rdata),
		.i_rresp    (ibus_rresp),
		.d_awvalid  (rd_awvalid),
		.d_awready  (rmo_awready),
		.d_awaddr   (rd_awaddr),
		.d_wvalid   (rd_wvalid),
		.d_wready   (rmo_wready),
		.d_wdata    (rd_wdata),
		.d_wstrb    (rd_wstrb),
		.d_bvalid   (rmo_bvalid),
		.d_bready   (rd_bready),
		.d_bresp    (rmo_bresp),
		.d_arvalid  (rd_arvalid),
		.d_arready  (rmo_arready),
		.d_araddr   (rd_araddr),
		.d_rvalid   (rmo_rvalid),
		.d_rready   (rd_rready),
		.d_rdata    (rmo_rdata),
		.d_rresp    (rmo_rresp)
	);

	// Fan RAM responses back to whichever master owns the port this cycle.
	assign ram_awready = core_rst_hold ? 1'b0 : rmo_awready;
	assign ram_wready  = core_rst_hold ? 1'b0 : rmo_wready;
	assign ram_bvalid  = core_rst_hold ? 1'b0 : rmo_bvalid;
	assign ram_bresp   = rmo_bresp;
	assign ram_arready = core_rst_hold ? 1'b0 : rmo_arready;
	assign ram_rvalid  = core_rst_hold ? 1'b0 : rmo_rvalid;
	assign ram_rdata   = rmo_rdata;
	assign ram_rresp   = rmo_rresp;

	assign ldr_awready = core_rst_hold ? rmo_awready : 1'b0;
	assign ldr_wready  = core_rst_hold ? rmo_wready  : 1'b0;
	assign ldr_bvalid  = core_rst_hold ? rmo_bvalid  : 1'b0;
	assign ldr_bresp   = rmo_bresp;
	assign ldr_arready = core_rst_hold ? rmo_arready : 1'b0;
	assign ldr_rvalid  = core_rst_hold ? rmo_rvalid  : 1'b0;
	assign ldr_rdata   = rmo_rdata;
	assign ldr_rresp   = rmo_rresp;

	// ---------------------------------------------------------------------
	// dBus AXI4-Lite address decode (single outstanding per direction)
	//   segment = addr[31:28]: 0->RAM, 1->PERIPH, 2->ENC (default RAM)
	// ---------------------------------------------------------------------
	localparam logic [1:0] SEG_RAM    = 2'd0;
	localparam logic [1:0] SEG_PERIPH = 2'd1;
	localparam logic [1:0] SEG_ENC    = 2'd2;

	function automatic logic [1:0] seg_of(input logic [31:0] a);
		case (a[31:28])
			4'h1:    seg_of = SEG_PERIPH;
			4'h2:    seg_of = SEG_ENC;
			default: seg_of = SEG_RAM;
		endcase
	endfunction

	uwire logic [1:0] wr_seg = seg_of(dbus_awaddr);
	uwire logic [1:0] rd_seg = seg_of(dbus_araddr);

	// Outstanding-response tracking.
	logic       b_pending, r_pending;
	logic [1:0] b_seg, r_seg;

	always_ff @(posedge clk) begin
		if (rst) begin
			b_pending <= 1'b0;
			r_pending <= 1'b0;
			b_seg     <= SEG_RAM;
			r_seg     <= SEG_RAM;
		end
		else begin
			if (dbus_awvalid && dbus_awready && dbus_wvalid && dbus_wready) begin
				b_pending <= 1'b1;
				b_seg     <= wr_seg;
			end
			else if (dbus_bvalid && dbus_bready) begin
				b_pending <= 1'b0;
			end

			if (dbus_arvalid && dbus_arready) begin
				r_pending <= 1'b1;
				r_seg     <= rd_seg;
			end
			else if (dbus_rvalid && dbus_rready) begin
				r_pending <= 1'b0;
			end
		end
	end

	// Write-address / write-data fan-out (gated until previous B drained).
	always_comb begin
		ram_awvalid    = 1'b0; ram_wvalid    = 1'b0;
		periph_awvalid = 1'b0; periph_wvalid = 1'b0;
		enc_awvalid    = 1'b0; enc_wvalid    = 1'b0;
		if (!b_pending) begin
			unique case (wr_seg)
				SEG_PERIPH: begin periph_awvalid = dbus_awvalid; periph_wvalid = dbus_wvalid; end
				SEG_ENC:    begin enc_awvalid    = dbus_awvalid; enc_wvalid    = dbus_wvalid; end
				default:    begin ram_awvalid    = dbus_awvalid; ram_wvalid    = dbus_wvalid; end
			endcase
		end
	end

	assign dbus_awready = !b_pending &&
		((wr_seg == SEG_PERIPH) ? periph_awready :
		 (wr_seg == SEG_ENC)    ? enc_awready    : ram_awready);
	assign dbus_wready  = !b_pending &&
		((wr_seg == SEG_PERIPH) ? periph_wready  :
		 (wr_seg == SEG_ENC)    ? enc_wready     : ram_wready);

	// Write response mux (by latched b_seg).
	assign dbus_bvalid =
		(b_seg == SEG_PERIPH) ? periph_bvalid :
		(b_seg == SEG_ENC)    ? enc_bvalid    : ram_bvalid;
	assign dbus_bresp  =
		(b_seg == SEG_PERIPH) ? periph_bresp  :
		(b_seg == SEG_ENC)    ? enc_bresp     : ram_bresp;
	assign ram_bready    = (b_seg == SEG_RAM)    && dbus_bready;
	assign periph_bready = (b_seg == SEG_PERIPH) && dbus_bready;
	assign enc_bready    = (b_seg == SEG_ENC)    && dbus_bready;

	// Read-address fan-out (gated until previous R drained).
	always_comb begin
		ram_arvalid    = 1'b0;
		periph_arvalid = 1'b0;
		enc_arvalid    = 1'b0;
		if (!r_pending) begin
			unique case (rd_seg)
				SEG_PERIPH: periph_arvalid = dbus_arvalid;
				SEG_ENC:    enc_arvalid    = dbus_arvalid;
				default:    ram_arvalid    = dbus_arvalid;
			endcase
		end
	end

	assign dbus_arready = !r_pending &&
		((rd_seg == SEG_PERIPH) ? periph_arready :
		 (rd_seg == SEG_ENC)    ? enc_arready    : ram_arready);

	// Read response mux (by latched r_seg).
	assign dbus_rvalid =
		(r_seg == SEG_PERIPH) ? periph_rvalid :
		(r_seg == SEG_ENC)    ? enc_rvalid    : ram_rvalid;
	assign dbus_rdata  =
		(r_seg == SEG_PERIPH) ? periph_rdata  :
		(r_seg == SEG_ENC)    ? enc_rdata     : ram_rdata;
	assign dbus_rresp  =
		(r_seg == SEG_PERIPH) ? periph_rresp  :
		(r_seg == SEG_ENC)    ? enc_rresp     : ram_rresp;
	assign ram_rready    = (r_seg == SEG_RAM)    && dbus_rready;
	assign periph_rready = (r_seg == SEG_PERIPH) && dbus_rready;
	assign enc_rready    = (r_seg == SEG_ENC)    && dbus_rready;

endmodule

`default_nettype wire
