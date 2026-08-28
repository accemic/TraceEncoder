#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# make_listing_rocket_rv64.sh -- merged decoder listing for the SINGLE-hart
# Rocket RV64 Linux boot. Runs on a Linux build host.
#
#   ./make_listing_rocket_rv64.sh          # -> out_rocket/merged.dis
#   OUT_DIR=/somewhere ./make_listing_rocket_rv64.sh
#
# WHY THIS IS A WRAPPER AND NOT A SECOND SCRIPT. Until 2026-08-21 this
# example had no listing step at all, while `cva6_linux`, `cva6_linux64` and
# `rocket2` did. Without a listing the reference decoder cannot decode, so
# anyone who rebuilt the payload here could capture a trace and then not
# read it -- the only usable pcinfo in the tree
# (`examples/dashboard/demo/rocket64.pcinfo`) belongs to one specific build.
#
# The gap does NOT need a second implementation. `make_listing_rocket2_rv64.sh`
# derives everything it needs from the artifacts -- kernel virtual base from
# the vmlinux entry point, physical base from the `payload_bin` symbol in the
# fw_payload ELF, section boundaries from the ELF -- and none of that depends
# on the number of harts. Its output directory is already a parameter
# (`OUT_DIR`, that script's line 50). A copy here would be a second place to
# fix the next time the address plan moves; the repository has been bitten by
# exactly that (see the No-Drift rule for the HTML build in the workspace
# conventions).
#
# WHAT WAS VERIFIED (2026-08-21), and what was not. Run against this
# example's payload the shared script produces a complete listing:
#   sbi.dis 47,135 lines / kern_phys.dis 1,555,321 / kern_virt40.dis 1,555,321
#   merged.dis 3,157,777 lines
#   LISTING OK: base 80000000 / 80200000 / ff80000000: present
# A pcinfo built from that listing was NOT confirmed against a board
# capture -- and the reason is worth carrying, because it is the trap this
# step has:
#
#   THE LISTING MUST COME FROM THE SAME BUILDROOT TREE THE PAYLOAD DID.
#   The shared script takes the kernel from `<L1_OUT>/build/linux-*/vmlinux`
#   -- whatever is in that tree right now. On the build host used here that
#   tree had meanwhile been rebuilt with a different kernel configuration
#   for another example, so the listing described a kernel the payload does
#   not contain. The decode then fails immediately and unmistakably
#   ("No entry in -pcinfo found", 0 PCs decoded) -- but only because the
#   kernels differ that much. A smaller difference would decode for a while
#   and then diverge, which is far harder to notice.
#
# So: build the listing right after the payload, from the same tree, or pin
# the kernel by pointing L1_OUT at a copy.
#
# The three address spaces, the 40-bit truncation of the Rocket generat and
# the reason for `objcopy --change-addresses` are documented once, in the
# header of the shared script. Read that one; this file only points at it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
shared="$here/../../rocket2/sw/make_listing_rocket2_rv64.sh"

[ -f "$shared" ] || {
    echo "### ERROR: shared listing script not found: $shared" >&2
    exit 1
}

# Default differs from the shared script's: this example builds into
# out_rocket, the two-hart one into out_rocket2.
export OUT_DIR="${OUT_DIR:-$here/out_rocket}"

echo "### make_listing_rocket_rv64: delegating to $(basename "$shared") with OUT_DIR=$OUT_DIR"
exec bash "$shared" "$@"
