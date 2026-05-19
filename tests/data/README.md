<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `tests/data/` — data-trace tests

System-level tests for the encoder's data-trace path.
Every test in this directory enables timestamps via CSR and the
scoreboard verifies that timestamp messages interleave correctly with
the data-trace messages — there is no separate `timestamp/` group.

## Test matrix

| # | Directory | Scenario | `cpu_model` tasks exercised |
|---|-----------|----------|------------------------------|
| 01 | `01_basic/` | Combined basic: loads and stores at varied sizes (byte, halfword, word, doubleword). Smoke test for the whole data-trace path. | `load / store` (with size variants) |
| 02 | `02_address_filter/` | CSR-programmed data-address range filter — encoder must only trace loads/stores within the configured range. | `load / store`, plus an address-range setup via `csr_helper` |
| 03 | `03_split_access/` | Exercises the encoder's `SPLIT_DATA_ACCESS` parameter — verifies that split load/store accesses generate the expected message sequence. | `load / store` with addresses crossing the split boundary |

## What this group does NOT cover

- Instruction-flow tracing → [`../instruction/`](../instruction/)
- HSI events → [`../hsi/`](../hsi/)
- Overflow / reset → [`../overflow/`](../overflow/)
- Everything-at-once → [`../combined/`](../combined/)

## Conventions

Each test directory contains `<name>_tb.sv` + `<name>_tb.abc`,
following the standard skeleton documented in
[`../lib/README.md`](../lib/README.md).

These tests enable **only** data trace (no instruction trace) so that
the data-path behaviour is observed in isolation. The combined view
lives in [`../combined/`](../combined/).
