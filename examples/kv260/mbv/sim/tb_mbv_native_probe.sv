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
// tb_mbv_native_probe -- minimal probe for AMD's NATIVE N-Trace encoder (external sink).
//
// Purpose (one question, empirical): does the native encoder emit bytes at the Dbg_Trace port at
// all when the core runs a program -- OR does it first need runtime programming of its
// trace registers over the debug interface (the way CTTE needs its CSRs over Wishbone)?
//
//   mbv_ctrace_soc_wrapper (block design with MBV_NATIVE_TRACE=1)
//        | Dbg_Trace_Data[0:35] + Valid  (valid/ready stream, its own Dbg_Trace_Clk)
//   -> tapped here, 36-bit words counted + written to <NATIVE_DUMP_PATH>.
//
// Deliberately WITHOUT adapter/CTTE/ATB: isolates the question "does an AMD stream come out?"
// from the dual-encoder integration. NO PASS/FAIL claim about trace correctness -- only "does anything come?".
//
// IMPORTANT (from experience with run_g4_sim.ps1): xsim returns exit 0 even on a kernel FATAL. The
// success signal is the PROBE line below, not the exit code.
`timescale 1ns/1ps
`default_nettype none

module tb_mbv_native_probe;

    int unsigned RUN_CYCLES = 6000;
    string       native_path = "mbv_native.trace.hex";

    // ---- Clocks / reset (as in tb_mbv_g0_soc: external reset ACTIVE_HIGH) ----
    logic clk   = 1'b0;
    logic reset = 1'b1;
    initial forever #5ns clk = ~clk;   // 100 MHz SoC/core clock

    // Trace output clock: coupled to the core clock for the sim (one domain is enough to
    // answer "does a stream come out?"; the real trace-clock policy is a later question).
    logic dbg_trace_clk = 1'b0;
    initial forever #5ns dbg_trace_clk = ~clk;   // phase-shifted, but 100 MHz

    logic         dbg_trace_ready = 1'b1;   // sink always ready (no backpressure test here)
    logic [0:35]  dbg_trace_data;
    logic         dbg_trace_valid;
    logic         Interrupt_0 = 1'b0;

    // ---- DUT: the REAL SoC (native-trace variant of the block design) ----
    // TRACE_0_* are deliberately left unconnected (outputs) -- this probe only tests the native port.
    mbv_ctrace_soc_wrapper dut (
        .clk             (clk),
        .reset           (reset),
        .Interrupt_0     (Interrupt_0),
        .dbg_trace_clk   (dbg_trace_clk),
        .dbg_trace_ready (dbg_trace_ready),
        .dbg_trace_data  (dbg_trace_data),
        .dbg_trace_valid (dbg_trace_valid)
    );

    // ---- Capture: every accepted 36-bit word as 9 hex nibbles/line ----
    int unsigned fd = 0;
    int unsigned beats = 0;
    initial fd = $fopen(native_path, "w");

    always_ff @(posedge dbg_trace_clk) begin
        if (!reset && dbg_trace_valid && dbg_trace_ready) begin
            beats <= beats + 1;
            if (fd != 0) $fwrite(fd, "%09h\n", dbg_trace_data);
        end
    end

    // ---- Sequence ----
    initial begin
        if ($value$plusargs("RUN_CYCLES=%d", RUN_CYCLES))
            $display("[probe] RUN_CYCLES per plusarg = %0d", RUN_CYCLES);

        // Hold reset, then release the core (BRAM is preloaded via COE -> the program starts running).
        repeat (20) @(posedge clk);
        reset <= 1'b0;
        $display("[probe] %0t: core released, observing Dbg_Trace_Valid ...", $time);

        repeat (RUN_CYCLES) @(posedge clk);

        $display("[probe] ---- result ----");
        $display("[probe] Dbg_Trace beats (36-bit words): %0d", beats);
        if (beats == 0) begin
            $display("[probe] FINDING: ZERO beats -- the native encoder emits NOTHING without runtime enable.");
            $display("[probe]         -> next step: program the trace registers via the debug interface.");
        end else begin
            $display("[probe] FINDING: %0d beats -- the native encoder emits. Stream in %s.", beats, native_path);
        end
        if (fd != 0) $fclose(fd);
        $display("[probe] PROBE DONE");
        $finish;
    end

    // Emergency brake
    initial begin
        #3ms;
        if (fd != 0) $fclose(fd);
        $fatal(1, "[probe] TIMEOUT");
    end

endmodule : tb_mbv_native_probe

`default_nettype wire
