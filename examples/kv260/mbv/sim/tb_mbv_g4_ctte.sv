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
// NEEDS VIVADO. Through its environment module this bench instantiates
// `mbv_ctrace_soc_wrapper` -- the module Vivado's make_wrapper generates from
// the `mbv_ctrace_soc` block design at build time, around the ENCRYPTED
// MicroBlaze-V core. It has no in-repo .sv source by design, so there is no
// path through Verilator for this bench: it runs under xsim, inside a project created
// by ../fpga/create_project_kv260.tcl. Recipe and the measured failure signature:
// this directory's README.md.
//
//
// tb_mbv_g4_ctte -- gate G4: real MicroBlaze-V core -> adapter -> CTTE encoder -> ATB.
//
// G4 question: does the chain carry? Does the encoder accept our TIP events and emit an
// N-Trace byte stream? The CONTENT of that stream is gate G5's concern (NexRv decode == oracle) --
// here we deliberately do NOT claim the trace is correct, only that it is produced.
//
// Success criteria (all measured, none estimated):
//   1. The core retires at all (tip_retire_count > 0)      -- otherwise the rest measures nothing.
//   2. The encoder emits ATB beats after enable             -- the chain carries.
//   3. NOTHING arrives before enable                        -- cross-check: the bytes come from
//      our trace, not from reset garbage/X propagation.
`timescale 1ns/1ps
`default_nettype none

