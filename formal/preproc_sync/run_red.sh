#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Red counter-proof for the Klasse-9 property (P-SYNC-1, Gate 14,
# Fix 335393b6). Two-sided falsification:
#   1) P-SYNC-1-only build against the CURRENT RTL      -> must PASS
#   2) the same build against the PRE-FIX RTL (441eac4c) -> must FAIL
# The pre-fix stand comes from a detached git worktree so the working
# repo (battery, vendored trees) stays untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
source "$SCRIPT_DIR/../common/env.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFIX_COMMIT=441eac4c   # parent of 335393b6 (resume-anchor-race fix)
WT_DIR="$REPO_ROOT/../ctte_worktrees/klasse9_$PREFIX_COMMIT"

if [ ! -d "$WT_DIR" ]; then
	git -C "$REPO_ROOT" worktree add --detach "$WT_DIR" "$PREFIX_COMMIT"
fi

build_red () { # $1 = RTL root
	local rtl="$1"
	sv2v -E Assert -DRED_CLASS9 \
		"$rtl/pkg/nexus_vendor_riscv_pkg.sv" \
		"$rtl/pkg/ct_cs_cpuif_pkg.sv" \
		"$rtl/pkg/ct_cs_cpuif_types_pkg.sv" \
		"$rtl/pkg/ct_pkg.sv" \
		"$rtl/pkg/tip_pkg.sv" \
		"$rtl/external/common/counter.sv" \
		"$rtl/external/common/signal_cdc.sv" \
		"$rtl/external/common/signal_ack_lock_fsm.sv" \
		"$rtl/external/common/vector_cdc2.sv" \
		"$rtl/pkg/tip_if.sv" \
		"$rtl/pkg/ct_preproc_if.sv" \
		"$rtl/pkg/ct_cs_if.sv" \
		"$rtl/preproc/ct_L23_preproc_sync.sv" \
		"$SCRIPT_DIR/wrapper.sv" \
		| sed -e 's/\buwire\b/wire/g' -e 's/\bf_preproc_check\.//g' -e 's/\bf_live\.//g' \
		> "$SCRIPT_DIR/build/preproc_sync_red.v"
}

mkdir -p "$SCRIPT_DIR/build"
cd "$SCRIPT_DIR"

echo "== red cross-check 1/2: P-SYNC-1-only vs CURRENT rtl (expect PASS)"
build_red "$REPO_ROOT/rtl"
if ! sby -f preproc_sync_red.sby > build/red_green_side.log 2>&1; then
	echo "ERROR: P-SYNC-1 FAILED on the CURRENT (fixed) RTL — property or probe defect."
	tail -5 build/red_green_side.log
	exit 1
fi
echo "   PASS on fixed RTL — property holds where it must."

echo "== red cross-check 2/2: P-SYNC-1-only vs pre-fix worktree $PREFIX_COMMIT (expect FAIL)"
build_red "$WT_DIR/rtl"
if sby -f preproc_sync_red.sby > build/red_red_side.log 2>&1; then
	echo "ERROR: P-SYNC-1 PASSED on the pre-fix RTL — the property does NOT catch Klasse 9."
	exit 1
fi
if ! grep -q "DONE (FAIL" build/red_red_side.log; then
	echo "ERROR: pre-fix run ended without a proper FAIL (tool error?):"
	tail -5 build/red_red_side.log
	exit 1
fi
echo "   FAIL on pre-fix RTL — Klasse-9 race caught. CEX:"
grep -E "failed assertion|Assert failed" build/red_red_side.log | head -2

echo "RED COUNTER-PROOF OK (green on fix, red on $PREFIX_COMMIT)."

