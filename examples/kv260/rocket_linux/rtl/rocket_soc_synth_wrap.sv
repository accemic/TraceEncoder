// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/*
 * rocket_soc_synth_wrap -- the Rocket branch of the KV260 app (L4 point 3):
 *
 *     RocketSystem (generat rocket64t1, third_party/rocket_ref, pinned)
 *       |- mem_axi4  -> rocket_mem_window -> mem_axi_* (board: PS S_AXI_HP,
 *       |               guest 0x8000_0000 -> PS DDR 0x6400_0000, guarded)
 *       |- mmio_axi4 -> rocket_con_8250   (8250 console @0x6001_0000, PS ring)
 *       `- trace_core_0_* -> rocket_tci_to_ctte_tip -> tip_if
 *            `- ct_encoder -> ATB out, CSR via Wishbone
 *
 * PORT CONTRACT analogous to cva6_soc_synth_wrap / mbv_soc_synth_wrap: same
 * ATB group (incl. `atb_te_raw`), same `cfg_wb_*` group, same
 * `core_trace_pc/valid` golden reference, same `core_rst_hold`. In addition
 * -- because the Rocket needs both and the CVA6 branch has them elsewhere:
 *   * the PS side of the console (`con_*`), inside cva6_linux_periph in the
 *     CVA6 design;
 *   * the window guard's diagnosis (`win_err_*`).
 *
 * WHAT THE ROCKET DOES NOT NEED (L2 inventory §1): no CLINT and no PLIC from
 * us -- both are IN THE GENERAT (CLINT @0x0200_0000, PLIC @0x0C00_0000,
 * 8 IRQs). Consequently also no `time_irq` port like the CVA6 branch;
 * instead `ext_irq` (8 bit) goes directly to the generat's PLIC input.
 *
 * CLOCK: single-clock like its siblings (all encoder domains on `clk`). The
 * generat's mtime tick comes from a FIXED /100 divider (L2 D-L2-3) --
 * `timebase-frequency` in the devicetree is thus mandatorily clk/100, not a
 * free choice. At 75 MHz that is 750 kHz, as carried by
 * sw/rocket_linux/rocket_kv260_rv64.dts and as OpenSBI reported in the L2 run
 * ("aclint-mtimer @ 750000Hz").
 *
 * RESET: `core_rst_hold` holds ONLY the core (and with it the generat).
 * Console, window guard, and encoder hang off `rst` -- otherwise the console
 * ring would be empty after every core restart, and exactly its last lines
 * are what one needs then. The encoder cannot block the boot: the TIP
 * interface has no backpressure into the core, and without CSR programming
 * capture is OFF after reset (CTTE default) -- so the core runs even if
 * nobody ever touches the encoder.
 *
 * TODO X2 (R1.1): `core_trace_pc` and the shim's address width are derived
 * from `tip_pkg::TIP_IADDRESS_WIDTH`, NOT hardcoded to 32. Once the encoder
 * tree moves to CT_XLEN=64, the width tracks automatically and the wrapper
 * needs no change. At the current 32-bit stand, the port is bit-identical to
 * its sibling wrappers'.
 */

