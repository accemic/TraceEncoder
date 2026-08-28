<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/mbv — MicroBlaze-V + CTTE on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) demonstrator that traces a bare
AMD MicroBlaze-V RISC-V core with CTTE. The Zynq UltraScale+ PS runs Linux
and drives the whole SoC via `devmem` reads/writes at a single AXI4-Lite
aperture (`0xA000_0000`); the PL holds the MicroBlaze-V core, the
[`rtl/adapters/amd_microblaze_v/`](../../../rtl/adapters/amd_microblaze_v/)
`TRACE`-bus-to-TIP adapter, a CTTE encoder instance, and an on-chip
capture ring readable from Linux.

Migrated 2026-08-17 from an internal predecessor repository -- the first
example moved after the shared sink RTL landed in
[`../common/`](../common/); see [`../README.md`](../README.md) for the
conventions all KV260 examples share.

## Layout

```
rtl/    mbv_soc_top.sv            AXI4-Lite control-port top (CTRL/ENC/RAM/TRACE/AXIS regions)
        mbv_soc_synth_wrap.sv     the bare MicroBlaze-V + CTTE SoC (block design + adapter + encoder)
fpga/   mbv_kv260_top.sv          bitstream top: Zynq PS + AXI plumbing around mbv_soc_top
        create_project_kv260.tcl entry point: builds the Vivado project (see "Build" below)
        create_bd.tcl             the mbv_ctrace_soc block design (MicroBlaze V + LMB + BRAM controllers)
        gen_ip.tcl                the 4 standalone PS-glue IPs (PS, reset sync, AXI DWC, AXI4-to-Lite)
        mbv_pib_pmod.xdc          PIB parallel trace port pinout (carrier PMOD J2, KR260-adapter compatible)
        abc_filelist.py           resolves the CTTE encoder's .abc dependency graph into a file list
board/  mbv_board_gate.sh         package -> deploy -> run -> capture -> decode -> compare (see board/README.md)
sw/     11 RV32 bare-metal test programs + crt0.S + linker script + Makefile (see sw/README.md)
sim/    tb_ctte_smoke.sv        the encoder alone -- the one bench here that runs on the
                                  default backend: `make sim-ctte-smoke`
        tb_mbv_{g0_soc,g4_ctrace,ps_devmem,native_probe,native_enable,dual_encoder}.sv
        mbv_ctte_env.sv / mbv_dual_encoder_env.sv / amd_native_trace_dump.sv
                                  the SoC/E2E level -- Vivado xsim only, see sim/README.md
```

`mbv_soc_top.sv` and `mbv_soc_synth_wrap.sv` consume the shared sink RTL from
[`../common/`](../common/) (`ct_trace_sinks` and the three sinks it holds:
`ct_soc_trace_ring`, `ct_soc_ddr_sink`, `ct_soc_pib`) and from
[`../common/tgc5b/rtl/`](../common/tgc5b/rtl/) (`ct_axil_to_wb`,
`ct_soc_axis_buf`) rather than duplicating them -- both were measured
byte-identical to the `common/tgc5b` copies apart from doc comments.

## Trace sinks

Since 2026-08-18 this example instantiates the same three-sink subsystem
[`ct_trace_sinks`](../common/ct_trace_sinks.sv) that `duo`, `trio` and
`tgc5b2_axis_wp` already carry -- `mbv` was the last single-sink design in the
tree. All three sinks observe the same ATB beat stream in parallel: the URAM
ring is the primary, always-ready sink, DDR4 and PIB are additive observers
with their own FIFO and drop counter and never back-pressure the trace path.

| Sink | Module | Where it goes |
|---|---|---|
| `Mem(URAM)` | `ct_soc_trace_ring` (1 MiB, as before) | read back through the TRACE region |
| `Mem(DDR4)` | `ct_soc_ddr_sink`, AXI4 write-only master | PS `S_AXI_HP0_FPD` -> DDR window `0x5000_0000` + 256 MiB |
| `PIB` | `ct_soc_pib`, 4-bit DDR parallel port | `pib_clk`/`pib_data[3:0]` on carrier PMOD J2 (`fpga/mbv_pib_pmod.xdc`) |

