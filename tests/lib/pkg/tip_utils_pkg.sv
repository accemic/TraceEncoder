// SPDX-FileCopyrightText: 2023 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    TIP (Trace Ingress Port) Utilty Package
 *
 * @notes    tip_utils_pkg hosts all interface-dependent helper tasks so that
 *           tip_pkg remains type-only and tip_if remains the sole interface definition,
 *           thereby breaking the tip_pkg ↔ tip_if circular compile dependency
 */

package tip_utils_pkg;

	import tip_pkg::*;

	// ---------------------------------------------------------------
	// Helper for simulation
	// ---------------------------------------------------------------

	task automatic TipIfSetDefault(
		virtual tip_if.master   tip,
		ref     logic           clk,
		input   int             delay_cycles);
		tip._time       <= '0;
		tip.itype       <= OTHER;
		tip.ecause      <= ECAUSE_NONE;
		tip.tval        <= '0;
		tip.priv        <= '0;
		tip.iaddr       <= TIP_DEFAULT_IADDR;
		tip._context    <= TIP_DEFAULT_CONTEXT;
		tip.ctype       <= UNREPORTED;
		tip.iretire     <= '0;
		tip.impdef      <= '0;
		tip.ilastsize   <= TIP_DEFAULT_ILASTSIZE;
		tip.dtype       <= LOAD;
		tip.dretire     <= '0;
		tip.daddr       <= TIP_DEFAULT_DADDR;
		tip.dsize       <= '0;
		tip.data        <= TIP_DEFAULT_DATA;
		tip.sdata       <= '0;
		tip.lresp       <= '0;
		tip.ldata       <= '0;
		tip.debug_mode  <= '0;
		tip.evti        <= '0;
		tip.power_down  <= '0;
		tip.trigger     <= '0;

		repeat (delay_cycles+1) @(posedge clk);
	endtask

	task automatic TipTSetDefault(output tip_t tipt);
		tipt._time       = '0;
		tipt.itype       = OTHER;
		tipt.ecause      = ECAUSE_NONE;
		tipt.tval        = '0;
		tipt.priv        = '0;
		tipt.iaddr       = TIP_DEFAULT_IADDR;
		tipt._context    = TIP_DEFAULT_CONTEXT;
		tipt.ctype       = UNREPORTED;
		tipt.iretire     = '0;
		tipt.impdef      = '0;
		tipt.ilastsize   = TIP_DEFAULT_ILASTSIZE;
		tipt.dtype       = LOAD;
		tipt.dretire     = '0;
		tipt.daddr       = TIP_DEFAULT_DADDR;
		tipt.dsize       = '0;
		tipt.data        = TIP_DEFAULT_DATA;
		tipt.sdata       = '0;
		tipt.lresp       = '0;
		tipt.ldata       = '0;
		tipt.debug_mode  = '0;
		tipt.evti        = '0;
		tipt.power_down  = '0;
		tipt.trigger     = '0;
	endtask

	task automatic TipSendMsg (
		virtual tip_if.master   tip,
		ref     logic           clk,
		input   tip_t           tipt,
		input int               delay_cycles);
		@(posedge clk);
		tip.itype       <= tipt.itype;
		tip.ecause      <= tipt.ecause;
		tip.tval        <= tipt.tval;
		tip.priv        <= tipt.priv;
		tip.iaddr       <= tipt.iaddr;
		tip._context    <= tipt._context;
		tip.ctype       <= tipt.ctype;
		tip.iretire     <= tipt.iretire;
		tip.impdef      <= tipt.impdef;
		tip.ilastsize   <= tipt.ilastsize;
		tip.dtype       <= tipt.dtype;
		tip.dretire     <= tipt.dretire;
		tip.daddr       <= tipt.daddr;
		tip.dsize       <= tipt.dsize;
		tip.data        <= tipt.data;
		tip.sdata       <= tipt.sdata;
		tip.lresp       <= tipt.lresp;
		tip.ldata       <= tipt.ldata;
		tip.debug_mode  <= tipt.debug_mode;
		tip.evti        <= tipt.evti;
		tip.power_down  <= tipt.power_down;
		tip.trigger     <= tipt.trigger;
		@(posedge clk);
		TipIfSetDefault (tip, clk, delay_cycles);
	endtask

endpackage

`default_nettype wire
