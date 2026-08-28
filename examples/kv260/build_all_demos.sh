#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# build_all_demos.sh -- build every KV260 example bitstream, one after another,
# and say plainly which ones came out.
#
#   bash examples/kv260/build_all_demos.sh                 # all of them
#   bash examples/kv260/build_all_demos.sh mbv duo         # a subset
#   bash examples/kv260/build_all_demos.sh --list          # what it knows
#   PACKAGE=1 bash examples/kv260/build_all_demos.sh mbv   # + app/bundle
#
# WHY THIS EXISTS. The nine examples grew at different times and their entry
# points differ (env-var flows, `-tclargs` flows, two-step flows). That is fine
# for one example and unusable for nine, so this wraps them WITHOUT replacing
# them: every line below is exactly the command the example's own README
# documents. If the two ever disagree, the README wins and this file is the bug.
#
# Three hard-won rules are baked in, all measured on 2026-08-18:
#   1. Every run gets its OWN -log/-journal path. Two Vivado batch sessions that
#      share vivado.log/vivado.jou collide, and the second one can end without a
#      log and without a verdict -- indistinguishable from "never started". With
#      separate paths they run happily side by side: this script is serial, but
#      you can start several of it in parallel (one demo each), which is how the
#      2026-08-18 build round was done on a 64 GB / 32-core host (~5.3 GB per run).
#   2. NEVER trust the exit code. Vivado exits 0 over a crashed synthesis, over
#      a Tcl error, and over a locked project directory. This script judges by
#      ARTEFACT: the .bit has to exist and be newer than the run's start.
#   3. Each run gets its own log path, so a failure can still be read afterwards.
#
# One argument is not obvious and is therefore stated here: rocket_linux runs
# with `TCLARGS=0 64`, i.e. EN_ETRACE=0 AND CT_XLEN=64. Its top hardwires
# .CORE_XLEN(64) (rtl/rocket_soc_synth_wrap.sv:398), so since P0-07
# (1415a02524) the 32-bit default tree fails elaboration with "CORE_XLEN=64
# does not match this netlist's trace ingress width of 32 bit" -- measured
# 2026-08-18, bld/demo_builds/rocket_linux.console. The 64-bit branch is also
# the one app_of() has always named (rocket_x64_ctrace_kv260). It needs the
# encoder mirror bld/w1_rv64_decode/ctte_xlen64; build the mirrors first:
#   bash examples/kv260/common/tools/mk_encoder_mirror.sh --dest bld/w1_rv64_decode/ctte_xlen64 --xlen 64
#   bash examples/kv260/common/tools/mk_encoder_mirror.sh --dest bld/m4_rocket_2hart/ctte_slim64 --profile slimfull_gold --xlen 64 --ctx-width 22
#   bash examples/kv260/common/tools/mk_encoder_mirror.sh --dest bld/d3_cva6_2_soc/ctte_slim32 --profile slimfull_gold --xlen 32 --ctx-width 22
#
# Exit: 0 = every requested example produced a bitstream, 1 = at least one did not.
set -u

here="$(cd "$(dirname "$0")/../.." && pwd)"          # repository root
cd "$here"
# Vivado: take $VIVADO, else whatever is on PATH. No install path is
# hardcoded -- point $VIVADO at your own installation if it is not on PATH.
vivado="${VIVADO:-$(command -v vivado || command -v vivado.bat || true)}"
logdir="${LOGDIR:-$here/bld/demo_builds}"
mkdir -p "$logdir"

