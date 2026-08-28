#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# wp_board_gate.sh -- G1 board-gate driver for the tgc5b2_axis_wp watchpoint
# testbed on the KV260: the Bash port of the predecessor repository's
# g1_board_run.ps1 (932 lines) + package_c0b.ps1 (34 lines), ported during
# the consolidation into this repository.
#
#   wp_board_gate.sh --phase <gen|deploy|runa|runb|checksa|checksb|restore> \
#                     [--board <ip>] [--app tgc5b2_axis_wp_c0b] [...]
#
# Phases (each individually invocable, state lives in --work):
#   gen      derive host artifacts from sw/ (C1b rules: 364 real + 659 odd
#            filler = 1023 slots) and package the bitstream into a loadable
#            app dir -- no board access.
#   deploy   stage the host-side tooling (axis_wp_host + wp_board.py + the
#            run/restore scripts + gen's generated data) onto the board's
#            /tmp/wp_board_run, then load the app (do_load(), see below).
#            Needs --board (acquire whatever hardware lease your site uses
#            for the board first).
#   runa     reload (do_load()) + finite walk: 851 records/core expected,
#            0 drops; drain happens AFTER the halt, through the F1 reader
#            (--source fifo).
#   runb     reload (do_load()) + endless walk: continuous per-FIFO drain
#            (--poll-ms/--duration-s), drops+wraps expected and balanced.
#   checksa  host checks on run A (count equality, W1/meta, cross-core TS
#            merge).
#   checksb  host checks on run B (subsequence, wraps, drop balance both
#            sides).
#   restore  restore the previous app + dashboard, report board health.
#
# DIFFERENCES FROM THE SOURCE (see README.md "Design notes / deltas" for
# the full reasoning -- summary here so the flags below make sense):
#   * the source's OS-level `g1_prep_install.sh`/`g1_prep_reload.sh` (dtc
#     compile + install + loadapp) is now split: the dashboard-stop/prev-
#     app-capture/unload/clock-set half lives in prep_load.sh + the fpga-
#     state/MAGIC-verify half in prep_verify.sh (both board-side, run by
#     do_load() below); the dtc/install/loadapp/hash-verify half is
#     delegated to the UNMODIFIED examples/kv260/common/board/
#     deploy_kv260_app.sh, called from the host between the two.
#   * `deploy` now also loads the app (do_load()), not just stages files --
#     deploy_kv260_app.sh's job IS load, and `runa`/`runb` reload again
#     anyway (matching the source's per-run reload discipline), so nothing
#     is lost by `deploy` doing one load cycle up front.
#   * --expected-md5 has NO hardcoded default (the source's was pinned to
#     one specific PowerShell-side C0b rebuild and would false-fail
#     against every future resynthesis); it is optional and, when set, is
#     checked against the FRESHLY PACKAGED local bit.bin during `gen`
#     (deploy_kv260_app.sh separately verifies the hash it actually pushed
#     to the target, so the board-side hash is already covered).
#
# Verdict lines kept byte-identical to the PowerShell driver on purpose
# (regression comparability is the gate): ### GEN_OK, ### DEPLOY_OK,
# G1GEN ..., G1CHECK ... PASS/FAIL, ### CHECKS_OK, ### PREP_FAILED,
# PLCLK_FAILED, MD5_MISMATCH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TE_ROOT="$(cd "$HERE/../../../.." && pwd)"
SW="$TE_ROOT/examples/kv260/tgc5b2_axis_wp/sw"
TOOLS="$TE_ROOT/tools/axis_wp_host"
COMMON_BOARD="$TE_ROOT/examples/kv260/common/board"
DEFAULT_BIT="$TE_ROOT/examples/kv260/tgc5b2_axis_wp/fpga/proj/tgc5b2_axis_wp.runs/impl_1/tgc5b2_kv260_top.bit"
DEFAULT_WORK="$HERE/run"

PY="${PY:-py}"
command -v py >/dev/null 2>&1 || PY=python3

usage() {
    sed -n '2,57p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

PHASE="" BOARD="" APP="tgc5b2_axis_wp_c0b" EXPECTED_MD5=""
JUMP="${KV260_JUMP:-}" USER_="ubuntu" SUDO_PASS="${KV260_SUDO_PASS:-}"
PLMHZ=75 RUNB_DRAIN_SEC="65.0" RUNB_MAX_RECORDS=1600000
BIT="$DEFAULT_BIT" WORK="$DEFAULT_WORK" VIVADO_BIN="" DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --phase) PHASE="$2"; shift 2;;
        --board) BOARD="$2"; shift 2;;
        --app) APP="$2"; shift 2;;
        --expected-md5) EXPECTED_MD5="$2"; shift 2;;
        --jump) JUMP="$2"; shift 2;;
        --user) USER_="$2"; shift 2;;
        --sudo-pass) SUDO_PASS="$2"; shift 2;;
        --pl-mhz) PLMHZ="$2"; shift 2;;
        --runb-drain-sec) RUNB_DRAIN_SEC="$2"; shift 2;;
        --runb-max-records) RUNB_MAX_RECORDS="$2"; shift 2;;
        --bit) BIT="$2"; shift 2;;
        --work) WORK="$2"; shift 2;;
        --vivado-bin) VIVADO_BIN="$2"; shift 2;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "wp_board_gate: unknown argument $1" >&2; exit 2;;
    esac
