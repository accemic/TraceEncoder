#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# build_payload_rv64.sh -- build the OpenSBI fw_payload for the RV64 CVA6
# Linux machine. Runs on a Linux build host, not on Windows. ADDITIVE
# variant alongside build_payload.sh (in ../../cva6_linux/sw/); the RV32
# version stays unchanged.
#
#   ./build_payload_rv64.sh       # DTB + fw_payload.bin into out64/
#
# Environment variables (default in parentheses):
#   BR_SRC  Buildroot source tree        ($here/buildroot)
#   BR_OUT  Buildroot OUTPUT tree        ($here/out_rv64)
# The RV64 run is an out-of-tree build (make O=...) on the same source
# tree as RV32 -- shared dl/, separate .config and separate output trees.
# That is why images/host/build sit here ONE level higher than in the RV32
# path ($BR_OUT/images instead of buildroot/output/images).
#
# WHY fw_payload and not fw_jump (unchanged from the RV32 stage):
#   fw_jump jumps to a COMPILE-TIME constant (FW_JUMP_ADDR) and expects the
#   devicetree at a second one (FW_JUMP_FDT_ADDR). Both would have to match
#   exactly what we place into the window via devmem -- two addresses that
#   can silently be got wrong, with the symptom "the board says nothing".
#   fw_payload carries both the kernel AND the devicetree in itself: ONE
#   blob, ONE load address (0x6400_0000 = the core's BOOT_ADDR), no address
#   contract in between.
#
# Result: out64/fw_payload.bin -- dd it to 0x6400_0000, set CONTROL b0.
set -e

here=$(cd "$(dirname "$0")" && pwd)
brsrc="${BR_SRC:-$here/buildroot}"
bro="${BR_OUT:-$here/out_rv64}"
img="$bro/images"
host="$bro/host"
# OUT_DIR is ADDITIVE: without the variable the artifact lands unchanged in
# out64/. With OUT_DIR a second image (e.g. with a different workload) can
# be produced WITHOUT overwriting a reference payload pinned elsewhere.
out="${OUT_DIR:-$here/out64}"
# Load address == BOOT_ADDR in cva6_linux64_soc_top == memory node in the DTS.
# A change here must happen at all three places.
TEXT_START=0x64000000

mkdir -p "$out"

# --- 1. Devicetree ---------------------------------------------------------
"$host/bin/dtc" -I dts -O dtb -o "$out/cva6_kv260_rv64.dtb" "$here/cva6_kv260_rv64.dts"
echo "DTB: $(stat -c%s "$out/cva6_kv260_rv64.dtb") bytes"

# --- 2. OpenSBI with the embedded kernel + DTB -----------------------------
# The OpenSBI source tree lives in the Buildroot build directory; we build a
# SECOND variant from it (fw_payload) without touching the Buildroot run.
sbi=$(ls -d "$bro"/build/opensbi-* 2>/dev/null | head -1)
if [ -z "$sbi" ]; then echo "### ERROR: OpenSBI source tree not found" >&2; exit 1; fi
if [ ! -f "$img/Image" ]; then echo "### ERROR: $img/Image missing" >&2; exit 1; fi

cross="$host/bin/riscv64-buildroot-linux-gnu-"
if [ ! -x "${cross}gcc" ]; then
    cross=$(ls "$host"/bin/riscv64-*-linux-*-gcc 2>/dev/null | head -1 | sed 's/gcc$//')
fi
if [ -z "$cross" ] || [ ! -x "${cross}gcc" ]; then
    echo "### ERROR: RV64 cross toolchain not found in $host/bin" >&2; exit 1
fi
echo "Toolchain: $cross"

# ISA string derived from delta D6: XLEN 64, M implicit (CVA6 has no M
# switch), A = CVA6ConfigAExtEn 1, C = CVA6ConfigCExtEn 1 -- so rv64imac.
# NO f/d: CVA6ConfigRVF/RVD = 0 => ABI lp64.
# FW_PAYLOAD_OFFSET is NOT set: platform/generic/objects.mk already chooses
# 0x200000 at XLEN=64, and exactly that 2 MiB alignment is what the RV64
# kernel requires (BUG_ON(kernel_map.phys_addr % PMD_SIZE), arch/riscv/mm/init.c).
make -C "$sbi" \
    CROSS_COMPILE="$cross" \
    PLATFORM=generic \
    PLATFORM_RISCV_XLEN=64 \
    PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei \
    PLATFORM_RISCV_ABI=lp64 \
    FW_TEXT_START=$TEXT_START \
    FW_PAYLOAD=y \
    FW_PAYLOAD_PATH="$img/Image" \
    FW_FDT_PATH="$out/cva6_kv260_rv64.dtb" \
    O="$sbi/build-cva6-rv64" \
    -j"$(nproc)"

