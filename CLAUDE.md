<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# C-Trace — Claude Working Notes

This file tells Claude how to work in **this** repository. Cross-cutting
rules (branching prefix, "push but don't open PR", artifact flow, etc.)
live in `~/.claude/CLAUDE.md` and apply here too. When the two
disagree on a non-repo-specific point, ask Albert before acting.

---

## Repo identity

- C-Trace is the **public, open-source release** of Accemic's RISC-V
  N-Trace encoder IP.
- The internal / proprietary implementation lives at
  `~/git2/fpga/modules/ctrace/`. It is the historical source for many
  of the modules here, but it is **not** a drop-in upstream.
- **Do not copy code, RDL, or docs from `~/git2/fpga` into this repo
  without explicit user direction.** The internal repo contains
  Accemic-proprietary integrations and undocumented APIs that must be
  reviewed before going public. Always ask first.

## Default branch

This repo's default branch is **`main`** (not `master`). Every other
Accemic repo under `~/git/` defaults to `master` — so the standard
"branch off the latest master" rule from `~/.claude/CLAUDE.md` becomes
"branch off the latest **main**" here.

Feature branches still follow the global convention:
`albert/<freeform-description>`.

## Build / development flow

The build driver is **[abc-flow](https://github.com/)** — Vivado-based,
text-defined projects. Tool versions are pinned in [`.abc.config`](.abc.config).

Umbrella commands (all routed through `Makefile`):

| Command       | What it does                                           |
|---------------|--------------------------------------------------------|
| `make help`   | List available targets.                                |
| `make rdl`    | Regenerate `rdl/gen/*.sv` from `rdl/*.rdl` (PeakRDL).  |
| `make sim`    | Run all testbenches via `abc -sim`.                    |
| `make lint`   | `verible-verilog-lint` over `rtl/` and `tests/`.       |
| `make format` | `verible-verilog-format` (in-place).                   |
| `make doc`    | Build documentation (TBD).                             |
| `make clean`  | Remove `bld/` and other generated artifacts.           |

> The Makefile targets are stubs in this skeleton — they print
> "not implemented" until the real RTL/RDL ports begin.

## Source layout rules

- Every `.sv` source file in `rtl/` has a paired `.abc` file describing
  its dependencies. Same in `tests/` and `rtl/<module>/test/`.
- Every source and documentation file carries an SPDX header:
  ```
  SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
  SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
  ```
  This is enforced by the `reuse` CI job — a missing header is a CI failure.
- New files must compile with `verible-verilog-lint --rules_config_search`
  using the repo's lint config (TBD; placeholder for now).

## Test layout

- **Per-module testbenches live next to the module they exercise**, in
  `rtl/<module>/test/`. Moving a module moves its tests. `.abc` imports
  stay short and local.
- **`tests/` at the repo root is for high-level / system / integration
  testbenches only** — anything that spans multiple modules or exercises
  the encoder end-to-end. Do **not** put per-module unit testbenches here.

## RDL flow

SystemRDL is the source of truth for the register map.

1. Edit `rdl/*.rdl`.
2. Run `make rdl` — regenerates `rdl/gen/*.sv`.
3. Commit **both** the RDL source and the regenerated SV in the same
   commit. CI verifies they are in sync (TBD).

Never hand-edit `rdl/gen/*.sv` — those files are overwritten on regen.

## CI

GitHub Actions runs on every PR:

- `lint` — Verible lint over `rtl/` and `tests/`.
- `sim` — `make sim`. Needs a self-hosted Vivado runner (TBD).
- `reuse` — REUSE / SPDX compliance check (every file has a license header).

**Never push directly to `main`.** Open a PR from `albert/<desc>` and let
the CI run. Per the global workflow, Claude pushes the branch and stops
before opening the PR.

## Sensitive paths — propose changes, don't edit unsolicited

- `LICENSE.md`
- `LICENSES/` (any file under it)
- `.github/workflows/`
- `.github/CODEOWNERS`
- `.abc.config`
- `CITATION.cff`

These define the legal, CI, and review-routing surface of the project.
Edits land in chat first, then in a commit only after the user approves.

## External documentation

When linking to specs or upstream resources, prefer **public** sources:

- RISC-V N-Trace spec: <https://github.com/riscv-non-isa/riscv-trace-spec>
- CERN-OHL-S: <https://ohwr.org/cernohl>
- REUSE: <https://reuse.software>

Do not link to internal Accemic wikis, Jira, or anything not reachable
without an Accemic account from documentation, code comments, or
commit messages in this repo.

## Commit / PR conventions

**TBD — to be filled.** Open questions:

- Conventional Commits vs. free-form? (Project-wide convention not yet set.)
- DCO sign-off vs. CLA Assistant for contributor licensing?
- PR template content (see `.github/PULL_REQUEST_TEMPLATE.md`).

Until these are decided, follow the global `~/.claude/CLAUDE.md` rules
(self-contained, clear commit messages; PR opened by a human).

## Things this repo does **not** currently have (future enhancements)

- `Bender.yml` / FuseSoC `.core` manifest for ecosystem interop —
  worth adding once integration use cases are clearer.
- GitHub Pages site with auto-generated SV docs.
- A real Vivado version pin in `.abc.config` (currently a placeholder).
- A working `make sim` end-to-end (currently a stub).

If a task starts to touch any of these, propose a separate branch and
clarify scope with the user first.
