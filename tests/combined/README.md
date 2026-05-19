<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `tests/combined/` — everything together

A single end-to-end test that enables **all** features at once
(instruction trace + data trace + HSI + timestamps) and runs a
realistic mixed workload. Lands after the per-feature groups already
pass — its purpose is to catch interactions that the per-feature
tests miss in isolation.

## Test matrix

| # | Directory | Scenario | `cpu_model` tasks exercised |
|---|-----------|----------|------------------------------|
| 01 | `01_all/` | Realistic mixed workload: linear code, branches, calls/returns, a couple of interrupts, varied-size loads/stores, HSI events from CSR writes — all with timestamps on. Scoreboard verifies the full decoded message stream. | Most of the `cpu_model` task surface. |

## What this group does NOT cover

- Overflow / reset → [`../overflow/`](../overflow/) (kept separate
  because its assertions are different — error path, not happy path).

## Conventions

The test follows the standard skeleton documented in
[`../lib/README.md`](../lib/README.md). The expectation is that this
is the longest-running test in the suite, but still well under the
per-PR CI budget (synthetic stimulus, so a few seconds rather than
minutes).
