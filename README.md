<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# CEDARtools.TraceEncoder

**RISC-V N-Trace encoder IP — SystemVerilog, dual-licensed.**

[![License: CERN-OHL-S-2.0 OR Accemic-Commercial](https://img.shields.io/badge/license-CERN--OHL--S--2.0%20OR%20Accemic--Commercial-blue.svg)](LICENSE.md)
[![REUSE compliant](https://img.shields.io/badge/REUSE-compliant-brightgreen.svg)](https://reuse.software)

CEDARtools.TraceEncoder (formerly *C-Trace*) is an open-source hardware implementation of a [**RISC-V N-Trace
encoder**](https://docs.riscv.org/reference/nexus-trace/index.html). It
ingests a core's [instruction-trace port (TIP / ITI)](https://docs.riscv.org/reference/nexus-trace/ntrace_ingress_port.html),
compresses the execution stream into [NEXUS-IEEE-ISTO-5001-2012-compliant](https://github.com/riscv-non-isa/riscv-nexus-trace/blob/main/docs/nexus-standard/IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf)
N-Trace messages, and emits them on an **ATB** (Nexus trace) output, with
an additional, uncompressed **AXI-Stream** event path for on-chip processing.

![Overview](doc/images/ct-context.drawio.png)

The encoder sits between a RISC-V core and a trace sink and 
is configured over a Wishbone CSR bus whose register map follows 
the [RISC-V Trace Control Interface Specification v1.0](https://docs.riscv.org/reference/trace-control-interface/index.html).

See [`doc/architecture.adoc`](doc/architecture.adoc) for the internal
pipeline, the five clock domains, and the top-level IO.

## Features

- **Instruction (program) trace** — branch-history mode (HTM) with
  Indirect Branch History, synchronization, program-trace correlation on
  trace-off, and resource-full (ICNT / HIST overflow) handling.
- **Synchronization** — periodic, trace-enable, and CSR / quota-driven
  sync requests.
- **Filtering & watchpoints** — control-flow and data-flow address
  comparators and range filters.
- **Performance counters** and **timestamping** against a free-running
  wall clock.
- **Overflow / overrun recovery** — queue-overrun error messages and a
  FIFO-overrun resync path.
- **Output** — variable-length MDO/MSEO encoding onto a 32-bit ATB
  stream, an AXIS instrumentation path, and an optional packet-aware
  funnel that merges up to four ATB streams.
- **Configuration** — CSR interface generated from SystemRDL; the register
  map follows the [RISC-V Trace Control Interface](https://docs.riscv.org/reference/trace-control-interface/index.html)
  (standard `trTeControl` / `trTeImpl` component discovery and component
  types). A **Wishbone** adapter ships by default, but the bus is swappable:
  PeakRDL-regblock natively targets **APB3/APB4**, **AXI4-Lite**,
  **Avalon-MM**, and **OBI** too — regenerate with a different `--cpuif`,
  or wrap the passthrough interface like the bundled Wishbone adapter.

**Feature Bonus (beyond N-Trace)**

- **Data trace** — read / write messages with address, size and data
  value (plus their sync variants). Unified or split load/store data via
  the `SPLIT_DATA_ACCESS` parameter.
- **Targeted for live processing** - Advanced periodic sync mechanisms - 
  for improved compatibility with technologies like [CEDARtools](https://accemic.com/cedartools/)
- **Lightweight instrumentation** - Data Acquisition messages driven by
  ACT-CAP / ACT-ST, routable to the Nexus (ATB) and/or AXIS sinks.

For the detail behind the CEDARtools.TraceEncoder-specific extensions, see
[`doc/enhanced-features.adoc`](doc/enhanced-features.adoc); for the
Nexus / N-Trace message formats, see
[`doc/trace-format.adoc`](doc/trace-format.adoc).

## Quickstart

**Prerequisites**

| Tool          | Version  | Purpose                              |
|---------------|----------|--------------------------------------|
| Xilinx Vivado | 2022.1   | Simulation and/or synthesis (via abc)|
| Verilator     | latest   | Simulation (via abc); required for coverage |
| `abc`         | latest   | Project / build driver — see [abc-flow](https://github.com/accemic/abc-flow) |
| PeakRDL       | pinned   | SystemRDL → SystemVerilog (`make rdl`; auto-installed into `.venv-rdl/` from [`rdl/requirements.txt`](rdl/requirements.txt)) |
| Python 3      | ≥ 3.8    | Runs the pinned `make rdl` toolchain |
| GNU Make      | any      | Umbrella commands                    |
| Verible       | latest   | Lint (`make lint`)                   |

**Run the tests**

```sh
make help          # list available targets
make sim           # run all testbenches, print a PASS/FAIL summary
make sim-basic     # run a single testbench (any of the sim-<name> targets)
```

Either simulator can run the testbenches: `abc` drives both Vivado's
`xsim` and Verilator, so only one of the two is required for simulation
(Verilator is additionally needed for `make coverage`).

Simulations run out of the gitignored `bld/` directory. `make sim` drives
each testbench through `abc` and checks the output against the NexRv
reference decoder (the CEDARtools.TraceEncoder port,
[accemic/NexRv-for-C-Trace](https://github.com/accemic/NexRv-for-C-Trace))
— to run one by hand:

```sh
mkdir -p bld && cd bld
abc -sim ../tests/instruction/01_basic/basic_tb.abc
../scripts/decode_and_check.sh --pc --disabled basic_tb
```

> `make sim`, `make lint`, and `make rdl` are real (`make rdl` regenerates
> the register block — see [`rdl/README.md`](rdl/README.md)).

The verification approach (the `cpu_model` stimulus that is also the
answer key, and the decode-and-compare loop) is described in
[`doc/verification.adoc`](doc/verification.adoc).

## Repository layout

```
├── doc/                AsciiDoc documentation
│   └── images/         diagrams (editable .drawio.png — diagram source embedded)
├── rdl/                SystemRDL register definitions (source of truth)
├── rtl/                SystemVerilog RTL sources
│   └── pkg/            generated CSR SystemVerilog (committed; `make rdl`)
│   └── <module>/test/  per-module testbenches live next to the module
├── tests/              high-level / integration tests (multi-module)
├── scripts/            developer helpers (RDL gen, lint, decode/check)
├── bin/                NexRv reference decoder (CEDARtools.TraceEncoder port — see bin/README.md)
├── .github/workflows/  CI: lint, sim, REUSE compliance
└── LICENSES/           full text of every license used by this repo
```

## Documentation

Full documentation lives under [`doc/`](doc/):

- [Architecture](doc/architecture.adoc) — block diagram, clock domains,
  top-level IO, pipeline stages, register-map overview.
- [Trace format](doc/trace-format.adoc) — Nexus / RISC-V N-Trace
  compliance, message types, MDO/MSEO encoding.
- [Enhanced features](doc/enhanced-features.adoc) — the CEDARtools.TraceEncoder-specific
  extensions (DAQ / ACT-CAP, filtering, sync variants, funnel, …).
- [Verification](doc/verification.adoc) — the test harness and checking
  principle.
- [Development](doc/development.adoc) — build flow, RDL flow, and SoC
  integration.

## Status & limitations

The headline limitations:

- History-mode (HTM) is the only program-trace method — traditional BTM is
  intentionally omitted (bandwidth-inefficient); single-hart; no
  return-stack compression.
- A known CSR-triggered-sync timestamp issue and some commented-out code
  remain.


## Future ideas

Larger enhancements under consideration:

- **Self-describing trace** — emit a vendor `VENDOR_CONFIG` Nexus message
  (Vendor Config, TCODE 56) carrying the encoder configuration, so a decoder
  can interpret the stream without out-of-band setup. The
  `trTeControl.SendConfig` control is reserved for this (today read-only
  `CFG_NONE`; would select once / on-sync emission once implemented).
- **Ownership / Context message (TCODE 2)** — emit the standard
  process / privilege correlation message (`scontext` / `hcontext`,
  privilege mode). The control bit (`trTeControl.Context`, today reserved /
  read-only) and the TIP context fields already exist; wiring up the
  message enables OS-aware and multi-hart trace decode.

## License

CEDARtools.TraceEncoder is licensed per artifact type — see [`LICENSE.md`](LICENSE.md)
for the full statement:

- **Hardware IP** (RTL, RDL, constraints, and the SystemVerilog/`.abc`
  testbenches) is dual-licensed under **CERN-OHL-S-2.0** (strongly
  reciprocal) or a **commercial license** from Accemic Technologies GmbH —
  `CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial`.
- **Software** (scripts, build, CI, config) is **ISC**.
- **Documentation** (Markdown, AsciiDoc, images) is **CC-BY-4.0**.

Each file declares its own `SPDX-License-Identifier`; the repository is
[REUSE](https://reuse.software)-compliant. For commercial licensing
inquiries: <sales@accemic.com>.

## Trademarks

RISC-V is a trademark of RISC-V International; Arm, AMBA, AXI and
CoreSight are trademarks of Arm Limited; Xilinx and Vivado are
trademarks of AMD. These and any other third-party marks are used
descriptively to identify the relevant specifications, interfaces, and
tools, and do not imply endorsement. See [`TRADEMARKS.md`](TRADEMARKS.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributions require a CLA so
that the project can continue to be offered under both licenses.

## References

- RISC-V N-Trace specification — <https://github.com/riscv-non-isa/riscv-trace-spec>
- RISC-V Trace Control Interface Specification v1.0 — <https://docs.riscv.org/reference/trace-control-interface/index.html>
- IEEE-ISTO 5001-2012 (Nexus) standard v3.0.1 — [IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf](https://github.com/riscv-non-isa/riscv-nexus-trace/blob/main/docs/nexus-standard/IEEE-ISTO-5001-2012-v3.0.1-Nexus-Standard.pdf)
- REUSE Software (SPDX compliance) — <https://reuse.software>
- CERN Open Hardware Licence v2 — <https://ohwr.org/cernohl>

## Acknowledgment — TRISTAN EU project

This work was developed as part of the TRISTAN project, a European Union research initiative involving 46 partners to advance the RISC-V ecosystem. The TRISTAN project, nr. 101095947 is supported by Chips Joint Undertaking (CHIPS-JU) and its members Austria, Belgium, Bulgaria, Croatia, Cyprus, Czechia, Germany, Denmark, Estonia, Greece, Spain, Finland, France, Hungary, Ireland, Iceland, Italy, Lithuania, Luxembourg, Latvia, Malta, Netherlands, Norway, Poland, Portugal, Romania, Sweden, Slovenia, Slovakia, Turkey. See https://tristan-project.eu/ for more information.
