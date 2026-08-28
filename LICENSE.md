<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Licensing

CEDARtools.TraceEncoder — RISC-V Trace Encoder IP
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
| **Pre-built demo apps** | The ready-to-load KV260 apps under `examples/kv260/<demo>/fpga/prebuilt/` — bitstream, device-tree overlay, `shell.json`, manifest — built from the Hardware IP and the example SoCs (declared in [`REUSE.toml`](REUSE.toml)) | **`CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial`** (dual); the third-party cores compiled into a bitstream keep their own licenses, stated in that example's README |
| **Third-party IP** | MINRES TGC5B core vendored for the example SoC (`examples/kv260/common/tgc5b/cpu/`) | **`CERN-OHL-S-2.0 OR LicenseRef-MINRES-Commercial`** (dual — licensed by MINRES) |
| **Fetched tool** | CTTD (CEDARtools.TraceDecoder) reference decoder — not committed; `scripts/fetch_cttd.py` downloads the pinned build into the gitignored `bin/` (see below) | **`ISC`** (upstream NexRv reference decoder of the RISC-V Nexus Trace TG, extended by Accemic) |

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

## Third-party IP — MINRES TGC5B core

`examples/kv260/common/tgc5b/cpu/TGC5B_AXI4L_H2E.sv` is **not** Accemic's work. It
is the MINRES **TGC5B** RISC-V core, `Copyright 2020-2022 MINRES
Technologies GmbH`, vendored so the integration example builds and
simulates against a real core.

MINRES has permitted its publication under the same dual-license model
this repository uses for its own hardware IP. The permission is on
record — Eyck Jentzsch, Managing Director of MINRES Technologies GmbH, by
e-mail of **2026-08-03**, in reply to an explicit request naming this
repository's `LICENSE.md`; the parties, the date and the scope are in
[`legal/minres-tgc5b-license-grant-20260803.md`](legal/minres-tgc5b-license-grant-20260803.md).
The correspondence itself is MINRES' text and not Accemic's to publish;
Accemic holds it and produces it for licensees and licence auditors on
request (<info@accemic.com>).

```
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-MINRES-Commercial
```

The licensor of **both** arms is MINRES, not Accemic
([`LICENSES/LicenseRef-MINRES-Commercial.txt`](LICENSES/LicenseRef-MINRES-Commercial.txt)).
Accemic conveys the file verbatim under CERN-OHL-S-2.0 and holds no right
to sublicense it. Concretely:

- Under **CERN-OHL-S-2.0** you may use, simulate, modify and redistribute
  the core on the license's terms, exactly as for the encoder. The
  file is left byte-identical to MINRES' delivery and its SPDX metadata
  lives in a REUSE `.license` sidecar, so the upstream Notices stay intact.
- A **commercial license for the core** comes from MINRES only. An Accemic
  commercial license for the encoder conveys no rights to the core, and
  vice versa — see [Commercial licensing](#commercial-licensing).

The permission covers this specific delivered netlist (core config
`TGC5B_AXI4L_H2E`), not other TGC5B configurations or versions. The
encoder IP itself does not depend on the core: nothing under `rtl/`,
`rdl/` or `tests/` references it.

## Software — ISC

Build scripts, tooling, CI, and configuration are licensed under the
permissive **ISC** license. Full text:
[`LICENSES/ISC.txt`](LICENSES/ISC.txt).

## Documentation — CC BY 4.0

Documentation (Markdown, AsciiDoc) and documentation images are licensed
under **Creative Commons Attribution 4.0 International (CC-BY-4.0)** — you
may share and adapt them with attribution. Full text:
[`LICENSES/CC-BY-4.0.txt`](LICENSES/CC-BY-4.0.txt).

## Fetched tool — CTTD

The reference decoder **CTTD (CEDARtools.TraceDecoder)** is not part of this
repository's tree: `scripts/fetch_cttd.py` downloads the build pinned in
`scripts/cttd.pin` (sha256 per platform, `base_url` naming the CTTD
repository) into the gitignored `bin/`. CTTD is
derived from the RISC-V Nexus Trace Task Group's reference decoder NexRv
(copyright IAR Systems AB, **ISC**) and extended by Accemic Technologies GmbH
(E-Trace front end, DAQ, multi-target decode, CTXP export); its licence text
and notices travel with the CTTD repository. Nothing of it is redistributed
from here, so it carries no `REUSE.toml` entry in this repository.

## Commercial licensing

Organizations that cannot comply with the copyleft obligations of
CERN-OHL-S-2.0 for the hardware IP may obtain a commercial license from
Accemic Technologies GmbH. Inquiries: [sales@accemic.com](mailto:sales@accemic.com).

That license covers the **CEDARtools.TraceEncoder IP**, and the IP is
defined by its licence expression, not by its directory: it is exactly the
set of files whose SPDX header reads
`CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial` — the RTL, the register
description, the testbenches, the formal properties, the reference vectors
and the Accemic-authored hardware parts of `examples/`. Files under the
same directories that carry a different expression (`ISC` build and board
scripts, `CC-BY-4.0` documentation) are already permissive and need no
commercial license. The commercial arm does **not** cover the vendored
MINRES TGC5B core, which carries its own dual license from MINRES. The two
are independent:

| You want to ship | Encoder | TGC5B core | License(s) needed |
|---|---|---|---|
| An open-source design | CERN-OHL-S-2.0 | CERN-OHL-S-2.0 | none — both open arms apply |
| A closed-source design **with your own core** | Accemic commercial | not used | Accemic only |
| A closed-source design **containing the TGC5B** | Accemic commercial | MINRES commercial | both, negotiated separately |
| Evaluation, simulation, internal development | either | either | none |

The third row follows from CERN-OHL-S-2.0 itself: including Covered
Source in a larger work makes the larger work modified Covered Source
(§3.2), and conveying a Product built from it requires providing the
Complete Source (§4). Keeping the TGC5B in a product therefore keeps the
product under CERN-OHL-S-2.0 regardless of the encoder's license.

Row two is the usual case — the example SoC is a worked integration, not
part of the IP deliverable, and integrators bring their own core.

## Contributions

Contributions may require acceptance of a Contributor License Agreement
(CLA) so the maintainers can continue offering the hardware IP under the
dual-license model. See [`CONTRIBUTING.md`](CONTRIBUTING.md).
