// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Top of the KV260 app: PS-facing AXI4-Lite control port around the example SoC.
 *
 * @details
 *   Presents a single AXI4-Lite slave (driven by the Zynq PS via M_AXI_HPM0_FPD)
 *   so the whole SoC is controlled from Linux with `devmem`. The slave aperture
 *   (base 0xA000_0000 in the block design) decodes into five regions:
 *
 *     0x00_0000  CTRL   control/status registers (this module + ct_trace_sinks)
 *                  0x00 CONTROL (rw): b0 core_run  b1 trace_clear  b2 trace_flush  b3 irq_gen_en
 *                  0x04 STATUS  (ro): b0 trace_wrapped (ring wrapped, oldest
 *                       beats overwritten; was: overflow)  b1 axis_overflow
 *                  0x08 TRACE_BEATS (ro, monotonic)  0x0C TRACE_BYTES (ro, monotonic)
 *                  0x10 AXIS_BEATS (ro)  0x14 TRACE_BUFSZ (ro, ring capacity bytes)
 *                  -- sink window, decoded inside ct_trace_sinks (identical in
 *                     every board design; this top only forwards the access) --
 *                  0x18 SINK_CTRL (rw): b0 ddr_en  b1 ddr_clear (pulse)
 *                       b2 ddr_circ (1=circular, 0=one shot)  b3 uram_oneshot
 *                       (1=one shot, 0=circular)  b4 pib_en  b5 pib_clear (pulse)
 *                       b6 pib_calib  b[10:8] pib_div  b[13:12] pib_pattern.
 *                       Reset 0 = DDR+PIB off, ring circular = pre-sink behavior
 *                  0x1C DDR_BASE  (ro): 0x5000_0000, read-only in hardware (U9-1)
 *                  0x20 DDR_SIZE  (ro): 0x1000_0000 = 256 MiB, read-only (U9-1)
 *                  0x24 DDR_WPTR  (ro): bytes written TOTAL (monotonic)
 *                  0x28 SINK_STAT (ro): b0 ddr_full  b1 ddr_axi_err  b2 ddr_wrapped
 *                       b3 uram_stopped  b4 ddr_cfg_rej
 *                  0x2C DDR_DROPS (ro): dropped beats (saturating)
 *                  0x30 PIB_DROPS (ro): dropped beats (saturating)
 *                  0x38 DDR_BEATS (ro): beats offered to the DDR sink while ddr_en
 *                  -- mbv-only registers (robustness campaign). 0x34 is ATB_STALLS
 *                     here, NOT the FUNNEL_CTRL of the multi-encoder tops: mbv has
 *                     ONE encoder and no funnel --
 *                  0x34 ATB_STALLS (ro): cycles with atvalid && !atready (saturating)
 *                  0x3C IRQ_DIV (rw): external-IRQ generator divider (reset 4096)
 *                  0x40 ATB_BP (rw): b[1:0] mode (0 off, 1 duty, 2 random, 3 burst),
 *                       b[15:8] param, b[31:16] LFSR seed -- ATB backpressure generator
 *                       for the robustness campaign (reset 0 = always ready = historic).
 *                       MOVED from 0x38, which the sink window claims for DDR_BEATS;
 *                       0x40 is the offset examples/kv260/common/rdl/README.md
 *                       names for this register. The board campaign's
 *                       ATB_BP_OFFSET must follow.
 *     0x01_0000  ENC    CTTE encoder CSRs (via ct_axil_to_wb -> Wishbone)
 *     0x10_0000  RAM    program/data RAM (write the program while core_run=0)
 *     0x20_0000  TRACE  captured ATB ring buffer (1 MiB URAM; ring order via
 *                       TRACE_BEATS % (TRACE_BUFSZ/4), decode on host)
 *     0x30_0000  AXIS   captured AXIS instrumentation stream (ct_soc_axis_buf,
 *                       AXIS_BEATS words; decoded on the host)
 *
 *   The PS holds the core in reset (core_run=0) while it loads the program and
 *   configures the encoder, then starts it (core_run=1). The ATB output is
 *   captured into an on-chip BRAM readable through the TRACE region.
 *
 *   Trace sinks (folded into the shared three-sink subsystem ct_trace_sinks,
 *   the same one duo/trio/tgc5b2_axis_wp use; all three run in parallel, the
 *   ring is the primary always-ready sink, DDR4/PIB are additive observers with
 *   their own FIFO + drop counter and NEVER back-pressure the trace path):
 *     Mem(URAM)  1 MiB ring @TRACE (as before)
 *     Mem(DDR4)  ct_soc_ddr_sink -> AXI4 master m_axi_* (PS S_AXI_HP0_FPD)
 *     PIB        ct_soc_pib -> pib_clk/pib_data[3:0] (4-bit DDR, KR260-adapter-
 *                compatible pinout -- see fpga/mbv_pib_pmod.xdc)
 *   Reset-inert: SINK_CTRL resets to 0, so DDR and PIB are off and the ring
 *   captures circular exactly as the pre-sink mbv build did.
 *
 *   The AXI4-Lite slave front-end uses the canonical registered-handshake
 *   pattern (awready/wready pulse together with an aw_en gate; bvalid/rvalid
 *   registered), which is robust with the PS SmartConnect. A small backend FSM
 *   services the decoded region — immediate for CTRL, forwarded to the encoder
 *   (Wishbone) / RAM sub-slaves for ENC/RAM, one BRAM-latency cycle for TRACE.
 */

