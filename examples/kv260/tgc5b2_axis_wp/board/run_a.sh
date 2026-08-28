#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# run_a.sh -- G1 run A (finite walk, root, ON THE BOARD): prep --walk 0 ->
# FIFO reset (F1 --reset) -> start -> the walk ends itself -> stop -> drain
# via the F1 reader (single FIFO master, sequential legs).
#
# Ported unchanged in substance from the predecessor repository's g1_run_a.sh; only the
# work directory changed (/tmp/g1 -> /tmp/wp_board_run) and the board
# control script's new name (g1_board.py -> wp_board.py).
#
#   sudo sh run_a.sh
cd /tmp/wp_board_run || exit 2
python3 wp_board.py prep --walk 0 || { echo PREP_PY_FAILED; exit 3; }
echo "== FIFO-RESET (F1 --reset, before core start) =="
python3 read_wp_stream.py --source fifo --base 0xA0410000 --reset || { echo RESET0_FAILED; exit 4; }
python3 read_wp_stream.py --source fifo --base 0xA0420000 --reset || { echo RESET1_FAILED; exit 4; }
python3 wp_board.py start || { echo START_FAILED; exit 3; }
sleep 1
python3 wp_board.py stop || { echo STOP_FAILED; exit 3; }
echo "== DRAIN A fifo0 (F1 reader, --ts-mode wrap) =="
python3 read_wp_stream.py --source fifo --base 0xA0410000 --core 0 \
  --wp-set wp_real.txt --expected expected_full.txt --ts-mode wrap \
  --raw > runA_reader_fifo0.log 2>&1
echo "READER_A0_RC=$?"
grep -E "^(SEQ|COUNTS|FIFO|RESULT)" runA_reader_fifo0.log
echo "== DRAIN A fifo1 =="
python3 read_wp_stream.py --source fifo --base 0xA0420000 --core 1 \
  --wp-set wp_real.txt --expected expected_full.txt --ts-mode wrap \
  --raw > runA_reader_fifo1.log 2>&1
echo "READER_A1_RC=$?"
grep -E "^(SEQ|COUNTS|FIFO|RESULT)" runA_reader_fifo1.log
echo "RUN_A_DONE"
