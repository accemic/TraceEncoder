// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    TGC5B H2E -> CTTE TIP adapter with software instrumentation
 *           (ACT-CAP) synthesised from a doorbell store.
 *
 * @details
 *   Functionally `../../common/tgc5b/rtl/ct_tip_adapter.sv` plus ONE
 *   addition, and the addition needs its reasons written down because it
 *   looks like a hack until you see what it replaces.
 *
 *   WHY THIS EXISTS
 *   ---------------
 *   The encoder's ACT-CAP stage (`rtl/preproc/ct_L23_preproc_act_cap.sv`)
 *   fires on
 *
 *       tip.dretire && tip.dtype == CSR_READ_WRITE && tip.daddr == 0x0B10
 *
 *   and takes the command word from `tip.data`. A core therefore has to do
 *   two independent things for software instrumentation to work: accept the
 *   CSR access without trapping, AND report it on its trace port.
 *
 *   The TGC5B does the first. Its CSR file decodes the vendor window
 *   0xB10-0xB9F and the arm only clears `illegalAccess` -- no register, no
 *   side effect, no exception (`cpu/TGC5B_AXI4L_H2E.sv`, the `12'hb10` case).
 *   It does NOT do the second: `h2e_data_dtype_o` is derived from the data
 *   bus alone (0 = load, 1 = store), so a `csrw 0x0B10, x` never reaches the
 *   trace port. There is no configuration bit for that; it needs a different
 *   core netlist.
 *
 *   WHAT THIS DOES INSTEAD
 *   ----------------------
 *   Software writes the command word to a doorbell address with ONE store.
 *   That store DOES appear on the H2E data channel, and this adapter
 *   rewrites the beat into the one ACT-CAP expects:
 *
 *       store to DOORBELL_ADDR   ->   dtype = CSR_READ_WRITE
 *                                     daddr = 0x0000_0B10
 *                                     data  = the stored word
 *
 *   The core is untouched (it is vendored third-party IP) and the encoder is
 *   untouched (the adapter is the integration layer, which is where a
 *   mapping like this belongs). If a future core reports CSR writes itself,
 *   set `EN_DOORBELL = 0`, change the instrumentation macro from a store to
 *   `csrw`, and nothing else moves.
 *
 *   TWO DETAILS THAT WOULD OTHERWISE COST A DEBUG SESSION EACH
 *   ---------------------------------------------------------
 *   1. **`tip.data`, not `tip.sdata`.** The reference adapter drives
 *      `tip.data = '0` because the encoder is instantiated with
 *      `SPLIT_DATA_ACCESS = 1`, where store data travels on `sdata`. But
 *      ACT-CAP reads `data`. An adapter that forwards the store on `sdata`
 *      only decodes EVERY command as `ACT_CAP_ST_NONE` with sink NEXUS --
 *      a silent no-op, not an error, and nothing anywhere reports it. So
 *      for the rewritten beat `data` carries the command word.
 *   2. **The doorbell beat still moves the encoder's `Prev*` state.** The
 *      AXIS composer latches `daddr`/`data`/`dtype` on EVERY `dretire`,
 *      including this one. So after a doorbell, "the last data access" is
 *      the doorbell. A `DAQ_DADDR`/`DAQ_DATA` command must therefore sit
 *      directly behind the real access it is asking about, never behind
 *      another doorbell. `assert_doorbell_pair` below makes a violation
 *      loud in simulation instead of subtly wrong on hardware.
 *
 *   The instrumentation deliberately does NOT appear as a data access: the
 *   beat is a CSR write after the rewrite, so the data-trace and DF stages
 *   do not see a store. Instrumentation must be invisible to the thing it
 *   instruments.
 */

module ct_tip_adapter_actcap
	import tip_pkg::*;
