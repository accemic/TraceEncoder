<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/rocket2 — dual-hart Rocket64 RV64 SMP Linux + 2x CTTE on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) demonstrator that traces a
TWO-hart, RV64IMAC Rocket-chip core (generat `Rocket64t2`, no FPU) booting
SMP Linux, with TWO independent CTTE instances merged into one stream by
a message-atomic funnel. Twin of [`../rocket_linux/`](../rocket_linux/) --
read that example's README first; this one only documents what differs.

Migrated 2026-08-17 from an internal predecessor repository; see
[`../README.md`](../README.md) for the conventions all KV260 examples
share.

## What differs from `rocket_linux`

1. **Generat `Rocket64t2`** (two harts + a per-hart `satp`-derived context
   sideband), not `Rocket64t1`. Same source pin, one additional patch layer
   -- see [`../third_party/ROCKET_PIN.md`](../third_party/ROCKET_PIN.md)
   "Rocket64t2" section.
2. **TWO CTTE encoder instances** (`enc0`/`enc1`), each with its own
   Wishbone CSR bridge and PS aperture window (`ENC0`/`ENC1`), merged by
   [`rtl/ct_L1_funnel.sv`](../../../rtl/ct_L1_funnel.sv) at the repo root
   (**not** re-pointed or copied -- that file is already the
   `MDO_WIDTH`-parametrized version this design needs, verified before
   migration: `grep MDO_WIDTH rtl/ct_L1_funnel.sv` shows it used as a real
   parameter, not the hardcoded-30 upstream default that would silently
   mis-parse this encoder's 4-byte-chunk-per-beat wire format -- see
   `rtl/rocket2_soc_synth_wrap.sv`'s header for the full finding).
3. **`EN_ETRACE` defaults to 0**, not 1: the funnel recognizes packet
   boundaries via the Nexus MSEO bits; an E-Trace backend delivers raw bytes
   without MSEO. `rocket2_soc_synth_wrap.sv` aborts elaboration (`$fatal`) if
   built with `EN_ETRACE=1`, rather than silently merging the two streams
   wrong.
4. **Golden reference and the board's observation channel are tracked per
   hart** (`core0_*`/`core1_*`, `PC0_*`/`PC1_*`/`RETIRES0`/`RETIRES1`) -- "the
   core is hung" is two independent questions with two harts, not one.
5. **`rocket_mem_window.sv` and `rocket_con_8250.sv` are cross-referenced**
   from [`../rocket_linux/rtl/`](../rocket_linux/rtl/), not duplicated --
   both blocks are hart-count-agnostic (one shared AXI4 memory port /
   console port for both harts) and this example is their second consumer.

## Layout

```
rtl/    rocket2_soc_top.sv         AXI4-Lite control-port top (CTRL/ENC0/ENC1/TRACE/CON regions)
        rocket2_soc_synth_wrap.sv  the Rocket64t2 generat + console + window guard + 2x adapter
                                   + 2x encoder + funnel (M4)
fpga/   rocket2_kv260_top.sv       bitstream top: Zynq PS + AXI plumbing around rocket2_soc_top
        run_rocket2_bitstream.tcl entry point: builds the Vivado project + bitstream (see "Build" below)
        synth_rocket2_ooc.tcl     out-of-context capacity/timing measurement (incl. place_design --
                                  the CLB row that answers "does it fit?", see the file's own header)
        rocket_synth_pre.tcl      TCL.PRE hook (single-threaded synth), own vendored copy
        gen_ip.tcl                the 4 standalone PS-glue IPs, own vendored copy
        abc_filelist.py           .abc dependency-graph resolver, own vendored copy
        rocket_pib_pmod.xdc       PIB parallel-trace-port pin constraints, own vendored copy
sw/     build_payload_rocket2_rv64.sh  OpenSBI fw_payload build + gates incl. the two-cpu-node gate
        rocket2_kv260_rv64.dts         devicetree with TWO cpu nodes (the actual hart-count switch)
        make_listing_rocket2_rv64.sh   merged decoder listing (OpenSBI + kernel phys + kernel virt40)
        m5_qemu_sanity_rocket2.sh      QEMU -smp 2 sanity boot, checks the SMP-specific boot strings
```

`rocket2_soc_top.sv`/`rocket2_soc_synth_wrap.sv` consume the same shared
sink RTL as `rocket_linux` (`../common/`, `../common/tgc5b/rtl/`), the
same already-migrated
[`rocket_tci_to_ctte_tip`](../../../rtl/adapters/rocket/rocket_tci_to_ctte_tip.sv)
adapter (instantiated twice, `shim0`/`shim1`), plus
`../rocket_linux/rtl/rocket_mem_window.sv` and
`../rocket_linux/rtl/rocket_con_8250.sv` cross-example (point 5 above) and
`../../../rtl/ct_L1_funnel.sv` (point 2 above).

## Register map (AXI4-Lite aperture, base `0xA000_0000`)

| Region | Offset | Contents |
|---|---|---|
| CTRL  | `0x00_0000` | control/status registers, per-hart PC/RETIRES, FUNNEL_CTRL (`rtl/rocket2_soc_top.sv`) |
| ENC0  | `0x01_0000` | CTTE encoder CSRs, hart 0 |
| ENC1  | `0x02_0000` | CTTE encoder CSRs, hart 1 |
| TRACE | `0x20_0000` | merged ATB ring buffer (1 MiB URAM, funnel output) |
| CON   | `0x30_0000` | console ring (word read accesses) |

`0x00..0x54` of CTRL are register-identical to `rocket_linux`'s CTRL map so
existing board scripts keep working; `0x58 FUNNEL_CTRL` and the `PC1_*`/
`RETIRES1` registers are new. Full detail in `rtl/rocket2_soc_top.sv`'s
header comment.

## Build (TCL flow)

```bash
# Default: pinned CT_XLEN=64 + CT_CONTEXT_WIDTH=22 encoder mirror.
# NOT FUNCTIONAL TODAY -- see "Open items" below.
vivado -mode batch -notrace -source examples/kv260/rocket2/fpga/run_rocket2_bitstream.tcl

# Pinned to an explicit encoder tree (must carry CT_XLEN=64, CT_CONTEXT_WIDTH=22):
vivado -mode batch -notrace -source examples/kv260/rocket2/fpga/run_rocket2_bitstream.tcl -tclargs <path>

# Out-of-context capacity/timing measurement (incl. place_design, ~20-40 min):
vivado -mode batch -notrace -source examples/kv260/rocket2/fpga/synth_rocket2_ooc.tcl -tclargs slim2
```

Unlike `rocket_linux`, `EN_ETRACE` is not a tclarg here -- it is fixed at 0
in the script (the funnel/MSEO constraint, point 3 above). Timing is a
build GATE in `run_rocket2_bitstream.tcl` (a negative WNS/WHS exits 5,
unlike the one-hart flow which only prints the numbers) -- see the script's
own header for why.

## Running it on the board

This example has no `board/` directory. Its board recipe lives with the
dashboard, because that is what drives it:
[`../../dashboard/boot/rocket2_linux_run.sh`](../../dashboard/boot/rocket2_linux_run.sh),
invoked in the phases `prep` / `start` / `live` via
[`../../dashboard/boot.json`](../../dashboard/boot.json). Run by hand:

```sh
sudo PHASE=prep  PL_MHZ=68 bash rocket2_linux_run.sh
sudo PHASE=start PL_MHZ=68 bash rocket2_linux_run.sh
sudo PHASE=live  PL_MHZ=68 bash rocket2_linux_run.sh
```

It needs `phys_io.py` at `/tmp/phys_io.py` and the payload at
`/tmp/fw_payload_rocket2.bin`. **Stop `ctrace-dashboard.service` before any
`xmutil unloadapp`** (see
[`../SPEC_board_memory_map.md`](../SPEC_board_memory_map.md) §3).

Measured 2026-08-21 on a KV260: payload 34 678 856 B byte-identical on
read-back, the cold-boot arbiter clean before and after the load,
**`M5_TWOHART_HW PASS`** -- hart 0 +25 087 923 and hart 1 +34 975 513
instructions in one second, both PCs virtual -- guest boots to
`buildroot login:`, DDR sink 27 452 136 bytes with 0 drops and
`WIN_ERR_CNT 0`, and the first 4 MiB of that sink decode to
**7 770 406 instructions**.

## Open items

All of `rocket_linux`'s open items apply here too (RocketSystem/rocket64t2
generat not vendored -- see
[`../third_party/ROCKET_PIN.md`](../third_party/ROCKET_PIN.md);
`tools/abc_filelist.py`
promotion overdue -- this is the THIRD vendored copy, after `mbv` and
`rocket_linux`; `rocket_pib_pmod.xdc` deliberately duplicated rather than
cross-referenced into `duo`; Vivado flow not executed end-to-end). The
`extract_tlrom.py` item on that list is **closed** since 2026-08-18
(`facf54cfbd`): the tool lives at
[`../common/tools/extract_tlrom.py`](../common/tools/extract_tlrom.py) and
both TCL call sites here (`run_rocket2_bitstream.tcl`,
`synth_rocket2_ooc.tcl`) point there. In addition:

