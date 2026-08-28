#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# run_b.sh -- G1 run B (endless walk, root, ON THE BOARD): prep --walk 1 ->
# FIFO reset -> start -> per-FIFO backlog flush + timed drain ($1 seconds,
# cap $2 records) -> stop -> backlog rest-drain -> status.
#
# Ported unchanged in substance from the predecessor repository's g1_run_b.sh. The source
# generated this script at runtime from a heredoc with __DURB__/__MAXB__
# text placeholders substituted in; this is now a static checked-in file,
# so the two values are positional arguments instead.
#
#   sudo sh run_b.sh <drain-seconds> <max-records>
DURB="${1:?usage: run_b.sh <drain-seconds> <max-records>}"
MAXB="${2:?usage: run_b.sh <drain-seconds> <max-records>}"
cd /tmp/wp_board_run || exit 2
free -m | sed -n 1,2p
python3 wp_board.py prep --walk 1 || { echo PREP_PY_FAILED; exit 3; }
echo "== FIFO-RESET (F1 --reset, before core start) =="
python3 read_wp_stream.py --source fifo --base 0xA0410000 --reset || { echo RESET0_FAILED; exit 4; }
python3 read_wp_stream.py --source fifo --base 0xA0420000 --reset || { echo RESET1_FAILED; exit 4; }
python3 wp_board.py start || { echo START_FAILED; exit 3; }
for C in 0 1; do
  [ "$C" = "1" ] && BASE=0xA0420000 || BASE=0xA0410000
  # Flush pre-drain (lab finding, 2026-08-13): the legs run
  # SEQUENTIALLY (single FIFO master) -- the second leg would otherwise find
  # exactly 1281 records of backlog (FIFO 1024 + shim 256 + 1) from right
  # after core start, followed by the first fresh record ~145 s later: a
  # forward jump > 2^31 that the 32-bit wrap heuristic MUST report as "TS
  # backwards". The flush pulls that old backlog off COUNTED (the drop
  # balance stays exact; --reset would throw the 1281 records away
  # unbalanced); its RESULT may legitimately be FAIL because of exactly
  # that era jump and is not gated on here -- checksb checks its counter
  # hygiene instead (see wp_check.py's runb branch).
  # --max-records is the MANDATORY terminator for the flush: --duration-s is
  # only checked "after each drained window" per fifo_mm_s.drain_poll's
  # contract -- under continuous production the window never empties (2026-
  # 08-13: an uncapped flush ran 12 min / 3.0 GB RSS and the board's OOM
  # killer took it at 66 MB free).
  echo "== FLUSH B fifo$C (backlog pre-drain, cap 4000, not TS-gated) =="
  python3 read_wp_stream.py --source fifo --base $BASE --core $C \
    --wp-set wp_real.txt --expected expected_full.txt --expected-cycle \
    --ts-mode wrap --poll-ms 5 --duration-s 1 --max-records 4000 \
    > runB_flush_fifo$C.log 2>&1
  echo "FLUSH_B${C}_RC=$?"
  grep -E "^(SEQ|COUNTS|FIFO|RESULT)" runB_flush_fifo$C.log
  echo "== DRAIN B fifo$C ($DURB s continuous drain, cap $MAXB) =="
  T0=$(date +%s)
  python3 read_wp_stream.py --source fifo --base $BASE --core $C \
    --wp-set wp_real.txt --expected expected_full.txt --expected-cycle \
    --ts-mode wrap --poll-ms 5 --duration-s $DURB \
    --max-records $MAXB > runB_reader_fifo$C.log 2>&1
  echo "READER_B${C}_RC=$?"
  echo "DRAIN_B${C}_SECS=$(( $(date +%s) - T0 ))"
  grep -E "^(SEQ|COUNTS|FIFO|RESULT)" runB_reader_fifo$C.log
done
python3 wp_board.py stop || { echo STOP_FAILED; exit 3; }
echo "== REST-DRAIN (backlog after halt, 2 s per FIFO) =="
for C in 0 1; do
  [ "$C" = "1" ] && BASE=0xA0420000 || BASE=0xA0410000
  python3 read_wp_stream.py --source fifo --base $BASE --core $C \
    --wp-set wp_real.txt --expected expected_full.txt --expected-cycle \
    --ts-mode wrap --poll-ms 5 --duration-s 2 > runB_rest_fifo$C.log 2>&1
  echo "REST_B${C}_RC=$?"
  grep -E "^(SEQ|COUNTS|FIFO|RESULT)" runB_rest_fifo$C.log
done
python3 wp_board.py status
free -m | sed -n 1,2p
echo "RUN_B_DONE"
