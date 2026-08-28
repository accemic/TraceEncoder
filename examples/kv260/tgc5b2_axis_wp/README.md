<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/tgc5b2_axis_wp -- dual MINRES TGC5B watchpoint/DAQ testbed on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) testbed for the CTTE
encoder's AXIS instrumentation-stream (ACT-CAP/ACT-ST watchpoint/DAQ) export
path: **two** independent MINRES TGC5B RISC-V cores, each with its own
CTTE encoder instance, each feeding a `ct_axis_wp_shim` that turns the
encoder's 96-bit AXIS watchpoint-hit stream into 32-bit records for a
`axi_fifo_mm_s` a Linux host can drain with `/dev/mem` reads. In parallel,
both encoders' Nexus (N-Trace) ATB output is merged by `ct_L1_funnel` into
the same three-sink subsystem (URAM ring + DDR4 + PIB) the `duo`/`trio`
examples use, so a program-flow capture is available alongside the
watchpoint records for cross-checking.

Migrated 2026-08-17 from an internal predecessor repository; see
[`../README.md`](../README.md) for the conventions all KV260 examples
share. Companion example:
[`../duo/`](../duo/) (the two-core Nexus-only pattern this testbed's SoC-level
plumbing follows) and [`../trio/`](../trio/) (three cores, mixed-protocol
funnel).

## What it shows

- **Two independent RISC-V cores, no SMP.** Each TGC5B has its own 64 KiB
  RAM, its own CLINT, its own CTTE encoder; `CONTROL` starts/stops them
  individually (`b8`/`b9`) or together (`b0`, historic collective bit).
