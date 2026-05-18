<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# RTL sources

SystemVerilog implementation of the C-Trace encoder, driven by
[abc-flow](https://github.com/) (paired `.sv` + `.abc` files).

## Layout

```
rtl/
├── pkg/                  type and parameter packages
└── <module>/             one directory per module
    ├── <module>.sv       implementation
    ├── <module>.abc      abc-flow dependencies for the module
    └── test/             per-module testbenches
        ├── <module>_tb.sv
        └── <module>_tb.abc
```

## Module test convention

**Per-module testbenches live next to the module under
`rtl/<module>/test/`.** Moving a module moves its tests; `.abc`
imports stay short and local.

The top-level [`../tests/`](../tests/) directory is reserved for
**high-level / system / integration tests** that span multiple
modules. Do not put per-module unit tests there.

## Conventions

- Every `.sv` file has a paired `.abc` file describing its
  dependencies (see [abc-flow docs](https://github.com/) for the
  syntax).
- Every file carries the SPDX header:
  ```
  // SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
  // SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
  ```
- Format with `make format` (Verible).
- Lint must pass: `make lint`.

## Status

Skeleton — no modules ported yet. See the project plan in
[`/home/albert/.claude/plans/`](../doc/) (developer-only) for the
porting roadmap.