module tb_mbv_g4_ctte;

    // Run length: enough for the COE program run; overridable via -testplusarg.
    int unsigned RUN_CYCLES = 4000;
    string       atb_path;

    mbv_ctte_env #(
        .ATB_DUMP_PATH    ("mbv_g4.atb.bin"),
        .RETIRED_PCS_PATH ("mbv_g4.retired.pcs"),  // G5 reference
        .TIP_DEBUG_PATH   ("mbv_g4.tip.csv")       // debug: what the encoder actually sees
    ) env ();

    int unsigned beats_before_enable, beats_after;
    int n_fail = 0;

    initial begin
        // Colon form first: xsim 2026.1 splits `-testplusarg NAME=VALUE` on the
        // equals sign ("Expected a switch but found ...") -- the
        // `=` form remains as a fallback for direct xsim calls with quoting.
        if ($value$plusargs("RUN_CYCLES:%d", RUN_CYCLES) || $value$plusargs("RUN_CYCLES=%d", RUN_CYCLES))
            $display("[tb_g4] RUN_CYCLES per plusarg = %0d", RUN_CYCLES);

        // +IRQ: enable periodic interrupt stimulus (for interrupt_test).
        // Without it, interrupt_test would run through the chain without ever seeing an interrupt.
        if ($test$plusargs("IRQ")) begin
            env.irq_enable = 1'b1;
            $display("[tb_g4] interrupt stimulus ACTIVE (periodic, coprime with the loop)");
        end

        $display("[tb_g4] %0t: waiting for encoder reset release (core stays in reset)", $time);
        env.wait_for_reset_release();
        $display("[tb_g4] %0t: encoder resets released", $time);

        // --- Configure the encoder WHILE the core is still in reset ---
        // Otherwise the program (~85 instructions) finishes before the Wishbone transactions
        // complete, and we would only trace the _exit infinite loop.
        env.csr.clear();
        // +SUITE_ISYNC: campaign configuration of the sync-boundary family
        // (full suite + sync_i16). Features are
        // enable-locked -> write BEFORE enable. Bisecting encoder-vs-adapter:
        // the plain encoder (tests/overflow/07_board_replay) is clean on the
        // board sequence; if THIS path (real core + adapter) breaks,
        // the defect sits in the adapter/SoC path.
        if ($test$plusargs("SUITE_ISYNC")) begin
            env.csr.Set_te_trTeControl_InstSyncMode (4'd6);   // ITR_SYNC_INSTRUCTIONS
            env.csr.Set_te_trTeControl_InstSyncMax  (4'd0);   // 2^4 = 16 Instr
            env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache  (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn   (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory  (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt         (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch     (1'b1);
            $display("[tb_g4] SUITE_ISYNC: suite + sync_i16 active (campaign config)");
        end
        // +ROB_SUITE: board campaign config of the mix class (bisector):
        // full suite x sync_off, timestamps ACTIVE (the campaign never writes
        // trTsControl -> active on the board; gates G07/G10 replicate the same).
        // If THIS path (real core + adapter + board clock profile via
        // +PROC_HALF_NS/+ATB_HALF_NS) breaks, the defect sits in the adapter/SoC path;
        // the plain encoder core is clean on the board sequence (gate G10).
        if ($test$plusargs("ROB_SUITE")) begin
            env.csr.Set_te_trTsControl_Active (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn   (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache  (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory  (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt         (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch     (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnIbhs             (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnRepeatInstr      (1'b1);
            $display("[tb_g4] ROB_SUITE: Suite + TS + sync_off (Board-Kampagnen-Config)");
        end
        env.csr.Set_te_trTeControl_Enable      (1'b1);
        env.csr.Set_te_trTeControl_InstTracing (1'b1);
        env.csr.Set_te_trTeControl_Active      (1'b1);
        $display("[tb_g4] %0t: CSR: Enable=1 InstTracing=1 Active=1", $time);
        env.wait_cycles(20);

        // --- Cross-check: the encoder is armed but the core stood still -> nothing may be there.
        beats_before_enable = env.atb_beat_count;
        $display("[tb_g4] %0t: before core start: ATB beats=%0d, TIP retires=%0d",
                 $time, beats_before_enable, env.tip_retire_count);

        // --- Start the core: from now on the program is traced from the FIRST instruction ---
        env.release_core();
        $display("[tb_g4] %0t: core started", $time);

        // --- Run: the core executes the COE program, the adapter feeds the encoder ---
        env.wait_cycles(RUN_CYCLES);

        // --- Drain the pipeline so the offline decoder sees a complete trace ---
        env.atb_force_flush = 1'b1;
        env.atb_force_sync  = 1'b1;
        env.wait_cycles(200);
        env.atb_force_flush = 1'b0;
        env.atb_force_sync  = 1'b0;
        env.wait_cycles(50);

        beats_after = env.atb_beat_count;

        // --- Evaluation ---
        $display("[tb_g4] ---- result ----");
        $display("[tb_g4] TIP retires : %0d", env.tip_retire_count);
        $display("[tb_g4] ATB beats   : %0d (of which before enable: %0d)", beats_after, beats_before_enable);

        if (env.tip_retire_count == 0) begin
            n_fail++;
            $display("[tb_g4] FAIL: the core retired NOTHING - check SoC/COE (the rest then measures nothing)");
        end else begin
            $display("[tb_g4] ok  : core retired (%0d instructions)", env.tip_retire_count);
        end

        if (beats_before_enable != 0) begin
            n_fail++;
            $display("[tb_g4] FAIL: %0d ATB beats while the core was standing still - the stream does not come from our trace",
                     beats_before_enable);
        end else begin
            $display("[tb_g4] ok  : no ATB activity while the core stood still (cross-check)");
        end

        if (beats_after <= beats_before_enable) begin
            n_fail++;
            $display("[tb_g4] FAIL: encoder emitted no ATB beats after the core started - chain does not carry");
        end else begin
            $display("[tb_g4] ok  : encoder emits %0d ATB beats after the core started",
                     beats_after - beats_before_enable);
        end

        if (n_fail != 0) $fatal(1, "[tb_g4] %0d criterion/criteria FAILED", n_fail);
        $display("[tb_g4] PASS - G4 chain carries (content is checked against NexRv in gate G5)");
        $finish;
    end

    // Emergency brake: if the sim hangs (e.g. a CSR handshake without a response), do not run forever.
    // Long rob_stress runs (~800k cycles = 8 ms + drain) raise the
    // threshold via +TIMEOUT_MS; the default remains the proven 2 ms brake.
    initial begin
        int unsigned timeout_ms = 2;
        if (!$value$plusargs("TIMEOUT_MS:%d", timeout_ms))
            void'($value$plusargs("TIMEOUT_MS=%d", timeout_ms));
        #(timeout_ms * 1ms);
        $fatal(1, "[tb_g4] TIMEOUT (%0d ms) - sim hangs (CSR handshake? clock/reset?)", timeout_ms);
    end

endmodule : tb_mbv_g4_ctte

`default_nettype wire
