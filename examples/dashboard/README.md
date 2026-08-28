<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# CEDARtools.TraceEncoder dashboard

A browser-based live view of a CEDARtools.TraceEncoder-instrumented RISC-V SoC: register
map, block diagram, PC stream, symbolized coverage, and (where the design carries
it) AXIS watchpoint records — all read straight from the running hardware over
`/dev/mem`, no custom driver. It ships with a **hardware-free demo mode** that
replays real captured board sessions, so the whole thing is inspectable in a
browser without a KV260, without Vivado, and without any third-party Python
packages (stdlib only).

## Quickstart (hardware-free demo mode)

```
py server.py --demo
```

Then open <http://127.0.0.1:8099/> in a browser and pick a scenario from the
menu — that's it. Nothing on this path touches real hardware; every register
value, console line and trace byte comes from the recordings under `demo/`.

## What it shows

Ten scenarios ship as demo recordings, one per KV260 SoC build this
repository's `examples/kv260/` family produces:

| Scenario | Cores | What it exercises |
|---|---|---|
| `mbv` | MicroBlaze V | single-core bring-up, the smallest CTRL map |
| `cva6_linux` | CVA6 (RV32) | Linux 6.12 boot over N-Trace |
| `cva6_linux64` | CVA6 (cv64a6, RV64) | RV64 core, Sv39 addressing through the whole display chain |
| `rocket64` | Rocket (RV64) | a second RV64 core family, single hart |
| `rocket2` | 2× Rocket hart | SMP Linux, two harts sharing one encoder pair |
| `cva6_2_rv64` | 2× cv64a6 | AMP (two independent RV64 guests, not one SMP kernel) |
| `cva6_2_rv32` | 2× cv32a6 | AMP at RV32, Linux-capable core (not the trio's cv32a60x) |
| `trio` | MicroBlaze V + TGC5B + CVA6 | three cores, one funnel, N-Trace **and** E-Trace on the same stream (one back end per encoder instance, mixed in one netlist) |
| `duo` | MicroBlaze V + TGC5B | two cores, one funnel, N-Trace only -- the smallest multi-source case: two ISAs told apart by the Nexus SRC field alone (`demo/demo_trace.bin` IS this recording) |
| `tgc5b2_axis_wp` | 2× TGC5B | the AXIS watchpoint testbed (live record table, not trace) |

Each scenario page shows the live (or replayed) block diagram, the full CSR
map with per-block filtering, the decoded PC stream and symbolized coverage,
and — for `tgc5b2_axis_wp` and `trio` — the AXIS watchpoint record view
(`wp.html`).

## Running it on real hardware

The same `server.py` runs unmodified on a KV260 (or KR260): start it without
`--demo` and it opens `/dev/mem`, auto-detects the loaded bitstream from the
active app, and serves live register reads instead of a recording. That needs
the matching bitstream from `examples/kv260/` deployed and running — see that
example's own README for the board-side deploy steps (bitfile, device-tree
overlay, systemd unit via `board_dashboard_install.sh`).

The live path itself is unchanged from the board-verified version it was
migrated from, but it has not been re-run on hardware from this tree --
what is exercised here is demo mode and the test sweep below.

**Security note:** the dashboard has **no authentication**, and its
`/api/write` endpoint is effectively **direct `/dev/mem` write access** on the
host that runs it. It is meant for a lab bench, bound to `127.0.0.1` and
reached over an SSH tunnel, or — if bound to `0.0.0.0` for direct reach — run
only inside an isolated lab network segment. Never expose it to an untrusted
network.

## Testing

Every test here is a standalone script (`py <test_file>.py`, not a pytest
suite with `def test_*` functions) that prints a `PASS`/`FAIL`/`SKIP` verdict
and exits 0 on pass-or-skip, 1 on any real failure:

```
for f in test_*.py; do py "$f" || echo "FAILED: $f"; done
node test_addr64.mjs
```

None of them need a KV260, and most need nothing beyond the Python standard
library. Two dependencies are **optional** and each test degrades to a clean
`SKIP` (never a `FAIL`) when it is missing:

- **A RISC-V toolchain** (`riscv64/32-unknown-elf-readelf`/`-objdump`) — only
  `test_elf_load.py` and parts of `test_rv64_scenarios.py` use it, to cross-
  check `server.py`'s own ELF/disassembly parsing against a reference tool.
  Resolved via `RISCV_READELF`/`RISCV_BIN` environment variables or `PATH`;
  no path is hardcoded.
- **Node.js** (`node` on `PATH`) — `test_wp_view.py` runs the register-grouping
  JavaScript that ships inside `index.html` headlessly, to prove the shipped
  code (not a reimplementation of it) groups indexed registers correctly.
  This one specific check is a deliberate **exception**: it stays a hard
  `FAIL` without `node`, by design (a skipped guard that reports green would
  be the more expensive kind of false confidence — see the comment at its
  call site in `test_wp_view.py`). It does not affect the demo mode itself.

A handful of gates also SKIP cleanly when a fixture tree lives elsewhere in
this repository, or nowhere in it at all (the KV260 RTL tops under
`examples/kv260/`, or software-characterization ELF corpora that never
shipped as an example) — each SKIP line names exactly which tree is missing
and why that is expected here. The rule throughout this directory is: a
missing fixture is a named SKIP, never a FAIL, and never a silent pass.

## `devtools/` — the architecture-diagram round trip