done

case "$PHASE" in
    gen|deploy|runa|runb|checksa|checksb|restore) ;;
    *) echo "wp_board_gate: --phase must be one of gen|deploy|runa|runb|checksa|checksb|restore (got '$PHASE')" >&2
       exit 2;;
esac

mkdir -p "$WORK"

need_board_ip() {
    [ -n "$BOARD" ] || {
        echo "### ERROR: --board <ip> required for phase $PHASE (or set KV260_BOARD)"
        exit 2
    }
}

need_gen_artifacts() {
    for f in wp_table.txt wp_real.txt expected_full.txt prog.hex; do
        [ -f "$WORK/$f" ] || {
            echo "### ERROR: $WORK/$f missing -- run --phase gen first"
            exit 1
        }
    done
    [ -f "$WORK/app_pkg/$APP/$APP.bit.bin" ] || {
        echo "### ERROR: $WORK/app_pkg/$APP/$APP.bit.bin missing -- run --phase gen first"
        exit 1
    }
}

# -- do_load(): the OS-level prep + deploy_kv260_app.sh + verify sandwich,
# shared by `deploy`, `runa` and `runb` (each reloads before it runs, like
# the source). $1 = a short tag for this call's log file names.
do_load() {
    local tag="$1" rc=0

    local prep_log="$WORK/prep_${tag}.log"
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] ssh $JUMP \"ssh $USER_@$BOARD 'sudo -S sh /tmp/wp_board_run/prep_load.sh $PLMHZ'\""
    else
        ssh "$JUMP" "ssh ${USER_}@${BOARD} 'echo ${SUDO_PASS} | sudo -S sh /tmp/wp_board_run/prep_load.sh ${PLMHZ}'" \
            2>&1 | tee "$prep_log" || rc=${PIPESTATUS[0]}
        if [ "$rc" -ne 0 ]; then echo "### PREP_FAILED (see $prep_log)"; exit 1; fi
        grep -q "PREP_LOAD_OK" "$prep_log" || { echo "### PREP_FAILED (PREP_LOAD_OK missing, see $prep_log)"; exit 1; }
        if grep -q "PLCLK_FAILED" "$prep_log"; then echo "### PLCLK_FAILED (see $prep_log)"; exit 1; fi
        grep -q "CLK_SET_OK ${PLMHZ}MHz" "$prep_log" || { echo "### PLCLK_UNVERIFIED (see $prep_log)"; exit 1; }

        if [ ! -f "$WORK/prev_app.txt" ]; then
            local prev
            prev="$(awk '
                /PREV_LISTAPPS_BEGIN/ { inblock=1; next }
                /PREV_LISTAPPS_END/   { inblock=0; next }
                inblock {
                    n = split($0, tok, /[ \t]+/)
                    if (n >= 1 && tok[1] == "") { for (i=1;i<n;i++) tok[i]=tok[i+1]; n-- }
                    if (n >= 2 && tok[n] != "-1" && tok[1] !~ /^Accelerator/) prev = tok[1]
                }
                END { print (prev == "" ? "none" : prev) }
            ' "$prep_log")"
            printf '%s\n' "$prev" > "$WORK/prev_app.txt"
            echo "### PREV_APP: $prev"
        fi
    fi

    local deploy_log="$WORK/deploy_${tag}.log"
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] $COMMON_BOARD/deploy_kv260_app.sh --app-dir $WORK/app_pkg/$APP --board $BOARD --jump $JUMP --user $USER_ --sudo-pass ****"
    else
        rc=0
        "$COMMON_BOARD/deploy_kv260_app.sh" --app-dir "$WORK/app_pkg/$APP" --board "$BOARD" \
            --jump "$JUMP" --user "$USER_" --sudo-pass "$SUDO_PASS" \
            2>&1 | tee "$deploy_log" || rc=${PIPESTATUS[0]}
        if [ "$rc" -ne 0 ]; then echo "### DEPLOY_FAILED (see $deploy_log)"; exit 1; fi
        grep -q "### DEPLOY_OK" "$deploy_log" || { echo "### DEPLOY_FAILED (no DEPLOY_OK marker, see $deploy_log)"; exit 1; }
    fi

    local verify_log="$WORK/verify_${tag}.log"
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] ssh $JUMP \"ssh $USER_@$BOARD 'sudo -S sh /tmp/wp_board_run/prep_verify.sh'\""
        echo "### DRY_RUN_OK ($tag): no board contact made"
        return 0
    fi
    rc=0
    ssh "$JUMP" "ssh ${USER_}@${BOARD} 'echo ${SUDO_PASS} | sudo -S sh /tmp/wp_board_run/prep_verify.sh'" \
        2>&1 | tee "$verify_log" || rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then echo "### PREP_FAILED (see $verify_log)"; exit 1; fi
    if grep -q "FPGA_NOT_OPERATING" "$verify_log"; then echo "### FPGA_NOT_OPERATING (see $verify_log)"; exit 1; fi
    grep -q "MAGIC 0x41575031" "$verify_log" || { echo "### MAGIC_FAILED (see $verify_log)"; exit 1; }
    grep -q "PREP_OK" "$verify_log" || { echo "### PREP_FAILED (PREP_OK missing, see $verify_log)"; exit 1; }

    echo "### PREP_OK ($tag): pl_clk0 $PLMHZ MHz, deploy verified, MAGIC OK"
}

