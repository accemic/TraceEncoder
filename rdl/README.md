<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Register description (SystemRDL)

This directory holds the **SystemRDL** source that describes CEDARtools.TraceEncoder's
control / status register map. The RDL is the **single source of
truth** for the register layout; the generated SystemVerilog is committed
alongside it (under `../rtl/pkg/` and `../tests/lib/`) so the repo is
buildable without the RDL toolchain.

## Layout

| Path                | Purpose                                          |
|---------------------|--------------------------------------------------|
| `ct_cs_cpuif.rdl`   | SystemRDL source (hand-written).                 |
| `requirements.txt`  | Pinned Python toolchain for `make rdl`.          |

## Generated files

`make rdl` regenerates five files from `ct_cs_cpuif.rdl`. **Do not edit
them by hand** — rerun `make rdl`.

| File                                    | Generator              |
|-----------------------------------------|------------------------|
| `../rtl/pkg/ct_cs_cpuif.sv`             | PeakRDL-regblock       |
| `../rtl/pkg/ct_cs_cpuif_pkg.sv`         | PeakRDL-regblock       |
| `../rtl/pkg/ct_cs_cpuif_wb_pkg.sv`      | `scripts/generate_wb_pkg.py` |
| `../rtl/pkg/ct_cs_cpuif_types_pkg.sv`   | `scripts/generate_wb_pkg.py` |
| `../tests/lib/ct_cs_cpuif_wb_helper.sv` | `scripts/generate_wb_pkg.py` |

The Wishbone↔CPUIF adapter `../rtl/pkg/ct_cs_cpuif_wb.sv` is
**hand-written** (not generated).

## Regenerating

```sh
make rdl
```

This runs [`../scripts/gen_rdl.sh`](../scripts/gen_rdl.sh), which:

1. Creates a local virtualenv `.venv-rdl/` and installs the **pinned**
   toolchain from [`requirements.txt`](requirements.txt) (PeakRDL +
   PeakRDL-regblock + systemrdl-compiler) — so output is reproducible.
2. Runs `peakrdl regblock … --cpuif passthrough --type-style hier` and
   `scripts/generate_wb_pkg.py`, prepends the SPDX header, and writes the
   files listed above.

Commit the RDL change and the regenerated SV in the **same** commit. Bump
the pins in `requirements.txt` deliberately and regenerate in that commit.

## Conventions

- Field enums describe command codes, action types, etc. Reuse them from
  SystemVerilog via the generated package.
- Document fields inline in the RDL — those descriptions are intended to
  feed an auto-generated register reference (see the register-map overview
  in [`../doc/architecture.adoc`](../doc/architecture.adoc)).