- **The default encoder-tree path (`bld/m4_rocket_2hart/ctte_slim64`) is
  functional again since 2026-08-18** — this item is **closed**. The
  workflow that produces it was ported from the predecessor repository's
  `sim/rocket/mk_ctte_m4.ps1` to
  [`../common/tools/mk_encoder_mirror.sh`](../common/tools/mk_encoder_mirror.sh).
  Build the mirror once before the first bitstream run (seconds; re-running
  is a no-op unless the tree moved):

  ```bash
  bash examples/kv260/common/tools/mk_encoder_mirror.sh \
       --dest bld/m4_rocket_2hart/ctte_slim64 \
       --profile slimfull_gold --xlen 64 --ctx-width 22
  ```

  Both `CT_XLEN=64` and `CT_CONTEXT_WIDTH=22` are mandatory here, not a
  preference: `rocket2_soc_synth_wrap.sv:462,472` passes `.CORE_XLEN(64)`,
  and since P0-07 (`1415a02524`) `ct_encoder` refuses a mismatch during
  elaboration. An explicit `<ctte-root>` tclarg still overrides the
  default.
- **The funnel path was dangling and is fixed (2026-08-18).** Both TCL
  entry points here asked for `third_party/CTTE/rtl/ct_L1_funnel.sv`,
  the predecessor repository's vendor copy of the encoder — a path that does not exist in
  this repository, because *this* repository is the encoder. They now use
  the repo-root `rtl/ct_L1_funnel.sv`, exactly as
  [`../cva6_2/README.md`](../cva6_2/README.md) had flagged.
