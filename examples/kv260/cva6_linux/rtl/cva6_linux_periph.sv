// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Minimal platform for the Linux CVA6: CLINT + 8250 console.
 *
 * @details
 *   Deliberately kept SMALL -- the purpose is a booting kernel, not a
 *   complete SoC:
 *
 *     CLINT  (base CLINT_BASE, standard layout)
 *       0x0000  msip      (32 bit, bit 0 = software IRQ hart 0)
 *       0x4000  mtimecmp  (64 bit)
 *       0xBFF8  mtime     (64 bit, ticks at TICK_HZ)
 *
 *     UART   (base UART_BASE, 8250-compatible, reg-shift = 2)
 *       0x00 THR/RBR/DLL   0x04 IER/DLM   0x08 IIR|FCR   0x0C LCR
 *       0x10 MCR           0x14 LSR       0x18 MSR       0x1C SCR
 *
 *   Properties and deliberate limitations (mirrored in the kernel
 *   devicetree fragment):
 *   - **TX: circular ring with a PS read pointer.** Characters written land
 *     in a BRAM ring that the PS reads out via `con_*` (same pattern as
 *     ct_soc_trace_ring). `con_wr_bytes` stays monotonic (total count), the
 *     PS reports back with `con_rd_bytes` how far it has read. Nothing is
 *     dropped until the PS falls more than CON_BYTES behind.
 *     *Why not stop permanently at CON_BYTES like an earlier design:* an
 *     interactive session would then be dead after 64 KiB, and a boot
 *     alone already consumes a fifth of that.
 *   - **RX: FIFO from the PS to the guest.** The PS pushes characters in
 *     via `con_rx_*`; `RBR` reads them out one at a time, `LSR.DR` reports
 *     "character available". This gives the guest a terminal that can be
 *     typed into.
 *   - **No interrupt.** IER is stored but never takes effect; the 8250
 *     driver then operates polled (DT node without `interrupts`) -- it
 *     also polls RX, just with timer latency instead of immediately. This
 *     design therefore still needs no PLIC.
 *   - **DLAB is handled correctly.** The driver sets LCR.7 and writes the
 *     baud divisor to 0x00/0x04 -- without DLAB decoding these bytes would
 *     land as garbage in the console (a classic bring-up bug). The same
 *     applies on READ: with DLAB=1, 0x00 returns the divisor, NOT the RX
 *     character -- otherwise the baud-rate probe would eat a typed
 *     character.
 *   - LSR reports THRE|TEMT permanently (the ring accepts at any time; if
 *     it is full, `con_drops` counts instead of blocking -- the trace-sink
 *     principle: never stall the CPU) and DR exactly when the RX FIFO holds
 *     something.
 *
 *   Bus interface: AXI4-Lite (from axi_to_axi_lite behind the atomics
 *   adapter), data width 64 bit -- CLINT's mtime/mtimecmp are 64-bit
 *   registers, the UART registers sit in the lower half.
 */
