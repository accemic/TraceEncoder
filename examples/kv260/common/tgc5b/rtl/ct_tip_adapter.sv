// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief    TGC5B H2E trace port -> CEDARtools.TraceEncoder TIP adapter.
 *
 * @details
 *   The MINRES TGC5B core exposes its retirement stream on a flat "H2E"
 *   (hart-to-encoder) port whose fields follow the RISC-V N-Trace ingress-port
 *   definition, so the mapping onto `tip_if` is almost 1:1:
 *
 *   - `itype` / `ecause` / `dtype` are re-typed to the encoder enums. The
 *     numeric encodings are the N-Trace standard ones (see tip_pkg), which the
 *     TGC5B already emits, so the cast is value-preserving. `map_itype()` is the
 *     single place to install a remap should a future core deviate.
 *   - `dsize` is the log2(byte-count) size code; the encoder field is 6 bits,
 *     the core drives 8, so the low 6 bits are taken.
 *   - The core is wired for split load/store data, so `sdata`/`lresp`/`ldata`
 *     are forwarded and the encoder must be instantiated with
 *     `SPLIT_DATA_ACCESS = 1` (the legacy combined `data` bus is left at 0).
 *
 *   Pure combinational: one TIP beat per core clock, qualified by the core's
 *   `iretire` / `dretire` strobes exactly as the encoder expects.
 */

module ct_tip_adapter
	import tip_pkg::*;
(
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

	// -- CEDARtools.TraceEncoder ingress port -------------------------------
	tip_if.master tip
);

	// Instruction-type remap. The TGC5B emits the N-Trace standard encoding
	// (OTHER=0, EXCEPTION_TRAP=1, INTERRUPT=2, NOT_TAKEN_BRANCH=4,
	// TAKEN_BRANCH=5, ... RETURN=13, ...) which is identical to tip_itype_e, so
	// this is a straight cast. Replace the body with an explicit case-map if a
	// core with a different itype numbering is ever wired to this adapter.
	function automatic tip_itype_e map_itype(input logic [3:0] raw);
		return tip_itype_e'(raw);
	endfunction

	always_comb begin
		// control flow
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

		// data flow (split load/store: legacy combined `data` unused)
		tip.dretire   = h2e_data_dretire;
		tip.dtype     = tip_dtype_e'(h2e_data_dtype);
		tip.daddr     = h2e_data_daddr;
		tip.dsize     = h2e_data_dsize[TIP_DSIZE_WIDTH-1:0];
		tip.data      = '0;
		tip.sdata     = h2e_data_sdata;
		tip.lresp     = h2e_data_lresp;
		tip.ldata     = h2e_data_ldata;
	end

endmodule

`default_nettype wire
