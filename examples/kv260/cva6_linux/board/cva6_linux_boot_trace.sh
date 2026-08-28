#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# cva6_linux_boot_trace.sh -- boot Linux on the CVA6 in the KV260's PL and
# capture the boot with CTTE. Bash port of the predecessor repository's
# `cva6_linux_board_boot.ps1` (Gate L6/L7), including its 2026-08-17 state
# (`-SyncMax` parameter, `mem_load.py` payload loader -- `dd`'s write() path
# into the reserved window fails with "Bad address" on this board's kernel,
# mmap works, see mem_load.py's own header).
#
#   cva6_linux_boot_trace.sh [options]
#
# Deployment is a PREREQUISITE, not this script's job (same as the ps1
# original): the bitstream `cva6_linux_kv260_top` must already be a loadable
# board app named `--app` -- use `examples/kv260/common/board/
# package_kv260_app.py` + `deploy_kv260_app.sh` first (see
# `../../duo/board/duo_board_gate.sh` for that pattern applied end-to-end).
#
# Options:
#   --app <name>              board-app name (default cva6_linux_ctrace_kv260)
#   --proto n|e                N-Trace (Nexus/MSEO) or E-Trace (te_inst)
#                              (default n -- the migrated bitstream is
#                              N-Trace-only; the ps1's default was `e` from
#                              an in-progress E-Trace investigation this
#                              port does not carry forward as a default)
#   --sendconfig <0-3>         trTeControl.SendConfig[8:7] (default 1 = CFG_ONCE,
#                             the RDL reset; the ps1 constant had it OFF)
#   --syncmax <0-15>           trTeControl.InstSyncMax[23:20]: periodic sync
#                              every 2^(x+4) instructions (InstSyncMode=6).
#                              Default 6 (every 1024 instr, the RDL reset
#                              value). 0 (every 16 instr) floods the ring
#                              with ResourceFull+ProgTraceSync pairs and --
#                              combined with the decoder's implicit-return
#                              reconstruction -- broke decode at the first
#                              jalr in fw_platform_init on every bitstream
#                              tested (2026-08-17 finding, see ps1 header).
#   --runsec <sec>              capture window (default 3.0)
#   --payload <local-file>      stage a local fw_payload.bin from the
#                              workstation (mutually exclusive with
#                              --payload-jump; wins if both are given)
#   --payload-jump <path>       path to fw_payload.bin ON the jump host,
#                              streamed board-ward without a workstation
#                              round trip (default cva6_linux/out/fw_payload.bin,
#                              the ps1's original -PanamaPath -- a Linux
#                              build host's sw/cva6_linux/build_payload.sh
#                              output; see ../sw/README.md)
#   --skip-load                 payload already in the window (fast re-run
#                              of the arm/boot/capture steps only)
#   --board <ip>                board IP (no default; or KV260_BOARD)
#   --jump <host>                jump host, ssh-config alias ok (no default; or KV260_JUMP)
#   --user <name>                board user (default ubuntu)
#   --sudo-pass <pw>              board sudo password (default: $KV260_SUDO_PASS)
#   --pcinfo <file>               decode the captured N-Trace/E-Trace stream
#                              against this pcinfo after capture (new vs. the
#                              ps1 -- none exists in this migrated tree yet
#                              for the CVA6 Linux payload, so without this
#                              flag the decode step SKIPs, loudly)
#   --out <dir>                   work dir for generated artifacts
#                              (default: ./board_run_cva6_linux next to this script)
#   -h|--help
#
# Address map (examples/kv260/cva6_linux/rtl/cva6_linux_soc_top.sv @details):
#   0x6000_0000 +64 MiB  Trace-DDR sink default window (unused by this
#                        script -- URAM ring only, matching the ps1)
#   0x6400_0000 +192 MiB CVA6 Linux guest RAM (OpenSBI @0x6400_0000,
#                        Kernel @0x6440_0000, DTB embedded)
#   PL aperture 0xA000_0000: CTRL 0x0 | ENC 0x1_0000 | TRACE 0x20_0000 | CON 0x30_0000
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
COMMON_BOARD="$REPO/examples/kv260/common/board"

