<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `tests/instruction/` — instruction-trace tests

System-level tests for the encoder's instruction-trace path.
Every test in this directory enables timestamps via CSR and the
scoreboard verifies that timestamp messages interleave correctly with
the instruction-trace messages — there is no separate `timestamp/`
group.

## Test matrix

| # | Directory | Scenario | `cpu_model` tasks exercised |
|---|-----------|----------|------------------------------|
| 01 | `01_basic/` | Combined basic: linear execution, conditional branches (taken + not-taken), function calls, returns. Smoke test for the whole instruction-trace path. | `enter / run / branch_taken / branch_not_taken / call / ret / exit` |
| 02 | `02_interrupts/` | Instruction trace through interrupts and exceptions, including `mret` returns. Covers traps that fire mid-linear-flow and back-to-back interrupts. | `interrupt / exception / mret` (in addition to `01_basic` set) |
| 03 | `03_address_filter/` | CSR-programmed PC-range filter — encoder must only trace instructions within the configured range. | `uninferable_jump`, plus a PC-range setup via `csr_helper` |

## What this group does NOT cover

- Data accesses → [`../data/`](../data/)
- HSI events → [`../hsi/`](../hsi/)
- Overflow / reset → [`../overflow/`](../overflow/)
- Everything-at-once → [`../combined/`](../combined/)

## Conventions

Each test directory contains `<name>_tb.sv` + `<name>_tb.abc`. The
testbench:

1. Instantiates `ctrace_env` from [`../lib/`](../lib/).
2. Programs the encoder to enable instruction trace (+ timestamps).
3. Runs a scripted `cpu_model` scenario.
4. Lets `trace_scoreboard` check the decoded output against the
   `cpu_model` event log.
5. `$finish` with PASS / FAIL.
