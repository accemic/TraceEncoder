#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Compression-suite robustness matrix (local bring-up aid).
# One workload (tests/instruction/11_robustness), four CSR configurations,
# five decodes:
#   off  : all compression off             -> reference baseline
#   hist : IR+RH+RB+WideICNT+JTC           -> HIST-family stack
#   bpf  : IR+BP+WideICNT+JTC              -> BP-family stack   (decode -bp)
#   all  : all six bits (misprogramming)   -> must be BYTE-IDENTICAL to bpf
#   neg  : bpf stream decoded WITHOUT -bp  -> must SUCCEED with PCs == bpf
#          (TCODE-58 ENAB autoconfig; guard updated 2026-08-04, see below)
# Every decode's PC prefix must equal the cpu_model reference.
# Self-contained: clones the 07 test's xsim .prj (abc's @-resolver is broken
# since the tree was vendored). NOT for upstream.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
. "$here/scripts/ct_env.sh"
ct_need_vivado
ct_need_nexrv

tb=robustness_tb
src_tb=repeated_history_tb   # donor project (same env, same libs)

xd="$here/bld/${tb}.abc.vivado/${tb}.abc.sim/sim_1/behav/xsim"
sd="$here/bld/${src_tb}.abc.vivado/${src_tb}.abc.sim/sim_1/behav/xsim"
if ct_prj_stale "$xd/${tb}_vlog.prj"; then
	ct_need_prj "$src_tb" || exit $?
	mkdir -p "$xd"
	sed "s|tests/instruction/07_repeated_history/${src_tb}.sv|tests/instruction/11_robustness/${tb}.sv|" \
		"$sd/${src_tb}_vlog.prj" > "$xd/${tb}_vlog.prj"
	cp "$sd/glbl.v" "$xd/"
fi

cd "$xd"
rm -rf xsim.dir          # clean compile so RTL/TB edits always take effect
xvlog --relax -L uvm -prj "${tb}_vlog.prj" -log xvlog.log >/dev/null 2>&1 || { echo "FAIL xvlog"; grep -i error xvlog.log|head; exit 4; }
xelab --relax --debug off -L uvm "xil_defaultlib.${tb}" xil_defaultlib.glbl -s "${tb}_snap" -log xelab.log >/dev/null 2>&1 || { echo "FAIL xelab"; grep -i error xelab.log|head; exit 5; }
printf 'run -all\nquit\n' > _runall.tcl

run_one () { # $1 = tag, $2 = NexRv extra flags, $3... = extra xsim args
	local tag="$1"; shift
	local decoflags="$1"; shift
	ct_xsim "xsim_${tag}.log" "${tb}_snap" "$@" -tclbatch _runall.tcl || exit 6
	cp "${tb}.atb.bin" "atb_${tag}.bin"
	# shellcheck disable=SC2086
	"$NEXRV" -deco "atb_${tag}.bin" -pcinfo "${tb}.nexrv.info" -pcout "${tb}.${tag}.pcout" -full $decoflags > "nexrv_${tag}.log" 2>&1
	grep -E '[0-9]+ PC: 0x' "nexrv_${tag}.log" | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > "${tag}.pcs"
}

echo "### run OFF ";  run_one off  ""
echo "### run HIST";  run_one hist ""    -testplusarg ROBUST_HIST
echo "### run BPF ";  run_one bpf  "-bp" -testplusarg ROBUST_BP
echo "### run ALL ";  run_one all  "-bp" -testplusarg ROBUST_ALL

# Flagless decode of the BPF stream. GUARD UPDATED (2026-08-04): the original
# premise "must abort hard on TCODE 56 without -bp" pre-dates two ratified
# features and is obsolete on the consolidated decoder line:
#   (a) CFG_ONCE (R2-final defaults): every stream starts with the vendor
#       config message (TCODE 58) carrying ENAB, and
#   (b) NexRv autoconfig (C4 goal "flagless == -bp"): the decoder reads ENAB
#       and self-configures the BP/JTC front-ends.
# Verified 2026-08-04: BOTH the e06d9e1 pin (781b6e5a, E-P3-1 consolidation)
# and the a2588ec pin (20537ae3) decode atb_bpf.bin flaglessly with rc=0 and
# a PC stream IDENTICAL to the -bp decode -- so the stale abort-guard had been
# red since the E-P3-1 pin, not since the P2 re-pin. New contract checked
# below: flagless decode must SUCCEED and its PCs must equal the -bp decode
# (autoconfig regression guard -- a decoder that silently loses the ENAB
# self-configuration would diverge or abort here).
"$NEXRV" -deco atb_bpf.bin -pcinfo "${tb}.nexrv.info" -pcout "${tb}.neg.pcout" -full > nexrv_neg.log 2>&1
neg_rc=$?
grep -E '[0-9]+ PC: 0x' nexrv_neg.log | sed -E 's/.*PC: (0x[0-9a-fA-F]+).*/\1/' > neg.pcs