PY="${PY:-py}"
command -v py >/dev/null 2>&1 || PY=python3

APP="cva6_linux_ctrace_kv260" PROTO="n" SYNCMAX="6" RUNSEC="3.0"
PAYLOAD_LOCAL="" PAYLOAD_JUMP="cva6_linux/out/fw_payload.bin" SKIP_LOAD=0
BOARD="${KV260_BOARD:-}" JUMP="${KV260_JUMP:-}" USER_="ubuntu"
SUDO_PASS="${KV260_SUDO_PASS:-}"
PCINFO="" OUT=""

usage() { sed -n '2,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2;;
        --proto) PROTO="$2"; shift 2;;
        --syncmax) SYNCMAX="$2"; shift 2;;
        --sendconfig) SENDCONFIG="$2"; shift 2;;
        --runsec) RUNSEC="$2"; shift 2;;
        --payload) PAYLOAD_LOCAL="$2"; shift 2;;
        --payload-jump) PAYLOAD_JUMP="$2"; shift 2;;
        --skip-load) SKIP_LOAD=1; shift;;
        --board) BOARD="$2"; shift 2;;
        --jump) JUMP="$2"; shift 2;;
        --user) USER_="$2"; shift 2;;
        --sudo-pass) SUDO_PASS="$2"; shift 2;;
        --pcinfo) PCINFO="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "cva6_linux_boot_trace: unknown argument $1" >&2; exit 2;;
    esac
done
case "$PROTO" in n|e) ;; *) echo "cva6_linux_boot_trace: --proto must be n or e" >&2; exit 2;; esac
case "$SYNCMAX" in [0-9]|1[0-5]) ;; *) echo "cva6_linux_boot_trace: --syncmax must be 0-15" >&2; exit 2;; esac
case "${SENDCONFIG:=1}" in [0-3]) ;; *) echo "cva6_linux_boot_trace: --sendconfig must be 0-3 (trTeControl.SendConfig)" >&2; exit 2;; esac

WORK="${OUT:-$HERE/board_run_cva6_linux}"
mkdir -p "$WORK"

# board_run SCRIPT ERRFILE -- writes SCRIPT (LF-only) to a local staging
# file, pushes it workstation -> jump -> board, runs it there via
# `sudo -S bash`, and echoes whatever it wrote to stdout (diagnostics go to
# ERRFILE). Same shape as the ps1's `Board-Run` helper, minus the single
# global scratch file it reused (bash gets one per call, cheap and avoids a
# read-after-write race if a caller ever runs two board_run calls in a row).
board_run() {
    local script="$1" errfile="$2" seq
    seq="$WORK/board_seq_$$_$RANDOM.sh"
    printf '%s\n' "$script" | sed 's/\r$//' > "$seq"
    scp -q "$seq" "$JUMP:/tmp/cva6_board_seq.sh" || { echo "### SCP_PANAMA_FAILED" >&2; return 1; }
    ssh "$JUMP" \
        "scp -q /tmp/cva6_board_seq.sh $USER_@${BOARD}:/tmp/ && \
         ssh $USER_@$BOARD 'echo $SUDO_PASS | sudo -S bash /tmp/cva6_board_seq.sh'" \
        2> "$errfile"
}

