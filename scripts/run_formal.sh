#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# CI Stage 2b -- formal gates (SymbiYosys) for the emission core:
#   ovf_injector  : P-INJ-1..4  unbounded (k-induction) + cover
#   preproc_sync  : P-SYNC-1..3+5a unbounded + P-SYNC-4 bounded +
#                   P-SYNC-5b/6/7 quota closed loop (BMC 160) + P-SYNC-9/10
#                   TE request through the real pacer and both strobe_cdc +
#                   P-SYNC-11 request-meets-quota collision + covers
#   msg_gen       : P-MSG-1..4 + I6/I7 as BMC(50) + cover
#   nexus_formatter: P-FMT-1..5 (P3 DF address compression) BMC(40) +
#                   cover + prove
#   nexus_formatter_xlen64: the same BMC in a 64-bit address net (see the
#                   width leg below)
# Optional RED=1 replays the red counter-proofs on the pre-fix revisions via a
# git worktree, so each property is falsified as well as proven.
#   TARGETS="ovf_injector preproc_sync"  -> run a subset (default: everything)
# Toolchain: OSS CAD Suite + sv2v, set up by formal/common/env.sh
# (OSS_CAD_SUITE / SV2V_HOME can be overridden).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
. "$here/scripts/ct_env.sh"
cd "$here/formal"

# --- yosys stack-reserve guard ---------------------------------------------
# A stock oss-cad-suite yosys.exe ships with the default 1 MiB stack reserve;
# deep SystemVerilog elaborations then die by silent stack overflow and sby
# reports only "engine did not return a status". Our suite copy is patched to
# a >= 128 MiB reserve (PE32+ optional header, SizeOfStackReserve, 8 bytes LE
# at e_lfanew+0x18+0x48). A suite update replaces the binary and silently
# reverts the patch -- fail LOUDLY here instead of hours later in a task.
#
# Where the suite lives is decided by formal/common/env.sh, which is what the
# targets themselves source. The literal `D:/tools/oss-cad-suite` that used to
# stand here was a SECOND answer to that question and only matched one
# workstation; everywhere else `[ -f "$yosys_exe" ]` was simply false and the
# guard evaporated WITHOUT A WORD. Measured 2026-08-13 with
# OSS_CAD_SUITE=/nonexistent: not one STACK-GUARD line, the run walked
# straight into the targets. That divergence has bitten before, in the other
# direction -- see the paragraph in formal/common/env.sh about a guard that
# reported OK on a binary the environment then refused to set up. One
# resolver, asked in a subshell so its PATH edits stay there.
suite="${OSS_CAD_SUITE:-}"
if [ -z "$suite" ]; then
	suite="$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${OSS_CAD_SUITE:-}"' _ "$here/formal/common/env.sh" || true)"
fi
yosys_exe="$suite/bin/yosys.exe"

if [ -z "$suite" ]; then
	# Not "skip": the formal targets cannot run either, so this is the
	# toolchain verdict (78 = TOOL), not a property one.
	ct_die "no OSS CAD Suite found -- OSS_CAD_SUITE is unset and none of formal/common/env.sh's defaults exist; the formal targets cannot run"
elif [ -f "$yosys_exe" ]; then
	# The probe is a Python program, so the interpreter has to be real, not
	# merely named: ct_need_python probes the function and heals all three
	# spellings (the presence loop that used to stand here was the last of
	# the sixteen copies). A missing interpreter is 78, not 1 -- it said 1
	# before, i.e. FAIL, a property verdict about an encoder nobody looked at.
	ct_need_python
	if ! python3 - "$yosys_exe" <<'PYEOF'
import struct, sys
p = sys.argv[1]
with open(p, "rb") as f:
    b = f.read(0x1000)
# Bounds first, so a truncated or non-image file says what it is instead of
# dying in a struct.error traceback three lines down. This is a precondition,
# not a swallowed exception: the run still stops, it just stops legibly.
if len(b) < 0x40:
    print(f"STACK-GUARD: {p}: too short for a PE header -- cannot verify stack reserve", file=sys.stderr)
    sys.exit(1)