# name|extra env|tcl script|expected .bit (glob, relative to repo root)
DEMOS="
mbv|MBV_KV260_SYNTH=1|examples/kv260/mbv/fpga/create_project_kv260.tcl|examples/kv260/mbv/fpga/proj*/mbv_kv260.runs/impl_1/mbv_kv260_top.bit
duo|DUO_KV260_SYNTH=1|examples/kv260/duo/fpga/create_project_kv260.tcl|examples/kv260/duo/fpga/proj*/duo_kv260.runs/impl_1/duo_kv260_top.bit
trio|TRIO_KV260_SYNTH=1|examples/kv260/trio/fpga/create_project_kv260.tcl|examples/kv260/trio/fpga/proj*/*.runs/impl_1/*_top.bit
tgc5b2_axis_wp||examples/kv260/tgc5b2_axis_wp/fpga/run_bitstream.tcl|examples/kv260/tgc5b2_axis_wp/fpga/proj*/tgc5b2_axis_wp.runs/impl_1/tgc5b2_kv260_top.bit
cva6_linux||examples/kv260/cva6_linux/fpga/run_cva6_linux_bitstream.tcl|examples/kv260/cva6_linux/fpga/proj_linux/cva6_linux_kv260.runs/impl_1/cva6_linux_kv260_top.bit
cva6_linux64|TCLARGS=64|examples/kv260/cva6_linux64/fpga/run_cva6_linux64_bitstream.tcl|examples/kv260/cva6_linux64/fpga/proj*/*.runs/impl_1/*_top.bit
cva6_2|TCLARGS=cv32a6_ima_sv32_fpga|examples/kv260/cva6_2/fpga/run_cva6_2_bitstream.tcl|examples/kv260/cva6_2/fpga/proj*/*.runs/impl_1/*_top.bit
rocket_linux|TCLARGS=0 64|examples/kv260/rocket_linux/fpga/run_rocket_bitstream.tcl|examples/kv260/rocket_linux/fpga/proj*/*.runs/impl_1/*_top.bit
rocket2||examples/kv260/rocket2/fpga/run_rocket2_bitstream.tcl|examples/kv260/rocket2/fpga/proj*/*.runs/impl_1/*_top.bit
"

# app name per demo, for --package (matches the published bundle names)
app_of() {
	case "$1" in
		mbv)            echo mbv_ctrace_kv260 ;;
		duo)            echo duo_ctrace_kv260 ;;
		trio)           echo trio_ctrace_kv260 ;;
		tgc5b2_axis_wp) echo tgc5b2_axis_wp_c0b ;;
		cva6_linux)     echo cva6_linux_ctrace_kv260 ;;
		cva6_linux64)   echo cva6_linux64_x64ctx_ctrace_kv260 ;;
		cva6_2)         echo cva6_2_rv32_ctrace_kv260 ;;
		rocket_linux)   echo rocket_x64_ctrace_kv260 ;;
		rocket2)        echo rocket2_ctrace_kv260 ;;
		*)              echo "" ;;
	esac
}

list_demos() { echo "$DEMOS" | sed '/^$/d' | cut -d'|' -f1; }

if [ "${1:-}" = "--list" ]; then list_demos; exit 0; fi

want="$*"
[ -z "$want" ] && want="$(list_demos | tr '\n' ' ')"

overall=0
summary=""
for name in $want; do
	line="$(echo "$DEMOS" | grep "^$name|" || true)"
	if [ -z "$line" ]; then
		echo "### UNKNOWN demo: $name (try --list)" >&2
		overall=1; summary="$summary
  UNKNOWN  $name"
		continue
	fi
	env_extra="$(echo "$line" | cut -d'|' -f2)"
	script="$(echo "$line" | cut -d'|' -f3)"
	bitglob="$(echo "$line" | cut -d'|' -f4)"
	log="$logdir/${name}.log"
	jou="$logdir/${name}.jou"
	winlog="$(cygpath -m "$log" 2>/dev/null || echo "$log")"
	winjou="$(cygpath -m "$jou" 2>/dev/null || echo "$jou")"

	# Rule 3 of the header: the start marker is what makes rule 2 checkable.
	marker="$logdir/${name}.start"
	: > "$marker"

	# tgc5b2_axis_wp is the one example whose bitstream script does NOT
	# create its project: run_bitstream.tcl opens an existing one and exits
	# with "### ERROR: project missing" otherwise. In a fresh clone that made
	# this queue fail on a demo the tutorial lists as buildable (found by the
	# tutorial walkthrough, 2026-08-19). Create it ONLY when it is absent --
	# create_project.tcl on an existing project would throw away whatever
	# state it holds, and that is not this script's decision to make.
	# tgc5b2_axis_wp is the one example whose bitstream script does NOT
	# create its project: run_bitstream.tcl opens an existing one and exits
	# with "### ERROR: project missing" otherwise. In a fresh clone that made
	# this queue fail on a demo the tutorial lists as buildable (found by the
	# tutorial walkthrough, 2026-08-19). Create it ONLY when it is absent --
	# create_project.tcl on an existing project would throw away whatever
	# state it holds, and that is not this queue's decision to make.
	if [ "$name" = "tgc5b2_axis_wp" ]; then
		if ! ls -d examples/kv260/tgc5b2_axis_wp/fpga/proj*/ >/dev/null 2>&1; then
			echo "### [$name] no project yet -> create_project.tcl first"
			"$vivado" -mode batch -notrace -log "$logdir/${name}.create.log" -journal "$logdir/${name}.create.jou" -source examples/kv260/tgc5b2_axis_wp/fpga/create_project.tcl >/dev/null 2>&1 || true
			if ! ls -d examples/kv260/tgc5b2_axis_wp/fpga/proj*/ >/dev/null 2>&1; then
				echo "### [$name] FAIL -- create_project.tcl produced no project"
				echo "###        see $logdir/${name}.create.log"
				overall=1
				summary="$summary
  FAIL     $name (project creation)"
				continue
			fi
		fi
	fi

	echo "### [$name] building -> $log"
	tclargs=""
	case "$env_extra" in
		TCLARGS=*) tclargs="-tclargs ${env_extra#TCLARGS=}"; env_extra="" ;;
	esac
	# shellcheck disable=SC2086
	( export MSYS2_ARG_CONV_EXCL='*'
	  [ -n "$env_extra" ] && export "${env_extra?}"
	  # -tclargs MUST be last: Vivado hands EVERYTHING after it to the
	  # script. Measured 2026-08-18 -- with -log/-journal behind -tclargs,
	  # cva6_2 read "-log" as its ctte-root argument and died on
	  # "-log/rtl/pkg/ct_pkg.sv missing", rocket_linux with
	  # "second tclarg must be 32 or 64 (was '-log')".
	  "$vivado" -mode batch -notrace -log "$winlog" -journal "$winjou" \
	            -source "$script" $tclargs ) >"$logdir/${name}.console" 2>&1
	rc=$?

	# Rule 2: judge by artefact, not by rc.
	bit="$(ls -1t $bitglob 2>/dev/null | head -1)"
	if [ -n "$bit" ] && [ "$bit" -nt "$marker" ]; then
		size="$(stat -c '%s' "$bit")"
		echo "### [$name] BITSTREAM OK ($size bytes) $bit   (vivado rc=$rc)"
		summary="$summary
  OK       $name  $size bytes  $bit"
		if [ "${PACKAGE:-0}" = "1" ]; then
			app="$(app_of "$name")"
			if [ -n "$app" ]; then
				py examples/kv260/common/board/package_kv260_app.py \
				   --bit "$bit" --app "$app" --bundle \
				   --version "${BUNDLE_VERSION:-dev}" >>"$logdir/${name}.console" 2>&1 \
				  && echo "### [$name] packaged as $app" \
				  || { echo "### [$name] PACKAGING FAILED (see $logdir/${name}.console)"; overall=1; }
			fi
		fi
	else
		echo "### [$name] NO BITSTREAM (vivado rc=$rc) -- read $log"
		# The most useful three lines are almost always the Tcl error itself.
		grep -m3 -E "^ERROR|error deleting|EXCEPTION_ACCESS_VIOLATION" "$log" 2>/dev/null | sed 's/^/      /'
		summary="$summary
  FAILED   $name  (rc=$rc, log $log)"
		overall=1
	fi
	rm -f "$marker"
done

echo
echo "=== build_all_demos summary ==="
echo "$summary"
[ $overall -eq 0 ] && echo "RESULT: all requested bitstreams built" || echo "RESULT: at least one example did not build"
exit $overall