# --- 1. Payload availability -------------------------------------------------
if [ "$SKIP_LOAD" -eq 0 ]; then
    if [ -n "$PAYLOAD_LOCAL" ]; then
        [ -f "$PAYLOAD_LOCAL" ] || { echo "### ERROR: --payload not found: $PAYLOAD_LOCAL"; exit 1; }
        psize="$(wc -c < "$PAYLOAD_LOCAL" | tr -d ' ')"
        echo "### Payload: local $PAYLOAD_LOCAL"
    else
        echo "### Payload on $JUMP: $PAYLOAD_JUMP"
        psize="$(ssh "$JUMP" "stat -c%s $PAYLOAD_JUMP 2>/dev/null || echo 0")"
    fi
    if [ "$psize" -lt 1000000 ]; then
        if [ -n "$PAYLOAD_LOCAL" ]; then
            echo "### ERROR: payload missing/too small ($psize bytes): $PAYLOAD_LOCAL"
        else
            echo "### ERROR: payload missing/too small ($psize bytes) on $JUMP: $PAYLOAD_JUMP"
            echo "  (build it with sw/cva6_linux/build_payload.sh on a Linux build host, see ../sw/README.md)"
        fi
        exit 1
    fi
    printf '### Payload: %s bytes\n' "$psize"
fi

# --- 2. Prepare: RESMEM gate, app load, AFIFM, hold core, clear rings ------
# RESMEM gate, LAYOUT-AGNOSTIC on purpose. Two boot overlays are in the
# field: address-plan v3 (ctrace-pl-ddr@60000000, 256 MiB -- what the boards
# gated on 2026-08-17 actually carry, RESMEM_OK observed on kria-kv260) and
# v4 (ctrace-pl-ddr@50000000, 512 MiB -- what common/board/ctrace_resmem.dtso
# ships since 2026-08-10). Hard-wiring either name false-negatives on the
# other board. What this example NEEDS is only that its guest RAM
# 0x6400_0000 +192 MiB (fw_payload: OpenSBI, kernel, DTB) lies inside a
# no-map reservation -- otherwise the kernel hands the region out and the
# soft core boots into foreign memory. So: read every ctrace-pl-ddr@* node
# (reg = 64-bit base + 64-bit size, big-endian in the live devicetree) and
# demand that ONE of them covers [0x6400_0000, 0x7000_0000). The LIVE
# devicetree is the only source: no-map regions never appear in /proc/iomem.
prep="$(cat <<PREP_EOF
set -e
dm() { busybox devmem "\$@"; }
need_lo=\$((0x64000000)); need_hi=\$((0x70000000))
ok=0
for node in /sys/firmware/devicetree/base/reserved-memory/ctrace-pl-ddr@*; do
  [ -d "\$node" ] || continue
  hex=\$(od -An -tx1 -v "\$node/reg" | tr -d ' 
')
  base=\$((0x\$(echo "\$hex" | cut -c1-16)))
  size=\$((0x\$(echo "\$hex" | cut -c17-32)))
  echo "RESMEM_NODE \$(basename \$node) base=\$(printf 0x%x \$base) size=\$(printf 0x%x \$size)" >&2
  if [ \$base -le \$need_lo ] && [ \$((base+size)) -ge \$need_hi ]; then ok=1; fi
done
if [ \$ok -ne 1 ]; then
  echo "RESMEM_MISSING (no ctrace-pl-ddr@* reservation covers 0x64000000..0x70000000 -- apply ctrace_resmem.dtso to the BOOT devicetree, regenerate user-override.dtb, reboot)" >&2
  ls /sys/firmware/devicetree/base/reserved-memory/ >&2 || true
  exit 9
fi
echo "RESMEM_OK (guest window 0x64000000+192MiB covered)" >&2

xmutil unloadapp >/dev/null 2>&1 || true
xmutil loadapp $APP >/dev/null
sleep 2
# PS AFIFM port widths (reset = 128 bit, needed once per boot): HP0/AFIFM2
# -> 32 bit (trace sink), HP1/AFIFM3 -> 64 bit (CVA6 memory). Without this
# FABRIC_WIDTH is bits [1:0] of RDCTRL/WRCTRL, and the reset value of those
# registers is 0x3B0 -- several bits above [1:0] are marked reserved but are
# RW and set out of reset (UG1087). Writing the whole register with the width
# code therefore clears them. Read-modify-write instead; pointed out
# 2026-08-21 while the AMP core-1 defect was being tracked down, and
# corrected everywhere the same day.
afifm_width() {   # $1 = AFIFM base, $2 = FABRIC_WIDTH code (0=128, 1=64, 2=32)
    for _o in 0x0 0x14; do
        _a=$(printf '0x%08X' $(( $1 + $_o )))
        _v=$(( $(dm $_a) ))
        dm $_a 32 $(printf '0x%08X' $(( (_v & ~0x3) | $2 )))
    done
}
# the first CVA6 fetch hangs (C6 finding, ps1 header).
afifm_width 0xFD380000 2
afifm_width 0xFD390000 1
echo "AFIFM HP0=\$(dm 0xFD380000)/\$(dm 0xFD380014) HP1=\$(dm 0xFD390000)/\$(dm 0xFD390014)" >&2
# Hold the core in reset, clear the trace and console rings.
dm 0xA0000000 32 0x6
dm 0xA0000000 32 0x0
# URAM one-shot (SINK_CTRL b3): the ring keeps the FIRST 1 MiB of the boot.
# Without one-shot it wraps and overwrites the stream's start -- exactly the
# interesting part, OpenSBI entry and the kernel handoff.
dm 0xA000001C 32 0x8
echo "READY" >&2
PREP_EOF
)"
echo "### Preparing the board (app load, AFIFM, clear rings) ..."
prep_err="$WORK/prep.err"
board_run "$prep" "$prep_err" > /dev/null || true
pe="$(cat "$prep_err" 2>/dev/null || true)"
printf '%s\n' "$pe" | grep -aE 'RESMEM|AFIFM|READY|FAILED|TOO_SMALL|MISSING' \
    | while IFS= read -r l; do echo "  [board] $l"; done || true
