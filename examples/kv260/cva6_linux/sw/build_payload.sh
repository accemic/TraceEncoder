#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# build_payload.sh -- build the OpenSBI fw_payload for the CVA6 Linux
# machine. Runs on a Linux build host, not on Windows.
#
#   ./build_payload.sh            # DTB + fw_payload.bin into out/
#
# WHY fw_payload and not fw_jump:
#   fw_jump jumps to a COMPILE-TIME constant (FW_JUMP_ADDR) and expects the
#   devicetree at a second one (FW_JUMP_FDT_ADDR). Both would have to match
#   exactly what we place into the window via devmem -- two addresses that
#   can silently be got wrong, with the symptom "the board says nothing".
#   fw_payload carries both the kernel AND the devicetree in itself: ONE
#   blob, ONE load address (0x6400_0000 = the core's BOOT_ADDR), no address
#   contract in between.
#
# Result: out/fw_payload.bin -- dd it to 0x6400_0000, set CONTROL b0, done.
set -e

here=$(cd "$(dirname "$0")" && pwd)
br="$here/buildroot"
img="$br/output/images"
host="$br/output/host"
out="$here/out"
# Load address == BOOT_ADDR in cva6_linux_soc_top == memory node in the DTS.
# A change here must happen at all three places.
TEXT_START=0x64000000

mkdir -p "$out"

# --- 1. Devicetree ---------------------------------------------------------
"$host/bin/dtc" -I dts -O dtb -o "$out/cva6_kv260.dtb" "$here/cva6_kv260.dts"
echo "DTB: $(stat -c%s "$out/cva6_kv260.dtb") bytes"

# --- 2. OpenSBI with the embedded kernel + DTB -----------------------------
# The OpenSBI source tree lives in the Buildroot build directory; we build a
# SECOND variant from it (fw_payload) without touching the Buildroot run.
sbi=$(ls -d "$br"/output/build/opensbi-* 2>/dev/null | head -1)
if [ -z "$sbi" ]; then echo "### ERROR: OpenSBI source tree not found" >&2; exit 1; fi
if [ ! -f "$img/Image" ]; then echo "### ERROR: $img/Image missing" >&2; exit 1; fi

cross="$host/bin/riscv32-buildroot-linux-musl-"
if [ ! -x "${cross}gcc" ]; then
    cross=$(ls "$host"/bin/riscv*-linux-*-gcc 2>/dev/null | head -1 | sed 's/gcc$//')
fi
if [ -z "$cross" ] || [ ! -x "${cross}gcc" ]; then
    echo "### ERROR: cross toolchain not found in $host/bin" >&2; exit 1
fi
echo "Toolchain: $cross"

make -C "$sbi" \
    CROSS_COMPILE="$cross" \
    PLATFORM=generic \
    PLATFORM_RISCV_XLEN=32 \
    PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
    PLATFORM_RISCV_ABI=ilp32 \
    FW_TEXT_START=$TEXT_START \
    FW_PAYLOAD=y \
    FW_PAYLOAD_PATH="$img/Image" \
    FW_FDT_PATH="$out/cva6_kv260.dtb" \
    O="$sbi/build-cva6" \
    -j"$(nproc)"

cp "$sbi/build-cva6/platform/generic/firmware/fw_payload.bin" "$out/"
cp "$sbi/build-cva6/platform/generic/firmware/fw_payload.elf" "$out/"
echo "PAYLOAD: $(stat -c%s "$out/fw_payload.bin") bytes -> load address $TEXT_START"

# --- 3. Gates --------------------------------------------------------------
# (a) The blob must fit into the CVA6 window (192 MiB starting at 0x6400_0000).
sz=$(stat -c%s "$out/fw_payload.bin")
lim=$((192 * 1024 * 1024))
if [ "$sz" -ge "$lim" ]; then
    echo "### ERROR: fw_payload.bin ($sz B) does not fit into 192 MiB" >&2; exit 1
fi
# (b) No compressed instruction in the firmware code -- same check as
#     check_images.sh for the kernel; the ITI/CTTE path cannot do RVC.
if "$host/bin/riscv32-buildroot-linux-musl-objdump" -d \
        "$out/fw_payload.elf" 2>/dev/null | grep -qE "^\s+[0-9a-f]+:\s+[0-9a-f]{4}\s+[a-z]"; then
    echo "### WARNING: possibly compressed instructions in fw_payload.elf" >&2
fi
echo "### PAYLOAD_OK"
