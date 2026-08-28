// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Minimal platform for the dual CVA6 (AMP): TWO-HART CLINT + console.
 *
 * @details
 *   **ADDITIVE** version alongside `cva6_linux64_periph.sv`; the single-core
 *   file stays unchanged (it carries the board-proven boot path and is not
 *   touched).
 *
 *   Register layout, console ring, RX FIFO, DLAB handling, the
 *   byte-strobe-exact CLINT write accesses, and all their comments are
 *   taken over from the single-core version. The deltas are EXCLUSIVELY
 *   these three, all from dual-hart operation:
 *
 *   **Delta 1: CLINT carries two harts.** Standard CLINT map:
 *       0x0000  msip[0]        (32 bit)
 *       0x0004  msip[1]        (32 bit)   -- SAME 8-byte beat as msip[0];
 *                                             separated via the byte
 *                                             strobes, not via the
 *                                             address. An `sw` to 0x0004
 *                                             carries wstrb 0xF0, an `sw`
 *                                             to 0x0000 carries 0x0F.
 *       0x4000  mtimecmp[0]    (64 bit)
 *       0x4008  mtimecmp[1]    (64 bit)
 *       0xBFF8  mtime          (64 bit, shared -- ONE time base)
 *     Hence four interrupt lines instead of two: `timer_irq0/1`,
 *     `sw_irq0/1`. A shared `mtimecmp` would be the silent bug here: both
 *     guests would derail each other's tick, and that only shows up as an
 *     unexplainable time drift.
 *
 *   **Delta 2: ONE console, deliberately.** Both cores write into the same
 *     8250 and thereby into the same ring. With AMP and two independent
 *     guests, the output interleaves -- that is not a defect, but the same
 *     picture the two-hart Rocket shows (there both harts of an SMP Linux
 *     write into one console). The alternative design with two rings would
 *     have needed a second CON aperture and thereby broken the requirement
 *     "congruent view". Whoever wants to separate the streams separates
 *     them at the trace, not at the console -- that is what the Nexus SRC
 *     identifier is for.
 *
 *   **Delta 3: `mtime` is shared and runs independent of the bus** -- as
 *     before. Both guests see the same time base; for AMP that is
 *     permissible and even desirable for a mailbox with timestamps.
 *
 *   What DELIBERATELY stays unchanged (no delta without a reason): UART
 *   lane selection via address bit 2 OR upper strobes, polled operation
 *   without a PLIC, ring with a PS read pointer, IIR with bit0 = 0.
 */