if printf '%s' "$pe" | grep -qE 'RESMEM_MISSING'; then
    echo "### RESMEM: guest window not reserved -- apply ctrace_resmem.dtso to the boot devicetree, regenerate user-override.dtb, REBOOT"
    exit 9
fi
printf '%s' "$pe" | grep -q READY || { echo "### PREP_FAILED (see $prep_err)"; exit 1; }

# --- 3. Payload into the window (no workstation round trip for the
# --payload-jump default: 42+ MB streamed jump -> board once, not twice) ---
if [ "$SKIP_LOAD" -eq 0 ]; then
    echo "### Writing the payload to 0x6400_0000 ..."
    dd_err="$WORK/dd.err"
    scp -q "$COMMON_BOARD/mem_load.py" "$JUMP:/tmp/mem_load.py"
    if [ -n "$PAYLOAD_LOCAL" ]; then
        scp -q "$PAYLOAD_LOCAL" "$JUMP:/tmp/fw_payload.bin"
        ssh "$JUMP" \
            "scp -q /tmp/mem_load.py /tmp/fw_payload.bin $USER_@${BOARD}:/tmp/ && \
             ssh $USER_@$BOARD 'echo $SUDO_PASS | sudo -S python3 /tmp/mem_load.py --addr 0x64000000 --file /tmp/fw_payload.bin --verify'" \
            > "$WORK/load.out" 2> "$dd_err" || true
    else
        ssh "$JUMP" \
            "scp -q /tmp/mem_load.py $USER_@${BOARD}:/tmp/mem_load.py && \
             cat $PAYLOAD_JUMP | ssh $USER_@$BOARD 'cat > /tmp/fw_payload.bin && echo $SUDO_PASS | sudo -S python3 /tmp/mem_load.py --addr 0x64000000 --file /tmp/fw_payload.bin --verify'" \
            > "$WORK/load.out" 2> "$dd_err" || true
    fi
    grep -aE 'wrote|verify' "$WORK/load.out" "$dd_err" 2>/dev/null | while IFS= read -r l; do echo "  [board] $l"; done || true
    # The loader's verdict is a GATE, not a log line. Before 2026-08-21 both
    # invocations above ended in `|| true` and nothing looked at the result:
    # mem_load.py died with SIGBUS at 16 MiB, the probe below read the first
    # word of the window -- written, therefore non-zero -- and the run
    # continued with a truncated payload. The guest then booted far enough to
    # print a kernel log and never reached userspace. Demand the proof.
    if ! grep -aq 'verify ok' "$WORK/load.out" "$dd_err" 2>/dev/null; then
        echo "### LOAD_UNVERIFIED -- mem_load.py did not report 'verify ok'."
        echo "  Its output was:"
        sed 's/^/    /' "$dd_err" 2>/dev/null | head -5
        exit 1
    fi

    probe_err="$WORK/probe.err"
    probe="$(board_run "busybox devmem 0x64000000
