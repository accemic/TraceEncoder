// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author	Albert Schulz <aschulz@accemic.com>
* @author	Alexander Lange <alange@accemic.com>
*
* @brief    TIP (Trace Ingress Port) Interface Definition
*/

import tip_pkg::*;

interface tip_if ();
	tip_itype_e			itype;			// instruction type
	tip_ecause_e		ecause;			// exception or interrupt cause
	tip_iaddr_t			tval;			// trap value
	tip_priv_t			priv;			// privilege level
	tip_iaddr_t			iaddr;			// instruction address
	tip_context_t		_context; 		// context
	tip_time_t			_time; 			// core time
	tip_ctype_t			ctype; 			// reporting behavior for context
//	logic			    sijump;			// sequentially inferable
	tip_iretire_t		iretire;		// number of instructions / halfwords retired in this block
	tip_ilastsize_t		ilastsize; 		// size of the retired instruction
	tip_impdef_t		impdef; 		// implementation defined sideband signals
//	logic [1:0]			trigger;		// trigger
//	logic				hart_halted;	// hart is halted
//	logic				hart_reset;		// hart is in reset
//	logic				hart_stall;		// stall request to hart

	// data trace
	logic 										dretire;		// data access retired
	tip_dtype_e									dtype;			// data access type
	tip_daddr_t									daddr;			// data access address
	tip_dsize_t									dsize;			// data access size is 2^dsize bytes
	tip_data_t									data;			// data (legacy: unused in split-load mode)
//	logic [IADDR_LSBS_WIDTH-1:0]		iaddr_lsbs;		// LSBs of the data access instruction address
//	logic [TIP_DBLOCK_WIDTH-1:0]		dblock;			// instruction block in which the data access instruction is retired
//	logic [TIP_LRID_WIDTH-1:0]			lrid;			// load request ID
//	logic [TIP_LRID_WIDTH-1:0]			lid;			// split load ID
	// split-load data flow (H2E v1.1 / TGC5C AXI4)
	logic [TIP_SDATA_WIDTH-1:0]				sdata;			// store data (valid at dretire for STORE)
	logic [TIP_LRESP_WIDTH-1:0]				lresp;			// load response: 2=OK, 3=error (valid when lresp[1]=1)
	logic [TIP_LDATA_WIDTH-1:0]				ldata;			// load data (valid when lresp[1]=1)

	modport master (
		output 	itype, ecause, tval, priv, iaddr, _context, _time, ctype, iretire, ilastsize, impdef,
				dretire, dtype, daddr, dsize, data, sdata, lresp, ldata
	);

	modport slave (
		input	itype, ecause, tval, priv, iaddr, _context, _time, ctype, iretire, ilastsize, impdef,
				dretire, dtype, daddr, dsize, data, sdata, lresp, ldata
	);

endinterface // tip_if
