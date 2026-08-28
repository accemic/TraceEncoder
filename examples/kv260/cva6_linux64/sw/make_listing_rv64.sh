#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# make_listing_rv64.sh -- merged decoder listing for the RV64 Linux boot.
# Runs on a Linux build host. ADDITIVE variant alongside make_listing.sh
# (in ../../cva6_linux/sw/); the RV32 version stays unchanged.
#
#   ./make_listing_rv64.sh        # -> out64/merged.dis
#
# A boot capture runs through THREE address spaces, and the decoder needs a
# listing for each:
#
#   1. OpenSBI            0x6400_0000          physical == virtual (M-mode)
#   2. kernel EARLY        0x6420_0000          physical, until satp is set
#   3. kernel AFTER MMU    0xFFFFFFFF8000_0000  virtual (the ITI reports virtual PCs)
#
# Difference to the RV32 version -- both addresses are NEW and are NOT
# guessed, but read from the artifacts:
#   * 0x6420_0000 = FW_TEXT_START + FW_PAYLOAD_OFFSET. OpenSBI chooses the
#     offset 0x20_0000 for XLEN=64 (platform/generic/objects.mk) -- 2 MiB,
#     because the RV64 kernel demands exactly that
#     (BUG_ON(kernel_map.phys_addr % PMD_SIZE), arch/riscv/mm/init.c). Read
#     here from the symbol payload_bin.
#   * 0xFFFFFFFF8000_0000 = KERNEL_LINK_ADDR = ADDRESS_SPACE_END - SZ_2G + 1
#     (arch/riscv/include/asm/pgtable.h). RV64 does NOT place the kernel at
#     PAGE_OFFSET, but into the topmost 2 GiB -- the RV32 constant
#     0xC000_0000 would be completely wrong here. Read here from the ELF
#     entry point.
#
# WHY bash and not sh like the RV32 path: the kernel addresses sit above
# 2^53. awk computes with doubles (strtonum) and rounds
# 0xFFFFFFFF80ABC000 to 2 KiB multiples -- the section boundary would then
# be silently wrong. All address arithmetic therefore runs in the shell's
# 64-bit integer arithmetic.
#
# Point 2 is why objcopy --change-addresses is used: merely rewriting the
# address column is NOT enough -- the jump targets in the text would still
# point at the virtual addresses and the decoder would search for them
# there in vain ("No entry in -pcinfo found @...", finding 2026-07-27 04:35
# from the RV32 stage).
#
# Userspace is deliberately NOT included: its pages sit at run-dependent
# virtual addresses (PIE + ASLR). Decoding into it needs the mapping from
# /proc/<pid>/maps per process.
set -e

here=$(cd "$(dirname "$0")" && pwd)
bro="${BR_OUT:-$here/out_rv64}"
# OUT_DIR is ADDITIVE -- without the variable unchanged out64/.
out="${OUT_DIR:-$here/out64}"
host="$bro/host"
B="$host/bin/riscv64-buildroot-linux-gnu"
V=$(ls -d "$bro"/build/linux-*/vmlinux 2>/dev/null | head -1)

[ -n "$V" ] || { echo "### ERROR: vmlinux not found" >&2; exit 1; }
[ -f "$out/fw_payload.elf" ] || { echo "### ERROR: out64/fw_payload.elf missing (build_payload_rv64.sh)" >&2; exit 1; }
mkdir -p "$out"

# --- Read addresses from the artifacts ---------------------------------
# Virtual base of the kernel: ELF entry point of vmlinux (== _start == KERNEL_LINK_ADDR).
kv_hex=$("$B-readelf" -h "$V" | awk '/Entry point address/{print $NF}')
KERN_VIRT=$(( kv_hex ))
# Physical load address: the symbol payload_bin in the fw_payload ELF.
kp_hex=0x$("$B-nm" "$out/fw_payload.elf" | awk '$3=="payload_bin"{print $1; exit}')
[ "$kp_hex" != "0x" ] || { echo "### ERROR: symbol payload_bin missing in fw_payload.elf" >&2; exit 1; }
KERN_PHYS=$(( kp_hex ))
printf 'Kernel virtual %s / physical %s\n' "$kv_hex" "$kp_hex"
if (( KERN_PHYS % 0x200000 != 0 )); then
    echo "### ERROR: physical kernel address not 2 MiB aligned" >&2; exit 1
fi

# How far the executable kernel reaches -- NOT guessed, but derived from the
# ELF. With an estimated boundary in the RV32 stage, .init.text was
# missing, and the decode broke off right in setup_vm -- the function that
# sets up the early page tables and therefore still runs physically.
# Computed in OFFSETS to the virtual base (small, exact numbers).
max_off=0
while read -r _idx name size vma _rest; do
    case "$name" in *text*) ;; *) continue;; esac
    [ -n "${vma:-}" ] || continue
    off=$(( 0x$vma - KERN_VIRT + 0x$size ))
    (( off > max_off )) && max_off=$off
done < <("$B-objdump" -h "$V" | awk 'NF>=7 && $1 ~ /^[0-9]+$/ {print $1, $2, $3, $4, $5}')
(( max_off > 0 )) || { echo "### ERROR: no *text* section found" >&2; exit 1; }
# round up to the next MiB
max_off=$(( (max_off + 0xFFFFF) / 0x100000 * 0x100000 ))
KERN_END_VIRT=$(printf '0x%x' $(( KERN_VIRT + max_off )))
echo "Kernel text up to $KERN_END_VIRT (length $((max_off / 1024 / 1024)) MiB)"
echo "vmlinux: $V"

# 1. OpenSBI (firmware text only; the payload behind it is data)
"$B-objdump" -d --start-address=0x64000000 --stop-address="$kp_hex" \
    "$out/fw_payload.elf" > "$out/sbi.dis"

# 2. Kernel physical -- addresses AND jump targets translated.
#    shift = KERN_PHYS - KERN_VIRT; objcopy computes in bfd_vma (unsigned
#    64 bit), the overflow is therefore exactly the intended mapping.
shift=$(( KERN_PHYS - KERN_VIRT ))
"$B-objcopy" --change-addresses="$shift" "$V" "$out/vmlinux_phys.elf"
"$B-objdump" -d --start-address="$kp_hex" \
    --stop-address=$(printf '0x%x' $(( KERN_PHYS + max_off ))) \
    "$out/vmlinux_phys.elf" > "$out/kern_phys.dis"

# 3. Kernel virtual (after satp)
"$B-objdump" -d --start-address="$kv_hex" --stop-address="$KERN_END_VIRT" \
    "$V" > "$out/kern_virt.dis"

cat "$out/sbi.dis" "$out/kern_phys.dis" "$out/kern_virt.dis" > "$out/merged.dis"
for f in sbi kern_phys kern_virt merged; do
    printf '  %-10s %s lines\n' "$f.dis" "$(wc -l < "$out/$f.dis")"
done
echo "### LISTING_OK -> $out/merged.dis"