busybox devmem 0x64400000
" "$probe_err" || true)"
    echo "### DDR probe @0x6400_0000 / @0x6440_0000: $(printf '%s' "$probe" | tr '\n' ' ')"
    if [ -z "$probe" ] || printf '%s' "$probe" | grep -qE '^0x0+[[:space:]]*0x0+$'; then
        echo "### LOAD_MISMATCH -- window is empty, payload did not arrive"
        exit 1
    fi
fi

# --- 4. Arm the encoder, start the core, read the console live -------------
protosel=""
if [ "$PROTO" = "e" ]; then
    protosel='dm 0xA0010030 32 0x1
'
fi
# SendConfig [8:7] = 1 (CFG_ONCE, the RDL reset): one config message per
# trace-on edge, BEFORE the first sync. The ps1 constant 0x01060067 cleared
# it (bit 7 = 0) -- with InstSyncMax=0 that went unnoticed (a sync every 16
# instructions never lets the branch history overflow), with the RDL default
# InstSyncMax=6 the first RCODE=2 history-overflow message met a decoder that
# had never seen the CAPS and walked the listing into _start_hang for 20 M
# PCs (2026-08-17 23:38, kria-kv260). The decoder needs the config message
# to know which compression formats the stream carries; --sendconfig 0
# reproduces the old behaviour on purpose.
ctrl_on="$(printf '0x%08x' $(( 0x01060067 | (SYNCMAX << 20) | (SENDCONFIG << 7) )))"
ctrl_off="$(printf '0x%08x' $(( 0x01060063 | (SYNCMAX << 20) | (SENDCONFIG << 7) )))"
echo "### trTeControl on=$ctrl_on off=$ctrl_off (InstSyncMax=$SYNCMAX SendConfig=$SENDCONFIG)"

run="$(cat <<RUN_EOF
set -e
dm() { busybox devmem "\$@"; }
# SrcID/SrcBits like the multi-core examples (SRC 2 = CVA6), then protocol
# select (trTeProtocolSel is swwel-gated: writable only while Enable=0),
# then arm.
f=\$(dm 0xA0010008)
f=\$(( (f & 0x0000FFFF) | 0x20020000 ))
dm 0xA0010008 32 \$(printf '0x%08x' \$f)
echo "FEAT \$(dm 0xA0010008)" >&2
${protosel}dm 0xA0010000 32 $ctrl_on
echo "CTRL \$(dm 0xA0010000) PSEL \$(dm 0xA0010030)" >&2
# Core loose -- OpenSBI runs from here and the encoder writes into the ring.
dm 0xA0000000 32 0x1
sleep $RUNSEC
# Tracing off (the core keeps running -- the console should keep going).
dm 0xA0010000 32 $ctrl_off
sleep 0.2
echo "TRACE_BEATS \$(dm 0xA0000008) TRACE_BYTES \$(dm 0xA000000C)" >&2
echo "CON_BYTES \$(dm 0xA0000014) CON_DROPS \$(dm 0xA0000018)" >&2
echo "STATUS \$(dm 0xA0000004)" >&2
RUN_EOF
)"
echo "### Encoder armed ($PROTO-trace), starting CVA6 ..."
run_err="$WORK/run.err"
board_run "$run" "$run_err" > /dev/null || true
re="$(cat "$run_err" 2>/dev/null || true)"
printf '%s\n' "$re" | grep -aE 'FEAT|CTRL|PSEL|TRACE_|CON_|STATUS' \
    | while IFS= read -r l; do echo "  [board] $l"; done || true

