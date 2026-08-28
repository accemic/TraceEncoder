<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/cva6_linux64 — RV64 CVA6 Linux + CTTE on the KV260

A KV260 (Kria K26 SOM, `xck26-sfvc784-2LV-c`) demonstrator that traces a
single RV64IMAC CVA6 core (config `cv64a6_imac_sv39_ctrace`, no FPU)
booting Linux, with CTTE. Twin of
[`../cva6_linux/`](../cva6_linux/) -- read that example's README first;
this one only documents what differs. ADDITIVE: `../cva6_linux/` is
unchanged by this example landing.

Migrated 2026-08-17 from an internal predecessor repository; see
[`../README.md`](../README.md) for the conventions all KV260 examples
share.

## What differs from `cva6_linux`

1. **Core `cv64a6_imac_sv39_ctrace`** (delta D6, a new FPU-less RV64 config
   not present upstream -- see
   [`../third_party/CVA6_PIN.md`](../third_party/CVA6_PIN.md)), not
   `cv32a6_ima_sv32_fpga`. Same underlying `cva6_trace_wrap` chain, wider
   nets throughout (widths come from `CVA6Cfg.XLEN`/`.VLEN`, not a literal
   32 in the code -- see `rtl/cva6_soc64_synth_wrap.sv`'s header for the
   RV32-vs-RV64 delta enumeration).
2. **`cva6_linux_mem_xbar.sv` is cross-referenced, not duplicated**, from
   [`../cva6_linux/rtl/`](../cva6_linux/rtl/), with
   `RISCV_WORD_WIDTH=64` overridden at the instantiation (the parameter is
   already width-parametric in that shared file; no RTL change needed for
   this example to consume it) -- the PULP `axi_riscv_atomics_wrap` block
   rejects any AMO wider than the configured word width, so this override
   is what makes `amoadd.d`/kernel spinlocks actually work on RV64.
3. **`cva6_linux64_periph.sv` handles CLINT writes exactly by AXI byte
   strobe** (not by picking a 32-bit half of the 64-bit beat like the RV32
   `cva6_linux_periph.sv` does) -- an RV64 `sd` on `mtimecmp` is one 8-byte
   beat with `wstrb=0xFF`; the RV32-style half-word selection would leave
   `mtimecmp[63:32]` at its reset value and `timer_irq` would never fire.
   See the file's own header for the full derivation (this is the one true
   boot-stopper delta of this example).
4. **`sw_irq`/`ipi_i` is wired**, not tied to 0: OpenSBI already uses IPI
   in the single-core start sequence on RV64 in a way the RV32 boot path
   did not exercise.
5. **N-Trace only in the bitstream top** (`EN_ETRACE=1'b0` in
   `fpga/cva6_linux64_kv260_top.sv`), unlike the RV32 top's DUAL
   provisioning -- a measured area/timing trade-off (E-Trace backend costs
   10,245 LUT and dominates the critical path at this core size); see that
   file's header for the exact numbers and the CT_XLEN=32-encoder-tree
   caveat this implies for full-width RV64 PC capture (TODO X2 in
   `rtl/cva6_soc64_synth_wrap.sv`).
6. **Board-derived core configuration**: `fpga/cva6_linux64_board_cfg.tcl`
   patches `CachedRegionLength` from the upstream 192 MiB down to the
   board-proven conservative 64 MiB (cacheable memory above `0x6800_0000`
   correlated with a board failure within ~5 s on the RV32 twin's
   equivalent finding) -- derived fresh from the pinned `cva6_ref` source
   on every build, not a committed second copy of that file (see the
   script's own header for why).

## Layout

```
rtl/    cva6_linux64_soc_top.sv    AXI4-Lite control-port top -- same CTRL/ENC/TRACE/CON map as cva6_linux
        cva6_soc64_synth_wrap.sv   CVA6 (cv64a6_imac_sv39_ctrace) + RVFI + ITI + shim + ct_encoder
        cva6_linux64_periph.sv     CLINT (byte-strobe-exact writes) + 8250 console
fpga/   cva6_linux64_kv260_top.sv        bitstream top (N-Trace only, see point 5 above)
        run_cva6_linux64_bitstream.tcl   entry point (CT_XLEN 32|64 switch, see the script header)
        synth_cva6_linux64_ooc.tcl       standalone OOC capacity measurement (soc|wrap, dual/nonly)
        cva6_linux64_board_cfg.tcl       derives the board core config from the pinned D6 source (point 6)
        gen_ip.tcl / abc_filelist.py / cva6_filelist.py / cva6_pib_pmod.xdc   own vendored copies
sw/     cva6_kv260_rv64.dts / cva6_kv260_rv64_defconfig / cva6_rv64.config /
        build_payload_rv64.sh / make_listing_rv64.sh / check_images_rv64.sh   RV64 Buildroot/Linux payload
```

`cva6_linux_mem_xbar.sv` (point 2 above) is the only cross-example
reference this example makes; every other RTL file here is its own.

## Register map (AXI4-Lite aperture, base `0xA000_0000`)

Bit-identical to [`../cva6_linux/`](../cva6_linux/)'s CTRL/ENC/TRACE/CON
map -- see that README and `rtl/cva6_linux64_soc_top.sv`'s header.

## Build (TCL flow)

```bash
# CT_XLEN=32 default (this repository's own encoder tree):
vivado -mode batch -notrace -source examples/kv260/cva6_linux64/fpga/run_cva6_linux64_bitstream.tcl

# CT_XLEN=64 mirror (NOT FUNCTIONAL TODAY, see "Open items"):
vivado -mode batch -notrace -source examples/kv260/cva6_linux64/fpga/run_cva6_linux64_bitstream.tcl -tclargs 64

# Standalone OOC capacity measurement (Gate R4b step 1, not part of the bitstream flow):
vivado -mode batch -notrace -source examples/kv260/cva6_linux64/fpga/synth_cva6_linux64_ooc.tcl -tclargs soc
```

## Running it on the board

This example has no `board/` directory. Its board recipe lives with the
dashboard, because that is what drives it:
[`../../dashboard/boot/cva6_linux64_run.sh`](../../dashboard/boot/cva6_linux64_run.sh),
invoked in the phases `prep` / `start` / `live` via
[`../../dashboard/boot.json`](../../dashboard/boot.json). Run by hand:

```sh
# on the board, app already loaded and pl_clk0 at 68 MHz
sudo PHASE=prep  APP=cva6_linux64_ctrace_kv260 PL_MHZ=68 bash cva6_linux64_run.sh
sudo PHASE=start APP=cva6_linux64_ctrace_kv260 PL_MHZ=68 bash cva6_linux64_run.sh
sudo PHASE=live  APP=cva6_linux64_ctrace_kv260 PL_MHZ=68 bash cva6_linux64_run.sh
```

It needs `phys_io.py` at `/tmp/phys_io.py` and the payload at
`/tmp/fw_payload64.bin`. **Stop `ctrace-dashboard.service` before any
`xmutil unloadapp`** -- otherwise the PL is pulled out from under a live AXI
master and the board stops answering ssh (see
[`../SPEC_board_memory_map.md`](../SPEC_board_memory_map.md) §3).

Measured 2026-08-21 on a KV260: payload 17 703 992 B written and read back
byte-identical, guest boots to `buildroot login:` (11 004 bytes of console,
0 drops), one-shot capture from core start decodes **4 246 697 instructions**.

## Open items

All of `cva6_linux`'s open items apply here too (CVA6-with-ITI reference
core not vendored; full SoC-top `verilator` elaboration blocked by the
same un-vendored PULP `AXI_BUS` infrastructure; Vivado flow not executed
end-to-end; board deploy tooling out of scope). In addition:

