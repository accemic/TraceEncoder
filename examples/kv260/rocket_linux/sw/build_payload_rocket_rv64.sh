#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# build_payload_rocket_rv64.sh -- build the OpenSBI fw_payload for the RV64
# Rocket Linux machine (RV64 program, package L2). Runs on a Linux build
# host (<linux-build-host>), not on Windows.
#
#   ./build_payload_rocket_rv64.sh      # DTB + fw_payload.bin -> out_rocket/
#
# REUSE instead of rebuild (§15 Iterations-Oekonomie, and the build host had
# only ~15 GiB free): kernel, initramfs, cross-toolchain, dtc, and the
# OpenSBI SOURCE TREE all come UNCHANGED from package L1
# (~/cva6_linux/out_rv64/...; the cva6_linux example this repo also
# migrates). Rocket-specific are only the DTB and the OpenSBI binding
# (FW_TEXT_START + embedded DTB). No second Buildroot tree.
#
# The L1 tree is only READ here: the OpenSBI build runs out-of-tree
# (O=$here/opensbi-build), no directory is created inside the L1 output
# tree.
#
# Environment variables (default in parentheses):
#   L1_OUT   Buildroot output tree from L1     ($HOME/cva6_linux/out_rv64)
#   KIMG     kernel image                      ($L1_OUT/images/Image)
#
# WHY fw_payload and not fw_jump (rationale carried over from L1):
#   fw_jump jumps to a compile-time constant and expects the devicetree at a
#   second one -- two addresses that can silently be gotten wrong, with the
#   symptom "board says nothing". fw_payload carries kernel AND devicetree
#   itself: ONE blob, ONE load address.
#
# WHY the embedded DTB is additionally mandatory here:
#   The Rocket bootrom hands over, in a1, the pointer to ITS OWN DTB in ROM
#   (0x0001_0080, a nexys-video description with 512 MiB RAM, 50 MHz,
#   SD/UART/Ethernet, none of which exist here). OpenSBI overwrites a1 when
#   FW_FDT_PATH is set with the embedded DTB
#   (opensbi-1.6/firmware/fw_base.S:121-124 "Override previous arg1") -- the
#   ROM DTB is thereby ineffective both for OpenSBI AND for the kernel. That
#   is why the ROM does NOT need to be rebuilt for a Linux boot; see
#   docs/handoffs/L2_rocket_linux.md.
set -e

here=$(cd "$(dirname "$0")" && pwd)
l1="${L1_OUT:-$HOME/cva6_linux/out_rv64}"
kimg="${KIMG:-$l1/images/Image}"
host="$l1/host"
out="$here/out_rocket"

# Load address == base of the memory window the generat's system bus decodes
# (system-nexys-video.v:616-629) == bootrom jump target (bootrom.lds
# `_ram`) == memory node in rocket_kv260_rv64.dts.
# A change here must happen at all three places -- and the first two are
# only reachable via a generat rebuild.
TEXT_START=0x80000000
# Size of the window (192 MiB) the KV260 wrapper mirrors here.
MEMWIN=$((192 * 1024 * 1024))

mkdir -p "$out"

# --- 1. Devicetree ---------------------------------------------------------
"$host/bin/dtc" -I dts -O dtb -o "$out/rocket_kv260_rv64.dtb" \
    "$here/rocket_kv260_rv64.dts"
echo "DTB: $(stat -c%s "$out/rocket_kv260_rv64.dtb") bytes"

# --- 2. OpenSBI with an embedded kernel + DTB ------------------------------
sbi=$(ls -d "$l1"/build/opensbi-* 2>/dev/null | head -1)
if [ -z "$sbi" ]; then echo "### ERROR: OpenSBI source tree not found" >&2; exit 1; fi
if [ ! -f "$kimg" ]; then echo "### ERROR: $kimg missing" >&2; exit 1; fi

cross="$host/bin/riscv64-buildroot-linux-gnu-"
if [ ! -x "${cross}gcc" ]; then
    cross=$(ls "$host"/bin/riscv64-*-linux-*-gcc 2>/dev/null | head -1 | sed 's/gcc$//')
