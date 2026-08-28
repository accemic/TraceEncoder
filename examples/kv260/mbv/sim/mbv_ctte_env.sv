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
// mbv_ctte_env -- G4 integration environment: REAL MicroBlaze-V core -> adapter -> CTTE encoder -> ATB.
//
// Analogous to upstream's `tests/lib/ctrace_env.sv`, but with the real core instead of `cpu_model`:
//
//   mbv_ctrace_soc_wrapper (real MBV, runs the COE program)
//        | AMD TRACE bus
//   mbv_to_ctte_tip (our adapter, gates G2+G3)
//        | tip_if
//   ct_encoder (upstream, pinned @3a74ea5 -- instantiated UNCHANGED, AD-01)
//        | atb_if -> atb_dump -> <run>.atb.bin  (primary artifact, decoded offline by NexRv)
//
// WHY a dedicated env instead of `ctrace_env`: there, `cpu_model` is hard-wired as the TIP driver.
// `third_party/CTTE/` is gitignored and re-fetched via `fetch.sh` -- a change there
// would be doubly wrong (AD-01 + gone on the next fetch). We therefore instantiate the same
// upstream building blocks (ct_encoder, ct_cs_cpuif_wb_helper, atb_dump) ourselves. No fork, no copy.
//
// CLOCK DOMAINS (the encoder spans five):
//   tip_clk  = SoC clock (100 MHz) -- MANDATORY: the TRACE bus is synchronous to the core clock.
//   proc_clk / atb_atclk = 250 MHz -- as upstream; lets the internal CDC operate for real,
//                          instead of hiding it behind a single-clock setup.
//   wb_clk / wall_clk    = 100 MHz.
`timescale 1ns/1ps
`default_nettype none