# ---------------------------------------------------------------------------
# P2 quota mutations (P-SYNC-5/6/7 falsifiability; pattern from
# formal/mseo_mdo/run_red.sh). No historical defect commit exists for the
# quota family, so each new property is shown red under a deliberate
# single-line defect on a BUILD-LOCAL copy of the DUT source (run.sh MUTATE
# hook; the tree is never touched):
#   M-A mode gate dropped   : the TRACE_BYTES term of is_overflow loses its
#                             InstSyncMode gate — the pre-P2 latent
#                             ungated-OR defect (TASK_STATE G6) reintroduced
#                             -> A_sync5_mode (task prove) must fail
#   M-B rearm dropped       : the PERIODIC arm no longer raises SyncCntClr —
#                             the egress counter is never cleared
#                             -> A_sync7_rearm (task quota) must fail
#   M-C silent rearm        : the PERIODIC arm still rearms the egress
#                             counter but no longer emits the message (the
#                             "lost anchor" class). The quota level keeps
#                             dropping, so the liveness bound A_sync6_live
#                             stays satisfied and ONLY the window grows
#                             -> A_sync5_win (task quota) must fail
#   M-D quota level dead    : the byte-quota term is removed from
#                             is_overflow altogether (pre-P2 state: the
#                             egress counters exist but never reach the sync
#                             generator). The held level then never produces
#                             a sync -> A_sync6_live (task quota) must fail
#                             (shallowest counterexample: pressure exceeds
#                             F_K6 = 32 cycles long before the window bound
#                             of 200 B = 50 byte events is reached).
# Ordering note (honest scope of A_sync5_win): in the f_quota environment
# the window bound is IMPLIED by the liveness bound (pressure <= 32 cycles
# => window <= (4 + 32) * 4 B = 144 B < 200 B), so a defect that kills the
# sync altogether always trips A_sync6_live first. M-C is exactly the defect
# class that separates them — it keeps liveness satisfied by construction
# and is therefore the falsifiability witness for the window bound itself.
#
# Each red run maps EVERY failing line of the generated model back to the
# property source (pattern from formal/nexus_formatter/run_red.sh:55-67;
# sv2v strips comments, so the match is on the property's signal tokens).
# A defect that trips an unrelated property is reported as such instead of
# being counted as a red for the target family.
# ---------------------------------------------------------------------------
run_mut () { # $1 name, $2 perl expr, $3 sby task, $4 target-token regex, $5 family label, [$6 sv2v defines], [$7 target: dut|pacer]
	local name="$1" expr="$2" task="$3" tokens="$4" family="$5" defs="${6:-}" tgt="${7:-dut}"
	local log="$SCRIPT_DIR/build/red_$name.log"
	local -a env=()
	case "$tgt" in
		dut)   env=(MUTATE="$expr" MUTATE_PACER="") ;;
		pacer) env=(MUTATE=""      MUTATE_PACER="$expr") ;;
		*)     echo "ERROR: unknown mutation target '$tgt'"; exit 1 ;;
	esac
	echo "== red mutation $name (expect FAIL on task $task; target family: $family${defs:+; $defs})"
	if env "${env[@]}" SV2V_DEFS="$defs" bash "$SCRIPT_DIR/run.sh" "$task" > "$log" 2>&1; then
		echo "ERROR: mutation $name PASSED — property does not see the defect."
		exit 1
	fi
	if ! grep -q "DONE (FAIL" "$log"; then
		echo "ERROR: mutation $name ended without a proper FAIL (tool error?):"
		tail -5 "$log"
		exit 1
	fi
	local hit=0 line src
	while read -r line; do
		[ -n "$line" ] || continue
		src=$(sed -n "${line}p" "$SCRIPT_DIR/build/preproc_sync_formal.v")
		printf '   failing assert (line %s): %s\n' "$line" "$src"
		if echo "$src" | grep -qE "$tokens"; then hit=1; fi
	done < <(grep -E "Assert failed in|failed assertion" "$log" \
		| grep -oE 'formal\.v:[0-9]+' | cut -d: -f2 | sort -un)
	if [ "$hit" -ne 1 ]; then
		echo "ERROR: mutation $name failed OUTSIDE its target property family ($family: $tokens)."
		exit 1
	fi
	grep -E "failed assertion|Assert failed" "$log" | head -1
}

run_mut MA_mode_gate \
	's/\|\|\(quota_byte_ovf_cdc\s+&&\s+\(cs_tip\.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES\s*\)\)/||(quota_byte_ovf_cdc)/s' \
	prove 'p_sync_mode_q' 'A_sync5_mode (mode discrimination)'

run_mut MB_rearm_dropped \
	's/(SyncReason\s*<=\s*NEXUS_SYNC_PERIODIC;)\s*\n\s*SyncCntClr\s*<=\s*.1;/$1/s' \
	quota 'f_seen_per|f_rearm' 'A_sync7_rearm (no double request)'

run_mut MC_periodic_silent \
	's/SyncReason\s*<=\s*NEXUS_SYNC_PERIODIC;\s*\n(\s*)SyncCntClr/$1SyncCntClr/s' \
	quota 'f_win' 'A_sync5_win (window bound)'

run_mut MD_quota_level_dead \
	's/\|\|\(quota_byte_ovf_cdc(\s+&&\s+\(cs_tip\.trTeInstSyncMode == ct_cs_cpuif__te__trTeControl__trTeInstSyncMode_e__ITR_SYNC_TRACE_BYTES\s*\)\))/||(1\x27b0$1/s' \
	quota 'f_press' 'A_sync6_live (no lost request)'

