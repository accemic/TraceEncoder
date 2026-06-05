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

set -euo pipefail

OUT="${1:-bld/coverage}"
BLD="$(dirname "$OUT")"
mkdir -p "$OUT"

shopt -s nullglob
dats=( "$BLD"/*.vsim/coverage_*.dat )
if (( ${#dats[@]} == 0 )); then
    echo "coverage: no coverage_*.dat under $BLD/*.vsim/" >&2
    echo "coverage: run 'make coverage' (it sets ABC_COV=--coverage for the suite)" >&2
    exit 1
fi

command -v verilator_coverage >/dev/null 2>&1 || {
    echo "coverage: verilator_coverage not found on PATH" >&2; exit 1; }

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
command -v lcov >/dev/null 2>&1 || {
    echo "coverage: lcov not found on PATH (needed to summarize the merged data)" >&2; exit 1; }

summary=$(lcov --summary "$info" --rc lcov_branch_coverage=1 2>/dev/null)
# Each rate line reads e.g.:  lines......: 57.1% (3029 of 5305 lines)
parse() { sed -n "s/.*$1\.*: \([0-9.]*\)% (\([0-9]*\) of \([0-9]*\).*/\1 \2 \3/p" <<<"$summary"; }
read -r pct   hit   found   <<<"$(parse lines)"
read -r brpct brhit brfound <<<"$(parse branches)"
: "${pct:=0.0}"

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

html=""
if command -v genhtml >/dev/null 2>&1; then
    if genhtml --branch-coverage -o "$OUT/html" "$info" >/dev/null 2>&1; then
        html="$OUT/html/index.html"
    fi
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
printf '  badge json    : %s\n' "$OUT/coverage-badge.json"
echo "============================================================"
echo
echo "README badge (static markdown):"
echo "  [![coverage](https://img.shields.io/badge/coverage-${pct}%25-${color})](#)"
