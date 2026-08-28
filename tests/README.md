<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# High-level tests

This directory is for **high-level / system / integration testbenches**
only — anything that exercises CEDARtools.TraceEncoder end-to-end or spans
multiple
modules.

**Per-module unit testbenches do not live here.** They live next to
the module they test, under `rtl/<module>/test/`. See
[`../rtl/README.md`](../rtl/README.md) for the module-test convention.

## Layout

| Directory | What it tests |
|-----------|---------------|
| [`lib/`](lib/) | Shared verification infrastructure: `ct_env`, `cpu_model`, `csr_helper`, `nexus_decoder`, `trace_scoreboard`, helper packages. Not runnable on its own. |
| [`instruction/`](instruction/) | Instruction-trace feature tests (basic, interrupts, address filter). |
| [`data/`](data/) | Data-trace feature tests (basic, address filter, split access). |
| [`hsi/`](hsi/) | Hardware-supported instrumentation tests (CSR-CAP, CSR-ST). |
| [`overflow/`](overflow/) | Cross-cutting overflow + reset test (run → overflow → reset → run). |
| [`combined/`](combined/) | Single end-to-end test exercising all features at once. |

**Timestamps** are not a separate category — every test enables them
via CSR and the scoreboard verifies they interleave correctly with the
data path.

## Stimulus

Tests are driven by a **scripted CPU model**
([`lib/cpu_model.sv`](lib/cpu_model.sv)) that mimics a RISC-V core via a
task-based API (`enter / run / branch_taken / call / ret / interrupt /
load / store / csr_write / …`). The model both drives the encoder's TIP
interface AND logs a sideband event stream that the scoreboard
cross-checks against the decoded encoder output. No real binary is
needed — the tasks themselves are the program.

There is no binary-trace player in the suite.

See the **Testbench skeleton** section below.

## Conventions

- Each test directory is named `NN_<scenario>/` with a numeric prefix
  so tests sort simple → sophisticated.
- Inside, a `<scenario>_tb.sv` + `<scenario>_tb.abc` pair drives the
  simulation under `abc -sim`.
- SPDX header on every file.
- `make lint` + `make sim` must pass before submitting.

## Testbench skeleton

A test instantiates the shared `ct_env`
([`lib/ct_env.sv`](lib/ct_env.sv)) — which wires `cpu_model`,
the DUT, and the trace sinks together — drives the scenario through the
`cpu_model` task API, then writes the `expected.*` reference files the
[`scripts/decode_and_check.sh`](../scripts/decode_and_check.sh) check
diffs against the NexRv decode.
