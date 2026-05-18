<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# Contributing to C-Trace

Thanks for your interest in contributing. This document describes the
expectations for changes to C-Trace.

## Quick checklist

- [ ] Branch named `<your-handle>/<short-description>` off `main`.
- [ ] All new files carry the SPDX header (see below).
- [ ] `make lint` passes.
- [ ] `make sim` passes for any module you touched.
- [ ] If you changed `rdl/*.rdl`, you re-ran `make rdl` and committed
      the regenerated `rdl/gen/*.sv` in the same commit.
- [ ] Commit messages explain *why*, not just *what*.
- [ ] You've signed the CLA (see [License & CLA](#license--cla)).

## Development setup

You will need:

| Tool          | Version  | Purpose                              |
|---------------|----------|--------------------------------------|
| Xilinx Vivado | TBD      | Simulation + synthesis (via `abc`)   |
| `abc`         | latest   | Project / build driver               |
| PeakRDL       | latest   | SystemRDL → SystemVerilog generation |
| GNU Make      | any      | Umbrella commands                    |
| Verible       | latest   | Lint + format                        |

See [`README.md`](README.md#quickstart) for the high-level commands.

## Coding style

- SystemVerilog formatting: `make format` (wraps `verible-verilog-format`).
- Lint: `make lint` must pass before submitting a PR.
- Every `.sv` file has a paired `.abc` file declaring its dependencies.
- Per-module testbenches live in `rtl/<module>/test/`, **not** in
  `tests/`. The `tests/` directory at the repo root is reserved for
  high-level / integration tests.
- Never hand-edit files under `rdl/gen/` — they're regenerated.

## SPDX headers

Every source file (`.sv`, `.svh`, `.rdl`, `.md`, `.yml`, `Makefile`,
shell scripts, etc.) must begin with:

```
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
```

(The comment syntax depends on the language. For Markdown / HTML use
an HTML comment; for SystemVerilog use `//` lines; for shell / Make use
`#` lines.)

The `reuse` CI job will fail any PR that introduces a file without a
valid SPDX header.

## Commit messages

**TBD** — the project has not yet settled on Conventional Commits vs.
free-form. For now: write a clear, self-contained subject line and a
body that explains the motivation when it's not obvious from the diff.

## Pull requests

1. Push your branch to your fork (or the main repo if you have write
   access).
2. Open a PR against `main`.
3. CI must pass: lint, REUSE, and (eventually) simulation.
4. At least one maintainer review is required before merge — see
   [`.github/CODEOWNERS`](.github/CODEOWNERS) for routing.
5. Squash-merge is the default. Keep the squashed commit message
   informative.

## License & CLA

C-Trace is dual-licensed under **CERN-OHL-S-2.0** or a **commercial
license** from Accemic Technologies GmbH (see [`LICENSE.md`](LICENSE.md)).

To preserve the dual-license option, contributions require a
**Contributor License Agreement** assigning the necessary rights to
Accemic Technologies GmbH while leaving you with copyright over your
work. The exact mechanism (CLA Assistant bot vs. DCO sign-off) is
**TBD** — until it's set up, please indicate in your PR description
that you agree to license your contribution under the project's
dual-license terms.

For questions: <oss@accemic.com> (placeholder — confirm address).

## Reporting bugs and security issues

- Functional bugs: open a GitHub issue using the bug-report template.
- **Security issues: do not open a public issue.** Email
  <security@accemic.com> (placeholder) with details.

## Code of conduct

By participating in this project you agree to abide by the
[Code of Conduct](CODE_OF_CONDUCT.md).