- **The `CT_XLEN=64` branch of `run_cva6_linux64_bitstream.tcl` works again
  since 2026-08-18** -- this item is **closed**. The workflow that produces
  `bld/w1_rv64_decode/ctte_xlen64` was ported from the predecessor repository's
  `sim/cva6_rv64/mk_ctte64.ps1` to
  [`../common/tools/mk_encoder_mirror.sh`](../common/tools/mk_encoder_mirror.sh);
  build the mirror once before the first run (seconds):

  ```bash
  bash examples/kv260/common/tools/mk_encoder_mirror.sh \
       --dest bld/w1_rv64_decode/ctte_xlen64 --xlen 64
  ```

  The mirror carries the tree's own (full) profile, only with `CT_XLEN=64`.
  It is not optional for this example: `cva6_soc64_synth_wrap.sv:288` passes
  `.CORE_XLEN(Cfg.XLEN)` = 64, and since P0-07 (`1415a02524`) `ct_encoder`
  refuses a core/encoder width mismatch during elaboration.
- **`tools/abc_filelist.py`/`cva6_filelist.py` promotion is overdue.**
  This is the fifth and third vendored copy respectively (after
  mbv/rocket_linux/rocket2/cva6_linux for `abc_filelist.py`; after `trio`
  and `cva6_linux` for `cva6_filelist.py`) -- out of this migration's write
  scope (`examples/kv260/cva6_linux/`, `examples/kv260/cva6_linux64/` and
  `examples/kv260/cva6_2/` only).

## Verification performed during migration

**Duplicate-module-name check:** all four module names this example
introduces (`cva6_linux64_soc_top`, `cva6_linux64_periph`,
`cva6_soc64_synth_wrap`, `cva6_linux64_kv260_top`) verified individually to
appear exactly once repo-wide (289 `.sv` files); this example introduces
**no new duplicates** (the tree's only duplicates remain the pre-existing
`fifo2clk_fwft` pair and the `cva6_soc_synth_wrap` cross-worker collision
documented in `../cva6_linux/README.md` -- unrelated to this RV64 example,
which does not touch that module name).

**`verilator --lint-only` (5.040), same two-scope approach as
`cva6_linux`** (full SoC-top closure blocked by the same un-vendored PULP
infrastructure, see "Open items"):

1. `cva6_soc64_synth_wrap` with the CTTE encoder's 74-file `.abc`
   closure + the adapter files + a throwaway RV64-width stub for
   `cva6_trace_wrap` (`AxiIdWidth=4`, `AxiAddrWidth=64`, `VLEN=XLEN=64`,
   `ASIDW=16` per `CVA6_PIN.md`'s Sv39 value) **plus** a second small
   scratch stub providing the three `config_pkg`/`cva6_config_pkg`/
   `build_config_pkg` packages this file's own `localparam Cfg = ...`
   mirror needs (populated with only the three fields actually
   dereferenced -- `Cfg.XLEN`/`.VLEN`/`.ASIDW` -- unlike the RV32
   `cva6_soc_synth_wrap.sv`, which hardcodes 32 throughout and needs no
   such package). Both stubs written to scratch, not committed.
   **Result: 0 `%Error`** (1223 warnings, same "exceeds the default
   warning budget" characteristic as every sibling example).
2. `cva6_linux64_periph.sv` standalone: **0 `%Error`**, 6 benign
   `UNUSEDSIGNAL` warnings (same classes as `cva6_linux_periph.sv`, plus
   two from the wider `wdata_eff`/`waddr_eff` intermediate signals this
   RV64 version carries).

**No built binaries under `sw/`**: verified as part of the combined check
across all three examples, see `../cva6_linux/README.md`.

**Not exercised: the Vivado TCL flow itself.**
