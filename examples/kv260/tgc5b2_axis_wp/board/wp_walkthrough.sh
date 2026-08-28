#!/bin/bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# wp_walkthrough.sh -- an interactive, step-by-step run through the
# tgc5b2_axis_wp watchpoint testbed on a KV260 board.
#
# A thin wrapper around wp_board_gate.sh (which carries the actual,
# board-proven mechanics): between the phases it shows WHAT is about to
# happen, WHICH program is loaded into the two TGC5B RISC-V cores, WHICH
# watchpoint table the encoders receive, and at the end the PARSED AXIS
# watchpoint stream of both FIFOs.
#
#   bash wp_walkthrough.sh --board <ip> --jump <host>
#
# Board and jump host have no defaults; they come from --board/--jump or from
# the environment variables KV260_BOARD/KV260_JUMP (the same convention as
# wp_board_gate.sh).
#
# Per step: [Enter] runs it, s skips it, q aborts.
# Precondition: --phase gen has run (artefacts under board/run/) and the
# bitfile lies under fpga/proj/.../tgc5b2_kv260_top.bit -- step 1 checks
# both.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX="$(dirname "$HERE")"                      # examples/kv260/tgc5b2_axis_wp
TE_ROOT="$(cd "$EX/../../.." && pwd)"
WORK="$HERE/run"
GATE="$HERE/wp_board_gate.sh"
export PY="${PY:-python3}"

BOARD="${KV260_BOARD:-}"; JUMP="${KV260_JUMP:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="$2"; shift 2;;
        --jump)  JUMP="$2";  shift 2;;
        *) echo "unknown argument: $1"; exit 2;;
    esac
done

[ -n "$BOARD" ] || { echo "### ERROR: --board <ip> required (or set KV260_BOARD)"; exit 2; }
[ -n "$JUMP" ]  || { echo "### ERROR: --jump <host> required (or set KV260_JUMP)"; exit 2; }

BOLD=$(tput bold 2>/dev/null || true); DIM=$(tput dim 2>/dev/null || true)
RST=$(tput sgr0 2>/dev/null || true)

step() { # $1=title  $2=explanation  after that: the commands
    echo
    echo "${BOLD}=============================================================="
    echo "  $1"
    echo "==============================================================${RST}"
    printf '%b\n' "$2"
    printf "${BOLD}[Enter]${RST} run   ${BOLD}s${RST}+Enter skip   ${BOLD}q${RST}+Enter abort > "
    read -r ans
    case "$ans" in
        q) echo "Aborted."; exit 0;;
        s) echo "${DIM}-- skipped --${RST}"; return 1;;
    esac
    return 0
}

# ------------------------------------------------------------------ step 1
step "1/8  ARTEFACT CHECK -- what is about to go onto the board" "
The PL design: ${DIM}fpga/proj/tgc5b2_axis_wp.runs/impl_1/tgc5b2_kv260_top.bit${RST}
  2x MINRES TGC5B (RV32), each with one ct_encoder whose ACT-ST/ACT-CAP AXIS
  path runs through a ct_axis_wp_shim into an axi_fifo_mm_s (FIFO0/FIFO1),
  plus the Nexus funnel and the URAM ring / DDR / PIB as trace sinks.
Packaged (gen phase) as a Kria app: ${DIM}board/run/app_pkg/tgc5b2_axis_wp_c0b/${RST}" && {
    bit="$EX/fpga/proj/tgc5b2_axis_wp.runs/impl_1/tgc5b2_kv260_top.bit"
    for f in "$bit" "$WORK/app_pkg/tgc5b2_axis_wp_c0b/tgc5b2_axis_wp_c0b.bit.bin" \
             "$WORK/prog.hex" "$WORK/wp_table.txt" "$WORK/expected_full.txt"; do
        [ -f "$f" ] || { echo "MISSING: $f  (run the fpga/ flow resp. --phase gen first)"; exit 1; }
    done
    echo "bit:      $(md5sum "$bit" | cut -c1-12)...  ($(stat -c%s "$bit") Bytes)"
    echo "bit.bin:  $(md5sum "$WORK/app_pkg/tgc5b2_axis_wp_c0b/tgc5b2_axis_wp_c0b.bit.bin" | cut -c1-12)..."
    rpt="$EX/fpga/reports/tgc5b2_axis_wp_timing_summary.rpt"
    [ -f "$rpt" ] && echo "Timing:   WNS $(grep -m1 -A2 'WNS(ns)' "$rpt" | tail -1 | awk '{print $1}') ns (from $rpt)"
    echo "OK -- all artefacts present."
}

# ------------------------------------------------------------------ step 2
step "2/8  THE RISC-V APPLICATION -- what is loaded into the two CPUs" "
${DIM}sw/axis_wp_demo${RST}: a deterministic, IRQ-paced walk across about 300
generated leaf functions (gen_program.py, seeded). THE SAME image is written
word by word into RAM0 AND RAM1 by wp_board.py prep -- both cores run it
independently. Every function entry that stands in the watchpoint table
produces an ACT-ST hit -> a four-word record on the AXIS path of that
core." && {
    echo "prog.hex: $(wc -l < "$WORK/prog.hex") words ($(($(wc -l < "$WORK/prog.hex")*4)) bytes)"
    echo "symbols:  $(wc -l < "$EX/sw/axis_wp_demo_symbols.map") entries (sw/axis_wp_demo_symbols.map)"
    echo; echo "${DIM}-- start of the disassembly (sw/axis_wp_demo.dis) --${RST}"
    sed -n '1,18p' "$EX/sw/axis_wp_demo.dis"
    echo "${DIM}   ... in full: less $EX/sw/axis_wp_demo.dis${RST}"
}

