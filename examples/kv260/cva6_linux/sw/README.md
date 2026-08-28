<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/cva6_linux/sw — Linux software stack for the RV32 CVA6

`BR2_EXTERNAL` tree for Buildroot 2025.02. Builds the RV32IMA toolchain
(**without the C extension**, target core `cv32a6_ima_sv32_fpga`), OpenSBI
1.6 (generic), Linux 6.12.9 with an embedded Busybox initramfs, and
host-qemu for a sanity boot without hardware.

Migrated 2026-08-17 from an internal predecessor repository, RV32 subset
only.
The RV64 sibling files from the same source directory
(`cva6_kv260_rv64.dts`, `cva6_kv260_rv64_defconfig`, `cva6_rv64.config`,
`build_payload_rv64.sh`, `make_listing_rv64.sh`, `check_images_rv64.sh`) were
migrated separately into [`../../cva6_linux64/sw/`](../../cva6_linux64/sw/),
which is this directory's RV64 counterpart -- see that directory's README
for the RV64 build.

**Runs on a Linux build host** (`build_payload.sh`/`make_listing.sh` invoke
`dtc`, the Buildroot-built cross toolchain, and GNU binutils; none of that
is available on Windows). The source repository's comments named a specific
lab host by name for this step -- scrubbed here to the generic wording
above; see the workspace's hardware-coordination conventions if a specific
build host needs to be pinned for a given run.

## Layout

```
Config.in / external.desc / external.mk   BR2_EXTERNAL marker files (tiny, see below)
cva6.config             kernel config fragment (RVC off, no FPU, 8250-polled console)
cva6_kv260.dts          devicetree of the RV32 CVA6 Linux machine
cva6_kv260_defconfig    Buildroot defconfig (riscv32, rv32ima, no C/F/D)
build_payload.sh        DTB + OpenSBI fw_payload build (runs on a Linux build host)
make_listing.sh         merged decoder listing (OpenSBI + kernel phys + kernel virt)
check_images.sh         gate check on the kernel artifact (ELF class, RVC, ISA)
```

`Config.in`/`external.desc`/`external.mk` are the generic BR2_EXTERNAL
marker files Buildroot needs to recognize this directory as an external
tree. They are tiny (1-3 lines) and, per the source repository's own
layout, are duplicated verbatim across the RV32/RV64/dual-core CVA6
examples that share this `BR2_EXTERNAL_CVA6_PATH` name (`external.desc`'s
`name: CVA6`) rather than factored into one owner with the others
cross-referencing it -- `external.desc`'s exact two-line
`name:`/`desc:` format is read by a Buildroot-internal parser whose
tolerance for extra content (e.g. an SPDX header comment) was not verified
against the pinned Buildroot 2025.02 release during this migration, so it
was kept byte-identical to the source rather than risk breaking
`BR2_EXTERNAL` detection; `Config.in` and `external.mk` are ordinary
Kconfig/Make syntax where a `#`-comment header is unambiguously safe and
therefore carries one.

## Building

```bash
cd ~/cva6_linux/buildroot
make BR2_EXTERNAL=$HOME/cva6_linux defconfig BR2_DEFCONFIG=$HOME/cva6_linux/cva6_kv260_defconfig
make -j$(nproc)
```

Artifacts land in `output/images/`: `Image` (kernel + initramfs),
`fw_jump.bin`/`fw_dynamic.bin` (OpenSBI). The devicetree for this SoC is
NOT built by Buildroot -- it is the sibling file `cva6_kv260.dts` (address
map matches `rtl/cva6_linux_soc_top.sv`'s header comment).

Then, on the same Linux build host:

```bash
./build_payload.sh && ./check_images.sh && ./make_listing.sh
```

Artifacts land in `out/`: `cva6_kv260.dtb`, `fw_payload.bin`/`.elf`
(load at `0x6400_0000`, `CONTROL.core_run=1` starts the core), and
`merged.dis` (the three-address-space decoder listing `make_listing.sh`
produces).

## Excluded from this migration

The source `sw/cva6_linux/` directory additionally carried
`build_s1_sqlite.sh`, `build_w5_procs.sh`, `s1_make_listing.sh`,
`w5_proc.S` and `w5_proc.ld` -- verified by reading each file's own header
comment: these are separate characterization/measurement side-projects (an
SQLite-as-workload benchmark and a bare-metal ownership-filter board test),
not part of the boot-Linux-with-trace demonstrator this example covers.
Same exclusion class the `mbv` migration already established for
`vivado/kv260_app/`'s `w5_*`/`s1_*`/`bm1_*` files.

## Open items

- **No built binaries are committed** -- `output/`, `out/`, `dl/` etc. are
  build products of the flow above, not part of this migration.
- The Buildroot build itself was not exercised end-to-end during this
  migration (no Linux build host with the pinned toolchain download cache
  was available in this session); the source files were carried over with
  path/reference review and comment translation only.