# =============================================================================
# Phase gen: host artifacts from sw/ + packaged app dir -- no board access.
# =============================================================================
if [ "$PHASE" = "gen" ]; then
    if ! "$PY" "$HERE/wp_gen.py" "$SW/expected_hits.txt" "$SW/axis_wp_demo.hex" "$WORK"; then
        echo "### G1GEN_FAILED"
        exit 1
    fi

    if [ ! -f "$BIT" ]; then
        echo "### ERROR: bit missing: $BIT (build it first via the fpga/ Vivado flow)"
        exit 1
    fi

    pkg_args=(--bit "$BIT" --app "$APP" --out "$WORK/app_pkg")
    [ -n "$VIVADO_BIN" ] && pkg_args+=(--vivado-bin "$VIVADO_BIN")
    if ! "$PY" "$COMMON_BOARD/package_kv260_app.py" "${pkg_args[@]}"; then
        echo "### PACKAGE_FAILED"
        exit 1
    fi

    BITBIN="$WORK/app_pkg/$APP/$APP.bit.bin"
    md5="$(md5sum "$BITBIN" | awk '{print $1}')"
    if [ -n "$EXPECTED_MD5" ] && [ "$md5" != "$EXPECTED_MD5" ]; then
        echo "### MD5_MISMATCH app_pkg: $md5 != $EXPECTED_MD5"
        exit 1
    fi
    echo "### GEN_OK (work=$WORK; app_pkg=$WORK/app_pkg/$APP; bit.bin md5=$md5)"
    exit 0
fi

# =============================================================================
# Phase deploy: stage host tooling on the board + load the app (do_load()).
# =============================================================================
if [ "$PHASE" = "deploy" ]; then
    need_board_ip
    need_gen_artifacts

    files=(
        "$TOOLS/fifo_mm_s.py" "$TOOLS/wp_records.py" "$TOOLS/checks.py"
        "$TOOLS/read_wp_stream.py" "$TOOLS/wp_load_indirect.py"
        "$COMMON_BOARD/kv260_plclk.sh"
        "$HERE/wp_board.py" "$HERE/prep_load.sh" "$HERE/prep_verify.sh"
        "$HERE/run_a.sh" "$HERE/run_b.sh" "$HERE/restore.sh"
        "$WORK/wp_table.txt" "$WORK/wp_real.txt" "$WORK/expected_full.txt" "$WORK/prog.hex"
    )
    for f in "${files[@]}"; do
        [ -f "$f" ] || { echo "### ERROR: tooling file missing: $f"; exit 1; }
    done

    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] ssh $JUMP \"rm -rf /tmp/wp_board_run && mkdir -p /tmp/wp_board_run\""
        echo "[dry-run] scp -q <${#files[@]} files> $JUMP:/tmp/wp_board_run/"
        echo "[dry-run] ssh $JUMP \"ssh $USER_@$BOARD 'sudo -S rm -rf /tmp/wp_board_run' && scp -q -r /tmp/wp_board_run $USER_@$BOARD:/tmp/\""
    else
        # C6 finding (carried over): /tmp on the jump host is NOT ephemeral --
        # a stale staging dir there is exactly trap #1 (examples/kv260/README.md).
        ssh "$JUMP" "rm -rf /tmp/wp_board_run && mkdir -p /tmp/wp_board_run"
        scp -q "${files[@]}" "${JUMP}:/tmp/wp_board_run/"
        # sudo-rm: the run scripts execute as root and leave a root-owned
        # /tmp/wp_board_run/__pycache__ behind -- a plain ubuntu-rm can't
        # remove it on the next deploy (lab finding, 2026-08-13).
        ssh "$JUMP" "ssh ${USER_}@${BOARD} 'echo ${SUDO_PASS} | sudo -S rm -rf /tmp/wp_board_run' && scp -q -r /tmp/wp_board_run ${USER_}@${BOARD}:/tmp/"
    fi

    do_load deploy
    [ "$DRY_RUN" = "1" ] && exit 0
    echo "### DEPLOY_OK (tooling staged in /tmp/wp_board_run on the board, app loaded+verified)"
    exit 0
