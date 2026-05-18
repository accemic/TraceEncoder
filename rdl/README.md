<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# Register description (SystemRDL)

This directory holds the **SystemRDL** sources that describe C-Trace's
control / status register map. The RDL is the **single source of
truth** for the register layout; the generated SystemVerilog under
[`gen/`](gen/) is committed alongside it so that the repo is buildable
without the RDL toolchain.

## Layout

| Path     | Purpose                                                   |
|----------|-----------------------------------------------------------|
| `*.rdl`  | SystemRDL sources (hand-written).                         |
| `gen/`   | PeakRDL-generated SystemVerilog (machine-written). Do **not** edit by hand. |

## Regenerating

```sh
make rdl
```

This re-runs `scripts/gen_rdl.sh`, which invokes PeakRDL and writes
into `gen/`. Commit both the RDL change and the regenerated SV in
the same commit.

## Conventions

- One RDL file per register block. Cross-references use SystemRDL
  imports.
- Field enums describe command codes, action types, etc. Reuse them
  from SystemVerilog via the generated package.
- Document fields inline in the RDL — those descriptions feed the
  generated register reference under [`../doc/registers.md`](../doc/registers.md).

## TODO before the first RTL port

- Decide on a PeakRDL exporter set (SV, HTML/Markdown docs, UVM regmodel?).
- Pin the PeakRDL version range — see [`../scripts/gen_rdl.sh`](../scripts/gen_rdl.sh).
- Add a CI check that re-runs `make rdl` and fails if `gen/` is stale.
