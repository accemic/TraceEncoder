#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# make_listing_rocket2_rv64.sh -- merged decoder listing for the TWO-HART
# Rocket RV64 Linux boot (package M5). Runs on a Linux build host
# (<linux-build-host>).
#
#   ./make_listing_rocket2_rv64.sh        # -> out_rocket2/merged.dis
#
# This is the gap that W1 §8.3 left open: "There is no merged listing for
# the Rocket ... without a listing NexRv cannot decode, and a guessed
# listing would not be evidence."
#
# A boot capture runs through THREE address spaces:
#
#   1. OpenSBI          0x8000_0000            physical == virtual (M-mode)
#   2. Kernel EARLY      0x8020_0000            physical, until satp is set
#   3. Kernel AFTER MMU  0x000000FF_8000_0000   virtual, BUT TRUNCATED TO 40 BIT
#
# ON POINT 3 -- THE DECISION W1 EXPLICITLY LEFT OPEN:
# The kernel sits virtually at 0xFFFFFFFF_8000_0000 (KERNEL_LINK_ADDR, RV64
# places the kernel in the topmost 2 GiB). In the trace, however, it shows
# up at 0x000000FF_8000_0000, because the Rocket generat only drives 40
# address bits and ZERO-extends, not sign-extends:
#
#     rtl/adapters/rocket/rocket_tci_to_ctte_tip.sv:190-191
#       "iaddr/tval ... only driven at 40 bit: {24'd0, wb_reg_pc}"
#
# W1 independently MEASURED the same shape on the board (observation
# channel: PC_HI = 0x000000FF at PC = 0x000000FF_8041_6ABA). Two sources,
# the same statement -- hence the listing is COMPUTED on the 40-bit form and
# the shim is NOT changed. The alternative (sign extension from bit 39 in
# the shim) would be an RTL change on a pinned tree and would have the same
# effect; it is thus a decision for a later package, not this one.
#
# WHY objcopy --change-addresses and not just rewriting the address column:
# otherwise the jump targets IN THE TEXT still point at the old addresses,
# and the decoder searches for them in vain ("No entry in -pcinfo found @...").
#
# WHY bash and not sh: the kernel addresses lie above 2^53. awk computes with
# doubles and rounds 0xFFFFFFFF80ABC000 to 2-KiB multiples -- the section
# boundary would silently come out wrong.
#
# Userspace is NOT included (PIE + ASLR, run-dependent addresses).
set -e

here=$(cd "$(dirname "$0")" && pwd)
l1="${L1_OUT:-$HOME/cva6_linux/out_rv64}"
out="${OUT_DIR:-$here/out_rocket2}"
host="$l1/host"
B="$host/bin/riscv64-buildroot-linux-gnu"
V=$(ls -d "$l1"/build/linux-*/vmlinux 2>/dev/null | head -1)

# Address bits the Rocket generat carries on the trace port.
ADDR_BITS=${ADDR_BITS:-40}

[ -n "$V" ] || { echo "### ERROR: vmlinux not found" >&2; exit 1; }
[ -f "$out/fw_payload.elf" ] || { echo "### ERROR: $out/fw_payload.elf missing (build_payload_rocket2_rv64.sh)" >&2; exit 1; }

SBI_START=0x80000000

kv_hex=$("$B-readelf" -h "$V" | awk '/Entry point address/{print $NF}')
KERN_VIRT=$(( kv_hex ))
kp_hex=0x$("$B-nm" "$out/fw_payload.elf" | awk '$3=="payload_bin"{print $1; exit}')
[ "$kp_hex" != "0x" ] || { echo "### ERROR: symbol payload_bin missing" >&2; exit 1; }
KERN_PHYS=$(( kp_hex ))
mask=$(( (1 << ADDR_BITS) - 1 ))
KERN_VIRT_TR=$(( KERN_VIRT & mask ))
printf 'Kernel virtual %s -> in the trace 0x%x (%s bit) / physical %s\n' \
       "$kv_hex" "$KERN_VIRT_TR" "$ADDR_BITS" "$kp_hex"
if (( KERN_PHYS % 0x200000 != 0 )); then
    echo "### ERROR: physical kernel address not 2-MiB-aligned" >&2; exit 1
fi

# How far the executable kernel reaches -- from the ELF, not guessed. With a
# guessed boundary, .init.text was missing at the RV32 stage, and decoding
# broke off exactly in setup_vm (the function that sets up the early page
# tables and therefore still runs physically).
max_off=0
while read -r _idx name size vma _rest; do
    case "$name" in *text*) ;; *) continue;; esac
    [ -n "${vma:-}" ] || continue
    off=$(( 0x$vma - KERN_VIRT + 0x$size ))
    (( off > max_off )) && max_off=$off
done < <("$B-objdump" -h "$V" | awk 'NF>=7 && $1 ~ /^[0-9]+$/ {print $1, $2, $3, $4, $5}')
(( max_off > 0 )) || { echo "### ERROR: no *text* section found" >&2; exit 1; }
max_off=$(( (max_off + 0xFFFFF) / 0x100000 * 0x100000 ))
echo "Kernel text $((max_off / 1024 / 1024)) MiB"
echo "vmlinux: $V"

# 1. OpenSBI (firmware text only; the payload behind it is DATA)
"$B-objdump" -d --start-address=$SBI_START --stop-address="$kp_hex" \
    "$out/fw_payload.elf" > "$out/sbi.dis"

# 2. Kernel, physical
shift_p=$(( KERN_PHYS - KERN_VIRT ))
"$B-objcopy" --change-addresses="$shift_p" "$V" "$out/vmlinux_phys.elf"
"$B-objdump" -d --start-address="$kp_hex" \
    --stop-address=$(printf '0x%x' $(( KERN_PHYS + max_off ))) \
    "$out/vmlinux_phys.elf" > "$out/kern_phys.dis"

# 3. Kernel, virtual, computed on the trace's 40-bit form.
#    objcopy computes in bfd_vma (unsigned 64 bit); the overflow is exactly
#    the intended mapping.
shift_v=$(( KERN_VIRT_TR - KERN_VIRT ))
"$B-objcopy" --change-addresses="$shift_v" "$V" "$out/vmlinux_tr.elf"
"$B-objdump" -d --start-address=$(printf '0x%x' "$KERN_VIRT_TR") \
    --stop-address=$(printf '0x%x' $(( KERN_VIRT_TR + max_off ))) \
    "$out/vmlinux_tr.elf" > "$out/kern_virt40.dis"

cat "$out/sbi.dis" "$out/kern_phys.dis" "$out/kern_virt40.dis" > "$out/merged.dis"
for f in sbi kern_phys kern_virt40 merged; do
    printf '  %-14s %s lines\n' "$f.dis" "$(wc -l < "$out/$f.dis")"
done

# Gate: the three expected base addresses must ACTUALLY occur in the
# listing. "objdump ran through" is not proof -- an empty address range
# produces a valid, empty file.
rc=0
for pat in "$(printf '%x' $SBI_START):" "$(printf '%x' "$KERN_PHYS"):" "$(printf '%x' "$KERN_VIRT_TR"):"; do
    if grep -qi "^ *$pat" "$out/merged.dis"; then
        echo "  LISTING OK: base $pat present"
    else
        echo "### ERROR: base $pat missing from the listing" >&2; rc=1
    fi
done
[ $rc -eq 0 ] || { echo "### LISTING_FAIL" >&2; exit 1; }
echo "### LISTING_OK -> $out/merged.dis"