- **`sw/build_payload_rocket2_rv64.sh` shares `rocket_linux`'s Buildroot
  dependency** on the `cva6_linux` example's output tree (`$L1_OUT`) --
  build `cva6_linux`'s Linux payload first (same note, confirmed against
  the script's own `L1_OUT`/`kimg` defaults, which are byte-identical to
  `rocket_linux`'s).
- **`rocket_synth_pre.tcl`/`gen_ip.tcl`/`abc_filelist.py`/
  `rocket_pib_pmod.xdc` are vendored as this example's own copies**, not
  cross-referenced from `../rocket_linux/fpga/`, even though their content
  is byte-identical -- same reasoning as `gen_ip.tcl`/`abc_filelist.py`
  already being vendored per-example rather than shared (small,
  self-contained build-flow files; no cross-example TCL dependency
  introduced for them). `rocket_mem_window.sv`/`rocket_con_8250.sv`
  (real RTL, not build-flow tooling) are the ones actually cross-referenced,
  per point 5 above.

## Verification performed during migration

`verilator --lint-only` elaboration of `rocket2_soc_top` together with its
full dependency closure (the same 74-file CTTE encoder closure as
`rocket_linux`; the already-migrated Rocket adapter, instantiated twice;
`../rocket_linux/rtl/`'s cross-referenced `rocket_mem_window.sv`/
`rocket_con_8250.sv`; the repo-root `ct_L1_funnel.sv`; the shared/common
sink RTL; and the same scratch, uncommitted `RocketSystem` stub used for
`rocket_linux`, extended with the two-hart-only ports) and a repository-wide
duplicate-module-name check, both green.
The Vivado TCL flow itself (`fpga/`) was adapted by careful path/reference
review, not executed.
