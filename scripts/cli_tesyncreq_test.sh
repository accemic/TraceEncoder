#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# P8 / G11 explicit-sync-request-over-TE verification
# (trTeControl.InstSyncReq, bit 27).
# Runs tests/instruction/33_te_sync_req ten times:
#   off    : no request              -> no SYNC = 14 at all (negative leg)
#   req    : one write mid-stream    -> exactly ONE SYNC = 14
#   reqnop : the same stimulus WITHOUT the write -- the activity control:
#            req minus reqnop is exactly the one anchor the feature adds
#   req2   : TWO writes back to back -> TWO SYNC = 14 (the queue is one deep,
#            so a write during an outstanding request is NOT swallowed)
#   req3   : THREE writes back to back -> still TWO (the third has nothing new
#            to ask for and collapses into the queued one)
#   cfonly : ACT-CAP CF_SYNC alone   -> the CONTROL for the collision leg
#   cfsync : write + ACT-CAP CF_SYNC on the same retire -> still ONE message
#            (a synchronization message satisfies every pending request)
#   quota  : write while the trace-BYTE quota runs -> quota syncs (SYNC = 2)
#            AND the request's own SYNC = 14, neither disturbs the other
#   qcoll  : the same, but with the write in the MIDDLE of the quota stream
#            instead of after it -- both sources in one window
#   ovf    : write inside an eTIP overflow storm -> the stream still decodes
#            and the encoder recovers (no losslessness claim in that leg)
# req2/req3 are the measurement behind the queue-depth contract in the
# register documentation; the same-BEAT collision is a formal target
# (formal/preproc_sync, task reqcoll / P-SYNC-11), because a testbench cannot
# schedule two independent sources onto one retire.
# The SyncReqSource read-backs and the write-1/read-0 field contract are
# self-checking in sim ($fatal), in EVERY leg -- an xsim exit with a fatal
# shows up as a missing PASS line here.
# Each leg is compared against ITS OWN cpu_model reference; an explicit sync
# adds a message but never changes which instructions are traced, so the
# four non-overflow legs must all be PC-lossless.
# Self-contained: clones the 07 test's xsim .prj. NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=te_sync_req_tb
src_tb=repeated_history_tb

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/33_te_sync_req/${tb}.sv|" \
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
	# ct_xsim, not a bare call: xsim reports a failed start only in its log
	# and still exits 0, and the copy below would then promote the PREVIOUS
	# leg's dump (P7 finding R4).
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl \
		|| { echo "FAIL: xsim leg $tag unusable (reason above)"; exit 6; }
	cp "${tb}.atb.bin"      "atb_${tag}.bin"
	cp "${tb}.expected.pcs" "exp_${tag}.pcs"
	"$NEXRV" -deco "atb_${tag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${tag}.pcout" -full > "nexrv_${tag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
}

norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
cnt () { grep -cE "$1" "$2" || true; }
verdict=0
chk () { # $1 = label, $2 = actual, $3 = expected
	if [ "$2" = "$3" ]; then printf '%-46s: PASS (%s)\n' "$1" "$2"
	else printf '%-46s: FAIL (got %s, want %s)\n' "$1" "$2" "$3"; verdict=1; fi
}
chk_ge () { # $1 = label, $2 = actual, $3 = minimum
	if [ "$2" -ge "$3" ]; then printf '%-46s: PASS (%s)\n' "$1" "$2"
	else printf '%-46s: FAIL (got %s, want >= %s)\n' "$1" "$2" "$3"; verdict=1; fi
}
lossless () { # $1 = tag
	local t="$1" n e m
	norm "$t.pcs" > "$t.norm"; norm "exp_$t.pcs" > "exp_$t.norm"
	n=$(grep -c . "$t.norm"); e=$(grep -c . "exp_$t.norm")
	m=$(( n < e ? n : e ))
	if [ "$m" -gt 20 ] && head -n "$m" "exp_$t.norm" | cmp -s - <(head -n "$m" "$t.norm"); then
		printf '%-46s: PASS (%s PCs)\n' "$t lossless vs own reference" "$m"
	else
		printf '%-46s: FAIL (n=%s exp=%s)\n' "$t lossless vs own reference" "$n" "$e"; verdict=1
	fi
}