# ---------------------------------------------------------------------------
# P8 mutations (P-SYNC-9/10 falsifiability). Same MUTATE hook, same mapping
# discipline as the P2 family above:
#   M-E ack dropped        : the arm serves the request but never
#                            acknowledges it -- precisely what the
#                            acknowledgement exists to prevent. Its FAILURE
#                            MODE changed with the B-N1 level handshake and
#                            the target property changed with it, which is
#                            worth stating rather than quietly re-pointing:
#                            under the retired strobe pacing the launch side
#                            stayed Busy for ever and no later request could
#                            be raised, so the "lost request" bound caught it;
#                            with a held request level the consumer simply
#                            sees the still-standing request again and serves
#                            it over and over, so the request is not lost, it
#                            is multiplied -> A_sync10_credit (task tereq)
#                            must fail (more messages than requests). Both
#                            readings are the same defect seen from the two
#                            sides of the handshake.
#   M-F pending never clears : the arm emits the message but leaves its
#                            pending latch set, so it fires again on the very
#                            next qualifying retire -- one request, a stream
#                            of messages -> A_sync10_credit (task tereq) must
#                            fail (more messages than launches)
#   M-G ack without message : the arm acknowledges the request and clears its
#                            latch but emits NO synchronization message. This
#                            is the defect the P8 audit used to show that the
#                            first A_sync9_live (pressure keyed on the pacer's
#                            Busy flag, which this very acknowledgement clears)
#                            did not enforce its own name -- it stayed green,
#                            and only the auxiliary credit bound caught the
#                            class. With the pressure keyed on the software
#                            write instead, A_sync9_live (task tereq) must fail
#                            -- isolated with RED_MASK_SYNC10 because the
#                            credit pair has the shallower counterexample.
# ---------------------------------------------------------------------------
run_mut ME_ack_dropped \
	"s/TeSyncAck     <= '1;/TeSyncAck     <= '0;/s" \
	tereq 'f_credit' 'A_sync10_credit (an unacknowledged request is served again and again)'

run_mut MF_pending_stuck \
	"s/(TeSyncAck\s+<=\s+'1;)\s*\n\s*TeSyncPending\s+<=\s+'0;/\$1/s" \
	tereq 'f_credit' 'A_sync10_credit (no double request)'

run_mut MG_ack_without_msg \
	"s/SyncReason\s+<=\s+NEXUS_SYNC_REQ;/SyncReason    <= NEXUS_SYNC_NONE;/s" \
	tereq 'f_press' 'A_sync9_live (no lost request, DUT-independent trigger)' \
	'-DRED_MASK_SYNC10'

# ---------------------------------------------------------------------------
# P8 audit B-5: the request/quota COLLISION (P-SYNC-11).
#   M-H quota outranks the request : the explicit arm steps aside while a
#                            quota level stands, so the beat the two share
#                            produces a PERIODIC instead of the request's own
#                            message -- the priority inversion the RTL reading
#                            claims cannot happen -> A_sync11_prio (task
#                            reqcoll) must fail.
# ---------------------------------------------------------------------------
run_mut MH_quota_outranks_req \
	's/\|\| do_tesync\)/|| (do_tesync && !is_overflow))/s' \
	reqcoll 'sr_ovf_seen|sr_tip_pend' 'A_sync11_prio (request wins the shared beat)'

# ---------------------------------------------------------------------------
# P8 closing audit B-N1: the request across a reset of the CONSUMER's domain
# alone (P-SYNC-12).
#   M-I request not held  : the pacer withdraws the request one cycle after
#                            raising it instead of holding it until the
#                            acknowledgement -- which is exactly the retired
#                            strobe design, in one line. Nothing is then left
#                            standing for the consumer to see again after a
#                            reset, so a request the reset caught in the
#                            crossing is dropped on the floor: no
#                            acknowledgement, no message, ever
#                            -> A_sync12_rstlive (task tereqrst) must fail.
#                            This one mutates the PACER, which is why run.sh
#                            grew the MUTATE_PACER hook.
# ---------------------------------------------------------------------------
run_mut MI_request_not_held \
	's/else if \(Req && ack\) begin/else if (Req) begin/s' \
	tereqrst 'f_press' 'A_sync12_rstlive (the held request level is what survives a consumer reset)' \
	'' pacer

echo "RED MUTATION CROSS-CHECKS OK (9/9 red where they must be)."
