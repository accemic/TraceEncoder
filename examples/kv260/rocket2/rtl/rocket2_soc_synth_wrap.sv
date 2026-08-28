// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/*
 * rocket2_soc_synth_wrap -- the TWO-HART Rocket branch for the KV260 app (M4):
 *
 *     RocketSystem (generat rocket64t2, third_party/rocket_ref/rocket64t2)
 *       |- mem_axi4  -> rocket_mem_window -> mem_axi_*   (ONE port for BOTH
 *       |               harts: the generat bus is shared, TLBroadcast keeps
 *       |               the L1s coherent -- M2 gate (e))
 *       |- mmio_axi4 -> rocket_con_8250   (8250 console @0x6001_0000)
 *       |- trace_core_0_* -> shim0 -> tip0 -> ct_encoder enc0 --|
 *       |                                                       |-> ct_L1_funnel -> ATB
 *       `- trace_core_1_* -> shim1 -> tip1 -> ct_encoder enc1 --|
 *
 * Why TWO harts in ONE SoC and not two SoCs (M1 §1/§5): the question is "one
 * process across two cores". That requires SMP Linux, hence coherent caches
 * and ONE address space -- two separate cores do not answer that. The
 * generat's port comparison t1->t2 shows: apart from
 * `resetctrl_hartIsInReset_1` and the second `trace_core_*` set, the outside
 * is identical (one mem, one mmio, one interrupts port).
 *
 * FUNNEL instead of a second ring: ct_L1_funnel merges both ATB streams
 * message-atomically into ONE (template duo_soc_top/trio_soc_top). The
 * decoder splits them apart again via the Nexus SRC field, which EVERY
 * encoder instance carries via CSR (trTeControl.InhibitSrc = 0 +
 * trTeInstFeatures.SrcID/SrcBits) -- pure software, no RTL difference
 * between the two instances.
 *
 * WHICH FUNNEL (M4 finding F-1, load-bearing): there are TWO versions of
 * ct_L1_funnel.sv, and the wrong one merges silently broken.
 *   - `D:\shared\engineering\CTTE\rtl\ct_L1_funnel.sv` (upstream working
 *     tree, 438 lines): `LOGICAL_CHUNK_W = 32`, i.e. one 30+2 chunk per ATB
 *     beat.
 *   - `third_party/CTTE/rtl/ct_L1_funnel.sv` (the predecessor repository delta, 609
 *     lines, commit 071031a): `MDO_WIDTH` parametrized, fold-parse across
 *     ALL chunks of a beat, idle-beat drop, optional source tag.
 * The SAME upstream tree's encoder emits `NEXUS_MDO_WIDTH = 6`
 * (nexus_vendor_riscv_pkg.sv:136), i.e. FOUR byte chunks per 32-bit beat.
 * The upstream version only reads the bottom two MSEO bits of that and
 * treats three quarters of the framing information as payload -- it would
 * switch channels mid-message, and elaboration turns NOTHING red. This
 * design therefore deliberately binds the delta version with `MDO_WIDTH = 6`,
 * the same way duo_soc_top/trio_soc_top do. The file is carried as its own
 * source (not from the encoder mirror) so its origin stays visible in the
 * file-list log.
 *
 * CONTEXT (M2/M3): `trace_core_N_context[63:0]` carries the satp image
 * {MODE[63:60], ASID[59:44], PPN[43:0]}. The shim takes `satp.PPN` from it
 * (D-R-8); on this generat only 22 bit of that are live (M3-1). The width
 * clamp below is SELF-SECURING like its CVA6 twin (cva6_soc64_synth_wrap.sv):
 * it derives the width from `tip_pkg`, not from a number in the code. If
 * the encoder netlist is narrower than the live key, CTX_W stays 0 and the
 * context path is bit-for-bit the prior state -- RATHER NO CONTEXT than one
 * silently truncated that names the wrong process.
 *
 * WARNING, INITIAL CONTEXT (M3-2): `satp.PPN` has NO reset value. Between
 * reset and the first `csrw satp`, the port carries garbage (measured: hart
 * 0 started with 0x30f07d7b30f). An ownership FILTER must therefore only be
 * armed after the first satp write. This design does NOT filter (the slim
 * profile has CT_EN_FILTERS = 0) -- it only reports the context; the
 * warning is for the next build that filters.
 *
 * RESET/CLOCK/window: unchanged from the one-hart branch
 * (rocket_soc_synth_wrap), including the fixed /100 mtime divider (D-L2-3).
 */

module rocket2_soc_synth_wrap #(
    parameter longint unsigned WIN_BASE  = 64'h8000_0000,
    parameter longint unsigned WIN_SIZE  = 64'h0C00_0000,   // 192 MiB
    parameter longint unsigned PS_BASE   = 64'h6400_0000,
    parameter longint unsigned UART_BASE = 64'h6001_0000,
    parameter int unsigned     CON_BYTES = 65536,
    // Live width of satp.PPN on THIS generat (M3-1, measured 22).
    parameter int unsigned     SATP_PPN_LIVE_WIDTH = 22,
    bit EN_ETRACE = ct_pkg::CT_EN_ETRACE
) (
    input  uwire logic        clk,
    input  uwire logic        rst,
    input  uwire logic        core_rst_hold,
    input  uwire logic [7:0]  ext_irq,

    // MERGED ATB (funnel output) -- one group like the siblings
    output logic [31:0]       atb_atdata,
    output logic [1:0]        atb_atbytes,
    output logic [6:0]        atb_atid,
    output logic              atb_atvalid,
    input  uwire logic        atb_atready,
    output logic              atb_afready,
    output logic              atb_te_raw,
    input  uwire logic        atb_afvalid,
    input  uwire logic        atb_syncreq,

    // Funnel control (template duo_soc_top FUNNEL_CTRL; higher number =
    // preferred, equal = round-robin)
    input  uwire logic [1:0]  funnel_prio0,
    input  uwire logic [1:0]  funnel_prio1,
    input  uwire logic        funnel_flush_req,
    output logic              funnel_flush_done,

    // Encoder CSRs: TWO windows (one per instance)
    input  uwire logic        cfg0_wb_en,
    input  uwire logic        cfg0_wb_cyc,
    input  uwire logic        cfg0_wb_stb,
    input  uwire logic        cfg0_wb_we,
    input  uwire logic [31:0] cfg0_wb_addr,
    input  uwire logic [31:0] cfg0_wb_data_m2s,
    input  uwire logic [3:0]  cfg0_wb_sel,
    output logic [31:0]       cfg0_wb_data_s2m,
    output logic              cfg0_wb_ack,
    output logic              cfg0_wb_err,

    input  uwire logic        cfg1_wb_en,
    input  uwire logic        cfg1_wb_cyc,
    input  uwire logic        cfg1_wb_stb,
    input  uwire logic        cfg1_wb_we,
    input  uwire logic [31:0] cfg1_wb_addr,
    input  uwire logic [31:0] cfg1_wb_data_m2s,
    input  uwire logic [3:0]  cfg1_wb_sel,
    output logic [31:0]       cfg1_wb_data_s2m,
    output logic              cfg1_wb_ack,
    output logic              cfg1_wb_err,

    // Memory path (unchanged from the one-hart branch)
    output logic [3:0]        mem_axi_awid,
    output logic [63:0]       mem_axi_awaddr,
    output logic [7:0]        mem_axi_awlen,
    output logic [2:0]        mem_axi_awsize,
    output logic [1:0]        mem_axi_awburst,
    output logic              mem_axi_awlock,
    output logic [3:0]        mem_axi_awcache,
    output logic [2:0]        mem_axi_awprot,
    output logic [5:0]        mem_axi_awatop,
    output logic              mem_axi_awvalid,
    input  uwire logic        mem_axi_awready,
    output logic [63:0]       mem_axi_wdata,
    output logic [7:0]        mem_axi_wstrb,
    output logic              mem_axi_wlast,
    output logic              mem_axi_wvalid,
    input  uwire logic        mem_axi_wready,
    input  uwire logic [3:0]  mem_axi_bid,
    input  uwire logic [1:0]  mem_axi_bresp,
    input  uwire logic        mem_axi_bvalid,
    output logic              mem_axi_bready,
    output logic [3:0]        mem_axi_arid,
    output logic [63:0]       mem_axi_araddr,
    output logic [7:0]        mem_axi_arlen,
    output logic [2:0]        mem_axi_arsize,
    output logic [1:0]        mem_axi_arburst,
    output logic              mem_axi_arlock,
    output logic [3:0]        mem_axi_arcache,
    output logic [2:0]        mem_axi_arprot,
    output logic              mem_axi_arvalid,
    input  uwire logic        mem_axi_arready,
    input  uwire logic [3:0]  mem_axi_rid,
    input  uwire logic [63:0] mem_axi_rdata,
    input  uwire logic [1:0]  mem_axi_rresp,
    input  uwire logic        mem_axi_rlast,
    input  uwire logic        mem_axi_rvalid,
    output logic              mem_axi_rready,

    // Console, PS side
    input  uwire logic        con_clear,
    input  uwire logic [31:0] con_rd_word,
    output logic [31:0]       con_rd_data,
    output logic [31:0]       con_bytes,
    output logic [31:0]       con_drops,
    input  uwire logic [31:0] con_rd_bytes,
    input  uwire logic        con_rx_wr,
    input  uwire logic [7:0]  con_rx_data,
    output logic [15:0]       con_rx_used,
    output logic [31:0]       con_rx_drops,

    // Window guard
    input  uwire logic        win_err_clear,
    output logic              win_err_sticky,
    output logic              win_err_was_write,
    output logic [31:0]       win_err_count,
    output logic [63:0]       win_err_addr,
    output logic              core_ndreset,

    // Golden reference PER HART (this is the non-trace counter-check of the
    // sim gate: it comes from the TIP, not from the decoded stream)
    output logic [tip_pkg::TIP_IADDRESS_WIDTH-1:0] core0_trace_pc,
    output logic                                   core0_trace_valid,
    output logic [2:0]                             core0_trace_priv,
    output logic [tip_pkg::TIP_IADDRESS_WIDTH-1:0] core1_trace_pc,
    output logic                                   core1_trace_valid,
    output logic [2:0]                             core1_trace_priv
);

    uwire logic core_rst = rst | core_rst_hold;
    uwire logic rst_n    = ~rst;

    // ------------------------------------------------------------------
    // Context width clamp (self-securing, see header)
    // ------------------------------------------------------------------
    localparam int unsigned CTX_W =
        (tip_pkg::TIP_CONTEXT_WIDTH >= SATP_PPN_LIVE_WIDTH) ? tip_pkg::TIP_CONTEXT_WIDTH : 0;

    // ------------------------------------------------------------------
    // Generat wiring
    // ------------------------------------------------------------------
    uwire logic        m_awready, m_awvalid, m_wready, m_wvalid, m_wlast;
    uwire logic [3:0]  m_awid, m_arid, m_bid, m_rid;
    uwire logic [33:0] m_awaddr, m_araddr;
    uwire logic [7:0]  m_awlen, m_arlen, m_wstrb;
    uwire logic [2:0]  m_awsize, m_arsize;
    uwire logic [1:0]  m_awburst, m_arburst, m_bresp, m_rresp;
    uwire logic [63:0] m_wdata, m_rdata;
    uwire logic        m_bvalid, m_bready, m_arready, m_arvalid, m_rlast, m_rvalid, m_rready;

    uwire logic        io_awready, io_awvalid, io_wready, io_wvalid, io_wlast;
    uwire logic [3:0]  io_awid, io_arid, io_bid, io_rid;
    uwire logic [30:0] io_awaddr, io_araddr;
    uwire logic [7:0]  io_awlen, io_arlen, io_wstrb;
    uwire logic [2:0]  io_awsize, io_arsize;
    uwire logic [1:0]  io_awburst, io_arburst, io_bresp, io_rresp;
    uwire logic [63:0] io_wdata, io_rdata;
    uwire logic        io_bvalid, io_bready, io_arready, io_arvalid, io_rlast, io_rvalid, io_rready;

    uwire logic        dmactive;
    uwire logic        tci0_iretire, tci0_ilastsize, tci1_iretire, tci1_ilastsize;
    uwire logic [63:0] tci0_iaddr, tci0_tval, tci0_cause, tci0_time, tci0_ctx;
    uwire logic [63:0] tci1_iaddr, tci1_tval, tci1_cause, tci1_time, tci1_ctx;
    uwire logic [3:0]  tci0_itype, tci0_priv, tci1_itype, tci1_priv;

    RocketSystem core (
        .io_aggregator_5_clock(clk), .io_aggregator_5_reset(core_rst),
        .io_aggregator_4_clock(clk), .io_aggregator_4_reset(core_rst),
        .io_aggregator_3_clock(clk), .io_aggregator_3_reset(core_rst),
        .io_aggregator_2_clock(clk), .io_aggregator_2_reset(core_rst),
        .io_aggregator_1_clock(clk), .io_aggregator_1_reset(core_rst),
        .io_aggregator_0_clock(clk), .io_aggregator_0_reset(core_rst),
        // TWO harts (the only reset difference to the one-hart generat)
        .resetctrl_hartIsInReset_0(core_rst),
        .resetctrl_hartIsInReset_1(core_rst),

        .debug_clock(clk), .debug_reset(core_rst),
        .debug_clockeddmi_dmi_req_valid(1'b0),
        .debug_clockeddmi_dmi_req_bits_addr(7'b0),
        .debug_clockeddmi_dmi_req_bits_data(32'b0),
        .debug_clockeddmi_dmi_req_bits_op(2'b0),
        .debug_clockeddmi_dmi_resp_ready(1'b1),
        .debug_clockeddmi_dmiClock(clk), .debug_clockeddmi_dmiReset(core_rst),
        .debug_ndreset(core_ndreset),
        .debug_dmactive(dmactive), .debug_dmactiveAck(dmactive),

        .mem_axi4_0_aw_ready(m_awready), .mem_axi4_0_aw_valid(m_awvalid),
        .mem_axi4_0_aw_bits_id(m_awid), .mem_axi4_0_aw_bits_addr(m_awaddr),
        .mem_axi4_0_aw_bits_len(m_awlen), .mem_axi4_0_aw_bits_size(m_awsize),
        .mem_axi4_0_aw_bits_burst(m_awburst),
        .mem_axi4_0_w_ready(m_wready), .mem_axi4_0_w_valid(m_wvalid),
        .mem_axi4_0_w_bits_data(m_wdata), .mem_axi4_0_w_bits_strb(m_wstrb),
        .mem_axi4_0_w_bits_last(m_wlast),
        .mem_axi4_0_b_ready(m_bready), .mem_axi4_0_b_valid(m_bvalid),
        .mem_axi4_0_b_bits_id(m_bid), .mem_axi4_0_b_bits_resp(m_bresp),
        .mem_axi4_0_ar_ready(m_arready), .mem_axi4_0_ar_valid(m_arvalid),
        .mem_axi4_0_ar_bits_id(m_arid), .mem_axi4_0_ar_bits_addr(m_araddr),
        .mem_axi4_0_ar_bits_len(m_arlen), .mem_axi4_0_ar_bits_size(m_arsize),
        .mem_axi4_0_ar_bits_burst(m_arburst),
        .mem_axi4_0_r_ready(m_rready), .mem_axi4_0_r_valid(m_rvalid),
        .mem_axi4_0_r_bits_id(m_rid), .mem_axi4_0_r_bits_data(m_rdata),
        .mem_axi4_0_r_bits_resp(m_rresp), .mem_axi4_0_r_bits_last(m_rlast),

        .mmio_axi4_0_aw_ready(io_awready), .mmio_axi4_0_aw_valid(io_awvalid),
        .mmio_axi4_0_aw_bits_id(io_awid), .mmio_axi4_0_aw_bits_addr(io_awaddr),
        .mmio_axi4_0_aw_bits_len(io_awlen), .mmio_axi4_0_aw_bits_size(io_awsize),
        .mmio_axi4_0_aw_bits_burst(io_awburst),
        .mmio_axi4_0_w_ready(io_wready), .mmio_axi4_0_w_valid(io_wvalid),
        .mmio_axi4_0_w_bits_data(io_wdata), .mmio_axi4_0_w_bits_strb(io_wstrb),
        .mmio_axi4_0_w_bits_last(io_wlast),
        .mmio_axi4_0_b_ready(io_bready), .mmio_axi4_0_b_valid(io_bvalid),
        .mmio_axi4_0_b_bits_id(io_bid), .mmio_axi4_0_b_bits_resp(io_bresp),
        .mmio_axi4_0_ar_ready(io_arready), .mmio_axi4_0_ar_valid(io_arvalid),
        .mmio_axi4_0_ar_bits_id(io_arid), .mmio_axi4_0_ar_bits_addr(io_araddr),
        .mmio_axi4_0_ar_bits_len(io_arlen), .mmio_axi4_0_ar_bits_size(io_arsize),
        .mmio_axi4_0_ar_bits_burst(io_arburst),
        .mmio_axi4_0_r_ready(io_rready), .mmio_axi4_0_r_valid(io_rvalid),
        .mmio_axi4_0_r_bits_id(io_rid), .mmio_axi4_0_r_bits_data(io_rdata),
        .mmio_axi4_0_r_bits_resp(io_rresp), .mmio_axi4_0_r_bits_last(io_rlast),

        .l2_frontend_bus_axi4_0_aw_valid(1'b0),
        .l2_frontend_bus_axi4_0_aw_bits_id(8'b0),
        .l2_frontend_bus_axi4_0_aw_bits_addr(34'b0),
        .l2_frontend_bus_axi4_0_aw_bits_len(8'b0),
        .l2_frontend_bus_axi4_0_aw_bits_size(3'b0),
        .l2_frontend_bus_axi4_0_aw_bits_burst(2'b01),
        .l2_frontend_bus_axi4_0_aw_bits_lock(1'b0),
        .l2_frontend_bus_axi4_0_aw_bits_cache(4'b0),
        .l2_frontend_bus_axi4_0_aw_bits_prot(3'b0),
        .l2_frontend_bus_axi4_0_aw_bits_qos(4'b0),
        .l2_frontend_bus_axi4_0_w_valid(1'b0),
        .l2_frontend_bus_axi4_0_w_bits_data(64'b0),
        .l2_frontend_bus_axi4_0_w_bits_strb(8'b0),
        .l2_frontend_bus_axi4_0_w_bits_last(1'b0),
        .l2_frontend_bus_axi4_0_b_ready(1'b1),
        .l2_frontend_bus_axi4_0_ar_valid(1'b0),
        .l2_frontend_bus_axi4_0_ar_bits_id(8'b0),
        .l2_frontend_bus_axi4_0_ar_bits_addr(34'b0),
        .l2_frontend_bus_axi4_0_ar_bits_len(8'b0),
        .l2_frontend_bus_axi4_0_ar_bits_size(3'b0),
        .l2_frontend_bus_axi4_0_ar_bits_burst(2'b01),
        .l2_frontend_bus_axi4_0_ar_bits_lock(1'b0),
        .l2_frontend_bus_axi4_0_ar_bits_cache(4'b0),
        .l2_frontend_bus_axi4_0_ar_bits_prot(3'b0),
        .l2_frontend_bus_axi4_0_ar_bits_qos(4'b0),
        .l2_frontend_bus_axi4_0_r_ready(1'b1),

        .interrupts(ext_irq),

        .trace_core_0_group_0_iretire(tci0_iretire),
        .trace_core_0_group_0_iaddr(tci0_iaddr),
        .trace_core_0_group_0_itype(tci0_itype),
        .trace_core_0_group_0_ilastsize(tci0_ilastsize),
        .trace_core_0_priv(tci0_priv),
        .trace_core_0_tval(tci0_tval),
        .trace_core_0_cause(tci0_cause),
        .trace_core_0_time(tci0_time),
        .trace_core_0_context(tci0_ctx),

        .trace_core_1_group_0_iretire(tci1_iretire),
        .trace_core_1_group_0_iaddr(tci1_iaddr),
        .trace_core_1_group_0_itype(tci1_itype),
        .trace_core_1_group_0_ilastsize(tci1_ilastsize),
        .trace_core_1_priv(tci1_priv),
        .trace_core_1_tval(tci1_tval),
        .trace_core_1_cause(tci1_cause),
        .trace_core_1_time(tci1_time),
        .trace_core_1_context(tci1_ctx)
    );

    // ------------------------------------------------------------------
    // Memory path + console (unchanged from the one-hart branch)
    // ------------------------------------------------------------------
    rocket_mem_window #(
        .WIN_BASE(WIN_BASE), .WIN_SIZE(WIN_SIZE), .PS_BASE(PS_BASE),
        .S_ADDR_WIDTH(34), .M_ADDR_WIDTH(64), .ID_WIDTH(4)
    ) memwin (
        .clk_i(clk), .rst_ni(rst_n),
        .err_clear(win_err_clear), .err_sticky(win_err_sticky),
        .err_was_write(win_err_was_write), .err_count(win_err_count),
        .err_addr(win_err_addr),
        .s_awid(m_awid), .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awsize(m_awsize),
        .s_awburst(m_awburst), .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast), .s_wvalid(m_wvalid),
        .s_wready(m_wready),
        .s_bid(m_bid), .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready),
        .s_arid(m_arid), .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arsize(m_arsize),
        .s_arburst(m_arburst), .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rid(m_rid), .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast),
        .s_rvalid(m_rvalid), .s_rready(m_rready),
        .m_awid(mem_axi_awid), .m_awaddr(mem_axi_awaddr), .m_awlen(mem_axi_awlen),
        .m_awsize(mem_axi_awsize), .m_awburst(mem_axi_awburst), .m_awlock(mem_axi_awlock),
        .m_awcache(mem_axi_awcache), .m_awprot(mem_axi_awprot), .m_awatop(mem_axi_awatop),
        .m_awvalid(mem_axi_awvalid), .m_awready(mem_axi_awready),
        .m_wdata(mem_axi_wdata), .m_wstrb(mem_axi_wstrb), .m_wlast(mem_axi_wlast),
        .m_wvalid(mem_axi_wvalid), .m_wready(mem_axi_wready),
        .m_bid(mem_axi_bid), .m_bresp(mem_axi_bresp), .m_bvalid(mem_axi_bvalid),
        .m_bready(mem_axi_bready),
        .m_arid(mem_axi_arid), .m_araddr(mem_axi_araddr), .m_arlen(mem_axi_arlen),
        .m_arsize(mem_axi_arsize), .m_arburst(mem_axi_arburst), .m_arlock(mem_axi_arlock),
        .m_arcache(mem_axi_arcache), .m_arprot(mem_axi_arprot),
        .m_arvalid(mem_axi_arvalid), .m_arready(mem_axi_arready),
        .m_rid(mem_axi_rid), .m_rdata(mem_axi_rdata), .m_rresp(mem_axi_rresp),
        .m_rlast(mem_axi_rlast), .m_rvalid(mem_axi_rvalid), .m_rready(mem_axi_rready)
    );

    rocket_con_8250 #(
        .UART_BASE(UART_BASE), .ADDR_WIDTH(31), .ID_WIDTH(4), .CON_BYTES(CON_BYTES)
    ) con (
        .clk_i(clk), .rst_ni(rst_n),
        .awid(io_awid), .awaddr(io_awaddr), .awlen(io_awlen), .awsize(io_awsize),
        .awburst(io_awburst), .awvalid(io_awvalid), .awready(io_awready),
        .wdata(io_wdata), .wstrb(io_wstrb), .wlast(io_wlast), .wvalid(io_wvalid),
        .wready(io_wready),
        .bid(io_bid), .bresp(io_bresp), .bvalid(io_bvalid), .bready(io_bready),
        .arid(io_arid), .araddr(io_araddr), .arlen(io_arlen), .arsize(io_arsize),
        .arburst(io_arburst), .arvalid(io_arvalid), .arready(io_arready),
        .rid(io_rid), .rdata(io_rdata), .rresp(io_rresp), .rlast(io_rlast),
        .rvalid(io_rvalid), .rready(io_rready),
        .con_clear(con_clear), .con_rd_word(con_rd_word), .con_rd_data(con_rd_data),
        .con_bytes(con_bytes), .con_drops(con_drops), .con_rd_bytes(con_rd_bytes),
        .con_rx_wr(con_rx_wr), .con_rx_data(con_rx_data),
        .con_rx_used(con_rx_used), .con_rx_drops(con_rx_drops)
    );

    // ------------------------------------------------------------------
    // Trace branches: per hart, shim -> TIP -> encoder
    // ------------------------------------------------------------------
    tip_if tip0 ();
    tip_if tip1 ();

    rocket_tci_to_ctte_tip #(
        .TCI_CONTEXT_WIDTH   (CTX_W),
        .SATP_PPN_LIVE_WIDTH (SATP_PPN_LIVE_WIDTH)
    ) shim0 (
        .clk_i(clk), .rst_ni(rst_n),
        .tci_iretire_i(tci0_iretire),
        .tci_iaddr_i(tci0_iaddr),
        .tci_itype_i(tci0_itype),
        .tci_ilastsize_i(tci0_ilastsize),
        .tci_priv_i(tci0_priv[2:0]),
        .tci_ctx_i(tci0_ctx),
        .tci_tval_i(tci0_tval),
        .tci_cause_i(tci0_cause),
        .tci_time_i(tci0_time),
        .tip(tip0.master)
    );

    rocket_tci_to_ctte_tip #(
        .TCI_CONTEXT_WIDTH   (CTX_W),
        .SATP_PPN_LIVE_WIDTH (SATP_PPN_LIVE_WIDTH)
    ) shim1 (
        .clk_i(clk), .rst_ni(rst_n),
        .tci_iretire_i(tci1_iretire),
        .tci_iaddr_i(tci1_iaddr),
        .tci_itype_i(tci1_itype),
        .tci_ilastsize_i(tci1_ilastsize),
        .tci_priv_i(tci1_priv[2:0]),
        .tci_ctx_i(tci1_ctx),
        .tci_tval_i(tci1_tval),
        .tci_cause_i(tci1_cause),
        .tci_time_i(tci1_time),
        .tip(tip1.master)
    );

    wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb0 ();
    wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb1 ();
    axis_if #(.TDATA_WIDTH(96), .TID_WIDTH(8)) axis0 (.aclk(clk), .aresetn(rst_n));
    axis_if #(.TDATA_WIDTH(96), .TID_WIDTH(8)) axis1 (.aclk(clk), .aresetn(rst_n));
    atb_if  atb0 ();
    atb_if  atb1 ();

    assign wb0.cyc          = cfg0_wb_en & cfg0_wb_cyc;
    assign wb0.stb          = cfg0_wb_en & cfg0_wb_stb;
    assign wb0.we           = cfg0_wb_we;
    assign wb0.addr         = cfg0_wb_addr;
    assign wb0.data_m2s     = cfg0_wb_data_m2s;
    assign wb0.sel          = cfg0_wb_sel;
    assign cfg0_wb_data_s2m = wb0.data_s2m;
    assign cfg0_wb_ack      = wb0.ack;
    assign cfg0_wb_err      = wb0.err;

    assign wb1.cyc          = cfg1_wb_en & cfg1_wb_cyc;
    assign wb1.stb          = cfg1_wb_en & cfg1_wb_stb;
    assign wb1.we           = cfg1_wb_we;
    assign wb1.addr         = cfg1_wb_addr;
    assign wb1.data_m2s     = cfg1_wb_data_m2s;
    assign wb1.sel          = cfg1_wb_sel;
    assign cfg1_wb_data_s2m = wb1.data_s2m;
    assign cfg1_wb_ack      = wb1.ack;
    assign cfg1_wb_err      = wb1.err;

    uwire logic enc0_te_raw, enc1_te_raw;

    ct_encoder #(.SPLIT_DATA_ACCESS(0), .EN_ETRACE(EN_ETRACE), .EN_NTRACE(!EN_ETRACE),
                .CORE_XLEN(64)) enc0 (
        .tip_clk(clk), .tip_rst(rst), .tip(tip0.slave),
        .wb_clk(clk),  .wb_rst(rst),  .wb(wb0),
        .ct_cs_rst(rst),
        .axis(axis0),
        .atb_atclk(clk), .atb_atresetn(rst_n), .atb(atb0), .atb_te_raw(enc0_te_raw),
        .proc_clk(clk), .proc_rst(rst), .wall_clk(clk), .wall_clk_rst(rst)
    );

    ct_encoder #(.SPLIT_DATA_ACCESS(0), .EN_ETRACE(EN_ETRACE), .EN_NTRACE(!EN_ETRACE),
                .CORE_XLEN(64)) enc1 (
        .tip_clk(clk), .tip_rst(rst), .tip(tip1.slave),
        .wb_clk(clk),  .wb_rst(rst),  .wb(wb1),
        .ct_cs_rst(rst),
        .axis(axis1),
        .atb_atclk(clk), .atb_atresetn(rst_n), .atb(atb1), .atb_te_raw(enc1_te_raw),
        .proc_clk(clk), .proc_rst(rst), .wall_clk(clk), .wall_clk_rst(rst)
    );

    assign axis0.tready = 1'b1;
    assign axis1.tready = 1'b1;

    // ------------------------------------------------------------------
    // Funnel: 2x ATB -> 1x ATB (message-atomic, MSEO-based)
    // ------------------------------------------------------------------
    // Elaboration clamp: the funnel recognizes packet boundaries
    // EXCLUSIVELY via the Nexus MSEO bits (ct_L1_funnel header). An E-Trace
    // backend delivers raw bytes without MSEO -- the funnel would switch
    // mid-packet and make BOTH streams unusable, without anything turning
    // red. So abort here instead of silently merging wrong.
    if (EN_ETRACE) begin : g_etrace_guard
        initial $fatal(1, "rocket2_soc_synth_wrap: EN_ETRACE=1 is incompatible with ct_L1_funnel (the funnel parses MSEO; E-Trace delivers raw bytes)");
    end

    atb_if atb_in [2] ();
    atb_if atb_mrg ();

    assign atb_in[0].atdata  = atb0.atdata;
    assign atb_in[0].atbytes = atb0.atbytes;
    assign atb_in[0].atid    = atb0.atid;
    assign atb_in[0].atvalid = atb0.atvalid;
    assign atb_in[0].afready = atb0.afready;
    assign atb0.atready = atb_in[0].atready;
    assign atb0.afvalid = atb_in[0].afvalid;
    assign atb0.syncreq = atb_in[0].syncreq;

    assign atb_in[1].atdata  = atb1.atdata;
    assign atb_in[1].atbytes = atb1.atbytes;
    assign atb_in[1].atid    = atb1.atid;
    assign atb_in[1].atvalid = atb1.atvalid;
    assign atb_in[1].afready = atb1.afready;
    assign atb1.atready = atb_in[1].atready;
    assign atb1.afvalid = atb_in[1].afvalid;
    assign atb1.syncreq = atb_in[1].syncreq;

    uwire logic [1:0] funnel_prio [2];
    assign funnel_prio[0] = funnel_prio0;
    assign funnel_prio[1] = funnel_prio1;
    uwire logic funnel_participate [2];
    assign funnel_participate[0] = 1'b1;
    assign funnel_participate[1] = 1'b1;
    uwire logic funnel_chan_flush_req [2];
    assign funnel_chan_flush_req[0] = 1'b0;
    assign funnel_chan_flush_req[1] = 1'b0;
    uwire logic funnel_chan_flush_done [2];
    // EN_TE_RAW = 0 -> the te_raw inputs are constant-optimized away, the
    // netlist matches the historical funnel's (header of the delta version).
    uwire logic funnel_chan_te_raw [2];
    assign funnel_chan_te_raw[0] = 1'b0;
    assign funnel_chan_te_raw[1] = 1'b0;

    ct_L1_funnel #(
        .N_STREAMS  (2),
        .MAX_PRIO   (3),
        .MSEO_WIDTH (2),
        // 6 = four byte chunks per 32-bit beat = this encoder's real wire
        // format (NEXUS_MDO_WIDTH, see header F-1). NOT the default 30.
        .MDO_WIDTH  (6),
        .EN_TE_RAW  (0)
    ) funnel (
        .atclk    (clk),
        .atresetn (rst_n),
        .chan_prio              (funnel_prio),
        .chan_flush_participate (funnel_participate),
        .chan_flush_req         (funnel_chan_flush_req),
        .chan_te_raw            (funnel_chan_te_raw),
        .te_tag_always          (1'b0),
        .te_tag_resync          (1'b0),
        .global_flush_req       (funnel_flush_req),
        .chan_flush_done        (funnel_chan_flush_done),
        .global_flush_done      (funnel_flush_done),
        .atb_in  (atb_in),
        .atb_out (atb_mrg)
    );

    assign atb_atdata   = atb_mrg.atdata;
    assign atb_atbytes  = atb_mrg.atbytes;
    assign atb_atid     = atb_mrg.atid;
    assign atb_atvalid  = atb_mrg.atvalid;
    assign atb_mrg.atready = atb_atready;
    assign atb_afready  = atb_mrg.afready;
    assign atb_mrg.afvalid = atb_afvalid;
    assign atb_mrg.syncreq = atb_syncreq;

    // Both instances carry the same profile, hence the same framing.
    assign atb_te_raw = enc0_te_raw;

`ifndef SYNTHESIS
    // The funnel must never mix two different framings. An assertion, not a
    // comment, because the case would be real with separate profiles.
    a_same_framing: assert property (@(posedge clk) disable iff (!rst_n)
        enc0_te_raw == enc1_te_raw)
        else $error("rocket2_soc_synth_wrap: encoders report different ATB framing (%0b vs %0b)", enc0_te_raw, enc1_te_raw);
`endif

    assign core0_trace_pc    = tip0.iaddr;
    assign core0_trace_valid = |tip0.iretire;
    assign core0_trace_priv  = tci0_priv[2:0];
    assign core1_trace_pc    = tip1.iaddr;
    assign core1_trace_valid = |tip1.iretire;
    assign core1_trace_priv  = tci1_priv[2:0];

endmodule

`default_nettype wire