module rocket_soc_synth_wrap #(
    // Window parameters (forwarded to rocket_mem_window; values from
    // examples/kv260/SPEC_board_memory_map.md v3 + L2 D-L2-1).
    parameter longint unsigned WIN_BASE  = 64'h8000_0000,
    parameter longint unsigned WIN_SIZE  = 64'h0C00_0000,   // 192 MiB
    parameter longint unsigned PS_BASE   = 64'h6400_0000,
    parameter longint unsigned UART_BASE = 64'h6001_0000,
    parameter int unsigned     CON_BYTES = 65536,
    // Per-instance encoder backend choice (default = build profile).
    bit EN_ETRACE = ct_pkg::CT_EN_ETRACE
) (
    input  uwire logic        clk,
    input  uwire logic        rst,
    input  uwire logic        core_rst_hold,   // 1 = core held (start only after DDR load)
    input  uwire logic [7:0]  ext_irq,         // -> the generat's PLIC (riscv,ndev = 8)

    // ATB (to the funnel)
    output logic [31:0]       atb_atdata,
    output logic [1:0]        atb_atbytes,
    output logic [6:0]        atb_atid,
    output logic              atb_atvalid,
    input  uwire logic        atb_atready,
    output logic              atb_afready,
    // ATB framing of this encoder (0 = Nexus MSEO, 1 = E-Trace raw bytes)
    output logic              atb_te_raw,
    input  uwire logic        atb_afvalid,
    input  uwire logic        atb_syncreq,

    // Encoder CSRs (Wishbone, via the ct_axil_to_wb bridge in the top)
    input  uwire logic        cfg_wb_en,
    input  uwire logic        cfg_wb_cyc,
    input  uwire logic        cfg_wb_stb,
    input  uwire logic        cfg_wb_we,
    input  uwire logic [31:0] cfg_wb_addr,
    input  uwire logic [31:0] cfg_wb_data_m2s,
    input  uwire logic [3:0]  cfg_wb_sel,
    output logic [31:0]       cfg_wb_data_s2m,
    output logic              cfg_wb_ack,
    output logic              cfg_wb_err,

    // Memory path: 64-bit AXI4 master (board: PS S_AXI_HP; sim: RAM model).
    // Addresses are ALREADY translated (PS view), the guard sits in front.
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

    // Console, PS side (in the CVA6 design inside cva6_linux_periph, here its
    // own block)
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

    // Window guard diagnosis (one devmem is enough)
    input  uwire logic        win_err_clear,
    output logic              win_err_sticky,
    output logic              win_err_was_write,
    output logic [31:0]       win_err_count,
    output logic [63:0]       win_err_addr,
    // Non-debug reset request from the generat (debug module); diagnosis only.
    output logic              core_ndreset,

    // Golden reference (tip side, iretire rule; pruned away on the board)
    output logic [tip_pkg::TIP_IADDRESS_WIDTH-1:0] core_trace_pc,
    output logic                                   core_trace_valid,
    // Addition compared to the sibling wrappers: the privilege level. For the
    // Rocket it is the ONLY visible sign of the OpenSBI hand-off to S-mode
    // (L2 stage L5) -- without it, a boot bank cannot prove the hand-off
    // happened without reaching into the hierarchy. Pruned away on the
    // board, like core_trace_pc/valid.
    output logic [2:0]                             core_trace_priv
);

    // The generat takes an ACTIVE-HIGH reset.
    uwire logic core_rst = rst | core_rst_hold;
    uwire logic rst_n    = ~rst;

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
    uwire logic        tci_iretire, tci_ilastsize;
    uwire logic [63:0] tci_iaddr, tci_tval, tci_cause, tci_time;
    uwire logic [3:0]  tci_itype, tci_priv;

    RocketSystem core (
        // All generat clock domains on clk (single-clock, like the sibling
        // branches).
        .io_aggregator_5_clock(clk), .io_aggregator_5_reset(core_rst),
        .io_aggregator_4_clock(clk), .io_aggregator_4_reset(core_rst),
        .io_aggregator_3_clock(clk), .io_aggregator_3_reset(core_rst),
        .io_aggregator_2_clock(clk), .io_aggregator_2_reset(core_rst),
        .io_aggregator_1_clock(clk), .io_aggregator_1_reset(core_rst),
        .io_aggregator_0_clock(clk), .io_aggregator_0_reset(core_rst),
        .resetctrl_hartIsInReset_0(core_rst),

        // Debug module: no JTAG at the top, DMI silent, dmactive looped back.
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

        // Frontend DMA bus silent (generat's slave input; the PS loads via
        // the PS DDR, not via this port).
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

        .trace_core_0_group_0_iretire(tci_iretire),
        .trace_core_0_group_0_iaddr(tci_iaddr),
        .trace_core_0_group_0_itype(tci_itype),
        .trace_core_0_group_0_ilastsize(tci_ilastsize),
        .trace_core_0_priv(tci_priv),
        .trace_core_0_tval(tci_tval),
        .trace_core_0_cause(tci_cause),
        .trace_core_0_time(tci_time)
    );

    // ------------------------------------------------------------------
    // Memory path: window translation + guard
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

    // ------------------------------------------------------------------
    // Console on the MMIO port (the building block missing from L2)
    // ------------------------------------------------------------------
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
    // Trace branch: shim -> TIP -> encoder
    // ------------------------------------------------------------------
    tip_if tip ();

    rocket_tci_to_ctte_tip shim (
        .clk_i(clk), .rst_ni(rst_n),
        .tci_iretire_i(tci_iretire),
        .tci_iaddr_i(tci_iaddr),
        .tci_itype_i(tci_itype),
        .tci_ilastsize_i(tci_ilastsize),
        // priv at the top is 4 bit with a constant 0 as the MSB (generat
        // :79630), the shim takes Cat(reg_debug, prv) -> [2:0] (R3.2a-D12).
        .tci_priv_i(tci_priv[2:0]),
        // Context: deliberately still '0 here, but NOT because the port is
        // missing anymore. Since M2 (2026-08-08) the rocket-chip patch
        // generates a trace_core_N_context[63:0] per tile carrying the satp
        // image, and M3 measured the edge: the new value is present starting
        // the cycle after `csrw satp`, nothing retires in between -- the
        // shim therefore needs no compensation. This board design, however,
        // still instantiates the ONE-HART generat Rocket64t1 WITHOUT
        // enableTraceCoreContext, whose top does not expose the port; only a
        // build against Rocket64t2 can connect it. The key would then be
        // satp.PPN = ctx[43:0] (D-R-8), only 22 bit wide in reality (M3-1) --
        // and it has NO reset value (M3-2), so a filter may only be armed
        // after the first satp write. Until then: '0.
        .tci_ctx_i(64'd0),
        .tci_tval_i(tci_tval),
        .tci_cause_i(tci_cause),
        .tci_time_i(tci_time),
        .tip(tip.master)
    );

    wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb ();
    axis_if #(.TDATA_WIDTH(96), .TID_WIDTH(8)) axis (.aclk(clk), .aresetn(rst_n));
    atb_if  atb ();

    assign wb.cyc          = cfg_wb_en & cfg_wb_cyc;
    assign wb.stb          = cfg_wb_en & cfg_wb_stb;
    assign wb.we           = cfg_wb_we;
    assign wb.addr         = cfg_wb_addr;
    assign wb.data_m2s     = cfg_wb_data_m2s;
    assign wb.sel          = cfg_wb_sel;
    assign cfg_wb_data_s2m = wb.data_s2m;
    assign cfg_wb_ack      = wb.ack;
    assign cfg_wb_err      = wb.err;

    ct_encoder #(.SPLIT_DATA_ACCESS(0), .EN_ETRACE(EN_ETRACE), .EN_NTRACE(!EN_ETRACE),
                .CORE_XLEN(64)) encoder (
        .tip_clk      (clk),
        .tip_rst      (rst),
        .tip          (tip.slave),
        .wb_clk       (clk),
        .wb_rst       (rst),
        .wb           (wb),
        .ct_cs_rst    (rst),
        .axis         (axis),
        .atb_atclk    (clk),
        .atb_atresetn (rst_n),
        .atb          (atb),
        .atb_te_raw   (atb_te_raw),
        .proc_clk     (clk),
        .proc_rst     (rst),
        .wall_clk     (clk),
        .wall_clk_rst (rst)
    );

    assign axis.tready = 1'b1;   // AXIS instrumentation unused here (like soc1)

    assign atb_atdata  = atb.atdata;
    assign atb_atbytes = atb.atbytes;
    assign atb_atid    = atb.atid;
    assign atb_atvalid = atb.atvalid;
    assign atb.atready = atb_atready;
    assign atb_afready = atb.afready;
    assign atb.afvalid = atb_afvalid;
    assign atb.syncreq = atb_syncreq;

    assign core_trace_pc    = tip.iaddr;
    assign core_trace_valid = |tip.iretire;
    assign core_trace_priv  = tci_priv[2:0];

endmodule

`default_nettype wire
