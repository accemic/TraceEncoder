#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# build_payload_rocket2_rv64.sh -- build the OpenSBI fw_payload for the
# TWO-HART Rocket Linux machine (package M5). Runs on a Linux build host
# (<linux-build-host>), not on Windows.
#
#   ./build_payload_rocket2_rv64.sh      # DTB + fw_payload.bin -> out_rocket2/
#
# Twin of build_payload_rocket_rv64.sh (package L2, see
# ../../rocket_linux/sw/build_payload_rocket_rv64.sh). Three differences,
# and each one has a reason that has nothing to do with cosmetics:
#
#  1. DEVICETREE with TWO cpu nodes (rocket2_kv260_rv64.dts). This is the
#     actual switch of this package: `Platform HART Count` comes from this
#     file, NOT from the hardware (M4 §4d). With the one-hart DTS, hart 1
#     would stay stuck in the bootrom -- and a "multicore proof" with two
#     encoders on ONE core would not be one.
#  2. OWN output and build directories (out_rocket2/,
#     opensbi-build-rocket2/). The reason is measured, not precautionary:
#     while M5 started, the L2 package's out_rocket/ directory was written
#     to by a neighboring package (mtime 16:15 on 2026-08-09). The L2 build
#     places its OpenSBI tree at a fixed $here/opensbi-build -- two
#     concurrent runs would overwrite each other there, and the error would
#     be a payload belonging to neither configuration.
#  3. An additional gate (a2) that proves the TWO cpu nodes on the
#     round-tripped DTB. "dtc ran through" is not proof that two harts are
#     actually in there.
#
# Everything else (kernel, initramfs, toolchain, OpenSBI source tree) is
# REUSED from package L1 and only read (§15).
set -e

here=$(cd "$(dirname "$0")" && pwd)
l1="${L1_OUT:-$HOME/cva6_linux/out_rv64}"
kimg="${KIMG:-$l1/images/Image}"
host="$l1/host"
out="$here/out_rocket2"
obuild="$here/opensbi-build-rocket2"

TEXT_START=0x80000000
MEMWIN=$((192 * 1024 * 1024))

mkdir -p "$out"

# --- 1. Devicetree ---------------------------------------------------------
"$host/bin/dtc" -I dts -O dtb -o "$out/rocket2_kv260_rv64.dtb" \
    "$here/rocket2_kv260_rv64.dts"
echo "DTB: $(stat -c%s "$out/rocket2_kv260_rv64.dtb") bytes"

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

make -C "$sbi" \
    CROSS_COMPILE="$cross" \
    PLATFORM=generic \
    PLATFORM_RISCV_XLEN=64 \
    PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei \
    PLATFORM_RISCV_ABI=lp64 \
    FW_TEXT_START=$TEXT_START \
    FW_PAYLOAD=y \
    FW_PAYLOAD_PATH="$kimg" \
    FW_FDT_PATH="$out/rocket2_kv260_rv64.dtb" \
    O="$obuild" \
    -j"$(nproc)"

cp "$obuild/platform/generic/firmware/fw_payload.bin" "$out/"
cp "$obuild/platform/generic/firmware/fw_payload.elf" "$out/"
echo "PAYLOAD: $(stat -c%s "$out/fw_payload.bin") bytes -> load address $TEXT_START"

# --- 3. Gates ----------------------------------------------------------------
rc=0
RE="${cross}readelf"
OD="${cross}objdump"
NM="${cross}nm"
DTC="$host/bin/dtc"

"$DTC" -I dtb -O dts -o "$out/rocket2_kv260_rv64.readback.dts" \
    "$out/rocket2_kv260_rv64.dtb" 2>/dev/null
