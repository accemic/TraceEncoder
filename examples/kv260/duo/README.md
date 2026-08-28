<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/duo -- MicroBlaze-V + MINRES TGC5B, funnelled trace, on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) demonstrator that traces **two**
independent RISC-V cores at once: an AMD MicroBlaze-V (same branch as
[`../mbv/`](../mbv/)) and a MINRES TGC5B (same branch as
`examples/kv260/common/tgc5b/`), each with its own CTTE encoder instance. A
`ct_L1_funnel` merges both encoders' ATB (Nexus) streams into one packet-
atomic stream, which then feeds the shared three-sink subsystem: an on-chip
1 MiB URAM ring, a DDR4 sink, and a parallel PIB port -- all three run in
parallel, reset-inert, and never backpressure the trace path. The decoder
tells the two sources apart via the Nexus SRC field.

Migrated 2026-08-17 from an internal predecessor repository; see
[`../README.md`](../README.md) for the conventions all KV260 examples
share. Companion examples:
[`../mbv/`](../mbv/) (the single-core MicroBlaze-V pattern this example's MBV
branch and AXI4-Lite front end are extended from) and [`../trio/`](../trio/)
(adds a third core, CVA6, plus a dual N-Trace/E-Trace funnel protocol).

## What it shows

- **Two heterogeneous cores merged into one trace stream.** `ct_L1_funnel`
  (`N_STREAMS=2`, `MDO_WIDTH=6` -- four byte chunks per 32-bit beat, the real
  wire format both encoders emit) arbitrates round-robin by default,
  configurable live per channel via `FUNNEL_CTRL` (priority, not just
  round-robin).
- **Per-core start/stop.** `CONTROL.core0_run`/`core1_run` (`b8`/`b9`) let
  either core run independently of the historic collective `b0` bit -- the
  two branches share nothing (different ISAs, separate RAMs, no SMP).
- **The three-sink subsystem** (`ct_trace_sinks`, `../common/`): the URAM
  ring stays the primary always-ready sink; the DDR4 sink
  (`ct_soc_ddr_sink`, AXI4 master to PS `S_AXI_HP0_FPD`) and the PIB parallel
  port (`ct_soc_pib`, 4-bit DDR, KR260-adapter-compatible pinout) are
  additive observers with their own drop counters.
- **A reusable AXI4-Lite router pattern.** `duo_kv260_top.sv`'s PS-facing
  plumbing (128-bit `M_AXI_HPM0_FPD` -> width downsize -> AXI4-Lite) is the
  same shape `../mbv/` and `../trio/` use, just with `S_AXI_HP0_FPD` wired to
  the DDR4 sink in addition.

## Layout

```
rtl/    duo_soc_top.sv            AXI4-Lite control-port top: 2 SoC branches + funnel + sinks
                                  (CTRL/ENC0/ENC1/RAM0/RAM1/TRACE/AXIS regions)
fpga/   duo_kv260_top.sv          bitstream top: Zynq PS + AXI plumbing around duo_soc_top
                                  (adds the S_AXI_HP0_FPD DDR4-sink port vs. mbv_kv260_top)
        create_project_kv260.tcl entry point: builds the Vivado project (see "Build" below)
        gen_ip.tcl                the 4 standalone PS-glue IPs (byte-identical to ../mbv/fpga/gen_ip.tcl --
                                  that file was already a superset provisioning GP2/GP3 for duo/trio)
        duo_pib_pmod.xdc          PIB pinout (KV260 PMOD J2, KR260-adapter-compatible)
        abc_filelist.py           resolves the CTTE encoder's .abc dependency graph into a file list
sim/    tb_duo_ps_devmem.sv       the whole devmem flow through duo_soc_top -- Vivado xsim
                                  only (see sim/README.md for why, and for what was checked
                                  without it)
```

`duo_soc_top.sv` instantiates `mbv_soc_synth_wrap` from
[`../mbv/rtl/`](../mbv/rtl/) (read-only reuse, not duplicated) for its MBV
branch, `ct_soc_synth_wrap` from
[`../common/tgc5b/rtl/`](../common/tgc5b/rtl/) for its TGC5B branch, and the
shared sink RTL from [`../common/`](../common/) (`ct_soc_trace_ring`,
`ct_soc_ddr_sink`, `ct_soc_pib`, `ct_trace_sinks`) plus `ct_L1_funnel` from
this repository's root (`../../../rtl/ct_L1_funnel.sv`).

## Register map (AXI4-Lite aperture, base `0xA000_0000`)

| Region | Offset | Contents |
|---|---|---|
| CTRL  | `0x00_0000` | control/status registers (`duo_soc_top.sv`) |
| ENC0  | `0x01_0000` | CTTE encoder CSRs, MBV     (via `ct_axil_to_wb` -> Wishbone) |
| ENC1  | `0x02_0000` | CTTE encoder CSRs, TGC5B   (via `ct_axil_to_wb` -> Wishbone) |
| RAM1  | `0x08_0000` | TGC5B program/data RAM (64 KiB; write while `core1_run=0`) |
| RAM0  | `0x10_0000` | MBV program/data RAM (128 KiB; write while `core0_run=0`) |
| TRACE | `0x20_0000` | merged ATB ring buffer (1 MiB URAM) |
| AXIS  | `0x30_0000` | AXIS capture (MBV encoder only) |

