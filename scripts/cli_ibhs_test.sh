#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# B2 IBHS verification (seq 24; local bring-up aid, cli_* pattern).
# Runs tests/instruction/13_ibhs twice (OFF = reset default, ON = +IBHS),
# NexRv-decodes both and gates:
#   - OFF: zero TCODE-29 messages, >= 3 RCODE=1 pre-flushes (historical form)
#   - ON : >= 3 TCODE-29 messages, RCODE=1 count strictly smaller than OFF
#   - both legs PC-lossless against the same cpu_model reference (prefix,
#     tail-truncation tolerated like cli_ir_test)
#   - ON stream strictly smaller than OFF (bandwidth win)
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=ibhs_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/13_ibhs/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_one () { # $1 = tag, $2... = extra xsim args
	local tag="$1"; shift
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin" "atb_${tag}.bin"
	"$NEXRV" -deco "atb_${tag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${tag}.pcout" -full > "nexrv_${tag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
}

echo "### run OFF"; run_one off
echo "### run ON ";  run_one on -testplusarg IBHS

exp="${tb}.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp"   > exp.norm
norm off.pcs  > off.norm
norm on.pcs   > on.norm
n_exp=$(grep -c . exp.norm); n_off=$(grep -c . off.norm); n_on=$(grep -c . on.norm)
sz_off=$(stat -c%s atb_off.bin); sz_on=$(stat -c%s atb_on.bin)

t29_off=$(grep -cE 'TCODE\[6\]=29 ' nexrv_off.log || true)
t29_on=$(grep -cE 'TCODE\[6\]=29 ' nexrv_on.log || true)
r1_off=$(grep -cE 'RCODE\[4\]=0x1\b' nexrv_off.log || true)
r1_on=$(grep -cE 'RCODE\[4\]=0x1\b' nexrv_on.log || true)
# Payload bytes / message count from the NexRv stat line -- the honest
# bandwidth measure (the .bin size is ATB-beat-quantized and pads the
# difference away on small workloads).
pb_off=$(sed -nE 's/^Stat: ([0-9]+) bytes, ([0-9]+) messages.*/\1 \2/p' nexrv_off.log)
pb_on=$(sed -nE 's/^Stat: ([0-9]+) bytes, ([0-9]+) messages.*/\1 \2/p' nexrv_on.log)
bytes_off=${pb_off% *}; msgs_off=${pb_off#* }
bytes_on=${pb_on% *};  msgs_on=${pb_on#* }

pfx=$(( n_off < n_on ? n_off : n_on ))
head -n "$pfx" exp.norm > exp.pfx
head -n "$pfx" off.norm > off.pfx
head -n "$pfx" on.norm  > on.pfx

echo "======================================================"
echo "expected PCs   : $n_exp"
echo "OFF: $n_off PCs, atb $sz_off B, TCODE29=$t29_off RCODE1=$r1_off"
echo "ON : $n_on PCs, atb $sz_on B, TCODE29=$t29_on RCODE1=$r1_on"
echo "verified prefix: $pfx PCs"
echo "------------------------------------------------------"
verdict=0
if cmp -s exp.pfx off.pfx; then echo "OFF prefix == reference : PASS"; else echo "OFF prefix == reference : FAIL"; verdict=1; diff exp.pfx off.pfx | head; fi
if cmp -s exp.pfx on.pfx;  then echo "ON  prefix == reference : PASS"; else echo "ON  prefix == reference : FAIL"; verdict=1; diff exp.pfx on.pfx | head; fi
if [ "$t29_off" -eq 0 ]; then echo "OFF has no TCODE 29     : PASS"; else echo "OFF has no TCODE 29     : FAIL ($t29_off)"; verdict=1; fi
if [ "$t29_on" -ge 3 ]; then echo "ON  TCODE 29 >= 3       : PASS ($t29_on)"; else echo "ON  TCODE 29 >= 3       : FAIL ($t29_on)"; verdict=1; fi
if [ "$r1_off" -ge 3 ]; then echo "OFF RCODE1 pre-flush >=3: PASS ($r1_off)"; else echo "OFF RCODE1 pre-flush >=3: FAIL ($r1_off)"; verdict=1; fi
if [ "$r1_on" -lt "$r1_off" ]; then echo "ON  RCODE1 < OFF        : PASS ($r1_on < $r1_off)"; else echo "ON  RCODE1 < OFF        : FAIL ($r1_on vs $r1_off)"; verdict=1; fi
if [ "$bytes_on" -lt "$bytes_off" ] && [ "$msgs_on" -lt "$msgs_off" ]; then
	pct=$(( 100 - bytes_on*100/bytes_off ))
	echo "ON payload < OFF        : PASS ($bytes_off -> $bytes_on B (-$pct%), $msgs_off -> $msgs_on msgs; atb.bin $sz_off -> $sz_on B beat-quantized)"
else
	echo "ON payload < OFF        : FAIL (bytes $bytes_off -> $bytes_on, msgs $msgs_off -> $msgs_on)"; verdict=1
fi
echo "======================================================"
[ $verdict -eq 0 ] && [ "$pfx" -gt 50 ] && echo "OVERALL: PASS" || { echo "OVERALL: FAIL (prefix=$pfx)"; verdict=1; }
exit $verdict