# ------------------------------------------------------------------ step 3
step "3/8  THE WATCHPOINT TABLE -- what the encoders look for" "
Each encoder is loaded with the 1023-slot table through the indirect CSR
protocol (trWpIndex/trWpDataLow/High). The ACT-ST engine searches the table
binarily on every retire beat; a hit produces the AXIS record (slot index,
PC, timestamp, tid/tstrb)." && {
    echo "table:         $(wc -l < "$WORK/wp_table.txt") lines (wp_table.txt, padding slots included)"
    echo "real WPs:      $(wc -l < "$WORK/wp_real.txt") (wp_real.txt)"
    echo "expected hits (finite walk, per core): $(wc -l < "$WORK/expected_full.txt")"
    echo; echo "${DIM}-- the first 5 real watchpoints (address -> slot) --${RST}"
    head -5 "$WORK/wp_real.txt"
}

# ------------------------------------------------------------------ step 4
step "4/8  DEPLOY -- load the app and stage the tooling  ${DIM}(touches the board!)${RST}" "
If other sessions might be working on the same board, coordinate access
first. What happens now (via $JUMP -> $BOARD):
  1. reader/runner tooling to /tmp/wp_board_run on the board
  2. prep_load.sh: stop the dashboard (single master on the FIFO), unload the
     previous app, pl_clk0 = 75 MHz
  3. dtso->dtbo, install into /lib/firmware/xilinx/, xmutil loadapp,
     md5 verification of the bit.bin on the target" && {
    bash "$GATE" --phase deploy --board "$BOARD" --jump "$JUMP" || { echo "DEPLOY FAILED"; exit 1; }
}

# ------------------------------------------------------------------ step 5
step "5/8  RUN A -- the finite walk, recorded  ${DIM}(touches the board!)${RST}" "
run_a.sh runs on the board:
  prep:  program -> RAM0/RAM1, WP table -> both encoders, walk mode 0
  reset: both FIFOs cleared
  run:   start both cores, the walk ends itself, the cores stop
  drain: read_wp_stream.py reads FIFO0 (0xA041_0000) and FIFO1 (0xA042_0000)
The reader logs come back to board/run/ automatically." && {
    bash "$GATE" --phase runa --board "$BOARD" --jump "$JUMP" || { echo "RUN A FAILED (log: $WORK/board_runA.log)"; exit 1; }
}

# ------------------------------------------------------------------ step 6
step "6/8  ORACLE COMPARISON (host side, without the board)" "
wp_check.py compares the recorded records of both FIFOs against
expected_full.txt: the count (expected per core: $(wc -l < "$WORK/expected_full.txt" 2>/dev/null || echo '?')),
the sequence, the metadata (slot, tid, tstrb), 0 drops, and the cross-core
timestamp merge." && {
    bash "$GATE" --phase checksa || echo "(CHECKS_FAIL -- details above; logs under $WORK/)"
}

# ------------------------------------------------------------------ step 7
step "7/8  THE PARSED AXI STREAM -- show the records" "
Every line is one parsed four-word AXIS record:
  index = watchpoint slot   pc = address of the hit   ts = fabric timestamp
  tid/tstrb = AXIS sideband (core id / strobe)" && {
    for c in 0 1; do
        log="$WORK/runA_reader_fifo$c.log"
        [ -f "$log" ] || { echo "missing: $log"; continue; }
        n=$(grep -c "WpRecord" "$log")
        echo; echo "${BOLD}-- FIFO$c (core $c): $n records --${RST}"
        grep "WpRecord" "$log" | head -10
        echo "${DIM}   ...${RST}"
        grep "WpRecord" "$log" | tail -3
        grep -E "^(SEQ|COUNTS|FIFO|RESULT)" "$log"
    done
    echo; echo "${DIM}In full: less $WORK/runA_reader_fifo0.log resp. ...fifo1.log${RST}"
}

# ------------------------------------------------------------------ step 8
step "8/8  RESTORE -- put the board back  ${DIM}(touches the board!)${RST}" "
Restores the previously active Kria app (from board/run/prev_app.txt, which
prep_load saved during the deploy) and starts the dashboard again. Release
the board afterwards if you reserved it.
${DIM}(Skip this if you still want RUN B or your own devmem experiments --
until then the WP app stays loaded.)${RST}" && {
    bash "$GATE" --phase restore --board "$BOARD" --jump "$JUMP" || echo "(restore reports an error -- check the state of the board)"
}

echo
echo "${BOLD}Done.${RST} Recordings: $WORK/runA_reader_fifo{0,1}.log"
echo "Endless variant: bash $GATE --phase runb --board $BOARD --jump $JUMP  (+ checksb)"
