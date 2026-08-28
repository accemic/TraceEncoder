// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    Dual-port shared memory in UltraRAM for the two-core RV/CFI demo.
 *
 * @details
 *   One word array behind TWO independent AXI4-Lite slave ports over one
 *   clock. Port A and port B are peers -- no master/slave relationship, no
 *   arbitration between them, because URAM288 has two genuinely independent
 *   ports that share only the clock. That is what two cores sharing memory
 *   need, and it is why this block is URAM and not BRAM.
 *
 *   WHY URAM AND NOT BRAM
 *   ---------------------
 *   The KV260 design this belongs to sits at 73 % BRAM (105.5 of 144 tiles)
 *   and 50 % URAM (32 of 64 URAM288). The BRAM is where it is tight; the
 *   URAM is half empty. The private core RAMs additionally cost DOUBLE their
 *   nominal BRAM area, because Vivado gives the instruction read port its own
 *   copy of the array (see `../../common/tgc5b/rtl/ct_soc_ram.sv`). Putting
 *   shared memory in URAM therefore costs no BRAM tile at all.
 *
 *   ONE WORD PER ADDRESS -- AND WHY THAT IS NOT THE OBVIOUS CHOICE
 *   -------------------------------------------------------------
 *   The trace ring next door packs two 32-bit beats into one 64-bit URAM row
 *   (`../../common/ct_soc_trace_ring.sv`), which doubles capacity per block:
 *   32 KiB instead of 16 KiB. This module deliberately does NOT do that, and
 *   the reason is the whole point of the design it serves.
 *
 *   Two words per row means two ADJACENT words share one URAM address. A
 *   simultaneous write to the same address from both ports is a conflict --
 *   URAM does not arbitrate it and one of the writes can be lost. Adjacent
 *   words are exactly what two cooperating cores write: `flag[0]` and
 *   `flag[1]` of a Peterson lock sit 4 bytes apart. The demo above this block
 *   exists to detect data races, so a memory that silently loses a write to a
 *   NEIGHBOURING word would manufacture the very phenomenon under study --
 *   and it would look like a software race while being a hardware artefact.
 *
 *   With one 32-bit word per URAM address, two ports writing different words
 *   never collide, and a collision can only happen where software really did
 *   write the same location from both cores -- which is a genuine race and
 *   precisely what the demo wants to surface. The price is 16 KiB usable per
 *   URAM288 instead of 32 KiB: 256 KiB needs 16 blocks of the 32 free ones.
 *   Correctness is worth eight blocks.
 *
 *   THREE THINGS ABOUT URAM THAT BITE IF YOU DO NOT KNOW THEM
 *   ---------------------------------------------------------
 *   1. **No bitstream initialization.** URAM has no INIT path -- unlike BRAM,
 *      its contents after configuration are not something the bitstream can
 *      set. `INIT_FILE` below is a *simulation* convenience only
 *      (`$readmemh`), and on hardware the PS must write every location it
 *      relies on. The demo's host tool does that and reads the values back
 *      rather than assuming them.
 *   2. **Deeper read latency than BRAM**, and cascaded blocks add more. Both
 *      ports here answer one cycle after the address is accepted, behind the
 *      AXI4-Lite handshake, so latency is legal by construction. If timing
 *      needs another stage, add it to the handshake -- never by removing the
 *      read register, which would stop URAM inference.
 *   3. **No byte-write enables.** This is the one that cost the most time, so
 *      it is written down in full. UltraRAM inference rejects a byte-enabled
 *      write template; Vivado says
 *
 *        [Synth 8-12186] The ram_style = "ultra" set on RAM ... is ignored
 *        because invalid write mode
 *
 *      and quietly builds block RAM instead. Measured with the one-minute
 *      probe `../fpga/probe_shared_mem.tcl`: with a byte-enabled write the
 *      module is 0 URAM / 64 BRAM, with a full-word write it is 16 URAM /
 *      0 BRAM -- exactly the 16 blocks 256 KiB needs at 32-bit width.
 *
 *      So this memory writes WHOLE WORDS. A partial byte strobe is not
 *      silently widened and not silently dropped: it is answered with
 *      SLVERR, because the one thing worse than an unsupported operation is
 *      an unsupported operation that pretends to have worked. Nothing in the
 *      demo needs it -- the RISC-V programs use `lw`/`sw` and the host
 *      writes words -- and a byte-granular shared object would be a poor
 *      idea in a race demo anyway.
 *
 *   4. **Inference can fail silently** and fall back to BRAM. Check the
 *      utilization report, not the attribute: the URAM count must rise by the
 *      expected number of blocks AND the BRAM count must not rise.
 *
 *      THIS HAPPENED HERE, and the shape of the mistake is worth keeping.
 *      The first version gave each port a separate read process and a
 *      separate write process, each with its own address register -- four
 *      processes on one array. Vivado does not see a dual-port memory in
 *      that; it reports
 *
 *        [Synth 8-7217] RAM identified as Multi-port RAM (2 WRite and 2 Read)
 *
 *      and builds a multi-port EMULATION: the array is replicated per read
 *      port with write-forwarding logic around it. That cannot be URAM, so
 *      it silently became ~64 block RAMs -- on a design that already sits at
 *      73 % BRAM. The attribute was still there and still ignored.
 *
 *      The canonical template is ONE process per port with ONE address per
 *      port, doing the write and the read together. A port therefore serves
 *      one access per cycle: the handshake below gives writes priority and
 *      simply does not accept a read in the same cycle, which AXI4-Lite
 *      permits and which costs nothing at these rates.
 *
 *   PROGRAMMING CONTRACT
 *   --------------------
 *   Same-address, same-cycle accesses from both ports are NOT resolved here.
 *   Software owns mutual exclusion (the demo uses Peterson's algorithm, since
 *   the TGC5B is RV32I with no atomics). Reads never error; an address beyond
 *   `SHARED_KIB` aliases within the array, matching the other memory windows
 *   in this SoC family, so the 1 MiB-wide PS window in front of a smaller
 *   array reads repeats rather than faulting.
 */

