<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/cva6_linux — RV32 CVA6 Linux + CTTE on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) demonstrator that traces a
single RV32IMA CVA6 core (config `cv32a6_ima_sv32_fpga`, no C extension)
booting Linux, with CTTE. The Zynq UltraScale+ PS drives the whole SoC
via `devmem` reads/writes at a single AXI4-Lite aperture (`0xA000_0000`);
the PL holds the CVA6 core, an atomics/address-demux crossbar, a minimal
CLINT+8250 peripheral, the [`rtl/adapters/cva6/`](../../../rtl/adapters/cva6/)
`cva6_trace_wrap`/`cva6_iti_to_ctte_tip` chain, a CTTE encoder
instance, and three trace sinks (on-chip capture ring, linear DDR sink,
optional parallel PIB port).

Migrated 2026-08-17 from an internal predecessor repository; see
[`../README.md`](../README.md) for the conventions all KV260 examples
share.

## Layout

```
rtl/    cva6_linux_soc_top.sv     AXI4-Lite control-port top (CTRL/ENC/TRACE/CON regions)
        cva6_soc_synth_wrap.sv    CVA6 (cv32a6_ima_sv32_fpga) + RVFI + ITI + shim + ct_encoder
        cva6_linux_mem_xbar.sv    atomics resolution + address demux (DRAM vs. peripherals)
                                  (shared: also used by ../cva6_linux64/, RISCV_WORD_WIDTH parametric)
        cva6_linux_periph.sv      CLINT + 8250 console (ring, PS-readable)
fpga/   cva6_linux_kv260_top.sv   bitstream top: Zynq PS + AXI plumbing around cva6_linux_soc_top
        run_cva6_linux_bitstream.tcl  entry point: builds the Vivado project + bitstream (see "Build")
        synth_cva6_cfg_ooc.tcl    standalone OOC capacity measurement of one CVA6 branch (not
                                  sourced by the bitstream flow -- a separate measurement tool)
        gen_ip.tcl                the 4 standalone PS-glue IPs (PS, reset sync, AXI DWC, AXI4-to-Lite)
        abc_filelist.py           resolves the CTTE encoder's .abc dependency graph into a file list
        cva6_filelist.py          resolves the vendored CVA6 core's Flist.cva6 manifest into a file list
        cva6_pib_pmod.xdc         PIB parallel-trace-port pin constraints (KV260 PMOD J2)
sw/     Config.in/external.desc/external.mk  BR2_EXTERNAL marker files (shared with ../cva6_linux64/)
        cva6.config / cva6_kv260.dts / cva6_kv260_defconfig / build_payload.sh / make_listing.sh /
        check_images.sh           RV32 Buildroot/Linux payload build (see sw/README.md)
```

`cva6_linux_soc_top.sv`/`cva6_soc_synth_wrap.sv` consume the shared sink
RTL from [`../common/`](../common/) (`ct_soc_trace_ring`) and from
[`../common/tgc5b/rtl/`](../common/tgc5b/rtl/) (`ct_axil_to_wb`) rather
than duplicating them, and the already-migrated
[`rtl/adapters/cva6/`](../../../rtl/adapters/cva6/) chain
(`cva6_trace_wrap`, `cva6_iti_to_ctte_tip`) unchanged at its existing
repo-root location. `cva6_linux_mem_xbar.sv` is width-parametric
(`RISCV_WORD_WIDTH`) and cross-referenced unchanged by
[`../cva6_linux64/`](../cva6_linux64/)'s RV64 build (default 32 = this
example's RV32 state).

**Cross-worker dependency (open item for the coordinator, see below):**
`cva6_soc_synth_wrap.sv` is the SoC branch this repository's `trio`
example (migrated concurrently by a different worker) also needs and, per
an internal predecessor repository (instance name
`soc2`), actually instantiates. `trio` should reference
`../cva6_linux/rtl/cva6_soc_synth_wrap.sv` rather than duplicate it -- the
same cross-example pattern `duo`/`trio` already use for
`mbv_soc_synth_wrap.sv`/`ct_soc_synth_wrap.sv`. **This did not happen**:
`trio` (already landed before this migration ran) vendored its own copy at
`examples/kv260/trio/rtl/cva6_soc_synth_wrap.sv` -- itself, with a header
comment explicitly anticipating and flagging this exact collision. This
example's own copy could not be
un-created without leaving `cva6_linux_soc_top.sv` without its SoC branch,
so it stands as written; the collision was a coordinator-level cross-worker
resolution, not something either worker could fix unilaterally.