fi

# =============================================================================
# Phases runa/runb: reload (do_load()) + the matching board run script.
# =============================================================================
if [ "$PHASE" = "runa" ] || [ "$PHASE" = "runb" ]; then
    need_board_ip
    need_gen_artifacts
    do_load "$PHASE"
    if [ "$DRY_RUN" = "1" ]; then
        exit 0
    fi

    if [ "$PHASE" = "runa" ]; then
        tag="runA"
        remote_cmd="sh /tmp/wp_board_run/run_a.sh"
        done_mark="RUN_A_DONE"
        rc_marks=(READER_A0_RC=0 READER_A1_RC=0)
        reader_logs=(runA_reader_fifo0.log runA_reader_fifo1.log)
    else
        tag="runB"
        remote_cmd="sh /tmp/wp_board_run/run_b.sh ${RUNB_DRAIN_SEC} ${RUNB_MAX_RECORDS}"
        done_mark="RUN_B_DONE"
        rc_marks=(READER_B0_RC=0 READER_B1_RC=0 REST_B0_RC=0 REST_B1_RC=0)
        reader_logs=(runB_flush_fifo0.log runB_flush_fifo1.log
                     runB_reader_fifo0.log runB_reader_fifo1.log
                     runB_rest_fifo0.log runB_rest_fifo1.log)
    fi

    run_log="$WORK/board_${tag}.log"
    rc=0
    ssh "$JUMP" "ssh ${USER_}@${BOARD} 'echo ${SUDO_PASS} | sudo -S ${remote_cmd}'" \
        2>&1 | tee "$run_log" || rc=${PIPESTATUS[0]}
    grep -q "$done_mark" "$run_log" || { echo "### RUN_FAILED (see $run_log)"; exit 1; }
    for mk in "${rc_marks[@]}"; do
        grep -qF "$mk" "$run_log" || { echo "### READER_RC_FAIL ($mk missing/nonzero, see $run_log)"; exit 1; }
    done

    # Fetch the reader logs (board -> jump -> workstation; they are created
    # on the board and --raw makes them large, so only pull them once done).
    remote_list=""
    for f in "${reader_logs[@]}"; do remote_list="$remote_list ${USER_}@${BOARD}:/tmp/wp_board_run/$f"; done
    ssh "$JUMP" "scp -q $remote_list /tmp/wp_board_run/"
    jump_list=()
    for f in "${reader_logs[@]}"; do jump_list+=("${JUMP}:/tmp/wp_board_run/$f"); done
    scp -q "${jump_list[@]}" "$WORK/"

    echo "### ${tag} DONE: board log=$run_log, reader logs in $WORK"
    exit 0
fi

# =============================================================================
# Phases checksa/checksb: host checks on the fetched logs (no board access).
# =============================================================================
if [ "$PHASE" = "checksa" ] || [ "$PHASE" = "checksb" ]; then
    mode="runa"
    [ "$PHASE" = "checksb" ] && mode="runb"
    if ! "$PY" "$HERE/wp_check.py" "$mode" --work "$WORK"; then
        echo "### CHECKS_FAIL ($mode)"
        exit 1
    fi
    echo "### CHECKS_OK ($mode)"
    exit 0
fi

# =============================================================================
# Phase restore: previous app + dashboard back, board health report.
# =============================================================================
if [ "$PHASE" = "restore" ]; then
    need_board_ip
    prev="none"
    [ -f "$WORK/prev_app.txt" ] && prev="$(cat "$WORK/prev_app.txt")"
    log="$WORK/restore.log"
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] ssh $JUMP \"ssh $USER_@$BOARD 'sudo -S sh /tmp/wp_board_run/restore.sh $prev $APP'\""
        echo "### DRY_RUN_OK (restore): no board contact made"
        exit 0
    fi
    rc=0
    ssh "$JUMP" "ssh ${USER_}@${BOARD} 'echo ${SUDO_PASS} | sudo -S sh /tmp/wp_board_run/restore.sh ${prev} ${APP}'" \
        2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
    ssh "$JUMP" "ssh ${USER_}@${BOARD} 'uptime -p; echo BOARD_SSH_OK'" 2>&1 | tee -a "$log" || true
    echo "### RESTORE DONE (prev=$prev, log=$log, restore.sh-rc=$rc)"
    exit 0
fi
