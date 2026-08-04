#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Run a program on the TGC5B + CEDARtools.TraceEncoder KV260 app and dump its trace — the
# on-hardware analogue of run.sh, driving everything over SSH + `devmem`.
#
# It converts the ELF to a memory image + NexRv pcinfo, loads it into the SoC
# RAM over devmem, configures + enables CEDARtools.TraceEncoder, starts the core, reads the
# captured ATB back over devmem, and decodes it on the host with NexRv.
#
# The capture buffers are small on-chip BRAMs — 16 KiB of ATB (4096 words) and
# 256 DAQ beats of AXIS — so a long run truncates: the readback is clamped to
# the buffer capacity and STATUS is reported when a buffer overflowed.
#
# Prereqs: the app is installed + loaded on the board (see README:
#   xmutil loadapp ct_soc_kv260), SSH access to $BOARD, a riscv32 toolchain and
#   bin/NexRv on this machine. The program must be bare-metal RV32I linked at 0x0
#   (see prog/src/). Register map: see README / ct_soc_top.sv.
#
# Usage: board_trace.sh <program.elf> [run_seconds]

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$here" rev-parse --show-toplevel)"
BOARD="${BOARD:-kria-kv260}"
CROSS="${CROSS:-riscv32-unknown-elf-}"
NEXRV="${NEXRV:-$repo_root/bin/NexRv}"
APP="${APP:-ct_soc_kv260}"
elf="${1:?usage: board_trace.sh <program.elf> [run_seconds]}"
run_s="${2:-1}"

# Physical register map (see README / ct_soc_top.sv, rdl/ct_soc.rdl).
CTRL=0xA0000000        # b0 core_run  b1 trace_clear  b2 trace_flush
STATUS=0xA0000004      # b0 trace_overflow  b1 axis_overflow
BEATS=0xA0000008       # captured ATB beat count (words)
BYTES=0xA000000C       # captured ATB byte count
AXISBEATS=0xA0000010   # captured AXIS DAQ beat count
ENC=0xA0010000         # trTeControl
RAM=0xA0100000         # program base
TRACE=0xA0200000       # captured ATB words
AXIS=0xA0300000        # captured AXIS DAQ records (4 words per beat)

# Capture-buffer capacities (ct_soc_top TRACE_DEPTH / AXIS_DEPTH). Reads past
# these alias back to word 0, so every readback is clamped to them.
TRACE_WORDS=4096       # 16 KiB of ATB
AXIS_BEATS_MAX=256     # 4 KiB of DAQ records

work="$(mktemp -d)"; trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$work"' EXIT

echo "[board] converting $elf"
"${CROSS}objcopy" -O binary "$elf" "$work/prog.bin"
python3 - "$work/prog.bin" "$work/prog.hex" <<'PY'
import sys
d = open(sys.argv[1],"rb").read(); d += b"\x00"*((-len(d))%4)
open(sys.argv[2],"w").write("".join("%08x\n"%int.from_bytes(d[i:i+4],"little") for i in range(0,len(d),4)))
PY
"${CROSS}objdump" -d "$elf" > "$work/prog.dis"
"$NEXRV" -conv -objd "$work/prog.dis" -pcinfo "$work/prog.pcinfo"

scp -q "$work/prog.hex" "$BOARD:/tmp/prog.hex"

# Reset the encoder to a clean state. The encoder's sync counter / ICNT /
# branch-history state is cleared only by the PL reset, NOT by the CTRL-register
# core-hold or trace-clear bits. Without a reset a *repeated* run inherits the
# previous run's sync phase and ICNT, which shifts the periodic-sync alignment
# and makes the decode fail ("ICNT too small"). Reloading the app pulses the PL
# reset, so every run starts from a defined encoder state.
echo "[board] resetting SoC (reload $APP — encoder state survives core-hold/trace-clear)"
load_out="$(ssh "$BOARD" "sudo xmutil unloadapp >/dev/null 2>&1 || true; sudo xmutil loadapp $APP && sleep 2")"
# A failed load MUST abort: devmem on an unconfigured PL address hangs the
# AXI port and wedges the whole board.
if ! grep -q 'loaded to slot' <<<"$load_out"; then
	echo "[board] ERROR: loadapp failed: $load_out" >&2
	exit 1
fi

echo "[board] loading + tracing on $BOARD"
ssh "$BOARD" "sudo bash -s $run_s" <<EOF > "$work/capture.txt"
set -e
dm() { busybox devmem "\$@"; }
dm $CTRL 32 0x2                       # hold core + re-arm both capture buffers
dm $CTRL 32 0x0                       # release clear (core still held)
i=0
while read -r w; do
    printf -v a '0x%08x' \$(( $RAM + i*4 ))
    dm \$a 32 0x\$w
    i=\$((i+1))