- **A shared time base.** One free-running 64-bit fabric counter feeds both
  encoders' `tip._time` input (`time_i`) instead of each core's own `mcycle`
  -- two cores started at different times would otherwise carry two drifting
  timestamps (see `tgc5b_wp_synth_wrap.sv`'s header, deviation (a)).
- **The AXIS export path with no backpressure.** The encoder's ACT-CAP/
  ACT-ST AXIS master never samples `tready`; `ct_axis_wp_shim`
  (`../common/ct_axis_wp_shim.sv`) is the shim that makes that safe --
  internal FIFO, saturating drop counter, sticky overflow flag -- documented
  in the shim's own header.
- **The same three-sink Nexus capture as `duo`/`trio`**, via `ct_L1_funnel`
  (round-robin, `EN_TE_RAW=0` -- this testbed does not use the E-Trace/CTMX
  mixed-protocol path those examples exercise) and `ct_trace_sinks`
  (`../common/`): 1 MiB URAM ring + DDR4 sink + PIB parallel port.
- **A deterministic watchpoint oracle.** [`sw/`](sw/) is a self-contained
  generate -> build -> extract -> cross-check pipeline (`gen_program.py` ->
  `build.sh` -> `gen_wp_set.py` -> `check_consistency.py`) that produces a
  1023-entry watchpoint set and its expected hit sequence from a seeded,
  IRQ-paced walk over ~300 generated leaf functions -- see
  [`sw/README.md`](sw/README.md).

## Layout

```
rtl/    tgc5b_wp_synth_wrap.sv    TGC5B + H2E adapter + ct_encoder, one deviation from
                                  examples/kv260/common/tgc5b/rtl/ct_soc_synth_wrap.sv: an external
                                  time_i input instead of the core-local mcycle (see header)
        tgc5b2_axis_soc_top.sv   two SoC branches + two ct_axis_wp_shim + ct_L1_funnel +
                                  ct_trace_sinks; AXI4-Lite control port (CTRL/ENC0/ENC1/RAM0/RAM1/TRACE)
fpga/   tgc5b2_kv260_top.sv       bitstream top: Zynq PS + AXI plumbing + a 1:4 AXI4-Lite router
                                  (SOC / WPCTRL / FIFO0 / FIFO1) + 2x axi_fifo_mm_s
        create_project.tcl        entry point: builds the Vivado project (see "Build" below)
        gen_ip.tcl                the 5 standalone IPs (PS, reset sync, AXI DWC, AXI4-to-Lite, RX FIFO)
        tgc5b2_axis_wp.xdc        PIB pinout (KV260 PMOD J2, duo-pattern-compatible)
        abc_filelist.py           resolves the CTTE encoder's .abc dependency graph into a file list
sim/    tb_axis_wp_shim*.sv       unit bench of ct_axis_wp_shim (both FIFO depths)
        tb_tgc5b2_axis_soc*.sv    full-chain bench, legs C1a/C1b (see "Simulation")
        *.abc                     the graph nodes `make sim-*` runs
sw/     axis_wp_demo/ -> here     deterministic walk program + WP-set generator + oracle (see sw/README.md)
```

`tgc5b_wp_synth_wrap.sv` and `tgc5b2_axis_soc_top.sv` consume the shared
sink/shim RTL from [`../common/`](../common/) (`ct_soc_trace_ring`,
`ct_soc_ddr_sink`, `ct_soc_pib`, `ct_trace_sinks`, `ct_axis_wp_shim`) and
the TGC5B building blocks + `ct_axil_to_wb` from
[`../common/tgc5b/`](../common/tgc5b/) rather than duplicating them.

## Simulation

Three legs, all on the pinned default backend (`.abc.config`:
`sim_backend=verilator`) -- no Vivado, no runner script, one `.abc` graph
node each:

```sh
make sim-axis-wp-shim        # unit bench of ct_axis_wp_shim, both FIFO depths
make sim-tgc5b2-axis-soc     # the full chain, legs C1a and C1b
make sim-ddr-sink-window     # the DDR sink's window guard (../common/sim/)
```

| Leg | What it proves | Marker |
|---|---|---|
| `sim-axis-wp-shim` | record packing, stall/overflow/resume, tstrb/tid into W3, 12k-beat soak, `drop_count` saturation -- at `FIFO_DEPTH` 256 (product default) and 16 (stress) | `TB_PASS (… DEPTH=256)` / `(… DEPTH=16)` |
| `sim-tgc5b2-axis-soc` C1a | devmem flow over the AXI4-Lite port: program load, watchpoint table (13 real entries), both cores traced, scoreboard against `sw/expected_hits.txt`, DDR-sink accounting, PIB calibration + beat balance, per-core run bits, drop scenario | `C1A_ALL_PASS` |
| `sim-tgc5b2-axis-soc` C1b | the same chain with the FULL oracle (all 851 expected hits per core, in order), timestamps (`trTsControl.Type=TR_TS_CORE`, per-core monotonic + cross-core bounded) and the negative probe (a table commit while the encoder is enabled moves nothing) | `C1B_ALL_PASS` |

All three are in `SIM_EXAMPLES`, so `make sim-examples` runs them.

The benches load their program and oracle straight out of [`sw/`](sw/)
(`axis_wp_demo.hex`, `expected_hits.txt`) -- nothing is copied anywhere, and
a regenerated `sw/` is picked up by the next run.

`sim-tgc5b2-axis-soc` is the long one: it verilates two TGC5B cores with
their two encoders. Measured on a 32-thread Windows host with two Vivado
sessions alongside: C1a 38 s, C1b 247 s (both from a cold work dir). If the
C++ build stage dies with `cc1plus: out of memory` / `the paging file is too
small`, that is the host, not the design -- Verilator's default is one build
job per core. Cap it:

```sh
ABC_VERILATOR_EXTRA_ARGS="--build-jobs 4" make sim-tgc5b2-axis-soc
```

## Register map (AXI4-Lite router, `tgc5b2_kv260_top`)

| Target | Offset | Contents |
|---|---|---|
| SOC    | `0xA000_0000` | `tgc5b2_axis_soc_top` (CTRL/ENC0/ENC1/RAM1/RAM0/TRACE, decodes the low 22 bits) |
| WPCTRL | `0xA040_0000` | D1 status registers: shim drop/fill/overflow, fabric-counter snapshot, magic |
| FIFO0  | `0xA041_0000` | `axi_fifo_mm_s` core 0 (PG080 register set) |
| FIFO1  | `0xA042_0000` | `axi_fifo_mm_s` core 1 |

SOC-region CTRL detail (register offsets, `SINK_CTRL`/`DDR_*`/`PIB_*` window)
is documented in `tgc5b2_axis_soc_top.sv`'s header comment (`@details`).

## Build (TCL flow)

Like `duo`/`trio`, this example's Vivado flow is still a plain TCL script,
not yet this repository's `abc` build driver -- see `../mbv/README.md`'s
"Build" section for why that conversion is a deliberate later step.

```bash
# Project + RTL elaboration check only:
vivado -mode batch -notrace -source examples/kv260/tgc5b2_axis_wp/fpga/create_project.tcl

# Full synth -> impl -> bitstream (after create_project.tcl):
vivado -mode batch -notrace -source examples/kv260/tgc5b2_axis_wp/fpga/run_bitstream.tcl
```

`vivado` itself must be on `PATH`. Unlike the source repository's version of
these scripts, there is no `AXIS_WP_LEG` environment switch -- the predecessor repository
used it to select between four RTL feature-set snapshots taken while this
testbed was under active development (D1/C0B/C0B_DDR/C0B_SINK3); by the T2
state migrated here all four snapshots build the identical RTL (only which
encoder checkout was bound differed, and one of the four legs pointed at a
read-only external worktree path that does not exist outside the predecessor repository),
so only the final, T2-equivalent configuration is carried here.

## Running the watchpoint/DAQ testbed

Board-deploy and board-gate tooling lives in this example:
[`board/`](board/) holds `wp_board_gate.sh` with its seven phases
(`gen`, `deploy`, `runa`, `checksa`, `runb`, `checksb`, `restore`) plus the
board-side helpers `prep_load.sh`, `prep_verify.sh`, `run_a.sh`, `run_b.sh`
and `restore.sh`; the shared packaging/loader parts it calls
(`package_kv260_app.py`, `deploy_kv260_app.sh`, `mem_load.py`) are in
[`../common/board/`](../common/board/). See
[`board/README.md`](board/README.md) for usage and options. Board verdict on
record: `G1CHECK runa PASS` 851/851, merge 1702/0, 2026-08-18 — as listed in
[`../README.md`](../README.md).

The gate automates the following sequence; the same steps are reproducible by
hand via `devmem` against the register map above:

1. Build [`sw/`](sw/) (`bash build.sh`, or run the full pipeline in
   `sw/README.md` to also regenerate `wp_set.txt`/`expected_hits.txt`).
2. Hold both cores (`CONTROL.core0_run=CONTROL.core1_run=0`), write the
   program image word-by-word into RAM0/RAM1.
3. Configure each encoder over its own ENC region and load its watchpoint
   set from `wp_set.txt` (encoder CSR protocol, not this example's own
   concern -- see the CTTE RM's watchpoint/ACT-CAP chapter).
4. Start both cores; drain FIFO0/FIFO1 via WPCTRL/`devmem` and compare
   against `sw/expected_hits.txt`.
5. Optionally read the Nexus capture (TRACE region, ring order as in the
   `mbv`/`duo` examples) for a program-flow cross-check.

## Verification performed during migration

`verilator --lint-only` elaboration of `tgc5b2_axis_soc_top` together with
its dependencies (`../common/`, `../common/tgc5b/`, and this example's own
`tgc5b_wp_synth_wrap.sv`) and a repository-wide duplicate-module-name
check, both green. `sw/` was fully rebuilt in its new location
(`gen_program.py` -> `build.sh` -> `gen_wp_set.py` -> `check_consistency.py`,
ending in `E0_ALL_PASS`) and every regenerated artifact diffed
byte-identical against the copy carried over from the predecessor repository (the one
expected difference is the embedded source path inside `axis_wp_demo.dis`'s
`objdump` header line). The Vivado TCL flow itself (`fpga/`) was adapted by
careful path/reference review, not executed -- no Vivado license/session was
exercised as part of this migration.
