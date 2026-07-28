<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Licensing

CEDARtools.TraceEncoder — RISC-V N-Trace Encoder IP
Copyright (C) 2026 Accemic Technologies GmbH

This repository is licensed **per artifact type**. Which license applies
to a given file is declared by that file's own `SPDX-License-Identifier`
header (or, for files that cannot carry a header, by [`REUSE.toml`](REUSE.toml)).
The repository is [REUSE](https://reuse.software) compliant, so the
machine-readable headers are authoritative; this document is the
human-readable summary.

The full text of every license used is in [`LICENSES/`](LICENSES/).

## Overview

| Artifact | What it covers | License |
|----------|----------------|---------|
| **Hardware IP** | RTL (`.sv`), register description (`.rdl`), timing/placement constraints (`.xdc`), and the SystemVerilog/`.abc` verification testbenches | **`CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial`** (dual) |
| **Software** | Build, tooling and CI — shell/Python scripts, `Makefile`, GitHub workflows, config and metadata | **`ISC`** |
| **Documentation** | Markdown, AsciiDoc, and documentation images | **`CC-BY-4.0`** |
| **Vendored** | `bin/NexRv` reference decoder (derived from the IAR Systems NexRv tool) | **`ISC`** |

## Hardware IP — dual license

The hardware design and its testbenches are provided under a
**dual-license** model. You may use them under **either**:

1. **CERN Open Hardware License Version 2 – Strongly Reciprocal
   (CERN-OHL-S-2.0)** — the default open-source license. It ensures that
   modifications and derivative works remain open when distributed.
   Full text: [`LICENSES/CERN-OHL-S-2.0.txt`](LICENSES/CERN-OHL-S-2.0.txt).

2. **Accemic Commercial License** — for organizations that require
   integration without the copyleft obligations of CERN-OHL-S-2.0.
   See [`LICENSES/LicenseRef-Accemic-Commercial.txt`](LICENSES/LicenseRef-Accemic-Commercial.txt).

Choose whichever fits your use case. The SPDX expression on these files is:

```
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
```

## Software — ISC

Build scripts, tooling, CI, and configuration are licensed under the
permissive **ISC** license. Full text:
[`LICENSES/ISC.txt`](LICENSES/ISC.txt).

## Documentation — CC BY 4.0

Documentation (Markdown, AsciiDoc) and documentation images are licensed
under **Creative Commons Attribution 4.0 International (CC-BY-4.0)** — you
may share and adapt them with attribution. Full text:
[`LICENSES/CC-BY-4.0.txt`](LICENSES/CC-BY-4.0.txt).

## Vendored — NexRv

`bin/NexRv` is a reference decoder built from the CEDARtools.TraceEncoder port at
[accemic/NexRv-for-C-Trace](https://github.com/accemic/NexRv-for-C-Trace),
derived from the IAR Systems NexRv tool, copyright IAR Systems AB and
Accemic Technologies GmbH, licensed under **ISC**. It is recorded in
[`REUSE.toml`](REUSE.toml).

## Commercial licensing

Organizations that cannot comply with the copyleft obligations of
CERN-OHL-S-2.0 for the hardware IP may obtain a commercial license from
Accemic Technologies GmbH. Inquiries: [sales@accemic.com](mailto:sales@accemic.com).

## Contributions

Contributions may require acceptance of a Contributor License Agreement
(CLA) so the maintainers can continue offering the hardware IP under the
dual-license model. See [`CONTRIBUTING.md`](CONTRIBUTING.md).
