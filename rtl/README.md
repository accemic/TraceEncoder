<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# RTL sources

SystemVerilog implementation of the C-Trace encoder, driven by
[abc-flow](https://github.com/accemic/abc-flow) (paired `.sv` + `.abc` files).

## Layout

```
rtl/
├── <module>.sv          top-level encoder modules (ct_encoder, ct_L1_funnel,
│   <module>.abc         ct_L2_nexus_formatter, ct_L2_mseo_mdo_formatter, …)
├── test/                testbenches for those top-level modules
├── pkg/                 type and parameter packages
├── preproc/             stage-2/3 preprocessor modules + preproc/test/
├── mseo_mdo/            MSEO/MDO formatter submodules + mseo_mdo/test/
└── external/            vendored deps from sibling repos (each with its own test/)
```

## Module test convention

**Per-module testbenches live next to the modules they exercise, in a
`test/` subdirectory of the relevant subsystem** — `rtl/preproc/test/`,
`rtl/mseo_mdo/test/`, or `rtl/test/` for the top-level modules. Moving a
subsystem moves its tests. `.abc` manifests reach shared sources through
repo-anchored imports (`@rtl/pkg`, `@rtl/preproc`, `@tests/lib`, …), so a
testbench builds the same from any location.

The top-level [`../tests/`](../tests/) directory is reserved for
**high-level / system / integration tests** that span multiple
modules. Do not put per-module unit tests there.

## Conventions

- Every `.sv` file has a paired `.abc` file describing its
  dependencies (see [abc-flow docs](https://github.com/accemic/abc-flow) for the
  syntax).
- Every file carries the SPDX header:
  ```
  // SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
  // SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
  ```
- Lint must pass: `make lint`.