Two consequences at the bitstream top (`fpga/mbv_kv260_top.sv`): the PS slave
port `S_AXI_HP0_FPD` is now driven instead of tied off (the PS IP always had it
enabled -- `gen_ip.tcl` -- because `duo`/`trio` use it), and `pib_clk`/
`pib_data[3:0]` are this design's first external pins. The PMOD pinout is
byte-identical to `../duo/fpga/duo_pib_pmod.xdc` apart from its header note:
the pin contract belongs to the KR260 PMOD adapter, not to a single example,
so the two files stay in step.

The DDR window is read-only in hardware (U9-1: `DDR_BASE`/`DDR_SIZE` discard
every write and latch `SINK_STAT.ddr_cfg_rej`) and must stay inside the
boot-time reservation `ctrace-pl-ddr@50000000`
([`../common/board/ctrace_resmem.dtso`](../common/board/ctrace_resmem.dtso)) --
the RTL reset value and the reserved-memory window are one contract; changing
one means changing the other.

**Reset-inert:** `SINK_CTRL` resets to 0, so DDR and PIB are off and the ring
captures circular exactly as the pre-subsystem build did. A `devmem` protocol
that never writes `0x18` sees no behavioural change at all.

**One register moved -- breaking for anything that writes it:** `ATB_BP` is now
at CTRL `0x40`, no longer at `0x38`, because `0x38` is `DDR_BEATS` inside the
shared sink window. `ATB_STALLS` (`0x34`) and `IRQ_DIV` (`0x3C`) are unchanged;
`0x40` is the offset `../common/rdl/README.md` names for this register. The known consumer is the
board campaign's `ATB_BP_OFFSET`, which has to follow -- a write to the old `0x38` now lands
on a read-only counter and would silently measure "backpressure has no effect".

## Register map (AXI4-Lite aperture, base `0xA000_0000`)

| Region | Offset | Contents |
|---|---|---|
| CTRL  | `0x00_0000` | control/status registers (`mbv_soc_top.sv` plus the shared sink window) |
| ENC   | `0x01_0000` | CTTE encoder CSRs (via `ct_axil_to_wb` -> Wishbone) |
| RAM   | `0x10_0000` | program/data RAM (write while `core_run=0`) |
| TRACE | `0x20_0000` | captured ATB ring buffer (1 MiB URAM) |
| AXIS  | `0x30_0000` | captured AXIS instrumentation stream (`ct_soc_axis_buf`) |

CTRL register detail is documented in `mbv_soc_top.sv`'s header comment
(`@details`), which is the single source of truth for this example:

- `0x00`..`0x14` -- this top: `CONTROL`, `STATUS`, `TRACE_BEATS`,
  `TRACE_BYTES`, `AXIS_BEATS`, `TRACE_BUFSZ`
- `0x18`..`0x30` and `0x38` -- the shared sink window, decoded inside
  `ct_trace_sinks` and identical in every board design: `SINK_CTRL`,
  `DDR_BASE`, `DDR_SIZE`, `DDR_WPTR`, `SINK_STAT`, `DDR_DROPS`, `PIB_DROPS`,
  `DDR_BEATS`
- `0x34`, `0x3C`, `0x40` -- this example's own registers: `ATB_STALLS`,
  `IRQ_DIV`, `ATB_BP`. `0x34` is `ATB_STALLS` here, *not* the `FUNNEL_CTRL` of
  the multi-encoder tops: `mbv` has one encoder and no funnel

That header comment and the RTL decoders are checked against each other
mechanically -- see "Verification performed" below.

## Build (TCL flow)

This example's Vivado flow is still a plain TCL script, **not** yet this
repository's `abc` build driver. Converting each KV260 top to `abc` is a
deliberate later step with its own board gate -- no big-bang conversion.

```bash
# Project + RTL elaboration check only (no Vivado license consumed beyond
# an interactive/batch session; produces a synthesizable-project sanity
# check via `synth_design -rtl -top mbv_soc_top`):
vivado -mode batch -source examples/kv260/mbv/fpga/create_project_kv260.tcl

# Full synth -> impl -> bitstream:
MBV_KV260_SYNTH=1 vivado -mode batch -source examples/kv260/mbv/fpga/create_project_kv260.tcl
```

Environment overrides (all optional):
- `MBV_PROJ_DIR` -- alternate project directory (default: `fpga/proj/`),
  so a measurement build does not discard an existing reference project.
- `MBV_CTTE_DIR` -- build against a separate, pinned CTTE worktree
  instead of this repository's own `rtl/` (sets `MBV_CT_ENC_GOLD` for the
  gold-standard encoder variant, which lacks the `atb_te_raw` port and the
  `EN_ETRACE`/`CORE_XLEN` instance parameters).
