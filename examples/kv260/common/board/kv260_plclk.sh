#!/bin/sh
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# kv260_plclk.sh -- read/set pl_clk0 of the KV260. DESIGN-AGNOSTIC: valid for
# every PL design of this repository, not just the cv64a6 branch. Runs ON THE
# BOARD.
#
#   sudo bash kv260_plclk.sh                 # show only
#   sudo MHZ=68  bash kv260_plclk.sh         # 68.181818 MHz (divisor 22)
#   sudo MHZ=75  bash kv260_plclk.sh         # set to 75 MHz
#   sudo MHZ=100 bash kv260_plclk.sh         # the value boards come up with
#
# MHZ IS A LABEL, NOT AN EXACT FREQUENCY. f = 1500 MHz / DIVISOR0 is not
# freely choosable with integer divisors; reachable are e.g. 100 (15),
# 75 (20), 71.43 (21), 68.18 (22), 65.22 (23). The label is the value rounded
# down to whole MHz, the shell computes in integer hertz:
#   divisor 22 -> 1500000000/22 = 68181818 Hz. NOT 68000000.
# Every consumer of this output must form the same integer division, or it
# fails on a rounding instead of on an error.
#
# CALLED AUTOMATICALLY by the board runners (`*_run.sh`, phase `prep`) -- the
# clock is set and read back there instead of being taken as found. By hand
# the script is only needed to look, or to deviate.
#
# WHY THIS SCRIPT EXISTS (two independent measurements): the board clocks the
# PL at **100 MHz**, while every design of this repository is constrained
# against 75 MHz. The PL clock comes from CRL_APB and is set by the BOOT
# firmware; an xmutil runtime overlay that only sets `firmware-name` does not
# change it. The 75 MHz from the Vivado PS configuration are therefore an
# assumption of the constraint, not board reality -- otherwise a design runs
# 33 % above its verified frequency (and an mtimer guest clock correspondingly
# too fast).
#
# PL0_REF_CTRL @ 0xFF5E00C0: [24] CLKACT | [21:16] DIVISOR1 | [13:8] DIVISOR0
#                            | [2:0] SRCSEL (0 = IOPLL = 1500 MHz)
#   f = 1500 MHz / (DIVISOR0 * DIVISOR1)
#
# ATTENTION -- the order is mandatory: change the clock ONLY with the PL
# UNLOADED (`xmutil unloadapp` first). A frequency jump under a running design
# is a clock glitch in the middle of the logic; no state is trustworthy after
# it. The script checks this and refuses the change while an app sits in the
# active slot.
set -e
REG=0xFF5E00C0
dm() { busybox devmem "$@"; }

cur=$(dm $REG)
v=$((cur))
div0=$(( (v >> 8) & 0x3F ))
div1=$(( (v >> 16) & 0x3F ))
src=$(( v & 0x7 ))
echo "PL0_REF_CTRL=$cur  SRCSEL=$src DIVISOR0=$div0 DIVISOR1=$div1"
[ "$div0" -gt 0 ] && [ "$div1" -gt 0 ] &&
  echo "pl_clk0 = $(( 1500000000 / (div0 * div1) )) Hz (IOPLL 1500 MHz)"

[ -z "${MHZ:-}" ] && exit 0

case "$MHZ" in
  # 68 = divisor 22 = 68181818 Hz. The ONLY value kept here that is BELOW
  # the 71.110 MHz constraint: that answers the closure question without
  # consulting the achieved column of the individual design. Divisor 21
  # (71.43 MHz) would be above it.
  68)  nd0=22 ;;
  75)  nd0=20 ;;
  100) nd0=15 ;;
  *)   echo "MHZ=$MHZ not supported (68|75|100)" >&2; exit 2 ;;
esac
exp_hz=$(( 1500000000 / nd0 ))

# Occupancy marker: a LOADED app shows a slot->handle pair like "0->0".
# The old check tested $NF!="-1", which false-positives on boards whose
# xmutil wraps rows (kria-kv260: the first physical line ends in XRT_FLAT).
if xmutil listapps 2>/dev/null | grep -qE '[0-9]+->[0-9]+'; then
  echo "ABORT: an app still occupies the active slot -- run 'xmutil unloadapp' first." >&2
  xmutil listapps >&2
  exit 3
fi

new=$(printf '0x%08x' $(( (v & ~(0x3F << 8)) | (nd0 << 8) )))
dm $REG 32 $new
rb=$(dm $REG)
rv=$((rb))
rd0=$(( (rv >> 8) & 0x3F ))
echo "SET $new -> read back $rb  DIVISOR0=$rd0"
echo "pl_clk0 = $(( 1500000000 / (rd0 * ((rv >> 16) & 0x3F)) )) Hz"
[ "$rd0" -eq "$nd0" ] || { echo "CLK_SET_FAILED" >&2; exit 1; }
# The label is rounded, the number above it is not -- print both, so that no
# reader concludes 68000000 Hz from "68MHz".
echo "CLK_SET_OK ${MHZ}MHz (label; DIVISOR0=$nd0 -> $exp_hz Hz)"
