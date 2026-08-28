#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Re-measurement of the synthesis matrix after the formatter / msg_gen gating
# fixes (the TCODE 2/29/31/32/58 arms plus tcode_is_sync and the config-message
# logic are now compile-gated; the full profile was verified byte-identical to
# the reference), together with a separation proof for the earlier change set:
#   T0  synthesize an older commit in a git worktree, in the featparity profile,
#       to obtain the cost of that earlier change set alone. The difference
#       featparity_base_v2 - T0 is then the cost of merely being able to switch
#       the newer features on, which the neutrality gate requires to be ~0.
#   Main tree: featparity_base_v2 / slimfull_base_v2 / voll_seq22cmp_v2 (the
#   neutrality gates after the fix), featparity_cfgonly (ONLY the config message
#   enabled in featparity), slimfull_gold_v2, voll_gold_v2 (variance control) and
#   the per-feature deltas in the full profile, now with effective gating.
# The _v2 suffix is historical: the predecessor scripts/phase_d_matrix.sh
# measured the same matrix BEFORE the gating fixes, was superseded by this
# script (which alone is quoted in doc/integration.adoc and sources the
# canonical profiles from ct_profiles.sh) and was removed as dead weight
# during the publication clean-up. Its numbers live on in verification/evidence/ and in
# the git history; the name is kept so those references still resolve.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
. "$repo/scripts/ct_env.sh"
# The profile definitions this script is quoted for (doc/integration.adoc:
# "canonically those of scripts/phase_d_matrix_v2.sh") live in ct_profiles.sh
# since P10-B, so a second measurement flow can USE them instead of
# re-deriving them from the sequence below. set_sw_in / set_ts_in /
# set_steps_in come from there; the composed profiles are ct_profile_in.
. "$repo/scripts/ct_profiles.sh"
PYRDL="$(ct_pyrdl)" || ct_die "no PeakRDL venv -- run scripts/gen_rdl.sh once, or set CT_PYRDL"
LOG="bld/phase_d_matrix_v2.log"
: > "$LOG"
say () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

if tasklist //FI "IMAGENAME eq vivado.exe" 2>/dev/null | grep -q vivado.exe; then
	echo "FATAL: vivado.exe is already running."; exit 9
fi

NEW_FEATS="$CT_GOLD_FEATS"

# Vivado as pinned in .abc.config (ct_env.sh discovery) -- this script used to
# name C:\Xilinx\Vivado\2025.1 literally, which is neither the pinned version
# nor the one P4/P7/P8 were measured with, and slack is version-dependent.
ct_need_vivado
VIVADO_BIN="$(command -v vivado || echo vivado)"

