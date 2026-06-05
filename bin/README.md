<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# `bin/` — vendored tools

## `NexRv`

The **NexRv** reference decoder for the Nexus RISC-V trace stream. This
is a dedicated port/fork maintained for C-Trace compatibility —
<https://github.com/accemic/NexRv-for-C-Trace> — not the upstream
IAR Systems tool. Used by the testbenches as a post-simulation
verification step: the encoder emits an ATB byte stream, NexRv decodes
it back into PCs using the program description (`*.nexrv.info`), and the
result is diffed address-for-address against the sequence the
`cpu_model` claims it executed.

```
NexRv -deco <atb.bin> -pcinfo <nexrv.info> -pcout <decoded.pcout> -full
```

The version bundled here is a **pinned binary** built from the C-Trace
port at <https://github.com/accemic/NexRv-for-C-Trace>. This directory
may later become a git submodule (or a tiny build script) so the binary
drops out.

### License

NexRv (the C-Trace port,
<https://github.com/accemic/NexRv-for-C-Trace>) is derived from the
IAR Systems NexRv tool and is distributed under the **ISC License**
(Copyright (c) 2020 IAR Systems AB,
Copyright (c) 2026 Accemic Technologies GmbH). This is independent of
C-Trace's own CERN-OHL-S-2.0 / Accemic-Commercial dual license. The
SPDX record for the binary lives in [`REUSE.toml`](../REUSE.toml) and
the license text in [`LICENSES/ISC.txt`](../LICENSES/ISC.txt).

### Why a pre-built binary in the repo?

NexRv is small (~85 KB) and the decode step is part of every test's
PASS criterion. Vendoring the binary keeps the testsuite self-contained
and reproducible. Rebuild it from the C-Trace port at
<https://github.com/accemic/NexRv-for-C-Trace> when an update is needed.
