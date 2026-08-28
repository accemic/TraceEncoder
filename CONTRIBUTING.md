<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Contributing to CEDARtools.TraceEncoder

Thanks for your interest in contributing. This document describes the
expectations for changes to CEDARtools.TraceEncoder (CTTE). The earlier
short name *C-Trace* is retired from prose but deliberately kept where
renaming would break something outside this repository: the `ct_*` identifier
prefix (the IP's public API), the published demo bundles `*_ctrace_kv260` and
the board artifacts `ctrace_resmem.dtso` / `ctrace-pl-ddr` /
`ctrace-dashboard.service`, the Vivado block design `mbv_ctrace_soc` baked
into committed bitstreams, and the recorded captures and evidence files under
`examples/dashboard/demo/` and `verification/`, which are raw data with
published checksums. (The sibling repositories have all been renamed too —
`scripts/check_public_links.py`, part of `make check-publication`, fails on a
link to one of the retired names.)

## Quick checklist

- [ ] Branch named `<your-handle>/<short-description>` off `main`.
- [ ] All new files carry the SPDX header (see below).
- [ ] `make lint` passes.
- [ ] `make sim` passes for any module you touched.
- [ ] If you changed `rdl/ct_cs_cpuif.rdl`, you re-ran `make rdl` and
      committed the regenerated SV in the same commit; likewise
      `make rdl-soc` for `examples/kv260/common/tgc5b/rdl/ct_soc.rdl`.
- [ ] Commit messages explain *why*, not just *what*.
- [ ] You've signed the CLA (see [License & CLA](#license--cla)).

## Which checks apply to which change

The checklist above is the floor. Which *further* gate has to be green
depends on what you touched, and that mapping is not obvious from the
directory names, so here it is:

| You changed | What has to be green as well |
|---|---|
| RTL of the encoder pipeline | `make sim`, and the simulation gate battery `scripts/run_gates.sh` (overflow/robustness gates, the compression byte-identity legs, the feature gates) |
| a register description (`rdl/*.rdl`) | `make rdl` re-run and the regenerated files under `rtl/pkg/` committed in the *same* commit — they are never hand-edited |
| a feature switch (`rtl/pkg/ct_pkg.sv`, an RDL reset or offset, the TCODE-58 CAPS map) | `scripts/check_feature_flags.py`, the drift guard that holds those three representations of one switch to each other (part of `make lint`) |
| the emission core — the state machine that forms the output | the SymbiYosys property gates `scripts/run_formal.sh`, including the `RED=1` mutation counter-proof where the property has one ([`formal/README.md`](formal/README.md)) |
| the byte format on the wire, or the pinned decoder | the decoder regression corpus `scripts/run_corpus_regression.sh`: archived campaign captures under `verification/corpus/` must keep decoding to their recorded verdicts. Turning an old green capture red needs a commit message saying why the old verdict was wrong |
| anything that carries a claim about *hardware* behaviour (robustness, overflow recovery) | a run on a real KV260 board. A green simulation is evidence about the model, not about the hardware — and this repository no longer carries the lab campaign driver, so that evidence is produced outside it and quoted into `verification/evidence/` |
| a diagram under `doc/images/` | edit the **`.drawio.png` itself** — open it in draw.io, it *is* the source. Re-export with `drawio -x -f png -e -s 2 -b 0 -o <name>.drawio.png <name>.drawio` and delete any temporary `.drawio` you exported from; `scripts/check_drawio_embedded.py` (part of `make lint`) fails on a sibling `.drawio` or on an image that lost its embedded source |
| documentation under `doc/` | the conformance and limitation lists ([`doc/trace-format.adoc`](doc/trace-format.adoc), [`doc/release-notes.adoc`](doc/release-notes.adoc)) re-read against the RTL you changed. Resource numbers quoted in `doc/` are additionally checked against the reports under `verification/evidence/` by `scripts/check_doc_evidence.py` (part of `make lint`) |

### Continuous integration

CI runs on GitHub Actions ([`.github/workflows/`](.github/workflows/)). What
runs where, and why the split exists:

| Workflow / job | What it runs | Tools |
|---|---|---|
| `ci` → `lint` | `make lint`: 14 drift guards, the 6 publication guards below, and Verible over every `*.sv` | Python 3.8+, Verible |
| `ci` → `publication-checks` | `make check-publication` on its own (it is also part of `make lint`): no lab internals, English-only, tutorial paths resolve, no private host or retired repository name and every README link resolves, vendored-CVA6 delta list matches, mbv CTRL map consistent | Python only |
| `ci` → `dashboard-tests` | the dashboard's stdlib-only self-tests | Python, Node |
| `ci` → `sim` | `make sim` + `make sim-examples` | Verilator, `abc`; the decode verdict additionally needs CTTD |
| `ci` → `reuse` | REUSE / SPDX compliance | — |
| `formal` | `scripts/run_formal.sh`: the SymbiYosys property gates. A fast subset per PR, the full set nightly | OSS CAD Suite + sv2v, no EDA licence |

Two things deliberately do **not** run on a hosted runner, because they cannot:

- **The gate battery** `scripts/run_gates.sh` (51 gates listed in
  `scripts/gates.list`) needs Vivado XSIM. `make sim` is the
  simulator-agnostic subset that CI does run.
- **Hardware verdicts** need a real KV260 board.

You do not need all of them locally — CI runs what it can — but a PR that is
red in the check its change belongs to will come back.

## Development setup

The required tools and the high-level commands are listed once, in the
[README Quickstart](README.md#quickstart).

## Coding style

- Lint: `make lint` must pass before submitting a PR.
- Every `.sv` file has a paired `.abc` file declaring its dependencies.
- Per-module testbenches live in `rtl/<module>/test/`, **not** in
  `tests/`. The `tests/` directory at the repo root is reserved for
  high-level / integration tests.
- Never hand-edit the PeakRDL-generated files in `rtl/pkg/` (e.g.
  `ct_cs_cpuif*.sv`) — they're regenerated by `make rdl`.

## SPDX headers

Every file must begin with an SPDX header. The copyright line is always:

```
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
```

The license identifier depends on **what the file is** (see
[`LICENSE.md`](LICENSE.md)):

- Hardware IP — RTL (`.sv`), `.rdl`, `.xdc`, and the SystemVerilog/`.abc`
  testbenches: `CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial`
- Software — scripts, `Makefile`, CI, config: `ISC`
- Documentation — `.md`, `.adoc`, images: `CC-BY-4.0`

(The comment syntax depends on the language. For Markdown / HTML use
an HTML comment; for SystemVerilog / AsciiDoc use `//` lines; for shell /
Make use `#` lines. Files that cannot carry a header are recorded in
[`REUSE.toml`](REUSE.toml).)

**Third-party files are the exception.** Vendored third-party sources keep
their upstream copyright and license, and are left byte-identical — their
SPDX metadata goes into a REUSE `.license` sidecar instead of an in-file
header. The one such file today is the MINRES TGC5B core,
`examples/kv260/common/tgc5b/cpu/TGC5B_AXI4L_H2E.sv` (see
[`examples/kv260/common/tgc5b/cpu/README.md`](examples/kv260/common/tgc5b/cpu/README.md)).
Do not modify it and do not submit patches against it — they belong
upstream at MINRES. Adding new vendored third-party code needs a
maintainer decision first.

The `reuse` CI job will fail any PR that introduces a file without a
valid SPDX header.

## Pull requests

1. Push your branch to your fork (or the main repo if you have write
   access).
2. Open a PR against `main`.
3. CI must pass: lint, simulation (`make sim` and `make sim-examples` under
   Verilator) and REUSE.
4. At least one maintainer review is required before merge — see
   [`.github/CODEOWNERS`](.github/CODEOWNERS) for routing.
5. Squash-merge is the default. Keep the squashed commit message
   informative.

## License & CLA

CTTE is licensed per artifact type (see [`LICENSE.md`](LICENSE.md)):
the **hardware IP** is dual-licensed under **CERN-OHL-S-2.0** or a
**commercial license** from Accemic Technologies GmbH, **software** is
**ISC**, and **documentation** is **CC-BY-4.0**.

To preserve the dual-license option for the hardware IP, contributions
require a **Contributor License Agreement** assigning the necessary
rights to Accemic Technologies GmbH while leaving you with copyright over
your work. Please contact Accemic Technologies GmbH at <info@accemic.com>
to arrange the CLA before your contribution can be merged.

For questions: <info@accemic.com>.
