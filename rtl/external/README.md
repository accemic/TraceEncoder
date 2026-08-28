<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# `rtl/external/` — Accemic's own building-block library

**"External" means outside the encoder core, not outside the company.**
Every one of the 81 files here is Accemic-authored (copyright 2018–2026,
`CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial` like the rest of the
hardware IP) — there is no vendored third-party code in this directory.
Code that really comes from elsewhere lives in
[`../../third_party/`](../../third_party/) and in
`examples/kv260/third_party/`, each with its upstream licence and a pin.

The name says where the modules sit in the design, not where they came from:
they are the general-purpose infrastructure the encoder is built *on*, kept
apart from the trace-encoding logic so that both can be read — and reused —
without the other.

| Directory | What is in it |
|---|---|
| `amba/` | The trace-port interfaces: ATB (`atb_if`, `atb_pkg`) and AXI4-Stream (`axis_if`), plus their simulation helpers (dump, sink model, stall injector). |
| `wishbone/` | The CSR bus: Wishbone package and the bridge to the generated register interface (`wb_to_cpuif`). |
| `stream/` | Streaming primitives: the counted-vector-stream (CVS) compacting FIFOs and their CDC variant, the `sink_if`/`source_if`/`cvsource_if` handshake interfaces, an overflow injector for tests. |
| `memory/` | Storage wrappers: first-word-fall-through FIFOs (one- and two-clock) and the simple-dual-port on-chip RAM with its read/write interfaces. |
| `common/` | Shared utilities: counter, reset and signal/vector/strobe CDC, the RAM-backed binary search (`vector_binary_search_2clk`), range checker, math package. |
| `testtools/` | Simulation-only helpers (file and string packages, the `tt` test-tool package) used by the testbenches of the above. |

Each subdirectory carries its own `test/` with the per-module testbenches,
following the convention in [`../README.md`](../README.md).
