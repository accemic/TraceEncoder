#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Gate check of the RV64 Linux artifacts for the CVA6. ADDITIVE variant
# alongside check_images.sh (in ../../cva6_linux/sw/); the RV32 version
# stays unchanged.
#
# Target core cv64a6_imac_sv39_ctrace (delta D6):
#   * RV64  -- CVA6ConfigXlen = 64
#   * C YES -- CVA6ConfigCExtEn = 1, RVC: bit'(...)
#   * F/D NO -- CVA6ConfigRVF/RVD = 0
# The RV32 gate "no compressed instructions" is therefore FACTUALLY WRONG
# here and is replaced by "no floating-point instructions" -- that is the
# property the core actually cannot serve.
#
# What matters is not what the kernel configuration says, but what lands
# in the BINARY IMAGE -- hence this script primarily checks the artifact.
#
#   ./check_images_rv64.sh [<buildroot-output-dir>]
set -u
BRO="${1:-$HOME/cva6_linux/out_rv64}"
BIN="$BRO/host/bin"
OD="$BIN/riscv64-buildroot-linux-gnu-objdump"
NM="$BIN/riscv64-buildroot-linux-gnu-nm"
RE="$BIN/riscv64-buildroot-linux-gnu-readelf"
VMLINUX="$(ls -d "$BRO"/build/linux-*/vmlinux 2>/dev/null | head -1)"
KCONF="$(ls -d "$BRO"/build/linux-*/.config 2>/dev/null | head -1)"
rc=0

[ -x "$OD" ]      || { echo "MISSING: $OD"; exit 2; }
[ -n "$VMLINUX" ] || { echo "MISSING: vmlinux"; exit 2; }

echo "== Artifacts =="
ls -la "$BRO"/images/Image "$BRO"/images/fw_jump.bin \
       "$BRO"/images/rootfs.cpio 2>/dev/null

echo
echo "== Kernel ELF class (must be ELF64 RISC-V) =="
"$RE" -h "$VMLINUX" | grep -E "^  (Class|Machine|Entry point)"
if ! "$RE" -h "$VMLINUX" | grep -q "^  Class:  *ELF64"; then
    echo "ERROR: vmlinux is not ELF64"; rc=1
fi

echo
echo "== Userspace ISA attribute (rv64, with c, WITHOUT f/d) =="
# WHY busybox and not vmlinux: vmlinux carries NO .riscv.attributes
# (measured on the RV32 stage -- "readelf -A vmlinux" is empty, objdump -h
# shows no such section). A gate on the kernel ELF attribute would
# therefore be a gate on an empty string. The userspace binary carries it
# and is the reliable statement about the toolchain ISA on the artifact;
# for the kernel itself the ELF class (above) and the floating-point sniff
# (below) apply.
BB="$BRO/target/bin/busybox"
if [ -f "$BB" ]; then
    arch=$("$RE" -A "$BB" 2>/dev/null | awk -F'"' '/Tag_RISCV_arch/{print $2; exit}')
    echo "Tag_RISCV_arch (busybox): ${arch:-<empty>}"
    case "$arch" in
        rv64*) ;;
        *)     echo "ERROR: ISA attribute is not rv64*"; rc=1;;
    esac
    case "$arch" in
        *_f*|*_d[0-9]*) echo "ERROR: F/D in the ISA attribute -- the core has no FPU!"; rc=1;;
    esac
    case "$arch" in
        *_c[0-9]*) echo "(c present -- expected, the core has the C extension)";;
        *)         echo "(NOTE: no c -- runs, but does not use the core to its potential)";;
    esac
else
    echo "ERROR: $BB missing"; rc=1
fi

echo
echo "== Floating-point instructions in the kernel CODE =="
# Header boundary as in the RV32 version, from the symbol table, not
# guessed: with the EFI stub, the image starts with a data block that
# every disassembler reads as instructions.
hdr_end=$("$NM" -n "$VMLINUX" 2>/dev/null \
          | awk '$3=="efi_header_end" || $3=="_start_kernel" {print $1; exit}')
if [ -z "$hdr_end" ]; then
    echo "(no PE/COFF header -- the EFI stub is off)"
else
    echo "(header boundary from the symbol table: 0x$hdr_end)"