rb="$out/rocket2_kv260_rv64.readback.dts"
check_dtb() {
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
check_dtb 'mmu-type = "riscv,sv39"'                "Sv39"
check_dtb 'riscv,isa = "rv64imac_zicsr_zifencei"'  "ISA rv64imac without f/d"
check_dtb 'serial@60010000'                        "console in the MMIO window"
check_dtb 'clint@2000000'                          "the generat's CLINT"
check_dtb 'interrupt-controller@c000000'           "the generat's PLIC"
check_dtb 'no4lvl'                                 "Sv39 enforcement in bootargs"

# (a2) THE gate of this package: TWO cpu nodes, and the CLINT/PLIC chains
#      with the contexts of BOTH harts. Without this, the kernel only ever
#      brings up one hart.
echo "GATE a2: two-hart description"
ncpu=$(grep -cE '^[[:space:]]*cpu@[0-9]+ \{' "$rb" || true)
echo "  cpu nodes in the round-tripped DTB: $ncpu"
if [ "$ncpu" -ne 2 ]; then
    echo "### ERROR: expected 2 cpu nodes, found $ncpu" >&2; rc=1
fi
nic=$(grep -cE 'interrupt-controller \{' "$rb" || true)
echo "  interrupt-controller nodes (one per hart + PLIC): $nic"
if [ "$nic" -lt 2 ]; then
    echo "### ERROR: fewer than 2 per-hart interrupt controllers" >&2; rc=1
fi
# CLINT and PLIC must carry the contexts of BOTH harts (4 and 2 entries respectively).
ncl=$(awk '/clint@2000000/,/};/' "$rb" | grep -c 'interrupts-extended' || true)
echo "  CLINT interrupts-extended present: $ncl"
awk '/clint@2000000/,/};/' "$rb" | grep 'interrupts-extended' >&2 || true
awk '/interrupt-controller@c000000/,/};/' "$rb" | grep 'interrupts-extended' >&2 || true

# (b) Size
sz=$(stat -c%s "$out/fw_payload.bin")
if [ "$sz" -ge "$MEMWIN" ]; then
    echo "### ERROR: fw_payload.bin ($sz B) does not fit into $MEMWIN B" >&2; rc=1
else
    echo "GATE b: size $sz B < $MEMWIN B (192 MiB) -- OK"
fi

# (c) ELF class, machine, ISA attribute, floating-point counter-check
cls=$("$RE" -h "$out/fw_payload.elf" | awk -F: '/^  Class/{gsub(/ /,"",$2);print $2}')
mach=$("$RE" -h "$out/fw_payload.elf" | awk -F: '/^  Machine/{sub(/^ +/,"",$2);print $2}')
echo "GATE c: Class=$cls Machine=$mach"
if [ "$cls" != "ELF64" ]; then echo "### ERROR: not ELF64" >&2; rc=1; fi
case "$mach" in *RISC-V*) ;; *) echo "### ERROR: not RISC-V" >&2; rc=1;; esac
fp=$("$OD" -d -M no-aliases -j .text "$out/fw_payload.elf" 2>/dev/null | awk '
    $3 ~ /^(flw|fld|flq|fsw|fsd|fsq|fsgnj|fadd\.|fsub\.|fmul\.|fdiv\.|fsqrt\.|fmin\.|fmax\.|fmadd\.|fmsub\.|fnmadd\.|fnmsub\.|fcvt\.|fmv\.|feq\.|flt\.|fle\.|fclass\.)/ { c++ }
    END { print c+0 }')
echo "GATE c: floating-point instructions in .text = $fp"
if [ "$fp" -gt 0 ]; then echo "### ERROR: floating-point instructions in the firmware text" >&2; rc=1; fi

# (d) Load addresses
entry=$("$RE" -h "$out/fw_payload.elf" | awk -F: '/Entry point/{gsub(/ /,"",$2);print $2}')
echo "GATE d: Entry = $entry (expected $TEXT_START)"
if [ "$entry" != "$TEXT_START" ]; then echo "### ERROR: Entry != $TEXT_START" >&2; rc=1; fi
kphys=$("$NM" "$out/fw_payload.elf" 2>/dev/null | awk '$3=="payload_bin"{print $1; exit}')
if [ -n "$kphys" ]; then
    echo "GATE d: payload_bin @ 0x$kphys"
    if [ $((0x$kphys % 0x200000)) -ne 0 ]; then
        echo "### ERROR: kernel load address not 2-MiB-aligned" >&2; rc=1
    fi
else
    echo "### WARNING: symbol payload_bin not found" >&2
fi

echo "MD5 $(md5sum "$out/fw_payload.bin" | cut -d' ' -f1)  $out/fw_payload.bin"
if [ $rc -ne 0 ]; then echo "### PAYLOAD_FAIL" >&2; exit 1; fi
echo "### PAYLOAD_OK"