module cva6_2_periph #(
	// Address decoding: upper bits of the respective base (32-bit address
	// space).
	logic [31:0] CLINT_BASE = 32'h0200_0000,
	logic [31:0] UART_BASE  = 32'h1000_0000,
	// mtime clock. The DT node (timebase-frequency) of BOTH guests MUST
	// carry the same value, otherwise their kernel times run wrong.
	int unsigned CLK_HZ     = 75_000_000,
	int unsigned TICK_HZ    = 1_000_000,
	// Console ring (bytes, power of two).
	int unsigned CON_BYTES  = 65536,
	// RX FIFO PS -> guest (bytes, power of two).
	int unsigned CON_RX_BYTES = 256
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous

	// --- AXI4-Lite slave (shared path of both cores) -----------------------
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

	// --- Interrupts to both cores -------------------------------------------
	output      logic         timer_irq0,   // mtime >= mtimecmp[0]
	output      logic         sw_irq0,      // msip[0]
	output      logic         timer_irq1,   // mtime >= mtimecmp[1]
	output      logic         sw_irq1,      // msip[1]

	// --- Console ring, PS side (word-addressed, like ct_soc_trace_ring) --
	input  uwire logic        con_clear,
	input  uwire logic [31:0] con_rd_word,
	output      logic [31:0]  con_rd_data,
	output      logic [31:0]  con_bytes,    // total characters written (monotonic)
	output      logic [31:0]  con_drops,    // dropped (PS fell too far behind)

	// --- PS console read pointer (feedback for the ring buffer) -----------
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

	// 32-bit register access on the 64-bit bus (UART): the upper or lower
	// half of the beat depending on address bit 2. Evaluate BOTH sources
	// (address AND strobes), because bridges are allowed to align the
	// address to the bus width -- otherwise e.g. an IER write access
	// (0x04) would falsely land on THR (0x00) and print garbage.
	uwire logic        wsel_hi   = awaddr_q[2] || (|wstrb_q[7:4] && !(|wstrb_q[3:0]));
	uwire logic [31:0] wdata_eff = wsel_hi ? wdata_q[63:32] : wdata_q[31:0];
	uwire logic [31:0] waddr_eff = {awaddr_q[31:3], wsel_hi, 2'b00};
	// CLINT, on the other hand, carries 64-bit registers: there the 8-byte
	// beat address counts, together with the byte strobes, not the
	// half-word selection (delta 1).
	uwire logic [31:0] wbeat_addr = {awaddr_q[31:3], 3'b000};

	assign s_awready = !aw_seen && !s_bvalid;
	assign s_wready  = !w_seen  && !s_bvalid;
	assign s_arready = !s_rvalid;
	assign s_bresp   = 2'b00;
	assign s_rresp   = 2'b00;

	uwire logic wr_fire = aw_seen && w_seen && !s_bvalid;

	// --- CLINT state (delta 1: separate msip/mtimecmp per hart) ---------
	logic [63:0] mtime_q, mtimecmp0_q, mtimecmp1_q;
	logic [31:0] tick_div_q;
	logic        msip0_q, msip1_q;

	assign timer_irq0 = (mtime_q >= mtimecmp0_q);
	assign timer_irq1 = (mtime_q >= mtimecmp1_q);
	assign sw_irq0    = msip0_q;
	assign sw_irq1    = msip1_q;

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
	uwire logic [7:0]    rx_head  = rx_mem[rx_rd_q[RXAW-1:0]];

	assign con_rx_used  = 16'(rx_used);
	assign con_rx_drops = rx_drop_q;

	// Character take-over: write access to THR with DLAB=0.
	uwire logic uart_sel   = (waddr_eff[31:12] == UART_BASE[31:12]);
	uwire logic clint_sel  = (wbeat_addr[31:16] == CLINT_BASE[31:16]);
	uwire logic thr_write  = wr_fire && uart_sel && (waddr_eff[7:0] == 8'h00) && !dlab;
	uwire logic [7:0] thr_byte = wdata_eff[7:0];

	// Guest RBR read access: takes one character out of the RX FIFO.
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
			mtime_q <= '0; mtimecmp0_q <= '1; mtimecmp1_q <= '1;
			tick_div_q <= '0; msip0_q <= 1'b0; msip1_q <= 1'b0;
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
			// mtime ticks independent of the bus (shared, delta 3).
			if (tick_div_q >= 32'(TICK_DIV - 1)) begin
				tick_div_q <= '0;
				mtime_q    <= mtime_q + 64'd1;
			end
			else tick_div_q <= tick_div_q + 32'd1;

			if (con_clear) begin
				con_wr_bytes <= '0;
				con_drop_q   <= '0;
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
					// 64-bit registers, exactly by byte strobe on the
					// 8-byte beat address. The begin/end around the loops
					// is mandatory, not cosmetic: XSIM 2024.1 rejects a
					// bare for loop as a case-item statement (finding
					// B-L3-3).
					unique case (wbeat_addr[15:0])
						16'h0000: begin
							// BOTH msip sit in this beat -- strobe 0 =
							// hart 0, strobe 4 = hart 1 (delta 1).
							if (wstrb_q[0]) msip0_q <= wdata_q[0];
							if (wstrb_q[4]) msip1_q <= wdata_q[32];
						end
						16'h4000: begin
							for (int b = 0; b < 8; b++)
								if (wstrb_q[b]) mtimecmp0_q[8*b +: 8] <= wdata_q[8*b +: 8];
						end
						16'h4008: begin
							for (int b = 0; b < 8; b++)
								if (wstrb_q[b]) mtimecmp1_q[8*b +: 8] <= wdata_q[8*b +: 8];
						end
						16'hBFF8: begin
							for (int b = 0; b < 8; b++)
								if (wstrb_q[b]) mtime_q[8*b +: 8] <= wdata_q[8*b +: 8];
						end
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
				// Function result FIRST into a variable: a bit-select
				// directly on the call is legal SV-2012, but XSIM 2024.1
				// aborts on it (finding B-L3-3).
				automatic logic [63:0] rmux = read_mux(s_araddr);
				araddr_q <= s_araddr;
				s_rvalid <= 1'b1;
				s_rdata  <= s_araddr[2] ? {rmux[31:0], 32'b0} : rmux;
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
			unique case ({a[15:3], 3'b000})
				// Both msip in ONE beat: lane 0 = hart 0, lane 1 = hart 1.
				// At a[2]=1 (32-bit read access to 0x0004) the caller
				// places rmux[31:0] into the upper lane -- hence msip1
				// goes into the lower half there.
				16'h0000: read_mux = a[2] ? {63'b0, msip1_q}
				                          : {31'b0, msip1_q, 31'b0, msip0_q};
				16'h4000: read_mux = a[2] ? {32'b0, mtimecmp0_q[63:32]} : mtimecmp0_q;
				16'h4008: read_mux = a[2] ? {32'b0, mtimecmp1_q[63:32]} : mtimecmp1_q;
				16'hBFF8: read_mux = a[2] ? {32'b0, mtime_q[63:32]}     : mtime_q;
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
			$fatal(1, "cva6_2_periph: CON_BYTES must be a power of two");
		if (CON_RX_BYTES != (1 << $clog2(CON_RX_BYTES)))
			$fatal(1, "cva6_2_periph: CON_RX_BYTES must be a power of two");
		if (CLK_HZ % TICK_HZ != 0)
			$fatal(1, "cva6_2_periph: CLK_HZ/TICK_HZ not integer (%0d/%0d)", CLK_HZ, TICK_HZ);
	end
`endif

endmodule

`default_nettype wire