module ct_soc_shared_mem #(
	int unsigned SHARED_KIB = 256,          // array size in KiB (power of two)
	string       INIT_FILE  = ""            // simulation only -- URAM has no bitstream INIT
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous

	// -- Port A (AXI4-Lite slave) -----------------------------------------
	input  uwire logic        a_awvalid,
	output      logic         a_awready,
	input  uwire logic [31:0] a_awaddr,
	input  uwire logic        a_wvalid,
	output      logic         a_wready,
	input  uwire logic [31:0] a_wdata,
	input  uwire logic [3:0]  a_wstrb,
	output      logic         a_bvalid,
	input  uwire logic        a_bready,
	output      logic [1:0]   a_bresp,
	input  uwire logic        a_arvalid,
	output      logic         a_arready,
	input  uwire logic [31:0] a_araddr,
	output      logic         a_rvalid,
	input  uwire logic        a_rready,
	output      logic [31:0]  a_rdata,
	output      logic [1:0]   a_rresp,

	// -- Port B (AXI4-Lite slave) -----------------------------------------
	input  uwire logic        b_awvalid,
	output      logic         b_awready,
	input  uwire logic [31:0] b_awaddr,
	input  uwire logic        b_wvalid,
	output      logic         b_wready,
	input  uwire logic [31:0] b_wdata,
	input  uwire logic [3:0]  b_wstrb,
	output      logic         b_bvalid,
	input  uwire logic        b_bready,
	output      logic [1:0]   b_bresp,
	input  uwire logic        b_arvalid,
	output      logic         b_arready,
	input  uwire logic [31:0] b_araddr,
	output      logic         b_rvalid,
	input  uwire logic        b_rready,
	output      logic [31:0]  b_rdata,
	output      logic [1:0]   b_rresp
);

	localparam int unsigned WORDS = (SHARED_KIB * 1024) / 4;
	localparam int          AW    = $clog2(WORDS);
	localparam logic [1:0]  OKAY   = 2'b00;
	localparam logic [1:0]  SLVERR = 2'b10;

	// One 32-bit word per UltraRAM address -- see @details.
	(* ram_style = "ultra" *) logic [31:0] mem [0:WORDS-1];

