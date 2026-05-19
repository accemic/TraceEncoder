<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `tests/lib/` — shared verification infrastructure

Every top-level testbench under `tests/<feature>/` reuses the modules
here. Nothing in this directory is itself a runnable test.

## Contents

| File | Purpose |
|------|---------|
| `ctrace_env.sv` + `.abc` | Single-instance test harness around `ct_encoder`. Generates clocks (`tip_clk`, `atb_atclk`, `proc_clk`, `wb_clk`, `wall_clk`) and resets for all five clock domains, instantiates the DUT, plugs in the `cpu_model`, the `ct_cs_cpuif_wb_helper`, an ATB stall injector + always-ready sink, and ATB / AXIS dumpers. Exposes `cpu`, `csr`, `atb_force_stall`, `atb_bytes_seen`, `axis_xfers_seen` for tests to drive and observe. Scoreboarding is currently minimal — counts + `$display`; a proper N-Trace decode-vs-event-log scoreboard is a planned follow-up. |
| `cpu_model.sv` + `.abc` | Scripted CPU model that drives the TIP interface. Task-based API: `.enter() / .exit_trace() / .run() / .jump_to() / .branch_taken() / .branch_not_taken() / .call_to() / .ret() / .uninferable_jump() / .interrupt() / .exception_trap() / .mret() / .load_data() / .store_data() / .csr_write() / .idle()`. Each task drives TIP **and** appends a high-level event to `event_q`. Time advances implicitly: every retired instruction takes `CYCLES_PER_INSTR` `tip_clk` cycles. |
| `pkg/cpu_model_pkg.sv` + `.abc` | `cpu_event_kind_e` enum + `cpu_event_t` record used by the model and (eventually) the scoreboard. |
| `ct_cs_cpuif_wb_helper.sv` + `.abc` | Wishbone CSR programming helpers (`Set_te_trTeControl_Enable`, `Set_te_trTeControl_InstTracing`, `Set_te_trTeControl_Active`, …). Used by `ctrace_env`'s `csr` instance. Should eventually be regenerated from `rdl/` rather than hand-maintained. |
| `ct_nexus_decoder.sv` + `.abc`, `nexus_msg_helper.sv` + `.abc` | Decode the encoder's ATB-side Nexus message stream into SystemVerilog structs. Building blocks for the (planned) scoreboard. |
| `ct_axis_decoder.sv` + `.abc`, `pkg/ct_axis_decoder_pkg.sv` | AXIS-side payload unpacker. |
| `ct_axis_dump.sv` + `.abc`, `tip_dump.sv` + `.abc`, `ct_encoder_top.sv` + `.abc` | Inherited debug / synthesis-wrapper utilities. The dumpers write transfer logs to files for post-mortem inspection. |
| `pkg/trace_utils_pkg.sv` (placeholder) | Future home for N-Trace decode utilities. Not present yet. |

## Why a scripted CPU model and not a real core?

A real RISC-V core (e.g. Ibex) running a meaningful C program is
order-of-minutes per test in Vivado xsim. Running 30+ such tests on
every PR is impractical. `cpu_model` runs in seconds, is
deterministic, and is easier to author for specific edge cases.

A single real-core example lives separately at
[`../../examples/ibex_smoke/`](../../examples/ibex_smoke/) and runs as
a nightly CI job (placeholder for now). There is no binary-trace
player; the C source under `examples/` is the canonical "real run"
reference.

## Standard testbench skeleton

```systemverilog
module foo_tb;
    import cpu_model_pkg::*;
    ctrace_env env ();

    initial begin
        env.wait_for_reset_release();

        // 1. Configure
        env.csr.Set_te_trTeControl_Enable      (1'b1);
        env.csr.Set_te_trTeControl_InstTracing (1'b1);
        env.csr.Set_te_trTeControl_Active      (1'b1);
        env.wait_cycles(20);

        // 2. Drive stimulus
        env.cpu.enter(.start_pc(32'h1000));
        env.cpu.run(16);
        env.cpu.branch_taken(.target(32'h1080));
        env.cpu.run(8);
        env.cpu.exit_trace();

        // 3. Let in-flight messages drain
        env.wait_cycles(2000);

        // 4. Check
        if (env.atb_bytes_seen == 0) $error("no ATB output");
        $display("PASS");
        $finish;
    end
endmodule
```

See [`../instruction/01_basic/`](../instruction/01_basic/) and
[`../overflow/01_run_overflow_reset/`](../overflow/01_run_overflow_reset/)
for the first two worked examples.

## Known limitations (planned follow-ups)

- **Scoreboarding is minimal**: `atb_bytes_seen > 0` is the current
  "PASS" signal. A proper scoreboard would feed the ATB stream through
  `ct_nexus_decoder` and cross-check each decoded message against the
  `cpu_model.event_q` log. The infrastructure for that decoder is
  imported and ready; the comparison code is not yet written.
- **Timestamps**: every test enables timestamps implicitly (the
  `cpu_model.r_time` counter ticks every `tip_clk` and the encoder
  emits timestamp messages when warranted), but there is no dedicated
  CSR helper yet to toggle the timestamp-message-mode bit. Once it
  lands, every test will call it.
- **CSR helper bit-fields**: `ct_cs_cpuif_wb_helper.sv` was imported as
  hand-written code. The plan calls for regenerating it from
  `rdl/ct_cs_cpuif.rdl` so the constants stay in sync.
- **RV-C / split-load**: `cpu_model` currently models 32-bit
  instructions only and uses the encoder's legacy data-trace mode
  (`SPLIT_DATA_ACCESS=0`). Split-load tests under
  `tests/data/03_split_access/` will extend the model.
