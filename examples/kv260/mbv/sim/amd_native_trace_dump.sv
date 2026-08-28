// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
//
// Migrated 2026-08-18 from the evidence archive
// (package D3b).
// Body verbatim; only the SPDX line changed. Used by mbv_dual_encoder_env --
// the AMD-native counterpart of the upstream `atb_dump` recorder. It has no
// Vivado dependency of its own; it is only ever instantiated by a bench that
// does.
//
//
// amd_native_trace_dump -- captures AMD's native N-Trace output (36-bit Dbg_Trace port).
//
// Counterpart to upstream's `atb_dump.sv` (CTTE branch), but for AMD's external sink: a
// valid/ready stream of 36-bit words (Dbg_Trace_Data[0:35]), clocked by Dbg_Trace_Clk.
// Every accepted word is written as 9 hex nibbles/line -- readable and further processable by
// tools/amd_trace_unframe.py (framing -> NexRv bytes). The beat counter is
// the success signal ("does a stream come out?"), so an empty run does not pass as a success.
`default_nettype none

module amd_native_trace_dump #(
    string FILEPATH = "mbv_native.trace.hex"
) (
    input  uwire logic        dbg_trace_clk,
    input  uwire logic        dbg_trace_rst_n,     // low-active: do not capture while in reset
    input  uwire logic        dbg_trace_valid,
    input  uwire logic        dbg_trace_ready,
    input  uwire logic [0:35] dbg_trace_data
);
    int fd    = 0;
    int beats = 0;

    initial fd = $fopen(FILEPATH, "w");

    // always_ff (not initial+forever), analogous to atb_dump: avoids the race where a posedge
    // fires while the forever body is still stuck in $fwrite (buffered disk I/O) -- otherwise
    // a beat would silently drop out of the file.
    always_ff @(posedge dbg_trace_clk) begin
        if (dbg_trace_rst_n && dbg_trace_valid && dbg_trace_ready) begin
            beats <= beats + 1;
            if (fd != 0) $fwrite(fd, "%09h\n", dbg_trace_data);
        end
    end

    final begin
        if (fd != 0) $fclose(fd);
        $display("*** INFO (%m) amd_native_trace_dump: %0d 36-bit words -> %s", beats, FILEPATH);
    end
endmodule : amd_native_trace_dump

`default_nettype wire
