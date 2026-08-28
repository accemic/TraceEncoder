// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    8250 console as BOARD RTL on the `mmio_axi4` port of the Rocket generat.
 *
 * @details
 *   L4 point 1. The missing building block from the L2 inventory: the Rocket
 *   generat has NO UART (`docs/handoffs/L2_rocket_linux.md` §1.1 -- the three
 *   `uart` greps in the 8.8 MB generat are ROM hex values, not a module, not
 *   a signal). Without a console, a Linux boot is invisible. This module is
 *   the **synthesizable replacement** for the testbench model
 *   `sw/rocket_linux/sim/rocket_mmio_con_sim.sv`.
 *
 *   TWO SOURCES, deliberately combined:
 *   1. **Register layout + bus behavior** from `rocket_mmio_con_sim.sv` (L2,
 *      VERIFIED in sim against OpenSBI: the boot run `l2boot_long` wrote 2652
 *      console bytes through exactly this layout). The model is therefore
 *      the **specification** for this file, not just an inspiration -- the
 *      match is checked transaction-by-transaction against the model itself
 *      in `sim/rocket/tb_rocket_con_8250.sv` (differential bench).
 *   2. **Memory-/PS-side** from `rtl/board_kv260/cva6_linux_periph.sv` (read
 *      only): circular BRAM ring with a PS read pointer + RX FIFO from PS to
 *      guest. This exact ring has demonstrably worked under Linux on the
 *      board (CVA6 Linux boot 2026-07-27). The CVA6 block's CLINT/PLIC are
 *      NOT carried over -- both are present in the Rocket generat (CLINT
 *      @0x0200_0000, PLIC @0x0C00_0000, L2 inventory §1).
 *
 *   ADDRESS: `UART_BASE = 0x6001_0000`. The CVA6 address 0x1000_0000 is
 *   unusable for the Rocket -- it lies below 0x4000_0000 and is not routed
 *   out at all (cbus -> `TLError`). 0x6001_0000 lies in the generat's MMIO
 *   window 0x4000_0000..0x7FFF_FFFF and is the same address carried by
 *   `sw/rocket_linux/rocket_kv260_rv64.dts`.
 *
 *   REGISTER LAYOUT (8250, reg-shift = 2, reg-io-width = 4):
 *     +0x00 THR/RBR/DLL   +0x04 IER/DLM   +0x08 IIR|FCR   +0x0C LCR
 *     +0x10 MCR           +0x14 LSR       +0x18 MSR       +0x1C SCR
 *   DLAB (LCR[7]) is decoded on BOTH write AND read: without DLAB decoding,
 *   the baud divisor ends up as garbage in the output, and a baud-rate query
 *   eats a typed character.
 *
 *   BUS SIDE: **full AXI4** with ID and burst (the generat's `mmio_axi4` port
 *   speaks AXI4, not AXI4-Lite) -- state machine and address arithmetic
 *   character-for-character identical to the L2 model. 64-bit data path:
 *   each 8-byte window holds TWO 32-bit registers. Writing: both halves
 *   separately via their own `wstrb` group (the generat replicates the data
 *   into both halves and only sets the associated strobes). Reading: both
 *   registers of the window are delivered, the master picks its half via
 *   `arsize`.
 *
 *   DELIBERATE DEVIATIONS from the L2 model (each named, none silent):
 *   - **D1 IIR (+0x08).** Default `IIR_VALUE = 8'h00` instead of the model's
 *     0xC1. Bit 0 = 0 means "interrupt pending"; that is exactly what polled
 *     operation wants: `serial8250_handle_irq` bails out immediately on
 *     `UART_IIR_NO_INT` and would never even read LSR -- the timer poll would
 *     then never pick up a character (rationale + board evidence:
 *     `cva6_linux_periph.sv`). OpenSBI does not read IIR (only writes
 *     IER/LCR/DLL/DLM/FCR/MCR, polls LSR), so the L2 boot is unaffected by
 *     this. For the equivalence proof, the bench can set `IIR_VALUE = 8'hC1`
 *     -- then the read behavior with an empty RX FIFO is **bit-identical**
 *     to the model.
 *   - **D2 RX.** The model knows no input (RBR reads constant 0, LSR.DR
 *     constant 0). This block has the CVA6 block's RX FIFO: RBR delivers the
 *     next character, LSR.DR reports "a character is available". With an
 *     EMPTY FIFO, RBR delivers 0 and DR = 0 -- then this too is bit-identical
 *     to the model. (`rx_head` is deliberately masked with `rx_empty`: an
 *     uninitialized distributed RAM would otherwise deliver X into the sim.)
 *   - **D3 Sink.** Instead of `$fwrite`, the characters land in the BRAM
 *     ring; the PS reads them via `con_*`. Dropped only once the PS lags
 *     behind by more than one ring length (`con_drops` counts it); the CPU is
 *     NEVER stalled (trace-sink principle) -- LSR therefore permanently
 *     reports THRE|TEMT.
 *
 *   NO INTERRUPT: IER is stored but never acted on. The DT node carries no
 *   `interrupts` property, the driver operates polled. This block therefore
 *   does not need the generat's PLIC.
 *
 *   NON-UART ADDRESSES on the port are acknowledged with OKAY (writes:
 *   ignored, reads: 0) -- identical to the L2 model. The block is currently
 *   the ONLY slave on the MMIO port; should further PL peripherals be added
 *   later, an address decoder belongs in front of it, not an error response
 *   here (the devicetree only describes this one address, a foreign access
 *   would be a finding).
 */
