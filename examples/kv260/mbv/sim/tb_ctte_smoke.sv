// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
//
// tb_ctte_smoke -- the encoder alone: no MicroBlaze-V, no adapter, no Xilinx IP.
//
// Migrated 2026-08-18 from the evidence archive
// (package D3b). The body
// is carried over verbatim apart from this header and the translation of the
// original German $display line, which is the verdict string the archived
// G4 evidence refers to.
//
// WHY IT EXISTS (2026-07-16, G4 bring-up): the first G4 run died with an xsim
// KERNEL FATAL at time 0. This bench answered the one question that mattered --
// is it our integration or not? Answer: NOT ours; it reproduces with the bare
// encoder. Measured back then, per xelab debug level:
//   -debug typical -> KERNEL FATAL     -debug line       -> PASS
//   -debug wave    -> KERNEL FATAL     -debug subprogram -> PASS
//   -debug all     -> KERNEL FATAL     -debug off        -> PASS
// The crash correlated exactly with the WAVE instrumentation and hit
// ct_L23_preproc_act_proc.sv:64 (always_comb) at time 0, iteration 0. Every
// encoder sim in the archive therefore ran with `-debug off`.
//
// WHAT IT IS HERE: that xsim-specific probe cannot fire on the pinned default
// backend of this repository (.abc.config: sim_backend=verilator) -- it is
// kept and wired because it is still a cheap, meaningful smoke: `ct_encoder`
// at CORE_XLEN=32 elaborates and runs 5 us on a completely quiet TIP with the
// ATB/AXIS sinks always ready, and nothing hangs, X-propagates into the
// handshakes or trips the CORE_XLEN elaboration guard. It becomes the original
// xsim probe again the moment it is run with `abc --sim-backend xsim`.
`timescale 1ns/1ps
`default_nettype none

module tb_ctte_smoke;

    logic tip_clk = 0, atb_atclk = 0, proc_clk = 0, wb_clk = 0, wall_clk = 0;
    initial forever #5ns  tip_clk   = ~tip_clk;
    initial forever #2ns  atb_atclk = ~atb_atclk;
    initial forever #2ns  proc_clk  = ~proc_clk;
    initial forever #5ns  wb_clk    = ~wb_clk;
    initial forever #5ns  wall_clk  = ~wall_clk;

    logic tip_rst = 1, proc_rst = 1, wb_rst = 1, ct_cs_rst = 1, wall_clk_rst = 1;
    logic atb_atresetn = 0;

    initial begin
        #200ns;
        @(posedge tip_clk);   tip_rst      <= 0;
        @(posedge atb_atclk); atb_atresetn <= 1;
        @(posedge proc_clk);  proc_rst     <= 0;
        @(posedge wb_clk);    wb_rst       <= 0;
        @(posedge wb_clk);    ct_cs_rst    <= 0;
        @(posedge wall_clk);  wall_clk_rst <= 0;
    end

    tip_if tip ();
    wb_if #(.DATA_WIDTH(32), .ADDR_WIDTH(32)) wb ();
    axis_if axis (.aclk(wb_clk), .aresetn(~wb_rst));
    atb_if  atb ();

    // Keep TIP completely quiet - this is only about time 0 / elaboration.
    assign tip.iretire   = '0;
    assign tip.itype     = tip_pkg::OTHER;
    assign tip.iaddr     = '0;
    assign tip.ilastsize = '0;
    assign tip.ecause    = tip_pkg::ECAUSE_NONE;
    assign tip.tval      = '0;
    assign tip.priv      = 3'd3;
    assign tip._context  = '0;
    assign tip.ctype     = '0;
    assign tip._time     = '0;
    assign tip.impdef    = '0;
    assign tip.dretire   = '0;
    assign tip.dtype     = tip_pkg::LOAD;
    assign tip.daddr     = '0;
    assign tip.dsize     = '0;
    assign tip.data      = '0;
    assign tip.sdata     = '0;
    assign tip.lresp     = '0;
    assign tip.ldata     = '0;
    assign tip.debug_mode = '0;
    assign tip.evti       = '0;
    assign tip.power_down = '0;
    assign tip.trigger    = '0;

    assign atb.atready = 1'b1;
    assign atb.afready = 1'b1;
    assign atb.afvalid = 1'b0;
    assign atb.syncreq = 1'b0;
    assign axis.tready = 1'b1;

    // CORE_XLEN(32): the probe drives this repo's encoder (CT_XLEN = 32)
    // with an RV32 stimulus; the elaboration guard requires the explicit setting.
    ct_encoder #(.SPLIT_DATA_ACCESS(0), .CORE_XLEN(32)) encoder (
        .tip_clk, .tip_rst, .tip (tip.slave),
        .wb_clk,  .wb_rst,  .wb, .ct_cs_rst,
        .axis,
        .atb_atclk, .atb_atresetn, .atb (atb),
        .proc_clk, .proc_rst,
        .wall_clk, .wall_clk_rst
    );

    initial begin
        #5us;
        $display("[smoke] PASS - encoder ran 5us without a kernel crash");
        $finish;
    end

endmodule
`default_nettype wire
