#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# wp_demo_run.sh -- run the tgc5b2_axis_wp watchpoint/DAQ demo on a KV260,
# step by step, exactly along the sequence documented in ../README.md
# ("Running the watchpoint/DAQ testbed").
#
#   bash wp_demo_run.sh [--board kria-kv260] [--app tgc5b2_axis_wp_c0b]
#                       [--pl-mhz 75] [--restore] [--dry-run]
#
# WHY THIS EXISTS NEXT TO wp_board_gate.sh
# ----------------------------------------
# wp_board_gate.sh is the board gate and carries the same mechanics, but its
# transport is hardcoded to two hops -- every board command is
#     ssh $JUMP "ssh ubuntu@$BOARD ..."
# -- because at its origin site the boards only accepted ssh from a jump
# host. On a workstation whose ~/.ssh/config already reaches the board
# directly (ProxyJump, VPN, or a flat network) that indirection is not just
# unnecessary, it fails: the inner ssh runs on the jump host and needs the
# board's key THERE.
#
# This script keeps the gate's proven board-side scripts -- prep_load.sh,
# prep_verify.sh, run_a.sh, restore.sh, wp_board.py, read_wp_stream.py are
# staged and executed UNCHANGED -- and replaces only the transport with one
# direct `ssh $BOARD`. It also drops the --sudo-pass plumbing where the
# board grants passwordless sudo, and falls back to KV260_SUDO_PASS where it
# does not.
#
# It is a demo driver, not a gate: it prints what each step does and why,
# and ends on the same host-side verdict the gate uses (wp_check.py runa).
# For the gate verdict in CI, use wp_board_gate.sh.
#
# THE FOUR TRAPS, honoured here as they are there (../../README.md):
#   1. never `scp -r` into an existing target dir -- staging dirs are removed
#      first, with sudo (the run scripts leave a root-owned __pycache__);
#   2. never touch the PL aperture unless OUR app owns the active slot;
#   3. `xmutil listapps`' slot column decides that, never fpga_manager state;
#   4. STOP ctrace-dashboard BEFORE unloading the PL. It holds /dev/mem
#      mappings onto the live aperture; unloading under it hangs the PS
#      interconnect and only the power switch recovers the board.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RDIR=/tmp/wp_board_run                        # staging dir ON the board

# Two layouts, detected rather than configured. In the repository the pieces
# live in three places; in a shipped customer bundle they are flattened to
# host/ + board/ + app/ + demo/ next to this script. Everything below uses
# only TOOLS / COMMON_BOARD / WORK / APPDIR_BASE, so the rest of the script is
# identical in both.
if [ -d "$HERE/../../../../tools/axis_wp_host" ]; then
    LAYOUT=repo
    EX="$(dirname "$HERE")"                   # examples/kv260/tgc5b2_axis_wp
    TE_ROOT="$(cd "$EX/../../.." && pwd)"
    TOOLS="$TE_ROOT/tools/axis_wp_host"
    COMMON_BOARD="$TE_ROOT/examples/kv260/common/board"
    WORK="$HERE/run"                          # gen output + logs
    APPDIR_BASE="$WORK/app_pkg"
else
    LAYOUT=bundle
    BUNDLE="$(dirname "$HERE")"
    TOOLS="$BUNDLE/host"
    COMMON_BOARD="$HERE"                      # flattened into board/
    WORK="$BUNDLE/run"                        # logs; demo data is copied in
    APPDIR_BASE="$BUNDLE/app"
    mkdir -p "$WORK"
    # The generated demo data lives in demo/ in a bundle; the steps below and
    # wp_check.py both read it from WORK, so mirror it once.
    for f in wp_table.txt wp_real.txt expected_full.txt prog.hex; do
        [ -f "$WORK/$f" ] || cp "$BUNDLE/demo/$f" "$WORK/" 2>/dev/null || true
    done
fi

BOARD="${KV260_BOARD:-kria-kv260}"
APP="tgc5b2_axis_wp_c0b"
PLMHZ=75
DO_RESTORE=0
DRY_RUN=0
PY="${PY:-python3}"

