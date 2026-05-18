<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# Integration guide

> **Stub.** Fill in once the first integration example lands in
> [`../examples/`](../examples/).

This guide will walk a SoC integrator through:

- Connecting the **TIP** port to a RISC-V core's trace output.
- Wiring the **CSR** bus (Wishbone, by default).
- Routing the **ATB** / **AXIS** output to a sink (debug pod, FPGA
  RAM, off-chip transceiver).
- Clocking and reset strategy across the encoder's clock domains.
- Parameter selection for area / throughput trade-offs.

For reference integrations, see [`../examples/`](../examples/).
