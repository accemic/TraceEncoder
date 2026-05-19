// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
*
* @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
*
* @brief    C-Trace Encoder for RISC-V
*
* @details
*   Emits NEXUS-compliant trace messages following the RISC-V N-Trace
*   specification (see https://github.com/riscv-non-isa/tg-nexus-trace).
*
*   The control/status register layout accessed via the Wishbone port is
*   defined in modules/ctrace/rdl/ct_cs_cpuif.rdl.
*
*   The module spans five clock domains (tip_clk, proc_clk, atb_atclk,
*   wb_clk, wall_clk); per-port frequency guidance is documented at the
*   port list below. The integrator is responsible for sizing each clock
*   domain to meet the stated ratios so that no CDC FIFO overflows under
*   worst-case TIP activity.
*/

module ct_encoder #(
	// Select split-load data trace path (H2E v1.1 / TGC5C AXI4).
	// 0 = legacy dretire-combined mode (tip.data at retirement)
	// 1 = split-load mode (tip.sdata for STOREs; tip.lresp/ldata for LOADs)
	bit SPLIT_DATA_ACCESS = 0
) (
	// TIP (Trace Ingress Port; CPU-side trace input)
	input uwire logic   tip_clk,
	input uwire logic   tip_rst,
	tip_if.slave        tip,

	// Wishbone (CSR access) + CSR shim reset
	input uwire logic   wb_clk,
	input uwire logic   wb_rst,
	wb_if.slave         wb,
	input uwire logic   ct_cs_rst,

	// AXIS
	axis_if.master      axis,

	// ATB (Nexus trace output)
	// Rule of thumb: atb_atclk >= 2 * tip_clk, sized to peak message byte rate.
	input uwire logic   atb_atclk,
	input uwire logic   atb_atresetn,
	atb_if.master       atb,

	// Processing clock (internal pipeline)
	// Rule of thumb: proc_clk >= 3 * tip_clk
	input uwire logic   proc_clk,
	input uwire logic   proc_rst,

	// Wall clock (free-running timestamp reference)
	input uwire logic   wall_clk,
	input uwire logic   wall_clk_rst
);

	import nexus_vendor::*;
	import nexus::*;
	import tip_pkg::*;
	import ct_etip_pkg::*;
	import ct_pkg::*;

	// ------------------------------------------------------------------
	// Global cross-stage interfaces and signals
	// ------------------------------------------------------------------
	// CSR interfaces driven by ct_cs_cpuif_wb, consumed by every stage.
	ct_cs_tipclk_if  cs_tip ();
	ct_cs_procclk_if cs_proc();
	ct_cs_atbclk_if  cs_atb ();
	ct_cs_decclk_if  cs_dec ();

	// Reverse-flow signals (driver is downstream of the consumer, so they
	// live up here rather than next to their drivers).
	//   - synq_req_trace_byte_count: mseo_mdo_formatter -> preproc,
	//     periodic-sync arbitration
	//   - nexus_formatter_ready:     nexus_formatter   -> msg_gen, backpressure
	//   - mseo_mdo_formatter_ready:  mseo_mdo_formatter -> nexus_formatter, backpressure
	uwire logic synq_req_trace_byte_count;
	uwire logic nexus_formatter_ready;
	uwire logic mseo_mdo_formatter_ready;

	// ------------------------------------------------------------------
	// CSR shim (Wishbone -> cs_*/wext interfaces)
	// ------------------------------------------------------------------
	ocram_write_if #(.A_BITS(M0_STAGES), .T(m0_kr_t)) act_st_wext   (wb_clk);
	ocram_write_if #(.A_BITS(M1_STAGES), .T(m1_kr_t)) df_range_wext (wb_clk);

	ct_cs_cpuif_wb ct_cs_cpuif_wb_inst (
		.wb_clk,   .wb_rst,   .wb,
		.ct_cs_rst,
		.tip_clk,  .tip_rst,
		.proc_clk, .proc_rst,
		.cs_tip,
		.act_st_wext,
		.df_range_wext,
		.cs_proc,  .cs_atb,   .cs_dec
	);

	// ------------------------------------------------------------------
	// Preprocessor (drives etip_q, next_iaddr_q, internal_delay_preproc)
	// ------------------------------------------------------------------
	source_if #(.T(etip_msg_struct_t), .STOP_ON_UNDERRUN(1)) etip_q       (.clk(proc_clk), .rst(proc_rst));
	source_if #(.T(tip_iaddr_t),       .STOP_ON_UNDERRUN(1)) next_iaddr_q (.clk(proc_clk), .rst(proc_rst));

	// TODO: internal_delay_preproc is driven by ct_L23_preproc but not consumed
	// anywhere.
	delay_t internal_delay_preproc;

	ct_L23_preproc #(.SPLIT_DATA_ACCESS(SPLIT_DATA_ACCESS))
	preproc_inst (
		.tip_clk,   .tip_rst,      .tip,
		.wall_clk,  .wall_clk_rst,
		.axis,
		.etip_q,
		.next_iaddr_q,
		.atb_afvalid (atb.afvalid),
		.atb_syncreq (atb.syncreq),
		.synq_req_trace_byte_count,
		.cs_tip,
		.wext_clk       (wb_clk),
		.act_st_wext,
		.df_range_wext,
		.internal_delay (internal_delay_preproc)
 );

	// ------------------------------------------------------------------
	// Message generator (drives trace_msg)
	// ------------------------------------------------------------------
	uwire nexus_msg_struct_t trace_msg;

	ct_L2_msg_gen msg_gen_inst (
		.proc_clk, .proc_rst,
		.ready_in(nexus_formatter_ready),
		.cs_proc,
		.etip_q,
		.next_iaddr_q,
		.trace_msg
	);

	// ------------------------------------------------------------------
	// Nexus formatter (drives nexus_msg; nexus_formatter_ready declared above)
	// ------------------------------------------------------------------
	uwire nexus_message_t nexus_msg;

	ct_L2_nexus_formatter nexus_formatter_inst (
		.proc_clk, .proc_rst,
		.ready_in  (mseo_mdo_formatter_ready),
		.ready_out (nexus_formatter_ready),
		.cs_proc,
		.trace_msg,					// generic trace msg input
		.nexus_msg					// nexus msg output
	);

	// ------------------------------------------------------------------
	// MSEO/MDO formatter
	//   - drives mseo_mdo_formatter_ready + synq_req_trace_byte_count (declared above)
	// ------------------------------------------------------------------
	ct_L2_mseo_mdo_formatter #(
		.NEXUS_MAX_FIELDS           (NEXUS_MAX_FIELDS),
		.NEXUS_MAX_FIELD_DATA_WIDTH (NEXUS_MAX_FIELD_DATA_WIDTH),
		.MDO_WIDTH                  (NEXUS_MDO_WIDTH)
	) ct_L2_mseo_mdo_formatter_inst (
		.proc_clk,   .proc_rst,
		.nexus_msg,
		.atb_atclk,  .atb_atresetn,  .atb,
		.cs_proc,    .cs_atb,
		.synq_req_trace_byte_count,
		.ready_out(mseo_mdo_formatter_ready)
	);

endmodule // ct_encoder

`default_nettype wire
