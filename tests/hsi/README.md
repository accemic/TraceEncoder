<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `tests/hsi/` — hardware-supported instrumentation tests

System-level tests for the encoder's HSI (hardware-supported
instrumentation) path. HSI events are driven via CSR writes from
software — the `cpu_model` issues `.csr_write()` calls to trigger
them.

Every test in this directory enables timestamps via CSR and the
scoreboard verifies that timestamp messages interleave correctly with
the HSI messages.

## Test matrix

| # | Directory | Scenario | `cpu_model` tasks exercised |
|---|-----------|----------|------------------------------|
| 01 | `01_csr_cap/` | HSI event triggered via a write to the CSR-CAP register. Scoreboard verifies the encoder emits the corresponding HSI message. | `csr_write` (to the CAP command register) |
| 02 | `02_csr_st/` | HSI event triggered via a write to the CSR-ST register. Scoreboard verifies the corresponding HSI message. | `csr_write` (to the ST command register) |

## What this group does NOT cover

- Instruction-flow tracing → [`../instruction/`](../instruction/)
- Data tracing → [`../data/`](../data/)
- Overflow / reset → [`../overflow/`](../overflow/)
- HSI alongside instruction + data trace → [`../combined/`](../combined/)

## Conventions

Each test directory contains `<name>_tb.sv` + `<name>_tb.abc`,
following the standard skeleton documented in
[`../lib/README.md`](../lib/README.md).

These tests enable **only** HSI (no instruction or data trace) so the
HSI path is observed in isolation.
