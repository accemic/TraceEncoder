<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# examples/kv260/cva6_linux64/sw — Linux software stack for the RV64 CVA6

ADDITIVE RV64 sibling of [`../../cva6_linux/sw/`](../../cva6_linux/sw/)
(the RV32 build) -- migrated from the same source directory
(an internal predecessor repository), RV64 subset only.

**This directory shares the BR2_EXTERNAL marker files with
[`../../cva6_linux/sw/`](../../cva6_linux/sw/).** `Config.in`,
`external.desc` and `external.mk` are NOT duplicated here -- both this
directory and `../../cva6_linux/sw/` are meant to be used as
`BR2_EXTERNAL=<path to cva6_linux/sw>` regardless of whether the RV32 or
RV64 defconfig is selected; `external.mk`'s own content confirms this is
defconfig-agnostic (it is a one-line comment, see
`../../cva6_linux/sw/external.mk`). Point `BR2_EXTERNAL` at
`../../cva6_linux/sw/` for BOTH the RV32 and the RV64 build; this
directory only supplies the RV64-specific defconfig/fragment/dts/scripts.

**Runs on a Linux build host** (same as the RV32 sibling; `dtc`, the
Buildroot-built RV64 cross toolchain and GNU binutils are not available on
Windows).

## Layout

```
cva6_rv64.config              kernel config fragment (RVC on, no FPU, EFI off, 8250-polled console)
cva6_kv260_rv64.dts           devicetree of the RV64 CVA6 Linux machine
cva6_kv260_rv64_defconfig     Buildroot defconfig (riscv64, rv64imac, no F/D)
build_payload_rv64.sh         DTB + OpenSBI fw_payload build (out-of-tree, runs on a Linux build host)
make_listing_rv64.sh          merged decoder listing (OpenSBI + kernel phys + kernel virt40)
check_images_rv64.sh          gate check on the kernel artifact (ELF64, ISA attribute, .config, Sv39)
```

## Building

The RV64 run is an out-of-tree build (`make O=...`) on the SAME Buildroot
source tree as the RV32 build -- shared download cache, separate `.config`
and separate output trees. Build the RV32 tree first if starting from
scratch (see [`../../cva6_linux/sw/README.md`](../../cva6_linux/sw/README.md));
then:

```bash
cd ~/cva6_linux/buildroot
make O=$HOME/cva6_linux/out_rv64 BR2_EXTERNAL=$HOME/cva6_linux defconfig \
     BR2_DEFCONFIG=$HOME/cva6_linux/cva6_kv260_rv64_defconfig
cd ~/cva6_linux/out_rv64 && make -j$(nproc)
cd ~/cva6_linux && ./build_payload_rv64.sh && ./check_images_rv64.sh && ./make_listing_rv64.sh
```

(Paths above assume both `../../cva6_linux/sw/` and this directory's files
are laid out flat under `~/cva6_linux/` on the build host, matching the
source repository's own layout convention; adjust to this repository's
actual checkout path.)

Artifacts land in `out_rv64/images/` (Buildroot) and `out64/` (payload,
DTB, listings). Two addresses deliberately differ from the RV32 path and
are READ by the scripts from the artifacts, not set: the kernel sits
physically at `0x6420_0000` (OpenSBI chooses a 2 MiB offset for XLEN=64,
because the RV64 kernel requires 2 MiB alignment) and virtually at
`0xFFFFFFFF8000_0000` (RV64 places the kernel in the topmost 2 GiB, not at
PAGE_OFFSET).

## Open items

- **No built binaries are committed.**
- The Buildroot build itself was not exercised end-to-end during this
  migration (no Linux build host with the pinned toolchain download cache
  was available in this session); the source files were carried over with
  path/reference review and comment translation only.
- `external.mk`'s defconfig-agnostic content was read and confirmed during
  this migration (see `../../cva6_linux/sw/README.md`'s note on why
  `Config.in`/`external.desc`/`external.mk` were not duplicated here) --
  this note records that check so a later session does not have to redo it.
