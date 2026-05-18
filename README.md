<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# C-Trace

**RISC-V N-Trace encoder IP — SystemVerilog, dual-licensed.**

[![License: CERN-OHL-S-2.0 OR Accemic-Commercial](https://img.shields.io/badge/license-CERN--OHL--S--2.0%20OR%20Accemic--Commercial-blue.svg)](LICENSE.md)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#status)
[![REUSE compliant](https://img.shields.io/badge/REUSE-compliant-brightgreen.svg)](https://reuse.software)

> **Status: alpha / pre-release.** APIs, register map, and module
> boundaries may change without notice until a 1.0 tag is cut.

## What is C-Trace?

C-Trace is an open-source hardware implementation of a **RISC-V N-Trace
encoder**: it ingests a core's instruction-trace port (TIP), compresses
the execution stream into N-Trace messages, and emits them on an ATB or
AXI-Stream output. It is the IP that Accemic Technologies builds its
commercial trace tooling on, released under a dual license so that
research, education, and open-hardware projects can use it freely while
commercial integrators retain a non-copyleft option.

The encoder is structured as a multi-stage pipeline:

```
  TIP (core) ──► L1 funnel ──► L2/L3 preproc ──► message gen ──► formatter ──► ATB / AXIS
                                                                                 │
                                                                 CSR (Wishbone) ─┘
```

See [`doc/architecture.md`](doc/architecture.md) for the full block
diagram, clock domains, and top-level IO.

## Quickstart

**Prerequisites**

| Tool          | Version  | Purpose                              |
|---------------|----------|--------------------------------------|
| Xilinx Vivado | TBD      | Simulation + synthesis (via abc)     |
| `abc`         | latest   | Project / build driver — see [abc-flow](https://github.com/) |
| PeakRDL       | latest   | SystemRDL → SystemVerilog generation |
| GNU Make      | any      | Umbrella commands                    |
| Verible       | latest   | Lint + format                        |

**Build / simulate**

```sh
make help          # list available targets
make rdl           # regenerate rdl/gen/*.sv from rdl/*.rdl
make lint          # verible-verilog-lint
make sim           # run all testbenches
```

> The Makefile targets are stubs in this skeleton release — they print
> "not implemented" until the actual RTL/RDL is dropped in.

## Repository layout

```
.                       repo root
├── doc/                architecture, theory of operation, register reference
├── rdl/                SystemRDL register definitions (source of truth)
│   └── gen/            generated SystemVerilog (committed)
├── rtl/                SystemVerilog RTL sources
│   └── <module>/test/  per-module testbenches live next to the module
├── tests/              high-level / integration tests (multi-module)
├── examples/           reference SoC integrations
├── scripts/            developer helpers (RDL gen, lint, format)
├── .github/workflows/  CI: lint, sim, REUSE compliance
└── LICENSES/           full text of every license used by this repo
```

## License

C-Trace is dual-licensed under **CERN-OHL-S-2.0** (strongly reciprocal)
or a **commercial license** from Accemic Technologies GmbH. You may pick
either; see [`LICENSE.md`](LICENSE.md) for the full statement.

```
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
```

For commercial licensing inquiries: <sales@accemic.com>.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributions require a CLA so
that the project can continue to be offered under both licenses.

## References

- RISC-V N-Trace specification — <https://github.com/riscv-non-isa/riscv-trace-spec>
- REUSE Software (SPDX compliance) — <https://reuse.software>
- CERN Open Hardware Licence v2 — <https://ohwr.org/cernohl>

## Maintainers

See [`MAINTAINERS.md`](MAINTAINERS.md).
