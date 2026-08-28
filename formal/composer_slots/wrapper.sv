// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief   Formal wrapper for the eTIP slot bound of
 *          ct_L23_preproc_composer_etip (P-SLOT-1).
 *
 * @details
 *   The composer allocates the eTIP slots of ONE tip beat by incrementing
 *   `msg_id_next` at thirteen independent allocation sites and writing
 *   `etip_msg_next[msg_id_next]`. The array has ETIP_PAR_MSG entries, so an
 *   out-of-range index writes NOWHERE -- an exceeded bound loses messages
 *   SILENTLY. `ct_pkg::ETIP_PAR_MSG` is a closed-form sum over the feature
 *   switches; the P4 re-audit (finding B-1) showed that the sum is an
 *   ARGUMENT, not a proof, and named three allocation sources that no term
 *   of it accounts for.
 *
 *   This gate turns the argument into a proof. The property under test is
 *   the DUT's OWN immediate assertion at the allocation site,
 *
 *       a_p4_slot_bound: assert (msg_id_next <= ETIP_PAR_MSG)
 *
 *   checked over the real module with a FREE environment: every tip beat,
 *   every sync verdict, every ACT-ST command, every CSR value and every
 *   qualifier hit the solver can construct. Nothing is assumed about which
 *   of them may coincide -- that is exactly the question.
 *
 *   Assumption budget (each justified in formal/README.md):
 *     ASM-SLOT-1: reset is asserted in the very first cycle (the module's
 *                 registers carry SystemVerilog initialisers, which yosys
 *                 does not honour in a formal build).
 *   Everything else is FREE, including the CSR view: the CSR programming
 *   contract (quasi-static while Enable=1) is deliberately NOT assumed, so
 *   the proof also covers a mid-stream reprogramming.
 *
 *   Observation: NONE. The property lives inside the DUT; the wrapper adds
 *   no probe, so the cross-module-reference trap of formal/README.md cannot
 *   apply here.
 *
 *   The two SPLIT_DATA_ACCESS configurations are separate tops, both in the
 *   same run: f_slots0 (dretire-combined, the shipped default) and
 *   f_slots1 (split load/store, two independent data-flow arms).
 */