# ---------------------------------------------------------------------------
# ro mode: the COMPILED-OUT negative (CT_EN_INST_SYNC_REQ = 0). Run this in a
# worktree whose ct_pkg has the switch at 0. Same stimulus as the req leg of
# the full run, which produces exactly ONE SYNC = 14 when the feature is
# compiled in; here it must produce NONE -- and the field must still accept
# the write and still read back 0 (the pre-P8 contract is unchanged), which
# the in-sim checks assert.
# ---------------------------------------------------------------------------
if [ "${1:-full}" = "ro" ]; then
	echo "### run REQ (compiled out)"
	run_one req -testplusarg REQLEG -testplusarg TESYNC_RO
	echo "======================================================"
	lossless req
	# Two reads in this leg -- after reset and after the request -- and BOTH
	# must return 0 in the compiled-out build: the write is accepted, clears
	# itself (checked in sim) and reaches nothing.
	chk "both reads return 0 (request inert)"     "$(cnt 'SyncReqSource=0 \(as expected\)' xsim_req.log)" 2
	chk "NO SYNC = 14 with the feature out"       "$(cnt 'SYNC\[4\]=0xe\b' nexrv_req.log)" 0
	chk "sim leg completed"                       "$(cnt 'PASS \(sim\)' xsim_req.log)" 1
	echo "======================================================"
	[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
	exit $verdict
fi

echo "### run OFF   "; run_one off
echo "### run REQ   "; run_one req    -testplusarg REQLEG
echo "### run REQNOP"; run_one reqnop -testplusarg REQNOPLEG
echo "### run REQ2  "; run_one req2   -testplusarg REQ2LEG
echo "### run REQ3  "; run_one req3   -testplusarg REQ3LEG
echo "### run CFONLY"; run_one cfonly -testplusarg CFONLYLEG
echo "### run CFSYNC"; run_one cfsync -testplusarg CFSYNCLEG
echo "### run QUOTA "; run_one quota  -testplusarg QUOTALEG
echo "### run QCOLL "; run_one qcoll  -testplusarg QCOLLLEG
echo "### run OVF   "; run_one ovf    -testplusarg OVFLEG

echo "======================================================"
# --- the non-overflow legs decode PC-lossless ------------------------------
for t in off req reqnop req2 req3 cfonly cfsync quota qcoll; do lossless "$t"; done
echo "------------------------------------------------------"
# --- every leg ran its in-sim CSR checks to the end ------------------------
for t in off req reqnop req2 req3 cfonly cfsync quota qcoll ovf; do
	chk "sim leg completed ($t)" "$(cnt 'PASS \(sim\)' "xsim_$t.log")" 1
done
echo "------------------------------------------------------"
# --- SYNC = 14 accounting: one request, one message ------------------------
chk "OFF: no explicit sync at all"            "$(cnt 'SYNC\[4\]=0xe\b' nexrv_off.log)" 0
chk "REQ: exactly one SYNC = 14"              "$(cnt 'SYNC\[4\]=0xe\b' nexrv_req.log)" 1
# Queue depth, measured (P8 audit A-1): one request in flight plus ONE
# remembered. Two writes therefore produce two messages -- the second is NOT
# absorbed -- and the third write of a burst collapses into the queued one.
chk "REQ2: two writes -> two SYNC = 14"       "$(cnt 'SYNC\[4\]=0xe\b' nexrv_req2.log)" 2
chk "REQ3: three writes -> still two"         "$(cnt 'SYNC\[4\]=0xe\b' nexrv_req3.log)" 2
# The control leg is what makes the collision leg meaningful: without it,
# "one message for two requests" would look the same as a CF_SYNC path that
# does nothing at all.
chk "CFONLY: the CF_SYNC path alone works"    "$(cnt 'SYNC\[4\]=0xe\b' nexrv_cfonly.log)" 1
chk "CFSYNC: collision yields ONE message"    "$(cnt 'SYNC\[4\]=0xe\b' nexrv_cfsync.log)" 1
chk "QUOTA: the request still gets its sync"  "$(cnt 'SYNC\[4\]=0xe\b' nexrv_quota.log)" 1
chk "QCOLL: request inside the quota stream"  "$(cnt 'SYNC\[4\]=0xe\b' nexrv_qcoll.log)" 1
echo "------------------------------------------------------"
# --- the diagnosis register, read back in sim ------------------------------
# 'after reset' (0) runs in every leg; the leg-specific reads follow.
chk "OFF: source stays 0 (reset + end)"       "$(cnt 'SyncReqSource=0 \(as expected\)' xsim_off.log)" 2
chk "REQ: source reads 4 (SYNC_REQ_TE)"       "$(cnt 'SyncReqSource=4 \(as expected\)' xsim_req.log)" 1
chk "REQ2: source reads 4 after the burst"    "$(cnt 'SyncReqSource=4 \(as expected\)' xsim_req2.log)" 1
chk "REQ3: source reads 4 after the burst"    "$(cnt 'SyncReqSource=4 \(as expected\)' xsim_req3.log)" 1
chk "CFONLY: source reads 1 (control leg)"    "$(cnt 'SyncReqSource=1 \(as expected\)' xsim_cfonly.log)" 1
chk "CFSYNC: source reads 1 (the later event)" "$(cnt 'SyncReqSource=1 \(as expected\)' xsim_cfsync.log)" 1
chk "QUOTA: source reads 4 after the request" "$(cnt 'SyncReqSource=4 \(as expected\)' xsim_quota.log)" 1
chk "OVF: request recorded despite the storm" "$(cnt 'SyncReqSource=4 \(as expected\)' xsim_ovf.log)" 1
echo "------------------------------------------------------"
# --- the quota leg must still show its quota syncs -------------------------
# SYNC = 2 (PERIODIC) is what a trace-byte quota window produces (P2/D4).
chk_ge "QUOTA: quota syncs keep coming (SYNC = 2)" "$(cnt 'SYNC\[4\]=0x2\b' nexrv_quota.log)" 2
chk_ge "QCOLL: quota keeps running around it"      "$(cnt 'SYNC\[4\]=0x2\b' nexrv_qcoll.log)" 2
chk    "OFF: no quota syncs in the sparse mode"    "$(cnt 'SYNC\[4\]=0x2\b' nexrv_off.log)" 0
echo "------------------------------------------------------"
# --- the overflow leg: loss is announced, the encoder recovers, decode ok --
chk_ge "OVF: overflow really happened (Error msg)" "$(cnt 'TCODE\[6\]=8 ' nexrv_ovf.log)" 1
if grep -q "Decoded OK" nexrv_ovf.log; then
	printf '%-46s: PASS\n' "OVF: stream still decodes"
else
	printf '%-46s: FAIL\n' "OVF: stream still decodes"; verdict=1
	tail -3 nexrv_ovf.log
fi
echo "------------------------------------------------------"
# --- the request is ADDITIVE: it adds a message, it changes nothing else ---
# off and req trace the identical instruction stream, so their TCODE
# sequences may differ only by the one extra synchronizing message.
tcodes () { grep -oE 'TCODE\[6\]=[0-9]+' "$1"; }
d_off=$(tcodes nexrv_off.log | wc -l)
d_req=$(tcodes nexrv_req.log | wc -l)
d_req2=$(tcodes nexrv_req2.log | wc -l)
chk "REQ adds exactly one message vs OFF"     "$(( d_req - d_off ))" 1
chk "REQ2 adds exactly two messages vs OFF"   "$(( d_req2 - d_off ))" 2
echo "------------------------------------------------------"
# --- ACTIVITY: switched ON *and requested*, the stream really does change ---
# The byte-neutrality gate (scripts/p8_off_neutrality.sh) compares 31 streams
# of the reference family with the feature compiled in -- but not one of those
# testbenches ever writes bit 27, so that run proves the feature is DORMANT,
# not that it works (P8 audit B-7). The activity half is here: same build,
# same stimulus, once without and once with the request.
# The comparison is req vs REQNOP -- the same stimulus with and without the
# write. (off is a different stimulus: it skips the request's settling run and
# decodes a different number of PCs, so it would compare apples to pears.)
d_reqnop=$(tcodes nexrv_reqnop.log | wc -l)
if cmp -s atb_reqnop.bin atb_req.bin; then
	printf '%-46s: FAIL (identical to the control)\n' "ACT: the request changes the stream"; verdict=1
else
	# cmp reports "differ: byte N" or "differ: char N" depending on the build.
	first=$(cmp atb_reqnop.bin atb_req.bin 2>/dev/null | sed -E 's/.*(byte|char) ([0-9]+).*/\2/')
	if [ -n "$first" ] && [ "$first" -gt 1 ]; then
		printf '%-46s: PASS (first differing byte %s)\n' "ACT: identical up to the request" "$first"
	else
		printf '%-46s: FAIL (differ from byte %s)\n' "ACT: identical up to the request" "${first:-?}"; verdict=1
	fi
fi
# ... and it changes it by adding an ANCHOR, not by tracing anything else:
# the decoded instruction sequences of the two legs stay identical.
chk "ACT: same PC sequence as the control"    "$(cmp -s req.norm reqnop.norm && echo same || echo differ)" same
chk "ACT: exactly one message more"           "$(( d_req - d_reqnop ))" 1
chk "ACT: and that message is the SYNC = 14"  "$(( $(cnt 'SYNC\[4\]=0xe\b' nexrv_req.log) - $(cnt 'SYNC\[4\]=0xe\b' nexrv_reqnop.log) ))" 1
chk "ACT: the control asked for nothing"      "$(cnt 'SyncReqSource=0 \(as expected\)' xsim_reqnop.log)" 2
echo "======================================================"
[ $verdict -eq 0 ] && echo "OVERALL: PASS" || echo "OVERALL: FAIL"
exit $verdict
