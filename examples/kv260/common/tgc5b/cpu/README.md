<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Vendored CPU core — MINRES TGC5B

`TGC5B_AXI4L_H2E.sv` is the RV32I core the example SoC traces. It is
**third-party IP**, not Accemic's work, and is vendored here so the
integration example builds and simulates against a real core rather than
the synthetic `cpu_model` stimulus used by the unit tests.

## Provenance

Taken verbatim from the delivery by MINRES Technologies GmbH. The
identifying fields from the file's own generator header:

| Field | Value |
|---|---|
| Copyright | `2020-2022 MINRES Technologies GmbH` (MINRES© TGC-CG) |
| Component | `TGC5B_AXI4L_H2E` |
| Core config hash | `ecababb8345510fc9133035ddf2a3116ca7a57bf` |
| Generator | SpinalHDL dev, git head `b4412ad3871dc6d7164fb726b30106dde25312e1` |
| Source git hash | `1c0c57ebccdb2e867d6e6c68ad4fc03e37fbe819` |
| Generated | `09/06/2026, 12:31:13` (per the header) |

## License

MINRES has permitted publication of this file under the same dual-license
model this repository applies to its own hardware IP:

```
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-MINRES-Commercial
```

**MINRES is the licensor of both arms** — Accemic conveys the file
verbatim under CERN-OHL-S-2.0 and cannot sublicense it. Full statement:
[`LICENSES/LicenseRef-MINRES-Commercial.txt`](../../../LICENSES/LicenseRef-MINRES-Commercial.txt)
and [`LICENSE.md`](../../../LICENSE.md#third-party-ip--minres-tgc5b-core).

The permission covers **this** netlist — the config and hashes above —
not other TGC5B configurations, versions or deliverables.

## Rules for this directory

- **Do not edit `TGC5B_AXI4L_H2E.sv`.** It stays byte-identical to the
  delivery. Its SPDX metadata therefore lives in the REUSE sidecar
  `TGC5B_AXI4L_H2E.sv.license`, not in an in-file header — the one
  documented exception to the SPDX-header rule in
  [`CONTRIBUTING.md`](../../../CONTRIBUTING.md).
- Modifying it would make the modifier a Licensor under CERN-OHL-S-2.0
  §3.3 and require adding modification notices. Fixes belong upstream at
  [MINRES](https://www.minres.com), not here.
- The core is excluded from `make lint` (see `scripts/lint.sh`) — upstream
  generator style is not held to this repo's Verible rules.
- Adapting the SoC to a different core means replacing this file and
  `../rtl/ct_tip_adapter.sv`, which maps the core's flat H2E trace port
  onto the encoder's `tip_if`. Nothing under `rtl/`, `rdl/` or `tests/`
  depends on the core.
