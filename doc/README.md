<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# C-Trace documentation

Start here:

- [Architecture](architecture.md) — block diagram, clock domains,
  top-level IO, pipeline stages.
- [Theory of operation](theory-of-operation.md) — how the N-Trace
  pipeline works end-to-end, message formats, the RISC-V N-Trace
  spec mapping.
- [Register reference](registers.md) — CSR map, generated from the
  SystemRDL sources under [`../rdl/`](../rdl/).
- [Integration guide](integration.md) — how to wire C-Trace into a
  SoC: clocks, resets, the TIP interface, the ATB / AXIS output, the
  CSR / Wishbone bus.
- [Verification](verification.md) — the test system & checking
  principle: the `cpu_model` stimulus, the `ctrace_env` harness, and the
  NexRv reference-decode-and-compare loop, with a block diagram.

Diagrams and images live in [`images/`](images/).
