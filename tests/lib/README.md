<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `tests/lib/` — shared verification infrastructure

Every top-level testbench under `tests/<feature>/` reuses the modules
here. Nothing in this directory is itself a runnable test.

## Planned contents

| File | Purpose |
|------|---------|
| `ctrace_env.sv` + `.abc` | Full test environment: DUT (encoder) + Wishbone CSR programmer + ATB / AXIS sinks + decoder + `cpu_model` instance. Testbenches instantiate `ctrace_env` and drive it. |
| `cpu_model.sv` + `.abc` | Scripted CPU model that mimics a RISC-V core. Testbenches call tasks (`.enter()`, `.run()`, `.branch_taken()`, `.call()`, `.ret()`, `.interrupt()`, `.load()`, `.store()`, `.csr_write()`, …) and the model drives the TIP interface. Time advances implicitly per task; a per-instruction cycle-cost knob lets tests stress timestamp behaviour. |
| `csr_helper.sv` + `.abc` | Wishbone CSR programming helpers (enable trace, set filters, etc.). Once `rdl/` is ported, this should be generated from RDL rather than hand-written. |
| `nexus_decoder.sv` + `.abc` | Decodes the encoder's ATB / AXIS output into SystemVerilog structs the scoreboard can consume. |
| `trace_scoreboard.sv` + `.abc` | Cross-checks the `nexus_decoder` output against the event log emitted by `cpu_model`. The fact that the two must agree IS the test — there is no separate golden file. |
| `pkg/cpu_model_pkg.sv` + `.abc` | Types used by `cpu_model`: `priv_e`, `event_e`, `cpu_event_t`, etc. |
| `pkg/trace_utils_pkg.sv` + `.abc` | N-Trace message helpers (field unpackers, pretty-printers, common predicates). |

## Why a scripted CPU model and not a real core?

A real RISC-V core (e.g. Ibex) running a meaningful C program is
order-of-minutes per test in Vivado xsim. Running 30+ such tests on
every PR is impractical. The `cpu_model` runs in seconds, is
deterministic, and is easier to author for specific edge cases.

A single real-core example lives separately at
[`../../examples/ibex_smoke/`](../../examples/ibex_smoke/) and runs as
a nightly CI job — it doubles as the integration tutorial. There is
no binary-trace player; the C source under `examples/` is the
canonical "real run" reference.

## Testbench skeleton (pattern every TB follows)

```systemverilog
ctrace_env env();
initial begin
  env.csr.enable_instruction_trace();
  env.csr.enable_timestamps();        // every test enables timestamps
  env.cpu.enter(.start_pc(32'h1000));
  env.cpu.run(16);
  env.cpu.branch_taken(.target(32'h1080));
  env.cpu.run(8);
  env.cpu.exit();
  env.scoreboard.check();              // cross-checks decoder output vs cpu_model log
  $finish;
end
```
