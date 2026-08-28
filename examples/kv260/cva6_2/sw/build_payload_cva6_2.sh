#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# build_payload_cva6_2.sh -- build the TWO guest images of the AMP two-core
# CVA6 demonstrator. Runs on a Linux build host, not on the board.
#
#   L1_OUT=~/cva6_linux/out_rv64 ./build_payload_cva6_2.sh
#   OUT_DIR=/tmp/cva6_2 ./build_payload_cva6_2.sh
#
# WHY THIS SCRIPT EXISTS. Until 2026-08-19 this directory's README said "no
# dedicated two-core payload-build script exists" and pointed at a manual
# procedure. That is a gap with teeth: the two images differ in exactly two
# places, and getting either of them wrong produces a guest that either does
# not boot at all or -- worse -- boots into the OTHER core's window and
# corrupts it silently.
#
# THE ADDRESS TRAP -- read this before changing anything. There are TWO
# views of the same memory and they do NOT agree:
#
#   core-side view   BOTH cores enter at 0x6400_0000. cva6_2_soc_top's
#                    BOOT_ADDR is one parameter for both ("Core-side view of
#                    the private RAM (both cores the same)"), and both guest
#                    device trees carry memory@64000000 accordingly.
#   PS-side view     core 0's window is at 0x6400_0000, core 1's at
#                    0x6600_0000 (PS_DRAM0/PS_DRAM1). That is where the
#                    payload gets WRITTEN from the board.
#
# So both images are linked at FW_TEXT_START=0x6400_0000 and differ only in
# their device tree (which hart is "okay", which is "disabled"). Linking
# core 1 at 0x6600_0000 -- the obvious-looking choice -- produces an image
# that its core enters at 0x6400_0000 and abandons after a handful of
# instructions. Measured on the board 2026-08-19: core 1 retired 14
# instructions and emitted no console output at all, while core 0 booted
# normally; the CTTE capture showed 447,245 instructions on SRC 0 and
# zero on SRC 1.
#
# Both reuse the RV64 Buildroot output of ../cva6_linux64/ -- the kernel and
# the root filesystem are identical, only OpenSBI is rebuilt around a
# different device tree and a different FW_TEXT_START. That is a one-minute
# make, not a Buildroot run, which is why this script does not carry a
# Buildroot stage of its own: a second full build would be a second thing to
# keep in sync for no benefit.
#
# CORRESPONDENCE RULE. The load addresses here MUST match, per core, the
# memory node of the respective .dts AND the PS_DRAM0/PS_DRAM1 parameters of
# rtl/cva6_2_soc_top.sv. A change belongs in all three places; the gates at
# the end of this script check the first two against each other.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
l1="${L1_OUT:-$HOME/cva6_linux/out_rv64}"
out="${OUT_DIR:-$here/out_cva6_2}"

# Where OpenSBI puts the devicetree at RUNTIME -- and the single reason this
# example did not boot until 2026-08-21.
#
# PLATFORM=generic defaults FW_PAYLOAD_FDT_OFFSET to FW_JUMP_FDT_OFFSET =
# 0x2200000 (34 MiB, platform/generic/objects.mk). fw_next_arg1() then returns
# _fw_start + 34 MiB, fw_base.S COPIES the embedded blob there, and
# fdt_get_address() hands that address to everything after fw_platform_init().
# Each guest here owns 32 MiB, so the default lands 2 MiB PAST the end of the
# window -- in this AMP design inside the other core's RAM. The symptom is as
# quiet as it gets: fdt_path_offset(fdt, "/chosen") fails, no serial driver is
# found, and the hart parks in sbi_hart_hang without a single console
# character. Measured on the board, decoded from the trace.
#
# 31 MiB instead: above the payload (16.88 MiB), 1 MiB below the window end.
# If the payload ever grows past 31 MiB this has to move -- and the guest
# would be out of room anyway.
fdt_offset=${FDT_OFFSET:-0x01F00000}
host="$l1/host"
img="$l1/images"

[ -d "$host/bin" ] || { echo "### ERROR: RV64 toolchain not found: $host/bin" >&2; exit 1; }
[ -f "$img/Image" ] || { echo "### ERROR: kernel image not found: $img/Image" >&2; exit 1; }
sbi=$(ls -d "$l1"/build/opensbi-* 2>/dev/null | head -1)
[ -n "$sbi" ] || { echo "### ERROR: OpenSBI source tree not found under $l1/build" >&2; exit 1; }