`default_nettype none

// ----------------------------------------------------------------------
// One instance of the composer, driven from free inputs.
// ----------------------------------------------------------------------
module f_slot_env #(
	bit SPLIT = 0
) (
	input wire logic        clk,
	input wire logic        rst,
	// --- tip beat (free) ---
	input wire logic [3:0]  in_itype,
	input wire logic [3:0]  in_ecause,
	input wire tip_pkg::tip_iaddr_t in_tval,
	input wire logic [2:0]  in_priv,
	input wire tip_pkg::tip_iaddr_t in_iaddr,
	input wire logic [1:0]  in_context,
	input wire logic [1:0]  in_ctype,
	input wire logic        in_iretire,
	input wire logic [1:0]  in_ilastsize,
	input wire logic [7:0]  in_impdef,
	input wire logic        in_dretire,
	input wire logic [3:0]  in_dtype,
	input wire tip_pkg::tip_daddr_t in_daddr,
	input wire logic [5:0]  in_dsize,
	input wire logic [63:0] in_data,
	input wire logic [31:0] in_sdata,
	input wire logic [1:0]  in_lresp,
	input wire logic [31:0] in_ldata,
	input wire logic        in_debug_mode,
	input wire logic        in_evti,
	input wire logic        in_power_down,
	input wire logic        in_trigger,
	// --- composer environment (free) ---
	input wire logic [63:0] in_ts_value,
	input wire logic        in_inst_trace_active,
	input wire logic        in_atb_afvalid,
	input wire logic [3:0]  in_sync_reason,
	input wire logic        in_cf_hit_valid,
	input wire logic        in_cf_hit,
	input wire logic        in_cf_region_entered,
	input wire logic        in_cf_region_exited,
	input wire logic        in_df_hit_valid,
	input wire logic        in_df_hit,
	input wire logic        in_etip_ack,
	input wire logic        in_niaddr_ack,
	// --- CSR view (free; the quasi-static contract is NOT assumed) ---
	input wire logic        in_cs_enable,
	input wire logic        in_cs_inst_tracing,
	input wire logic        in_cs_context,
	input wire logic        in_cs_wide_icnt,
	input wire logic        in_cs_seq_sync,
	input wire logic        in_cs_drop_ena,
	input wire logic [1:0]  in_cs_send_config,
	input wire logic [1:0]  in_cs_send_devid,
	input wire logic [15:0] in_cs_wp_wem,
	input wire logic        in_cs_hist_clear,
	input wire logic        in_cs_maxfill_clear,
	input wire logic        in_cs_numovf_clear,
	// --- ACT-ST command (free) ---
	input wire logic        in_act_valid,
	input wire logic [5:0]  in_act_cmd,
	input wire logic [1:0]  in_act_sink,
	input wire logic [23:0] in_act_directdata,
	input wire ct_pkg::ct_act_cap_addr_t in_act_addr,
	input wire logic [31:0] in_act_data
);
	import tip_pkg::*;
	import nexus::*;
	import nexus_vendor::*;
	import ct_pkg::*;
	import ct_cs_cpuif_pkg::*;
	import ct_cs_cpuif_types_pkg::*;
	import ct_etip_pkg::*;

	// ------------------------------------------------------------------
	// Interfaces
	// ------------------------------------------------------------------
	tip_if            tip ();
	ct_act_cap_if     act_cap_st ();
	ct_sync_if        sync ();
	ct_hit_if         cf_qualifier ();
	ct_hit_if         df_qualifier ();
	ct_perfcnt_if     perfcnt ();
	ct_cs_tipclk_if   cs_tip ();
	source_if #(.T(etip_msg_struct_t),               .STOP_ON_UNDERRUN(0)) etip_q       (.clk(clk), .rst(rst));
	source_if #(.T(ct_etip_pkg::etip_next_iaddr_t),  .STOP_ON_UNDERRUN(0)) next_iaddr_q (.clk(clk), .rst(rst));

	// ------------------------------------------------------------------
	// Free stimulus
	// ------------------------------------------------------------------
	assign tip.itype      = tip_itype_e'(in_itype);
	assign tip.ecause     = tip_ecause_e'(in_ecause);
	assign tip.tval       = in_tval;
	assign tip.priv       = in_priv;
	assign tip.iaddr      = in_iaddr;
	assign tip._context   = in_context;
	assign tip._time      = '0;
	assign tip.ctype      = in_ctype;
	assign tip.iretire    = in_iretire;
	assign tip.ilastsize  = in_ilastsize;
	assign tip.impdef     = in_impdef;
	assign tip.dretire    = in_dretire;
	assign tip.dtype      = tip_dtype_e'(in_dtype);
	assign tip.daddr      = in_daddr;
	assign tip.dsize      = in_dsize;
	assign tip.data       = in_data;
	assign tip.sdata      = in_sdata;
	assign tip.lresp      = in_lresp;
	assign tip.ldata      = in_ldata;
	assign tip.debug_mode = in_debug_mode;
	assign tip.evti       = in_evti;
	assign tip.power_down = in_power_down;
	assign tip.trigger    = in_trigger;

	assign sync.reason               = nexus_sync_reason_e'(in_sync_reason);
	assign cf_qualifier.hit_valid    = in_cf_hit_valid;
	assign cf_qualifier.hit          = in_cf_hit;
	assign cf_qualifier.region_entered = in_cf_region_entered;
	assign cf_qualifier.region_exited  = in_cf_region_exited;
	assign df_qualifier.hit_valid    = in_df_hit_valid;
	assign df_qualifier.hit          = in_df_hit;
	assign df_qualifier.region_entered = 1'b0;
	assign df_qualifier.region_exited  = 1'b0;

	assign etip_q.ack       = in_etip_ack;
	assign next_iaddr_q.ack = in_niaddr_ack;

	assign act_cap_st.valid              = in_act_valid;
	assign act_cap_st.cmd.Cmd.value        = in_act_cmd;
	assign act_cap_st.cmd.Sink.value       = in_act_sink;
	assign act_cap_st.cmd.DirectData.value = in_act_directdata;
	assign act_cap_st.addr               = in_act_addr;
	assign act_cap_st.data               = in_act_data;

	assign cs_tip.trTeEnable                = in_cs_enable;
	assign cs_tip.trTeInstTracing           = in_cs_inst_tracing;
	assign cs_tip.trTeContext               = in_cs_context;
	assign cs_tip.trTeInstEnWideIcnt        = in_cs_wide_icnt;
	assign cs_tip.trTeInstSeqSyncEnable     = in_cs_seq_sync;
	assign cs_tip.trTeDataDropEna           = in_cs_drop_ena;
	assign cs_tip.trTeSendConfig            = ct_cs_cpuif__te__trTeControl__trTeSendConfigMode_e_e'(in_cs_send_config);
	assign cs_tip.trTeSendDeviceId          = ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e_e'(in_cs_send_devid);
	assign cs_tip.trWpWEM                   = in_cs_wp_wem;
	assign cs_tip.trTeTipFifoHistClear      = in_cs_hist_clear;
	assign cs_tip.trTeTipFifoMaxFillClear   = in_cs_maxfill_clear;
	assign cs_tip.trTeTipFifoNumOverflowsClear = in_cs_numovf_clear;

	// perfcnt: the composer only READS counter values (DAQ payloads) and
	// drives the *_clr_etip strobes -- values stay free, clears are outputs.
	assign perfcnt.ifetch_th_counter_value  = '0;
	assign perfcnt.data_rd_th_counter_value = '0;
	assign perfcnt.data_rd_counter_value    = '0;
	assign perfcnt.data_wr_counter_value    = '0;

	// ------------------------------------------------------------------
	// DUT
	// ------------------------------------------------------------------
	/* verilator lint_off PINMISSING */
	ct_L23_preproc_composer_etip #(.SPLIT_DATA_ACCESS(SPLIT)) dut (
		.clk                 (clk),
		.rst                 (rst),
		.ts_value            (in_ts_value),
		.act_cap_st          (act_cap_st),
		.tip                 (tip),
		.inst_trace_active_q (in_inst_trace_active),
		.atb_afvalid         (in_atb_afvalid),
		.sync                (sync),
		.cf_qualifier        (cf_qualifier),
		.df_qualifier        (df_qualifier),
		.perfcnt             (perfcnt),
		.etip_q              (etip_q),
		.next_iaddr_q        (next_iaddr_q),
		.cs_tip              (cs_tip),
		.internal_delay      ()
	);
	/* verilator lint_on PINMISSING */

	// ------------------------------------------------------------------
	// ASM-SLOT-1: reset in cycle 0.
	// ------------------------------------------------------------------
	logic Started = 1'b0;
	always_ff @(posedge clk) Started <= 1'b1;
	always_ff @(posedge clk) begin
		a_slot_rst0: assume (Started || rst);
	end

endmodule : f_slot_env


// SPLIT_DATA_ACCESS = 0 -- the shipped default (dretire-combined data flow).
module f_slots0 (
	input wire logic        clk,
	input wire logic        rst,
	input wire logic [3:0]  in_itype,
	input wire logic [3:0]  in_ecause,
	input wire tip_pkg::tip_iaddr_t in_tval,
	input wire logic [2:0]  in_priv,
	input wire tip_pkg::tip_iaddr_t in_iaddr,
	input wire logic [1:0]  in_context,
	input wire logic [1:0]  in_ctype,
	input wire logic        in_iretire,
	input wire logic [1:0]  in_ilastsize,
	input wire logic [7:0]  in_impdef,
	input wire logic        in_dretire,
	input wire logic [3:0]  in_dtype,
	input wire tip_pkg::tip_daddr_t in_daddr,
	input wire logic [5:0]  in_dsize,
	input wire logic [63:0] in_data,
	input wire logic [31:0] in_sdata,
	input wire logic [1:0]  in_lresp,
	input wire logic [31:0] in_ldata,
	input wire logic        in_debug_mode,
	input wire logic        in_evti,
	input wire logic        in_power_down,
	input wire logic        in_trigger,
	input wire logic [63:0] in_ts_value,
	input wire logic        in_inst_trace_active,
	input wire logic        in_atb_afvalid,
	input wire logic [3:0]  in_sync_reason,
	input wire logic        in_cf_hit_valid,
	input wire logic        in_cf_hit,
	input wire logic        in_cf_region_entered,
	input wire logic        in_cf_region_exited,
	input wire logic        in_df_hit_valid,
	input wire logic        in_df_hit,
	input wire logic        in_etip_ack,
	input wire logic        in_niaddr_ack,
	input wire logic        in_cs_enable,
	input wire logic        in_cs_inst_tracing,
	input wire logic        in_cs_context,
	input wire logic        in_cs_wide_icnt,
	input wire logic        in_cs_seq_sync,
	input wire logic        in_cs_drop_ena,
	input wire logic [1:0]  in_cs_send_config,
	input wire logic [1:0]  in_cs_send_devid,
	input wire logic [15:0] in_cs_wp_wem,
	input wire logic        in_cs_hist_clear,
	input wire logic        in_cs_maxfill_clear,
	input wire logic        in_cs_numovf_clear,
	input wire logic        in_act_valid,
	input wire logic [5:0]  in_act_cmd,
	input wire logic [1:0]  in_act_sink,
	input wire logic [23:0] in_act_directdata,
	input wire ct_pkg::ct_act_cap_addr_t in_act_addr,
	input wire logic [31:0] in_act_data
);
	f_slot_env #(.SPLIT(0)) env (.*);
endmodule : f_slots0


// SPLIT_DATA_ACCESS = 1 -- store at dretire, load at lresp (two data-flow arms).
module f_slots1 (
	input wire logic        clk,
	input wire logic        rst,
	input wire logic [3:0]  in_itype,
	input wire logic [3:0]  in_ecause,
	input wire tip_pkg::tip_iaddr_t in_tval,
	input wire logic [2:0]  in_priv,
	input wire tip_pkg::tip_iaddr_t in_iaddr,
	input wire logic [1:0]  in_context,
	input wire logic [1:0]  in_ctype,
	input wire logic        in_iretire,
	input wire logic [1:0]  in_ilastsize,
	input wire logic [7:0]  in_impdef,
	input wire logic        in_dretire,
	input wire logic [3:0]  in_dtype,
	input wire tip_pkg::tip_daddr_t in_daddr,
	input wire logic [5:0]  in_dsize,
	input wire logic [63:0] in_data,
	input wire logic [31:0] in_sdata,
	input wire logic [1:0]  in_lresp,
	input wire logic [31:0] in_ldata,
	input wire logic        in_debug_mode,
	input wire logic        in_evti,
	input wire logic        in_power_down,
	input wire logic        in_trigger,
	input wire logic [63:0] in_ts_value,
	input wire logic        in_inst_trace_active,
	input wire logic        in_atb_afvalid,
	input wire logic [3:0]  in_sync_reason,
	input wire logic        in_cf_hit_valid,
	input wire logic        in_cf_hit,
	input wire logic        in_cf_region_entered,
	input wire logic        in_cf_region_exited,
	input wire logic        in_df_hit_valid,
	input wire logic        in_df_hit,
	input wire logic        in_etip_ack,
	input wire logic        in_niaddr_ack,
	input wire logic        in_cs_enable,
	input wire logic        in_cs_inst_tracing,
	input wire logic        in_cs_context,
	input wire logic        in_cs_wide_icnt,
	input wire logic        in_cs_seq_sync,
	input wire logic        in_cs_drop_ena,
	input wire logic [1:0]  in_cs_send_config,
	input wire logic [1:0]  in_cs_send_devid,
	input wire logic [15:0] in_cs_wp_wem,
	input wire logic        in_cs_hist_clear,
	input wire logic        in_cs_maxfill_clear,
	input wire logic        in_cs_numovf_clear,
	input wire logic        in_act_valid,
	input wire logic [5:0]  in_act_cmd,
	input wire logic [1:0]  in_act_sink,
	input wire logic [23:0] in_act_directdata,
	input wire ct_pkg::ct_act_cap_addr_t in_act_addr,
	input wire logic [31:0] in_act_data
);
	f_slot_env #(.SPLIT(1)) env (.*);
endmodule : f_slots1

`default_nettype wire