exp="${tb}.expected.pcs"
norm () { sed -E 's/^0x0*/0x/; s/^0x$/0x0/' "$1" | tr -d '\r' | tr 'A-F' 'a-f'; }
norm "$exp"    > exp.norm
for t in off hist bpf all; do norm "$t.pcs" > "$t.norm"; done
n_exp=$(grep -c . exp.norm)
pfx=$n_exp
for t in off hist bpf all; do n=$(grep -c . "$t.norm"); [ "$n" -lt "$pfx" ] && pfx=$n; done
head -n "$pfx" exp.norm > exp.pfx
for t in off hist bpf all; do head -n "$pfx" "$t.norm" > "$t.pfx"; done

sz_off=$(stat -c%s atb_off.bin); sz_hist=$(stat -c%s atb_hist.bin)
sz_bpf=$(stat -c%s atb_bpf.bin); sz_all=$(stat -c%s atb_all.bin)
md5_bpf=$(md5sum atb_bpf.bin | cut -d' ' -f1)
md5_all=$(md5sum atb_all.bin | cut -d' ' -f1)

echo "======================================================"
echo "expected PCs   : $n_exp"
for t in off hist bpf all; do
	printf "%-4s decoded    : %s PCs, atb %s B\n" "$t" "$(grep -c . $t.norm)" "$(stat -c%s atb_$t.bin)"
done
echo "verified prefix: $pfx PCs (tail beyond this lost to host ATB truncation)"
echo "VendorBP (bpf) : $(grep -c ' - VendorBP' nexrv_bpf.log) msgs   VendorJTC (bpf): $(grep -c ' - VendorJTC' nexrv_bpf.log) msgs"
echo "RptBr (hist)   : $(grep -c ' - RepeatBranch' nexrv_hist.log) msgs   VendorJTC (hist): $(grep -c ' - VendorJTC' nexrv_hist.log) msgs   RCODE2: $(grep -c 'RCODE\[4\]=0x2' nexrv_hist.log)"
echo "------------------------------------------------------"
verdict=0
for t in off hist bpf all; do
	if cmp -s exp.pfx "$t.pfx"; then echo "$t prefix == reference : PASS"; else echo "$t prefix == reference : FAIL"; verdict=1; diff exp.pfx "$t.pfx" | head; fi
done
# With SendConfig resetting to CFG_ONCE, every trace session describes its own
# configuration on the wire: the ALL and BPF legs differ EXACTLY in the ENAB
# bytes of their TCODE-58 config messages, while the payload stream stays
# identical (RH/RB are blocked under BP in hardware). The gate is therefore two
# stage: (a) the message sequence of the decodable stream is identical
# (deco-full without IDLE lines, ENAB neutralized), and (b) the raw byte
# difference is tiny -- only the ENAB MDO bytes, two sessions of at most two
# bytes each.
# Compare DECODED field lines only ('='): raw per-byte echo lines carry the
# differing ENAB MDO bytes and idle separators shift with assembly latency.
grep -E '=' nexrv_bpf.log | sed -E 's/ENAB\[[0-9]+\]=0x[0-9a-f]+ \([0-9]+\)/ENAB=X/' > all_vs_bpf.a
grep -E '=' nexrv_all.log | sed -E 's/ENAB\[[0-9]+\]=0x[0-9a-f]+ \([0-9]+\)/ENAB=X/' > all_vs_bpf.b
n_bytediff=$(cmp -l atb_bpf.bin atb_all.bin | wc -l)
if cmp -s all_vs_bpf.a all_vs_bpf.b && [ "$n_bytediff" -le 4 ]; then
	echo "ALL == BPF (mod ENAB)   : PASS (msgs identical, $n_bytediff ENAB byte(s) differ)"
else
	echo "ALL == BPF (mod ENAB)   : FAIL (bytediff=$n_bytediff, msg diff: $(diff all_vs_bpf.a all_vs_bpf.b | head -4 | tr '\n' ' '))"; verdict=1
fi
# Autoconfig contract (guard updated 2026-08-04, rationale at the decode above).
if [ $neg_rc -eq 0 ] && cmp -s neg.pcs bpf.pcs; then
	echo "BPF decode flagless     : PASS (rc=0, PCs == -bp decode; ENAB autoconfig)"
else
	echo "BPF decode flagless     : FAIL (rc=$neg_rc, PC diff: $(diff neg.pcs bpf.pcs 2>/dev/null | head -2 | tr '\n' ' '))"; verdict=1
fi
# Compression is INFORMATIONAL here (not a pass criterion): this workload is
# deliberately adversarial (alias interference, random patterns, collision
# thrash), where e.g. BP legitimately costs more than HIST bits. The dedicated
# tests 06-10 own the compression claims; this test owns losslessness.
echo "atb sizes (info)        : off $sz_off B | hist $sz_hist B | bpf $sz_bpf B | all $sz_all B"
echo "======================================================"
[ $verdict -eq 0 ] && [ "$pfx" -gt 50 ] && echo "OVERALL: PASS" || { echo "OVERALL: FAIL (prefix=$pfx)"; verdict=1; }
exit $verdict
