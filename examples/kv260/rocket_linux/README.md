<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/rocket_linux — Rocket64 RV64 Linux + CTTE on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) demonstrator that traces a
one-hart, RV64IMAC Rocket-chip core (generat `Rocket64t1`, no FPU) booting
Linux, with CTTE. The Zynq UltraScale+ PS drives the whole SoC via
`devmem` reads/writes at a single AXI4-Lite aperture (`0xA000_0000`); the PL
holds the Rocket generat (CLINT + PLIC + bootrom are inside it), a
synthesizable 8250 console, an address-window guard translating the
generat's fixed `0x8000_0000` guest view onto the reserved PS DDR window,
the [`rtl/adapters/rocket/`](../../../rtl/adapters/rocket/)
`TraceCoreInterface`-to-TIP adapter, a CTTE encoder instance, and three
trace sinks (on-chip capture ring, linear DDR sink, optional parallel PIB
port).

Migrated 2026-08-17 from an internal predecessor repository; see
[`../README.md`](../README.md) for the conventions all KV260 examples
share.

## Layout

```
rtl/    rocket_soc_top.sv         AXI4-Lite control-port top (CTRL/ENC/TRACE/CON regions)
        rocket_soc_synth_wrap.sv  the Rocket64t1 generat + console + window guard + adapter + encoder (L4)
        rocket_mem_window.sv      guest 0x8000_0000 -> PS DDR 0x6400_0000 address translation + guard
                                  (shared: also used by ../rocket2/, cross-referenced there)
        rocket_con_8250.sv        synthesizable 8250 console on the generat's mmio_axi4 port
                                  (shared: also used by ../rocket2/, cross-referenced there)
fpga/   rocket_kv260_top.sv       bitstream top: Zynq PS + AXI plumbing around rocket_soc_top
        run_rocket_bitstream.tcl entry point: builds the Vivado project + bitstream (see "Build" below)
        synth_rocket_ooc.tcl      out-of-context capacity/timing measurement of the whole Rocket branch
        rocket_synth_pre.tcl      TCL.PRE hook (single-threaded synth -- see the file's own header)
        gen_ip.tcl                the 4 standalone PS-glue IPs (PS, reset sync, AXI DWC, AXI4-to-Lite)
        abc_filelist.py           resolves the CTTE encoder's .abc dependency graph into a file list
        rocket_pib_pmod.xdc       PIB parallel-trace-port pin constraints (KV260 PMOD J2)
sw/     build_payload_rocket_rv64.sh   OpenSBI fw_payload build + gates (runs on a Linux build host)
        rocket_kv260_rv64.dts          devicetree of the RV64 Rocket Linux machine
        fp_gate_probe.sh               counter-check for the floating-point gate in the build script
        qemu_sanity_rocket.sh          QEMU sanity boot of the built payload (does not exercise the SoC)
```

`rocket_soc_top.sv`/`rocket_soc_synth_wrap.sv` consume the shared sink RTL
from [`../common/`](../common/) (`ct_soc_trace_ring`, `ct_soc_ddr_sink`,
`ct_soc_pib`) and from [`../common/tgc5b/rtl/`](../common/tgc5b/rtl/)
(`ct_axil_to_wb`) rather than duplicating them; the already-migrated
[`rocket_tci_to_ctte_tip`](../../../rtl/adapters/rocket/rocket_tci_to_ctte_tip.sv)
adapter is referenced at its existing repo-root location, unchanged.
`rocket_mem_window.sv`/`rocket_con_8250.sv` live here rather than in
`../rocket2/` (both are consumed cross-example by that sibling, and by the
CVA6 dual-core example once it lands).

## Register map (AXI4-Lite aperture, base `0xA000_0000`)

| Region | Offset | Contents |
|---|---|---|
| CTRL  | `0x00_0000` | control/status registers (`rocket_soc_top.sv`) |
| ENC   | `0x01_0000` | CTTE encoder CSRs (via `ct_axil_to_wb` -> Wishbone) |
| TRACE | `0x20_0000` | captured ATB ring buffer (1 MiB URAM) |
| CON   | `0x30_0000` | console ring (word read accesses) |

CTRL register detail (CONTROL/STATUS/TRACE_x/SINK_x/DDR_x/CON_x/WIN_x/
PC/RETIRES/EXT_IRQ) is documented in `rtl/rocket_soc_top.sv`'s header
comment (`@details`).

## Board memory map

