// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Common three-sink trace subsystem: URAM ring + DDR4 sink + PIB
 *           behind ONE ATB beat input and ONE CTRL register window --
 *           identical for every board design (T2, 2026-08-14).
 *
 * @details
 *   Bundles the three proven sinks (previously wired individually in
 *   duo_soc_top/trio_soc_top; tgc5b2_axis_soc_top only had ring + DDR):
 *
 *     trace_buf  ct_soc_trace_ring 1-MiB URAM ring (primary, ALWAYS-ready;
 *                                  one shot | circular via SINK_CTRL b3;
 *                                  named _ring, not _buf: examples/kv260/common/tgc5b
 *                                  keeps ct_soc_trace_buf for its own,
 *                                  unrelated simple BRAM buffer)
 *     ddr_sink   ct_soc_ddr_sink   PS-DDR4 writer (AXI4 master m_axi_*,
 *                                  additive observer, own FIFO + drops)
 *     pib        ct_soc_pib        parallel 4-bit-DDR off-chip port
 *                                  (pib_clk/pib_data, PIB_PAR_4, KR260-
 *                                  adapter-compatible; calib patterns)
 *
 *   All three watch the SAME (funnel-merged) beat stream; the observer
 *   contract is unchanged: the ring never stalls, DDR/PIB drop-and-count
 *   when their FIFOs overflow -- NEVER back-pressure on the trace path.
 *
 *   CTRL register window (word index = CTRL byte offset [5:2]; the SoC top
 *   forwards its CTRL-segment accesses, everything outside these indices
 *   reads 0 / ignores writes -- index 13 = 0x34 stays in the top for
 *   FUNNEL_CTRL where present). Layout = duo_soc_top 0x18..0x30 verbatim,
 *   plus DDR_BEATS relocated to 0x38 (was 0x30 in the tgc5b2 D2 build --
 *   BREAKING there, 0x30 is PIB_DROPS everywhere now; SPEC §9):
 *     0x18 SINK_CTRL  (rw) b0 ddr_en  b1 ddr_clear (pulse, not stored)
 *                          b2 ddr_circ (1=circular, 0=one shot)
 *                          b3 uram_oneshot (1=one shot, 0=circular)
 *                          b4 pib_en  b5 pib_clear (pulse)  b6 pib_calib
 *                          b[10:8] pib_div (port clk = clk/2^(div+1), min 1)
 *                          b[13:12] pib_pattern (0=STANDARD AA/55/00/FF,
 *                          1=MOVING_ONE, 2=MOVING_ZERO)
 *     0x1C DDR_BASE   (ro) byte address in PS DDR, 32-byte aligned; ALWAYS
 *                          DDR_BASE_RST (resmem window). Read-only in
 *                          hardware since U9-1 -- every write is discarded,
 *                          armed or not (see below)
 *     0x20 DDR_SIZE   (ro) buffer bytes, 4-aligned; ALWAYS DDR_SIZE_RST.
 *                          Read-only in hardware since U9-1
 *     0x24 DDR_WPTR   (ro) bytes written TOTAL (monotonic; offset = wptr%size)
 *     0x28 SINK_STAT  (ro) b0 ddr_full (one shot)  b1 ddr_axi_err (sticky)
 *                          b2 ddr_wrapped (circular)  b3 uram_stopped
 *                          b4 ddr_cfg_rej (sticky): a DDR_BASE/DDR_SIZE write
 *                          was refused. U6 latched it only while the sink was
 *                          armed; since U9-1 it latches EVERY refused window
 *                          write, because there is no longer a state in which
 *                          one is accepted -- cleared by ddr_clear
 *     0x2C DDR_DROPS  (ro) dropped beats, saturating
 *     0x30 PIB_DROPS  (ro) dropped beats, saturating
 *     0x38 DDR_BEATS  (ro) beats offered while ddr_en (accepted = BEATS -
 *                          DROPS; clear via ddr_clear) -- cheap host proof
 *                          "beats reach the sink"
 *
 *   Reset-inert: SINK_CTRL resets to 0 -> DDR and PIB are off, the ring
 *   captures circular exactly as the pre-T2 designs did; the wire/record
 *   stream is untouched by construction (pure observers).
 *
 *   EN_DDR/EN_PIB const the respective sink away entirely (no instance, AXI
 *   master quiet / pins idle, registers read 0, SINK_CTRL bits masked) --
 *   zero cost when off.
 *
 *   DDR window (U6, 2026-08-15, translated: "one central DDR4
 *   implementation ... right away including the 256 MB DDR4 trace memory
 *   too"): the reset window is address
 *   plan v4 -- 0x5000_0000 + 256 MiB, the same one rocket2_soc_top has been
 *   using since C1 (examples/kv260/SPEC_board_memory_map.md §1). It lies completely
 *   inside the boot-time reservation ctrace-pl-ddr@50000000 (no-map,
 *   0x5000_0000 + 512 MiB, vivado/kv260_app/ctrace_resmem.dtso) and keeps
 *   64 MiB of distance to the guest window at 0x6400_0000. Correspondence
 *   rule: RTL reset == reserved-memory window; changing one means changing
 *   both. Why 256 and not 64 MiB: the sink sees the SAME byte rate as the
 *   1-MiB URAM ring (one ATB stream), so depth is the only lever there is --
 *   measured 16,7 MB/s (U5) to 41,5 MB/s (T3) fill 64 MiB in 4,0 s resp.
 *   1,6 s, and 256 MiB in 16,1 s resp. 6,5 s.
 *
 *   DDR_WPTR stays a 32-bit TOTAL byte count and wraps after 4 GiB; the host
 *   rule "offset = wptr % size" survives that wrap as long as size is a power
 *   of two (256 MiB and 64 MiB both are).
 *
 *   Reconfiguration contract (U9-1, hardware-enforced): there is none at
 *   runtime -- DDR_BASE/DDR_SIZE are fixed by the bitstream. U6 accepted
 *   writes while ddr_en=0 and refused them while armed, which covered the
 *   B-C1-1 hazard (shrinking the window under a running sink,
 *   docs/handoffs/C1_sink_overrun.md §5) but not the larger one: with the
 *   sink switched off, any address was accepted and the sink then wrote
 *   there as an AXI master. Measured consequence on kv260b
 *   (docs/handoffs/U9_window_readonly.md §1a): the sink wedged on the PS
 *   side, survived a full PL reprogram and needed a board restart. Refusals
 *   are still NOT silent -- SINK_STAT b4 latches them, and a host that reads
 *   back its write (dashboard since U4) sees the reset value.
 */
module ct_trace_sinks #(
	int unsigned TRACE_DEPTH  = 262144,       // ring capacity in beats (1 MiB URAM)
	bit          EN_DDR       = 1'b1,
	bit          EN_PIB       = 1'b1,
	// Address plan v4 (see header): resmem window 0x5000_0000, 256 MiB.
	logic [31:0] DDR_BASE_RST = 32'h5000_0000,
	logic [31:0] DDR_SIZE_RST = 32'h1000_0000
) (
	input  uwire logic        clk,
	input  uwire logic        rst,           // active-high, synchronous
	input  uwire logic        trace_clear,   // level (CONTROL b1): ring re-arm

	// ATB beat observer (funnel output; atready is constant 1 there)
	input  uwire logic        atb_atvalid,
	input  uwire logic [31:0] atb_atdata,
	input  uwire logic [1:0]  atb_atbytes,

	// CTRL register window (indices 6..14 = offsets 0x18..0x38; others no-op)
	input  uwire logic        reg_wr_i,      // 1-cycle strobe (CTRL write)
	input  uwire logic [3:0]  reg_wr_ix_i,   // word index awaddr[5:2]
	input  uwire logic [31:0] reg_wr_data_i,
	input  uwire logic [3:0]  reg_rd_ix_i,   // word index araddr[5:2]
	output logic [31:0]       reg_rd_data_o, // comb; 0 outside the window

	// URAM ring: counters (CTRL 0x08/0x0C in the top) + read-back port
	output logic [31:0]       trace_beats_o,
	output logic [31:0]       trace_bytes_o,
	output logic              trace_wrapped_o,
	input  uwire logic [31:0] trace_rd_word,
	output logic [31:0]       trace_rd_data,

	// DDR4 sink: AXI4 write-only master (to PS S_AXI_HP*_FPD, 32-bit data)
	output logic [31:0]       m_axi_awaddr,
	output logic [7:0]        m_axi_awlen,
	output logic [2:0]        m_axi_awsize,
	output logic [1:0]        m_axi_awburst,
	output logic              m_axi_awvalid,
	input  uwire logic        m_axi_awready,
	output logic [31:0]       m_axi_wdata,
	output logic [3:0]        m_axi_wstrb,
	output logic              m_axi_wlast,
	output logic              m_axi_wvalid,
	input  uwire logic        m_axi_wready,
	input  uwire logic [1:0]  m_axi_bresp,
	input  uwire logic        m_axi_bvalid,
	output logic              m_axi_bready,

	// PIB: parallel trace port (source-synchronous, DDR nibbles)
	output logic              pib_clk,
	output logic [3:0]        pib_data
);

	// Window word indices (CTRL byte offset [5:2]).
	localparam logic [3:0] IX_SINK_CTRL = 4'd6;   // 0x18
	localparam logic [3:0] IX_DDR_BASE  = 4'd7;   // 0x1C
	localparam logic [3:0] IX_DDR_SIZE  = 4'd8;   // 0x20
	localparam logic [3:0] IX_DDR_WPTR  = 4'd9;   // 0x24
	localparam logic [3:0] IX_SINK_STAT = 4'd10;  // 0x28
	localparam logic [3:0] IX_DDR_DROPS = 4'd11;  // 0x2C
	localparam logic [3:0] IX_PIB_DROPS = 4'd12;  // 0x30
	localparam logic [3:0] IX_DDR_BEATS = 4'd14;  // 0x38 (0x34 stays in the top)

	// Stored SINK_CTRL bits: everything except the two clear pulses (duo
	// contract, 0xFFFF_FFDD); absent sinks additionally mask their bits.
	localparam logic [31:0] SINK_WR_MASK = 32'hFFFF_FFDD
		& (EN_DDR ? 32'hFFFF_FFFF : ~32'h0000_0005)    // b0 ddr_en, b2 ddr_circ
		& (EN_PIB ? 32'hFFFF_FFFF : ~32'h0000_3750);   // b4/b6/b[10:8]/b[13:12]

	// -- SINK_CTRL + clear pulses -------------------------------------------
	logic [31:0] sink_ctrl_reg;
	logic        ddr_clear_pulse, pib_clear_pulse;

	always_ff @(posedge clk) begin
		if (rst) begin
			sink_ctrl_reg   <= '0;
			ddr_clear_pulse <= 1'b0;
			pib_clear_pulse <= 1'b0;
		end
		else begin
			ddr_clear_pulse <= 1'b0;
			pib_clear_pulse <= 1'b0;
			if (reg_wr_i && reg_wr_ix_i == IX_SINK_CTRL) begin
				sink_ctrl_reg   <= reg_wr_data_i & SINK_WR_MASK;
				ddr_clear_pulse <= reg_wr_data_i[1];
				pib_clear_pulse <= reg_wr_data_i[5];
			end
		end
	end

	// -- URAM ring (primary sink, always present) ----------------------------
	logic uram_stopped;

	ct_soc_trace_ring #(.DEPTH(TRACE_DEPTH)) trace_buf (
		.clk (clk), .rst (rst), .clear (trace_clear),
		.oneshot_i (sink_ctrl_reg[3]),
		.atb_atvalid (atb_atvalid), .atb_atready (1'b1),
		.atb_atdata (atb_atdata), .atb_atbytes (atb_atbytes),
		.beats_o (trace_beats_o), .bytes_o (trace_bytes_o),
		.wrapped_o (trace_wrapped_o), .stopped_o (uram_stopped),
		.rd_word (trace_rd_word), .rd_data (trace_rd_data)
	);

	// -- DDR4 sink ------------------------------------------------------------
	logic [31:0] ddr_base_reg, ddr_size_reg;
	logic [31:0] ddr_wptr, ddr_drops, ddr_beats;
	logic        ddr_full, ddr_axi_err, ddr_wrapped, ddr_cfg_rej;

	generate if (EN_DDR) begin : g_ddr
		// The window is WARL with an EMPTY set of legal software values
		// (U9-1): DDR_BASE/DDR_SIZE are read-only in HARDWARE, they hold
		// DDR_BASE_RST/DDR_SIZE_RST for the life of the bitstream, and a
		// write is discarded no matter what the sink is doing. The refusal
		// is not silent -- ddr_cfg_rej (SINK_STAT b4) latches EVERY refused
		// window write now, not just the ones that arrive while armed.
		//
		// Why the armed-only interlock (U6) was not enough, measured on
		// kv260b 2026-08-16 (docs/handoffs/U9_window_readonly.md §1/§1a):
		// with ddr_en=0 the hardware took a 0x8000_0000 for both registers
		// -- exactly as the U8 operating hint suggested -- and the sink then
		// wrote as an AXI master into an address that is not its buffer. It
		// wedged: 794 million dropped beats, wptr stuck at 0, and NEITHER a
		// soft reset of the registers NOR a full app reload with freshly
		// programmed PL brought it back; only a board restart did. The stuck
		// transaction sits on the PS side of S_AXI_HP and survives the PL.
		// One register write therefore costs the DDR trace sink until the
		// next reboot, and one digit less (0x1000_0000 instead of
		// 0x8000_0000) would have been a DMA write master in the middle of
		// the hosting Ubuntu's memory rather than into the PL aperture.
		// The dashboard answers such a write with HTTP 403 since U9, but
		// that is policy in one consumer; devmem is one line away from it.
		//
		// The legitimate way to move the window stays what the operating
		// hint says: change DDR_BASE_RST/DDR_SIZE_RST here (they are
		// elaboration parameters), rebuild the bitstream and move the
		// reserved-memory node with it -- the correspondence rule in the
		// header, unchanged.
		uwire logic [31:0] ddr_base_fix = {DDR_BASE_RST[31:5], 5'b0};
		uwire logic [31:0] ddr_size_fix = {DDR_SIZE_RST[31:2], 2'b0};
		assign ddr_base_reg = ddr_base_fix;
		assign ddr_size_reg = ddr_size_fix;

		uwire logic ddr_win_wr = reg_wr_i &&
			(reg_wr_ix_i == IX_DDR_BASE || reg_wr_ix_i == IX_DDR_SIZE);

		always_ff @(posedge clk) begin
			if (rst) ddr_cfg_rej <= 1'b0;
			else begin
				if (ddr_clear_pulse) ddr_cfg_rej <= 1'b0;
				if (ddr_win_wr)      ddr_cfg_rej <= 1'b1;
			end
		end

		// Beat proof (0x38): beats offered while ddr_en; clear via ddr_clear.
		always_ff @(posedge clk) begin
			if (rst)                  ddr_beats <= '0;
			else if (ddr_clear_pulse) ddr_beats <= '0;
			else if (atb_atvalid && sink_ctrl_reg[0]) ddr_beats <= ddr_beats + 1'b1;
		end

		ct_soc_ddr_sink ddr_sink (
			.clk (clk), .rst (rst),
			.enable_i (sink_ctrl_reg[0]),
			.clear_i (ddr_clear_pulse),
			.base_i (ddr_base_reg),
			.size_i (ddr_size_reg),
			.circ_i (sink_ctrl_reg[2]),
			.beat_valid_i (atb_atvalid),
			.beat_data_i (atb_atdata),
			.wptr_o (ddr_wptr), .full_o (ddr_full), .wrapped_o (ddr_wrapped),
			.axi_err_o (ddr_axi_err), .drops_o (ddr_drops),
			.m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst,
			.m_axi_awvalid, .m_axi_awready,
			.m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid, .m_axi_wready,
			.m_axi_bresp, .m_axi_bvalid, .m_axi_bready
		);
	end
	else begin : g_no_ddr
		assign ddr_base_reg = '0;
		assign ddr_size_reg = '0;
		assign ddr_wptr = '0;
		assign ddr_drops = '0;
		assign ddr_beats = '0;
		assign ddr_full = 1'b0;
		assign ddr_axi_err = 1'b0;
		assign ddr_wrapped = 1'b0;
		assign ddr_cfg_rej = 1'b0;
		assign m_axi_awaddr = '0;
		assign m_axi_awlen = '0;
		assign m_axi_awsize = 3'b010;
		assign m_axi_awburst = 2'b01;
		assign m_axi_awvalid = 1'b0;
		assign m_axi_wdata = '0;
		assign m_axi_wstrb = 4'hF;
		assign m_axi_wlast = 1'b0;
		assign m_axi_wvalid = 1'b0;
		assign m_axi_bready = 1'b0;
	end endgenerate

	// -- PIB -------------------------------------------------------------------
	logic [31:0] pib_drops;

	generate if (EN_PIB) begin : g_pib
		ct_soc_pib pib (
			.clk (clk), .rst (rst),
			.enable_i (sink_ctrl_reg[4]),
			.clear_i (pib_clear_pulse),
			.div_i (sink_ctrl_reg[10:8]),
			.calib_i (sink_ctrl_reg[6]),
			.pattern_i (sink_ctrl_reg[13:12]),
			.beat_valid_i (atb_atvalid),
			.beat_data_i (atb_atdata),
			.drops_o (pib_drops),
			.pib_clk, .pib_data
		);
	end
	else begin : g_no_pib
		assign pib_drops = '0;
		assign pib_clk = 1'b0;
		assign pib_data = 4'hF;      // all-ones idle (port contract)
	end endgenerate

	// -- CTRL window read mux (comb; the top registers into its rdata) --------
	always_comb begin
		case (reg_rd_ix_i)
			IX_SINK_CTRL: reg_rd_data_o = sink_ctrl_reg;
			IX_DDR_BASE:  reg_rd_data_o = ddr_base_reg;
			IX_DDR_SIZE:  reg_rd_data_o = ddr_size_reg;
			IX_DDR_WPTR:  reg_rd_data_o = ddr_wptr;
			IX_SINK_STAT: reg_rd_data_o = {27'b0, ddr_cfg_rej,
			                               uram_stopped, ddr_wrapped, ddr_axi_err, ddr_full};
			IX_DDR_DROPS: reg_rd_data_o = ddr_drops;
			IX_PIB_DROPS: reg_rd_data_o = pib_drops;
			IX_DDR_BEATS: reg_rd_data_o = ddr_beats;
			default:      reg_rd_data_o = '0;
		endcase
	end

endmodule

`default_nettype wire