module rocket_con_8250 #(
	// Base within the generat's MMIO window (0x4000_0000..0x7FFF_FFFF).
	parameter longint unsigned UART_BASE  = 64'h6001_0000,
	// Port widths of the generat port mmio_axi4_0 (L2 TB: 31-bit address, ID 4).
	parameter int unsigned     ADDR_WIDTH = 31,
	parameter int unsigned     ID_WIDTH   = 4,
	// Console ring (bytes, power of two) and RX FIFO PS -> guest.
	parameter int unsigned     CON_BYTES    = 65536,
	parameter int unsigned     CON_RX_BYTES = 256,
	// D1: 0x00 = "interrupt pending" (polled Linux driver, board evidence
	// CVA6); 0xC1 = the L2 sim model's value (for the bit-equivalence proof).
	parameter logic [7:0]      IIR_VALUE  = 8'h00
) (
	input  uwire logic                  clk_i,
	input  uwire logic                  rst_ni,      // active-low (generat convention)

	// --- AXI4 slave (mmio_axi4_0 of RocketSystem) -------------------------
	input  uwire logic [ID_WIDTH-1:0]   awid,
	input  uwire logic [ADDR_WIDTH-1:0] awaddr,
	input  uwire logic [7:0]            awlen,
	input  uwire logic [2:0]            awsize,
	input  uwire logic [1:0]            awburst,
	input  uwire logic                  awvalid,
	output logic                        awready,
	input  uwire logic [63:0]           wdata,
	input  uwire logic [7:0]            wstrb,
	input  uwire logic                  wlast,
	input  uwire logic                  wvalid,
	output logic                        wready,
	output logic [ID_WIDTH-1:0]         bid,
	output logic [1:0]                  bresp,
	output logic                        bvalid,
	input  uwire logic                  bready,
	input  uwire logic [ID_WIDTH-1:0]   arid,
	input  uwire logic [ADDR_WIDTH-1:0] araddr,
	input  uwire logic [7:0]            arlen,
	input  uwire logic [2:0]            arsize,
	input  uwire logic [1:0]            arburst,
	input  uwire logic                  arvalid,
	output logic                        arready,
	output logic [ID_WIDTH-1:0]         rid,
	output logic [63:0]                 rdata,
	output logic [1:0]                  rresp,
	output logic                        rlast,
	output logic                        rvalid,
	input  uwire logic                  rready,

	// --- Console ring, PS side (word-addressed, like ct_soc_trace_buf) ----
	input  uwire logic        con_clear,
	input  uwire logic [31:0] con_rd_word,
	output logic [31:0]       con_rd_data,
	output logic [31:0]       con_bytes,     // total characters written (monotonic)
	output logic [31:0]       con_drops,     // dropped (PS too far behind)
	input  uwire logic [31:0] con_rd_bytes,  // PS read pointer (feedback)

	// --- RX: PS -> guest ----------------------------------------------------
	input  uwire logic        con_rx_wr,     // one pulse = accept one character
	input  uwire logic [7:0]  con_rx_data,
	output logic [15:0]       con_rx_used,
	output logic [31:0]       con_rx_drops
);

	localparam int unsigned CON_WORDS = CON_BYTES / 4;
	localparam int unsigned AW        = $clog2(CON_WORDS);
	localparam int unsigned RXAW      = $clog2(CON_RX_BYTES);

	// ------------------------------------------------------------------
	// Register state
	// ------------------------------------------------------------------
	logic [7:0] ier_q, lcr_q, mcr_q, scr_q;
	logic [7:0] dll_q, dlm_q;
	uwire logic dlab = lcr_q[7];

	// --- Console ring (BRAM, written byte-wise, read word-wise) -----------
	(* ram_style = "block" *) logic [31:0] con_mem [0:CON_WORDS-1];
	logic [31:0] con_wr_bytes;      // monotonic, = write position
	logic [31:0] con_drop_q;
	logic [31:0] con_rd_q;

	uwire logic [AW-1:0] con_waddr = con_wr_bytes[AW+1:2];
	uwire logic [1:0]    con_wsel  = con_wr_bytes[1:0];
	// The difference of two monotonic counters is correct even across the
	// 32-bit wraparound (modular arithmetic), as long as the lag never
	// reaches 2^31 -- impossible at CON_BYTES <= 64 KiB.
	uwire logic [31:0]   con_used  = con_wr_bytes - con_rd_bytes;
	uwire logic          con_full  = (con_used >= 32'(CON_BYTES));

	assign con_bytes   = con_wr_bytes;
	assign con_drops   = con_drop_q;
	assign con_rd_data = con_rd_q;

	// --- RX FIFO (PS -> guest) ------------------------------------------
	logic [7:0]          rx_mem [0:CON_RX_BYTES-1];
	logic [RXAW:0]       rx_wr_q, rx_rd_q;      // one extra bit: full != empty
	logic [31:0]         rx_drop_q;
	uwire logic [RXAW:0] rx_used  = rx_wr_q - rx_rd_q;
	uwire logic          rx_empty = (rx_wr_q == rx_rd_q);
	uwire logic          rx_full  = (rx_used == (RXAW+1)'(CON_RX_BYTES));
	// Distributed RAM -> combinatorially readable; RBR needs the byte in the
	// same cycle the read channel responds. Masking with rx_empty: see D2
	// above (X avoidance + bit-equivalence to the L2 model).
	uwire logic [7:0]    rx_head  = rx_empty ? 8'h00 : rx_mem[rx_rd_q[RXAW-1:0]];

	assign con_rx_used  = 16'(rx_used);
	assign con_rx_drops = rx_drop_q;

	// ------------------------------------------------------------------
	// Register accesses (offset relative to UART_BASE, reg-shift 2)
	// ------------------------------------------------------------------
	function automatic logic [31:0] uart_read(input int off);
		case (off)
			0:  return dlab ? {24'd0, dll_q} : {24'd0, rx_head};   // DLL / RBR
			4:  return dlab ? {24'd0, dlm_q} : {24'd0, ier_q};     // DLM / IER
			8:  return {24'd0, IIR_VALUE};                          // IIR (D1)
			12: return {24'd0, lcr_q};
			16: return {24'd0, mcr_q};
			// LSR: THRE|TEMT permanently (the ring accepts at any time),
			// DR (b0) exactly when a character is sitting in the RX FIFO.
			20: return {24'd0, 8'h60 | {7'b0, ~rx_empty}};
			24: return 32'h0000_00B0;                               // MSR: CTS/DSR/DCD active
			28: return {24'd0, scr_q};
			default: return 32'd0;
		endcase
	endfunction

	// ------------------------------------------------------------------
	// Write channel (AXI4, burst-capable -- state machine like the L2 model)
	// ------------------------------------------------------------------
	typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } wstate_e;
	wstate_e             wstate;
	logic [63:0]         waddr_q;
	logic [ID_WIDTH-1:0] wid_q;

	assign awready = (wstate == W_IDLE);
	assign wready  = (wstate == W_DATA);
	assign bresp   = 2'b00;
	assign bid     = wid_q;
	assign bvalid  = (wstate == W_RESP);

	// Window base of the current beat + hit condition. `off_lo` is a
	// VARIABLE, not an expression inline in the function call: XSIM 2026.1
	// mis-compiles an `int'()` cast placed directly in a function argument
	// with `-debug off` (the argument arrives as 0 AND the guarding `if` is
	// bypassed) -- finding B-L2-2, hard-documented in the header of
	// rocket_mmio_con_sim.sv.
	uwire logic [63:0] w_base   = waddr_q & ~64'h7;
	uwire logic        w_in_win = (w_base >= UART_BASE) && (w_base < UART_BASE + 64'h100);
	// Declared as an `int` VARIABLE (not as a cast at the point of use): per
	// B-L2-2, any `int'()` in an argument list is forbidden.
	int                off_lo;
	int                off_hi;
	always_comb begin
		off_lo = int'(w_base - UART_BASE);
		off_hi = off_lo + 4;
	end

	uwire logic w_beat  = (wstate == W_DATA) && wvalid;
	uwire logic w_lo_en = w_beat && w_in_win && (wstrb[3:0] != 4'h0);
	uwire logic w_hi_en = w_beat && w_in_win && (wstrb[7:4] != 4'h0);

	// Character intake: THR sits at offset 0 (DLAB=0). `w_base` is 8-aligned
	// and UART_BASE too -> off_lo is always a multiple of 8, so the upper
	// half never hits THR. That is exactly why the lower half is enough here.
	uwire logic       thr_hit  = w_lo_en && (off_lo == 0) && !dlab;
	uwire logic [7:0] thr_byte = wdata[7:0];

	// RBR pop: only when the master actually addressed the LOWER half and
	// DLAB = 0 -- otherwise an IER/baud-rate query eats a typed character
	// (same comment as in the CVA6 block).
	//
	// TWO-STAGE, and this is not cosmetic: `rdata` here is COMBINATIONAL (as
	// bit-equivalence with the L2 model requires). If the pop already
	// counted in the address phase, `rx_rd_q` would already have advanced by
	// the time the data beat is emitted -- the guest would get the SECOND
	// character and the first would be gone. (Measured exactly this way:
	// tb_rocket_con_8250 P4 reported 0x69 instead of 0x68.) The CVA6 block
	// does not have this problem because it REGISTERS `s_rdata` in the
	// address phase. So: only REMEMBER in the address phase, pop on the data
	// beat.
	uwire logic [63:0] ar_off64 = 64'(araddr) - UART_BASE;
	uwire logic rbr_sel  = (64'(araddr) >= UART_BASE) && (64'(araddr) < UART_BASE + 64'h100)
	                    && (ar_off64[7:0] == 8'h00) && !dlab;
	logic       rbr_arm;
	uwire logic rbr_pop  = rvalid && rready && rbr_arm && !rx_empty;

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			wstate  <= W_IDLE;
			waddr_q <= '0;
			wid_q   <= '0;
			ier_q <= '0; lcr_q <= 8'h03; mcr_q <= '0; scr_q <= '0;
			dll_q <= 8'h01; dlm_q <= '0;
			con_wr_bytes <= '0; con_drop_q <= '0;
			rx_wr_q <= '0; rx_rd_q <= '0; rx_drop_q <= '0;
		end
		else begin
			// --- RX FIFO: PS pushes in, guest fetches via RBR ---
			if (con_rx_wr) begin
				if (rx_full) rx_drop_q <= rx_drop_q + 32'd1;
				else         rx_wr_q   <= rx_wr_q + 1'b1;
			end
			if (rbr_pop) rx_rd_q <= rx_rd_q + 1'b1;

			if (con_clear) begin
				con_wr_bytes <= '0;
				con_drop_q   <= '0;
				// Also clear the RX FIFO: otherwise the guest would get
				// characters from before a "clear the ring" after all.
				rx_wr_q      <= '0;
				rx_rd_q      <= '0;
				rx_drop_q    <= '0;
			end

			unique case (wstate)
				W_IDLE: if (awvalid) begin
					waddr_q <= 64'(awaddr);
					wid_q   <= awid;
					wstate  <= W_DATA;
				end
				W_DATA: if (wvalid) begin
					if (w_lo_en) begin
						case (off_lo)
							0:  if (dlab) dll_q <= wdata[7:0];   // otherwise: a character (ring path)
							4:  if (dlab) dlm_q <= wdata[7:0];
							    else      ier_q <= wdata[7:0];
							8:  ;                                 // FCR: no FIFO model
							12: lcr_q <= wdata[7:0];
							16: mcr_q <= wdata[7:0];
							20: ;                                 // LSR read-only
							24: ;                                 // MSR read-only
							28: scr_q <= wdata[7:0];
							default: ;
						endcase
					end
					if (w_hi_en) begin
						case (off_hi)
							0:  if (dlab) dll_q <= wdata[39:32];
							4:  if (dlab) dlm_q <= wdata[39:32];
							    else      ier_q <= wdata[39:32];
							8:  ;
							12: lcr_q <= wdata[39:32];
							16: mcr_q <= wdata[39:32];
							20: ;
							24: ;
							28: scr_q <= wdata[39:32];
							default: ;
						endcase
					end
					// Character counter (the BRAM write port hangs off the
					// same thr_hit, below)
					if (thr_hit) begin
						if (con_full) con_drop_q   <= con_drop_q + 32'd1;
						else          con_wr_bytes <= con_wr_bytes + 32'd1;
					end
					waddr_q <= waddr_q + 8;
					if (wlast) wstate <= W_RESP;
				end
				W_RESP: if (bready) wstate <= W_IDLE;
				default: wstate <= W_IDLE;
			endcase
		end
	end

	// Byte write port of the ring (separate always_ff -> clean BRAM inference)
	always_ff @(posedge clk_i) begin
		if (thr_hit && !con_full) con_mem[con_waddr][8*con_wsel +: 8] <= thr_byte;
		// PS read port (registered, like the trace ring)
		con_rd_q <= con_mem[con_rd_word[AW-1:0]];
	end

	// RX FIFO memory (separate, as above -> clean RAM inference)
	always_ff @(posedge clk_i) begin
		if (con_rx_wr && !rx_full) rx_mem[rx_wr_q[RXAW-1:0]] <= con_rx_data;
	end

	// ------------------------------------------------------------------
	// Read channel (AXI4, burst-capable -- state machine like the L2 model)
	// ------------------------------------------------------------------
	typedef enum logic [0:0] { R_IDLE, R_DATA } rstate_e;
	rstate_e             rstate;
	logic [63:0]         raddr_q;
	logic [7:0]          rlen_q;
	logic [ID_WIDTH-1:0] rid_q;

	assign arready = (rstate == R_IDLE);
	assign rvalid  = (rstate == R_DATA);
	assign rid     = rid_q;
	assign rresp   = 2'b00;
	assign rlast   = (rstate == R_DATA) && (rlen_q == 0);

	int roff, roff_hi;
	always_comb begin
		roff    = int'(raddr_q - UART_BASE);   // NOT inline, see B-L2-2 above
		roff_hi = roff + 4;
		rdata   = '0;
		if (raddr_q >= UART_BASE && raddr_q < UART_BASE + 64'h100)
			rdata = {uart_read(roff_hi), uart_read(roff)};
	end

	always_ff @(posedge clk_i or negedge rst_ni) begin
		if (!rst_ni) begin
			rstate  <= R_IDLE;
			raddr_q <= '0;
			rlen_q  <= '0;
			rid_q   <= '0;
			rbr_arm <= 1'b0;
		end
		else begin
			if (rvalid && rready) rbr_arm <= 1'b0;   // only the FIRST beat pops
			unique case (rstate)
				R_IDLE: if (arvalid) begin
					raddr_q <= 64'(araddr) & ~64'h7;
					rlen_q  <= arlen;
					rid_q   <= arid;
					rbr_arm <= rbr_sel;
					rstate  <= R_DATA;
				end
				R_DATA: if (rready) begin
					raddr_q <= raddr_q + 8;
					if (rlen_q == 0) rstate <= R_IDLE;
					else             rlen_q <= rlen_q - 1;
				end
				default: rstate <= R_IDLE;
			endcase
		end
	end

`ifndef SYNTHESIS
	initial begin
		if (CON_BYTES != (1 << $clog2(CON_BYTES)))
			$fatal(1, "rocket_con_8250: CON_BYTES must be a power of two");
		if (CON_RX_BYTES != (1 << $clog2(CON_RX_BYTES)))
			$fatal(1, "rocket_con_8250: CON_RX_BYTES must be a power of two");
	end
`endif

endmodule

`default_nettype wire