- `MBV_USE_COMPRESSION=1` (read by `create_bd.tcl`) -- build the MicroBlaze-V
  core with the RVC extension, for the `rvc_test.S` raw-encoding measurement
  (`sw/README.md`).
- `MBV_NATIVE_TRACE=1` (read by `create_bd.tcl`) -- additionally bring out
  AMD's own native N-Trace port, for cross-validation against the CTTE
  path.

`vivado` itself must be on `PATH` (or invoked with its full path) -- no tool
path is hardcoded in these scripts.

## Running the bare-metal programs

The board gate [`board/mbv_board_gate.sh`](board/mbv_board_gate.sh) automates
the whole protocol end to end -- build the program, package the bitstream into
a Kria `fpga-manager` app, deploy it, load and run `trace_test` on the real
MicroBlaze-V core, capture the ring over `devmem`, decode it and compare the
decoded PC sequence against an oracle. It prints
`### MBV_BOARD_GATE PASS <n>/<n>`; [`../README.md`](../README.md) records the
2026-08-17 result `MBV_BOARD_GATE PASS 26772/26772` for this example. Its
options, its four evidence lines and what it deliberately does not do are
documented in [`board/README.md`](board/README.md).

(Until 2026-08-18 this section stated that the board/deploy tooling "was not
part of this migration's scope". That was true when the example was migrated
and stopped being true when `board/` landed the same day -- corrected here
rather than carried on as documentation drift.)

By hand -- and this is what the gate script does step by step -- the protocol
against the register map above is:

1. Build a program in [`sw/`](sw/) (`make` there produces `build/<prog>.bin`).
2. Hold the core (`CONTROL.core_run=0`), write the program image word-by-word
   into the RAM region starting at `0x10_0000`.
3. Configure the CTTE encoder over the ENC region (Wishbone via
   `ct_axil_to_wb`).
4. Start the core (`CONTROL.core_run=1`); optionally clear/flush the trace
   ring first (`CONTROL.trace_clear`/`trace_flush`).
5. Read `STATUS`, `TRACE_BEATS`, `TRACE_BYTES` and pull `TRACE_BEATS`
   32-bit words back from the TRACE region (ring order: index
   `TRACE_BEATS % (TRACE_BUFSZ/4)` is the oldest surviving beat once
   `STATUS.trace_wrapped` is set).
6. Decode the captured bytes with a CTTE decoder against the program's
   `.dump`/oracle (see `sw/README.md`).

## Verification performed

**Migration (2026-08-17):** `verilator --lint-only` elaboration of
`mbv_soc_top` together with its dependencies (the shared sinks from
`../common/` and `../common/tgc5b/rtl/`, and `mbv_soc_synth_wrap.sv`) and a
repository-wide duplicate-module-name check, both green. On the board,
`board/mbv_board_gate.sh` produced `MBV_BOARD_GATE PASS 26772/26772`
(recorded in [`../README.md`](../README.md)).

**Three-sink change (2026-08-18):** the same `verilator --lint-only -Wall
--timing --top-module mbv_soc_top` elaboration, now across the four sink files
(`ct_soc_trace_ring`, `ct_soc_ddr_sink`, `ct_soc_pib`, `ct_trace_sinks`):
0 real `%Error` -- the only `%Error` line is Verilator's aggregate `Exiting due
to N warning(s)`, this repository's known `-Wall` volume over the full encoder
closure. A warning-level diff against the pre-change top shows the change
*removes* one warning (the ring's empty `.stopped_o ()`, now internal to
`ct_trace_sinks`) and adds none. The header comment's register table was
compared to the RTL decoders *mechanically*, not by eye: one pass over the
`@details` block, `seg_of()`, both `case (a[wr]addr_q[6:2])` decoders and
`ct_trace_sinks`'s own `IX_*` window, mutation-tested to prove the check can
go red.

**Not executed:** the Vivado TCL flow itself (`fpga/`) -- project creation, the
`synth_design -rtl -top mbv_soc_top` elaboration gate, bitstream, board
deploy. No Vivado license/session was exercised for the migration or for the
three-sink change; both were reviewed path by path instead. Running the flow
end-to-end over the new sink ports (`m_axi_*` to `S_AXI_HP0_FPD`, `pib_*` to
the PMOD constraints) and re-running `board/mbv_board_gate.sh` against the
resulting bitstream is the open item for whoever picks this up next.