CTRL register detail -- including the `SINK_CTRL`/`DDR_BASE`/`DDR_SIZE`/
`DDR_WPTR`/`SINK_STAT`/`DDR_DROPS`/`PIB_DROPS`/`FUNNEL_CTRL`/`DDR_BEATS`
window -- is documented in `duo_soc_top.sv`'s header comment (`@details`).

## Build (TCL flow)

Like `../mbv/`, this example's Vivado flow is still a plain TCL script, not
yet this repository's `abc` build driver -- see `../mbv/README.md`'s "Build"
section for why that conversion is a deliberate later step.

```bash
# Project + RTL elaboration check only:
vivado -mode batch -source examples/kv260/duo/fpga/create_project_kv260.tcl

# Full synth -> impl -> bitstream:
DUO_KV260_SYNTH=1 vivado -mode batch -source examples/kv260/duo/fpga/create_project_kv260.tcl
```

Unlike the predecessor repository's original two-script flow (`create_project_kv260.tcl` +
`run_duo_bitstream.tcl`, which built on top of an already-open `mbv_kv260`
project to reuse its cached block design across local iterations), this
migrated version is a single, self-contained entry point that builds `duo`
from a clean project. That restructuring is disclosed here rather than
silent (the resulting bitstream is unaffected;
only the predecessor-repository-internal project-cache reuse was dropped as
non-portable).

## Running the bare-metal programs

Board-deploy tooling lives in this example: [`board/`](board/) holds
`duo_board_gate.sh`, which packages the bitstream, deploys it, runs both
cores and decodes both streams; the cross-example packaging/loader parts it
calls (`package_kv260_app.py`, `deploy_kv260_app.sh`, `mem_load.py`) are in
[`../common/board/`](../common/board/). See [`board/README.md`](board/README.md)
for the phases and options. Board verdict on record:
`DUO_BOARD PASS` (both streams decoded), 2026-08-18 — as listed in
[`../README.md`](../README.md).

The register-level protocol is identical to `../mbv/README.md`'s "Running
the bare-metal programs" section, applied per core (RAM0/ENC0 for MBV,
RAM1/ENC1 for TGC5B) with the added `FUNNEL_CTRL`/`SINK_CTRL`/`DDR_*`/`PIB_*`
registers documented above; the gate script automates exactly that sequence.

## Live view: the `duo` dashboard scenario

The dashboard in [`../../dashboard/`](../../dashboard/) carries a `duo`
scenario (`scenarios.json`, id `duo`, app `duo_ctrace_kv260`). It renders the
two-core block diagram, the CSR map of both encoder instances, and the decoded
PC stream of both sources side by side.

```bash
cd examples/dashboard
py server.py                      # on the board: /dev/mem, app auto-detected
py server.py --demo --port 8155   # off the board: replay, then pick "duo"
```

Two things about this scenario are worth knowing, because both are places
where copying a neighbouring scenario would have been wrong:

- **`0x34` is `FUNNEL_CTRL` here, not `ATB_STALLS`.** The single-core
  `../mbv/` build puts its ATB back-pressure counter at that offset
  (`mbv_soc_top.sv`); `duo_soc_top.sv` puts the funnel's channel priorities
  there. A dashboard with hard-wired offsets would read one design's counter
  under the other design's name -- which is exactly why the CTRL map lives in
  `scenarios.json` per app.
- **The scenario carries no merged symbol table** (`"symbols": null`). Both
  guest programs are linked from address `0x0`, so one flat table would label
  the MicroBlaze-V's PCs with TGC5B names and vice versa. The live view shows
  addresses instead of plausible-looking wrong names.

The offline replay is a real capture of *this* design: `demo/demo_trace.bin`
is the merged stream from the green `duo` simulation. It decodes against
`demo/mbv.pcinfo` (SRC 0, the same `trace_test` image `board/duo_board_gate.sh`
loads into RAM0) and `demo/tgc.pcinfo` (SRC 1, `hello_trace`) with
`-src 2`, yielding 20112 + 15229 = 35341 instructions and zero error
messages.

## Verification performed during migration

`verilator --lint-only` elaboration of `duo_soc_top` together with its
dependencies (`../mbv/rtl/`, `../common/tgc5b/rtl/`, `../common/`, and the
repository's own `rtl/ct_L1_funnel.sv`) and a repository-wide
duplicate-module-name check, both green.
The Vivado TCL flow itself (`fpga/`) was adapted by careful path/reference
review, not executed -- no Vivado license/session was exercised as part of
this migration.
