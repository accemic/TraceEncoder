// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @file    ct_sync_req_pacer.sv
 * @brief   Launch pacing for the explicit sync request over the TE register
 *          (P8/G11, trTeControl.InstSyncReq).
 *
 * @details
 *   A CSR write to a self-clearing field is a ONE-CYCLE pulse, and a pulse is
 *   the wrong thing to hand to a clock-domain crossing on its own: two pulses
 *   closer than one destination clock period cancel in a toggle synchronizer
 *   and BOTH requests are lost. This module is the answer -- PACING:
 *
 *     * a request is raised only while no other one is outstanding;
 *     * the consumer acknowledges when it has SERVED the request;
 *     * two requests are therefore always a full round trip apart, which is
 *       what makes the crossing lossless.
 *
 *   Depth is one plus one: a write arriving while a request is outstanding is
 *   not dropped, it is remembered in `Queued` and raised the moment the
 *   handshake closes -- so it becomes its OWN request and gets its own
 *   synchronization message. Only a write that arrives when a request is
 *   already queued collapses into that queued one; it asks for exactly what
 *   is about to be asked for anyway.
 *
 *   WHAT CROSSES IS A LEVEL, AND THAT IS THE POINT (P8 closing audit B-N1).
 *   The first version paced STROBES across two toggle synchronizers, and
 *   that is not survivable: the two halves of one request live in two reset
 *   domains -- the pacing here in wb_rst, the pending latch in the consumer
 *   in tip_rst -- and ct_encoder carries both as independent inputs ("every
 *   domain has its own synchronous reset", doc/integration.adoc). A consumer
 *   reset then clears the pending latch without an acknowledgement, the
 *   strobe that carried the request is long gone, and nothing can bring it
 *   back: the request is silently lost, and depending on which way the two
 *   toggle pairs fall out of reset the launch path can also be left waiting
 *   for an acknowledgement that will never come.
 *
 *   The ATB request path never had that problem, and the reason is
 *   structural rather than lucky: its trigger is a HELD LEVEL, so after a
 *   reset the consumer simply sees it again (signal_ack_lock_fsm). The same
 *   property is bought here the same way -- a four-phase handshake on two
 *   plain level synchronizers:
 *
 *       req  0 -> 1   software asked (one outstanding, one remembered)
 *       ack  0 -> 1   the consumer emitted the synchronization message
 *       req  1 -> 0   the launch side has seen the acknowledgement
 *       ack  1 -> 0   the consumer has seen the request go away; idle again
 *
 *   Every state of that loop is re-derivable from the two levels alone, so a
 *   reset on either side re-converges instead of losing the request: after a
 *   consumer reset `req` is still up and `ack` is down, which is precisely
 *   "a request is owed". No reset needs to be observed across the domain
 *   boundary and no timer is involved. The objection that ruled a level out
 *   in the first design -- the ATB handshake FSM needs to see its input fall
 *   before it rearms, so a write landing in the acknowledgement cycle either
 *   wedges it or is lost -- does not apply to a four-phase master that owns
 *   its own `Queued` slot: such a write is remembered and raised after the
 *   handshake closes.
 *
 *   What is NOT promised across a consumer reset: exactly one message. A
 *   request that was already served but whose acknowledgement had not been
 *   seen yet is asked for again, so a re-anchor can cost one additional
 *   synchronization message. A synchronization message is always safe to
 *   emit, and claiming otherwise would be a claim nothing here can support.
 *
 *   It is a module of its own, and not four lines inside the CSR shim,
 *   because the formal environment instantiates THIS source: the pacing
 *   protocol is what formal/preproc_sync proves (P-SYNC-9/10/12), so a
 *   hand-copied mirror of it in the wrapper would be a second truth that can
 *   drift (P8 audit B-2).
 *
 * @ports
 *   clk / rst            source (CSR) clock domain
 *   write                one-cycle pulse: software wrote 1 to the field
 *   ack                  LEVEL, synchronised from the consumer: served
 *   req                  LEVEL to the consumer: one request is owed
 */

`default_nettype none

module ct_sync_req_pacer (
	input  wire logic clk,
	input  wire logic rst,
	input  wire logic write,
	input  wire logic ack,
	output uwire logic req
);

	logic Req    = 1'b0;   // a request is outstanding (raised, not withdrawn)
	logic Queued = 1'b0;   // a write arrived while one was outstanding

	// Idle = no request up and no acknowledgement standing. Only then may the
	// next request be raised -- that is the fourth phase, and it is what keeps
	// two requests a full round trip apart.
	uwire logic idle = !Req && !ack;

	always_ff @(posedge clk) begin
		if (rst) begin
			Req    <= 1'b0;
			Queued <= 1'b0;
		end
		else begin
			if (idle && (write || Queued)) begin
				Req    <= 1'b1;
				Queued <= 1'b0;
			end
			else if (Req && ack) begin
				// Served: withdraw the request. The consumer drops its
				// acknowledgement when it sees that, and the loop is closed.
				Req <= 1'b0;
			end
			// A write that cannot be raised right now is remembered -- exactly
			// one, so the third write in a burst collapses into the second.
			// Textually AFTER the clear above, so a write in the very cycle a
			// queued request is raised is not swallowed.
			if (write && !(idle && (write || Queued))) Queued <= 1'b1;
		end
	end

	assign req = Req;

endmodule : ct_sync_req_pacer

`default_nettype wire
