// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * Address: Kiefersfelden, Germany
 *
 * @file    ct_L23_preproc_act_cap.sv
 * @brief   Preprocessing stage for ACT‑CAP (CSR Access Protocol) commands.
 *
 * @description
 *   The ACT‑CAP (Accemic C‑Trace CSR Access Protocol) allows the trace encoder
 *   to transparently observe CPU write accesses to designated virtual CSR
 *   registers via the Trace Ingress Port (TIP). This is achieved without CPU
 *   modifications, since CSR writes are treated as functional NOPs with no
 *   system bus side effects.
 *
 *   To support access to many virtual control registers, ACT‑CAP implements a
 *   two‑stage access method:
 *     1. A target register index is written to a dedicated selector CSR.
 *     2. The selected register is then written via a second CSR access.
 *
 *   This module acts as a preprocessing unit:
 *     - Monitors retired TIP transactions for CSR writes to ACT‑CAP CSRs.
 *     - Extracts command values from CSR write data.
 *     - Feeds them into a configurable pipeline (EXTRA_DELAY).
 *     - Exposes valid/command/address on the act_cap interface for subsequent
 *       trace encoder modules.
 *
 * @tparam EXTRA_DELAY  Pipeline depth extension (shifts outputs).
 *
 * @ports
 *   clk                Trace input clock.
 *   rst                Synchronous reset.
 *   tip                TIP interface from CPU (retired data stream).
 *   act_cap            ACT‑CAP master interface providing decoded commands.
 *   cs_tip             Control/status interface (TIP clock domain).
 *   internal_delay     Base internal latency of the module (=1).
 *
 * @notes
 *   - Reset clears the entire pipeline to prevent spurious outputs.
 *   - CSR writes to non‑ACT‑CAP addresses are ignored.
 *   - Output is aligned to the tail of the pipeline (EXTRA_DELAY cycles).
 *   - TODO: check implementation of mcontrol CSR (0x7a1) support
 */

`undef  MY_DEBUG
`ifdef  MY_DEBUG
`define MY_MARK_DEBUG (* MARK_DEBUG = "TRUE" *)
`else
`define MY_MARK_DEBUG
`endif

import tip_pkg::*;
import ct_pkg::*;
import nexus_vendor::*;
import ct_cs_cpuif_pkg::*;
import ct_cs_cpuif_types_pkg::*;

module ct_L23_preproc_act_cap (
	input uwire logic           clk,                    // trace input clock
	input uwire logic           rst,                    // reset
	tip_if.slave                tip,                    // TIP from CPU
	ct_act_cap_if.master        act_cap,
	ct_cs_tipclk_if.slave       cs_tip,                 // control / status interface
	output delay_t              internal_delay,         // delay of this component including all submodules
	input uwire delay_t         extra_delay             // extra delay to be added for syncronizing preproc modules
);

	logic                           [EXTRA_DELAY_MAX:0] ValidPipe = '0;
	ct_cs_cpuif__trActCapStCmd__out_t                   CmdPipe [EXTRA_DELAY_MAX:0] ;

	always_ff @(posedge clk) begin
		if (rst) begin
			ValidPipe <= '0;
		end
		else begin
			ValidPipe[0] <= '0;
			if (tip.dretire && (tip.dtype == CSR_READ_WRITE)) begin
				if (tip.daddr == ACT_CAP_CMD) begin
					ValidPipe[0] <= 1;
					// The command payload is transferred via TIP data with byte-wise
					// streaming semantics (see tip_pkg::cmd_to_tip_data / tip_data_to_cmd).
					CmdPipe  [0] <= tip_data_to_cmd(tip.data);
				end
			end
			// shift through remaining stages
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				ValidPipe[idx] <= ValidPipe[idx-1];
				CmdPipe  [idx] <= CmdPipe  [idx-1];
			end
		end
	end

	assign act_cap.valid    = ValidPipe[extra_delay];
	assign act_cap.cmd      = CmdPipe  [extra_delay];

	assign internal_delay   = 1;

endmodule // ct_L23_preproc_act_cap

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