Guest (Rocket bus decoder, fixed in the generat, not relocatable -- see
`rtl/rocket_mem_window.sv`'s header for the three independent reasons):
`0x8000_0000` + 192 MiB RAM, `0x6001_0000` 8250 console (in the generat's
`0x4000_0000..0x7FFF_FFFF` MMIO window), `0x0200_0000` CLINT and
`0x0C00_0000` PLIC (both inside the generat, not board RTL). PS DDR side
([`../SPEC_board_memory_map.md`](../SPEC_board_memory_map.md) -- since
2026-08-21 part of this repository; the note that it was "not resolvable
from this repository alone" is obsolete): `0x5000_0000` + 256 MiB
trace-sink window, `0x6000_0000` + 64 MiB clearance, `0x6400_0000` +
192 MiB Rocket Linux RAM. The trace-sink numbers here were the v3 plan; v4
moved and enlarged it on 2026-08-10, see §1 of that document.

## Build (TCL flow)

Like `examples/kv260/mbv/`, this example's Vivado flow is still a plain TCL
script, not yet this repository's `abc` build driver. Converting each KV260
top to `abc` is a deliberate later step with its own board gate.

```bash
# CT_XLEN=32 default, E-Trace back end (EN_ETRACE=1). The output protocol is
# a SYNTHESIS choice per encoder instance -- exactly one of EN_NTRACE /
# EN_ETRACE is built (rtl/ct_encoder.sv header); the CSR trTeProtocolSel only
# REPORTS which back end was built, it does not switch it at runtime
# (rtl/pkg/ct_cs_if.sv:256, "constant of the built-in back end"):
vivado -mode batch -notrace -source examples/kv260/rocket_linux/fpga/run_rocket_bitstream.tcl

# EN_ETRACE explicit override (0 or 1), default 1:
vivado -mode batch -notrace -source examples/kv260/rocket_linux/fpga/run_rocket_bitstream.tcl -tclargs 0

# CT_XLEN=64 mirror (EN_ETRACE MUST be 0 -- see the script header for why):
# NOT FUNCTIONAL TODAY, see "Open items" below.
vivado -mode batch -notrace -source examples/kv260/rocket_linux/fpga/run_rocket_bitstream.tcl -tclargs 0 64

# Out-of-context capacity/timing measurement only (no bitstream):
vivado -mode batch -notrace -source examples/kv260/rocket_linux/fpga/synth_rocket_ooc.tcl -tclargs full
```

`vivado` and `py` (Python 3) must be on `PATH`.

## Running it on the board

This example has no `board/` directory. Its board recipe lives with the
dashboard, because that is what drives it:
[`../../dashboard/boot/rocket_linux64_run.sh`](../../dashboard/boot/rocket_linux64_run.sh),
invoked in the phases `prep` / `start` / `live` via
[`../../dashboard/boot.json`](../../dashboard/boot.json). Run by hand:

```sh
sudo PHASE=prep  PL_MHZ=68 bash rocket_linux64_run.sh
sudo PHASE=start PL_MHZ=68 bash rocket_linux64_run.sh
sudo PHASE=live  PL_MHZ=68 bash rocket_linux64_run.sh
```

It needs `phys_io.py` at `/tmp/phys_io.py` and the payload at
`/tmp/fw_payload_rocket.bin`. **Stop `ctrace-dashboard.service` before any
`xmutil unloadapp`** (see
[`../SPEC_board_memory_map.md`](../SPEC_board_memory_map.md) §3).

Measured 2026-08-21 on a KV260: payload 34 678 856 B written and read back
byte-identical, guest boots to `buildroot login:` (15 331 bytes of console,
0 drops, `Starting network: OK`), 973 127 483 retired instructions with
`WIN_ERR_CNT 0`, one-shot capture decodes **5 414 841 instructions**.

## Open items

- **`RocketSystem` (the generat) is not vendored** -- it is a *generated*
  Verilog blob from a Chisel/FIRRTL build (WSL2/sbt toolchain), pinned by
  commit + reproducible generation recipe in
  [`../third_party/ROCKET_PIN.md`](../third_party/ROCKET_PIN.md), not
  fetchable by a simple clone. `plusarg_reader.v` (the one FIRRTL blackbox
  the generat needs) IS vendored, at
  [`../third_party/rocket_ref/plusarg_reader.v`](../third_party/rocket_ref/plusarg_reader.v)
  (third-party SiFive/Apache-2.0 code, not Accemic IP).
- ~~`sim/rocket/extract_tlrom.py` not migrated~~ **-- closed 2026-08-18
  (`facf54cfbd`).** The bootrom hart-0 reset-vector patch tool that
  `run_rocket_bitstream.tcl` and `synth_rocket_ooc.tcl` invoke at build time
  now lives at
  [`../common/tools/extract_tlrom.py`](../common/tools/extract_tlrom.py),
  shared with `../rocket2/`; both TCL call sites here point there. Note that
  the tool patches the *generat*, which is still not vendored (previous
  bullet) -- a full build therefore still needs `system-nexys-video.v`
  obtained per `ROCKET_PIN.md`.
- **`tools/abc_filelist.py` promotion is overdue.** This repository has no
  repo-root `tools/abc_filelist.py` yet; `mbv` vendored the first per-example
  copy, this example is the SECOND consumer (and `../rocket2/` the third).
  Per `mbv`'s own migration notes, a second consumer should trigger
  promotion to `tools/` -- that promotion is out of this migration's write
  scope (`examples/kv260/rocket_linux/` and `examples/kv260/rocket2/` only).
- **`rocket_pib_pmod.xdc` is a deliberately renamed, duplicated vendor copy**
  of the `duo` example's `duo_pib_pmod.xdc` rather than a cross-reference
  into that example's directory (constraint files pinning physical pads are
  a different
  risk class than RTL; avoids a hard dependency on a directory owned by a
  concurrent, uncoordinated migration worker).
- **The `CT_XLEN=64` branch of `run_rocket_bitstream.tcl` works again since
  2026-08-18, and it is now the branch this example is BUILT with** -- this
  item is **closed**. Two things were wrong at once. First,
  `bld/w1_rv64_decode/ctte_xlen64` had no producer here; the workflow was
  ported from the predecessor repository's `sim/cva6_rv64/mk_ctte64.ps1` to
  [`../common/tools/mk_encoder_mirror.sh`](../common/tools/mk_encoder_mirror.sh):

  ```bash
  bash examples/kv260/common/tools/mk_encoder_mirror.sh \
       --dest bld/w1_rv64_decode/ctte_xlen64 --xlen 64
  ```

  Second, the 32-bit default branch cannot build this design **at all**:
  `rocket_soc_synth_wrap.sv:398` hardwires `.CORE_XLEN(64)`, and since P0-07
  (`1415a02524`, 2026-08-12) `ct_encoder` refuses the mismatch during
  elaboration ("CORE_XLEN=64 does not match this netlist's trace ingress
  width of 32 bit", measured 2026-08-18). The correct invocation is
  `-tclargs 0 64`, which is also the one `build_all_demos.sh`'s app name has
  always implied (`rocket_x64_ctrace_kv260`); `build_all_demos.sh` was
  corrected accordingly.
- **The payload build (`sw/build_payload_rocket_rv64.sh`) depends on the
  `cva6_linux` example's Buildroot output tree.** It reuses the kernel
  image, initramfs, and RISC-V cross-toolchain built by `cva6_linux`'s
  Buildroot output (`$L1_OUT`, override via env var, default
  `$HOME/cva6_linux/out_rv64`); Rocket-specific build steps here only
  produce the DTB and the OpenSBI `fw_payload` binding. **Build
  `cva6_linux`'s Linux payload first.** (`cva6_linux` is migrated
  as part of the same consolidation.)
- **The Vivado TCL flow was not executed end-to-end** during this migration
  (project creation, elaboration, bitstream, board deploy) -- no Vivado
  license/session was invoked; the script was adapted by careful path/
  reference review and cross-checked structurally, not run. Exercising it is
  still an open item; nothing in this repository has run this flow.
- **This example has no board gate of its own** -- `../README.md` lists
  `rocket_linux`/`rocket2` as "bitstream flow migrated, board leg pending",
  and there is no `rocket_linux/board/` directory. The shared packaging /
  deploy / loader tooling the gated examples use does exist and is reusable
  from here: [`../common/board/`](../common/board/)
  (`package_kv260_app.py`, `deploy_kv260_app.sh`, `mem_load.py`); the
  closest template for a Linux payload is
  [`../cva6_linux/board/README.md`](../cva6_linux/board/README.md).

## Verification performed during migration

`verilator --lint-only` elaboration of `rocket_soc_top` together with its
full dependency closure (the CTTE encoder's transitive `.abc` closure, 74
files; the already-migrated Rocket adapter; the shared/common sink RTL; and
a scratch, uncommitted, port-compatible stub for the unvendored
`RocketSystem` generat) and a repository-wide duplicate-module-name check --
both green. The Vivado TCL flow itself (`fpga/`) was adapted by careful
path/reference review, not executed.
