<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Worked integrations

Everything under `examples/` shows the CEDARtools.TraceEncoder (CTTE) IP doing
real work: driven by a real core, captured by a real sink, decoded by the real
decoder. The root of the repository is the IP; this directory is what it can
do.

Three entry levels, by rising effort:

1. **Dashboard demo mode** — no hardware, no FPGA tools, stdlib-only Python.
   `examples/dashboard/`, three commands, ~2 minutes.
2. **Simulation** — `make sim-examples` runs the examples wired into
   `SIM_EXAMPLES` (the variable in the `Makefile`): `tgc5b-soc` from
   `kv260/common/tgc5b/`, plus `ddr-sink-window`, `axis-wp-shim`,
   `tgc5b2-axis-soc` and `ctte-smoke` from `kv260/` (see
   [`kv260/README.md`](kv260/README.md), "Simulation legs of the KV260
   examples"). Needs abc + a simulator; program artifacts are committed, so
   no RISC-V toolchain. The MicroBlaze-V-based examples (`mbv`, `duo`,
   `trio`) have benches in the tree but cannot run on the default backend
   (encrypted core — see [`kv260/mbv/sim/README.md`](kv260/mbv/sim/README.md));
   the CVA6 and Rocket examples have no bench yet.
3. **KV260 board flows** — build a bitstream, deploy, watch live trace.
   `examples/kv260/` (all nine examples migrated; four board-gated from this
   tree, see status column). Without Vivado: every demo ships its
   ready-to-load app under `kv260/<demo>/fpga/prebuilt/`.

## Catalog

| Example | Core(s) | Status |
|---|---|---|
| `dashboard/` | any (consumes captures) | **in tree** — browser dashboard; demo mode replays committed captures without hardware (`py examples/dashboard/server.py --demo`) |
| `kv260/common/` | — (shared board RTL) | **in tree** — trace sinks (URAM ring, DDR sink, PIB), watchpoint shim |
| `kv260/common/tgc5b/` | MINRES TGC5B (RV32) | **in tree** — not an example but the shared library eight examples build on: the vendored core, the AXI-Lite→Wishbone bridge, SoC RAM/CLINT/INTC + their RDL, and the `hello_trace` program. Its own SoC bench is `make sim-tgc5b-soc` ([`kv260/common/tgc5b/README.md`](kv260/common/tgc5b/README.md)) |
| `kv260/mbv/` | AMD MicroBlaze V (RV32) | **in tree, board-gated 2026-08-17** — 11 bare-metal programs, TRACE-bus ingress adapter; bitstream built here (Vivado 2026.1, WNS +2.094), 26772/26772 PCs prefix-identical on KV260 |
| `kv260/cva6_linux/`, `kv260/cva6_linux64/`, `kv260/cva6_2/` | CVA6 (RV32/RV64, AMP pair) | **in tree; cva6_linux boots on the board 2026-08-17** — reference core fetched by pin + local delta patch series (`third_party/patches/cva6/`), Buildroot br2_external sources (payload builds on a Linux host); cva6_linux bitstream built here (WNS +2.265), OpenSBI + kernel captured; the other two: bitstream flows migrated, board leg pending |
| `kv260/rocket_linux/`, `kv260/rocket2/` | Rocket (RV64, 2-hart SMP) | **in tree** — Buildroot br2_external sources, lint 0 errors with core stubs |
| `kv260/duo/`, `kv260/trio/` | MBV+TGC5B (+CVA6) | **in tree; duo board-gated 2026-08-17** — multi-core funnel; duo bitstream built here (WNS +2.188), both streams decoded on KV260 (first-ever duo board run); trio adds the per-instance protocol mix (Nexus next to E-Trace raw in one CTMX container, demux tool vendored), board leg pending |
| `kv260/tgc5b2_axis_wp/` | 2× TGC5B | **in tree, board-gated 2026-08-17** — watchpoint/DAQ testbed; bitstream built here (WNS +1.575), 851/851 watchpoint records per core on KV260, cross-core merge monotone; sw pipeline byte-identical (E0_ALL_PASS, 1023 watchpoints) |

## Vivado versions, honestly

Two tool generations are in play, on purpose (no silent unification):

- **Core simulation and the gate battery** pin **Vivado 2022.1** (xsim, via
  `.abc.config` at the repo root). That is the version every core verdict
  recorded under `verification/evidence/` is calibrated against.
- **The `kv260/` bitstream flows** are verified with **Vivado 2026.1**;
  the 2026-08-17 board gates (mbv, tgc5b2_axis_wp) ran on 2026.1-built
  bitstreams.

The resource cost of the newer tool generation is measured, not assumed:
~2.5x LUT premium between the two on the same RTL (measured in the
internal predecessor repository; that report is not in this tree). A version
bump for either side is a deliberate, measured change — never a side effect.

## Rules that keep this directory honest

- Every example that has a simulation leg is wired into `make sim-examples`,
  which **refuses to pass over an empty list** — a summary over nothing must
  never read as green. `SIM_EXAMPLES` in the `Makefile` is that list (entry
  level 2 above names its current contents). A `kv260/` example without a
  sim leg is not in it, so `make sim-examples` says nothing about that
  example — its evidence is the per-example board gate.
- Vendored third-party cores (`*/cpu/`) and the pinned reference-core material
  under `kv260/third_party/` keep their upstream coding style and are excluded
  from lint; everything else lints like the core IP.
- No bitstreams, no `.rpt` reports, no measurement logs in git. Build scripts
  and small committed program artifacts only.
- Board flows document their deploy traps next to the flow, not in tribal
  memory (see `kv260/README.md`).