cross="$host/bin/riscv64-buildroot-linux-gnu-"
[ -x "${cross}gcc" ] || cross=$(ls "$host"/bin/riscv64-*-linux-*-gcc 2>/dev/null | head -1 | sed 's/gcc$//')
[ -n "$cross" ] && [ -x "${cross}gcc" ] || { echo "### ERROR: RV64 cross toolchain not found" >&2; exit 1; }

mkdir -p "$out"
echo "OpenSBI: $sbi"
echo "Kernel:  $img/Image"
echo "Output:  $out"

rc=0
for c in 0 1; do
    # Same entry address for both -- see "THE ADDRESS TRAP" above.
    text_start=0x64000000
    case $c in
    0) ps_addr=0x64000000 ;;
    1) ps_addr=0x66000000 ;;
    esac
    dts="$here/cva6_2_kv260_core${c}.dts"
    [ -f "$dts" ] || { echo "### ERROR: $dts missing" >&2; exit 1; }

    # Gate 1: the device tree's memory node must carry the CORE-side base.
    # This is the gate that catches the address trap: a device tree written
    # against the PS-side address would describe memory the core cannot see.
    want=$(printf '%x' $((text_start)))
    if ! grep -q "memory@${want}" "$dts"; then
        echo "### ERROR: $dts has no memory@${want} node -- both guest device" >&2
        echo "    trees must describe the CORE-side base $text_start, not the" >&2
        echo "    PS-side window address." >&2
        rc=1; continue
    fi

    "$host/bin/dtc" -I dts -O dtb -o "$out/core${c}.dtb" "$dts" 2>/dev/null
    echo "core$c DTB: $(stat -c%s "$out/core${c}.dtb") bytes, memory@${want} OK"

    make -s -C "$sbi" \
        CROSS_COMPILE="$cross" \
        PLATFORM=generic \
        PLATFORM_RISCV_XLEN=64 \
        PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei \
        PLATFORM_RISCV_ABI=lp64 \
        FW_TEXT_START=$text_start \
        FW_PAYLOAD=y \
        FW_PAYLOAD_PATH="$img/Image" \
        FW_FDT_PATH="$out/core${c}.dtb" \
        FW_PAYLOAD_FDT_OFFSET=$fdt_offset \
        O="$sbi/build-cva6-2-core${c}" \
        -j"$(nproc)"

    cp "$sbi/build-cva6-2-core${c}/platform/generic/firmware/fw_payload.bin" "$out/fw_payload_core${c}.bin"
    cp "$sbi/build-cva6-2-core${c}/platform/generic/firmware/fw_payload.elf" "$out/fw_payload_core${c}.elf"

    # Gate 2: the linked entry point must BE the load address. objdump running
    # through is not proof -- an empty address range produces a valid file.
    entry=$("$host/bin/riscv64-buildroot-linux-gnu-readelf" -h "$out/fw_payload_core${c}.elf" |
            awk '/Entry point address/{print $NF}')
    if [ "$((entry))" -eq "$((text_start))" ]; then
        echo "core$c PAYLOAD: $(stat -c%s "$out/fw_payload_core${c}.bin") bytes, entry $entry OK -> write to PS $ps_addr"
    else
        echo "### ERROR: core$c entry $entry != $text_start" >&2; rc=1
    fi
done

[ $rc -eq 0 ] || { echo "### PAYLOAD_FAIL" >&2; exit 1; }

# Gate 3: the two images must actually DIFFER. Building twice with the same
# device tree by accident would produce two identical guests fighting over
# one window, and every symptom of that is a memory-corruption symptom.
if cmp -s "$out/fw_payload_core0.bin" "$out/fw_payload_core1.bin"; then
    echo "### ERROR: both images are byte-identical -- the per-core DTS did not take" >&2
    exit 1
fi
echo "### PAYLOAD_OK -> $out/fw_payload_core0.bin + fw_payload_core1.bin"
echo "Write core0 to PS 0x6400_0000 and core1 to PS 0x6600_0000; the board"
echo "runner examples/kv260/cva6_2/board/cva6_2_run.sh does that for you."
