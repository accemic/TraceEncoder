// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @brief   Formal wrapper for ovf_injector (SymbiYosys route, P-INJ-1..4).
 *
 * @details
 *   Checks the counted-vector overflow marker injector against an
 *   independent mirror model (full functional correspondence — the mirror
 *   re-states the intended contract, the assertions prove DUT == contract,
 *   the cover points prove the contract is exercised, i.e. not vacuous).
 *
 *   Token abstraction: T = logic[3:0] (the injector is type-generic and
 *   never inspects payload bits — a 4-bit token is exhaustive for the
 *   control skeleton).
 *
 *   Two instances are proven in ONE run:
 *     chk_par : SEQ_INJECT=0, P=2 (parallel double-marker beat)
 *     chk_seq : SEQ_INJECT=1, P=1 (serialized d0-then-d1, the P=1-sink
 *               configuration that motivated SEQ_INJECT)
 *
 *   Assumption budget (each one justified in formal/README.md):
 *     ASM-INJ-1: isnk.cnt <= P (counted-vector interface contract).
 *   Everything else (rst, clear, full, force_inject, inject_hold,
 *   inject_second_valid, payloads) is FREE.
 *
 *   Properties (see formal/README.md):
 *     P-INJ-1 conservation   : every accepted isnk element is forwarded
 *                              exactly once XOR counted as discarded
 *                              (accumulator identity, modulo 2^32 like the
 *                              DUT's CntDiscards; a concurrent clear absorbs
 *                              the same-cycle discards into the cleared
 *                              bucket exactly like the RTL).
 *     P-INJ-2 episode debt   : after a drop episode begins, d0 (and d1
 *                              when armed) are emitted exactly once before
 *                              forwarding resumes.
 *     P-INJ-3 inject_done    : pulses exactly in the emission cycle of the
 *                              LAST marker element.
 *     P-INJ-4 hold           : inject_hold blocks the anchor-carrying
 *                              marker (d1 / single-beat) and dropping stays
 *                              asserted; SEQ may pre-emit the anchor-free
 *                              d0 while a second marker is armed.
 */