report () { # $1 dir prefix, $2 name
	local d="$1" n="$2" l f b w fx
	l=$(grep -m1 "CLB LUTs" "$d/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	f=$(grep -m1 "CLB Registers" "$d/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	b=$(grep -m1 "Block RAM Tile" "$d/util_flat.rpt" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
	w=$(awk '/Design Timing Summary/{f=1} f && $1 ~ /^-?[0-9]+\.[0-9]+$/ {print $1; exit}' "$d/timing_summary.rpt")
	fx=$(awk -v w="$w" 'BEGIN{ if (w != "") printf "%.1f", 1000.0/(5.0-w) }')
	say "synth $n: LUTs=$l FFs=$f BRAM=$b | WNS=${w:-?} ns @5ns -> Fmax~${fx:-?} MHz"
}

synth_in () { # $1 = tree root (abs), $2 = name
	local root="$1" n="$2"
	( cd "$root" && rm -rf bld/synth_ooc_t .Xil 2>/dev/null
	  "$VIVADO_BIN" -mode batch -nojournal -nolog -source scripts/synth_encoder_ooc_timing.tcl -tclargs xck26-sfvc784-2LV-c 5.0 > "bld/synth_d2_${n}.log" 2>&1
	  if ! [ -f bld/synth_ooc_t/util_flat.rpt ]; then
		sleep 15
		"$VIVADO_BIN" -mode batch -nojournal -nolog -source scripts/synth_encoder_ooc_timing.tcl -tclargs xck26-sfvc784-2LV-c 5.0 > "bld/synth_d2_${n}.log" 2>&1
	  fi )
	if [ -f "$root/bld/synth_ooc_t/util_flat.rpt" ]; then
		mkdir -p "bld/synth_d2_${n}"
		cp "$root"/bld/synth_ooc_t/{util_flat.rpt,util_hier.rpt,timing_summary.rpt} "bld/synth_d2_${n}/" 2>/dev/null
		report "bld/synth_d2_${n}" "$n"
	else
		say "synth $n: FAIL"; tail -4 "$root/bld/synth_d2_${n}.log" | tee -a "$LOG"
	fi
}

# The featparity base profile itself now lives in scripts/ct_profiles.sh; this
# wrapper only maps "tree root" to "package path". (CT_ETIP_SERIALIZE exists
# in both the current and the T0 state; the nine gold switches do not exist
# in T0, where setting them is a no-op.)
featparity_profile_in () { # $1 tree root
	ct_profile_featparity_base_in "$1/rtl/pkg/ct_pkg.sv"
}

# ---- T0: earlier-change-set anchor, synthesized in a git worktree ----
say "=== T0: worktree 2ec3993 (after A, before B1) in the featparity profile ==="
# In the PREDECESSOR repository the encoder sat at <super>/third_party/C-Trace,
# so this used to add the worktree two levels up and then descend back into
# third_party/. Here the encoder IS the repository: the worktree root is the
# encoder tree, and there is no third_party/ hop. The old paths resolved to
# nothing in this layout, which the `else` arm below reported as a skip --
# i.e. T0 could never have run here, and said so only as "worktree missing".
WT="$repo/../_wt_a_phase"
( cd "$repo" && git worktree add "$WT" 2ec3993 >> /dev/null 2>&1 ) || say "worktree add: possibly already present"
WTC="$WT"
if [ -d "$WTC/rtl/pkg" ]; then
	featparity_profile_in "$WTC"
	( cd "$WTC" && "$PYRDL" scripts/gen_rdl_profile.py >> "$LOG" 2>&1 )
	synth_in "$WTC" a_phase_featparity
else
	say "T0: worktree missing -- skipped"
fi

# ---- main-tree remeasurements ----
PKG="rtl/pkg/ct_pkg.sv"
set_sw () { set_sw_in "$PKG" "$1" "$2"; }
new_feats () { local f; for f in $NEW_FEATS; do set_sw "$f" "$1"; done; }
regen () { "$PYRDL" scripts/gen_rdl_profile.py >> "$LOG" 2>&1; }
base_switches () { # daq dt act filt suite sclk ts steps serialize
	set_sw CT_EN_DAQ "$1"; set_sw CT_EN_DATA_TRACE "$2"; set_sw CT_EN_ACT "$3"; set_sw CT_EN_FILTERS "$4"; set_sw CT_EN_WATCHPOINT_MSG "$3"; set_sw CT_EN_AXIS_TS "$3"; set_sw CT_EN_DF_DROP "$2"; set_sw CT_EN_DF_ADDR_COMPRESS "$2"
	for f in CT_EN_IMPLICIT_RETURN CT_EN_REPEATED_HISTORY CT_EN_WIDE_ICNT CT_EN_REPEAT_BRANCH CT_EN_JTC CT_EN_BP; do set_sw $f "$5"; done
	set_sw CT_SINGLE_CLOCK "$6"; set_ts_in "$PKG" "$7"; set_steps_in "$PKG" "$8"
	set_sw CT_ETIP_SERIALIZE "$9"
	set_sw CT_COMPACT_PACKER 0; set_sw CT_ETIP_CDC_SLIM 0; set_sw CT_EN_ETIP_WATERMARK 1
	set_sw CT_EN_TIMESTAMP 1; set_sw CT_MICRO_CSR 0
}

say "=== featparity_base_v2 (gates active; expected ~= the T0 anchor) ==="
base_switches 0 0 0 0 0 1 32 1 0; new_feats 0; set_sw CT_COMPACT_PACKER 1; regen
synth_t_name=featparity_base_v2; synth_in "$repo" featparity_base_v2

say "=== featparity_cfgonly (E6: featparity + ONLY config message) ==="
set_sw CT_EN_CONFIG_MSG 1; regen
synth_in "$repo" featparity_cfgonly
set_sw CT_EN_CONFIG_MSG 0

say "=== slimfull_base_v2 ==="
set_sw CT_ETIP_CDC_SLIM 1; set_sw CT_EN_ETIP_WATERMARK 0; set_sw CT_EN_TIMESTAMP 0; set_sw CT_EN_AXIS_TS 0; regen
synth_in "$repo" slimfull_base_v2

say "=== slimfull_gold_v2 (retry of the flaky FAIL) ==="
new_feats 1; regen
synth_in "$repo" slimfull_gold_v2

say "=== voll_seq22cmp_v2 (new features off + Serialize 0) ==="
base_switches 1 1 1 1 1 0 64 2 0; new_feats 0; regen
synth_in "$repo" voll_seq22cmp_v2

say "=== voll_gold_v2 (variance control) ==="
base_switches 1 1 1 1 1 0 64 2 1; new_feats 1; regen
synth_in "$repo" voll_gold_v2

say "=== voll individual deltas v2 (gates effective) ==="
for feat in CONFIG_MSG OWNERSHIP IBHS REPEAT_INSTR; do
	say "--- voll_no${feat,,}_v2 ---"
	set_sw "CT_EN_${feat}" 0; regen
	synth_in "$repo" "voll_no${feat,,}_v2"
	set_sw "CT_EN_${feat}" 1
done
say "--- voll_noevents_v2 ---"
for f in CT_EN_DEBUG_EVENTS CT_EN_POWER_EVENTS CT_EN_EVTI CT_EN_TRIG_SYNC CT_EN_SEQ_SYNC; do set_sw $f 0; done
regen
synth_in "$repo" voll_noevents_v2

say "=== restore gold defaults ==="
base_switches 1 1 1 1 1 0 64 2 1; new_feats 1; regen
say "=== clean up worktree ==="
( cd "$repo/../.." && git worktree remove --force "$WT" >> /dev/null 2>&1 ) || say "worktree remove: check manually"
say "=== DONE ==="