**Resolved since (verified 2026-08-18):** `trio` dropped its copy and now
references this one. Measured, not assumed: `examples/kv260/trio/rtl/`
holds only `trio_soc_top.sv` and `tgc5b_dual_synth_wrap.sv`;
`examples/kv260/trio/fpga/create_project_kv260.tcl:155` adds
`[file join $script_dir .. .. cva6_linux rtl cva6_soc_synth_wrap.sv]`; and a
repository-wide search finds exactly one `module cva6_soc_synth_wrap`
declaration, `rtl/cva6_soc_synth_wrap.sv:26` in this example. The paragraph
above is kept as the historical record of how it got there.

## Register map (AXI4-Lite aperture, base `0xA000_0000`)

| Region | Offset | Contents |
|---|---|---|
| CTRL  | `0x00_0000` | control/status registers (`cva6_linux_soc_top.sv`) |
| ENC   | `0x01_0000` | CTTE encoder CSRs (via `ct_axil_to_wb` -> Wishbone) |
| TRACE | `0x20_0000` | captured ATB ring buffer (1 MiB URAM) |
| CON   | `0x30_0000` | console ring (word read accesses) |

CTRL register detail (CONTROL/STATUS/TRACE_x/SINK_x/DDR_x/CON_x) is
documented in `rtl/cva6_linux_soc_top.sv`'s header comment (`@details`).

## Board memory map

Core view (fixed in `cva6_soc_synth_wrap.sv`/`cva6_linux_mem_xbar.sv`):
`0x0200_0000` CLINT, `0x1000_0000` UART (8250), `0x6400_0000` +192 MiB
guest RAM (`BOOT_ADDR`/`DRAM_SIZE`, PS DDR window via the atomics/demux
crossbar and the PS `S_AXI_HP1_FPD` port). Trace-sink window
`0x6000_0000` +64 MiB sits outside the guest's DRAM window and is
unreachable from the guest (see `cva6_linux_mem_xbar.sv`'s header for the
2026-07-27 board finding that made this boundary mandatory, not optional).

## Build (TCL flow)

Like `examples/kv260/mbv/` and `examples/kv260/rocket_linux/`, this
example's Vivado flow is still a plain TCL script, not yet this
repository's `abc` build driver.

```bash
vivado -mode batch -notrace -source examples/kv260/cva6_linux/fpga/run_cva6_linux_bitstream.tcl

# Standalone OOC capacity measurement of one CVA6 branch (Gate L0, not part
# of the bitstream flow):
vivado -mode batch -notrace -source examples/kv260/cva6_linux/fpga/synth_cva6_cfg_ooc.tcl \
       -tclargs cv32a6_ima_sv32_fpga
```

`vivado` and `py` (Python 3) must be on `PATH`.

## Open items

- ~~`cva6_soc_synth_wrap.sv` duplicate-module-name collision with `trio`~~
  **-- closed 2026-08-18** exactly as predicted: `trio` dropped its own copy
  and cross-references this one, matching the `mbv` precedent.
  See the "Resolved since" note above for the measurement that shows it.
- **CVA6-with-ITI reference core is not vendored** -- see
  [`../third_party/CVA6_PIN.md`](../third_party/CVA6_PIN.md) and
  [`../third_party/fetch.sh`](../third_party/fetch.sh).
- **Full SoC-top `verilator --lint-only` elaboration could not be run** for
  `cva6_linux_soc_top`/`cva6_linux_kv260_top`: beyond the un-vendored CVA6
  core itself, `cva6_linux_mem_xbar.sv` additionally needs PULP's
  interface-typed AXI infrastructure (`AXI_BUS`/`AXI_LITE` SystemVerilog
  interfaces, `axi_demux_intf`, `axi_riscv_atomics_wrap`,
  `axi_to_axi_lite_intf`, plus several `common_cells` modules), which is
  **not vendored anywhere in this repository** (verified by repository-wide
  grep) -- a materially different and larger gap than the single-leaf-module
  stubs that sufficed for the `mbv`/`rocket_linux`/`rocket2` migrations,
  because none of those designs use PULP's interface-typed `AXI_BUS` (the
  Rocket examples use flat AXI ports throughout; MicroBlaze-V needs no PULP
  atomics at all). Per `third_party/CVA6_PIN.md`'s "Included subset", this
  PULP infrastructure is bundled inside the same un-vendored `cva6_ref`
  checkout (`vendor/pulp-platform/*`) -- fetching `cva6_ref` resolves both
  gaps at once. See "Verification performed during migration" below for
  what WAS actually elaborated (the SoC branch `cva6_soc_synth_wrap.sv`,
  with a throwaway stub for the reference core, and the standalone
  `cva6_linux_periph.sv`).
- **The Vivado TCL flow was not executed end-to-end** (no Vivado
  license/session was invoked); adapted by careful path/reference review.
