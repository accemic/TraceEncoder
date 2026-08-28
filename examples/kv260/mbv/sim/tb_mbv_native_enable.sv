// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
//
// Migrated 2026-08-18 from the evidence archive
// (package D3b). Body verbatim apart from the SPDX line (this repository
// runs fsfe/reuse-action and licenses under CERN-OHL-S-2.0 OR the commercial
// option) and this note; the original German comments -- the verdict strings
// the archived G0/G1/G4/G5 evidence quotes -- were translated to English for
// publication.
//
// NEEDS VIVADO. This bench instantiates
// `mbv_ctrace_soc_wrapper` -- the module Vivado's make_wrapper generates from
// the `mbv_ctrace_soc` block design at build time, around the ENCRYPTED
// MicroBlaze-V core. It has no in-repo .sv source by design, so there is no
// path through Verilator for this bench: it runs under xsim, inside a project created
// by ../fpga/create_project_kv260.tcl. Recipe and the measured failure signature:
// this directory's README.md.
//
//
// tb_mbv_native_enable -- arms AMD's native N-Trace encoder over S_AXI and checks
// whether it then emits at the Dbg_Trace port. Register map from UG1629 (not guessed):
//
//   trTeControl @ 0x2000 :  bit0 trTeActive | bit1 trTeEnable | bit2 trTeInstTracing
//                           bits6:4 trTeInstMode (3=BTM, 6=HTM)
//   Enable value HTM = 0x1|0x2|0x4|(6<<4) = 0x67   (same shape as CTTE's Active+Enable+InstTracing)
//
// Access: C_S_AXI=1 -> AXI4-Lite slave (14-bit address, 32-bit data, NO WSTRB, clock domain,
// UG1629 "The Slave AXI Interface (S_AXI) with access from any AXI4 Master").
//
// Open (to be clarified empirically): does S_AXI respond while the core is in reset (then trace
// could be armed BEFORE core start, as with CTTE)? The probe tests both orderings.
`timescale 1ns/1ps
`default_nettype none