# --- 5. Console ring (the boot proof) ---------------------------------------
echo "### Reading the console ..."
conread="$(cat <<'EOF'
n=$(busybox devmem 0xA0000014)
n=$((n))
i=0
while [ $i -lt $n ]; do
  busybox devmem $(printf '0x%08x' $((0xA0300000 + i)))
  i=$((i+4))
done
EOF
)"
con_out="$(board_run "$conread" "$WORK/con.err" || true)"
conwords="$(printf '%s\n' "$con_out" | grep -aE '^0x' || true)"
con_bin="$WORK/console.txt"
con_bytes="$("$PY" -c "
import sys
words = [int(x, 16) for x in sys.stdin.read().split()]
data = b''.join(w.to_bytes(4, 'little') for w in words)
open(sys.argv[1], 'wb').write(data)
sys.stdout.write(str(len(data)))
" "$con_bin" <<< "$conwords")"
text="$(cat "$con_bin" 2>/dev/null || true)"
echo "### Console ($con_bytes bytes) -> $con_bin"
echo "----------------------------------------------------------------"
printf '%s\n' "$text"
echo "----------------------------------------------------------------"

# --- 6. Trace ring -----------------------------------------------------------
echo "### Reading the trace ring ..."
traceread="$(cat <<'EOF'
n=$(busybox devmem 0xA000000C)
n=$((n))
[ $n -gt 1048576 ] && n=1048576
i=0
while [ $i -lt $n ]; do
  busybox devmem $(printf '0x%08x' $((0xA0200000 + i)))
  i=$((i+4))
done
EOF
)"
trace_out="$(board_run "$traceread" "$WORK/trace.err" || true)"
tracewords="$(printf '%s\n' "$trace_out" | grep -aE '^0x' || true)"
atb="$WORK/boot_$PROTO.atb.bin"
trace_bytes="$("$PY" -c "
import sys
words = [int(x, 16) for x in sys.stdin.read().split()]
data = b''.join(w.to_bytes(4, 'little') for w in words)
open(sys.argv[1], 'wb').write(data)
sys.stdout.write(str(len(data)))
" "$atb" <<< "$tracewords")"
echo "### Trace: $trace_bytes bytes -> $atb"

# --- 7. Gates ----------------------------------------------------------------
ok=1
case "$text" in *OpenSBI*) ;; *) echo "### GATE_FAIL: no OpenSBI banner in the console"; ok=0;; esac
case "$text" in *"Linux version"*) ;; *) echo "### GATE_WARN: no 'Linux version' -- kernel not entered?";; esac
if [ "$trace_bytes" -eq 0 ]; then echo "### GATE_FAIL: empty trace ring"; ok=0; fi
if [ "$ok" -eq 1 ]; then echo "### BOOT_TRACE_OK"; else echo "### BOOT_TRACE_INCOMPLETE"; fi

# --- 8. Optional decode (new vs. the ps1 -- no pcinfo ships for this
# payload in this migrated tree yet, see README.md) -------------------------
if [ -n "$PCINFO" ]; then
    if [ ! -f "$PCINFO" ]; then
        echo "### DECODE: SKIP -- --pcinfo not found: $PCINFO"
    else
        # shellcheck source=/dev/null
        . "$REPO/scripts/ct_env.sh"
        ct_need_nexrv
        rc=0
        "$NEXRV" -deco "$atb" -pcinfo "$PCINFO" -pcout "$WORK/boot_$PROTO.pcout" -full \
            > "$WORK/decode.log" 2>&1 || rc=$?
        grep -aE '^Stat:' "$WORK/decode.log" || true
        echo "### DECODE exit=$rc (log: $WORK/decode.log, pcout: $WORK/boot_$PROTO.pcout)"
    fi
else
    echo "### DECODE: SKIP -- no --pcinfo given (none exists yet for the CVA6 Linux payload in this tree)"
fi
exit 0
