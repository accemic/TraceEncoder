#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Red counter-proof for P-MSG-4 and for the hold-mirror drift guard
# (A_consume_decomposition), added 2026-08-24 after a stale f_any_hold list
# produced a counterexample that looked like an RTL defect.
#
# Unlike run_red.sh (which replays a historical pre-fix commit) this one
# MUTATES: each check disables exactly one mechanism and demands that a NAMED
# assertion turn red. A mutation that stays green means the assertion cannot
# fail and is decoration.
#
# Each check states the assertion it expects, and the script attributes the
# failure by the CONTENT of the generated line, not by its number. That is not
# pedantry: the first draft of this file reported MUT-A as proof of
# A_msg4_slot_pays when the assertion that actually fired was
# A_msg4_debt_kept. One mutation trips several assertions and the first one
# wins, so attribution by line number would have shipped that error.
#
#   MUT-0  control: unmutated build, must stay GREEN at depth 50
#   MUT-A  RTL: the free-slot arm no longer emits the flush marker (it still
#              clears the request), so the debt is dropped silently
#              -> A_msg4_debt_kept     (earliest assertion to see it)
#   MUT-B  ... same RTL mutation, A_msg4_debt_kept disabled
#              -> A_msg4_slot_pays     (the free slot did not pay)
#   MUT-C  ... plus A_msg4_slot_pays disabled
#              -> A_msg4_no_idle_beat  (the hold-enumeration-free backstop is
#                 independently live)
#   MUT-D  WRAPPER, clean RTL: f_any_hold loses cf_sync_icnt_overflow_hold,
#              i.e. the exact state of the file between 2026-08-12 and
#              2026-08-24, with all three P-MSG-4 assertions disabled
#              -> A_consume_decomposition (drift caught by its own named
#                 guard instead of by a misleading P-MSG-4 counterexample)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

RTL="$SCRIPT_DIR/../../rtl"
MUT="$SCRIPT_DIR/build/mut"
mkdir -p "$MUT"

# --- mutation primitives (build-local copies; rtl/ and wrapper.sv untouched)
mut_rtl_no_flush_emit () {
	perl -0pe 's/(else if \(FlushRequest\) begin.*?)\bsend_flush_msg\(\);/$1;\/\/ MUT: marker suppressed/s' \
		"$RTL/ct_L2_msg_gen.sv" > "$MUT/ct_L2_msg_gen.sv"
	grep -q "MUT: marker suppressed" "$MUT/ct_L2_msg_gen.sv" \
		|| { echo "ERROR: RTL mutation did not apply"; exit 1; }
}
copy_rtl_clean () { cp "$RTL/ct_L2_msg_gen.sv" "$MUT/ct_L2_msg_gen.sv"; }

mut_wrapper () {  # $@ = mutations to apply to the wrapper copy
	cp "$SCRIPT_DIR/wrapper.sv" "$MUT/wrapper.sv"
	local tag
	for tag in "$@"; do
		case "$tag" in
		drop_debt_kept)
			perl -0pi -e 's/assert \(f_flushreq\s*\n\s*\|\| \(\(trace_msg\.sub_type == SUB_MSG_OTHER\)\s*\n\s*&& \(trace_msg\.tcode == NEXUS_MSG_FLUSH\)\)\);(\s*)\/\/ A_msg4_debt_kept/assert (1);$1\/\/ A_msg4_debt_kept DISABLED/s' "$MUT/wrapper.sv"
			grep -q "A_msg4_debt_kept DISABLED" "$MUT/wrapper.sv" \
				|| { echo "ERROR: could not disable A_msg4_debt_kept"; exit 1; } ;;
		drop_slot_pays)
			perl -0pi -e 's/assert \(\(trace_msg\.sub_type == SUB_MSG_OTHER\)\s*\n\s*&& \(trace_msg\.tcode == NEXUS_MSG_FLUSH\)\);(\s*)\/\/ A_msg4_slot_pays/assert (1);$1\/\/ A_msg4_slot_pays DISABLED/s' "$MUT/wrapper.sv"
			grep -q "A_msg4_slot_pays DISABLED" "$MUT/wrapper.sv" \
				|| { echo "ERROR: could not disable A_msg4_slot_pays"; exit 1; } ;;
		drop_no_idle)
			perl -0pi -e 's/assert \(trace_msg\.sub_type != SUB_MSG_NONE\);(\s*)\/\/ A_msg4_no_idle_beat/assert (1);$1\/\/ A_msg4_no_idle_beat DISABLED/s' "$MUT/wrapper.sv"
			grep -q "A_msg4_no_idle_beat DISABLED" "$MUT/wrapper.sv" \
				|| { echo "ERROR: could not disable A_msg4_no_idle_beat"; exit 1; } ;;
		stale_holdlist)
			perl -0pi -e 's/^\t                        \|\| dut\.cf_sync_icnt_overflow_hold\n/\t\/\/ MUT-D: eighth arm removed (state of 2026-08-12..24)\n/m' "$MUT/wrapper.sv"
			grep -q "MUT-D: eighth arm removed" "$MUT/wrapper.sv" \
				|| { echo "ERROR: could not stale the hold list"; exit 1; } ;;
		*) echo "ERROR: unknown wrapper mutation $tag"; exit 1 ;;
		esac
	done
}