module tb_mbv_native_enable;

    localparam logic [13:0] TRTE_CONTROL = 14'h2000;
    localparam logic [13:0] TRTS_CONTROL = 14'h2040;                  // timestamp control
    localparam logic [31:0] TE_ACTIVE    = 32'h0000_0001;             // Active only
    localparam logic [31:0] TE_ENABLE_HTM= 32'h0000_0067;             // Active|Enable|InstTracing|HTM
    localparam logic [31:0] TE_FLUSH     = 32'h0000_0063;             // InstTracing=0 -> encoder flushes
    localparam logic [31:0] TE_ENABLE_BTM= 32'h0000_0037;             // Active|Enable|InstTracing|BTM (fallback)

    int unsigned RUN_CYCLES = 6000;

    logic clk   = 1'b0;
    logic reset = 1'b1;
    initial forever #5ns clk = ~clk;

    logic dbg_trace_clk = 1'b0;
    initial forever #5ns dbg_trace_clk = ~clk;
    logic         dbg_trace_ready = 1'b1;
    logic [0:35]  dbg_trace_data;
    logic         dbg_trace_valid;
    logic         Interrupt_0 = 1'b0;

    // S_AXI master signals (we are the master)
    logic [13:0] saxi_awaddr = '0;  logic saxi_awvalid = 1'b0;  logic saxi_awready;
    logic [31:0] saxi_wdata  = '0;  logic saxi_wvalid  = 1'b0;  logic saxi_wready;
    logic [1:0]  saxi_bresp;        logic saxi_bvalid;          logic saxi_bready  = 1'b0;
    logic [13:0] saxi_araddr = '0;  logic saxi_arvalid = 1'b0;  logic saxi_arready;
    logic [31:0] saxi_rdata;        logic [1:0] saxi_rresp;     logic saxi_rvalid; logic saxi_rready = 1'b0;

    mbv_ctrace_soc_wrapper dut (
        .clk(clk), .reset(reset), .Interrupt_0(Interrupt_0),
        .dbg_trace_clk(dbg_trace_clk), .dbg_trace_ready(dbg_trace_ready),
        .dbg_trace_data(dbg_trace_data), .dbg_trace_valid(dbg_trace_valid),
        .saxi_awaddr(saxi_awaddr), .saxi_awvalid(saxi_awvalid), .saxi_awready(saxi_awready),
        .saxi_wdata(saxi_wdata), .saxi_wvalid(saxi_wvalid), .saxi_wready(saxi_wready),
        .saxi_bresp(saxi_bresp), .saxi_bvalid(saxi_bvalid), .saxi_bready(saxi_bready),
        .saxi_araddr(saxi_araddr), .saxi_arvalid(saxi_arvalid), .saxi_arready(saxi_arready),
        .saxi_rdata(saxi_rdata), .saxi_rresp(saxi_rresp), .saxi_rvalid(saxi_rvalid), .saxi_rready(saxi_rready)
    );

    // ---- AXI4-Lite write with timeout (does not spin forever if the slave stays silent) ----
    task automatic axi_write(input logic [13:0] addr, input logic [31:0] data, output bit ok);
        int guard;
        bit aw_done, w_done;
        ok = 1'b0; aw_done = 1'b0; w_done = 1'b0;
        @(posedge clk);
        saxi_awaddr <= addr; saxi_awvalid <= 1'b1;
        saxi_wdata  <= data; saxi_wvalid  <= 1'b1;
        saxi_bready <= 1'b1;
        guard = 0;
        while (!(aw_done && w_done)) begin
            @(posedge clk);
            if (saxi_awready) begin saxi_awvalid <= 1'b0; aw_done = 1'b1; end
            if (saxi_wready)  begin saxi_wvalid  <= 1'b0; w_done  = 1'b1; end
            if (++guard > 200) begin
                saxi_awvalid <= 1'b0; saxi_wvalid <= 1'b0; saxi_bready <= 1'b0;
                $display("[en] AXI write @0x%04h TIMEOUT (slave without AWREADY/WREADY)", addr);
                return;
            end
        end
        guard = 0;
        while (!saxi_bvalid) begin @(posedge clk); if (++guard > 200) break; end
        @(posedge clk);
        saxi_bready <= 1'b0;
        ok = 1'b1;
        $display("[en] AXI write @0x%04h = 0x%08h ok (BRESP=%0d)", addr, data, saxi_bresp);
    endtask

    task automatic axi_read(input logic [13:0] addr, output logic [31:0] data, output bit ok);
        int guard;
        ok = 1'b0; data = 'x;
        @(posedge clk);
        saxi_araddr <= addr; saxi_arvalid <= 1'b1; saxi_rready <= 1'b1;
        guard = 0;
        while (!(saxi_arready && saxi_arvalid)) begin
            @(posedge clk);
            if (++guard > 200) begin saxi_arvalid <= 1'b0; saxi_rready <= 1'b0; return; end
        end
        @(posedge clk); saxi_arvalid <= 1'b0;
        guard = 0;
        while (!saxi_rvalid) begin @(posedge clk); if (++guard > 200) begin saxi_rready <= 1'b0; return; end end
        data = saxi_rdata;
        @(posedge clk); saxi_rready <= 1'b0;
        ok = 1'b1;
    endtask

    task automatic arm_trace(output bit ok);
        bit ok1, ok2, ok3;
        // Timestamps OFF (trTsControl=0): otherwise AMD packs TSTAMP fields into the messages, which
        // NexRv (tuned to CTTE's profile) chokes on. They are unnecessary for PC reconstruction.
        axi_write(TRTS_CONTROL, 32'h0000_0000,  ok3);
        // BTM (trTeInstMode=3): one message per branch -> more robust for NexRv than HTM's history.
        // Irrelevant for the LOGICAL comparison (both reconstruct the same PC sequence).
        axi_write(TRTE_CONTROL, TE_ACTIVE,     ok1);
        axi_write(TRTE_CONTROL, TE_ENABLE_BTM, ok2);
        ok = ok1 && ok2 && ok3;
    endtask

    int unsigned fd = 0, beats = 0;
    initial fd = $fopen("mbv_native.trace.hex", "w");
    always_ff @(posedge dbg_trace_clk) begin
        if (!reset && dbg_trace_valid && dbg_trace_ready) begin
            beats <= beats + 1;
            if (fd != 0) $fwrite(fd, "%09h\n", dbg_trace_data);
        end
    end

    // S_AXI does NOT respond in reset (empirically confirmed: armed_in_reset was 0). So: release
    // the core, then arm IMMEDIATELY (minimal delay -> trace starts around instruction 5-10).
    bit armed_live;
    int unsigned beats_at_flush;
    initial begin
        if ($value$plusargs("RUN_CYCLES=%d", RUN_CYCLES)) ;

        repeat (10) @(posedge clk);
        @(posedge clk); reset <= 1'b0;                 // release the core
        $display("[en] core released @%0t -- arming IMMEDIATELY", $time);
        arm_trace(armed_live);                          // no intermediate delay
        $display("[en] -> armed_live = %0b", armed_live);

        repeat (RUN_CYCLES) @(posedge clk);
        beats_at_flush = beats;

        // FLUSH: InstTracing=0 -> the encoder finishes the message in flight + emits
        // ProgTraceCorrelation (closes out the history -> NexRv emits the PCs). Afterwards
        // poll trTeEmpty (bit 3) until the encoder is truly empty -- otherwise the
        // closing marker stays truncated and NexRv emits 0 PCs.
        $display("[en] %0t: FLUSH (trTeInstTracing=0), beats so far=%0d", $time, beats_at_flush);
        begin
            bit ok; logic [31:0] rd; int p;
            axi_write(TRTE_CONTROL, TE_FLUSH, ok);
            for (p = 0; p < 40; p++) begin
                repeat (20) @(posedge clk);
                axi_read(TRTE_CONTROL, rd, ok);
                if (ok && rd[3]) begin $display("[en] trTeEmpty=1 after %0d polls (rd=0x%08h)", p, rd); break; end
            end
        end
        repeat (200) @(posedge clk);

        $display("[en] ---- result ----");
        $display("[en] armed_live=%0b", armed_live);
        $display("[en] Dbg_Trace beats: %0d (of which before flush: %0d, from flush: %0d)",
                 beats, beats_at_flush, beats - beats_at_flush);
        if (beats == 0)
            $display("[en] FINDING: 0 beats -- enabling via trTeControl is (still) not enough. More registers?");
        else
            $display("[en] FINDING: %0d beats -- the native encoder is ALIVE. Stream in mbv_native.trace.hex.", beats);
        if (fd != 0) $fclose(fd);
        $display("[en] ENABLE PROBE DONE");
        $finish;
    end

    initial begin
        #4ms;
        if (fd != 0) $fclose(fd);
        $fatal(1, "[en] TIMEOUT");
    end

endmodule : tb_mbv_native_enable

`default_nettype wire
