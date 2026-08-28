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
// tb_mbv_g0_soc -- gate G0 baseline testbench: observes the REAL MicroBlaze-V core (mbv_ctrace_soc)
// while it executes a program pre-loaded into the LMB BRAM, and logs the `TRACE` bus.
// Goal (gate G0): `Trace_PC`/`Trace_Instruction` at `Trace_Valid_Instr` == object dump
// (sw/.../build/*.oracle.csv) -- bit-order acceptance criterion.
//
// Program load: ELF via "Associate ELF Files" (run_g0_sim.tcl) -> LMB BRAM init in the sim.
// Wrapper ports empirically confirmed (all trace buses VHDL `[0:31]` ascending, bit 0 = MSB).
`timescale 1ns/1ps

module tb_mbv_g0_soc;

    // Reset polarity: the external port is typed ACTIVE_HIGH (proc_sys_reset derives C_EXT_RESET_HIGH).
    localparam bit RESET_ACTIVE   = 1'b1;
    localparam int MAX_RETIRE     = 4000;    // enough for trace_test (loop 64x) + margin
    localparam int MAX_CYCLES     = 300000;  // hard upper bound
    localparam string CAP_FILE    = "trace_capture.log";

    // --- Full-cycle window (EVERY cycle, including stalls) ---
    // The retire capture above only shows cycles with valid_instr/exc -- stall cycles stay invisible.
    // This window logs every cycle without gaps, including the PipeRun signals, to measure:
    //   (a) does Trace_Valid_Instr fire EXACTLY ONCE per instruction? (the core question)
    //   (b) how do Trace_OF/EX/MEM_PipeRun behave during pipeline stalls?
    localparam int CYC_WIN_LO     = 1;
    localparam int CYC_WIN_HI     = 1200;
    localparam string CYC_FILE    = "cycle_capture.log";

    logic clk = 1'b0;
    logic reset;
    // Interrupt measurement: external machine interrupt (edge), pulsed from the testbench.
    logic Interrupt_0 = 1'b0;
    localparam int IRQ_PULSE_CYCLE = 500;   // first edge: safely inside the foreground loop (after SW MIE enable)
    // Keeps pulsing periodically afterwards. The period is coprime with the loop length (~9 cycles), so the
    // interrupts land on ROTATING loop positions over the run -- including a branch ("interrupt on
    // a branch"). 0 = off (single interrupt, as in an earlier round).
    localparam int IRQ_PERIOD      = 37;

    // --- Trace bus (widths exactly as the wrapper: [0:31] ascending) ---
    wire        TRACE_0_valid_instr, TRACE_0_jump_taken, TRACE_0_exception_taken;
    wire        TRACE_0_of_piperun, TRACE_0_ex_piperun, TRACE_0_mem_piperun, TRACE_0_mb_halted;
    wire [0:31] TRACE_0_pc, TRACE_0_instruction, TRACE_0_new_reg_value;
    wire [0:5]  TRACE_0_exception_kind;
    wire        TRACE_0_data_access, TRACE_0_data_read, TRACE_0_data_write, TRACE_0_reg_write;
    wire [0:31] TRACE_0_data_address, TRACE_0_data_write_value;
    wire [0:3]  TRACE_0_data_byte_enable;
    wire [0:4]  TRACE_0_reg_addr;

    // --- DUT ---
    mbv_ctrace_soc_wrapper dut (
        .clk(clk), .reset(reset), .Interrupt_0(Interrupt_0),
        .TRACE_0_pc(TRACE_0_pc), .TRACE_0_instruction(TRACE_0_instruction),
        .TRACE_0_valid_instr(TRACE_0_valid_instr), .TRACE_0_jump_taken(TRACE_0_jump_taken),
        .TRACE_0_exception_taken(TRACE_0_exception_taken), .TRACE_0_exception_kind(TRACE_0_exception_kind),
        .TRACE_0_of_piperun(TRACE_0_of_piperun), .TRACE_0_ex_piperun(TRACE_0_ex_piperun),
        .TRACE_0_mem_piperun(TRACE_0_mem_piperun), .TRACE_0_mb_halted(TRACE_0_mb_halted),
        .TRACE_0_data_access(TRACE_0_data_access), .TRACE_0_data_address(TRACE_0_data_address),
        .TRACE_0_data_read(TRACE_0_data_read), .TRACE_0_data_write(TRACE_0_data_write),
        .TRACE_0_data_write_value(TRACE_0_data_write_value), .TRACE_0_data_byte_enable(TRACE_0_data_byte_enable),
        .TRACE_0_reg_write(TRACE_0_reg_write), .TRACE_0_reg_addr(TRACE_0_reg_addr),
        .TRACE_0_new_reg_value(TRACE_0_new_reg_value)
    );

    // --- 100 MHz clock ---
    always #5 clk = ~clk;

    // --- Reset ---
    initial begin
        reset = RESET_ACTIVE;
        repeat (20) @(posedge clk);
        reset = ~RESET_ACTIVE;
    end

    // --- Capture ---
    integer fd;
    int retired = 0;
    int cyc = 0;

    integer fd_cyc;

    initial begin
        fd = $fopen(CAP_FILE, "w");
        if (fd == 0) begin $display("[tb] ERROR: cannot open %s", CAP_FILE); $finish; end
        // Column header: pc,instr,valid,exc_taken,exc_kind,jump_taken
        $fdisplay(fd, "# pc,instr,valid,exc_taken,exc_kind,jump_taken (retire events)");

        fd_cyc = $fopen(CYC_FILE, "w");
        if (fd_cyc == 0) begin $display("[tb] ERROR: cannot open %s", CYC_FILE); $finish; end
        $fdisplay(fd_cyc, "# cyc,pc,instr,valid,exc,of_piperun,ex_piperun,mem_piperun,halted,jump_taken (EVERY cycle)");
    end

    always @(posedge clk) begin
        cyc++;
        // Interrupt pulse (edge-triggered): first edge @ IRQ_PULSE_CYCLE, periodic afterwards
        // (IRQ_PERIOD coprime with the loop length -> rotating hit positions).
        if (cyc == IRQ_PULSE_CYCLE)          Interrupt_0 <= 1'b1;
        else if (cyc == IRQ_PULSE_CYCLE + 6) Interrupt_0 <= 1'b0;
        else if (IRQ_PERIOD > 0 && cyc > IRQ_PULSE_CYCLE + 6) begin
            if      (((cyc - IRQ_PULSE_CYCLE) % IRQ_PERIOD) == 0) Interrupt_0 <= 1'b1;
            else if (((cyc - IRQ_PULSE_CYCLE) % IRQ_PERIOD) == 3) Interrupt_0 <= 1'b0;
        end
        if (reset != RESET_ACTIVE) begin
            // Gapless window -- EVERY cycle, including stall cycles + PipeRun
            if (cyc >= CYC_WIN_LO && cyc <= CYC_WIN_HI) begin
                $fdisplay(fd_cyc, "%0d,%08h,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                          cyc, TRACE_0_pc, TRACE_0_instruction, TRACE_0_valid_instr,
                          TRACE_0_exception_taken, TRACE_0_of_piperun, TRACE_0_ex_piperun,
                          TRACE_0_mem_piperun, TRACE_0_mb_halted, TRACE_0_jump_taken);
            end
            // Log the retire OR exception cycle (both are needed here; the object-dump check uses valid_instr)
            if (TRACE_0_valid_instr || TRACE_0_exception_taken) begin
                $fdisplay(fd, "%08h,%08h,%0d,%0d,%02h,%0d",
                          TRACE_0_pc, TRACE_0_instruction, TRACE_0_valid_instr,
                          TRACE_0_exception_taken, TRACE_0_exception_kind, TRACE_0_jump_taken);
                if (TRACE_0_valid_instr) retired++;
                if (retired >= MAX_RETIRE) begin
                    $display("[tb] MAX_RETIRE=%0d reached @cyc=%0d", MAX_RETIRE, cyc);
                    $fclose(fd); $fclose(fd_cyc); $finish;
                end
            end
        end
        if (cyc >= MAX_CYCLES) begin
            $display("[tb] MAX_CYCLES=%0d reached, retired=%0d", MAX_CYCLES, retired);
            $fclose(fd); $fclose(fd_cyc); $finish;
        end
    end

endmodule