build_mut () {
	perl -0pe 's/,\s*\n\s*import\s+have_available//' \
		"$RTL/external/stream/source_if.sv" > "$MUT/source_if_patched.sv"
	sv2v -E Assert -E SeverityTask \
		"$RTL/pkg/nexus_vendor_riscv_pkg.sv" \
		"$RTL/pkg/ct_cs_cpuif_pkg.sv" \
		"$RTL/pkg/ct_cs_cpuif_types_pkg.sv" \
		"$RTL/pkg/ct_pkg.sv" \
		"$RTL/pkg/tip_pkg.sv" \
		"$RTL/pkg/ct_etip_pkg.sv" \
		"$RTL/pkg/ct_cs_if.sv" \
		"$MUT/source_if_patched.sv" \
		"$MUT/ct_L2_msg_gen.sv" \
		"$MUT/wrapper.sv" \
		| sed -e 's/\buwire\b/wire/g' -e 's/\bf_msg_check\.//g' \
		| perl -0pe 's/\s*else\s+\$error\s*\([^;]*\);/;/g; s/\w+\s*:\s*assert\s+property\s*\(.*?\)\s*else\s+begin.*?\bend\b//gs' \
		> "$SCRIPT_DIR/build/msg_gen_mut.v"
}

# Attribute a failing generated line to its wrapper assertion by CONTENT:
# sv2v strips comments, so the tag is gone -- but each P-MSG-4 assertion has a
# unique guard variable on the line above, and A_holdset_complete is the only
# one that mentions f_eligible.
attribute () { # $1 = log -> "<tag> (line N)"
	local ln body prev tag=UNKNOWN
	ln="$(grep -oE 'msg_gen_mut\.v:[0-9]+' "$1" | head -1 | cut -d: -f2)"
	[ -n "$ln" ] || { echo "UNKNOWN (no line in log)"; return; }
	body="$(sed -n "${ln}p" "$SCRIPT_DIR/build/msg_gen_mut.v")"
	prev="$(sed -n "$((ln-1))p" "$SCRIPT_DIR/build/msg_gen_mut.v")"
	case "$body" in *f_eligible*) tag=A_consume_decomposition ;; esac
	if [ "$tag" = UNKNOWN ]; then
		case "$prev" in
		*"if (p_flushreq_q)"*) tag=A_msg4_debt_kept ;;
		*"if (p_freeslot_q)"*) tag=A_msg4_slot_pays ;;
		*"if (p_debtslot_q)"*) tag=A_msg4_no_idle_beat ;;
		*"if (p_hold_q)"*)     tag=A_msg3_drain_emits ;;
		*"if (p_nonother_q)"*) tag=A_msg1_noclobber ;;
		esac
	fi
	echo "$tag (line $ln)"
}

run_mut () { # $1 = name, $2 = fail|pass, $3 = expected assertion tag
	local name="$1" expect="$2" want="${3:-}" log rc=0 got
	log="$SCRIPT_DIR/build/red_p4_${name}.log"
	build_mut
	sby -f "$SCRIPT_DIR/msg_gen_mut.sby" > "$log" 2>&1 || rc=$?
	if [ "$expect" = fail ]; then
		if [ "$rc" -eq 0 ]; then
			echo "  $name: GREEN although mutated -- that assertion cannot fail. NOT a proof."
			return 1
		fi
		grep -q "DONE (FAIL" "$log" \
			|| { echo "  $name: ended without a clean FAIL (tool error?)"; tail -3 "$log"; return 1; }
		got="$(attribute "$log")"
		if [ -n "$want" ] && [ "${got%% *}" != "$want" ]; then
			echo "  $name: RED, but on $got -- expected $want."
			echo "        The mutation does not isolate what this check claims."
			return 1
		fi
		echo "  $name: RED as required on $got, at $(grep -oE 'step [0-9]+' "$log" | tail -1)"
	else
		[ "$rc" -eq 0 ] || { echo "  $name: RED although unmutated"; tail -3 "$log"; return 1; }
		echo "  $name: GREEN as required (BMC 50)"
	fi
	return 0
}

[ -f "$SCRIPT_DIR/msg_gen_mut.sby" ] || { echo "ERROR: msg_gen_mut.sby missing"; exit 1; }

echo "== MUT-0 control: unmutated build must be GREEN"
copy_rtl_clean; mut_wrapper
run_mut MUT0_control pass

echo "== MUT-A: free-slot arm drops the marker but still clears the request"
mut_rtl_no_flush_emit; mut_wrapper
run_mut MUTA_debt_kept fail A_msg4_debt_kept

echo "== MUT-B: ... A_msg4_debt_kept disabled"
mut_rtl_no_flush_emit; mut_wrapper drop_debt_kept
run_mut MUTB_slot_pays fail A_msg4_slot_pays

echo "== MUT-C: ... A_msg4_slot_pays also disabled"
mut_rtl_no_flush_emit; mut_wrapper drop_debt_kept drop_slot_pays
run_mut MUTC_no_idle_beat fail A_msg4_no_idle_beat

echo "== MUT-D: stale hold mirror, clean RTL, all three P-MSG-4 assertions off"
copy_rtl_clean; mut_wrapper drop_debt_kept drop_slot_pays drop_no_idle stale_holdlist
run_mut MUTD_consume_decomposition fail A_consume_decomposition

echo "RED COUNTER-PROOF P-MSG-4 + drift guard OK: control green, four mutations red on the assertions they name."