// Adaptation of the tgc5b `ct_soc_top` (examples/kv260/common/tgc5b/ct_soc_top.sv):
// identical register map / devmem semantics, only the inner SoC is the
// MBV CTTE stack (`mbv_soc_synth_wrap` instead of `ct_soc_synth_wrap`)
// and the RAM size follows the MBV block design (128 KiB).
//
// Migrated 2026-08-17 from an internal predecessor repository. The
// `ct_soc_trace_buf` instance was renamed to
// `ct_soc_trace_ring` on migration (decision A-04, same notes) --
// examples/kv260/common/tgc5b/rtl/ct_soc_trace_buf.sv is an unrelated, differently
// sized design that kept the old name. Since D2 (2026-08-18) that ring is no
// longer instantiated here directly: it sits inside the shared three-sink
// subsystem `ct_trace_sinks`, which this top now instantiates like every other
// board example -- mbv was the last single-sink design.
module mbv_soc_top #(
	int unsigned MEM_WORDS   = 32768,    // 128 KiB program/data RAM (G0-BD)
	int unsigned TRACE_DEPTH = 262144    // trace ring capacity in beats; 1 MiB URAM
) (
	input  uwire logic        clk,
	input  uwire logic        resetn,        // PS pl_resetn0, active-low

	// AXI4-Lite slave (from PS M_AXI_HPM0_FPD via SmartConnect)
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

	// DDR4 sink: AXI4 write-only master (to PS S_AXI_HP0_FPD)
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

	// PIB: parallel trace port (source-synchronous, DDR nibbles)
	output      logic         pib_clk,
	output      logic [3:0]   pib_data
);

	localparam logic [1:0] RESP_OKAY = 2'b00;

	uwire logic rst = ~resetn;

	// -- Control / status registers ----------------------------------------
	logic [31:0] control_reg;      // b0 core_run, b1 trace_clear, b2 trace_flush
	uwire logic  core_run    = control_reg[0];
	uwire logic  trace_clear = control_reg[1];
	uwire logic  trace_flush = control_reg[2];
	uwire logic  core_rst_hold = ~core_run;
	// CONTROL b3 = enable of an HW IRQ pulse generator (one clock-wide pulse
	// every 4,096 cycles ~= 55 us @75 MHz). Host-clocked single pulses would be
	// useless: the 16 KiB capture BRAM is full after ~100 us (first-fill), while
	// devmem pulses arrive no sooner than ~10 ms apart -- only a cycle-accurate
	// generator places IRQs deterministically inside the capture window (sim
	// and board identical).
	// The divider is programmable (IRQ_DIV @0x3C, reset 4096 = legacy ~55 us
	// @75 MHz), so the IRQ rate is a sweep axis rather than a constant.
	// -- Sink-window wiring (0x18..0x30 + 0x38 live in ct_trace_sinks) ------
	logic        sinks_reg_wr;                 // strobe: CTRL-segment write (assigned below)
	logic [3:0]  sinks_wr_ix, sinks_rd_ix;     // word indices awaddr/araddr[5:2]
	logic [31:0] sinks_wr_data, sinks_rd_data;

	logic [31:0] irq_div_reg;
	logic [31:0] irq_cnt;
	logic        ext_irq;
	always_ff @(posedge clk) begin
		if (rst || !control_reg[3]) begin
			irq_cnt <= '0;
			ext_irq <= 1'b0;
		end
		else begin
			irq_cnt <= (irq_cnt + 1'b1 >= irq_div_reg) ? '0 : irq_cnt + 1'b1;
			ext_irq <= (irq_cnt == '0);
		end
	end

	// ======================================================================
	// ATB backpressure generator (ATB_BP @0x40) -- board-side, NOT in the encoder
	// ======================================================================
	// Why: the sink used to be ALWAYS `ready`. Overflow therefore only ever
	// arose source-side (a JI storm). A real target setup (trace port, funnel,
	// DDR sink) does throttle, though -- and that path is not covered by any
	// sim gate. The generator throttles `atb_atready` reproducibly without
	// touching the encoder core itself (AD-01).
	//   b[1:0]   mode: 0 = off (always ready)
	//                  1 = duty:   ready 1 out of (param+1) cycles
	//                  2 = random: ready when LFSR[7:0] >= param (param=0 -> always)
	//                  3 = burst:  (param+1)*16 cycles stall, then as many ready
	//   b[15:8]  param
	//   b[31:16] seed for mode 2 (0 -> default; reloaded on every write)
	logic [31:0] atb_bp_reg;
	logic [15:0] bp_lfsr;
	logic [15:0] bp_cnt;
	logic [31:0] bp_stalls;                       // ATB_STALLS @0x34 (ro, saturating)
	logic        bp_load;                         // one-cycle pulse after a write to ATB_BP
	uwire [1:0]  bp_mode  = atb_bp_reg[1:0];
	uwire [7:0]  bp_param = atb_bp_reg[15:8];
	uwire [15:0] bp_half  = {4'd0, bp_param, 4'd0} + 16'd16;   // (param+1)*16

	logic bp_ready;
	always_comb begin
		unique case (bp_mode)
			2'd1:    bp_ready = (bp_cnt == '0);
			2'd2:    bp_ready = (bp_lfsr[7:0] >= bp_param);
			2'd3:    bp_ready = (bp_cnt >= bp_half);
			default: bp_ready = 1'b1;
		endcase
	end

	uwire atb_ready_eff = bp_ready;

	always_ff @(posedge clk) begin
		if (rst) begin
			bp_lfsr <= 16'hACE1;
			bp_cnt  <= '0;
			bp_stalls <= '0;
		end
		else if (bp_load) begin
			bp_cnt    <= '0;
			bp_stalls <= '0;
			bp_lfsr   <= (atb_bp_reg[31:16] == 16'd0) ? 16'hACE1 : atb_bp_reg[31:16];
		end
		else begin
			// Galois LFSR (x^16+x^14+x^13+x^11+1) -- deterministically reproducible
			bp_lfsr <= {bp_lfsr[14:0],
			            bp_lfsr[15] ^ bp_lfsr[13] ^ bp_lfsr[12] ^ bp_lfsr[10]};
			unique case (bp_mode)
				2'd1:    bp_cnt <= (bp_cnt >= {8'd0, bp_param}) ? '0 : bp_cnt + 1'b1;
				2'd3:    bp_cnt <= (bp_cnt >= (bp_half + bp_half - 1)) ? '0 : bp_cnt + 1'b1;
				default: bp_cnt <= '0;
			endcase
			if (atb_atvalid && !atb_ready_eff && !(&bp_stalls))
				bp_stalls <= bp_stalls + 1'b1;
		end
	end

	// -- SoC + encoder CSR bridge + trace buffer ---------------------------
	logic [31:0] atb_atdata;
	logic [1:0]  atb_atbytes;
	logic [6:0]  atb_atid;
	logic        atb_atvalid;
	logic        atb_afready;
	logic [95:0] axis_tdata;
	logic [11:0] axis_tkeep;
	logic [7:0]  axis_tid;
	logic        axis_tlast;
	logic        axis_tvalid;
	logic [31:0] core_trace_pc;
	logic        core_trace_valid;

	// Encoder CSR bridge (AXI4-Lite region -> Wishbone) wires.
	logic        enc_awvalid, enc_awready, enc_wvalid, enc_wready, enc_bvalid, enc_bready;
	logic [1:0]  enc_bresp;
	logic        enc_arvalid, enc_arready, enc_rvalid, enc_rready;
	logic [31:0] enc_rdata;
	logic [1:0]  enc_rresp;
	logic [31:0] enc_addr, enc_wdata;
	logic [3:0]  enc_wstrb;

	// RAM-load region wires (-> ct_soc_synth_wrap ldr port).
	logic        ram_awvalid, ram_awready, ram_wvalid, ram_wready, ram_bvalid, ram_bready;
	logic [1:0]  ram_bresp;
	logic        ram_arvalid, ram_arready, ram_rvalid, ram_rready;
	logic [31:0] ram_rdata;
	logic [1:0]  ram_rresp;
	logic [31:0] ram_addr, ram_wdata;
	logic [3:0]  ram_wstrb;

	// Trace buffer.
	logic [31:0] trace_beats, trace_bytes, trace_rdata;
	logic        trace_overflow;
	logic [31:0] trace_rd_word;

	// AXIS instrumentation-capture buffer.
	logic [31:0] axis_beats, axis_rdata;
	logic        axis_overflow;
	logic [31:0] axis_rd_word;

	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) cfg();

	// AXI4-Lite -> Wishbone bridge for the encoder CSR region.
	ct_axil_to_wb enc_bridge (
		.clk (clk), .rst (rst),
		.s_awvalid (enc_awvalid), .s_awready (enc_awready), .s_awaddr (enc_addr),
		.s_wvalid  (enc_wvalid),  .s_wready  (enc_wready),  .s_wdata  (enc_wdata), .s_wstrb (enc_wstrb),
		.s_bvalid  (enc_bvalid),  .s_bready  (enc_bready),  .s_bresp  (enc_bresp),
		.s_arvalid (enc_arvalid), .s_arready (enc_arready), .s_araddr (enc_addr),
		.s_rvalid  (enc_rvalid),  .s_rready  (enc_rready),  .s_rdata  (enc_rdata), .s_rresp (enc_rresp),
		.wb (cfg.master)
	);

	mbv_soc_synth_wrap #(.MEM_WORDS(MEM_WORDS)) soc (
		.clk (clk), .rst (rst),
		.core_rst_hold (core_rst_hold),
		.ext_irq (ext_irq),
		.atb_atdata (atb_atdata), .atb_atbytes (atb_atbytes), .atb_atid (atb_atid),
		.atb_atvalid (atb_atvalid), .atb_atready (atb_ready_eff),
		.atb_afready (atb_afready), .atb_afvalid (trace_flush), .atb_syncreq (1'b0),
		.axis_tdata (axis_tdata), .axis_tkeep (axis_tkeep), .axis_tid (axis_tid),
		.axis_tlast (axis_tlast), .axis_tvalid (axis_tvalid), .axis_tready (1'b1),
		.cfg_wb_en (1'b1),
		.cfg_wb_cyc (cfg.cyc), .cfg_wb_stb (cfg.stb), .cfg_wb_we (cfg.we),
		.cfg_wb_addr (cfg.addr), .cfg_wb_data_m2s (cfg.data_m2s), .cfg_wb_sel (cfg.sel),
		.cfg_wb_data_s2m (cfg.data_s2m), .cfg_wb_ack (cfg.ack), .cfg_wb_err (cfg.err),
		.ldr_awvalid (ram_awvalid), .ldr_awready (ram_awready), .ldr_awaddr (ram_addr),
		.ldr_wvalid (ram_wvalid), .ldr_wready (ram_wready), .ldr_wdata (ram_wdata), .ldr_wstrb (ram_wstrb),
		.ldr_bvalid (ram_bvalid), .ldr_bready (ram_bready), .ldr_bresp (ram_bresp),
		.ldr_arvalid (ram_arvalid), .ldr_arready (ram_arready), .ldr_araddr (ram_addr),
		.ldr_rvalid (ram_rvalid), .ldr_rready (ram_rready), .ldr_rdata (ram_rdata), .ldr_rresp (ram_rresp),
		.core_trace_pc (core_trace_pc), .core_trace_valid (core_trace_valid)
	);

	// Three-sink subsystem (T2): URAM ring + DDR4 sink + PIB behind ONE beat
	// input and ONE CTRL window (0x18..0x30 + 0x38), identical to duo/trio/
	// tgc5b2_axis_wp. It holds the ct_soc_trace_ring instance this top used to
	// instantiate directly; TRACE_BEATS/TRACE_BYTES/trace_wrapped and the TRACE
	// read-back port keep their previous meaning.
	//
	// mbv is the only design whose ATB sink can stall (ATB_BP), so the sinks
	// observe the ACCEPTED beat stream: ct_trace_sinks ties the ring's atready
	// to 1'b1 internally and ct_soc_trace_ring captures on `atvalid && atready`
	// (ct_soc_trace_ring.sv:82) -- handing it the raw atvalid would count a
	// stalled beat once per stalled cycle and wreck every ATB_BP measurement.
	uwire logic atb_beat = atb_atvalid && atb_ready_eff;

	ct_trace_sinks #(.TRACE_DEPTH(TRACE_DEPTH)) sinks (
		.clk (clk), .rst (rst),
		.trace_clear (trace_clear),
		.atb_atvalid (atb_beat),
		.atb_atdata (atb_atdata),
		.atb_atbytes (atb_atbytes),
		.reg_wr_i (sinks_reg_wr), .reg_wr_ix_i (sinks_wr_ix), .reg_wr_data_i (sinks_wr_data),
		.reg_rd_ix_i (sinks_rd_ix), .reg_rd_data_o (sinks_rd_data),
		.trace_beats_o (trace_beats), .trace_bytes_o (trace_bytes),
		.trace_wrapped_o (trace_overflow),
		.trace_rd_word (trace_rd_word), .trace_rd_data (trace_rdata),
		.m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
		.m_axi_awvalid, .m_axi_awready,
		.m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid, .m_axi_wready,
		.m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
		.pib_clk, .pib_data
	);

	ct_soc_axis_buf axis_buf (
		.clk (clk), .rst (rst), .clear (trace_clear),
		.axis_tvalid (axis_tvalid), .axis_tready (1'b1),
		.axis_tdata (axis_tdata), .axis_tkeep (axis_tkeep),
		.axis_tid (axis_tid), .axis_tlast (axis_tlast),
		.beats_o (axis_beats), .overflow_o (axis_overflow),
		.rd_word (axis_rd_word), .rd_data (axis_rdata)
	);

	// -- Region decode -----------------------------------------------------
	typedef enum logic [2:0] { SEG_CTRL, SEG_ENC, SEG_RAM, SEG_TRACE, SEG_AXIS } seg_e;

	function automatic seg_e seg_of(input logic [21:0] a);
		if      (a[21] && a[20]) seg_of = SEG_AXIS;
		else if (a[21])          seg_of = SEG_TRACE;
		else if (a[20])          seg_of = SEG_RAM;
		else if (a[16])          seg_of = SEG_ENC;
		else                     seg_of = SEG_CTRL;
	endfunction

	// ======================================================================
	// AXI4-Lite slave front-end (canonical registered handshake)
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

	// Write address + data are accepted together (aw_en gates re-acceptance
	// until the current write's B response is taken).
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

	// Read address accepted with a one-cycle arready pulse.
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
	// Backend: service the decoded region; produce bvalid / rvalid
	// ======================================================================
	typedef enum logic [3:0] {
		B_IDLE, B_WR, B_SUB_AW, B_SUB_B, B_RD, B_SUB_AR, B_SUB_R, B_TRACE0, B_TRACE1,
		B_AXIS0, B_AXIS1
	} bstate_e;

	bstate_e     bstate;
	seg_e        seg;
	uwire logic  is_ram = (seg == SEG_RAM);

	always_ff @(posedge clk) begin
		if (rst) begin
			bstate <= B_IDLE; seg <= SEG_CTRL; rd_busy <= 1'b0;
			axi_bvalid <= 1'b0; axi_rvalid <= 1'b0; rdata_q <= '0;
			control_reg <= '0;
			atb_bp_reg  <= '0;          // backpressure off = legacy behavior
			bp_load     <= 1'b0;
			irq_div_reg <= 32'd4096;    // ~55 us @75 MHz (legacy fixed value)
		end
		else begin
			bp_load <= 1'b0;            // default; the ATB_BP write edge sets it
			// response accept
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
							case (awaddr_q[6:2])
								5'd0:  control_reg <= wdata_q;              // 0x00 CONTROL
								// 0x18..0x30 + 0x38: sink window in ct_trace_sinks
								// (sinks_reg_wr strobes in this same cycle).
								5'd15: irq_div_reg <= (wdata_q == 32'd0) ? 32'd4096 : wdata_q; // 0x3C IRQ_DIV
								5'd16: begin                                // 0x40 ATB_BP
									atb_bp_reg <= wdata_q;
									// The counter/LFSR/stall-counter belong to the generator
									// block (ONE driver per signal -- otherwise DRC MDRV-1);
									// only the load pulse lives here. The seed is picked up
									// there, so a run from (mode, param, seed) stays exactly
									// reproducible.
									bp_load    <= 1'b1;
								end
								default: ;
							endcase
							axi_bvalid <= 1'b1; bstate <= B_IDLE;
						end
						SEG_ENC, SEG_RAM: bstate <= B_SUB_AW;
						default: begin axi_bvalid <= 1'b1; bstate <= B_IDLE; end   // TRACE write ignored
					endcase
				end
				B_SUB_AW: if (is_ram ? (ram_awready && ram_wready) : (enc_awready && enc_wready))
					bstate <= B_SUB_B;
				B_SUB_B: if (is_ram ? ram_bvalid : enc_bvalid) begin axi_bvalid <= 1'b1; bstate <= B_IDLE; end

				B_RD: begin
					unique case (seg)
						SEG_CTRL: begin
							case (araddr_q[6:2])
								5'd0:    rdata_q <= control_reg;             // 0x00 CONTROL
								5'd1:    rdata_q <= {30'b0, axis_overflow, trace_overflow}; // 0x04 STATUS
								5'd2:    rdata_q <= trace_beats;             // 0x08 TRACE_BEATS
								5'd3:    rdata_q <= trace_bytes;             // 0x0C TRACE_BYTES
								5'd4:    rdata_q <= axis_beats;              // 0x10 AXIS_BEATS
								5'd5:    rdata_q <= 32'(TRACE_DEPTH * 4);    // 0x14 TRACE_BUFSZ (bytes)
								5'd13:   rdata_q <= bp_stalls;               // 0x34 ATB_STALLS (ro)
								5'd15:   rdata_q <= irq_div_reg;             // 0x3C IRQ_DIV
								5'd16:   rdata_q <= atb_bp_reg;              // 0x40 ATB_BP
								// 0x18..0x30 + 0x38: sink window (ct_trace_sinks);
								// anything else in the CTRL segment reads 0.
								default: rdata_q <= araddr_q[6] ? 32'd0 : sinks_rd_data;
							endcase
							axi_rvalid <= 1'b1; bstate <= B_IDLE;
						end
						SEG_TRACE: bstate <= B_TRACE0;
						SEG_AXIS:  bstate <= B_AXIS0;
						default:   bstate <= B_SUB_AR;
					endcase
				end
				B_TRACE0: bstate <= B_TRACE1;
				B_TRACE1: begin rdata_q <= trace_rdata; axi_rvalid <= 1'b1; bstate <= B_IDLE; end
				B_AXIS0: bstate <= B_AXIS1;
				B_AXIS1: begin rdata_q <= axis_rdata; axi_rvalid <= 1'b1; bstate <= B_IDLE; end
				B_SUB_AR: if (is_ram ? ram_arready : enc_arready) bstate <= B_SUB_R;
				B_SUB_R:  if (is_ram ? ram_rvalid : enc_rvalid) begin
					rdata_q <= is_ram ? ram_rdata : enc_rdata;
					axi_rvalid <= 1'b1; bstate <= B_IDLE;
				end
				default: bstate <= B_IDLE;
			endcase
		end
	end

	// Forward to the selected sub-slave (ENC / RAM), region-local byte address.
	uwire logic [21:0] acc_addr = (bstate == B_SUB_AR || bstate == B_SUB_R) ? araddr_q : awaddr_q;

	assign enc_addr    = {16'b0, acc_addr[15:0]};
	assign enc_wdata   = wdata_q;
	assign enc_wstrb   = wstrb_q;
	assign enc_awvalid = (bstate == B_SUB_AW) && (seg == SEG_ENC);
	assign enc_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_ENC);
	assign enc_bready  = (bstate == B_SUB_B)  && (seg == SEG_ENC);
	assign enc_arvalid = (bstate == B_SUB_AR) && (seg == SEG_ENC);
	assign enc_rready  = (bstate == B_SUB_R)  && (seg == SEG_ENC);

	assign ram_addr    = {12'b0, acc_addr[19:0]};
	assign ram_wdata   = wdata_q;
	assign ram_wstrb   = wstrb_q;
	assign ram_awvalid = (bstate == B_SUB_AW) && (seg == SEG_RAM);
	assign ram_wvalid  = (bstate == B_SUB_AW) && (seg == SEG_RAM);
	assign ram_bready  = (bstate == B_SUB_B)  && (seg == SEG_RAM);
	assign ram_arvalid = (bstate == B_SUB_AR) && (seg == SEG_RAM);
	assign ram_rready  = (bstate == B_SUB_R)  && (seg == SEG_RAM);

	assign trace_rd_word = {12'b0, araddr_q[21:2]};
	assign axis_rd_word  = {12'b0, araddr_q[21:2]};

	// Sink-window accesses (0x18..0x30, 0x38) delegated to ct_trace_sinks: the
	// strobe fires in exactly the one B_WR cycle of the CTRL segment; the module
	// decodes its own indices (0x00/0x34/0x3C/0x40 stay here). That window index
	// is only four bits wide, so a CTRL access at 0x40 and above must NOT reach
	// it -- otherwise 0x58 would alias onto SINK_CTRL. addr[6] gates the write
	// strobe; the read mux above returns 0 for that half instead of sinks_rd_data.
	assign sinks_reg_wr  = (bstate == B_WR) && (seg == SEG_CTRL) && !awaddr_q[6];
	assign sinks_wr_ix   = awaddr_q[5:2];
	assign sinks_wr_data = wdata_q;
	assign sinks_rd_ix   = araddr_q[5:2];

endmodule

`default_nettype wire