`default_nettype none

module f_ovf_check #(
	parameter bit          SEQ = 0,
	parameter int unsigned P   = 2
)(
	input wire logic                   clk,
	input wire logic                   rst,
	input wire logic [$clog2(P+1)-1:0] in_cnt,
	input wire logic [P-1:0][3:0]      in_d,
	input wire logic                   out_full,
	input wire logic                   force_inject,
	input wire logic                   inject_hold,
	input wire logic                   inject_second_valid,
	input wire logic [3:0]             inject_d0,
	input wire logic [3:0]             inject_d1,
	input wire logic                   clear
);
	// ------------------------------------------------------------------
	// Interfaces + DUT
	// ------------------------------------------------------------------
	cvsink_if #(.T(logic[3:0]), .P(P), .STOP_ON_OVERRUN(0)) isnk (.clk(clk), .rst(rst));
	cvsink_if #(.T(logic[3:0]), .P(P), .STOP_ON_OVERRUN(0)) osnk (.clk(clk), .rst(rst));

	assign isnk.cnt  = in_cnt;
	assign isnk.d    = in_d;
	assign osnk.full = out_full;

	wire logic        dut_dropping;
	wire logic        dut_done;
	wire logic        dut_busy;
	wire logic [31:0] dut_discard_cnt;

	ovf_injector #(.T(logic[3:0]), .SEQ_INJECT(SEQ)) dut (
		.clk                 (clk),
		.rst                 (rst),
		.isnk                (isnk),
		.osnk                (osnk),
		.inject_d0           (inject_d0),
		.inject_d1           (inject_d1),
		.inject_second_valid (inject_second_valid),
		.force_inject        (force_inject),
		.inject_hold         (inject_hold),
		.clear               (clear),
		.dropping            (dut_dropping),
		.inject_done         (dut_done),
		.busy                (dut_busy),
		.discard_cnt         (dut_discard_cnt)
	);

	// ASM-INJ-1: counted-vector contract — the producer never presents more
	// elements than the vector holds (cnt <= P). cnt_t is $clog2(P+1) bits,
	// so for P=2 the encoding 3 is representable but illegal.
	always_comb assume (in_cnt <= P);

	// ------------------------------------------------------------------
	// Mirror model (independent restatement of the contract)
	// ------------------------------------------------------------------
	localparam logic [1:0] M_FWD  = 0;
	localparam logic [1:0] M_INJ  = 1;
	localparam logic [1:0] M_INJ2 = 2;

	logic [1:0]  m_state = M_FWD;
	logic [31:0] m_discards = '0;      // mirrors CntDiscards
	logic [31:0] m_in_total = '0;      // accepted input elements (mod 2^32)
	logic [31:0] m_fwd_total = '0;     // forwarded input elements (mod 2^32)
	logic [31:0] m_cleared_total = '0; // elements absorbed by clear pulses

	logic [1:0]  m_state_n;
	logic [2:0]  m_ocnt;      // expected osnk.cnt
	logic [2:0]  m_disc;      // elements discarded THIS cycle
	logic        m_fwd;       // pass-through cycle (osnk carries isnk data)
	logic        m_emit_d0;   // d0 marker goes out this cycle
	logic        m_emit_d1;   // d1 marker goes out this cycle

	always_comb begin
		m_state_n = m_state;
		m_ocnt    = '0;
		m_disc    = '0;
		m_fwd     = 1'b0;
		m_emit_d0 = 1'b0;
		m_emit_d1 = 1'b0;

		case (m_state)
		M_FWD: begin
			m_ocnt = 3'(in_cnt);
			m_fwd  = 1'b1;
			if (((in_cnt > 0) && out_full) || force_inject) begin
				m_state_n = M_INJ;
				m_disc    = 3'(in_cnt);
				m_ocnt    = '0;
				m_fwd     = 1'b0;
			end
		end
		M_INJ: begin
			m_disc = 3'(in_cnt);
			if (!out_full && (!inject_hold || (SEQ && inject_second_valid))) begin
				if (SEQ) begin
					m_ocnt    = 3'd1;
					m_emit_d0 = 1'b1;
					m_state_n = inject_second_valid ? M_INJ2 : M_FWD;
				end
				else begin
					m_ocnt    = inject_second_valid ? 3'd2 : 3'd1;
					m_emit_d0 = 1'b1;
					m_emit_d1 = inject_second_valid;
					m_state_n = M_FWD;
				end
			end
		end
		M_INJ2: begin
			m_disc = 3'(in_cnt);
			if (!out_full && !inject_hold) begin
				m_ocnt    = 3'd1;
				m_emit_d1 = 1'b1;
				m_state_n = M_FWD;
			end
		end
		default: ; // unreachable (mirror only ever holds M_FWD/M_INJ/M_INJ2)
		endcase
	end

	// Last marker element leaves THIS cycle (the anchor-sample moment).
	wire logic m_done = m_emit_d1 || (m_emit_d0 && !inject_second_valid);

	wire logic m_dropping = (m_state != M_FWD)
	                     || ((m_state == M_FWD) && (in_cnt > 0) && out_full)
	                     || ((m_state == M_FWD) && force_inject);

	// Episode bookkeeping for P-INJ-2.
	logic m_ep_d0_done = 1'b0; // d0 already emitted in the open episode
	logic m_ep_d1_due  = 1'b0; // a second marker is still owed (SEQ only)

	// State probe (hierarchical reference into the DUT; after sv2v inlining
	// `dut` is a generate scope of this module, so the reference binds
	// lexically). Needed as strengthening invariant: without it k-induction
	// admits unreachable aliases (DUT in Injecting2 vs mirror in Injecting)
	// that survive arbitrarily long under full=1 and then diverge.
	wire logic [1:0] dut_state_probe = dut.State;

	always_ff @(posedge clk) begin
		if (rst) begin
			m_state         <= M_FWD;
			m_discards      <= '0;
			m_in_total      <= '0;
			m_fwd_total     <= '0;
			m_cleared_total <= '0;
			m_ep_d0_done    <= 1'b0;
			m_ep_d1_due     <= 1'b0;
		end
		else begin
			m_state         <= m_state_n;
			m_discards      <= clear ? '0 : m_discards + 32'(m_disc);
			m_in_total      <= m_in_total  + 32'(in_cnt);
			m_fwd_total     <= m_fwd_total + (m_fwd ? 32'(in_cnt) : 32'd0);
			// A clear pulse absorbs the running count AND any same-cycle
			// discards (exactly the RTL's `clear ? '0 : cnt + discards`).
			m_cleared_total <= m_cleared_total
			                 + (clear ? (m_discards + 32'(m_disc)) : 32'd0);
			if ((m_state == M_FWD) && (m_state_n == M_INJ)) begin
				m_ep_d0_done <= 1'b0;
				m_ep_d1_due  <= 1'b0;
			end
			else begin
				if (m_emit_d0) begin
					m_ep_d0_done <= 1'b1;
					m_ep_d1_due  <= SEQ && inject_second_valid;
				end
				if (m_emit_d1) m_ep_d1_due <= 1'b0;
			end
		end
	end

	// ------------------------------------------------------------------
	// Assertions
	// ------------------------------------------------------------------
	// Full functional correspondence DUT == mirror. Checked as clocked
	// immediate assertions (sampled on the combinational values of the
	// current cycle, just before the edge).
	always @(posedge clk) begin
		if (!rst) begin
			// state correspondence (busy is the registered state view)
			assert (dut_state_probe == m_state);                 // A_state_eq (strengthening)
			// Episode-bookkeeping invariants (strengthening for k-induction;
			// both follow from the mirror's update rules on reachable states):
			assert (m_ep_d1_due == (m_state == M_INJ2));         // A_inv_due
			assert (!((m_state == M_INJ) && m_ep_d0_done));      // A_inv_d0
			if (!SEQ)
				assert (m_state != M_INJ2);                      // A_inv_noinj2 (Injecting2 is SEQ-only)
			assert (dut_busy     == (m_state != M_FWD));         // A_busy
			assert (dut_dropping == m_dropping);                 // A_dropping
			assert (osnk.cnt     == m_ocnt[$bits(osnk.cnt)-1:0]);// A_ocnt
			assert (isnk.full    == 1'b0);                       // A_ifull

			// data lanes: pass-through carries isnk data, marker beats carry
			// inject_d0/d1 (only lanes < cnt are defined)
			if (m_fwd && (in_cnt > 0))
				assert (osnk.d[0] == in_d[0]);                   // A_fwd_d0
			if (m_fwd && (in_cnt > 1))
				assert (osnk.d[(P > 1) ? 1 : 0] == in_d[(P > 1) ? 1 : 0]); // A_fwd_d1
			if (m_emit_d0)
				assert (osnk.d[0] == inject_d0);                 // A_mark_d0
			if (m_emit_d1 && !SEQ)
				assert (osnk.d[(P > 1) ? 1 : 0] == inject_d1);   // A_mark_d1_par
			if (m_emit_d1 && SEQ)
				assert (osnk.d[0] == inject_d1);                 // A_mark_d1_seq

			// P-INJ-1: discard counter correspondence + flow conservation
			// (mod 2^32): accepted == forwarded + counted-discarded + cleared.
			assert (dut_discard_cnt == m_discards);              // A_disc_cnt
			assert (m_in_total == m_fwd_total + m_discards + m_cleared_total); // A_conserve

			// P-INJ-2: no isnk forwarding while an episode is open; d0 at
			// most once per episode; the episode closes only in the cycle
			// the last owed marker leaves.
			assert (!((m_state != M_FWD) && m_fwd));             // A_no_fwd_busy
			if (m_emit_d0)
				assert (!m_ep_d0_done);                          // A_d0_once
			if (m_emit_d1 && SEQ)
				assert (m_ep_d1_due);                            // A_d1_due
			if ((m_state != M_FWD) && (m_state_n == M_FWD))
				assert (m_done);                                 // A_ep_closed

			// P-INJ-3: inject_done contract
			assert (dut_done == m_done);                         // A_done

			// P-INJ-4: hold blocks the anchor-carrying marker; dropping stays
			if (inject_hold && (m_state == M_INJ) && !(SEQ && inject_second_valid))
				assert ((osnk.cnt == 0) && dut_dropping);        // A_hold_inj
			if (inject_hold && (m_state == M_INJ2))
				assert ((osnk.cnt == 0) && dut_dropping);        // A_hold_inj2
		end
	end

	// ------------------------------------------------------------------
	// Cover (non-vacuity witnesses)
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (!rst) begin
			cover (m_state == M_INJ);                            // C_episode
			cover (m_done);                                      // C_emit_last
			cover ((m_state != M_FWD) && (in_cnt > 0));          // C_disc_busy
			cover (clear && (m_discards != 0));                  // C_clear_live
			cover ((m_state != M_FWD) && (m_state_n == M_FWD));  // C_resume
			cover ((m_state == M_FWD) && force_inject && (in_cnt == 0)); // C_forced
			if (SEQ) begin
				cover (m_state == M_INJ2);                       // C_second
				cover (m_emit_d0 && inject_hold);                // C_d0_hold
			end
			else begin
				cover (osnk.cnt == 2);                           // C_double
			end
		end
	end

endmodule : f_ovf_check


module f_top (
	input wire logic       clk,

	// -------- parallel variant (SEQ_INJECT=0, P=2) --------
	input wire logic       a_rst,
	input wire logic [1:0] a_cnt,
	input wire logic [7:0] a_d,
	input wire logic       a_full,
	input wire logic       a_force,
	input wire logic       a_hold,
	input wire logic       a_sv,
	input wire logic [3:0] a_d0,
	input wire logic [3:0] a_d1,
	input wire logic       a_clear,

	// -------- serialized variant (SEQ_INJECT=1, P=1) --------
	input wire logic       b_rst,
	input wire logic [0:0] b_cnt,
	input wire logic [3:0] b_d,
	input wire logic       b_full,
	input wire logic       b_force,
	input wire logic       b_hold,
	input wire logic       b_sv,
	input wire logic [3:0] b_d0,
	input wire logic [3:0] b_d1,
	input wire logic       b_clear
);

	f_ovf_check #(.SEQ(0), .P(2)) chk_par (
		.clk                 (clk),
		.rst                 (a_rst),
		.in_cnt              (a_cnt),
		.in_d                (a_d),
		.out_full            (a_full),
		.force_inject        (a_force),
		.inject_hold         (a_hold),
		.inject_second_valid (a_sv),
		.inject_d0           (a_d0),
		.inject_d1           (a_d1),
		.clear               (a_clear)
	);

	f_ovf_check #(.SEQ(1), .P(1)) chk_seq (
		.clk                 (clk),
		.rst                 (b_rst),
		.in_cnt              (b_cnt),
		.in_d                (b_d),
		.out_full            (b_full),
		.force_inject        (b_force),
		.inject_hold         (b_hold),
		.inject_second_valid (b_sv),
		.inject_d0           (b_d0),
		.inject_d1           (b_d1),
		.clear               (b_clear)
	);

endmodule : f_top

`default_nettype wire