fi
if [ -z "$cross" ] || [ ! -x "${cross}gcc" ]; then
    echo "### ERROR: RV64 cross-toolchain not found in $host/bin" >&2; exit 1
fi
echo "Toolchain: $cross"
echo "OpenSBI source tree (read-only): $sbi"

# ISA string derived from the generat: system-nexys-video.dts:30 says
# "rv64imaczicsr_zifencei_zihpm_xrocket" -- we take rv64imac + zicsr +
# zifencei from that; zihpm/xrocket stay unused (using less than the core
# can is always safe). NO f/d: the generat is FPU-free (R3.0 gate c, 0 hits
# for FPU/hardfloat) => ABI lp64.
# FW_PAYLOAD_OFFSET is NOT set: platform/generic/objects.mk already picks
# 0x200000 at XLEN=64, and exactly this 2-MiB alignment is what the RV64
# kernel requires (BUG_ON(kernel_map.phys_addr % PMD_SIZE), arch/riscv/mm/init.c).
make -C "$sbi" \
    CROSS_COMPILE="$cross" \
    PLATFORM=generic \
    PLATFORM_RISCV_XLEN=64 \
    PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei \
    PLATFORM_RISCV_ABI=lp64 \
    FW_TEXT_START=$TEXT_START \
    FW_PAYLOAD=y \
    FW_PAYLOAD_PATH="$kimg" \
    FW_FDT_PATH="$out/rocket_kv260_rv64.dtb" \
    O="$here/opensbi-build" \
    -j"$(nproc)"

cp "$here/opensbi-build/platform/generic/firmware/fw_payload.bin" "$out/"
cp "$here/opensbi-build/platform/generic/firmware/fw_payload.elf" "$out/"
echo "PAYLOAD: $(stat -c%s "$out/fw_payload.bin") bytes -> load address $TEXT_START"

# --- 3. Gates ----------------------------------------------------------------
rc=0
RE="${cross}readelf"
OD="${cross}objdump"
NM="${cross}nm"
DTC="$host/bin/dtc"

# (a) Decompile the DTB back and prove the derived values. Not "dtc ran
#     through", but: is what should be there actually there.
"$DTC" -I dtb -O dts -o "$out/rocket_kv260_rv64.readback.dts" \
    "$out/rocket_kv260_rv64.dtb" 2>/dev/null
rb="$out/rocket_kv260_rv64.readback.dts"
check_dtb() {   # $1 = regex, $2 = plain-text label
    if grep -qE "$1" "$rb"; then
        echo "  DTB OK: $2"
    else
        echo "### ERROR: DTB missing $2 (pattern: $1)" >&2; rc=1
    fi
}
echo "GATE a: DTB round-trip"
check_dtb 'memory@80000000'                        "memory node @0x8000_0000"
check_dtb 'reg = <0x80000000 0x[cC]000000>'        "192 MiB window"
check_dtb 'timebase-frequency = <0xb71b0>'         "timebase 750000 (= 75 MHz/100)"
check_dtb 'clock-frequency = <0x47868c0>'          "clock-frequency 75 MHz"
check_dtb 'mmu-type = "riscv,sv39"'                "Sv39"
check_dtb 'riscv,isa = "rv64imac_zicsr_zifencei"'  "ISA rv64imac without f/d"
check_dtb 'serial@60010000'                        "console in the MMIO window"
check_dtb 'clint@2000000'                          "the generat's CLINT"
check_dtb 'interrupt-controller@c000000'           "the generat's PLIC"
check_dtb 'no4lvl'                                 "Sv39 enforcement in bootargs"

# (b) The blob must fit into the mirrored window (192 MiB from 0x8000_0000).
sz=$(stat -c%s "$out/fw_payload.bin")
if [ "$sz" -ge "$MEMWIN" ]; then
    echo "### ERROR: fw_payload.bin ($sz B) does not fit into $MEMWIN B" >&2; rc=1
else
    echo "GATE b: size $sz B < $MEMWIN B (192 MiB) -- OK"
fi

