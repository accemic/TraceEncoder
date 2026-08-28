// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    The bare MicroBlaze-V CTTE SoC for the KV260 app.
 *
 * @details
 *   Port-compatible with the tgc5b `ct_soc_synth_wrap`
 *   (examples/kv260/common/tgc5b/rtl/ct_soc_synth_wrap.sv), so `mbv_soc_top` (an
 *   adapted copy of `ct_soc_top`) and the whole devmem stack work unchanged.
 *   Contents:
 *
 *     mbv_ctrace_soc_wrapper (block design, MBV_KV260=1: BRAM ports
 *     ilmb_bram_* / dlmb_bram_* brought to the edge)
 *       |- TRACE bus -> mbv_trace_if -> mbv_to_ctte_tip (adapter) -> tip_if
 *       `- ct_encoder (pinned, AD-01) -> ATB/AXIS outward, CSR via Wishbone
 *     TDP BRAM (xpm_memory_tdpram 32Kx32, byte write-enable):
 *       Port A = ILMB controller * Port B = mux(DLMB controller <-> PS loader)
 *
 *   Loader-mux contract (tgc5b semantics): the ldr AXI4-Lite window is valid
 *   ONLY while the core is held (core_rst_hold=1) -- only then is the DLMB
 *   path guaranteed idle. While the core runs, port B belongs to the DLMB;
 *   ldr accesses would corrupt the data path and are therefore never muxed
 *   in to begin with (the access hangs -- identical to tgc5b behavior, see
 *   its README).
 *
 *   Single clock: every encoder domain (tip/wb/atb/proc/wall) runs on `clk`
 *   (75 MHz pl_clk0). This is the single-clock configuration verified in the
 *   resource pass; the internal CDC FIFOs then act as plain buffers.
 *
 *   Migrated from an internal predecessor repository
 *   (2026-08-17).
 */

module mbv_soc_synth_wrap #(
	parameter int unsigned MEM_WORDS = 32768,     // 128 KiB, matches the MBV block design (BRAM @ 0x0)
	// Per-instance backend choice of the encoder (default = build profile):
	// 1 = also build the E-Trace backend (DUAL, when N-Trace is on too).
	bit EN_ETRACE = ct_pkg::CT_EN_ETRACE
) (
	input  uwire logic        clk,
	input  uwire logic        rst,
	input  uwire logic        core_rst_hold,      // 1 = core held (block-design ext_reset, ACTIVE_HIGH)
	input  uwire logic        ext_irq,            // MBV Interrupt_0 (edge; PS-triggered via CONTROL b3)

	// ATB outward (capture BRAM in the top)
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

	// AXIS instrumentation stream (ACT/DAQ) outward
	output logic [95:0]       axis_tdata,
	output logic [11:0]       axis_tkeep,
	output logic [7:0]        axis_tid,
	output logic              axis_tlast,
	output logic              axis_tvalid,
	input  uwire logic        axis_tready,

	// Encoder CSR (Wishbone, driven by ct_axil_to_wb in the top)
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

	// Program load window (AXI4-Lite sub-slave; access ONLY while core_rst_hold=1)
	input  uwire logic        ldr_awvalid,
	output logic              ldr_awready,
	input  uwire logic [31:0] ldr_awaddr,
	input  uwire logic        ldr_wvalid,
	output logic              ldr_wready,
	input  uwire logic [31:0] ldr_wdata,
	input  uwire logic [3:0]  ldr_wstrb,
	output logic              ldr_bvalid,
	input  uwire logic        ldr_bready,
	output logic [1:0]        ldr_bresp,
	input  uwire logic        ldr_arvalid,
	output logic              ldr_arready,
	input  uwire logic [31:0] ldr_araddr,
	output logic              ldr_rvalid,
	input  uwire logic        ldr_rready,
	output logic [31:0]       ldr_rdata,
	output logic [1:0]        ldr_rresp,

	// Golden reference (sim/debug): retiring PCs from the TRACE bus
	output logic [31:0]       core_trace_pc,
	output logic              core_trace_valid
);

	localparam int unsigned ADDR_W = $clog2(MEM_WORDS);   // word address width (15 for 32K)

	// ------------------------------------------------------------------
	// Block-design instance (MBV_KV260=1 wrapper): BRAM ports at the edge
	// ------------------------------------------------------------------
	uwire logic        TRACE_0_valid_instr, TRACE_0_jump_taken, TRACE_0_exception_taken;
	uwire logic        TRACE_0_of_piperun, TRACE_0_ex_piperun, TRACE_0_mem_piperun, TRACE_0_mb_halted;
	uwire logic [0:31] TRACE_0_pc, TRACE_0_instruction, TRACE_0_new_reg_value;
	uwire logic [0:5]  TRACE_0_exception_kind;
	uwire logic        TRACE_0_data_access, TRACE_0_data_read, TRACE_0_data_write, TRACE_0_reg_write;
	uwire logic [0:31] TRACE_0_data_address, TRACE_0_data_write_value;
	uwire logic [0:3]  TRACE_0_data_byte_enable;
	uwire logic [0:4]  TRACE_0_reg_addr;

	// BRAM interface directions (bram_rtl, from the BRAM's point of view): *_din = write
	// data INTO the BRAM (controller->BRAM, an input of the xpm instance here), *_dout =
	// read data OUT OF the BRAM (driven by us).
	uwire logic [31:0] ilmb_bram_addr, ilmb_bram_din;
	logic  [31:0]      ilmb_bram_dout;
	uwire logic [3:0]  ilmb_bram_we;
	uwire logic        ilmb_bram_clk, ilmb_bram_rst, ilmb_bram_en;
	uwire logic [31:0] dlmb_bram_addr, dlmb_bram_din;
	logic  [31:0]      dlmb_bram_dout;
	uwire logic [3:0]  dlmb_bram_we;
	uwire logic        dlmb_bram_clk, dlmb_bram_rst, dlmb_bram_en;

	mbv_ctrace_soc_wrapper soc (
		.clk            (clk),
		.reset          (core_rst_hold),   // ACTIVE_HIGH ext_reset of the block design's rstgen
		.Interrupt_0    (ext_irq),         // PS-triggered (CONTROL b3, edge pulse via devmem)
		.ilmb_bram_addr (ilmb_bram_addr),
		.ilmb_bram_clk  (ilmb_bram_clk),
		.ilmb_bram_din  (ilmb_bram_din),
		.ilmb_bram_dout (ilmb_bram_dout),
		.ilmb_bram_en   (ilmb_bram_en),
		.ilmb_bram_rst  (ilmb_bram_rst),
		.ilmb_bram_we   (ilmb_bram_we),
		.dlmb_bram_addr (dlmb_bram_addr),
		.dlmb_bram_clk  (dlmb_bram_clk),
		.dlmb_bram_din  (dlmb_bram_din),
		.dlmb_bram_dout (dlmb_bram_dout),
		.dlmb_bram_en   (dlmb_bram_en),
		.dlmb_bram_rst  (dlmb_bram_rst),
		.dlmb_bram_we   (dlmb_bram_we),
		.TRACE_0_pc(TRACE_0_pc), .TRACE_0_instruction(TRACE_0_instruction),
		.TRACE_0_valid_instr(TRACE_0_valid_instr), .TRACE_0_jump_taken(TRACE_0_jump_taken),
		.TRACE_0_exception_taken(TRACE_0_exception_taken), .TRACE_0_exception_kind(TRACE_0_exception_kind),
		.TRACE_0_of_piperun(TRACE_0_of_piperun), .TRACE_0_ex_piperun(TRACE_0_ex_piperun),
		.TRACE_0_mem_piperun(TRACE_0_mem_piperun), .TRACE_0_mb_halted(TRACE_0_mb_halted),
		.TRACE_0_data_access(TRACE_0_data_access), .TRACE_0_data_address(TRACE_0_data_address),
		.TRACE_0_data_read(TRACE_0_data_read), .TRACE_0_data_write(TRACE_0_data_write),
		.TRACE_0_data_write_value(TRACE_0_data_write_value), .TRACE_0_data_byte_enable(TRACE_0_data_byte_enable),
		.TRACE_0_reg_write(TRACE_0_reg_write), .TRACE_0_reg_addr(TRACE_0_reg_addr),
		.TRACE_0_new_reg_value(TRACE_0_new_reg_value)
	);

	// ------------------------------------------------------------------
	// Program/data BRAM (replaces the block design's internal blk_mem_gen)
	// Port A: ILMB (fetch only, WE practically 0) * Port B: DLMB <-> loader
	// ------------------------------------------------------------------
	// Loader -> BRAM port-B signals
	logic              ldb_en;
	logic [3:0]        ldb_we;
	logic [ADDR_W-1:0] ldb_word;
	logic [31:0]       ldb_wdata;
	uwire logic [31:0] portb_rdata;

	// Mux: while the core is held, port B belongs to the loader, otherwise to the DLMB.
	uwire logic              b_sel_ldr = core_rst_hold;
	uwire logic              b_en    = b_sel_ldr ? ldb_en    : dlmb_bram_en;
	uwire logic [3:0]        b_we    = b_sel_ldr ? ldb_we    : dlmb_bram_we;
	uwire logic [ADDR_W-1:0] b_word  = b_sel_ldr ? ldb_word  : dlmb_bram_addr[ADDR_W+1:2];
	uwire logic [31:0]       b_wdata = b_sel_ldr ? ldb_wdata : dlmb_bram_din;
	assign dlmb_bram_dout = portb_rdata;

	xpm_memory_tdpram #(
		.MEMORY_SIZE        (MEM_WORDS * 32),
		.MEMORY_PRIMITIVE   ("block"),
		.CLOCKING_MODE      ("common_clock"),
		.WRITE_DATA_WIDTH_A (32), .READ_DATA_WIDTH_A (32), .BYTE_WRITE_WIDTH_A (8),
		.WRITE_DATA_WIDTH_B (32), .READ_DATA_WIDTH_B (32), .BYTE_WRITE_WIDTH_B (8),
		.ADDR_WIDTH_A       (ADDR_W), .ADDR_WIDTH_B (ADDR_W),
		.READ_LATENCY_A     (1), .READ_LATENCY_B (1),
		.WRITE_MODE_A       ("no_change"), .WRITE_MODE_B ("no_change"),
		.MEMORY_INIT_FILE   ("none")
	) u_ram (
		.clka   (clk),
		.rsta   (1'b0),
		.ena    (ilmb_bram_en),
		.wea    (ilmb_bram_we),
		.addra  (ilmb_bram_addr[ADDR_W+1:2]),   // the LMB controller supplies a byte address
		.dina   (ilmb_bram_din),
		.douta  (ilmb_bram_dout),
		.regcea (1'b1),
		.injectsbiterra (1'b0), .injectdbiterra (1'b0),
		.sbiterra (), .dbiterra (),
		.clkb   (clk),
		.rstb   (1'b0),
		.enb    (b_en),
		.web    (b_we),
		.addrb  (b_word),
		.dinb   (b_wdata),
		.doutb  (portb_rdata),
		.regceb (1'b1),
		.injectsbiterrb (1'b0), .injectdbiterrb (1'b0),
		.sbiterrb (), .dbiterrb ()
	);

	// ------------------------------------------------------------------
	// Loader: AXI4-Lite -> BRAM port B (1 cycle of read latency)
	// ------------------------------------------------------------------
	typedef enum logic [2:0] { L_IDLE, L_WR, L_B, L_RD0, L_RD1, L_R } lstate_e;
	lstate_e lstate;

	assign ldr_bresp = 2'b00;
	assign ldr_rresp = 2'b00;

	always_ff @(posedge clk) begin
		if (rst) begin
			lstate <= L_IDLE;
			ldr_awready <= 1'b0; ldr_wready <= 1'b0; ldr_bvalid <= 1'b0;
			ldr_arready <= 1'b0; ldr_rvalid <= 1'b0; ldr_rdata <= '0;
			ldb_en <= 1'b0; ldb_we <= '0; ldb_word <= '0; ldb_wdata <= '0;
		end
		else begin
			ldr_awready <= 1'b0; ldr_wready <= 1'b0; ldr_arready <= 1'b0;
			ldb_en <= 1'b0; ldb_we <= '0;

			case (lstate)
				L_IDLE: begin
					if (ldr_awvalid && ldr_wvalid) begin
						ldr_awready <= 1'b1; ldr_wready <= 1'b1;
						ldb_en    <= 1'b1;
						ldb_we    <= ldr_wstrb;
						ldb_word  <= ldr_awaddr[ADDR_W+1:2];
						ldb_wdata <= ldr_wdata;
						lstate    <= L_WR;
					end
					else if (ldr_arvalid) begin
						ldr_arready <= 1'b1;
						ldb_en   <= 1'b1;
						ldb_word <= ldr_araddr[ADDR_W+1:2];
						lstate   <= L_RD0;
					end
				end
				L_WR: begin ldr_bvalid <= 1'b1; lstate <= L_B; end
				L_B:  if (ldr_bvalid && ldr_bready) begin ldr_bvalid <= 1'b0; lstate <= L_IDLE; end
				L_RD0: lstate <= L_RD1;                          // BRAM read latency
				L_RD1: begin ldr_rdata <= portb_rdata; ldr_rvalid <= 1'b1; lstate <= L_R; end
				L_R:  if (ldr_rvalid && ldr_rready) begin ldr_rvalid <= 1'b0; lstate <= L_IDLE; end
				default: lstate <= L_IDLE;
			endcase
		end
	end

	// ------------------------------------------------------------------
	// TRACE bus -> adapter -> encoder (structure identical to mbv_ctte_env, single clock)
	// ------------------------------------------------------------------
	mbv_trace_if mbv ();

	assign mbv.trace_pc              = TRACE_0_pc;
	assign mbv.trace_instruction     = TRACE_0_instruction;
	assign mbv.trace_valid_instr     = TRACE_0_valid_instr;
	assign mbv.trace_jump_taken      = TRACE_0_jump_taken;
	assign mbv.trace_exception_taken = TRACE_0_exception_taken;
	assign mbv.trace_exception_kind  = TRACE_0_exception_kind;
	assign mbv.trace_of_piperun      = TRACE_0_of_piperun;
	assign mbv.trace_ex_piperun      = TRACE_0_ex_piperun;
	assign mbv.trace_mem_piperun     = TRACE_0_mem_piperun;
	assign mbv.trace_halted          = TRACE_0_mb_halted;
	assign mbv.trace_data_access     = TRACE_0_data_access;
	assign mbv.trace_data_address    = TRACE_0_data_address;
	assign mbv.trace_data_read       = TRACE_0_data_read;
	assign mbv.trace_data_write      = TRACE_0_data_write;
	assign mbv.trace_data_write_value= TRACE_0_data_write_value;
	assign mbv.trace_data_byte_enable= TRACE_0_data_byte_enable;
	assign mbv.trace_reg_write       = TRACE_0_reg_write;
	assign mbv.trace_reg_addr        = TRACE_0_reg_addr;
	assign mbv.trace_new_reg_value   = TRACE_0_new_reg_value;

	tip_if tip ();

	mbv_to_ctte_tip adapter (
		.clk       (clk),
		.rst       (rst),
		.sijump_en (1'b0),
		.mbv       (mbv.sink),
		.tip       (tip.master)
	);

	wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb ();
	axis_if #(.TDATA_WIDTH(96), .TID_WIDTH(8)) axis (.aclk(clk), .aresetn(~rst));
	atb_if  atb ();

	// Wishbone pass-through (discrete top-level signals <-> interface)
	assign wb.cyc        = cfg_wb_en & cfg_wb_cyc;
	assign wb.stb        = cfg_wb_en & cfg_wb_stb;
	assign wb.we         = cfg_wb_we;
	assign wb.addr       = cfg_wb_addr;
	assign wb.data_m2s   = cfg_wb_data_m2s;
	assign wb.sel        = cfg_wb_sel;
	assign cfg_wb_data_s2m = wb.data_s2m;
	assign cfg_wb_ack      = wb.ack;
	assign cfg_wb_err      = wb.err;

	// MBV_CT_ENC_GOLD: the gold-standard encoder (the frozen CTTE reference line,
	// built via the MBV_CTTE_DIR override in create_project_kv260.tcl) has neither an
	// atb_te_raw port nor EN_ETRACE/EN_NTRACE instance parameters (vendored-only,
	// trio dual-protocol build). N-Trace-only build => framing output constant 0 (Nexus MSEO).
	ct_encoder #(
		.SPLIT_DATA_ACCESS(0)
`ifndef MBV_CT_ENC_GOLD
		, .EN_ETRACE(EN_ETRACE), .EN_NTRACE(!EN_ETRACE)
		// CORE_XLEN(32): MBV is an RV32 hart; the synced encoder (R1 elaboration
		// guard) requires the explicit value (a one-line fix per top). The gold
		// build does not know the parameter (vendored-only) -- left in the
		// ifndef branch.
		, .CORE_XLEN(32)
