<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `tests/overflow/` — backpressure, overflow, and reset

Cross-cutting tests for the encoder's overflow and reset behaviour.
This group's single test sweeps the full "something went wrong, then
we recovered" cycle.

## Test matrix

| # | Directory | Scenario |
|---|-----------|----------|
| 01 | `01_run_overflow_reset/` | **run → overflow → reset → run**. The testbench (a) drives a normal short scenario via `cpu_model`, (b) deliberately stalls the ATB / AXIS sink to provoke an overflow message from the encoder, (c) applies a reset, (d) drives another normal scenario and confirms the encoder resumes tracing cleanly. |

The scoreboard checks for **three** things in sequence:

1. The first run produces the expected instruction-trace messages.
2. After backpressure is applied, the encoder emits an **overflow
   indication** (the exact message type depends on the encoder's
   error-reporting protocol).
3. After reset, the second run produces clean output again — no
   leftover state, no spurious messages.

## What this group does NOT cover

- Functional correctness of individual features → see
  [`../instruction/`](../instruction/), [`../data/`](../data/),
  [`../hsi/`](../hsi/).

## Conventions

The test directory contains `<name>_tb.sv` + `<name>_tb.abc`,
following the standard skeleton documented in
[`../lib/README.md`](../lib/README.md), with an extra hook in
`ctrace_env` to assert and release ATB/AXIS backpressure on demand
(provided by the env's sink models).