cp "$sbi/build-cva6-rv64/platform/generic/firmware/fw_payload.bin" "$out/"
cp "$sbi/build-cva6-rv64/platform/generic/firmware/fw_payload.elf" "$out/"
echo "PAYLOAD: $(stat -c%s "$out/fw_payload.bin") bytes -> load address $TEXT_START"

# --- 3. Gates --------------------------------------------------------------
rc=0
RE="$host/bin/riscv64-buildroot-linux-gnu-readelf"
OD="$host/bin/riscv64-buildroot-linux-gnu-objdump"
NM="$host/bin/riscv64-buildroot-linux-gnu-nm"

# (a) The blob must fit into the CVA6 window (192 MiB starting at 0x6400_0000).
sz=$(stat -c%s "$out/fw_payload.bin")
lim=$((192 * 1024 * 1024))
if [ "$sz" -ge "$lim" ]; then
    echo "### ERROR: fw_payload.bin ($sz B) does not fit into 192 MiB" >&2; rc=1
else
    echo "GATE a: size $sz B < $lim B (192 MiB) -- OK"
fi

# (b) ELF class and machine: must be ELF64 RISC-V.
cls=$("$RE" -h "$out/fw_payload.elf" | awk -F: '/^  Class/{gsub(/ /,"",$2);print $2}')
mach=$("$RE" -h "$out/fw_payload.elf" | awk -F: '/^  Machine/{sub(/^ +/,"",$2);print $2}')
echo "GATE b: Class=$cls Machine=$mach"
if [ "$cls" != "ELF64" ]; then echo "### ERROR: not ELF64" >&2; rc=1; fi
case "$mach" in *RISC-V*) ;; *) echo "### ERROR: not RISC-V" >&2; rc=1;; esac

# (c) ISA attribute of the LINKED artifact -- not the configuration, but
#     what actually ended up in it. Must contain c (the core has C) and
#     must NOT contain f/d (no FPU).
arch=$("$RE" -A "$out/fw_payload.elf" 2>/dev/null \
       | awk -F'"' '/Tag_RISCV_arch/{print $2; exit}')
echo "GATE c: Tag_RISCV_arch = ${arch:-<empty>}"
if [ -z "$arch" ]; then
    echo "### ERROR: no Tag_RISCV_arch in the ELF" >&2; rc=1
else
    case "$arch" in rv64*) ;; *) echo "### ERROR: ISA attribute is not rv64*" >&2; rc=1;; esac
    case "$arch" in *_f*|*_d[0-9]*) echo "### ERROR: F/D in the ISA attribute -- the core has no FPU!" >&2; rc=1;; esac
    case "$arch" in *_c[0-9]*) ;; *) echo "### WARNING: no c in the ISA attribute (the core has C)" >&2;; esac
fi

# (d) RVC gate, ADAPTED against the RV32 version.
#     RV32 forbade compressed instructions, because cv32a6_ima_sv32_fpga
#     has no C. cv64a6_imac_sv39_ctrace HAS C (CVA6ConfigCExtEn = 1) -- an
#     RVC ban would be factually wrong here. The matching gate is the
#     counterpart: NO floating-point instructions in the firmware text.
#     Only .text is checked (the embedded kernel sits as DATA in its own
#     section; disassembling it too produces exactly the false positives
#     that only stayed a warning in the RV32 script).
# -M no-aliases: see check_images_rv64.sh -- without the flag alias forms
# (fneg./fabs.) hide the base mnemonic fsgnj*.
fp=$("$OD" -d -M no-aliases -j .text "$out/fw_payload.elf" 2>/dev/null | awk '
    $3 ~ /^(flw|fld|flq|fsw|fsd|fsq|fsgnj|fadd\.|fsub\.|fmul\.|fdiv\.|fsqrt\.|fmin\.|fmax\.|fmadd\.|fmsub\.|fnmadd\.|fnmsub\.|fcvt\.|fmv\.|feq\.|flt\.|fle\.|fclass\.)/ { c++ }
    END { print c+0 }')
echo "GATE d: floating-point instructions in .text = $fp (RVC is allowed, the core has C)"
if [ "$fp" -gt 0 ]; then
    echo "### ERROR: floating-point instructions in the firmware text" >&2; rc=1
fi

# (e) Load address of the kernel in the payload -- for make_listing_rv64.sh
#     and the board run. Must be 2 MiB aligned (RV64 kernel BUG_ON).
kphys=$("$NM" "$out/fw_payload.elf" 2>/dev/null | awk '$3=="payload_bin"{print $1; exit}')
if [ -n "$kphys" ]; then
    echo "GATE e: payload_bin @ 0x$kphys"
    if [ $((0x$kphys % 0x200000)) -ne 0 ]; then
        echo "### ERROR: kernel load address not 2 MiB aligned" >&2; rc=1
    fi
else
    echo "### WARNING: symbol payload_bin not found" >&2
fi

if [ $rc -ne 0 ]; then echo "### PAYLOAD_FAIL" >&2; exit 1; fi
echo "### PAYLOAD_OK"