module mbv_ctte_env #(
    parameter string ATB_DUMP_PATH = "mbv_g4.atb.bin",
    // Reference for gate G5: the ACTUALLY retiring PCs, in execution order.
    // NexRv's decoded PC sequence is checked against this list ("== reference without gaps").
    // Empty = no capture.
    parameter string RETIRED_PCS_PATH = "",
    // Debug: every TIP cycle with iretire=1 OR itype!=OTHER (empty = off).
    parameter string TIP_DEBUG_PATH = "",
    parameter bit    RESET_ACTIVE  = 1'b1     // as in tb_mbv_g0_soc: the external port is ACTIVE_HIGH
) ();

    // ------------------------------------------------------------------
    // Clocks
    //
    // Clock profile via plusarg (board-profile bisection): the KV260 board
    // (mbv_soc_synth_wrap) clocks ALL encoder domains from the ONE SoC clock
    // (proc = atb = tip = wb = wall, 1:1) -- the default env, by contrast,
    // runs proc/atb at 250 MHz (upstream profile, 2.5x drain).
    //   +PROC_HALF_NS=5 +ATB_HALF_NS=5  -> 100 MHz = board ratio 1:1
    //   +ATB_HALF_NS=40                 -> ATB throttle (gate G09/G10 method:
    //                                      drain << source rate -> real overflows)
    // ------------------------------------------------------------------
    logic clk       = 1'b0;   // SoC + tip
    logic atb_atclk = 1'b0;
    logic proc_clk  = 1'b0;
    logic wb_clk    = 1'b0;
    logic wall_clk  = 1'b0;

    int unsigned atb_half_ns  = 2;   // default 250 MHz (upstream profile)
    int unsigned proc_half_ns = 2;

    initial forever #5ns  clk       = ~clk;        // 100 MHz
    // Colon form first: xsim 2026.1 splits `-testplusarg NAME=VALUE` on the
    // equals sign; the `=` form remains as a fallback.
    initial begin
        if (!$value$plusargs("ATB_HALF_NS:%d", atb_half_ns))
            void'($value$plusargs("ATB_HALF_NS=%d", atb_half_ns));
        if (atb_half_ns != 2) $display("[env] ATB half-period via plusarg: %0d ns", atb_half_ns);
        forever #(atb_half_ns * 1ns) atb_atclk = ~atb_atclk;
    end
    initial begin
        if (!$value$plusargs("PROC_HALF_NS:%d", proc_half_ns))
            void'($value$plusargs("PROC_HALF_NS=%d", proc_half_ns));
        if (proc_half_ns != 2) $display("[env] PROC half-period via plusarg: %0d ns", proc_half_ns);
        forever #(proc_half_ns * 1ns) proc_clk = ~proc_clk;
    end
    initial forever #5ns  wb_clk    = ~wb_clk;
    initial forever #5ns  wall_clk  = ~wall_clk;

    // ------------------------------------------------------------------
    // Resets
    // ------------------------------------------------------------------
    logic soc_reset    = RESET_ACTIVE;
    logic tip_rst      = 1'b1;
    logic atb_atresetn = 1'b0;
    logic proc_rst     = 1'b1;
    logic wb_rst       = 1'b1;
    logic ct_cs_rst    = 1'b1;
    logic wall_clk_rst = 1'b1;

    logic reset_released = 1'b0;

    // The CORE deliberately stays in reset until the test calls `release_core()`.
    //
    // WHY (measured): if the core ran immediately, it would already be well past `main` and
    // spinning in `_exit: jal x0,_exit` before the CSR programming over Wishbone completes
    // (the test programs are only ~85 instructions long). The trace would then contain almost
    // nothing but the infinite loop instead of the program -- and an E2E comparison against that
    // proves nothing. Configuring the encoder first and then starting the core also matches the
    // real-world sequence.
    initial begin
        #200ns;
        @(posedge clk);       tip_rst       <= 1'b0;
        @(posedge atb_atclk); atb_atresetn  <= 1'b1;
        @(posedge proc_clk);  proc_rst      <= 1'b0;
        @(posedge wb_clk);    wb_rst        <= 1'b0;
        @(posedge wb_clk);    ct_cs_rst     <= 1'b0;
        @(posedge wall_clk);  wall_clk_rst  <= 1'b0;
        @(posedge clk);       reset_released <= 1'b1;
    end

    // Encoder resets released (core is NOT yet running).
    task automatic wait_for_reset_release();
        wait (reset_released == 1'b1);
        @(posedge clk);
    endtask

    // Start the core -- call only after the CSR configuration.
    task automatic release_core();
        @(posedge clk);
        soc_reset <= ~RESET_ACTIVE;
        @(posedge clk);
    endtask

    task automatic wait_cycles(input int n);
        repeat (n) @(posedge clk);
    endtask

    // ------------------------------------------------------------------
    // Interrupt stimulus (edge-triggered, as in tb_mbv_g0_soc).
    //
    // Without this driver, `interrupt_test` would run through the E2E chain without ever seeing
    // an interrupt -- a green run that never touches the INTERRUPT path at all. The period is
    // coprime with the loop length so the IRQs land on rotating positions (including a branch) --
    // the same method used in an earlier gate-G1 round.
    // ------------------------------------------------------------------
    logic Interrupt_0 = 1'b0;
    logic irq_enable  = 1'b0;    // set by the test; default off (other programs unaffected)
    int unsigned irq_cyc = 0;

    localparam int IRQ_FIRST  = 60;   // after core start, so mtvec is set
    localparam int IRQ_PERIOD = 37;   // coprime with the loop length

    always_ff @(posedge clk) begin
        if (soc_reset == RESET_ACTIVE) begin
            irq_cyc     <= 0;
            Interrupt_0 <= 1'b0;
        end else begin
            irq_cyc <= irq_cyc + 1;
            if (irq_enable && irq_cyc >= IRQ_FIRST) begin
                if      (((irq_cyc - IRQ_FIRST) % IRQ_PERIOD) == 0) Interrupt_0 <= 1'b1;
                else if (((irq_cyc - IRQ_FIRST) % IRQ_PERIOD) == 3) Interrupt_0 <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // SoC: the REAL MicroBlaze-V core
    // ------------------------------------------------------------------
    wire        TRACE_0_valid_instr, TRACE_0_jump_taken, TRACE_0_exception_taken;
    wire        TRACE_0_of_piperun, TRACE_0_ex_piperun, TRACE_0_mem_piperun, TRACE_0_mb_halted;
    wire [0:31] TRACE_0_pc, TRACE_0_instruction, TRACE_0_new_reg_value;
    wire [0:5]  TRACE_0_exception_kind;
    wire        TRACE_0_data_access, TRACE_0_data_read, TRACE_0_data_write, TRACE_0_reg_write;
    wire [0:31] TRACE_0_data_address, TRACE_0_data_write_value;
    wire [0:3]  TRACE_0_data_byte_enable;
    wire [0:4]  TRACE_0_reg_addr;

    mbv_ctrace_soc_wrapper soc (
        .clk(clk), .reset(soc_reset), .Interrupt_0(Interrupt_0),
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

    // ------------------------------------------------------------------
    // AMD TRACE bus -> mbv_trace_if
    //
    // Bit order: the buses are `[0:31]` VHDL-ascending. A packed vector assignment
    // copies value-correctly (LSB to LSB) regardless of declaration direction -- hence
    // NO mirroring. This matches the gate-G0 finding (Trace_PC == object dump without reversal).
    // ------------------------------------------------------------------
    mbv_trace_if mbv ();

    assign mbv.trace_pc              = TRACE_0_pc;
    assign mbv.trace_instruction     = TRACE_0_instruction;
    assign mbv.trace_valid_instr     = TRACE_0_valid_instr;
    assign mbv.trace_jump_taken      = TRACE_0_jump_taken;
    assign mbv.trace_exception_taken = TRACE_0_exception_taken;
    assign mbv.trace_exception_kind  = TRACE_0_exception_kind;
    assign mbv.trace_of_piperun      = TRACE_0_of_piperun;
    assign mbv.trace_ex_piperun      = TRACE_0_ex_piperun;
    assign mbv.trace_mem_piperun     = TRACE_0_mem_piperun;
    assign mbv.trace_halted          = TRACE_0_mb_halted;
    assign mbv.trace_data_access     = TRACE_0_data_access;
    assign mbv.trace_data_address    = TRACE_0_data_address;
    assign mbv.trace_data_read       = TRACE_0_data_read;
    assign mbv.trace_data_write      = TRACE_0_data_write;
    assign mbv.trace_data_write_value= TRACE_0_data_write_value;
    assign mbv.trace_data_byte_enable= TRACE_0_data_byte_enable;
    assign mbv.trace_reg_write       = TRACE_0_reg_write;
    assign mbv.trace_reg_addr        = TRACE_0_reg_addr;
    assign mbv.trace_new_reg_value   = TRACE_0_new_reg_value;

    // ------------------------------------------------------------------
    // Our adapter (gates G2+G3, unit testbenches green)
    // ------------------------------------------------------------------
    tip_if tip ();

    mbv_to_ctte_tip adapter (
        .clk       (clk),
        .rst       (tip_rst),
        .sijump_en (1'b0),      // G4/G5 baseline path: sijump off (default behavior)
        .mbv       (mbv.sink),
        .tip       (tip.master)
    );

    // ------------------------------------------------------------------
    // CTTE encoder (upstream, unchanged)
    // ------------------------------------------------------------------
    localparam int WB_DATA_WIDTH = 32;
    localparam int WB_ADDR_WIDTH = 32;

    wb_if #(.DATA_WIDTH(WB_DATA_WIDTH), .ADDR_WIDTH(WB_ADDR_WIDTH)) wb ();
    axis_if axis (.aclk(wb_clk), .aresetn(~wb_rst));
    atb_if  atb ();

    // CORE_XLEN(32): MicroBlaze V is an RV32 hart; the synced encoder (its
    // elaboration guard) requires the explicit setting. This run's tree is
    // the pinned third_party/CTTE (CT_XLEN = 32) -- the second guard
    // (CORE_XLEN != CT_XLEN) locks in the match.
    ct_encoder #(.SPLIT_DATA_ACCESS(0), .CORE_XLEN(32)) encoder (
        .tip_clk   (clk),
        .tip_rst   (tip_rst),
        .tip       (tip.slave),
        .wb_clk,   .wb_rst,   .wb, .ct_cs_rst,
        .axis,
        .atb_atclk, .atb_atresetn, .atb (atb),
        .proc_clk, .proc_rst,
        .wall_clk, .wall_clk_rst
    );

    // ------------------------------------------------------------------
    // CSR programming (upstream helper)
    // ------------------------------------------------------------------
    ct_cs_cpuif_wb_helper csr (
        .clk (wb_clk),
        .wb  (wb.master)
    );

    // ------------------------------------------------------------------
    // ATB sink: always ready. No stall injector -- gate G4 asks "does a correct
    // byte stream come out?", not "what happens under backpressure?" (overflow/resync is a separate test).
    //
    // atb_force_flush/-_sync: end-of-run hooks so the encoder drains its pipeline before the
    // simulation ends -- otherwise the offline decoder sees a truncated trace.
    // ------------------------------------------------------------------
    logic atb_force_flush = 1'b0;
    logic atb_force_sync  = 1'b0;

    assign atb.atready = 1'b1;
    assign atb.afready = 1'b1;
    assign atb.afvalid = atb_force_flush;
    assign atb.syncreq = atb_force_sync;
    assign axis.tready = 1'b1;

    atb_dump #(.FILEPATH(ATB_DUMP_PATH)) atb_recorder (
        .atb_atclk,
        .atb_atresetn,
        .atb (atb.monitor)
    );

    // ------------------------------------------------------------------
    // ATB byte counter: the G4 success criterion ("encoder emits bytes") is measured
    // here, not estimated.
    // ------------------------------------------------------------------
    int unsigned atb_beat_count = 0;
    always_ff @(posedge atb_atclk) begin
        if (!atb_atresetn) atb_beat_count <= 0;
        else if (atb.atvalid && atb.atready) atb_beat_count <= atb_beat_count + 1;
    end

    // Retire counter on the TIP side (cross-check: did the core deliver anything at all?)
    int unsigned tip_retire_count = 0;
    always_ff @(posedge clk) begin
        if (tip_rst) tip_retire_count <= 0;
        else if (tip.iretire) tip_retire_count <= tip_retire_count + 1;
    end

    // ------------------------------------------------------------------
    // TIP capture (debug): every cycle in which the encoder gets to see something.
    // IMPORTANT: the encoder evaluates `itype` ALSO when iretire=0 (upstream cpu_model:
    // "count_halfwords includes EXCEPTION_TRAP regardless of iretire") -- so this is
    // deliberately NOT filtered on iretire alone.
    // ------------------------------------------------------------------
    int unsigned tipdbg_fd = 0;
    int unsigned dbg_cyc   = 0;
    initial begin
        if (TIP_DEBUG_PATH != "") begin
            tipdbg_fd = $fopen(TIP_DEBUG_PATH, "w");
            $fwrite(tipdbg_fd, "cycle,iaddr,itype,iretire,ecause,valid,exc_taken,kind,instr\n");
        end
    end
    always_ff @(posedge clk) begin
        if (!tip_rst) begin
            dbg_cyc <= dbg_cyc + 1;
            if (tipdbg_fd != 0 && (tip.iretire || tip.itype != OTHER))
                $fwrite(tipdbg_fd, "%0d,0x%08h,%s,%0b,%0d,%0b,%0b,0x%02h,0x%08h\n",
                        dbg_cyc, tip.iaddr, tip.itype.name(), tip.iretire, int'(tip.ecause),
                        mbv.trace_valid_instr, mbv.trace_exception_taken,
                        mbv.trace_exception_kind, mbv.trace_instruction);
        end
    end

    // ------------------------------------------------------------------
    // G5 reference: the PC sequence an N-Trace decoder MUST reconstruct.
    //
    // This is NOT the same as "the retiring PCs":
    //   - every retiring instruction (iretire=1)                              -> belongs in it
    //   - PLUS the faulting instruction on EXCEPTION_TRAP (iretire=0)         -> belongs in it
    //   - NOT the preempted instruction on INTERRUPT (iretire=0)              -> does NOT belong in it
    //
    // Rationale (upstream convention, not our invention) -- cpu_model.sv, exception_trap():
    //   "The encoder's `count_halfwords` includes EXCEPTION_TRAP regardless of iretire (see
    //    composer_etip), so the decoder still walks the faulting instruction and reconstructs its
    //    PC (mepc) even though it never retired. The faulting PC therefore still appears once in
    //    expected.pcs".
    // The faulting instruction was executed (attempted) -- the decoder emits its PC.
    // The instruction preempted by an interrupt, by contrast, did NOT run and is repeated after
    // the mret (an earlier gate-G1 round disproved the alternative hypothesis) -- it appears
    // there, not here.
    //
    // IMPORTANT -- the reference is tapped at the TIP side of the adapter, i.e. AFTER our
    // iretire rule. That is deliberate, not self-confirmation: gate G0 independently established
    // that this rule holds (TRACE retire sequence == object dump, 7/7 at 4000/4000 each). Gate G5
    // checks the question that follows from it: does the encoder+decoder path reproduce exactly
    // this sequence? The reference also cannot make the test "pass": it only adds PCs that the
    // decoder must independently reconstruct from the byte stream.
    // ------------------------------------------------------------------
    int unsigned pcs_fd = 0;
    initial begin
        if (RETIRED_PCS_PATH != "") begin
            pcs_fd = $fopen(RETIRED_PCS_PATH, "w");
            if (pcs_fd == 0) $fatal(1, "mbv_ctte_env: cannot write %s", RETIRED_PCS_PATH);
        end
    end

    // Ground truth = RETIRING instructions (iretire=1). The trapped, non-retiring instruction
    // (EXCEPTION_TRAP, iretire=0) does NOT belong in it -- spec-backed iretire rule, matching AMD
    // 1:1 and the fixed CTTE encoder (composer_etip count_halfwords = iretire).
    always_ff @(posedge clk) begin
        if (!tip_rst && pcs_fd != 0 && tip.iretire)
            $fwrite(pcs_fd, "0x%08h\n", tip.iaddr);
    end

    final begin
        if (pcs_fd != 0) $fclose(pcs_fd);
    end

endmodule : mbv_ctte_env

`default_nettype wire