`devtools/` holds the tooling that keeps the per-scenario block diagrams
(embedded in `index.html` as `ARCH_BY_SCEN`) in sync with hand-edited
[draw.io](https://www.drawio.com/) source files:

1. `py devtools/compact_layout.py` — derive an initial geometry straight from
   `scenarios.json` for a scenario that has none yet, writing
   `devtools/ctte_view_<id>.drawio.svg`.
2. Open that `.svg` in draw.io, rearrange it by hand, save.
3. `py server.py --demo --port 8142` — start the server the two measuring
   tools talk to, in its own shell, from `examples/dashboard/`. The port has
   to be named: `server.py` defaults to **8099**, but `measure_geometry.py`
   and `check_themes.py` default to **8142** (`sys.argv[1]` if given).
4. `py devtools/measure_geometry.py 8142` — measure the **rendered**
   dashboard against that server — the page scales and lays out arrows at
   runtime, so only a measurement gets the real pixel geometry. The port
   argument is optional here only because 8142 is also the tool's default;
   against a server left on 8099 you would pass `8099` instead.
5. `py devtools/check_congruence.py` — verify the hand-edited drawing and the
   measured rendering still agree (block positions, edges).
6. `py devtools/check_themes.py 8142` — verify every colour scheme in
   `themes.json` actually reaches the rendered page and meets WCAG contrast.
7. `py devtools/sync_arch_view.py` — write the reconciled geometry back into
   `index.html`'s `ARCH_BY_SCEN` blob and `devtools/arch_geometry.json`.
8. Stop the server from step 3.

`devtools/trio_dual_protocol_view.html` is a separate, self-contained page
documenting the `trio` scenario's N-Trace/E-Trace mixed-protocol funnel (one back end per encoder instance, mixed in one netlist); it
has no dependency on the round trip above.

## Files

| Path | Role |
|---|---|
| `server.py` | The dashboard server: HTTP API, `/dev/mem` access, ELF loading, ELF/PC decoding, demo-mode recording playback |
| `index.html`, `wp.html` | Self-contained frontend pages (no build step, no third-party JS) |
| `scenarios.json` | The scenario catalog: one entry per SoC build (cores, CTRL map, sinks, decode config) |
| `regmap.json` | The full CSR register map, generated from `rdl/ct_cs_cpuif.rdl` by `gen_regmap.py` |
| `themes.json`, `block_csrs.json`, `boot.json` | Colour schemes; block→CSR relevance for the detail panel; per-scenario guest boot recipes |
| `plclk.json` | Per-scenario `pl_clk0` label (68/75/100), each entry with the file its value is taken from. The server programs it between `xmutil unloadapp` and `xmutil loadapp` — the only moment a PL clock may change. A scenario without an entry keeps whatever the board has, and the load result says so |
| `demo/` | The hardware-free demo dataset: console captures, ELF/pcinfo metadata, symbol maps, recorded trace streams |
| `wp_view.py` | AXIS watchpoint state machine (live drain + deterministic demo generator); consumes `tools/axis_wp_host` |
| `scenario.py` | The scenario model behind `scenarios.json`: apertures, CTRL map, cores/encoders, sinks, console, decode config |
| `insight.py` | Post-decode analysis of the PC stream: symbolisation from a `System.map`, live window, hot list |
| `gen_regmap.py` | Generates `regmap.json` from `rdl/ct_cs_cpuif.rdl` (full profile) plus the hand-kept SoC CTRL block |
| `dis_to_symbols.py` | Turns objdump `.dis` listings into the symbol and call/return site maps the decoder configs reference |
| `make_demo_console.py` | Rebuilds `demo/console_<scenario>.txt` from the recorded board captures (reproducible, nothing invented) |
| `record_web_demo.py`, `record_web_replay.py` | Record the dataset for the public website: `_demo` the analysis/window dataset, `_replay` the v2 replay bundle of the original dashboard |
| `check_replay_public.py` | Marker scan over the public replay bundle — refuses commit IDs, internal source paths and RDL line references |
| `run_demo_axis.sh` | One-line launcher: demo mode, scenario `tgc5b2_axis_wp`, port 8151, log to `demo_axis_server.log` |
| `wp_board_start.py` | Starts the AXIS-WP demo program on the board (root, next to `axis_wp_host/`) |
| `boot/` | Per-scenario board boot sequences invoked by the guest-boot recipes in `boot.json`, one per Linux/AMP scenario that can boot a guest: `cva6_linux64_run.sh` (CVA6 RV64), `rocket_linux64_run.sh` (Rocket RV64), `rocket2_linux_run.sh` (two Rocket harts). All three share the same phase interface — `PHASE=prep` loads the payload and verifies it by reading the window back, `start` boots and measures a window, `live` switches to continuous operation — and all three run **on the board**, staged there by `board_dashboard_install.sh` together with `phys_io.py` and `kv260_plclk.sh` |
| `test_*.py`, `test_addr64.mjs` | The gates described above |
| `board_dashboard_install.sh` | Installs the dashboard as a persistent systemd service on the target board |
| `devtools/` | The architecture-diagram round trip described above |

## Licensing

Scripts and configuration data are ISC (see the SPDX header in each file, or
`REUSE-additions.toml.txt` for formats that cannot carry one). Captured
CTTE encoder byte streams under `demo/` follow the encoder's own licence,
CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial. This file is CC-BY-4.0.
