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

| # | Directory | Scenario | Verification |
|---|-----------|----------|--------------|
| 01 | `01_all/` | Mixed workload with instruction trace + data trace + ACT-CAP instrumentation on together: linear code, a taken branch, a call and a return, varied-size loads/stores, and one `ACT_CAP_ST_CF_SYNC` (CSR-CAP initiated instruction synchronization) mid-stream. | Three offline checks on one trace: PC stream (`decode_and_check.sh`), DataRead/DataWrite sequence (`decode_and_check_data.sh`), and synchronization-message count (`decode_and_check_sync.sh`, ≥ 2: startup + CF_SYNC). `make sim-combined`, part of `make sim`. |

### Deferred (future additions to 01_all or siblings)

- **Interrupts/exceptions** alongside data trace.
- **Timestamps** on — kept off here for a deterministic, minimal byte
  stream for the offline NexRv decode.

## What this group does NOT cover

- Overflow / reset → [`../overflow/`](../overflow/) (kept separate
  because its assertions are different — error path, not happy path).

## Conventions

The test follows the standard skeleton documented in
[`../lib/README.md`](../lib/README.md). The expectation is that this
is the longest-running test in the suite, but still well under the
per-PR CI budget (synthetic stimulus, so a few seconds rather than
minutes).