while [ $# -gt 0 ]; do
    case "$1" in
        --board)   BOARD="$2"; shift 2;;
        --app)     APP="$2"; shift 2;;
        --pl-mhz)  PLMHZ="$2"; shift 2;;
        --restore) DO_RESTORE=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "wp_demo_run: unknown argument $1" >&2; exit 2;;
    esac
done

APPDIR="$APPDIR_BASE/$APP"
B=$(tput bold 2>/dev/null || true); R=$(tput sgr0 2>/dev/null || true)
STEP=0

step() {
    STEP=$((STEP + 1))
    echo
    echo "${B}=========================================================================${R}"
    echo "${B}STEP $STEP -- $1${R}"
    echo "  $2"
    echo "${B}=========================================================================${R}"
}
die() { echo; echo "### DEMO_FAILED (step $STEP): $*" >&2; exit 1; }

# Board-side sudo. Resolved once in step 1: passwordless where available,
# otherwise KV260_SUDO_PASS piped into `sudo -S`.
SUDO="sudo"
rsh()  { [ "$DRY_RUN" = "1" ] && { echo "[dry-run] ssh $BOARD $*"; return 0; }; ssh "$BOARD" "$@"; }
rsudo() {  # run one command line on the board as root
    if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] ssh $BOARD (root) $*"; return 0; fi
    ssh "$BOARD" "$SUDO $*"
}

# =============================================================================
step "Preflight -- host artifacts, board reachable, sudo mode" \
     "Nothing is touched yet. Checks that --phase gen has run (the packaged app
  and the oracle files) and that the board answers."

for f in wp_table.txt wp_real.txt expected_full.txt prog.hex; do
    [ -f "$WORK/$f" ] || die "$WORK/$f missing -- run: bash wp_board_gate.sh --phase gen"
done
for f in "$APP.bit.bin" "$APP.dtso" shell.json; do
    [ -f "$APPDIR/$f" ] || die "$APPDIR/$f missing -- run: bash wp_board_gate.sh --phase gen"
done
LOCAL_MD5="$(md5sum "$APPDIR/$APP.bit.bin" | awk '{print $1}')"
echo "  app     : $APPDIR"
echo "  bit.bin : $LOCAL_MD5"
echo "  oracle  : $(grep -c . "$WORK/expected_full.txt") expected records, $(grep -c . "$WORK/wp_real.txt") real watchpoints"

if [ "$DRY_RUN" != "1" ]; then
    timeout 20 ssh -o ConnectTimeout=8 -o BatchMode=yes "$BOARD" true 2>/dev/null \
        || die "board '$BOARD' not reachable -- power it on however your site does that"
    if ssh "$BOARD" 'sudo -n true' 2>/dev/null; then
        SUDO="sudo"
        echo "  sudo    : passwordless"
    else
        [ -n "${KV260_SUDO_PASS:-}" ] || die "board needs a sudo password -- set KV260_SUDO_PASS"
        SUDO="echo ${KV260_SUDO_PASS} | sudo -S"
        echo "  sudo    : via KV260_SUDO_PASS"
    fi
    echo "  board   : $(ssh "$BOARD" 'hostname; uptime -p' | tr '\n' ' ')"
fi

# =============================================================================
step "Stage the board-side tooling and the demo data" \
     "Copies the AXIS reader, the board control script and the generated demo
  data (program image, watchpoint table, oracle) to $RDIR.
  The staging dir is removed WITH SUDO first -- the run scripts execute as
  root and leave a root-owned __pycache__ a plain rm cannot clear (trap 1)."

files=(
    "$TOOLS/fifo_mm_s.py" "$TOOLS/wp_records.py" "$TOOLS/checks.py"
    "$TOOLS/read_wp_stream.py" "$TOOLS/wp_load_indirect.py"
    "$COMMON_BOARD/kv260_plclk.sh"
    "$HERE/wp_board.py" "$HERE/prep_load.sh" "$HERE/prep_verify.sh"
    "$HERE/run_a.sh" "$HERE/run_b.sh" "$HERE/restore.sh"
    "$WORK/wp_table.txt" "$WORK/wp_real.txt" "$WORK/expected_full.txt" "$WORK/prog.hex"
)
for f in "${files[@]}"; do [ -f "$f" ] || die "tooling file missing: $f"; done

