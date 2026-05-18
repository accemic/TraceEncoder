<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
-->

# High-level tests

This directory is for **high-level / system / integration testbenches**
only — anything that exercises C-Trace end-to-end or spans multiple
modules.

**Per-module unit testbenches do not live here.** They live next to
the module they test, under `rtl/<module>/test/`. See
[`../rtl/README.md`](../rtl/README.md) for the module-test convention.

## What belongs here

- End-to-end encoder tests: TIP stimulus → ATB / AXIS output check.
- Multi-module integration: e.g. encoder + ATB bridge + sink.
- Regression suites that pull from `examples/` or replay captured
  traces.
- Performance / throughput benchmarks.

## What does **not** belong here

- Unit tests for a single module → `rtl/<module>/test/` instead.
- Stand-alone interface mocks → keep them with the module they support.

## Conventions

- Each test directory contains `<test>.sv` + `<test>.abc` and uses
  `abc -sim <test>.abc` to run.
- SPDX header on every file.
- Format / lint pass before submitting.
