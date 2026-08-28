#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Merge the per-test Verilator line-coverage data into one rate.
#
# `abc --coverage -sim <task>.abc` leaves a `coverage_<top>.dat` file in each
# test's work dir (bld/<task>.vsim/). This script merges every such file with
# `verilator_coverage --write-info`, which groups coverage points by source
# file + line and sums their hit counts — so a line exercised by several
# testbenches is counted ONCE, giving a true union line-coverage rate across
# the whole suite (not a per-test average, no double-counting).
#
# Outputs into <out-dir> (default bld/coverage):
#   merged.info          lcov-format merged coverage (genhtml / Coverage Gutters)
#   html/index.html      browsable HTML report (if genhtml is on PATH)
#   coverage-badge.json  shields.io endpoint JSON for a README badge
#
# Usage: scripts/coverage_report.sh [out-dir]
#
# Exit codes: 0 = a rate was computed, 78 = it could NOT be computed (missing
# tool, missing data, unparsable summary -- CT_E_TOOL, not a coverage verdict).
#
# Until 2026-08-13 every one of those ends returned 1, the code `make coverage`
# and every summary read as "coverage failed". Measured on this host, where
# verilator_coverage is installed and lcov is not:
#
#     $ scripts/coverage_report.sh
#     coverage: lcov not found on PATH (needed to summarize the merged data)
#     rc=1
#
# The script diagnosed correctly and then filed the diagnosis under the wrong
# heading. 78 is red as well -- it just says "build/install the tool" instead
# of "the coverage went bad".

set -euo pipefail

OUT="${1:-bld/coverage}"
BLD="$(dirname "$OUT")"
mkdir -p "$OUT"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/ct_env.sh"

# Probe on FUNCTION, not presence: these three are dropped onto PATH by hand
# or come from a package that can be half-installed, and a present-but-dead
# binary fails later and less legibly. The verdict is the STATUS of --version,
# not its wording -- a loader error names the tool it failed to load, so its
# text is indistinguishable from a banner (measured at ct_need_verible).
need_tool() { # $1 = command, $2 = hint
	local out vrc=0
	command -v "$1" >/dev/null 2>&1 || ct_die "$1 not found on PATH -- $2"
	out="$("$1" --version 2>&1)" || vrc=$?
	[ "$vrc" -eq 0 ] || ct_die "$1 at $(command -v "$1") does not run (--version exited $vrc). First line: $(printf '%s' "$out" | sed -n '1{s/[[:cntrl:]]//g;p;}')"
}

shopt -s nullglob
dats=( "$BLD"/*.vsim/coverage_*.dat )
if (( ${#dats[@]} == 0 )); then
	echo "coverage: no coverage_*.dat under $BLD/*.vsim/" >&2
	echo "coverage: run 'make coverage' (it sets ABC_COV=--coverage for the suite)." >&2
	echo "coverage: an UNINSTRUMENTED build also lands here -- 'abc -sim' compiles" >&2
	echo "coverage: with -DVM_COVERAGE=0 and writes no .dat; only 'abc --coverage -sim' does." >&2
	exit "$CT_E_TOOL"
fi

need_tool verilator_coverage "it ships with Verilator; put its bin/ on PATH"

# Merge in two explicit steps: first sum every test's points into one
# canonical Verilator .dat (verilator_coverage groups points by source
# file/line/hierarchy and adds the counts), then render that to lcov. Passing
# all the .dat files straight to --write-info yields the same totals, but the
# merged.dat is a useful re-mergeable / re-annotatable artifact.
merged="$OUT/merged.dat"
info="$OUT/merged.info"
verilator_coverage --write      "$merged" "${dats[@]}" >/dev/null
verilator_coverage --write-info "$info"   "$merged"    >/dev/null

# Reduce the merged data to a single rate with lcov's own summarizer — the
# same computation genhtml renders into the HTML report — rather than
# re-counting records by hand. (verilator_coverage itself emits no
# percentage; it only writes data, so a separate summary step is required.)
# Branch coverage must be enabled explicitly; lcov ignores it by default.
need_tool lcov "needed to summarize the merged data (apt install lcov / msys2 pacman -S lcov)"

# stderr is NOT discarded here: it used to be (`2>/dev/null`), which meant a
# summarizer that produced nothing left no trace of why.
summary=$(lcov --summary "$info" --rc lcov_branch_coverage=1)
# Each rate line reads e.g.:  lines......: 57.1% (3029 of 5305 lines)
parse() { sed -n "s/.*$1\.*: \([0-9.]*\)% (\([0-9]*\) of \([0-9]*\).*/\1 \2 \3/p" <<<"$summary"; }
read -r pct   hit   found   <<<"$(parse lines)"
read -r brpct brhit brfound <<<"$(parse branches)"

# The line that used to stand here was `: "${pct:=0.0}"`, and it is the most
# dangerous line this script ever had: when the summary could not be parsed --
# an lcov whose wording changed, a truncated merge, a locale that prints
# "57,1%" -- it substituted a MEASUREMENT. The report then said "line coverage
# : 0.0%", the badge turned red, and nothing anywhere said that nobody had
# measured anything. A default is exactly the `|| true` this class is about,
# one layer in: it does not lose a tool, it invents a number. Fail instead,
# and show the text that could not be read.
case "${pct:-}" in
	'' ) ct_die "lcov produced no parsable line rate. Its summary was:
