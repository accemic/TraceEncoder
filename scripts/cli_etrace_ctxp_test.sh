#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# EC6 regression: E-Trace (te_inst) -> NexRv -decoe -> CTXP, gated three ways
# per leg against independent references (audit-the-auditor):
#
#   EC2  reconstructed PC sequence  == vendored Siemens Python decoder oracle
#                                      (byte-identical)
#   EC3  CTXP control-flow records  == independent Python-model CF reference
#                                      (etrace_ctxp_ref.py, same stream)
#   EC4  CTXP INTERRUPT record count == dump_te.py interrupt=1 TRAP count
#
# It reuses the E-Trace leg artifacts produced by cli_etrace_test.sh
# (bld/etrace_<leg>/: atb_*.bin, <tb>.nexrv.info, <tb>.expected.pcs). Run
# cli_etrace_test.sh <leg> first if a leg's bld dir is missing.
#
# This gate needs a decoder carrying the -decoe (E-Trace) front end. Since
# 2026-08-17 the pinned CTTD (scripts/cttd.pin, fetched into bin/) carries it
# -- the AP2 consolidation folded the E-Trace decoder line into CTTD -- so
# the gate runs by default on the fetched build (ct_env resolves $NEXRV) and
# no longer skips. NEXRV_DECOE still overrides for a deliberate cross-check
# against another build.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_nexrv

# Python launcher: the function, not the name. The presence loop that used to
# stand here picked the Microsoft Store stub on Windows (exit 49), and this
# gate hides its tool output (`>/dev/null 2>&1`), so a stub would have turned
# every decode leg into a silent miss. ct_need_python heals all three
# spellings or dies with 78. An explicit PY from the environment still wins.
ct_need_python
: "${PY:=python3}"

NEXRV="${NEXRV_DECOE:-$NEXRV}"
if [ -z "$NEXRV" ] || { [ ! -x "$NEXRV" ] && [ ! -f "$NEXRV" ]; }; then
	echo "### [ctxp] SKIP: no decoder binary (run: py scripts/fetch_cttd.py)."
	exit 77
fi
# The pinned CTTD must know -decoe; a build without it would turn every leg
# into a silent miss. Probe once, loudly.
if ! "$NEXRV" 2>&1 | grep -q -- "-decoe"; then
	echo "### [ctxp] FAIL: $NEXRV does not know -decoe (expected the pinned CTTD, scripts/cttd.pin)"
	exit 1
fi

# leg -> testbench basename
legs="basic:basic_tb exceptions:exceptions_tb interrupts:interrupts_tb \
	  stress:stress_tb ir:etrace_ir_tb f1ntrap:etrace_f1n_trap_tb resync:etrace_resync_tb"

cfrec () { grep -E ':(BRANCH_TAKEN|BRANCH_NOTTAKEN|CALL|RETURN):' "$1" 2>/dev/null \
	| sed -E 's/^#[0-9]+://; s/ @ [0-9]+$//; s/0x0*([0-9a-f])/0x\1/g' | tr -d '\r'; }
refn ()  { sed -E 's/0x0*([0-9a-f])/0x\1/g' "$1" 2>/dev/null | tr -d '\r'; }
pcn ()   { sed -e 's/^0x//' -e 's/^0*//' -e 's/^$/0/' "$1" 2>/dev/null | tr 'A-F' 'a-f' | tr -d '\r'; }

pass=0; fail=0; tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check_leg () { # $1=leg $2=tb $3=tag
	local leg="$1" tb="$2" tag="$3" d="bld/etrace_$leg" in
	in="bld/etrace_$leg/atb_$tag.bin"
	[ -f "$in" ] || return 0
	[ -f "$d/$tb.nexrv.info" ] || { echo "### [ctxp] SKIP $leg/$tag (no nexrv.info)"; return 0; }

	# References (regenerated fresh from the committed model; §14 audit-the-auditor)
	"$PY" tools/etrace/pcinfo2listing.py "$d/$tb.nexrv.info" "$d/$tb.objdump" >/dev/null 2>&1
	"$PY" tools/etrace/etrace_decode.py     -i "$in" -l "$d/$tb.objdump" -o "$d/$tb.$tag.pctrace"    >/dev/null 2>&1
	"$PY" tools/etrace/etrace_ctxp_ref.py   -i "$in" -l "$d/$tb.objdump" -o "$d/$tb.$tag.ctxp.cfref" >/dev/null 2>&1

	# Device under test: NexRv -decoe -> pcout + CTXP
	CTXP_TEXT_TRACEFILE="$d/$tb.$tag.ctxp.txt" \
		"$NEXRV" -decoe "$in" -pcinfo "$d/$tb.nexrv.info" -pcout "$d/$tb.$tag.ec.pcout" -none >/dev/null 2>&1

	local ok=1 detail=""
	# EC2
	if ! diff <(pcn "$d/$tb.$tag.pctrace") <(pcn "$d/$tb.$tag.ec.pcout") >"$tmp/d2" 2>&1; then ok=0; detail="EC2(PC)"; fi
	# EC3
	if ! diff <(refn "$d/$tb.$tag.ctxp.cfref") <(cfrec "$d/$tb.$tag.ctxp.txt") >"$tmp/d3" 2>&1; then ok=0; detail="$detail EC3(CF)"; fi
	# EC4
	local n_int_ctxp n_int_ref
	n_int_ctxp=$(grep -c ":INTERRUPT:" "$d/$tb.$tag.ctxp.txt" 2>/dev/null || true); n_int_ctxp=${n_int_ctxp:-0}
	n_int_ref=$("$PY" tools/etrace/dump_te.py "$in" 2>/dev/null | grep -c 'interrupt=1' || true); n_int_ref=${n_int_ref:-0}
	if [ "$n_int_ctxp" != "$n_int_ref" ]; then ok=0; detail="$detail EC4(INT $n_int_ctxp!=$n_int_ref)"; fi

	local npc; npc=$(wc -l < "$d/$tb.$tag.pctrace" 2>/dev/null | tr -d ' ')
	if [ "$ok" = 1 ]; then
		echo "### [ctxp] PASS $leg/$tag  ($npc PCs, $(cfrec "$d/$tb.$tag.ctxp.txt" | wc -l | tr -d ' ') CF, $n_int_ctxp INTERRUPT)"
		pass=$((pass+1))
	else
		echo "### [ctxp] FAIL $leg/$tag  [$detail]"; head -6 "$tmp/d2" "$tmp/d3" 2>/dev/null
		fail=$((fail+1))
	fi
}

for pair in $legs; do
	leg="${pair%%:*}"; tb="${pair##*:}"
	for tag in run on off; do check_leg "$leg" "$tb" "$tag"; done
done

echo "### [ctxp] === EC2/EC3/EC4 gate: PASS=$pass FAIL=$fail ==="
[ "$fail" -eq 0 ] || exit 5
[ "$pass" -ge 5 ] || { echo "### [ctxp] FATAL: too few legs exercised ($pass) — run cli_etrace_test.sh first"; exit 6; }
echo "### [ctxp] PASS — E-Trace -> CTXP decode green on $pass legs"
