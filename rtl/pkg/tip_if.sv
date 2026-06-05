// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    TIP (Trace Ingress Port) Interface Definition
 *
 * @details
 *   Conforms to the RISC-V trace ingress-port specifications:
 *   - E-Trace: https://docs.riscv.org/reference/e-trace/ingressPort.html
 *   - N-Trace: https://docs.riscv.org/reference/nexus-trace/ntrace_ingress_port.html
 */

import tip_pkg::*;

interface tip_if ();
	// control flow
	tip_itype_e     itype;     // instruction type
	tip_ecause_e    ecause;    // exception or interrupt cause
	tip_iaddr_t     tval;      // trap value
	tip_priv_t      priv;      // privilege level
	tip_iaddr_t     iaddr;     // instruction address
	tip_context_t   _context;  // context
	tip_time_t      _time;     // core time
	tip_ctype_t     ctype;     // reporting behavior for context
	tip_iretire_t   iretire;   // number of instructions / halfwords retired in this block
	tip_ilastsize_t ilastsize; // size of the retired instruction
	tip_impdef_t    impdef;    // implementation defined sideband signals

	// data trace
	logic           dretire;   // data access retired
	tip_dtype_e     dtype;     // data access type
	tip_daddr_t     daddr;     // data access address
	tip_dsize_t     dsize;     // data access size is 2^dsize bytes
	tip_data_t      data;      // data (legacy: unused in split-load mode)

	// split-load data flow
	logic [TIP_SDATA_WIDTH-1:0] sdata; // store data (valid at dretire for STORE)
	logic [TIP_LRESP_WIDTH-1:0] lresp; // load response: 2=OK, 3=error (valid when lresp[1]=1)
	logic [TIP_LDATA_WIDTH-1:0] ldata; // load data (valid when lresp[1]=1)

	modport master (
		output  itype, ecause, tval, priv, iaddr, _context, _time, ctype, iretire, ilastsize, impdef,
		        dretire, dtype, daddr, dsize, data, sdata, lresp, ldata
	);

	modport slave (
		input   itype, ecause, tval, priv, iaddr, _context, _time, ctype, iretire, ilastsize, impdef,
		        dretire, dtype, daddr, dsize, data, sdata, lresp, ldata
	);

endinterface // tip_if

`default_nettype wire