# (c) ELF class, machine, and ISA attribute of the LINKED artifact.
cls=$("$RE" -h "$out/fw_payload.elf" | awk -F: '/^  Class/{gsub(/ /,"",$2);print $2}')
mach=$("$RE" -h "$out/fw_payload.elf" | awk -F: '/^  Machine/{sub(/^ +/,"",$2);print $2}')
echo "GATE c: Class=$cls Machine=$mach"
if [ "$cls" != "ELF64" ]; then echo "### ERROR: not ELF64" >&2; rc=1; fi
case "$mach" in *RISC-V*) ;; *) echo "### ERROR: not RISC-V" >&2; rc=1;; esac

arch=$("$RE" -A "$out/fw_payload.elf" 2>/dev/null \
       | awk -F'"' '/Tag_RISCV_arch/{print $2; exit}')
echo "GATE c: Tag_RISCV_arch = ${arch:-<empty>}"
if [ -z "$arch" ]; then
    echo "### ERROR: no Tag_RISCV_arch in the ELF" >&2; rc=1
else
    case "$arch" in rv64*) ;; *) echo "### ERROR: ISA attribute is not rv64*" >&2; rc=1;; esac
    case "$arch" in *_f*|*_d[0-9]*) echo "### ERROR: F/D in the ISA attribute -- the generat has no FPU!" >&2; rc=1;; esac
    case "$arch" in *_c[0-9]*) ;; *) echo "### WARNING: no c in the ISA attribute (the generat can do C)" >&2;; esac
fi

# Floating-point counter-check in the firmware text (the core has no FPU;
# RVC is allowed). .text only -- the embedded kernel sits as DATA in its own
# section and would produce false positives as disassembly.
#
# `-M no-aliases` is MANDATORY, not cosmetic: objdump by default prints the
# alias spellings, and those no longer carry the base mnemonic --
# `fsgnjn.d rd,rs,rs` shows up as `fneg.d`, `fsgnjx.s` as `fabs.s`, compressed
# instructions without a `c.` prefix. An image that contains ONLY fneg/fabs
# would have stayed GREEN without this switch (finding from the L1 audit,
# fixed there in build_payload_rv64.sh/check_images_rv64.sh, commit
# 2c718b5). Counter-check for this gate: sw/rocket_linux/fp_gate_probe.sh.
fp=$("$OD" -d -M no-aliases -j .text "$out/fw_payload.elf" 2>/dev/null | awk '
    $3 ~ /^(flw|fld|flq|fsw|fsd|fsq|fsgnj|fadd\.|fsub\.|fmul\.|fdiv\.|fsqrt\.|fmin\.|fmax\.|fmadd\.|fmsub\.|fnmadd\.|fnmsub\.|fcvt\.|fmv\.|feq\.|flt\.|fle\.|fclass\.)/ { c++ }
    END { print c+0 }')
echo "GATE c: floating-point instructions in .text = $fp"
if [ "$fp" -gt 0 ]; then
    echo "### ERROR: floating-point instructions in the firmware text" >&2; rc=1
fi

# (d) Load addresses: firmware at the bootrom jump target, kernel 2-MiB-aligned.
entry=$("$RE" -h "$out/fw_payload.elf" | awk -F: '/Entry point/{gsub(/ /,"",$2);print $2}')
echo "GATE d: Entry = $entry (expected $TEXT_START -- the bootrom's jump target)"
if [ "$entry" != "$TEXT_START" ]; then
    echo "### ERROR: Entry != $TEXT_START" >&2; rc=1
fi
kphys=$("$NM" "$out/fw_payload.elf" 2>/dev/null | awk '$3=="payload_bin"{print $1; exit}')
if [ -n "$kphys" ]; then
    echo "GATE d: payload_bin @ 0x$kphys"
    if [ $((0x$kphys % 0x200000)) -ne 0 ]; then
        echo "### ERROR: kernel load address not 2-MiB-aligned" >&2; rc=1
    fi
    if [ $((0x$kphys)) -lt $((TEXT_START)) ] || \
       [ $((0x$kphys)) -ge $((TEXT_START + MEMWIN)) ]; then
        echo "### ERROR: kernel load address outside the window" >&2; rc=1
    fi
else
    echo "### WARNING: symbol payload_bin not found" >&2
fi

if [ $rc -ne 0 ]; then echo "### PAYLOAD_FAIL" >&2; exit 1; fi
echo "### PAYLOAD_OK"