e_lfanew = struct.unpack_from("<I", b, 0x3C)[0]
if e_lfanew + 0x18 + 0x50 > len(b):
    print(f"STACK-GUARD: {p}: PE header offset 0x{e_lfanew:X} is outside the first 4 KiB "
          f"-- not a PE image, cannot verify stack reserve", file=sys.stderr)
    sys.exit(1)
magic = struct.unpack_from("<H", b, e_lfanew + 0x18)[0]
if magic != 0x20B:
    print(f"STACK-GUARD: {p}: not PE32+ (magic 0x{magic:X}) -- cannot verify stack reserve", file=sys.stderr)
    sys.exit(1)
reserve = struct.unpack_from("<Q", b, e_lfanew + 0x18 + 0x48)[0]
if reserve < 0x8000000:
    print(f"STACK-GUARD FAIL: {p}: SizeOfStackReserve = 0x{reserve:X} < 0x8000000.\n"
          f"  A suite update reverted the stack patch. Deep elaborations will die as\n"
          f"  silent stack overflows ('engine did not return a status'). Re-apply the\n"
          f"  patch (see formal/README.md, Tool traps) before running formal gates.",
          file=sys.stderr)
    sys.exit(1)
print(f"STACK-GUARD OK: SizeOfStackReserve = 0x{reserve:X}")
PYEOF
	then
		echo "### ABORT: yosys.exe stack-reserve guard failed" >&2
		exit "$CT_E_TOOL"
	fi
elif [ -x "$suite/bin/yosys" ]; then
	# ELF yosys (Linux). The reserve lives in the PE optional header, so the
	# patch and this check simply do not apply -- but that is SAID, because a
	# guard that is silently inapplicable is indistinguishable from one that
	# silently did not run, and the two need different reactions.
	echo "STACK-GUARD n/a: $suite/bin/yosys is not a PE binary -- the Windows stack-reserve patch does not apply here"
else
	ct_die "no yosys under $suite/bin (OSS_CAD_SUITE=$suite) -- the formal targets cannot run"
fi
# ---------------------------------------------------------------------------

declare -A tasks=(
	[ovf_injector]="prove cover"
	[preproc_sync]="prove cover live livecover quota quotacover tereq tereqcover reqcoll reqcollcover tereqrst tereqrstcover"
	# msg_gen: the .sby also declares a `prove` task. It is deliberately NOT
	# in this set -- it does not pass (k-induction fails on the module's own
	# drift guards, which reference deep reachability) and it is pre-existing,
	# not caused by any of the P1..P9 packages: the same task returns
	# `DONE (UNKNOWN, rc=4)` at the pre-P4 commit a210f82. The accepted
	# criterion for msg_gen is BMC depth 50. Reasoning and evidence in
	# formal/msg_gen/msg_gen.sby (P4 re-audit finding C-10) -- a task that is
	# silently dropped from the CI set is a silent failure, so it is named
	# here as well as there.
	[msg_gen]="bmc cover"
	[mseo_mdo]="bmc cover live"
	[nexus_formatter]="bmc cover prove"
	# composer_slots: k-induction for both SPLIT_DATA_ACCESS settings. The
	# .sby also declares bmc0/bmc1 (depth 45); they are for extracting a
	# counter-example when the bound is broken and add nothing once the
	# unbounded proof holds, so CI runs the two proofs.
	[composer_slots]="prv0 prv1"
	# A target whose name ends in _xlen64 runs the SAME <base>/run.sh against
	# a source copy with ct_pkg::CT_XLEN flipped to 64 -- see the width leg
	# below for why that needs a leg of its own.
	[nexus_formatter_xlen64]="bmc"
)
default_targets="ovf_injector preproc_sync msg_gen mseo_mdo nexus_formatter composer_slots nexus_formatter_xlen64"
targets="${TARGETS:-$default_targets}"
fail=0
declare -a results

