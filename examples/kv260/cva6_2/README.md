<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/cva6_2 — dual-core CVA6 AMP + 2x CTTE on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) demonstrator that traces TWO
independent CVA6 cores (AMP, not SMP -- the cores are incoherent, see
`rtl/cva6_2_soc_top.sv`'s header for the full rationale) booting two guest
Linux images, with TWO independent CTTE instances merged into one
stream by a message-atomic funnel. RV32 OR RV64 from the SAME source files
-- the CVA6 configuration in the build's file list decides which, and
register map/segments/memory layout are identical either way (a
demonstrator must not tell two different stories depending on the
visitor).

Migrated 2026-08-17 from an internal predecessor repository; see
[`../README.md`](../README.md) for the conventions all KV260 examples
share.

## Architecture in one paragraph

Each core gets its own AXI4 master, own cached PS DDR window, and own PS
port (`S_AXI_HP1_FPD`/`S_AXI_HP2_FPD`); the only thing shared between them
is an **uncached** 16 MiB mailbox window on a fourth PS port
(`S_AXI_HP3_FPD`), reached through ONE shared atomics instance (so LR/SC
cross-core reservation-table clearing works) behind a two-step
ID-narrowing merge. See `rtl/cva6_2_mem_xbar.sv`'s header for the complete
topology diagram and the reasoning behind every one of those design
choices -- it is deliberately written as the single place that topology is
fully described, so a reviewer does not have to hold three files against
each other.

## Layout

```
rtl/    cva6_2_soc_top.sv          AXI4-Lite control-port top (CTRL/ENC0/ENC1/TRACE/CON + per-core observation)
        cva6_2_soc_synth_wrap.sv   2x cva6_trace_wrap + 2x ITI shim + 2x ct_encoder + ct_L1_funnel
        cva6_2_periph.sv           two-hart CLINT (per-hart msip/mtimecmp, shared mtime) + 8250 console
        cva6_2_mem_xbar.sv         private-per-core + one-shared-atomics memory topology (see above)
fpga/   cva6_2_kv260_top.sv           bitstream top: FOUR-port ct_soc_kv260_ps4 (see gen_ip_ps4.tcl)
        run_cva6_2_bitstream.tcl      entry point: ONE script builds either RV32 or RV64 (tclarg 1)
        gen_ip_ps4.tcl                additive four-slave-port PS instance (HP0 trace, HP1/HP2 cores, HP3 mailbox)
        synth_cva6_2_ooc.tcl          D2: lower-bound OOC capacity measurement (2 cores + 2 encoders + funnel only)
        synth_cva6_2_soc_ooc.tcl      D3: full-build OOC capacity measurement (adds xbar/periph/sinks)
        gen_ip.tcl / abc_filelist.py / cva6_filelist.py / cva6_pib_pmod.xdc / rocket_synth_pre.tcl /
        cva6_linux64_board_cfg.tcl    own vendored copies (see "Cross-references" below)
sw/     cva6_2_kv260_core0.dts / cva6_2_kv260_core1.dts   guest device trees, one per core (see sw/README.md)
```

## Cross-references (not duplicated)

- **`ct_L1_funnel.sv`** at the repository root
  (`../../../rtl/ct_L1_funnel.sv`) -- already the correct
  `MDO_WIDTH`-parametrized version this design needs (verified before use:
  `grep MDO_WIDTH rtl/ct_L1_funnel.sv` shows a real parameter, not a
  hardcoded default that would silently mis-parse this encoder's
  four-byte-chunk-per-beat wire format). This was a **deliberate deviation
  from
  [`../rocket2/fpga/run_rocket2_bitstream.tcl`](../rocket2/fpga/run_rocket2_bitstream.tcl)'s
  own migrated funnel path**, which pointed at a non-existent
  `third_party/CTTE/rtl/ct_L1_funnel.sv` left over from the source
  repository's layout (that path does not exist anywhere in this
  repository) -- flagged here rather than silently copying a stale
  reference forward. `rocket2` was corrected to the same repo-root file on
  2026-08-18, so the two flows now agree.