`endif
	) encoder (
		.tip_clk      (clk),
		.tip_rst      (rst),
		.tip          (tip.slave),
		.wb_clk       (clk),
		.wb_rst       (rst),
		.wb           (wb),
		.ct_cs_rst    (rst),
		.axis         (axis),
		.atb_atclk    (clk),
		.atb_atresetn (~rst),
		.atb          (atb),
`ifndef MBV_CT_ENC_GOLD
		.atb_te_raw   (atb_te_raw),
`endif
		.proc_clk     (clk),
		.proc_rst     (rst),
		.wall_clk     (clk),
		.wall_clk_rst (rst)
	);
`ifdef MBV_CT_ENC_GOLD
	assign atb_te_raw = 1'b0;
`endif

	// ATB/AXIS interface <-> discrete top-level signals
	assign atb_atdata  = atb.atdata;
	assign atb_atbytes = atb.atbytes;
	assign atb_atid    = atb.atid;
	assign atb_atvalid = atb.atvalid;
	assign atb.atready = atb_atready;
	assign atb_afready = atb.afready;
	assign atb.afvalid = atb_afvalid;
	assign atb.syncreq = atb_syncreq;

	assign axis_tdata  = axis.tdata;
	assign axis_tkeep  = axis.tkeep;
	assign axis_tid    = axis.tid;
	assign axis_tlast  = axis.tlast;
	assign axis_tvalid = axis.tvalid;
	assign axis.tready = axis_tready;

	// Golden reference: retiring PCs at the TIP side of the adapter (the iretire rule --
	// the trapped, non-retiring instruction does NOT belong in the reference; identical
	// to the reference used in mbv_ctte_env). Raw `valid_instr` would be wrong: on
	// traps it includes the faulting instruction, which the decoder conventionally does
	// not emit. Unused on the board (pruned away).
	assign core_trace_pc    = tip.iaddr;
	assign core_trace_valid = tip.iretire;

endmodule

`default_nettype wire