rsudo "rm -rf $RDIR" || die "could not clear $RDIR"
rsh "mkdir -p $RDIR" || die "could not create $RDIR"
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] scp -q <${#files[@]} files> $BOARD:$RDIR/"
else
    scp -q "${files[@]}" "$BOARD:$RDIR/" || die "staging scp failed"
    echo "  staged ${#files[@]} files in $RDIR"
fi

# =============================================================================
step "Pre-load -- stop the dashboard, unload the PL, set pl_clk0 to $PLMHZ MHz" \
     "prep_load.sh, unchanged from the gate. Order matters: the dashboard is the
  other possible master of the FIFO windows and holds /dev/mem mappings onto
  the live aperture -- unloading the PL under it hangs the PS interconnect
  and only a power cycle recovers the board (trap 4). The PL clock may only
  be changed while the PL is unloaded, which is why it happens here and not
  after the load."

PREP_LOG="$WORK/demo_prep_load.log"
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] ssh $BOARD (root) sh $RDIR/prep_load.sh $PLMHZ"
else
    rsudo "sh $RDIR/prep_load.sh $PLMHZ" 2>&1 | tee "$PREP_LOG"
    grep -q "PREP_LOAD_OK" "$PREP_LOG" || die "prep_load.sh did not reach PREP_LOAD_OK (see $PREP_LOG)"
    grep -q "PLCLK_FAILED" "$PREP_LOG" && die "pl_clk0 could not be set to $PLMHZ MHz (see $PREP_LOG)"
    PREV_APP="$(awk '/PREV_LISTAPPS_BEGIN/,/PREV_LISTAPPS_END/' "$PREP_LOG" \
                | awk '$NF ~ /^[0-9]+$/ && $NF != "-1" {print $1}' | head -1)"
    [ -n "${PREV_APP:-}" ] || PREV_APP="(none active)"
    echo "$PREV_APP" > "$WORK/demo_prev_app.txt"
    echo "  previously active app : $PREV_APP  (recorded for --restore)"
    echo "  dashboard was         : $(grep -m1 DASHBOARD_WAS "$PREP_LOG" | awk '{print $2}')"
fi

# =============================================================================
step "Load the bitstream as a Kria app" \
     "Compiles the device-tree overlay ON the board (dtc lives there), installs
  bit.bin + dtbo + shell.json under /lib/firmware/xilinx/$APP, then
  xmutil loadapp. The deploy counts as verified ONLY by the bit.bin hash read
  back on the target -- 'app listed' is not evidence."

if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] scp -r $APPDIR $BOARD:/tmp/$APP  + dtc + install + xmutil loadapp"
else
    rsudo "rm -rf /tmp/$APP" || die "could not clear /tmp/$APP"
    scp -q -r "$APPDIR" "$BOARD:/tmp/$APP" || die "app scp failed"
    ssh "$BOARD" "
set -e
cd /tmp/$APP
dtc -@ -I dts -O dtb -o $APP.dtbo $APP.dtso
$SUDO bash -c 'mkdir -p /lib/firmware/xilinx/$APP && cp /tmp/$APP/$APP.bit.bin /tmp/$APP/$APP.dtbo /tmp/$APP/shell.json /lib/firmware/xilinx/$APP/ && xmutil unloadapp >/dev/null 2>&1; xmutil loadapp $APP'
md5sum /lib/firmware/xilinx/$APP/$APP.bit.bin
" 2>&1 | tee "$WORK/demo_load.log"
    REMOTE_MD5="$(grep -oE '^[0-9a-f]{32}' "$WORK/demo_load.log" | tail -1)"
    [ "$REMOTE_MD5" = "$LOCAL_MD5" ] \
        || die "HASH_MISMATCH -- local $LOCAL_MD5 vs target '${REMOTE_MD5:-<none>}'"
    echo "  bit.bin verified on target: $REMOTE_MD5"
fi

# =============================================================================
step "Verify the design is alive on the AXI bus" \
     "prep_verify.sh, unchanged: fpga_manager must report 'operating', pl_clk0 is
  re-read (read-only probe), and the WPCTRL magic register must read 0x41575031
  ('AWP1'). That last read is the proof the PL actually answers -- without it
  every later /dev/mem access is a guess."

