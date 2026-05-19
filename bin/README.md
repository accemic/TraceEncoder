<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# `bin/` — vendored tools

## `NexRv`

The **NexRv** reference decoder for the Nexus RISC-V trace stream. Used
by the testbenches as a post-simulation verification step: the encoder
emits an ATB byte stream, NexRv decodes it back into PCs using the
program description (`*.nexrv.info`), and the result is diffed
address-for-address against the sequence the `cpu_model` claims it
executed.

```
NexRv -deco <atb.bin> -pcinfo <nexrv.info> -pcout <decoded.pcout> -full
```

The version bundled here is a **pre-release pinned binary**. NexRv will
be published as open source at <https://github.com/accemic/NexRv>;
once that lands, this directory becomes a git submodule (or a tiny
build script) and the binary drops out.

### Why a pre-built binary in the repo?

NexRv is small (~85 KB) and the decode step is part of every test's
PASS criterion. Vendoring the binary keeps the testsuite self-contained
and reproducible while the upstream OSS repo is being prepared.
Replace with the upstream build as soon as it's available.
