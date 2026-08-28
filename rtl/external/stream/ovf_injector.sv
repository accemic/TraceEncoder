// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
 * @brief   Counted-vector stream overflow marker injector.
 *
 * @details Forwards `isnk` to `osnk` while there is room. On downstream
 *          full (or an upstream-driven `force_inject`) it discards any
 *          concurrent input data, bumps `discard_cnt`, and once `osnk`
 *          has room emits one or two configured marker elements
 *          (`inject_d0`, optionally `inject_d1`). `discard_cnt` is
 *          synchronously cleared by `clear`; `dropping` reflects the
 *          instantaneous drop state for upstream observation.
 *
 * @author   Albert Schulz <aschulz@accemic.com>
 */
module ovf_injector #(
	type T          = logic[7:0],
	// Emit the two marker elements in TWO cycles (d0 first, then d1)
	// instead of one 2-element beat. REQUIRED whenever `osnk` is a P=1
	// sink: its cnt port is 1 bit wide, so a combined `osnk.cnt = 2`
	// truncates to 0 and BOTH markers are lost silently (found 2026-07-20
	// via the serialized eTIP path: QueueOverrun ERROR + resync never
	// reached the FIFO).
	bit  SEQ_INJECT = 0
)(
	input  uwire             clk,
	input  uwire             rst,

	cvsink_if.impl           isnk,
	cvsink_if.client         osnk,
	input  T                 inject_d0,
	input  T                 inject_d1,
	input  uwire logic       inject_second_valid,

	// Upstream-driven overflow request: treated like `osnk.full` — any
	// concurrent `isnk` data is discarded and the configured marker is
	// emitted on `osnk` once it has room.
	input  uwire logic       force_inject,

	// Hold the marker emission even when `osnk` has room (tie to 0 when
	// unused). The upstream uses this to delay the resync marker until its
	// content (the re-anchor address sampled combinationally via
	// inject_d0/d1) is actually valid — e.g. the eTIP composer's
	// FIFO_OVERRUN FADDR formula `PrevIAddr + size` only names the next
	// retire address when the previous retire was NOT a taken control-flow
	// change. Input data arriving during the hold keeps being discarded
	// (dropping stays asserted).
	input  uwire logic       inject_hold,

	input  uwire logic       clear, // synchronous clear for discard_cnt
	output uwire logic       dropping,
	// Pulses in the cycle the LAST marker element is emitted — the moment
	// the re-anchor content was sampled. The upstream uses it to reset its
	// post-anchor accumulators (e.g. icnt_cum) so counts restart at the
	// anchor instead of including the discarded window.
	output uwire logic       inject_done,
	// Registered "marker emission in progress" (State != Forwarding).
	// Loop-free by construction — upstreams gate their presentation on it
	// so accepted beats are never discarded mid-inject (see dropping).
	output uwire logic       busy,
	output uwire logic[31:0] discard_cnt
);
	typedef enum logic [1:0] {
		Forwarding = 0,
		Injecting  = 1,
		Injecting2 = 2   // SEQ_INJECT only: second marker (inject_d1) pending
	} state_e;

	state_e State = Forwarding;

	// Input never overflows ... as we gently discard the data by kind of "consuming" it
	assign isnk.full = 0;

	int discards;

	state_e next_state;
	always_comb begin
		next_state = State;

		osnk.cnt =  0;
		osnk.d   = 'x;

		discards = 0;

		if (State == Forwarding) begin
			osnk.cnt = isnk.cnt;
			osnk.d   = isnk.d;

			if (((isnk.cnt > 0) && osnk.full) || force_inject) begin
				// Overflow! Either the downstream is full while we have
				// data, or the upstream explicitly signalled that it had
				// to drop. Discard any concurrent isnk data and move to
				// Injecting so we emit the configured marker
				// (inject_d0 [, inject_d1]).

				next_state = Injecting;

				discards = isnk.cnt;

				// actively discard the data
				osnk.cnt =  0;
				osnk.d   = 'x;
			end
		end
		else if (State == Injecting) begin

			if (isnk.cnt > 0) begin
				discards = isnk.cnt;
			end

			// Inject - when possible. With SEQ_INJECT the first marker
			// (inject_d0, the anchor-free ERROR) may go out immediately;
			// only the anchor-carrying second marker honours inject_hold.
			if (!osnk.full && (!inject_hold || (SEQ_INJECT && inject_second_valid))) begin
				if (SEQ_INJECT) begin
					// One marker per cycle (P=1-safe): d0 now, d1 next.
					osnk.cnt   = 1;
					osnk.d     = 'x;
					osnk.d[0]  = inject_d0;
					next_state = inject_second_valid ? Injecting2 : Forwarding;
				end
				else begin
					osnk.cnt    = inject_second_valid ? 2 : 1;
					osnk.d      = 'x;
					osnk.d[0]   = inject_d0;
					if (inject_second_valid) begin
						osnk.d[1] = inject_d1;
					end
					next_state = Forwarding;
				end
			end
		end
		else if (State == Injecting2) begin
			if (isnk.cnt > 0) begin
				discards = isnk.cnt;
			end
			if (!osnk.full && !inject_hold) begin
				osnk.cnt   = 1;
				osnk.d     = 'x;
				osnk.d[0]  = inject_d1;
				next_state = Forwarding;
			end
		end
	end

	// Last marker element goes out THIS cycle (the anchor-sample moment).
	assign inject_done =
		   ((State == Injecting)  && !osnk.full && !inject_hold
		    && (!SEQ_INJECT || !inject_second_valid))
		|| ((State == Injecting2) && !osnk.full && !inject_hold);

	assign busy = (State != Forwarding);

	assign dropping = (State == Injecting) || (State == Injecting2)
		|| ((State == Forwarding) && (isnk.cnt > 0) && osnk.full)
		|| ((State == Forwarding) && force_inject);

	logic[31:0] CntDiscards = 0;

	always_ff @(posedge clk) begin
		if (rst) begin
			State       <= Forwarding;
			CntDiscards <= 0;
		end
		else begin
			State       <= next_state;
			CntDiscards <= clear ? '0 : CntDiscards + discards;
		end
	end

	assign discard_cnt = CntDiscards;

endmodule
`default_nettype wire
