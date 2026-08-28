// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * Address: Kiefersfelden, Germany
 *
 * @file    ct_L23_preproc_act_st.sv
 * @brief   Preprocessing stage for ACT‑ST (Smart Trigger) events.
 *
 * @details
 *   The ACT‑ST (Accemic CEDARtools Smart Trigger) extends ACT‑CAP by generating
 *   *virtual HSI operations* when preconfigured runtime events occur in the
 *   instruction stream, without CPU involvement.
 *
 *   Supported trigger conditions:
 *     - Match of a specific retired instruction address.
 *     - Match of a configured interrupt ID.
 *
 *   On trigger, a pre‑stored command word is fetched from control/status
 *   registers and emitted as if it were an ACT‑CAP CSR write by the CPU.
 *
 *   This module performs:
 *     - Runtime comparison of retired instruction addresses against an array of
 *       key addresses (`vector_binary_search`).
 *     - Fetching of the associated preconfigured command when a match occurs.
 *     - Injection of the command into a pipeline of configurable depth
 *       (EXTRA_DELAY).
 *     - Delivery of valid/command pairs via the act_st output in ACT‑CAP format.
 *
 * @tparam EXTRA_DELAY      Optional pipeline depth extension.
 *
 * @ports
 *   clk                Trace input clock.
 *   rst                Synchronous reset.
 *   tip                TIP interface from CPU (retired instruction stream).
 *   act_st             ACT‑ST master interface (emitted commands in ACT‑CAP format).
 *   cs_tip             Control/status interface providing trigger addresses and
 *                      associated command data.
 *   internal_delay     Base internal latency of the module, including vector_binary_search
 *
 * @notes
 *   - Multiple trigger reference addresses can be monitored in parallel.
 *   - Commands emitted are format‑compatible with downstream ACT‑CAP decoding.
 *   - Reset clears all pipeline stages.
 *   - The vector_match_checker contributes to the fixed INTERNAL_DELAY=2.
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

module ct_L23_preproc_act_st #(
	int DIM = 4
)(
	input uwire logic     clk,            // trace input clock
	input uwire logic     rst,            // reset
	tip_if.slave          tip,            // TIP from CPU
	ct_act_cap_if.master  act_st,
	ct_cs_tipclk_if.slave cs_tip,         // control / status interface
	input uwire logic     wext_clk,
	ocram_write_if.impl   wext,           // vector_binary_search memory config
	output delay_t        internal_delay, // delay of this component including all submodules
	input uwire delay_t   extra_delay     // extra delay to be added for syncronizing preproc modules
);

	localparam type   R             = logic [CSR_CT_ACT_CAP_WIDTH-1:0];
	localparam string SEARCH_MODE   = "VALUE";

	// ----------------------------------------------------------------
	// Elaboration budget guard (C0b): the ACT-ST chain is a CONSTANT,
	// 1 + vbs(4*DIM-1) = 4*DIM cycles. Check it against the alignment
	// budget HERE, where both sides are elaboration constants -- the
	// downstream $fatal in ct_L23_preproc compares module-port wires and
	// is only a simulation-time net. The undeclared-module poison keeps
	// the violation fatal on backends that demote $fatal to a warning
	// (Verilator under abc's blanket -Wno-fatal, C0a audit B-1).
	// ----------------------------------------------------------------
	localparam int ACT_ST_CHAIN_DELAY = 4*DIM; // 1 + (4*DIM - 1)
	if (ACT_ST_CHAIN_DELAY > EXTRA_DELAY_MAX) begin : genActStBudgetGuard
		$fatal(1, "ct_L23_preproc_act_st: chain delay %0d (= 4*DIM) exceeds EXTRA_DELAY_MAX=%0d -- raise PREPROC_DELAY_MAX with M0_DIM", ACT_ST_CHAIN_DELAY, EXTRA_DELAY_MAX);
		ct_elab_guard_violation poison ();
	end

	logic           hit, hit_valid;
	R               hit_value;

	logic   [EXTRA_DELAY_MAX:0]          ValidPipe;
	ct_cs_cpuif__trActCapStCmd__out_t    CmdPipe [EXTRA_DELAY_MAX:0] ;
	logic                                valid;
	delay_t                              vbs_delay;

	// Instantiate DUT
	vector_binary_search_2clk #(
		.K          (tip_iaddr_t),
		.R          (R),
		.DIM        (DIM),
		.SEARCH_MODE(SEARCH_MODE),
		.INTERNAL_DELAY_WIDTH($bits(delay_t)))
	vector_binary_search_inst (
		.wr_clk (wext_clk),
		.rd_clk (clk),
		.rst,
		// TipBeatRetires: the port is one bit, tip.iretire is not at a block
		// ingress width -- a bare connection would keep the LSB only.
		.valid   (TipBeatRetires(tip.iretire)),
		.data_in (tip.iaddr),
		.wext,
		.hit_valid,
		.hit,
		.hit_value,
		.internal_delay(vbs_delay)
	);

	// Unpack the watchpoints memory Cmd word using the RDL bit layout of
	// trActCapStCmd @ 0x0B10, so a watchpoint entry and a direct CSR 0xB10
	// write decode identically. A raw struct cast here previously produced
	// the struct's declaration order (Cmd at MSB), which silently
	// disagreed with the RDL and left all watchpoint-armed commands as
	// ACT_CAP_ST_NONE on SW that followed the RDL.
	function automatic ct_cs_cpuif__trActCapStCmd__out_t unpack_act_st_cmd(logic [CSR_CT_ACT_CAP_WIDTH-1:0] word);
		ct_cs_cpuif__trActCapStCmd__out_t cmd;
		cmd = '{default:'0};
		cmd.Cmd.value        = word[5:0];
		cmd.Sink.value       = word[7:6];
		cmd.DirectData.value = word[31:8];
		return cmd;
	endfunction

	always_ff @(posedge clk)begin
		if (rst) begin
			// Clear pipe
			ValidPipe <= '0;
		end
		else begin
			ValidPipe[0] <= '0;
			if (hit) begin
				ValidPipe[0] <= '1;
				CmdPipe  [0] <= unpack_act_st_cmd(hit_value);
			end
			// shift through remaining stages
			for (int idx = 1; idx <= EXTRA_DELAY_MAX; idx++) begin
				ValidPipe[idx] <= ValidPipe[idx-1];
				CmdPipe  [idx] <= CmdPipe  [idx-1];
			end
		end
	end

	// Output is at the tail of the pipeline
	assign act_st.valid = ValidPipe[extra_delay];
	assign act_st.cmd   = CmdPipe  [extra_delay];

	assign internal_delay = delay_t'(1 + vbs_delay);

endmodule // ct_L23_preproc_act_st

`undef MY_MARK_DEBUG
`undef MY_DEBUG
`default_nettype wire