# --- the 64-bit width leg --------------------------------------------------
# Until R1.1 every formal gate had only ever seen ct_pkg::CT_XLEN = 32. The
# wrappers re-type ports by hand to match the DUT and several of those widths
# come from CT_XLEN (formal/nexus_formatter/wrapper.sv:88,173,194,258,259,
# formal/composer_slots/wrapper.sv), so a wrapper that truncates in a 64-bit
# net would prove a property about a net nobody builds, and no gate here
# would have said so. The R1.1 closing audit ran `nexus_formatter bmc` at 64
# BY HAND -- PASS, 16 min -- and recorded the missing leg as finding C-6.
# This is that leg.
#
# The copy is of the WORKING TREE's own sources (tracked plus new-but-not-
# ignored), not a HEAD checkout: a gate that quietly judges something other
# than what is in front of you is worse than no gate. formal/'s sby work
# directories are hundreds of MB and gitignored, which is exactly the set
# `git ls-files -co --exclude-standard` leaves out.
#
# Only nexus_formatter is registered, because that is the one target that has
# been run at 64 and passed. Registering an unproven one would turn the stage
# red for an unknown reason, which is not what a regression leg is for -- run
# it by hand first, the way this one was, then add it here.
XLEN64_DIR="${XLEN64_DIR:-$here/bld/formal_xlen64}"

prepare_xlen64() {
	# The copy is rebuilt from scratch, and the directory is overridable, so
	# the delete is fenced: it only ever removes a directory this function
	# made. Without the marker an XLEN64_DIR pointing somewhere real would
	# be an rm -rf on it.
	local marker="$XLEN64_DIR/.ctte_xlen64_copy"
	case "$XLEN64_DIR" in
		""|/|.|..) echo "### ABORT: refusing XLEN64_DIR='$XLEN64_DIR'" >&2; return 1 ;;
	esac
	if [ -e "$XLEN64_DIR" ] && [ ! -f "$marker" ]; then
		echo "### ABORT: $XLEN64_DIR exists and is not a copy this script made" >&2
		return 1
	fi
	rm -rf "$XLEN64_DIR" || return 1
	mkdir -p "$XLEN64_DIR" || return 1
	: > "$marker" || return 1
	( cd "$here" && git ls-files -z --cached --others --exclude-standard rtl formal \
		| tar --null -T - -cf - ) | ( cd "$XLEN64_DIR" && tar -xf - ) || return 1
	local pkg="$XLEN64_DIR/rtl/pkg/ct_pkg.sv"
	sed -i -E 's/(localparam int unsigned CT_XLEN = )[0-9]+;/\164;/' "$pkg" || return 1
	# The edit IS the leg. If the declaration is ever renamed or reformatted,
	# the sed becomes a no-op and this would run the 32-bit proof a second
	# time and report it as the 64-bit one -- so it is read back.
	grep -qE '^[[:space:]]*localparam int unsigned CT_XLEN = 64;' "$pkg" || {
		echo "### ABORT: CT_XLEN could not be set to 64 in $pkg" >&2
		return 1
	}
	echo "[xlen64] source copy in $XLEN64_DIR"
	grep -nE 'localparam int unsigned CT_XLEN = ' "$pkg"
}