VERIFY_LOG="$WORK/demo_prep_verify.log"
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] ssh $BOARD (root) sh $RDIR/prep_verify.sh"
else
    rsudo "sh $RDIR/prep_verify.sh" 2>&1 | tee "$VERIFY_LOG"
    grep -q "FPGA_NOT_OPERATING" "$VERIFY_LOG" && die "fpga_manager not operating (see $VERIFY_LOG)"
    grep -q "MAGIC 0x41575031" "$VERIFY_LOG" || die "WPCTRL magic wrong -- design not answering (see $VERIFY_LOG)"
    grep -q "PREP_OK" "$VERIFY_LOG" || die "prep_verify.sh did not reach PREP_OK (see $VERIFY_LOG)"
    echo "  MAGIC 0x41575031 -- the design answers on the AXI bus"
fi

# =============================================================================
step "Run the RISC-V demo and capture the ACT-CAP/ACT-ST stream" \
     "run_a.sh, unchanged from the gate. In order: hold both TGC5B cores, write
  the program image word-by-word into RAM0/RAM1, load the 1023-slot watchpoint
  table into each encoder and configure it, reset both RX FIFOs, release the
  cores, let the finite walk run itself out, halt, then drain FIFO0 (0xA0410000)
  and FIFO1 (0xA0420000) through the AXIS reader.
  Expected: 851 records per core, 0 drops."

# wp_check.py reads this by an exact name (wp_check.py:100) -- do not rename.
RUN_LOG="$WORK/board_runA.log"
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] ssh $BOARD (root) sh $RDIR/run_a.sh"
else
    rsudo "sh $RDIR/run_a.sh" 2>&1 | tee "$RUN_LOG"
    grep -q "RUN_A_DONE" "$RUN_LOG" || die "run_a.sh did not reach RUN_A_DONE (see $RUN_LOG)"
    for mk in READER_A0_RC=0 READER_A1_RC=0; do
        grep -qF "$mk" "$RUN_LOG" || die "$mk missing or non-zero -- a FIFO drain failed (see $RUN_LOG)"
    done
fi

# =============================================================================
step "Fetch the captured records and check them against the oracle" \
     "Pulls both reader logs back and runs wp_check.py -- the same host-side
  verdict the gate uses: full list equality against expected_full.txt (not just
  a count), per-record metadata (slot index, tid, tstrb), drop/overflow-free
  operation, and a cross-core timestamp merge."

if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] scp $BOARD:$RDIR/runA_reader_fifo{0,1}.log $WORK/ && $PY wp_check.py runa"
else
    scp -q "$BOARD:$RDIR/runA_reader_fifo0.log" "$BOARD:$RDIR/runA_reader_fifo1.log" "$WORK/" \
        || die "could not fetch the reader logs"
    echo "  fetched: $WORK/runA_reader_fifo0.log, $WORK/runA_reader_fifo1.log"
    echo
    "$PY" "$HERE/wp_check.py" runa --work "$WORK" || die "G1CHECK runa FAILED"
fi

# =============================================================================
if [ "$DO_RESTORE" = "1" ]; then
    step "Restore the board" \
         "Unloads our app, reloads whatever was active before step 3, and restarts
  the dashboard service."
    PREV="$(cat "$WORK/demo_prev_app.txt" 2>/dev/null || echo '')"
    case "$PREV" in
        ""|"(none active)") echo "  no previously active app recorded -- unloading only";
                            rsudo "xmutil unloadapp" >/dev/null 2>&1 || true;
                            rsudo "systemctl start ctrace-dashboard" || true;;
        *) rsudo "sh $RDIR/restore.sh $PREV $APP" 2>&1 | tee "$WORK/demo_restore.log";;
    esac
else
    echo
    echo "  NOTE: the board is left with $APP loaded and ctrace-dashboard stopped."
    echo "        Re-run with --restore to put it back, or start the dashboard by hand:"
    echo "          ssh $BOARD 'sudo systemctl start ctrace-dashboard'"
fi

echo
echo "### DEMO_OK -- $APP on $BOARD, run A captured and checked"
echo "    logs and captured records: $WORK"
