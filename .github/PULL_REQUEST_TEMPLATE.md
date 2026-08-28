<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

## Summary

<!-- One or two sentences describing what this PR changes and why. -->

## Checklist

- [ ] Branch is named `<handle>/<short-description>`
- [ ] New files carry the SPDX header
- [ ] `make lint` passes
- [ ] `make sim` passes for any module touched
- [ ] If `rdl/ct_cs_cpuif.rdl` changed, `make rdl` was re-run and the
      regenerated `rtl/pkg/ct_cs_cpuif*.sv` + `tests/lib/ct_cs_cpuif_wb_helper.sv`
      are committed in the same PR (likewise `make rdl-soc` →
      `examples/kv260/common/tgc5b/pkg/ct_soc_regs*.sv`)
- [ ] CLA agreed (see [CONTRIBUTING.md](../CONTRIBUTING.md))

## Notes for reviewers

<!-- Anything reviewers should pay extra attention to: tricky logic, perf
     considerations, register-map changes, breaking changes, etc. -->
