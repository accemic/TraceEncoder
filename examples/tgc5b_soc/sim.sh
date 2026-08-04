#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Trace an arbitrary RV32I program through the TGC5B + CEDARtools.TraceEncoder example SoC and
# dump the decoded trace — the example's analogue of trace_fs's run.sh.
#
# The program is run unmodified: the testbench acts as the trace host and turns
# CEDARtools.TraceEncoder on over the SoC config port, so the ELF needs no CEDARtools.TraceEncoder awareness. It
# must be a bare-metal RV32I image linked at 0x0 that fits the RAM (64 KiB by
# default) — see examples/tgc5b_soc/prog/src/ for the reference program.
#
# Usage:
#   examples/tgc5b_soc/sim.sh <program.elf>        # trace your own ELF
#   examples/tgc5b_soc/sim.sh                      # trace the committed hello_trace
#
# Needs a bare-metal RV32I toolchain (riscv32-unknown-elf-*, override via CROSS),
# the abc build driver, and Verilator. Produces, under the sim work dir:
#   ct_soc_tb.atb.bin        raw N-Trace (ATB) byte stream
#   ct_soc_tb.decoded.pcout  NexRv-reconstructed PC stream
#   ct_soc_tb.nexrv.log      full NexRv message decode

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$here" rev-parse --show-toplevel)"
prog_dir="$here/prog"

CROSS="${CROSS:-riscv32-unknown-elf-}"
OBJCOPY="${OBJCOPY:-${CROSS}objcopy}"
OBJDUMP="${OBJDUMP:-${CROSS}objdump}"
NEXRV="${NEXRV:-$repo_root/bin/NexRv}"

elf="${1:-}"

# --- 1. Populate the active program slot (prog.hex / prog.pcinfo) ------------
if [[ -n "$elf" ]]; then
	[[ -f "$elf" ]] || { echo "sim.sh: no such ELF: $elf" >&2; exit 2; }
	echo "[run] converting $elf -> program slot"
	"$OBJDUMP" -d "$elf" > "$prog_dir/prog.dis"
	tmpbin="$(mktemp)"; trap 'rm -f "$tmpbin"' EXIT
	"$OBJCOPY" -O binary "$elf" "$tmpbin"
	python3 - "$tmpbin" "$prog_dir/prog.hex" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
data += b"\x00" * ((-len(data)) % 4)
with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 4):
        f.write("%08x\n" % int.from_bytes(data[i:i+4], "little"))
PY
	"$NEXRV" -conv -objd "$prog_dir/prog.dis" -pcinfo "$prog_dir/prog.pcinfo"
else
	echo "[run] using committed hello_trace program"
	cp "$prog_dir/hello_trace.hex"    "$prog_dir/prog.hex"
	cp "$prog_dir/hello_trace.pcinfo" "$prog_dir/prog.pcinfo"
	cp "$prog_dir/hello_trace.dis"    "$prog_dir/prog.dis"
fi

# --- 2. Run the SoC simulation ----------------------------------------------
echo "[run] simulating the SoC (host-enabled tracing)"
( cd "$repo_root/bld" && abc -sim ../examples/tgc5b_soc/test/ct_soc_tb.abc )

# --- 3. Locate outputs and dump the decoded trace ---------------------------
atb="$(find "$repo_root/bld" -name ct_soc_tb.atb.bin -printf '%T@ %p\n' \
	| sort -rn | head -1 | cut -d' ' -f2-)"
[[ -n "$atb" ]] || { echo "sim.sh: no ct_soc_tb.atb.bin produced" >&2; exit 1; }
sim_dir="$(dirname "$atb")"
pcout="$sim_dir/ct_soc_tb.decoded.pcout"
log="$sim_dir/ct_soc_tb.nexrv.log"

echo "[run] decoding $atb with NexRv"
"$NEXRV" -deco "$atb" -pcinfo "$prog_dir/prog.pcinfo" -pcout "$pcout" -full > "$log" 2>&1 || true

nmsg="$(grep -cE 'TCODE\[6\]=' "$log" || true)"
nsync="$(grep -cE 'TCODE\[6\]=[0-9]+.*Sync' "$log" || true)"
npc="$(wc -l < "$pcout" 2>/dev/null || echo 0)"

echo
echo "========= CEDARtools.TraceEncoder decode summary ========="
printf '  program        : %s\n' "${elf:-hello_trace (committed)}"
printf '  ATB bytes      : %s\n' "$(wc -c < "$atb")"
printf '  Nexus messages : %s (%s synchronization)\n' "$nmsg" "$nsync"
printf '  decoded PCs    : %s\n' "$npc"
printf '  ATB dump       : %s\n' "$atb"
printf '  decoded PCs    : %s\n' "$pcout"
printf '  full decode    : %s\n' "$log"
echo "========================================================="
echo
echo "First reconstructed PCs:"
head -20 "$pcout" 2>/dev/null || true