`ifndef SYNTHESIS
	/* SIMULATION ONLY -- and the guard is not cosmetic.
	 *
	 * UltraRAM has no initialization path at all, so an array that carries an
	 * `initial` block writing it cannot be a URAM. Vivado does not say this;
	 * it simply picks block RAM and moves on. Leaving this block visible to
	 * synthesis is therefore enough, all by itself, to turn a 256 KiB
	 * UltraRAM into 64 block RAMs -- which on this design means the
	 * implementation fails on
	 *
	 *   [DRC UTLZ-1] RAMB18 and RAMB36/FIFO over-utilized ... requires 290
	 *   of such cell types but only 288 compatible sites are available
	 *
	 * an hour into the build, with nothing pointing at the cause. */
	initial begin
		if (INIT_FILE != "") begin
			$readmemh(INIT_FILE, mem);
		end
	end
`endif

	function automatic logic [AW-1:0] word_of(input logic [31:0] byte_addr);
		return byte_addr[AW+1:2];
	endfunction

	// -----------------------------------------------------------------
	// Port A
	// -----------------------------------------------------------------
	logic          a_awready_q, a_wready_q, a_bvalid_q, a_aw_en;
	logic          a_arready_q, a_rvalid_q;
	logic          a_wpend, a_rpend;
	logic [31:0]   a_rdata_q;
	/* ONE address, ONE write-enable, ONE data/strobe register per port --
	 * the canonical true-dual-port template (see @details 3). */
	logic [AW-1:0] a_acc_addr;
	logic          a_acc_we;
	logic [31:0]   a_acc_din;
	logic [3:0]    a_acc_strb;
	logic          a_bad_strb;   /* partial strobe seen -> SLVERR */

	assign a_awready = a_awready_q;
	assign a_wready  = a_wready_q;
	assign a_bvalid  = a_bvalid_q;
	assign a_bresp   = a_bad_strb ? SLVERR : OKAY;
	assign a_arready = a_arready_q;
	assign a_rvalid  = a_rvalid_q;
	assign a_rdata   = a_rdata_q;
	assign a_rresp   = OKAY;

	always_ff @(posedge clk) begin
		if (rst) begin
			a_awready_q <= 1'b0; a_wready_q <= 1'b0; a_bvalid_q <= 1'b0;
			a_aw_en     <= 1'b1; a_wpend    <= 1'b0;
			a_arready_q <= 1'b0; a_rvalid_q <= 1'b0; a_rpend    <= 1'b0;
			a_bad_strb  <= 1'b0;
		end
		else begin
			a_awready_q <= 1'b0;
			a_wready_q  <= 1'b0;
			a_arready_q <= 1'b0;
			a_wpend     <= 1'b0;
			a_rpend     <= 1'b0;
			a_acc_we    <= 1'b0;

			// One access per cycle on this port. Writes win; a read simply
			// is not accepted in that cycle and comes one cycle later.
			if (a_aw_en && a_awvalid && a_wvalid && !a_bvalid_q) begin
				a_awready_q <= 1'b1;
				a_wready_q  <= 1'b1;
				a_aw_en     <= 1'b0;
				a_wpend     <= 1'b1;
				a_acc_we    <= (a_wstrb == 4'hF);
				a_bad_strb  <= (a_wstrb != 4'hF) && (a_wstrb != 4'h0);
				a_acc_addr  <= word_of(a_awaddr);
				a_acc_din   <= a_wdata;
				a_acc_strb  <= a_wstrb;
			end
			else if (a_arvalid && !a_rvalid_q && !a_rpend) begin
				a_arready_q <= 1'b1;
				a_rpend     <= 1'b1;
				a_acc_addr  <= word_of(a_araddr);
			end

			if (a_wpend)  a_bvalid_q <= 1'b1;
			if (a_rpend)  a_rvalid_q <= 1'b1;

			if (a_bvalid_q && a_bready) begin
				a_bvalid_q <= 1'b0;
				a_aw_en    <= 1'b1;
			end
			if (a_rvalid_q && a_rready) begin
				a_rvalid_q <= 1'b0;
			end
		end
	end

	// Canonical true-dual-port byte-write-enable template for port A: one
	// process, one address, write and read together. Do not split this into
	// separate read and write processes -- that is what made Vivado build a
	// multi-port emulation in block RAM instead of a URAM (see @details 3).
	always_ff @(posedge clk) begin
		if (a_acc_we) begin
			mem[a_acc_addr] <= a_acc_din;
		end
		else begin
			/* NO_CHANGE, not READ_FIRST: the output register keeps its value
			 * during a write instead of being loaded with the pre-write
			 * contents. UltraRAM implements NO_CHANGE; it does NOT implement
			 * read-first, and a template that asks for read-first is
			 * silently built in block RAM instead. Costs nothing here,
			 * because the handshake above already makes read and write
			 * mutually exclusive on a port. */
			a_rdata_q <= mem[a_acc_addr];
		end
	end

	// -----------------------------------------------------------------
	// Port B -- identical structure, independent state
	// -----------------------------------------------------------------
	logic          b_awready_q, b_wready_q, b_bvalid_q, b_aw_en;
	logic          b_arready_q, b_rvalid_q;
	logic          b_wpend, b_rpend;
	logic [31:0]   b_rdata_q;
	logic [AW-1:0] b_acc_addr;
	logic          b_acc_we;
	logic [31:0]   b_acc_din;
	logic [3:0]    b_acc_strb;
	logic          b_bad_strb;   /* partial strobe seen -> SLVERR */

	assign b_awready = b_awready_q;
	assign b_wready  = b_wready_q;
	assign b_bvalid  = b_bvalid_q;
	assign b_bresp   = b_bad_strb ? SLVERR : OKAY;
	assign b_arready = b_arready_q;
	assign b_rvalid  = b_rvalid_q;
	assign b_rdata   = b_rdata_q;
	assign b_rresp   = OKAY;

	always_ff @(posedge clk) begin
		if (rst) begin
			b_awready_q <= 1'b0; b_wready_q <= 1'b0; b_bvalid_q <= 1'b0;
			b_aw_en     <= 1'b1; b_wpend    <= 1'b0;
			b_arready_q <= 1'b0; b_rvalid_q <= 1'b0; b_rpend    <= 1'b0;
			b_bad_strb  <= 1'b0;
		end
		else begin
			b_awready_q <= 1'b0;
			b_wready_q  <= 1'b0;
			b_arready_q <= 1'b0;
			b_wpend     <= 1'b0;
			b_rpend     <= 1'b0;
			b_acc_we    <= 1'b0;

			if (b_aw_en && b_awvalid && b_wvalid && !b_bvalid_q) begin
				b_awready_q <= 1'b1;
				b_wready_q  <= 1'b1;
				b_aw_en     <= 1'b0;
				b_wpend     <= 1'b1;
				b_acc_we    <= (b_wstrb == 4'hF);
				b_bad_strb  <= (b_wstrb != 4'hF) && (b_wstrb != 4'h0);
				b_acc_addr  <= word_of(b_awaddr);
				b_acc_din   <= b_wdata;
				b_acc_strb  <= b_wstrb;
			end
			else if (b_arvalid && !b_rvalid_q && !b_rpend) begin
				b_arready_q <= 1'b1;
				b_rpend     <= 1'b1;
				b_acc_addr  <= word_of(b_araddr);
			end

			if (b_wpend)  b_bvalid_q <= 1'b1;
			if (b_rpend)  b_rvalid_q <= 1'b1;

			if (b_bvalid_q && b_bready) begin
				b_bvalid_q <= 1'b0;
				b_aw_en    <= 1'b1;
			end
			if (b_rvalid_q && b_rready) begin
				b_rvalid_q <= 1'b0;
			end
		end
	end

	// Port B: same canonical template as port A -- see the note there.
	always_ff @(posedge clk) begin
		if (b_acc_we) begin
			mem[b_acc_addr] <= b_acc_din;
		end
		else begin
			b_rdata_q <= mem[b_acc_addr];   /* NO_CHANGE -- see port A */
		end
	end

endmodule // ct_soc_shared_mem

`default_nettype wire