# --- timeout policy --------------------------------------------------------
# FORMAL_TIMEOUT is a per-task budget; the wall-clock limit a target gets is
# that budget times its number of tasks. It used to be one flat 3600 s around
# the whole target no matter how much work it declared, and the summary called
# the result "FAIL mseo_mdo". A formal FAIL means a property was violated.
# That one meant the clock ran out, and a package spent a triage round on it
# (P9 finding, repeated in the P8 sweep).
#
# How the clock is really spent, MEASURED on mseo_mdo 2026-08-06 (log in the
# handoff): sby runs the tasks of one .sby concurrently and they contend, so
# the limit is one wall clock for the whole target. All three passed, and each
# took most of an hour:
#     live  0:52:42 (3162 s)   DONE (PASS)
#     bmc   0:56:15 (3375 s)   DONE (PASS)
#     cover 0:56:17 (3377 s)   DONE (PASS)
# Against the old flat 3600 s that is a 6 % margin for the target as a whole,
# under the load of one session. Anything else running on the machine pushes
# it over, and the run then reported FAIL -- which is how a green target came
# to cost a triage round.
#
# The contention has a named cause, and it is the P9 observation again: the
# `live` task carries a second engine (smtbmc bitwuzla) that was still
# grinding at step 68 of 120 after 51 minutes of engine time on a bound the
# first engine (btor btormc) had already cleared at 20:06. `cover` made
# essentially no progress while it ran. Raising the budget is the symptom
# fix; scoping that engine away from `live` is the cause fix and is a change
# to the proof configuration, so it is left as a measured recommendation
# rather than made here (formal/mseo_mdo/mseo_mdo.sby).
#
# So the budget scales with the declared work -- a target with twelve tasks
# (preproc_sync) gets room its long pole may need, one with two does not
# reserve it -- and a timeout is reported as TIMEOUT, never as FAIL, naming
# the knob. Per-target override from the environment: FORMAL_TIMEOUT_<target>
# is the TOTAL for that target and switches the scaling off.
ft_total() {  # $1 = target, $2 = task count -> seconds
	local t="$1" n="$2" v
	eval "v=\${FORMAL_TIMEOUT_${t}:-}"
	[ -n "$v" ] && { echo "$v"; return; }
	echo $(( ${FORMAL_TIMEOUT:-3600} * n ))
}

# $1 = label, $2 = timeout, $3.. = command. Appends one result line.
run_leg() {
	local label="$1" tmo="$2"; shift 2
	local rc=0 t0 dt
	t0=$SECONDS
	timeout "$tmo" "$@" || rc=$?
	dt=$((SECONDS - t0))
	case $rc in
		0)   results+=("PASS  $label (${dt}s)") ;;
		# 124 = GNU timeout killed it. Not a property failure: red, but red
		# about the clock. The remedy is named in the line itself so a
		# reader does not have to find this file first.
		124) results+=("TIMEOUT  $label -- killed after ${tmo}s; NOT a property failure. Raise FORMAL_TIMEOUT_${label%% *}=<seconds> (total for this target) or FORMAL_TIMEOUT=<seconds> (per task).")
		     fail=1 ;;
		*)   results+=("FAIL  $label (rc=$rc, ${dt}s)"); fail=1 ;;
	esac
	return 0
}

for t in $targets; do
	# shellcheck disable=SC2086
	set -- ${tasks[$t]}
	tmo="$(ft_total "$t" "$#")"
	base="${t%_xlen64}"
	root="$here/formal"
	envpre=()
	if [ "$base" != "$t" ]; then
		echo "########## FORMAL: preparing the CT_XLEN=64 source copy"
		if ! prepare_xlen64; then
			results+=("FAIL  $t -- CT_XLEN=64 source copy could not be prepared")
			fail=1
			continue
		fi
		root="$XLEN64_DIR/formal"
		# run.sh would resolve RTL to $root/../rtl on its own, which is the
		# copy -- but an RTL_DIR already exported by the caller would win and
		# this leg would silently prove the 32-bit net again. Pin it.
		envpre=(env "RTL_DIR=$XLEN64_DIR/rtl")
	fi
	echo "########## FORMAL: $t (${tasks[$t]}) -- $# task(s), timeout ${tmo}s"
	run_leg "$t (${tasks[$t]})" "$tmo" \
		${envpre[@]+"${envpre[@]}"} bash "$root/$base/run.sh" ${tasks[$t]}
	# No red replay for a width leg: run_red.sh mutates the DUT to falsify a
	# property, and none of those mutations has been run at 64 -- an unproven
	# counter-proof would be a red line nobody can read.
	if [ "$base" = "$t" ] && [ "${RED:-0}" = "1" ] && [ -f "$t/run_red.sh" ]; then
		echo "########## FORMAL RED: $t"
		run_leg "$t red counter-proof" "$tmo" bash "$t/run_red.sh"
	fi
done

echo "========== STAGE-2b-SUMMARY =========="
printf '%s\n' "${results[@]}"
exit $fail
