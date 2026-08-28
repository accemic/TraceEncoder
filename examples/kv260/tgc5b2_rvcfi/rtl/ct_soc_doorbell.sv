// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    ACT-CAP doorbell: a write-only AXI4-Lite sink whose only job is
 *           to give the store a legal bus completion.
 *
 * @details
 *   Software instruments a site with ONE store to this address; the value
 *   stored is the ACT-CAP command word. The interesting part happens in
 *   `ct_tip_adapter_actcap`, which turns that store into the CSR-write TIP
 *   beat the encoder's ACT-CAP stage decodes. This module exists because the
 *   store still has to complete on the bus -- an AXI4-Lite transaction
 *   without a response hangs the core.
 *
 *   Consequences of that division of labour, all deliberate:
 *
 *   - **The data is discarded.** The payload's meaning lives in the trace
 *     stream, not in memory. The last word written is latched anyway and
 *     readable back, because during bring-up the first question is always
 *     "did the store even arrive", and answering it without a trace decoder
 *     saves an hour.
 *   - **It is NOT in the shared memory.** If the doorbell lived in the
 *     shared block, every instrumentation site would itself be a shared
 *     memory access and would appear in the race analysis as an event. The
 *     instrumentation must not be visible to the thing it instruments.
 *   - **One per core, private.** Two cores writing one doorbell would
 *     serialize on it and couple their timing.
 *   - **Always ready.** No backpressure, so instrumentation never stalls the
 *     core for longer than a single-beat AXI4-Lite handshake.
 *
 *   `hits_o` counts accepted writes (saturating). The demo's host tool reads
 *   it as a cheap cross-check against the number of ACT-CAP records it
 *   received: equal counts mean the adapter converted every store, a
 *   shortfall on the record side means records were dropped downstream
 *   rather than never generated. Distinguishing those two is the difference
 *   between "the FIFO overflowed" and "the instrumentation is broken".
 */

module ct_soc_doorbell #(
	// Saturation value of `hits_o`. Only a test overrides it: the real
	// saturation edge is 2**32-1 and no simulation reaches it, so without a
	// hook the saturation branch would ship untested -- and an unsaturated
	// wrap-to-zero would silently understate the instrumentation count.
	logic [31:0] HITS_MAX = 32'hFFFF_FFFF
) (
	input  uwire logic        clk,
	input  uwire logic        rst,          // active-high, synchronous

	// -- AXI4-Lite slave ---------------------------------------------------
	input  uwire logic        s_awvalid,
	output      logic         s_awready,
	input  uwire logic [31:0] s_awaddr,
	input  uwire logic        s_wvalid,
	output      logic         s_wready,
	input  uwire logic [31:0] s_wdata,
	input  uwire logic [3:0]  s_wstrb,
	output      logic         s_bvalid,
	input  uwire logic        s_bready,
	output      logic [1:0]   s_bresp,
	input  uwire logic        s_arvalid,
	output      logic         s_arready,
	input  uwire logic [31:0] s_araddr,
	output      logic         s_rvalid,
	input  uwire logic        s_rready,
	output      logic [31:0]  s_rdata,
	output      logic [1:0]   s_rresp,

	// -- Observation (read by the SoC CTRL window) -------------------------
	output      logic [31:0]  last_o,       // last command word written
	output      logic [31:0]  hits_o        // accepted writes, saturating
);

	localparam logic [1:0] OKAY = 2'b00;

	logic        awready_q, wready_q, bvalid_q, aw_en;
	logic        arready_q, rvalid_q;
	logic [31:0] last_q, hits_q;
	/* The write response must NOT be raised in the same cycle the address and
	 * data are accepted.
	 *
	 * The first version did exactly that -- `awready_q <= 1` and
	 * `bvalid_q <= 1` in one branch -- so BVALID went high during the very
	 * cycle in which AWREADY/WREADY were high, i.e. BEFORE the write transfer
	 * completed at the next edge. AXI forbids that, and the TGC5B's data bus
	 * does not survive it: the core wedged on the SECOND doorbell store of a
	 * pair, after the first had masked the problem (the upstream demux still
	 * had its selector pointing elsewhere and hid the early BVALID).
	 *
	 * The symptom was maddening precisely because the store LOOKED fine: the
	 * doorbell's hit counter showed both writes accepted, so software had
	 * issued them and the slave had taken them -- only the handshake back was
	 * malformed. One pending stage fixes it, and it is the same structure the
	 * shared memory next door uses, which is why THAT one never showed the
	 * problem. */
	logic        wpend, rpend;   /* R has the same rule as B */

	assign s_awready = awready_q;
	assign s_wready  = wready_q;
	assign s_bvalid  = bvalid_q;
	assign s_bresp   = OKAY;
	assign s_arready = arready_q;
	assign s_rvalid  = rvalid_q;
	assign s_rdata   = last_q;
	assign s_rresp   = OKAY;
	assign last_o    = last_q;
	assign hits_o    = hits_q;

	always_ff @(posedge clk) begin
		if (rst) begin
			awready_q <= 1'b0; wready_q <= 1'b0; bvalid_q <= 1'b0; aw_en <= 1'b1;
			arready_q <= 1'b0; rvalid_q <= 1'b0; wpend <= 1'b0; rpend <= 1'b0;
			last_q    <= 32'h0;
			hits_q    <= 32'h0;
		end
		else begin
			awready_q <= 1'b0;
			wready_q  <= 1'b0;
			wpend     <= 1'b0;
			if (aw_en && s_awvalid && s_wvalid && !bvalid_q) begin
				awready_q <= 1'b1;
				wready_q  <= 1'b1;
				aw_en     <= 1'b0;
				wpend     <= 1'b1;   /* B one cycle later -- see @details */
				// Byte strobes are honoured so a partial store cannot pretend
				// to be a full command word in the readback.
				for (int i = 0; i < 4; i++) begin
					if (s_wstrb[i]) last_q[i*8 +: 8] <= s_wdata[i*8 +: 8];
				end
				if (hits_q != HITS_MAX) begin
					hits_q <= hits_q + 32'd1;
				end
			end
			if (wpend) begin
				bvalid_q <= 1'b1;
			end
			if (bvalid_q && s_bready) begin
				bvalid_q <= 1'b0;
				aw_en    <= 1'b1;
			end

			arready_q <= 1'b0;
			rpend     <= 1'b0;
			if (s_arvalid && !rvalid_q && !rpend) begin
				arready_q <= 1'b1;
				rpend     <= 1'b1;   /* R one cycle later, same rule as B */
			end
			if (rpend) begin
				rvalid_q <= 1'b1;
			end
			if (rvalid_q && s_rready) begin
				rvalid_q <= 1'b0;
			end
		end
	end

endmodule // ct_soc_doorbell

`default_nettype wire
