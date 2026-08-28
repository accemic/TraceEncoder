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
 *     0x00_0000  CTRL   control/status registers (this module)
 *                  0x00 CONTROL (rw): b0 core_run  b1 trace_clear  b2 trace_flush
 *                  0x04 STATUS  (ro): b0 trace_overflow  b1 axis_overflow
 *                  0x08 TRACE_BEATS (ro)   0x0C TRACE_BYTES (ro)
 *                  0x10 AXIS_BEATS  (ro)
 *     0x01_0000  ENC    CEDARtools.TraceEncoder CSRs (via ct_axil_to_wb -> Wishbone)
 *     0x10_0000  RAM    program/data RAM (write the program while core_run=0),
 *                       MEM_WORDS x 32 b = 64 KiB by default
 *     0x20_0000  TRACE  captured ATB words (ct_soc_trace_buf), TRACE_DEPTH x 32 b
 *                       = 16 KiB by default; read back, decode on host
 *     0x30_0000  AXIS   captured DAQ records (ct_soc_axis_buf), AXIS_DEPTH x 128 b
 *                       = 4 KiB by default, read back as four 32-bit words per beat
 *
 *   A region is selected from the aperture's top address bits, so every window
 *   is 1 MiB wide while the memory behind it is smaller: reads past a buffer's
 *   capacity alias back to its start (TRACE every 4*TRACE_DEPTH bytes, AXIS
 *   every 16*AXIS_DEPTH, RAM every 4*MEM_WORDS). Read TRACE_BYTES / AXIS_BEATS
 *   first and stop there — both buffers stop capturing once full and latch
 *   their STATUS overflow bit, so a full buffer means the capture is truncated.
 *
 *   The PS holds the core in reset (core_run=0) while it loads the program and
 *   configures the encoder, then starts it (core_run=1). The encoder's ATB
 *   output is captured into the TRACE BRAM and its AXIS instrumentation (DAQ)
 *   stream into the AXIS BRAM; both are re-armed together by trace_clear.
 *
 *   The AXI4-Lite slave front-end uses the canonical registered-handshake
 *   pattern (awready/wready pulse together with an aw_en gate; bvalid/rvalid
 *   registered), which is robust with the PS SmartConnect. A small backend FSM
 *   services the decoded region — immediate for CTRL, forwarded to the encoder
 *   (Wishbone) / RAM sub-slaves for ENC/RAM, one BRAM-latency cycle for
 *   TRACE/AXIS.
 */

module ct_soc_top #(
	int unsigned MEM_WORDS   = 16384,    // program/data RAM: words -> 64 KiB
	int unsigned TRACE_DEPTH = 4096,     // ATB capture: beats (1 word each) -> 16 KiB
	int unsigned AXIS_DEPTH  = 256       // AXIS capture: beats (4 words each) -> 4 KiB
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
	input  uwire logic        s_axi_rready
);

	localparam logic [1:0] RESP_OKAY = 2'b00;

	uwire logic rst = ~resetn;

	// -- Control / status registers ----------------------------------------
	logic [31:0] control_reg;      // b0 core_run, b1 trace_clear, b2 trace_flush
	uwire logic  core_run    = control_reg[0];
	uwire logic  trace_clear = control_reg[1];
	uwire logic  trace_flush = control_reg[2];
	uwire logic  core_rst_hold = ~core_run;

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

	ct_soc_synth_wrap #(.MEM_WORDS(MEM_WORDS)) soc (
		.clk (clk), .rst (rst),
		.core_rst_hold (core_rst_hold),
		.atb_atdata (atb_atdata), .atb_atbytes (atb_atbytes), .atb_atid (atb_atid),
		.atb_atvalid (atb_atvalid), .atb_atready (1'b1),
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

	ct_soc_trace_buf #(.DEPTH(TRACE_DEPTH)) trace_buf (
		.clk (clk), .rst (rst), .clear (trace_clear),
		.atb_atvalid (atb_atvalid), .atb_atready (1'b1),
		.atb_atdata (atb_atdata), .atb_atbytes (atb_atbytes),
		.beats_o (trace_beats), .bytes_o (trace_bytes), .overflow_o (trace_overflow),
		.rd_word (trace_rd_word), .rd_data (trace_rdata)
	);

	ct_soc_axis_buf #(.DEPTH(AXIS_DEPTH)) axis_buf (
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
		end
		else begin
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
							if (awaddr_q[5:2] == 4'd0) control_reg <= wdata_q;
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
							case (araddr_q[5:2])
								4'd0:    rdata_q <= control_reg;             // 0x00 CONTROL
								4'd1:    rdata_q <= {30'b0, axis_overflow, trace_overflow}; // 0x04 STATUS
								4'd2:    rdata_q <= trace_beats;             // 0x08 TRACE_BEATS
								4'd3:    rdata_q <= trace_bytes;             // 0x0C TRACE_BYTES
								4'd4:    rdata_q <= axis_beats;              // 0x10 AXIS_BEATS
								default: rdata_q <= '0;
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

endmodule

`default_nettype wire
