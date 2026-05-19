// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
 * Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
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
	type         T = logic[7:0]
)(
	input  uwire   clk,
	input  uwire   rst,

	cvsink_if.impl     isnk,
	cvsink_if.client   osnk,
	input  T           inject_d0,
	input  T           inject_d1,
	input  uwire logic inject_second_valid,

	// Upstream-driven overflow request: treated like `osnk.full` — any
	// concurrent `isnk` data is discarded and the configured marker is
	// emitted on `osnk` once it has room.
	input  uwire logic force_inject,

	input  uwire logic       clear,         // synchronous clear for discard_cnt
	output uwire logic       dropping,
	output uwire logic[31:0] discard_cnt
);
	typedef enum logic {
		Forwarding = 0,
		Injecting  = 1
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

			// Inject - when possible
			if (!osnk.full) begin
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

	assign dropping = (State == Injecting)
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