fi
# -M no-aliases is MANDATORY: objdump prints alias forms by default that
# hide the base mnemonic -- fsgnjn.d is printed as "fneg.d", fsgnjx.s as
# "fabs.s". The list below catches "fsgnj", not "fneg"/"fabs"; without this
# flag an image with exclusively fneg/fabs stays GREEN. Same trap as with
# the RVC counter.
"$OD" -d -M no-aliases "$VMLINUX" 2>/dev/null > /tmp/vmlinux_rv64.dis || { echo "objdump failed"; exit 2; }
n=$(awk '
      $3 ~ /^(flw|fld|flq|fsw|fsd|fsq|fsgnj|fadd\.|fsub\.|fmul\.|fdiv\.|fsqrt\.|fmin\.|fmax\.|fmadd\.|fmsub\.|fnmadd\.|fnmsub\.|fcvt\.|fmv\.|feq\.|flt\.|fle\.|fclass\.)/ { c++ }
      END { print c+0 }' /tmp/vmlinux_rv64.dis)
echo "found: $n"
if [ "$n" -gt 0 ]; then
    echo "ERROR: the core has no FPU!"
    awk '$3 ~ /^(flw|fld|flq|fsw|fsd|fsq|fsgnj|f[a-z]+\.[sdqh])/' /tmp/vmlinux_rv64.dis | head -5
    rc=1
fi

echo
echo "== Compressed instructions in the kernel CODE (ALLOWED, informational) =="
# CAUTION measurement trap: binutils 2.43.1 prints compressed instructions
# by default WITH alias, i.e. WITHOUT the "c." prefix -- "aa01" appears as
# "j", not "c.j" (measured on the generated kernel). A counter that checks
# /^c\./ on the default disassembly is therefore practically blind: the
# same kernel yields 1,908,696 hits with -M no-aliases and 7 without. This
# is why -M no-aliases is ALWAYS used here.
"$OD" -d -M no-aliases "$VMLINUX" 2>/dev/null > /tmp/vmlinux_rv64_na.dis || { echo "objdump failed"; exit 2; }
nc=$(awk '$3 ~ /^c\./ { c++ } END { print c+0 }' /tmp/vmlinux_rv64_na.dis)
echo "found: $nc  (the target core has the C extension -- not an error)"
if [ "$nc" -eq 0 ]; then
    echo "(NOTE: none at all -- the kernel does not use the core to its potential, but still runs)"
fi

echo
echo "== Kernel configuration: 64 bit, no FPU, no EFI =="
if [ -n "$KCONF" ]; then
    grep -E "^(CONFIG_64BIT|CONFIG_ARCH_RV64I|CONFIG_MMU|CONFIG_RISCV_ISA_C)=|^# CONFIG_(FPU|EFI) is not set" "$KCONF"
    grep -q "^CONFIG_64BIT=y"            "$KCONF" || { echo "ERROR: CONFIG_64BIT missing"; rc=1; }
    grep -q "^CONFIG_MMU=y"              "$KCONF" || { echo "ERROR: CONFIG_MMU missing"; rc=1; }
    grep -q "^# CONFIG_FPU is not set"   "$KCONF" || { echo "ERROR: CONFIG_FPU is on"; rc=1; }
    grep -q "^# CONFIG_EFI is not set"   "$KCONF" || { echo "ERROR: CONFIG_EFI is on"; rc=1; }
else
    echo "ERROR: kernel .config not found"; rc=1
fi

echo
echo "== Sv39 =="
# Linux 6.12 has no Kconfig switch for the satp level; it is chosen at
# runtime. It is made deterministic via "no4lvl" in the DTB bootarg
# (cva6_kv260_rv64.dts) -- the DTB is therefore checked, not the .config.
DTB="$(dirname "$0")/out64/cva6_kv260_rv64.dtb"
if [ -f "$DTB" ]; then
    if strings "$DTB" | grep -q "no4lvl"; then
        echo "DTB bootargs contain no4lvl -- Sv39 forced"
    else
        echo "ERROR: no4lvl missing from the DTB bootargs"; rc=1
    fi
    if strings "$DTB" | grep -q "riscv,sv39"; then
        echo "DTB mmu-type = riscv,sv39"
    else
        echo "ERROR: mmu-type riscv,sv39 missing in the DTB"; rc=1
    fi
else
    echo "(DTB not built yet -- build_payload_rv64.sh runs before this)"
fi

echo
echo "== Toolchain ISA (must be rv64imac without f/d, ABI lp64) =="
"$BIN"/riscv64-buildroot-linux-gnu-gcc -Q --help=target 2>/dev/null \
    | grep -E "^[[:space:]]+-march=|^[[:space:]]+-mabi=" | head -2
if ! "$BIN"/riscv64-buildroot-linux-gnu-gcc -Q --help=target 2>/dev/null \
     | grep -qE "^[[:space:]]+-march=[[:space:]]+rv64imac"; then
    echo "ERROR: toolchain is not rv64imac"
    rc=1
fi
if ! "$BIN"/riscv64-buildroot-linux-gnu-gcc -Q --help=target 2>/dev/null \
     | grep -qE "^[[:space:]]+-mabi=[[:space:]]+lp64$"; then
    echo "ERROR: toolchain ABI is not lp64"
    rc=1
fi

echo
if [ $rc -eq 0 ]; then echo "IMAGES OK (ELF64 RISC-V, no floating-point instructions, ISA/ABI match, Sv39 forced)"
else                   echo "IMAGES FAIL"; fi
exit $rc
