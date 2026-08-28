#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Mint the baseline reference artefacts: the whole suite under the new
# defaults (strict CDF handling, the CSR clean-ups, and CT_ETIP_SERIALIZE=1 as
# the full-profile default), producing a manifest, the test 06 md5s, a
# timestamp-less leg (+NO_TSTAMP) and a diff against the previous manifest.
# Expected:
#   - only the robustness streams differ from the previous manifest (the
#     empty-HIST arm),
#   - 06 OFF/ON == historisch (61c0a2ea/a9c69b38) => REF2_FULL_* == REF_FULL_*,
#   - NO_TSTAMP-md5 == md5_R1 (18f8b7ef...) => md5_R2_notstamp == md5_R1.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
ct_need_vivado
LOG="bld/r2_mint.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

suite_manifest () { # $1 outfile
	local out="$1"; : > "$out"; local d f
	for d in implicit_return_tb repeated_history_tb repeat_branch_tb jtc_tb branch_predict_tb robustness_tb; do
		local x="bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"
		[ -d "$x" ] || continue
		for f in "$x"/atb_*.bin; do
			[ -f "$f" ] || continue
			echo "$(md5sum "$f" | cut -d' ' -f1)  ${d}/$(basename "$f")" >> "$out"
		done
	done
	sort -k2 -o "$out" "$out"
}

for d in implicit_return_tb repeated_history_tb repeat_branch_tb jtc_tb branch_predict_tb robustness_tb; do
	rm -f "bld/${d}.abc.vivado/${d}.abc.sim/sim_1/behav/xsim"/atb_*.bin 2>/dev/null
done

say "=== R2 baseline: suite 06-11 under the new defaults ==="
bash scripts/cli_ir_test.sh >> "$LOG" 2>&1 && say "06 ir: PASS" || say "06 ir: FAIL"
for t in rh rb jtc bp robust; do
	bash scripts/cli_${t}_test.sh >> "$LOG" 2>&1 && say "cli_${t}: PASS" || say "cli_${t}: FAIL"
done
suite_manifest "bld/r2_manifest_basis.txt"
say "Manifest R2 baseline: $(grep -c . bld/r2_manifest_basis.txt) artefacts"

xd06="bld/implicit_return_tb.abc.vivado/implicit_return_tb.abc.sim/sim_1/behav/xsim"
m_off=$(md5sum "$xd06/atb_off.bin" | cut -d' ' -f1)
m_on=$(md5sum "$xd06/atb_on.bin" | cut -d' ' -f1)
say "REF2_FULL_OFF=$m_off  (was 61c0a2eac0d6a94fa51c785b936295af)"
say "REF2_FULL_ON =$m_on  (was a9c69b3809196b5bd8717d3c8d4b755a)"

say "=== timestamp-less leg (+NO_TSTAMP) for md5_R2_notstamp ==="
( cd "$xd06" \
  && ct_xsim xsim_nots.log implicit_return_tb_snap -testplusarg NO_TSTAMP -tclbatch _runall.tcl \
  && cp implicit_return_tb.atb.bin atb_nots.bin ) \
  && say "md5_R2_notstamp=$(md5sum "$xd06/atb_nots.bin" | cut -d' ' -f1)  (md5_R1=18f8b7ef35e74da029c34f5f5d855053)" \
  || say "NO_TSTAMP leg: FAIL"

say "=== diff: baseline manifest vs the previous full-profile manifest ==="
diff bld/phase_t_manifest_full0.txt bld/r2_manifest_basis.txt | tee -a "$LOG" || true
say "fertig."
