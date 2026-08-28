#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# qemu_sanity_rocket.sh -- sanity boot of the L2 payload under QEMU (package L2).
#
#   ./qemu_sanity_rocket.sh [seconds]      # default 120
#
# WHAT THIS RUN PROVES -- AND WHAT IT DOES NOT:
#
#   PROVES:   our devicetree (structure, ISA strings, Sv39 enforcement,
#             memory@0x8000_0000 +192 MiB, CLINT @0x0200_0000, PLIC
#             @0x0C00_0000), the OpenSBI binding (FW_TEXT_START, embedded
#             FDT, 2-MiB kernel offset), and the L1 kernel fit together and
#             boot to the login prompt.
#
#   DOES NOT PROVE OUR SoC. QEMU provides its own machine; the Rocket
#             generat, its bootrom, its bus decoding, and the still-missing
#             console IP are NOT involved in this run. The SoC proof is the
#             XSIM run (or, later, the board).
#
# TWO DELTAS against rocket_kv260_rv64.dts, both QEMU properties, both
# produced via sed (no second source of truth -- the target DTS stays the
# source):
#
#   1. Console address 0x6001_0000 -> 0x1000_0000.
#      On the Rocket, the console must sit in the MMIO window
#      (0x4000_0000..0x7FFF_FFFF, system-nexys-video.v:629-632); QEMU virt
#      has its 16550 fixed at 0x1000_0000. An access to 0x6001_0000 would be
#      an access to unpopulated memory in QEMU.
#   2. timebase-frequency 750000 -> 10000000.
#      On the Rocket it is necessarily clock-frequency/100 (fixed /100
#      divider in the generat, :99468-99470); QEMU's CLINT ticks at 10 MHz.
#      With the wrong value, all kernel timings run wrong.
#   3. Console register layout: reg-shift 2 -> 0, reg-io-width 4 -> 1,
#      earlycon type "mmio32" -> "mmio".
#      Our 8250 block (cva6_linux_periph.sv) hangs off a 64-bit AXI and lays
#      the registers out on a 32-bit grid; QEMU's virt UART is a
#      byte-addressed 16550 without a shift. Without this delta, earlycon
#      writes to the wrong offsets (LSR at +0x14 instead of +0x05) and the
#      run stays SILENT -- exactly as observed on the first attempt
#      (qemu_rocket.log, 90 s without a single character).
#
# Everything else -- memory base, size, CLINT and PLIC address, ISA, Sv39,
# bootargs -- is IDENTICAL to the target DTB. That is not a coincidence: the
# Rocket map matches QEMU virt in exactly these points.
set -e

secs="${1:-120}"
here=$(cd "$(dirname "$0")" && pwd)
l1="${L1_OUT:-$HOME/cva6_linux/out_rv64}"
host="$l1/host"
out="$here/out_qemu"
qemu="$host/bin/qemu-system-riscv64"

mkdir -p "$out"
[ -x "$qemu" ] || { echo "### ERROR: $qemu missing (BR2_PACKAGE_HOST_QEMU)" >&2; exit 1; }

# --- 1. QEMU variant of the DTS (two sed deltas, see header) ----------------
sed -e 's/0x60010000/0x10000000/g' \
    -e 's/serial@60010000/serial@10000000/g' \
    -e 's/timebase-frequency = <750000>/timebase-frequency = <10000000>/' \
    -e 's/uart8250,mmio32,/uart8250,mmio,/' \
    -e 's/reg-shift = <2>/reg-shift = <0>/' \
    -e 's/reg-io-width = <4>/reg-io-width = <1>/' \
    "$here/rocket_kv260_rv64.dts" > "$out/rocket_qemu_virt_rv64.dts"

# Counter-check: EXACTLY the intended lines must differ.
ndiff=$(diff "$here/rocket_kv260_rv64.dts" "$out/rocket_qemu_virt_rv64.dts" \
        | grep -c '^[<>]' || true)
echo "DTS deltas (lines, < and > combined): $ndiff"
diff "$here/rocket_kv260_rv64.dts" "$out/rocket_qemu_virt_rv64.dts" \
    | grep -E '^[<>].*(0x[16]0010000|timebase-frequency|serial@)' || true

"$host/bin/dtc" -I dts -O dtb -o "$out/rocket_qemu_virt_rv64.dtb" \
    "$out/rocket_qemu_virt_rv64.dts"

# --- 2. fw_payload with THIS DTB (otherwise identical binding) -------------
sbi=$(ls -d "$l1"/build/opensbi-* 2>/dev/null | head -1)
cross="$host/bin/riscv64-buildroot-linux-gnu-"
make -C "$sbi" \
    CROSS_COMPILE="$cross" \
    PLATFORM=generic PLATFORM_RISCV_XLEN=64 \
    PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei PLATFORM_RISCV_ABI=lp64 \
    FW_TEXT_START=0x80000000 FW_PAYLOAD=y \
    FW_PAYLOAD_PATH="$l1/images/Image" \
    FW_FDT_PATH="$out/rocket_qemu_virt_rv64.dtb" \
    O="$here/opensbi-build-qemu" -j"$(nproc)" >"$out/build.log" 2>&1
cp "$here/opensbi-build-qemu/platform/generic/firmware/fw_payload.bin" "$out/"
echo "PAYLOAD (QEMU variant): $(stat -c%s "$out/fw_payload.bin") bytes"

# --- 3. Boot -----------------------------------------------------------------
# -bios loads at 0x8000_0000 == FW_TEXT_START; -m 192M == the memory node.
# A timeout kill (124) at the login prompt is the EXPECTED end.
set +e
timeout "$secs" "$qemu" -M virt -m 192M -nographic \
    -bios "$out/fw_payload.bin"
rc=$?
set -e
echo "QEMU-EXIT=$rc (124 = timeout at the prompt, intended)"
