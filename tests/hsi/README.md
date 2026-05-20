<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `tests/hsi/` — hardware-supported instrumentation tests

System-level tests for the encoder's HSI (hardware-supported
instrumentation) path. HSI events are driven via the ACT-CAP CSR
protocol: the `cpu_model` issues `.act_cap_cmd()` calls, which model the
CPU executing `csrw 0x0B10, x` — a functional NOP the encoder observes
on the TIP data channel and turns into an instrumentation message (DAQ
on the Nexus and/or AXIS sink). See `rdl/ct_cs_cpuif.rdl`
`trActCapStCmd_e` for the command set.

## Test matrix

| # | Directory | Scenario | Verification |
|---|-----------|----------|--------------|
| 01 | `01_csr_cap/` | ACT-CAP CSR-based instrumentation: `DAQ_DIRECT_DATA` issued via CSR 0x0B10, routed to the AXIS sink. | In-sim `ct_axis_decoder` (env `ENABLE_DECODERS`): asserts decoded command (TID) + payload (element 0). `make sim-hsi-csr-cap`. |
| 02 | `02_csr_sync/` | ACT-CAP `CF_SYNC` issued via CSR 0x0B10: requests an instruction synchronization message (Nexus only). | Offline NexRv sync-message count (`scripts/decode_and_check_sync.sh`): requires ≥ 2 syncs (startup + the one CF_SYNC produces). `make sim-hsi-csr-sync`, part of `make sim`. |

### Notes / deferred coverage

- **Nexus-sink DAQ** (a `DATA_ACQUISITION` vendor message in the trace)
  is not yet verified in-sim: the in-sim `ct_nexus_decoder` depends on
  `mseo2_decoder`, which has not been ported into this repo, and the
  external NexRv reference decoder does not understand the vendor DAQ
  TCODE. Test 01 therefore checks the AXIS sink; Nexus-sink DAQ
  verification lands once that decoder dependency is available.
- **Timestamps**: these tests keep timestamps OFF for a deterministic,
  minimal decode. Timestamp-interleaving coverage belongs to the
  combined tests.
- **ACT-ST** (watchpoint-driven Smart Trigger) instrumentation is a
  future addition to this group.

## What this group does NOT cover

- Instruction-flow tracing → [`../instruction/`](../instruction/)
- Data tracing → [`../data/`](../data/)
- Overflow / reset → [`../overflow/`](../overflow/)
- HSI alongside instruction + data trace → [`../combined/`](../combined/)

## Conventions

Each test directory contains `<name>_tb.sv` + `<name>_tb.abc`,
following the standard skeleton documented in
[`../lib/README.md`](../lib/README.md).

These tests run instruction trace ON (so the encoder is in normal trace
mode while the instrumentation fires) with data trace and timestamps
OFF. HSI-alongside-everything coverage belongs to
[`../combined/`](../combined/).
