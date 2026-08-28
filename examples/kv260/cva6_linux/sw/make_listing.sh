#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# make_listing.sh -- merged decoder listing for the Linux boot. Runs on a
# Linux build host.
#
#   ./make_listing.sh            # -> out/merged.dis
#
# A boot capture runs through THREE address spaces, and the decoder needs a
# listing for each:
#
#   1. OpenSBI            0x6400_0000  physical == virtual (M-mode, no MMU)
#   2. kernel EARLY        0x6440_0000  physical, until satp is set
#   3. kernel AFTER MMU    0xC000_0000  virtual (the ITI reports virtual PCs)
#
# Point 2 is why objcopy --change-addresses is used: merely rewriting the
# address column is NOT enough -- the jump targets in the text would still
# point at the virtual addresses and the decoder would search for them
# there in vain ("No entry in -pcinfo found @0xc00010d0").
#
# Userspace is deliberately NOT included: its pages sit at run-dependent
# virtual addresses (PIE + ASLR). Decoding into it needs the mapping from
# /proc/<pid>/maps per process -- see the disclosure note in the handover.
set -e

here=$(cd "$(dirname "$0")" && pwd)
br="$here/buildroot"
out="$here/out"
host="$br/output/host"
B="$host/bin/riscv32-buildroot-linux-gnu"
V=$(ls -d "$br"/output/build/linux-*/vmlinux 2>/dev/null | head -1)

# Virtual base of the kernel (PAGE_OFFSET) and its physical load address.
KERN_VIRT=0xC0000000
KERN_PHYS=0x64400000
# How far the executable kernel reaches -- NOT guessed, but derived from the
# ELF. With an estimated boundary (0xC0D00000), .init.text was missing, and
# the decode broke off right in setup_vm (0xC1006408) -- the function that
# sets up the early page tables and therefore still runs physically.
KERN_END_VIRT=auto

[ -n "$V" ] || { echo "### ERROR: vmlinux not found" >&2; exit 1; }
if [ "$KERN_END_VIRT" = auto ]; then
    # End of the last *.text section (head/text/init.text/exit.text),
    # rounded up to the next MiB.
    KERN_END_VIRT=$("$B-objdump" -h "$V" | awk '
        $2 ~ /text/ { end = strtonum("0x" $4) + strtonum("0x" $3); if (end > m) m = end }
        END { printf "0x%X", int((m + 0xFFFFF) / 0x100000) * 0x100000 }')
fi
echo "Kernel text up to $KERN_END_VIRT"

[ -f "$out/fw_payload.elf" ] || { echo "### ERROR: out/fw_payload.elf missing (build_payload.sh)" >&2; exit 1; }
mkdir -p "$out"

echo "vmlinux: $V"

# 1. OpenSBI (firmware text only; the payload behind it is data)
"$B-objdump" -d --start-address=0x64000000 --stop-address=0x64040000 \
    "$out/fw_payload.elf" > "$out/sbi.dis"

# 2. Kernel physical -- addresses AND jump targets translated
delta=$(printf '%d' $(( KERN_VIRT - KERN_PHYS )))
"$B-objcopy" --change-addresses=-$delta "$V" "$out/vmlinux_phys.elf"
"$B-objdump" -d --start-address=$KERN_PHYS \
    --stop-address=$(printf '0x%x' $(( KERN_END_VIRT - delta ))) \
    "$out/vmlinux_phys.elf" > "$out/kern_phys.dis"

# 3. Kernel virtual (after satp)
"$B-objdump" -d --start-address=$KERN_VIRT --stop-address=$KERN_END_VIRT \
    "$V" > "$out/kern_virt.dis"

cat "$out/sbi.dis" "$out/kern_phys.dis" "$out/kern_virt.dis" > "$out/merged.dis"
for f in sbi kern_phys kern_virt merged; do
    printf '  %-10s %s lines\n' "$f.dis" "$(wc -l < "$out/$f.dis")"
done
echo "### LISTING_OK -> $out/merged.dis"
