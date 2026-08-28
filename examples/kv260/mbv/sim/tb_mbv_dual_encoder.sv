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
// tb_mbv_dual_encoder -- drives both encoder branches from ONE core and captures both.
//   Branch B (CTTE): program the CSRs -> ATB -> mbv_dual.atb.bin  (verified G4/G5 chain)
//   Branch A (AMD native): Dbg_Trace port  -> mbv_dual.native.hex
//
// Success criteria (measured):
//   1. Core retires (tip_retire_count > 0).
//   2. CTTE emits ATB beats after enable (branch B carries).
//   3. AMD beats: REPORT-only. 0 is the known, documented enable blocker -- NOT a FAIL, otherwise
//      the branch-B proof could never turn green while the AMD enable remains open. Once the
//      enable is resolved, this criterion will be armed (native_beats > 0).
`timescale 1ns/1ps
`default_nettype none

module tb_mbv_dual_encoder;

    int unsigned RUN_CYCLES = 4000;

    mbv_dual_encoder_env #(
        .ATB_DUMP_PATH    ("mbv_dual.atb.bin"),
        .NATIVE_DUMP_PATH ("mbv_dual.native.hex"),
        .RETIRED_PCS_PATH ("mbv_dual.retired.pcs")
    ) env ();

    int unsigned beats_before_enable, beats_after;
    int n_fail = 0;

    initial begin
        if ($value$plusargs("RUN_CYCLES=%d", RUN_CYCLES))
            $display("[tb_dual] RUN_CYCLES per plusarg = %0d", RUN_CYCLES);
        if ($test$plusargs("IRQ")) begin
            env.irq_enable = 1'b1;
            $display("[tb_dual] interrupt stimulus ACTIVE");
        end

        $display("[tb_dual] %0t: waiting for encoder reset release", $time);
        env.wait_for_reset_release();

        // --- Configure CTTE (branch B) while the core is in reset ---
        env.csr.clear();

        // Compression suite (branch B only -- AMD has none of these features; the
        // three-way comparison runs at the PC level and must still be green):
        //   +CTTE_HIST : IR + RepeatedHistory + RepeatBranch + WideICNT + JTC
        //   +CTTE_BP   : IR + BranchPrediction + WideICNT + JTC (NexRv -bp!)
        // Order: features BEFORE enable. The eight InstEn* bits have been
        // `swwel`-locked since an earlier audit (rdl/ct_cs_cpuif.rdl) --
        // a write at Enable=1 is silently swallowed WITHOUT an error response, so the
        // run would look like ineffective compression instead of like a
        // write error. tb_mbv_g4_ctte.sv has always done it this way.
        if ($test$plusargs("CTTE_HIST")) begin
            env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnRepeatedHistory(1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnRepeatBranch   (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt       (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache(1'b1);
            $display("[tb_dual] CTTE features: HIST family (IR+RH+RB+WideICNT+JTC)");
        end
        if ($test$plusargs("CTTE_BP")) begin
            env.csr.Set_te_trTeInstFeatures_InstEnImplicitReturn  (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnBranchPrediction(1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnWideIcnt        (1'b1);
            env.csr.Set_te_trTeInstFeatures_InstEnJumpTargetCache (1'b1);
            $display("[tb_dual] CTTE features: BP family (IR+BP+WideICNT+JTC)");
        end

        env.csr.Set_te_trTeControl_Enable      (1'b1);
        env.csr.Set_te_trTeControl_InstTracing (1'b1);
        env.csr.Set_te_trTeControl_Active      (1'b1);
        $display("[tb_dual] %0t: CTTE CSR: Enable=1 InstTracing=1 Active=1", $time);
        env.wait_cycles(20);

        // --- AMD's native encoder (branch A): runtime enable HERE, once the register path is up. ---
        // KNOWN BLOCKER: programming the N-Trace registers via S_AXI_DEBUG (needs the UG1629 map).
        // Until then branch A stays silent; the run proves branch B + the coexistence of both encoders.

        beats_before_enable = env.atb_beat_count;
        $display("[tb_dual] %0t: before core start: ATB beats=%0d, AMD beats=%0d, TIP retires=%0d",
                 $time, beats_before_enable, env.native_beats, env.tip_retire_count);

        env.release_core();
        $display("[tb_dual] %0t: core started", $time);

        // Arm AMD's native encoder -- S_AXI only responds while the core is running, hence HERE
        // (not before the start, as with CTTE). The native branch starts ~10 instructions later.
        env.arm_native_trace();
        $display("[tb_dual] %0t: AMD encoder armed (BTM, timestamps off)", $time);

        env.wait_cycles(RUN_CYCLES);

        // Drain the CTTE pipeline
        env.atb_force_flush = 1'b1; env.atb_force_sync = 1'b1;
        env.wait_cycles(200);
        env.atb_force_flush = 1'b0; env.atb_force_sync = 1'b0;
        env.wait_cycles(50);

        // Flush the AMD encoder (closes the trace history -> NexRv emits all PCs)
        env.flush_native_trace();
        env.wait_cycles(400);

        beats_after = env.atb_beat_count;

        $display("[tb_dual] ---- result ----");
        $display("[tb_dual] TIP retires   : %0d", env.tip_retire_count);
        $display("[tb_dual] CTTE ATB   : %0d beats (branch B)", beats_after);
        $display("[tb_dual] AMD native    : %0d beats (branch A)", env.native_beats);

        if (env.tip_retire_count == 0) begin
            n_fail++; $display("[tb_dual] FAIL: core retired nothing");
        end
        // Since an earlier fix (SendConfig reset = CFG_ONCE), CTTE emits the
        // vendor config message TCODE 58 on the trace-start edge -- BEFORE the
        // core runs. A few pre-start beats are therefore expected (and their
        // absence would be the bug); more than ~8 beats would again mean
        // "branch B is unclean".
        if (beats_before_enable == 0) begin
            n_fail++; $display("[tb_dual] FAIL: config message missing before core start (SendConfig reset=CFG_ONCE)");
        end else if (beats_before_enable > 8) begin
            n_fail++; $display("[tb_dual] FAIL: %0d ATB beats while the core stood still (more than the config message -- branch B unclean)", beats_before_enable);
        end else begin
            $display("[tb_dual] ok  : config message before core start (%0d beats, TCODE 58/CFG_ONCE)", beats_before_enable);
        end
        if (beats_after <= beats_before_enable) begin
            n_fail++; $display("[tb_dual] FAIL: CTTE emitted nothing (branch B does not carry)");
        end else begin
            $display("[tb_dual] ok  : CTTE branch B carries (%0d beats)", beats_after - beats_before_enable);
        end

        if (env.native_beats == 0) begin
            n_fail++;
            $display("[tb_dual] FAIL: AMD branch A silent -- encoder enable via S_AXI did not take (BRESP? core running?)");
        end else begin
            $display("[tb_dual] ok  : AMD branch A emits (%0d beats) -> un-framer (le_strip_ff) + NexRv -src 0", env.native_beats);
        end

        if (n_fail != 0) $fatal(1, "[tb_dual] %0d criterion/criteria FAILED", n_fail);
        $display("[tb_dual] PASS - dual-encoder harness carries: both encoders emit, PC comparison offline");
        $finish;
    end

    initial begin
        #3ms;
        $fatal(1, "[tb_dual] TIMEOUT");
    end

endmodule : tb_mbv_dual_encoder

`default_nettype wire