$(printf '%s' "$summary" | sed 's/^/    /')" ;;
	*[!0-9.]* ) ct_die "lcov line rate '$pct' is not a number -- summary:
$(printf '%s' "$summary" | sed 's/^/    /')" ;;
esac

# Badge colour by the usual coverage thresholds.
pctint=${pct%.*}
if   (( pctint >= 90 )); then color=brightgreen
elif (( pctint >= 75 )); then color=green
elif (( pctint >= 60 )); then color=yellowgreen
elif (( pctint >= 45 )); then color=yellow
elif (( pctint >= 30 )); then color=orange
else                          color=red
fi

printf '{"schemaVersion":1,"label":"coverage","message":"%s%%","color":"%s"}\n' \
	"$pct" "$color" > "$OUT/coverage-badge.json"

# genhtml is OPTIONAL -- the rate is the deliverable, the browsable report is
# a convenience. But "optional" is not "silent": both failure paths used to
# leave `html` empty, the summary simply omitted its line, and a reader who
# expected an HTML report had no way to tell that one was never written.
html=""; html_note=""
if command -v genhtml >/dev/null 2>&1; then
	if genhtml --branch-coverage -o "$OUT/html" "$info" >"$OUT/genhtml.log" 2>&1; then
		html="$OUT/html/index.html"
	else
		html_note="genhtml failed (rc above 0) -- see $OUT/genhtml.log; the rate below is unaffected"
	fi
else
	html_note="genhtml not on PATH -- no HTML report written; the rate below is unaffected"
fi

ntests=$(printf '%s\n' "${dats[@]}" | sed 's#/coverage_[^/]*\.dat$##' | sort -u | wc -l)

echo
echo "===================== coverage summary ====================="
printf '  line coverage : %s%%   (%s / %s lines)\n' "$pct" "$hit" "$found"
if [ -n "$brpct" ]; then
	printf '  branch cov.   : %s%%   (%s / %s branches)\n' "$brpct" "$brhit" "$brfound"
else
	printf '  branch cov.   : n/a\n'
fi
printf '  merged from   : %d test(s), %d data file(s)\n' "$ntests" "${#dats[@]}"
printf '  merged lcov   : %s\n' "$info"
[ -n "$html" ] && printf '  html report   : %s\n' "$html"
[ -n "$html_note" ] && printf '  html report   : none — %s\n' "$html_note"
printf '  badge json    : %s\n' "$OUT/coverage-badge.json"
echo "============================================================"
echo
echo "README badge (static markdown):"
echo "  [![coverage](https://img.shields.io/badge/coverage-${pct}%25-${color})](#)"
