// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief   Formal wrapper for ct_L2_nexus_formatter (P-FMT-1..5, P3 DF
 *          address compression / TCODE 13-14 re-anchor contract).
 *
 * @details
 *   The formatter is a single registered field-table stage (no FIFO, no
 *   CDC), so the whole DF-compression state machine (RefDaddr, DfReanchor,
 *   the 13/14 TCODE substitution) is proven directly. The generic trace
 *   message input is abstracted to small tokens (msg_gen wrapper pattern):
 *   only tcode / sub_type / ts / DF address feed the properties, the rest
 *   of the packed union payload never gates the DF control flow under test.
 *
 *   Assumption budget (each justified below / in formal/README.md):
 *     ASM-FMT-1: initial reset in cycle 0.
 *     ASM-FMT-2: sub_type is a legal enum value (0..4).
 *     ASM-FMT-3: msg_gen never selects TCODE 13/14 -- the sync upgrade is
 *                the formatter's OWN job (TCODE substitution at emission;
 *                verified msg_gen contract: no 13/14 arm exists there).
 *     ASM-FMT-4: DataAddrCompress / InhibitSrc / TsEnable are quasi-static
 *                (CSR programming contract: writable only while
 *                trTeControl.Enable = 0). trTeDataTracing is deliberately
 *                FREE per cycle -- its edges are the T2(b) trigger under
 *                test, including edges during a ready_in stall.
 *
 *   MODEL BOUNDARY -- sv2v packed-struct-literal limitation (found via CEX
 *   bit forensics 2026-08-04): sv2v converts the formatter's positional
 *   field literals `'{TCODE, FIXED, tcode, 6}` into UNPADDED concats
 *   ({9'h00c, 6-bit enum, 32-bit int} = 47 bits, left-zero-padded into the
 *   210-bit field slot), so every NexusMsg FIELD WRITE sits at wrong bit
 *   offsets in the formal model -- the model's output register does NOT
 *   represent the RTL. All properties therefore bind to the DF-compression
 *   STATE (RefDaddr / DfReanchor, plain assignments, converted correctly)
 *   and to the combinational DECISION nets (df_sync_now / df_sync_tcode /
 *   daddr_xor). The on-wire field/TCODE layer is covered by the simulation
 *   gates instead (scripts/cli_dfcompress_test.sh: exact TCODE sequence,
 *   full decode round-trip, no-13/14-in-FULL greps).
 *
 *   Properties (gate wording from PLAN P3 / handoffs/P3.md step 5):
 *     P-FMT-1 (13/14 anchor): after every emitted 13/14 upgrade the DF
 *             reference equals the transmitted FULL address (the upgrade
 *             transmits df_daq.addr_idtag), and the upgrade decision
 *             carries the 5/6 direction (write->13, read->14).
 *     P-FMT-2 (reference upkeep): RefDaddr advances ONLY on an emission
 *             beat (ready_in && DF && compress mode) -- never on a stall,
 *             never on a non-DF message, never in FULL mode -- and a DF
 *             emission re-seats it on exactly the offered address.
 *     P-FMT-3 (OFF-mode neutrality): with DataAddrCompress = FULL the
 *             13/14 upgrade decision can never fire.
 *     P-FMT-4 (sticky re-anchor, T2): a contract-side mirror of the
 *             re-anchor obligation (set on sync/ERROR emission and on the
 *             DataTracing rising edge, consumed by a DF emission) must
 *             equal the RTL's DfReanchor at all times, and a DF emission
 *             under an outstanding obligation fires the upgrade decision.
 *     P-FMT-5 (XOR correctness): in XOR mode the emitted delta is
 *             daddr ^ RefDaddr (the reference the decoder also holds).
 *
 *   Probe-canary discipline (formal/README.md "Tool traps"): f_canary
 *   cross-checks a probed net against a wrapper-recomputed twin -- an
 *   unbound `dut.` reference would fail it immediately.
 *
 *   Mutation falsifiability (run_red.sh): M-A (the emission gate is lost on
 *   the whole reference/flag update) lands in the reference family OR in
 *   its contract mirror -- the solver may re-seat RefDaddr on its own value
 *   and then only A_fmt4_pend_mirror sees the lost gate; M-B (sticky
 *   re-anchor removed) lands in the sticky family (A_fmt4_..); M-C (the
 *   gate is lost on the RefDaddr assignment ALONE, mirror intact) pins the
 *   reference family (A_fmt2_.., p_ref_q/p_daddr_q) on its own. The red
 *   runs map every failing line back to the property source.
 */

`default_nettype none

module f_fmt_check (
	input wire logic                                                       clk,
	input wire logic                                                       rst,
	// downstream flow control
	input wire logic                                                       in_ready,
	// abstracted generic trace message
	input wire ct_pkg::ct_sub_type_e                                       in_sub_type,
	input wire nexus::nexus_tcode_e                                        in_tcode,
	input wire logic [7:0]                                                 in_ts,
	input wire tip_pkg::tip_daddr_t                                        in_daddr,
	input wire logic [7:0]                                                 in_ddata,
	// CSR view
	input wire logic                                                       in_inhibit_src,
	input wire ct_cs_cpuif_pkg::ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e_e in_daddr_compress,
	input wire logic                                                       in_data_tracing,
	input wire logic                                                       in_ts_enable
);
	import ct_pkg::*;
	import tip_pkg::*;
	import nexus::*;
	import nexus_vendor::*;
	import ct_cs_cpuif_pkg::*;

	localparam ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e_e
		DADDR_FULL = ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e__DTR_ADDR_FULL;

	// ------------------------------------------------------------------
	// Interface + abstracted trace message + DUT
	// ------------------------------------------------------------------
	ct_cs_procclk_if cs ();

	nexus_df_daq_msg_struct_t f_df;
	nexus_msg_struct_t        f_msg;
	always_comb begin
		f_df            = '0;
		f_df.addr_idtag = in_daddr;
		f_df.data       = NEXUS_MSG_DATA_WIDTH'(in_ddata);
		f_msg           = '0;
		f_msg.sub_type  = in_sub_type;
		f_msg.tcode     = in_tcode;
		f_msg.ts        = nexus_ts_t'(in_ts);
		// Packed union: CF/ERR/OTHER views reinterpret the same DF bits --
		// payload content never gates the DF control flow under test.
		f_msg.sub.df_daq = f_df;
	end

	// Free/constant CSR view. The constants only feed the config-message
	// payload arms (TCODE 58) -- not part of the properties.
	assign cs.trTeInhibitSrc             = in_inhibit_src;
	assign cs.trTeDataAddrCompress       = in_daddr_compress;
	assign cs.trTeDataTracing            = in_data_tracing;
	assign cs.trTsEnable                 = in_ts_enable;
	assign cs.trTeInstMode               = ct_cs_cpuif__te__trTeControl__trTeInstMode_e_e'(0);
	assign cs.trTeInstSyncMode           = ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e_e'(0);
	assign cs.trTeInstSyncMax            = '0;
	assign cs.trTeContext                = 1'b0;
	assign cs.trTeSrcID                  = '0;
	assign cs.trTeSrcBits                = 4'd0;
	assign cs.trTeInstEnImplicitReturn   = 1'b0;
	assign cs.trTeInstEnBranchPrediction = 1'b0;
	assign cs.trTeInstEnRepeatedHistory  = 1'b0;
	assign cs.trTeInstEnRepeatBranch     = 1'b0;
	assign cs.trTeInstEnJumpTargetCache  = 1'b0;
	assign cs.trTeInstEnWideIcnt         = 1'b0;
	assign cs.trTeInstEnIbhs             = 1'b0;
	assign cs.trTeInstEnRepeatInstr      = 1'b0;
	assign cs.trTeInstTrigEnable         = 1'b0;
	assign cs.trTeInstSeqSyncEnable      = 1'b0;
	// P4 status-message controls: the properties here are about the DF/CF
	// field layout, and the two new messages (TCODE 1/15) carry a single
	// payload field each with no address or ICNT semantics -- tie them off
	// like every other config input that is not part of the proof.
	assign cs.trTeSendDeviceId           = ct_cs_cpuif__te__trTeControl__trTeSendDeviceIdMode_e_e'(0);
	assign cs.trWpWEM                    = 16'd0;
	assign cs.trTsType                   = ct_cs_cpuif__te__trTsControl__trTsType_e_e'(0);
	assign cs.trTsPrescale               = 2'd0;
	assign cs.trTsWidth                  = 6'd0;

	nexus_message_t nexus_msg;
	uwire logic     ready_out;

	ct_L2_nexus_formatter dut (
		.proc_clk  (clk),
		.proc_rst  (rst),
		.cs_proc   (cs),
		.trace_msg (f_msg),
		.nexus_msg (nexus_msg),
		.ready_in  (in_ready),
		.ready_out (ready_out)
	);

	// ------------------------------------------------------------------
	// Probes (bind lexically after sv2v inlining, msg_gen pattern)
	// ------------------------------------------------------------------
	wire nexus_vendor::nexus_addr_t f_refdaddr  = dut.RefDaddr;
	wire logic        f_reanchor  = dut.DfReanchor;

	// Wrapper-side recomputation (checked against the contract, the DUT's
	// own classification is deliberately NOT probed):
	uwire logic f_fire     = in_ready && (in_sub_type != SUB_MSG_NONE);
	uwire logic f_df_now   = (in_tcode == NEXUS_MSG_DATA_TRACE_READ)
	                      || (in_tcode == NEXUS_MSG_DATA_TRACE_WRITE);
	uwire logic f_compress = (in_daddr_compress != DADDR_FULL); // CT_EN_DF_ADDR_COMPRESS=1 in this build
	uwire logic f_sync_cf  = (in_tcode == NEXUS_MSG_PROGRAM_TRACE_SYNC)
	                      || (in_tcode == NEXUS_MSG_PROGRAM_TRACE_DIRECT_BRANCH_SYNC)
	                      || (in_tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_SYNC)
	                      || (ct_pkg::CT_EN_IBHS && (in_tcode == NEXUS_MSG_PROGRAM_TRACE_INDIRECT_BRANCH_HISTORY_SYNC))
	                      || (ct_pkg::CT_EN_REPEAT_INSTR && (in_tcode == NEXUS_MSG_PROGRAM_TRACE_REPEAT_INSTRUCTION_SYNC));

	// Decision-net probes (the sv2v struct-literal limitation makes the
	// packed OUTPUT register unusable in the model -- header note; the
	// on-wire field layer is sim-gate territory).
	uwire logic        f_dut_compress  = dut.df_compress_active;
	uwire logic        f_dut_sync_now  = dut.df_sync_now;
	uwire logic [5:0]  f_dut_sync_tc   = 6'(dut.df_sync_tcode);
	uwire nexus_vendor::nexus_addr_t f_dut_xor  = dut.daddr_xor;

	// ------------------------------------------------------------------
	// Environment assumptions
	// ------------------------------------------------------------------
	logic f_past_valid = 1'b0;
	always_ff @(posedge clk) f_past_valid <= 1'b1;

	// ASM-FMT-1
	always_comb if (!f_past_valid) assume (rst);

	// ASM-FMT-2: legal sub_type encoding
	always_comb assume (in_sub_type <= SUB_MSG_OTHER);

	// ASM-FMT-3: msg_gen contract -- 13/14 are formatter-made, never input
	always_comb assume ((in_tcode != NEXUS_MSG_DATA_TRACE_WRITE_SYNC)
	                 && (in_tcode != NEXUS_MSG_DATA_TRACE_READ_SYNC));

	// ASM-FMT-4: quasi-static CSRs (DataTracing stays free)
	ct_cs_cpuif__te__trTeDataControl__trTeDataAddrCompress_e_e p_mode_q;
	logic p_inh_q, p_tse_q;
	always_ff @(posedge clk) begin
		p_mode_q <= in_daddr_compress;
		p_inh_q  <= in_inhibit_src;
		p_tse_q  <= in_ts_enable;
	end
	always_comb if (f_past_valid) begin
		assume (in_daddr_compress == p_mode_q);
		assume (in_inhibit_src    == p_inh_q);
		assume (in_ts_enable      == p_tse_q);
	end

	// ------------------------------------------------------------------
	// Contract-side re-anchor mirror (P-FMT-4). Independently written from
	// the T2 contract (D-P3-2), NOT copied from the RTL: consumed by a DF
	// emission, set by sync/ERROR emission and by the DataTracing rising
	// edge (observed in every cycle, set-dominant).
	// ------------------------------------------------------------------
	logic w_pend   = 1'b1;
	logic w_dtprev = 1'b0;
	always_ff @(posedge clk) begin
		if (rst) begin
			w_pend   <= 1'b1;
			w_dtprev <= 1'b0;
		end
		else begin
			if (f_fire && f_df_now && f_compress)
				w_pend <= 1'b0;
			if (f_fire && (f_sync_cf || (in_tcode == NEXUS_MSG_ERROR)))
				w_pend <= 1'b1;
			w_dtprev <= in_data_tracing;
			if (in_data_tracing && !w_dtprev)
				w_pend <= 1'b1;
		end
	end

	// ------------------------------------------------------------------
	// Helper state (previous = decision cycle)
	// ------------------------------------------------------------------
	logic        p_rst_q      = 1'b1;
	logic        p_dfemit_q   = 1'b0; // DF emission beat in compress mode at t
	logic        p_dfsync_q   = 1'b0; // ... with the re-anchor obligation (13/14)
	logic        p_dfxor_q    = 1'b0; // ... without it (XOR form)
	logic        p_dfwrite_q  = 1'b0; // DF direction at t (write=5)
	nexus_vendor::nexus_addr_t p_daddr_q; // DF address offered at t
	nexus_vendor::nexus_addr_t p_ref_q;   // RefDaddr BEFORE the t-edge update
	logic        p_err_seen   = 1'b0; // sticky: an ERROR was emitted (cover)

	always_ff @(posedge clk) begin
		p_rst_q     <= rst;
		p_dfemit_q  <= f_fire && f_df_now && f_compress;
		p_dfsync_q  <= f_fire && f_df_now && f_compress && f_reanchor;
		p_dfxor_q   <= f_fire && f_df_now && f_compress && !f_reanchor;
		p_dfwrite_q <= (in_tcode == NEXUS_MSG_DATA_TRACE_WRITE);
		p_daddr_q   <= in_daddr;
		p_ref_q     <= f_refdaddr;
		if (rst) p_err_seen <= 1'b0;
		else if (f_fire && (in_tcode == NEXUS_MSG_ERROR)) p_err_seen <= 1'b1;
	end

	// ------------------------------------------------------------------
	// Assertions -- registered (previous cycle = decision cycle)
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (f_past_valid && !p_rst_q && !rst) begin
			// P-FMT-2 -- reference advances ONLY on a DF emission beat.
			if (!p_dfemit_q)
				assert (f_refdaddr == p_ref_q);                       // A_fmt2_ref_stable

			// P-FMT-2b -- a DF emission re-seats the reference exactly ...
			// (RED_MASK_FMT2SEATED: red runs only -- this assertion is the
			// strict GENERALIZATION of A_fmt1_ref_eq_addr below
			// [p_dfsync_q => p_dfemit_q, identical consequent], so it always
			// fires first and would hide the target. Masking it isolates the
			// A_fmt1 red. NEVER define this in a green run -- run.sh/CI pass
			// no defines; only run_red.sh sets SV2V_DEFS.)
`ifndef RED_MASK_FMT2SEATED
			if (p_dfemit_q)
				assert (f_refdaddr == p_daddr_q);                     // A_fmt2_ref_seated
`endif

			// P-FMT-1 -- ... so after a 13/14 upgrade (which transmits the
			// FULL df_daq address) the reference equals the transmitted
			// address: the decoder's re-anchor invariant.
			if (p_dfsync_q)
				assert (f_refdaddr == p_daddr_q);                     // A_fmt1_ref_eq_addr
		end
	end

	// ------------------------------------------------------------------
	// Assertions -- combinational, on the decision cycle itself
	// ------------------------------------------------------------------
	always_comb if (f_past_valid && !rst) begin
		// Probe canary (README "Tool traps"): an unbound probe would
		// diverge from the wrapper-recomputed twin immediately.
		assert (f_dut_compress == f_compress);                        // A_canary_probe

		// P-FMT-4 -- a DF offer under an outstanding obligation fires the
		// upgrade decision; without one (or without a DF) it must not.
		// (RED_MASK_FMT4UPG: red runs only -- this equality is the strict
		// GENERALIZATION of A_fmt3_full_no_upgrade below and would hide that
		// target. Same rule as RED_MASK_FMT2SEATED: never in a green run.)
`ifndef RED_MASK_FMT4UPG
		assert (f_dut_sync_now == (f_compress && f_reanchor && f_df_now)); // A_fmt4_reanchor_upgrade
`endif

		// P-FMT-1 -- the upgrade direction follows the 5/6 input.
		if (f_df_now)
			assert (f_dut_sync_tc == ((in_tcode == NEXUS_MSG_DATA_TRACE_WRITE)
			        ? 6'(NEXUS_MSG_DATA_TRACE_WRITE_SYNC)
			        : 6'(NEXUS_MSG_DATA_TRACE_READ_SYNC)));           // A_fmt1_tcode_dir

		// P-FMT-3 -- FULL mode: the upgrade decision can never fire.
		if (!f_compress)
			assert (!f_dut_sync_now);                                 // A_fmt3_full_no_upgrade

		// P-FMT-5 -- the emitted XOR delta is daddr ^ RefDaddr (the
		// reference the decoder reconstructs against).
		assert (f_dut_xor == (in_daddr ^ f_refdaddr));                // A_fmt5_xor_value
	end

	// P-FMT-4 -- the RTL's sticky flag equals the contract mirror at all
	// times (also the induction anchor for the prove task).
	always_comb if (f_past_valid) begin
		assert (w_pend == f_reanchor);                                // A_fmt4_pend_mirror
	end

	// ------------------------------------------------------------------
	// Cover (non-vacuity witnesses)
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (f_past_valid && !p_rst_q && !rst) begin
			cover (p_dfsync_q && p_dfwrite_q);                        // C_13_emitted
			cover (p_dfsync_q && !p_dfwrite_q);                       // C_14_emitted
			cover (p_dfxor_q);                                        // C_xor_emitted
			cover (p_dfsync_q && p_err_seen);                         // C_reanchor_after_error
			cover (in_data_tracing && !w_dtprev && !in_ready);        // C_edge_during_stall
			cover (f_fire && f_df_now && !f_compress);                // C_full_df_emission
		end
	end

endmodule : f_fmt_check

`default_nettype wire
