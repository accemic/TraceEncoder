#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# fp_gate_probe.sh -- counter-check for the floating-point gate in
# build_payload_rocket_rv64.sh (package L2). Runs on a Linux build host
# (<linux-build-host>).
#
# Purpose: prove that the gate can actually turn its own failure class RED.
# A gate that is only ever green on clean material has proven nothing
# (§2.10 regression guard, §14.1 audit-the-auditor).
#
# The probe contains EXCLUSIVELY alias-hidden floating-point instructions:
#   fsgnjn.d rd,rs,rs  -> objdump prints by default  "fneg.d"
#   fsgnjx.s rd,rs,rs  ->                             "fabs.s"
#   fsgnj.d  rd,rs,rs  ->                             "fmv.d"
# Exactly this class is what the L1 audit found (fixed there: commit
# 2c718b5). Expectation: default disassembly 0 hits, `-M no-aliases` 3 hits.
#
# The search regex is NOT duplicated, but extracted from the build script --
# that way the probe is guaranteed to test the gate, not its own copy of it.
set -e

here=$(cd "$(dirname "$0")" && pwd)
l1="${L1_OUT:-$HOME/cva6_linux/out_rv64}"
host="$l1/host"
cross="$host/bin/riscv64-buildroot-linux-gnu-"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/probe.S" <<'EOF'
	.text
	.globl _probe
_probe:
	fsgnjn.d	fa0, fa1, fa1
	fsgnjx.s	fa2, fa3, fa3
	fsgnj.d 	fa4, fa5, fa5
	ret
EOF

"${cross}as" -march=rv64imafd -mabi=lp64 -o "$tmp/probe.o" "$tmp/probe.S"

# Take the regex from the gate (the one line that carries the sniff).
rex=$(grep -F '$3 ~ /^(flw|' "$here/build_payload_rocket_rv64.sh" | head -1)
[ -n "$rex" ] || { echo "### ERROR: sniff line not found in the build script" >&2; exit 1; }
prog="$rex
    END { print c+0 }"

n_def=$("${cross}objdump" -d               "$tmp/probe.o" | awk "$prog")
n_noa=$("${cross}objdump" -d -M no-aliases "$tmp/probe.o" | awk "$prog")

echo "Probe contains 3 floating-point instructions (alias-hidden forms only)."
echo "  objdump -d                 -> gate counts $n_def"
echo "  objdump -d -M no-aliases   -> gate counts $n_noa"
"${cross}objdump" -d "$tmp/probe.o"               | awk '$3 ~ /^f[a-z]+\./ {print "    default:   "$3}'
"${cross}objdump" -d -M no-aliases "$tmp/probe.o" | awk '$3 ~ /^f[a-z]+\./ {print "    no-alias:  "$3}'
echo "  => without the switch, $((n_noa - n_def)) of $n_noa instructions would have slipped through."
echo "     (The one default hit is coincidence: the alias of fsgnj.d is named"
echo "      'fmv.d' and falls under the regex alternative 'fmv\\.'; fneg.d and"
echo "      fabs.s have no counterpart in the regex.)"

rc=0
if [ "$n_noa" -ne 3 ]; then
    echo "### ERROR: with -M no-aliases the gate only finds $n_noa of 3 -- regex too narrow" >&2; rc=1
fi
if [ "$n_def" -ge "$n_noa" ]; then
    echo "### ERROR: no difference default vs no-aliases -- probe is unfit for purpose" >&2; rc=1
fi
[ $rc -eq 0 ] && echo "### FP_GATE_PROBE_OK (the gate is turned red by its own failure class)"
exit $rc
