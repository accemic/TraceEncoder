#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# m5_qemu_sanity_rocket2.sh -- sanity boot of the TWO-HART payload under QEMU
# (package M5). Runs on a Linux build host (<linux-build-host>).
#
#   ./m5_qemu_sanity_rocket2.sh [seconds]      # default 120
#
# WHAT THIS RUN PROVES -- AND WHAT IT DOES NOT:
#
#   PROVES:   that our TWO-HART devicetree, the OpenSBI binding, and the L1
#             kernel together produce an SMP boot: `Platform HART Count`,
#             both harts in OpenSBI, `smp: Brought up ... 2 CPUs`, two
#             entries in /proc/cpuinfo. That is exactly the question the
#             whole proof hinges on (M4 §4d: the hart count comes from the
#             DTS, not from the hardware) -- and it is answerable without
#             a board.
#
#   DOES NOT PROVE OUR SoC. QEMU provides its own machine; the Rocket
#             generat, its bootrom, its bus decoding, the funnel, and both
#             encoders are NOT involved in this run. The board run remains
#             the proof; this run only rules out that a DTS/OpenSBI question
#             shows up at the board as a hardware fault.
#
# Twin of qemu_sanity_rocket.sh (package L2, see
# ../../rocket_linux/sw/qemu_sanity_rocket.sh), two differences:
#   1. Source is rocket2_kv260_rv64.dts (two cpu nodes).
#   2. `-smp 2`. Without this, QEMU would have ONE hart while the
#      devicetree describes two -- the run would then answer the wrong
#      question.
# The three sed deltas (console address/layout, timebase) are unchanged
# QEMU properties and rationalized in the L2 header.
set -e

secs="${1:-120}"
here=$(cd "$(dirname "$0")" && pwd)
l1="${L1_OUT:-$HOME/cva6_linux/out_rv64}"
host="$l1/host"
out="$here/out_qemu_rocket2"
qemu="$host/bin/qemu-system-riscv64"

mkdir -p "$out"
[ -x "$qemu" ] || { echo "### ERROR: $qemu missing" >&2; exit 1; }

sed -e 's/0x60010000/0x10000000/g' \
    -e 's/serial@60010000/serial@10000000/g' \
    -e 's/timebase-frequency = <750000>/timebase-frequency = <10000000>/' \
    -e 's/uart8250,mmio32,/uart8250,mmio,/' \
    -e 's/reg-shift = <2>/reg-shift = <0>/' \
    -e 's/reg-io-width = <4>/reg-io-width = <1>/' \
    "$here/rocket2_kv260_rv64.dts" > "$out/rocket2_qemu_virt_rv64.dts"

echo "DTS deltas (lines, < and > combined): $(diff "$here/rocket2_kv260_rv64.dts" \
      "$out/rocket2_qemu_virt_rv64.dts" | grep -c '^[<>]' || true)"

"$host/bin/dtc" -I dts -O dtb -o "$out/rocket2_qemu_virt_rv64.dtb" \
    "$out/rocket2_qemu_virt_rv64.dts"

sbi=$(ls -d "$l1"/build/opensbi-* 2>/dev/null | head -1)
cross="$host/bin/riscv64-buildroot-linux-gnu-"
make -C "$sbi" \
    CROSS_COMPILE="$cross" \
    PLATFORM=generic PLATFORM_RISCV_XLEN=64 \
    PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei PLATFORM_RISCV_ABI=lp64 \
    FW_TEXT_START=0x80000000 FW_PAYLOAD=y \
    FW_PAYLOAD_PATH="$l1/images/Image" \
    FW_FDT_PATH="$out/rocket2_qemu_virt_rv64.dtb" \
    O="$here/opensbi-build-qemu-r2" -j"$(nproc)" >"$out/build.log" 2>&1
cp "$here/opensbi-build-qemu-r2/platform/generic/firmware/fw_payload.bin" "$out/"
echo "PAYLOAD (QEMU variant, 2 harts): $(stat -c%s "$out/fw_payload.bin") bytes"

# -smp 2: QEMU must provision as many harts as the devicetree describes.
set +e
timeout "$secs" "$qemu" -M virt -smp 2 -m 192M -nographic \
    -bios "$out/fw_payload.bin" 2>&1 | tee "$out/qemu_rocket2.log"
rc=$?
set -e
echo "QEMU-EXIT=$rc (124 = timeout at the prompt, intended)"

# --- Gates: the SMP statements WORD-FOR-WORD from the boot output ----------
log="$out/qemu_rocket2.log"
fail=0
show() { grep -aE "$1" "$log" | head -${2:-3} || true; }
echo "--- OpenSBI ---"; show 'Platform HART Count|Boot HART ID|Domain0 Next|HART Count'
echo "--- Kernel SMP ---"; show 'smp:|SMP:|Brought up|CPU[0-9]|riscv: base ISA|processor'
echo "--- cpuinfo ---"; show 'hart\s*:|processor\s*:' 8

if grep -aqE 'Platform HART Count *: *2' "$log"; then
  echo "### M5_QEMU PASS: OpenSBI reports 2 harts"
else
  echo "### M5_QEMU FAIL: 'Platform HART Count : 2' not in the output"; fail=1
fi
if grep -aqE 'smp: Brought up .* 2 CPUs' "$log"; then
  echo "### M5_QEMU PASS: Linux brought up 2 CPUs"
else
  echo "### M5_QEMU FAIL: 'smp: Brought up ... 2 CPUs' not in the output"; fail=1
fi
[ $fail -eq 0 ] && echo "### M5_QEMU_VERDICT PASS" || echo "### M5_QEMU_VERDICT FAIL"
exit $fail