- **Board deploy tooling has landed since:** [`board/`](board/) holds
  `cva6_linux_boot_trace.sh` (load payload, boot the guest, capture and
  decode), the shared packaging/loader parts are in
  [`../common/board/`](../common/board/). See
  [`board/README.md`](board/README.md). Board verdict on record: 2026-08-18,
  `cva6_linux` boots and decodes `Decoded OK (4 619 090 instructions)` with
  0 errors — as listed in [`../README.md`](../README.md).

## Verification performed during migration

**Duplicate-module-name check:** 289 `.sv` files repo-wide; only the
pre-existing `fifo2clk_fwft` pair and the `cva6_soc_synth_wrap` cross-worker
collision documented above (every module name this migration introduces --
`cva6_linux_soc_top`, `cva6_linux_periph`, `cva6_linux_mem_xbar`,
`cva6_linux_kv260_top` -- verified individually to appear exactly once).

**`verilator --lint-only` (5.040), two scopes**, since the full SoC-top
closure is blocked by the un-vendored PULP infrastructure (see above):

1. `cva6_soc_synth_wrap` (the CVA6 SoC branch: core + RVFI + ITI + shim +
   ct_encoder) with the CTTE encoder's full 74-file `.abc` closure
   (resolved with this example's own vendored `abc_filelist.py`) + the
   already-migrated adapter files
   (`rtl/adapters/cva6/cva6_riscv_itype_refine.sv`/`cva6_iti_to_ctte_tip.sv`)
   + a throwaway, port-compatible stub for the un-vendored
   `cva6_trace_wrap` (concrete RV32 widths taken from this file's own
   connections -- `AxiIdWidth=4`, `AxiAddrWidth=64`, `VLEN=XLEN=32` --
   same technique the `trio` example uses; written to a scratch file,
   not committed). Command:
   ```
   verilator --lint-only -Wall --timing --top-module cva6_soc_synth_wrap -f <ordered file list>
   ```
   **Result: 0 `%Error`** (only the "Exiting due to 1218 warning(s)"
   exit-limit summary line -- same characteristic mbv/rocket_linux/rocket2
   already documented: `-Wall` across the full encoder closure exceeds
   verilator's default warning budget, not itself a failure). Of the 9
   warnings inside `cva6_soc_synth_wrap.sv` itself: 7 `PINCONNECTEMPTY` on
   the unconnected RVFI golden-reference outputs (present, unconnected, in
   the unmodified source too -- RVFI is a debug/formal-verification
   interface this SoC branch does not use), 1 `PINMISSING` on
   `satp_asid_o` (also present in the unmodified source -- the port was
   added to `cva6_trace_wrap` after this instantiation was last touched
   there), 1 `SYNCASYNCNET` on `rst` (pre-existing repo characteristic in
   `rtl/external/common/vector_cdc2.sv` vs. `rtl/pkg/ct_cs_cpuif_wb.sv`,
   unrelated to this migration). 1 `MODDUP` for `fifo1clk_fwft.sv`, traced
   to `abc_filelist.py`'s own dependency-graph resolution listing the same
   file via two textually different (unnormalized `..`-relative) paths --
   a pre-existing characteristic of the shared, unmodified script, not
   introduced by this migration (confirmed: the same script is used
   byte-identically by `mbv`/`rocket_linux`/`rocket2`/`cva6_linux64`/`cva6_2`).
2. `cva6_linux_periph.sv` standalone (self-contained, flat-port module,
   no external type dependencies):
   ```
   verilator --lint-only -Wall --timing --top-module cva6_linux_periph examples/kv260/cva6_linux/rtl/cva6_linux_periph.sv
   ```
   **Result: 0 `%Error`**, 4 benign `UNUSEDSIGNAL` warnings (unused address
   decode slack bits, an unread `araddr_q` when the module is linted in
   isolation without its enclosing top, and the write-only `fcr_q` -- all
   consistent with the source's own intentional design, not migration
   defects).

`cva6_linux_mem_xbar.sv` and the full `cva6_linux_soc_top`/
`cva6_linux_kv260_top` closure were **not** elaborated -- blocked by the
un-vendored PULP AXI infrastructure (see "Open items" above).

**`sw/` build**: not exercised (no Linux build host with the pinned
Buildroot toolchain download cache was available in this session); see
`sw/README.md`'s own disclosure.

**No built binaries under `sw/`**: verified explicitly across all three
migrated examples' `sw/` trees (`find` + `file`(1) type check) -- all
entries are text sources (`.sh`, `.dts`, `.config`, `.md`, BR2_EXTERNAL
marker files), no `.bin`/`.elf`/`.img` artifacts.

**Not exercised: the Vivado TCL flow itself** -- same disclosure as every
sibling KV260 example migration to date.