- **`rocket_mem_window.sv`** from
  [`../rocket_linux/rtl/`](../rocket_linux/rtl/) -- instantiated THREE
  times in `cva6_2_mem_xbar.sv` (guarding core 0's private window, core
  1's private window, and the shared mailbox window). Verified present
  before starting this package (`rocket_linux` was migrated by a
  concurrent worker just before this session began); this is its **third**
  consumer after `rocket_linux` and `rocket2`.
- **`ct_axil_to_wb.sv`** from [`../common/tgc5b/rtl/`](../common/tgc5b/rtl/),
  **`ct_soc_trace_ring.sv`/`ct_soc_ddr_sink.sv`/`ct_soc_pib.sv`** from
  [`../common/`](../common/) -- same shared-sink pattern every KV260
  example uses.
- **`rtl/adapters/cva6/`** (`cva6_trace_wrap.sv`, `cva6_iti_to_ctte_tip.sv`)
  at the repo root, unchanged, instantiated twice (`core0`/`core1`).

## Register map (AXI4-Lite aperture, base `0xA000_0000`)

| Region | Offset | Contents |
|---|---|---|
| CTRL  | `0x00_0000` | control/status, per-core PC/RETIRES, per-core window guards, FUNNEL_CTRL |
| ENC0  | `0x01_0000` | CTTE encoder CSRs, core 0 |
| ENC1  | `0x02_0000` | CTTE encoder CSRs, core 1 |
| TRACE | `0x20_0000` | merged ATB ring buffer (1 MiB URAM, funnel output) |
| CON   | `0x30_0000` | console ring (shared, word read accesses) |

`0x00..0x44` and `0x4C..0x64` of CTRL are register-identical to
`rocket2_soc_top`'s CTRL map (same board scripts/dashboard keep working);
`0x68..0x74` (core-1 window guard + mailbox guard) are new here because
this design has two separate private windows where rocket2's single
shared-memory generat needed only one guard. Full detail in
`rtl/cva6_2_soc_top.sv`'s header comment.

## Board memory map

Core view (identical for both cores): `0x0200_0000` CLINT (two-hart),
`0x1000_0000` UART, `0x6400_0000` +32 MiB private cached RAM,
`0x6800_0000` +16 MiB shared uncached mailbox. PS side: core 0's window
translates to `0x6400_0000`, core 1's to `0x6600_0000`, the mailbox stays
at `0x6800_0000` for both (identical translation -- the same PS byte,
uncached from both sides).

## Guest software

Two independent guest images (one per core), each built from the same
Buildroot/toolchain machinery as [`../cva6_linux64/`](../cva6_linux64/)'s
RV64 payload (or [`../cva6_linux/`](../cva6_linux/)'s RV32 payload, for the
RV32 build variant), just with this directory's own `.dts` substituted.
**No dedicated two-core payload-build script exists** -- see
[`sw/README.md`](sw/README.md) for the exact manual procedure (the
existing `build_payload_rv64.sh` hardcodes its DTS input filename and was
not extended with an override in this migration, to avoid inventing
build-flow tooling outside this migration's RTL/TCL scope).

## Build (TCL flow)

```bash
# RV64 (default), this repository's own encoder tree:
vivado -mode batch -notrace -source examples/kv260/cva6_2/fpga/run_cva6_2_bitstream.tcl

# RV32 comparison build:
vivado -mode batch -notrace -source examples/kv260/cva6_2/fpga/run_cva6_2_bitstream.tcl -tclargs cv32a6_ima_sv32_fpga

# D2 lower-bound capacity measurement (2 cores + 2 encoders + funnel, no xbar/periph/sinks):
vivado -mode batch -notrace -source examples/kv260/cva6_2/fpga/synth_cva6_2_ooc.tcl -tclargs slim2

# D3 full-build capacity measurement:
vivado -mode batch -notrace -source examples/kv260/cva6_2/fpga/synth_cva6_2_soc_ooc.tcl -tclargs soc_rv64
```

`EN_ETRACE` is fixed at 0 in every entry point here (not a tclarg): the
funnel recognizes packet boundaries via the Nexus MSEO bits, which an
E-Trace backend does not emit.

## Open items

All of `cva6_linux`/`cva6_linux64`'s open items apply here too
(CVA6-with-ITI reference core not vendored; Vivado flow not executed
end-to-end; board deploy tooling out of scope; `tools/abc_filelist.py`/
`cva6_filelist.py` promotion overdue -- this is the sixth and fourth
vendored copy respectively). In addition:

- **The default encoder trees are functional again since 2026-08-18** --
  this item is **closed**, and there are now TWO of them, one per variant:
  `bld/d3_cva6_2_soc/ctte_slim32` for the RV32 build and
  `bld/m4_rocket_2hart/ctte_slim64` for the RV64 one (the latter shared with
  [`../rocket2/`](../rocket2/)). Build them with
  [`../common/tools/mk_encoder_mirror.sh`](../common/tools/mk_encoder_mirror.sh),
  the Bash port of the measurement workflow that had not been migrated:

  ```bash
  bash examples/kv260/common/tools/mk_encoder_mirror.sh \
       --dest bld/d3_cva6_2_soc/ctte_slim32 \
       --profile slimfull_gold --xlen 32 --ctx-width 22     # RV32 build
  bash examples/kv260/common/tools/mk_encoder_mirror.sh \
       --dest bld/m4_rocket_2hart/ctte_slim64 \
       --profile slimfull_gold --xlen 64 --ctx-width 22     # RV64 build
  ```

  One tree per variant and not one shared 64-bit tree: `rtl/cva6_2_soc_synth_wrap.sv`
  passes `.CORE_XLEN(Cfg.XLEN)`, and since P0-07 (`1415a02524`, 2026-08-12)
  `ct_encoder` refuses a core/encoder width mismatch during elaboration
  instead of truncating addresses silently. The script's own header claim
  that "both are correct" for the RV32 build predates that guard and was
  corrected with it.
- **`ct_L1_funnel.sv` cross-reference: `rocket2` now agrees.** The
  divergence flagged under "Cross-references" above was fixed on 2026-08-18;
  both examples take the repo-root `rtl/ct_L1_funnel.sv`.
- **`gen_ip.tcl` in this directory creates an unused `ct_soc_kv260_ps`
  (two-port) IP alongside the actually-used four-port
  `ct_soc_kv260_ps4`** (from `gen_ip_ps4.tcl`) -- verified this matches the
  source repository's own behavior (both files are sourced the same way
  there too, and `generate_target`'s `ct_soc_kv260_*` wildcard picks up
  both regardless); not trimmed during migration, see `fpga/gen_ip.tcl`'s
  own header for the full disclosure.
- **No dedicated two-core payload-build script** -- see `sw/README.md`.
- **`verilator --lint-only` could not fully elaborate
  `cva6_2_soc_synth_wrap`** in this environment -- see "Verification
  performed during migration" below for the exact, reproducible finding
  (a Verilator 5.040 internal crash, not a design defect) and what WAS
  achieved instead.

## Verification performed during migration

**Duplicate-module-name check:** all four module names this example
introduces (`cva6_2_soc_top`, `cva6_2_periph`, `cva6_2_mem_xbar`,
`cva6_2_soc_synth_wrap`, `cva6_2_kv260_top` -- five, not four) verified
individually to appear exactly once repo-wide (289 `.sv` files); this
example introduces **no new duplicates**.

**`verilator --lint-only` (5.040):**

1. **`cva6_2_periph.sv` standalone** (self-contained, no external type
   dependencies): **0 `%Error`**, 6 benign `UNUSEDSIGNAL` warnings (same
   classes as the sibling periph modules).
2. **`cva6_2_soc_synth_wrap`, full attempt, did NOT complete.** With the
   same two-instance-of-`cva6_trace_wrap`-plus-`ct_L1_funnel` closure that
   elaborates cleanly for `rocket2`/`duo`/`trio` at their (superset,
   SoC-top-level) scope, this narrower "lower bound" top hit a
   **reproducible Verilator 5.040 internal crash**:
   `%Error: Internal Error: rtl/pkg/ct_cs_cpuif.sv:<line>: ../V3AstNodeExpr.h:2232: Unexpected Call`,
   triggered only when `--timing` is combined with elaborating the CTTE
   encoder's `ct_cs_cpuif.sv` TWICE within one compilation unit (i.e., once
   per `enc0`/`enc1` instance) for this specific narrower file
   composition. Investigated methodically before giving up on it:
   - Reproduced identically 3 times (same crash class, different exact
     line number each run -- `2083`, then `2341` on immediate retry --
     consistent with an internal AST-processing-order-dependent bug, not a
     one-off fluke).
   - Isolated to `--timing`: removing it avoids the crash but then fails
     with the SAME 2 expected `NOTIMING` errors on `rtl/external/amba/atb_pkg.sv`
     mbv's migration already documented as a pre-existing repository
     characteristic requiring `--timing` -- so `--timing` cannot be
     dropped.
   - Isolated to `-Wall`: removing it crashes even harder (no internal-error
     message at all, raw process termination), ruling out "a specific
     -Wall-only check trips it" as the sole cause.
   - `rocket2` (same dual-encoder-instance-behind-a-funnel architecture)
     achieves 0 `%Error` when linting its full `rocket2_soc_top` (a
     superset of files) -- this strongly suggests the crash is sensitive
     to this exact narrower file list/composition rather than being
     fundamental to instantiating `ct_encoder` twice per se, but the full
     `cva6_2_soc_top` scope needed to test that theory directly is itself
     blocked by the un-vendored PULP infrastructure (see below), so it
     could not be confirmed either way within this migration's scope.
   - **Conclusion:** disclosed as an investigated, reproducible Verilator
     tool limitation in this environment, not a defect in the migrated
     RTL (the same architecture lints cleanly in the sibling
     `rocket2`/`duo`/`trio` migrations) and not something this migration's
     scope extends to fixing (a Verilator bug report, not an RTL change).
3. **`cva6_2_mem_xbar.sv` and the full `cva6_2_soc_top`/`cva6_2_kv260_top`
   closure were not elaborated** -- blocked by the same un-vendored PULP
   `AXI_BUS` infrastructure documented in `../cva6_linux/README.md`'s
   "Open items" (this example's `cva6_2_mem_xbar.sv` uses the interface
   even more heavily than `cva6_linux_mem_xbar.sv`: `axi_id_serialize_intf`,
   `axi_mux_intf` and `axi_err_slv`-pattern code in addition to
   `axi_demux_intf`/`axi_riscv_atomics_wrap`/`axi_to_axi_lite_intf`).

**No built binaries under `sw/`**: verified as part of the combined check
across all three examples, see `../cva6_linux/README.md`.

**Not exercised: the Vivado TCL flow itself.**
