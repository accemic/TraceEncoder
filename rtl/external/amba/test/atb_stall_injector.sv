// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
* Copyright (c) 2026 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Albert Schulz <aschulz@accemic.com>
*
* @brief    ATB pass-through that injects Aurora-like bursty backpressure
* @details
*   Drop-in shim between an ATB master (e.g. `ct_encoder`) and an ATB slave
*   (e.g. `ct_nexus_decoder`). All ATB signals are forwarded transparently;
*   when `stall_enable_i` is high, short random bursts of !atready are
*   inserted on the master-facing side to emulate the bursty backpressure
*   seen from Aurora-style SerDes sinks (where `atready` stays high most of
*   the time and then drops for a few cycles during link flow-control).
*
*   Handshake-safe: the downstream `atvalid` is gated by the same stall, so
*   no beat is ever presented to the slave that the master hasn't committed
*   to. Forward and reverse protocol signals (`atbytes`, `atdata`, `atid`,
*   `afready`, `afvalid`, `syncreq`) are forwarded untouched.
*
*   Sizing rule of thumb: keep
*     average sink rate >= average master rate
*   so the encoder's internal FIFOs do not overflow. In practice,
*   `STALL_PERIOD` should be several times larger than `STALL_LENGTH_MAX`;
*   an elaboration check enforces that.
*/
module atb_stall_injector #(
    int unsigned    STALL_PERIOD     = 32,           // cycles between bursts
    int unsigned    STALL_LENGTH_MAX = 4,            // max consecutive stall cycles
    bit [31:0]      SEED             = 32'hDEAD_BEEF
) (
    input uwire logic       atb_atclk,
    input uwire logic       atb_atresetn,
    input uwire logic       stall_enable_i, // enable random pattern
    input uwire logic       force_stall_i,  // level: force stall=1 while high
    atb_if.slave            atb_up,         // towards ATB master
    atb_if.master           atb_dn          // towards ATB slave
);

    // Parameter Sanity Checks
    initial begin
        if (STALL_PERIOD <= STALL_LENGTH_MAX) begin
            $error("STALL_PERIOD (%0d) must exceed STALL_LENGTH_MAX (%0d) to guarantee recovery",
                STALL_PERIOD, STALL_LENGTH_MAX);
            $finish;
        end
        if (SEED == 32'h0) begin
            $error("SEED must be non-zero (LFSR would be stuck at 0)");
            $finish;
        end
    end

    initial begin
        $display("*** INFO (%m) atb_stall_injector: seed=0x%08h period=%0d max_burst=%0d",
            SEED, STALL_PERIOD, STALL_LENGTH_MAX);
    end

    int              CycleCnt = 0;
    int              StallRem = 0;
    logic [31:0]     Lfsr     = SEED;

    // Galois LFSR tap set (x^32 + x^22 + x^2 + x + 1) -- same tap positions
    // used by `atb_sink_model` for consistency across the ATB test kit.
    function automatic logic [31:0] lfsr_next(input logic [31:0] cur);
        return {cur[30:0], cur[31] ^ cur[21] ^ cur[1] ^ cur[0]};
    endfunction

    always_ff @(posedge atb_atclk) begin
        if (!atb_atresetn) begin
            CycleCnt <= 0;
            StallRem <= 0;
            Lfsr     <= SEED;
        end
        else begin
            Lfsr <= lfsr_next(Lfsr);
            if (!stall_enable_i) begin
                CycleCnt <= 0;
                StallRem <= 0;
            end
            else if (StallRem > 0) begin
                StallRem <= StallRem - 1;
                CycleCnt <= 0;
            end
            else if (CycleCnt >= STALL_PERIOD - 1) begin
                // Start a new burst of 0..STALL_LENGTH_MAX cycles. A result
                // of 0 means "no stall this window", giving bursty rather
                // than strictly periodic behaviour.
                StallRem <= Lfsr % (STALL_LENGTH_MAX + 1);
                CycleCnt <= 0;
            end
            else begin
                CycleCnt <= CycleCnt + 1;
            end
        end
    end

    uwire logic stall = force_stall_i || (stall_enable_i && (StallRem > 0));

    // Forward signals (master -> slave)
    assign atb_dn.atbytes = atb_up.atbytes;
    assign atb_dn.atdata  = atb_up.atdata;
    assign atb_dn.atid    = atb_up.atid;
    assign atb_dn.atvalid = atb_up.atvalid & ~stall;
    assign atb_dn.afready = atb_up.afready;

    // Reverse signals (slave -> master)
    assign atb_up.atready = atb_dn.atready & ~stall;
    assign atb_up.afvalid = atb_dn.afvalid;
    assign atb_up.syncreq = atb_dn.syncreq;

endmodule // atb_stall_injector
`default_nettype wire