done < /tmp/prog.hex
# trTeControl: Format=1<<24 | InstSyncMode=6<<16 | InhibitSrc=1<<15 |
#              InstMode=6<<4 | Active|Enable|InstTracing.
# CAUTION: a full-word write must preserve the reset-default fields
# (InstMode=6, InhibitSrc=1, Format=1 — see rdl/ct_cs_cpuif.rdl). Clearing
# InstMode drops every control-flow message; clearing InhibitSrc inserts a
# SRC field into each message that a plain NexRv invocation misparses.
dm $ENC  32 0x01068067
dm $CTRL 32 0x1                       # start core
sleep "\$1"
dm $ENC  32 0x01068063                # disable InstTracing -> trace-off correlation
dm $CTRL 32 0x5                       # flush
sleep 0.1
dm $CTRL 32 0x1                       # stop flush
# One line of counters + status, then each capture clamped to its buffer depth
# (reads past the depth alias back to word 0 and would corrupt the dump).
echo "status \$(dm $STATUS w) bytes \$(dm $BYTES w) beats \$(dm $BEATS w) axisbeats \$(dm $AXISBEATS w)"
nwords=\$(( ( \$(dm $BYTES w) + 3 ) / 4 ))
if [ \$nwords -gt $TRACE_WORDS ]; then nwords=$TRACE_WORDS; fi
echo "trace \$nwords"
for ((i=0;i<nwords;i++)); do printf -v a '0x%08x' \$(( $TRACE + i*4 )); dm \$a w; done
nbeats=\$(( \$(dm $AXISBEATS w) ))
if [ \$nbeats -gt $AXIS_BEATS_MAX ]; then nbeats=$AXIS_BEATS_MAX; fi
echo "axis \$nbeats"
for ((i=0;i<nbeats*4;i++)); do printf -v a '0x%08x' \$(( $AXIS + i*4 )); dm \$a w; done
EOF

# Split the single capture stream into its sections (counters / ATB / AXIS).
hdr="$(grep -m1 '^status ' "$work/capture.txt" || true)"
if [ -z "$hdr" ]; then
	echo "[board] ERROR: no counters in the capture — the devmem sequence did not complete" >&2
	exit 1
fi
read -r _ status _ nbytes _ nbeats _ naxis <<<"$hdr"
status=$((status)); nbytes=$((nbytes)); nbeats=$((nbeats)); naxis=$((naxis))
awk -v t="$work/trace.words" -v a="$work/axis.words" '
	/^trace /{ out=t; next } /^axis /{ out=a; next } /^0x/ && out { print > out }' \
	"$work/capture.txt"
touch "$work/trace.words" "$work/axis.words"

echo "[board] captured $nbytes ATB bytes ($nbeats beats), $naxis AXIS beats"
if (( status & 1 )); then
	echo "[board] WARNING: trace_overflow — ATB buffer full ($TRACE_WORDS words," \
	     "$((TRACE_WORDS * 4)) bytes); the trace is truncated, decode stops early"
	nbytes=$((TRACE_WORDS * 4))
fi
if (( status & 2 )); then
	echo "[board] WARNING: axis_overflow — AXIS buffer full ($AXIS_BEATS_MAX beats);" \
	     "later DAQ beats were dropped"
fi

python3 - "$work/trace.words" "$work/trace.bin" "$nbytes" <<'PY'
import sys
words = [int(x,16) for x in open(sys.argv[1]) if x.strip().startswith("0x")]
nb = int(sys.argv[3])
b = b"".join(int(w).to_bytes(4,"little") for w in words)[:nb]
open(sys.argv[2],"wb").write(b)
PY

echo "[board] decoding with NexRv"
"$NEXRV" -deco "$work/trace.bin" -pcinfo "$work/prog.pcinfo" \
	-pcout "$work/trace.pcout" -full > "$work/nexrv.log" 2>&1 || true
echo "=== reconstructed PCs ==="
head -40 "$work/trace.pcout" || true

# The AXIS capture is only non-empty when watchpoints were programmed (see the
# README's DAQ walkthrough); print it whenever the run produced beats.
if (( naxis > 0 )); then
	echo "=== AXIS DAQ beats ==="
	"$repo_root/scripts/parse_axis.py" < "$work/axis.words"
fi

if [ "${KEEP:-0}" = 1 ]; then
	echo "[board] kept work dir: $work (trace.bin, trace.pcout, nexrv.log, axis.words)"
else
	echo "(set KEEP=1 to keep the work dir: $work)"
fi