#(
	// Doorbell address. Its own segment, private per core, NOT inside the
	// shared memory (an instrumentation store into shared memory would show
	// up in the race analysis as a shared access).
	logic [31:0] DOORBELL_ADDR = 32'h4000_0000,
	// 0 = behave exactly like the reference adapter (for a core that reports
	// CSR writes itself, or to measure the demo without ACT-CAP).
	bit          EN_DOORBELL   = 1'b1
) (
	input  uwire logic        clk,          // for the simulation assertion only
	input  uwire logic        rst,

	// -- TGC5B H2E instruction-trace fields --------------------------------
	input  uwire logic [3:0]  h2e_inst_itype,
	input  uwire logic [3:0]  h2e_inst_cause,
	input  uwire logic [31:0] h2e_inst_tval,
	input  uwire logic [2:0]  h2e_inst_priv,
	input  uwire logic [31:0] h2e_inst_iaddr,
	input  uwire logic [1:0]  h2e_inst_context,
	input  uwire logic [63:0] h2e_inst_time,
	input  uwire logic [1:0]  h2e_inst_ctype,
	input  uwire logic        h2e_inst_iretire,
	input  uwire logic [1:0]  h2e_inst_ilastsize,

	// -- TGC5B H2E data-trace fields (split load/store) --------------------
	input  uwire logic [3:0]  h2e_data_dtype,
	input  uwire logic [31:0] h2e_data_daddr,
	input  uwire logic [7:0]  h2e_data_dsize,
	input  uwire logic        h2e_data_dretire,
	input  uwire logic [31:0] h2e_data_sdata,
	input  uwire logic [1:0]  h2e_data_lresp,
	input  uwire logic [31:0] h2e_data_ldata,

	// -- CTTE ingress port -------------------------------------------------
	tip_if.master tip,

	// -- Observation -------------------------------------------------------
	output      logic         actcap_hit,   // one pulse per rewritten beat
	output      logic [31:0]  actcap_count  // rewritten beats, saturating
);

	// Same value-preserving cast as the reference adapter: the TGC5B emits
	// the N-Trace standard itype encoding.
	function automatic tip_itype_e map_itype(input logic [3:0] raw);
		return tip_itype_e'(raw);
	endfunction

	localparam logic [3:0] H2E_DTYPE_STORE = 4'd1;   // TGC5B: 0 = load, 1 = store
	localparam logic [31:0] ACT_CAP_CSR    = 32'h0000_0B10;

	uwire logic is_doorbell = EN_DOORBELL
	                       && h2e_data_dretire
	                       && (h2e_data_dtype == H2E_DTYPE_STORE)
	                       && (h2e_data_daddr == DOORBELL_ADDR);

	always_comb begin
		// control flow -- unchanged from the reference adapter
		tip.itype     = map_itype(h2e_inst_itype);
		tip.ecause    = tip_ecause_e'(h2e_inst_cause);
		tip.tval      = h2e_inst_tval;
		tip.priv      = h2e_inst_priv;
		tip.iaddr     = h2e_inst_iaddr;
		tip._context  = h2e_inst_context;
		tip._time     = h2e_inst_time;
		tip.ctype     = h2e_inst_ctype;
		tip.iretire   = h2e_inst_iretire;
		tip.ilastsize = h2e_inst_ilastsize;
		tip.impdef    = '0;

		if (is_doorbell) begin
			// The one addition: present the store as the CSR write ACT-CAP
			// decodes. `data` carries the command word (see @details 1).
			tip.dretire = 1'b1;
			tip.dtype   = CSR_READ_WRITE;
			tip.daddr   = ACT_CAP_CSR;
			tip.dsize   = tip_dsize_t'(2);          // word
			tip.data    = tip_data_t'(h2e_data_sdata);
			tip.sdata   = '0;
			tip.lresp   = '0;
			tip.ldata   = '0;
		end
		else begin
			// data flow (split load/store: legacy combined `data` unused)
			tip.dretire = h2e_data_dretire;
			tip.dtype   = tip_dtype_e'(h2e_data_dtype);
			tip.daddr   = h2e_data_daddr;
			tip.dsize   = h2e_data_dsize[TIP_DSIZE_WIDTH-1:0];
			tip.data    = '0;
			tip.sdata   = h2e_data_sdata;
			tip.lresp   = h2e_data_lresp;
			tip.ldata   = h2e_data_ldata;
		end
	end

	// -----------------------------------------------------------------
	// Observation counter -- lets the host compare "stores converted" against
	// "records received" and tell a dropped record from a missing conversion.
	// -----------------------------------------------------------------
	logic [31:0] count_q;
	assign actcap_hit   = is_doorbell;
	assign actcap_count = count_q;

	always_ff @(posedge clk) begin
		if (rst) begin
			count_q <= 32'h0;
		end
		else if (is_doorbell && (count_q != 32'hFFFF_FFFF)) begin
			count_q <= count_q + 32'd1;
		end
	end

	// -----------------------------------------------------------------
	// Simulation guard for @details 2: a doorbell directly behind another
	// doorbell leaves the encoder's Prev* state pointing at the doorbell, so
	// a DAQ_DADDR/DAQ_DATA command there reports the wrong access. This is a
	// software contract, so it is checked where software can still be fixed.
	// -----------------------------------------------------------------
`ifndef SYNTHESIS
	logic prev_beat_was_doorbell;
	always_ff @(posedge clk) begin
		if (rst) begin
			prev_beat_was_doorbell <= 1'b0;
		end
		else if (h2e_data_dretire) begin
			prev_beat_was_doorbell <= is_doorbell;
		end
	end

	// NOTE the polarity: the property is the GOOD case, so the `else` fires
	// on the bad one. Writing this as `(bad) |-> 1'b1` would pass
	// unconditionally -- a check that cannot fail is not a check.
	//
	// Refined after the first end-to-end run: back-to-back doorbells are a
	// LEGITIMATE pattern (the demo's _cap() blocks emit two DAQ_PC_CURR
	// stores in a row), because PC_CURR does not read the encoder's Prev*
	// state. The hazard exists only when the SECOND command is one of the
	// data commands (DAQ_DATA=4 / DAQ_DADDR=5 / DAQ_DATA_DADDR=6) -- those
	// would report the doorbell itself as "the last data access". The
	// command is right there in the store data, so the check reads it and
	// warns only about the real hazard instead of every pair.
	uwire logic [5:0] doorbell_cmd = h2e_data_sdata[5:0];
	uwire logic doorbell_reads_prev =
		(doorbell_cmd == 6'd4) || (doorbell_cmd == 6'd5) || (doorbell_cmd == 6'd6);

	assert_doorbell_pair: assert property (
		@(posedge clk) disable iff (rst)
		!(is_doorbell && prev_beat_was_doorbell && doorbell_reads_prev)
	) else $warning("%t ct_tip_adapter_actcap: a DAQ_DATA/DADDR doorbell directly follows another doorbell -- it reports the DOORBELL as the last data access, not your access (see @details 2)", $realtime);
`endif

endmodule // ct_tip_adapter_actcap

`default_nettype wire