module cva6_linux_periph #(
	// Address decoding: upper bits of the respective base (32-bit address
	// space).
	logic [31:0] CLINT_BASE = 32'h0200_0000,
	logic [31:0] UART_BASE  = 32'h1000_0000,
	// mtime clock. The DT node (timebase-frequency) MUST carry the same
	// value, otherwise every kernel time runs wrong.
	int unsigned CLK_HZ     = 75_000_000,
	int unsigned TICK_HZ    = 1_000_000,
	// Console ring (bytes, power of two).
	int unsigned CON_BYTES  = 65536,
	// RX FIFO PS -> guest (bytes, power of two). A typed line is rarely
	// longer than a few dozen characters; 256 also covers a pasted-in
	// command without costing noticeable area (distributed RAM).
	int unsigned CON_RX_BYTES = 256
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous

	// --- AXI4-Lite slave (CVA6 side) -------------------------------------
	input  uwire logic [31:0] s_awaddr,
	input  uwire logic        s_awvalid,
	output      logic         s_awready,
	input  uwire logic [63:0] s_wdata,
	input  uwire logic [7:0]  s_wstrb,
	input  uwire logic        s_wvalid,
	output      logic         s_wready,
	output      logic [1:0]   s_bresp,
	output      logic         s_bvalid,
	input  uwire logic        s_bready,
	input  uwire logic [31:0] s_araddr,
	input  uwire logic        s_arvalid,
	output      logic         s_arready,
	output      logic [63:0]  s_rdata,
	output      logic [1:0]   s_rresp,
	output      logic         s_rvalid,
	input  uwire logic        s_rready,

	// --- Interrupts to the core -------------------------------------------
	output      logic         timer_irq,    // mtime >= mtimecmp
	output      logic         sw_irq,       // msip[0]

	// --- Console ring, PS side (word-addressed, like ct_soc_trace_ring) --
	input  uwire logic        con_clear,
	input  uwire logic [31:0] con_rd_word,
	output      logic [31:0]  con_rd_data,
	output      logic [31:0]  con_bytes,    // total characters written (monotonic)
	output      logic [31:0]  con_drops,    // dropped (PS fell too far behind)

	// --- PS console read pointer (feedback for the ring buffer) -----------
	// The PS writes here how many characters it has already fetched. As
	// long as con_bytes - con_rd_bytes < CON_BYTES, nothing is lost.
	input  uwire logic [31:0] con_rd_bytes,

	// --- RX: PS -> guest ---------------------------------------------------
	input  uwire logic        con_rx_wr,    // one pulse = accept one character
	input  uwire logic [7:0]  con_rx_data,
	output      logic [15:0]  con_rx_used,  // slots used in the RX FIFO
	output      logic [31:0]  con_rx_drops  // dropped (RX FIFO full)
);

	localparam int unsigned CON_WORDS = CON_BYTES / 4;
	localparam int unsigned AW        = $clog2(CON_WORDS);
	localparam int unsigned TICK_DIV  = CLK_HZ / TICK_HZ;
	localparam int unsigned RXAW      = $clog2(CON_RX_BYTES);

	// ------------------------------------------------------------------
	// Write/read channel (simple, non-pipelined AXI-Lite)
	// ------------------------------------------------------------------
	logic [31:0] awaddr_q, araddr_q;
	logic [63:0] wdata_q;
	logic [7:0]  wstrb_q;
	logic        aw_seen, w_seen;

	// 64-bit bus, but 32-bit registers: RV32 stores hit the upper or lower
	// half of the beat depending on address bit 2. Evaluate BOTH sources
	// (address AND strobes), because bridges are allowed to align the
	// address to the bus width -- otherwise e.g. an IER write access
	// (0x04) would falsely land on THR (0x00) and print garbage.
	uwire logic        wsel_hi   = awaddr_q[2] || (|wstrb_q[7:4] && !(|wstrb_q[3:0]));
	uwire logic [31:0] wdata_eff = wsel_hi ? wdata_q[63:32] : wdata_q[31:0];
	uwire logic [31:0] waddr_eff = {awaddr_q[31:3], wsel_hi, 2'b00};

	assign s_awready = !aw_seen && !s_bvalid;
	assign s_wready  = !w_seen  && !s_bvalid;
	assign s_arready = !s_rvalid;
	assign s_bresp   = 2'b00;
	assign s_rresp   = 2'b00;

	uwire logic wr_fire = aw_seen && w_seen && !s_bvalid;

	// --- CLINT state -------------------------------------------------
	logic [63:0] mtime_q, mtimecmp_q;
	logic [31:0] tick_div_q;
	logic        msip_q;

	assign timer_irq = (mtime_q >= mtimecmp_q);
	assign sw_irq    = msip_q;

	// --- UART state --------------------------------------------------
	logic [7:0] ier_q, lcr_q, mcr_q, scr_q, fcr_q;
	logic [7:0] dll_q, dlm_q;
	uwire logic dlab = lcr_q[7];

	// --- Console ring (BRAM, byte-written, word-read) --
	(* ram_style = "block" *) logic [31:0] con_mem [0:CON_WORDS-1];
	logic [31:0] con_wr_bytes;      // monotonic, = write position
	logic [31:0] con_drop_q;
	logic [31:0] con_rd_q;

	uwire logic [AW-1:0]  con_waddr = con_wr_bytes[AW+1:2];
	uwire logic [1:0]     con_wsel  = con_wr_bytes[1:0];
	// Circular ring: dropping only starts once the PS is more than one
	// ring length behind. The difference of two monotonic counters is
	// correct even across the 32-bit wraparound (modular arithmetic), as
	// long as the backlog never reaches 2^31 -- impossible at
	// CON_BYTES <= 64 KiB.
	uwire logic [31:0]    con_used  = con_wr_bytes - con_rd_bytes;
	uwire logic           con_full  = (con_used >= 32'(CON_BYTES));

	assign con_bytes   = con_wr_bytes;
	assign con_drops   = con_drop_q;
	assign con_rd_data = con_rd_q;

	// --- RX FIFO (PS -> guest) ------------------------------------------
	logic [7:0]      rx_mem [0:CON_RX_BYTES-1];
	logic [RXAW:0]   rx_wr_q, rx_rd_q;        // one extra bit: full != empty
	logic [31:0]     rx_drop_q;
	uwire logic [RXAW:0] rx_used  = rx_wr_q - rx_rd_q;
	uwire logic          rx_empty = (rx_wr_q == rx_rd_q);
	uwire logic          rx_full  = (rx_used == (RXAW+1)'(CON_RX_BYTES));
	// Distributed RAM -> combinationally readable; RBR needs the byte in
	// the same cycle in which the read channel registers the response.
	uwire logic [7:0]    rx_head  = rx_mem[rx_rd_q[RXAW-1:0]];

	assign con_rx_used  = 16'(rx_used);
	assign con_rx_drops = rx_drop_q;

	// Character take-over: write access to THR with DLAB=0.
	uwire logic uart_sel   = (waddr_eff[31:12] == UART_BASE[31:12]);
	uwire logic clint_sel  = (waddr_eff[31:16] == CLINT_BASE[31:16]);
	uwire logic thr_write  = wr_fire && uart_sel && (waddr_eff[7:0] == 8'h00) && !dlab;
	uwire logic [7:0] thr_byte = wdata_eff[7:0];

	// Guest RBR read access: takes one character out of the RX FIFO.
	// The condition MUST include `!dlab` -- with DLAB=1, 0x00 reads the
	// baud divisor, and a baud-rate probe must not otherwise swallow a
	// typed character.
	uwire logic rbr_read = s_arvalid && s_arready
	                    && (s_araddr[31:12] == UART_BASE[31:12])
	                    && (s_araddr[7:0] == 8'h00) && !dlab;

	always_ff @(posedge clk) begin
		if (rst) begin
			aw_seen <= 1'b0; w_seen <= 1'b0; s_bvalid <= 1'b0;
			// s_rvalid MUST be reset here too: s_arready depends on it
			// combinationally, and an X poisons the entire read channel
			// (a classic bring-up bug, cf. the tgc5b adapter finding).
			s_rvalid <= 1'b0; s_rdata <= '0;
			araddr_q <= '0;
			awaddr_q <= '0; wdata_q <= '0; wstrb_q <= '0;
			mtime_q <= '0; mtimecmp_q <= '1; tick_div_q <= '0; msip_q <= 1'b0;
			ier_q <= '0; lcr_q <= 8'h03; mcr_q <= '0; scr_q <= '0; fcr_q <= '0;
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
			if (rbr_read && !rx_empty) rx_rd_q <= rx_rd_q + 1'b1;
			// mtime ticks independent of the bus.
			if (tick_div_q >= 32'(TICK_DIV - 1)) begin
				tick_div_q <= '0;
				mtime_q    <= mtime_q + 64'd1;
			end
			else tick_div_q <= tick_div_q + 32'd1;

			if (con_clear) begin
				con_wr_bytes <= '0;
				con_drop_q   <= '0;
				// Also clear the RX FIFO: otherwise the guest would still
				// get characters left over from before a "clear the ring".
				rx_wr_q      <= '0;
				rx_rd_q      <= '0;
				rx_drop_q    <= '0;
			end

			// --- write channel ---
			if (s_awvalid && s_awready) begin awaddr_q <= s_awaddr; aw_seen <= 1'b1; end
			if (s_wvalid  && s_wready)  begin wdata_q  <= s_wdata;  wstrb_q <= s_wstrb; w_seen <= 1'b1; end

			if (wr_fire) begin
				aw_seen <= 1'b0; w_seen <= 1'b0; s_bvalid <= 1'b1;
				if (clint_sel) begin
					// RV32 writes 64-bit registers in two 32-bit halves.
					unique case (waddr_eff[15:0])
						16'h0000: msip_q            <= wdata_eff[0];
						16'h4000: mtimecmp_q[31:0]  <= wdata_eff;
						16'h4004: mtimecmp_q[63:32] <= wdata_eff;
						16'hBFF8: mtime_q[31:0]     <= wdata_eff;
						16'hBFFC: mtime_q[63:32]    <= wdata_eff;
						default: ;
					endcase
				end
				else if (uart_sel) begin
					unique case (waddr_eff[7:0])
						8'h00: if (dlab) dll_q <= wdata_eff[7:0];    // else: character, see below
						8'h04: if (dlab) dlm_q <= wdata_eff[7:0];
						       else      ier_q <= wdata_eff[7:0];
						8'h08: fcr_q <= wdata_eff[7:0];
						8'h0C: lcr_q <= wdata_eff[7:0];
						8'h10: mcr_q <= wdata_eff[7:0];
						8'h1C: scr_q <= wdata_eff[7:0];
						default: ;
					endcase
				end
			end
			else if (s_bvalid && s_bready) s_bvalid <= 1'b0;

			// --- console ring: one byte per THR write access ---
			if (thr_write) begin
				if (con_full) con_drop_q <= con_drop_q + 32'd1;
				else          con_wr_bytes <= con_wr_bytes + 32'd1;
			end

			// --- read channel ---
			if (s_arvalid && s_arready) begin
				araddr_q <= s_araddr;
				s_rvalid <= 1'b1;
				// Place the register into the lane the master expects
				// (address bit 2).
				s_rdata  <= s_araddr[2] ? {read_mux(s_araddr)[31:0], 32'b0}
				                        : read_mux(s_araddr);
			end
			else if (s_rvalid && s_rready) s_rvalid <= 1'b0;

			// PS read port (registered, like the trace ring)
			con_rd_q <= con_mem[con_rd_word[AW-1:0]];
		end
	end

	// Byte write port of the ring (separate always_ff -> clean BRAM inference)
	always_ff @(posedge clk) begin
		if (thr_write && !con_full) begin
			con_mem[con_waddr][8*con_wsel +: 8] <= thr_byte;
		end
	end

	// RX FIFO memory (separate, as above -> clean RAM inference)
	always_ff @(posedge clk) begin
		if (con_rx_wr && !rx_full) rx_mem[rx_wr_q[RXAW-1:0]] <= con_rx_data;
	end

	function automatic logic [63:0] read_mux(input logic [31:0] a);
		read_mux = '0;
		if (a[31:16] == CLINT_BASE[31:16]) begin
			unique case (a[15:0])
				16'h0000: read_mux = {63'b0, msip_q};
				16'h4000: read_mux = mtimecmp_q;
				16'h4004: read_mux = {32'b0, mtimecmp_q[63:32]};
				16'hBFF8: read_mux = mtime_q;
				16'hBFFC: read_mux = {32'b0, mtime_q[63:32]};
				default:  read_mux = '0;
			endcase
		end
		else if (a[31:12] == UART_BASE[31:12]) begin
			unique case (a[7:0])
				8'h00: read_mux = dlab ? {56'b0, dll_q} : {56'b0, rx_head};  // DLL / RBR
				8'h04: read_mux = dlab ? {56'b0, dlm_q} : {56'b0, ier_q};
				// IIR with bit0 = 0 means "interrupt pending". Exactly what
				// polled operation wants: serial8250_handle_irq bails out
				// immediately on UART_IIR_NO_INT and would never even read
				// LSR -- the timer poll would then never pick up a
				// character.
				8'h08: read_mux = {56'b0, 8'h00};
				8'h0C: read_mux = {56'b0, lcr_q};
				8'h10: read_mux = {56'b0, mcr_q};
				// LSR: THRE|TEMT permanently (the ring accepts at any
				// time), DR (b0) exactly when a character sits in the RX
				// FIFO.
				8'h14: read_mux = {56'b0, 8'h60 | {7'b0, !rx_empty}};
				8'h18: read_mux = {56'b0, 8'hB0};                  // MSR: CTS/DSR/DCD active
				8'h1C: read_mux = {56'b0, scr_q};
				default: read_mux = '0;
			endcase
		end
	endfunction

`ifndef SYNTHESIS
	initial begin
		if (CON_BYTES != (1 << $clog2(CON_BYTES)))
			$fatal(1, "cva6_linux_periph: CON_BYTES must be a power of two");
		if (CON_RX_BYTES != (1 << $clog2(CON_RX_BYTES)))
			$fatal(1, "cva6_linux_periph: CON_RX_BYTES must be a power of two");
		if (CLK_HZ % TICK_HZ != 0)
			$fatal(1, "cva6_linux_periph: CLK_HZ/TICK_HZ not integer (%0d/%0d)", CLK_HZ, TICK_HZ);
	end
`endif

endmodule

`default_nettype wire
