#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Run verible-verilog-lint across the SystemVerilog sources of this
# repo. Rules live in `.rules.verible_lint` at the repo root, with
# per-directory overrides (e.g. `rtl/pkg/.rules.verible_lint` for
# generated/imported packages). The rule set is **opt-in**: --ruleset=none
# disables all built-in rules, and only the `+rule` lines in the
# config files take effect.
#
# Excluded paths:
#   - bld/, .git/          : build artefacts / VCS metadata
#   - formal/*/build/      : generated formal build output
#   - examples/kv260/*/fpga/{ip,proj*}/ : Vivado-generated IP/project trees
#   - examples/*/cpu/, examples/kv260/third_party/ : vendored third-party RTL
#
# Everything else is linted, including the per-module testbenches under
# `rtl/<subsystem>/test/` and `tests/lib/test/`, and the vendored sources
# under `rtl/external/`.
#
# Usage: scripts/lint.sh [extra verible-verilog-lint args]
#
# Exit codes: 0 = clean, 1 = lint violations, 78 = the linter itself could not
# be established or died on a signal (CT_E_TOOL -- NOT a lint verdict).

set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

# The linter has to be proven to RUN before its exit code may be read as a
# verdict. Until 2026-08-13 it was not: on a host without verible this script
# printed "[lint] FAIL -- verible-verilog-lint exited 127" and returned 127, a
# lint verdict over a lint that never happened. The distinction cannot be made
# afterwards either -- verible answers 1 for "violations found" AND for its own
# errors, so a missing tool and dirty sources are only separable up front.
. "$repo_root/scripts/ct_env.sh"
ct_need_verible

EXCLUDE_DIRS=(
	"./bld"
	"./.git"
	# Generated formal build output (sv2v result + mutants). It only exists
	# after a formal run, so linting it would make the result depend on
	# whether someone happened to run the gates.
	"./formal/*/build"
	# Vendored third-party CPU cores under examples/ (e.g. the MINRES TGC5B
	# example core) keep their upstream style -- linting them would report
	# findings nobody here may fix. Same for the pinned reference-core
	# material under examples/kv260/third_party/ (upstream CVA6/Rocket files
	# and the delta patches against them).
	"./examples/*/cpu"
	"./examples/kv260/third_party"
	# Vivado-generated IP output and project trees of the KV260 example flows
	# (gitignored, see .gitignore). They exist only on a machine that ran the
	# flow, so linting them would make the verdict depend on local state --
	# and they are vendor-generated code in any case.
	"./examples/kv260/*/fpga/ip"
	"./examples/kv260/*/fpga/proj*"
)

prune_expr=()
for d in "${EXCLUDE_DIRS[@]}"; do
	prune_expr+=( -path "$d" -o )
done
unset 'prune_expr[${#prune_expr[@]}-1]' 2>/dev/null || true   # drop trailing -o

mapfile -t srcs < <(
	find . \
		\( "${prune_expr[@]}" \) -prune -o \
		-type f -name '*.sv' -print | sort
)

n=${#srcs[@]}
echo "[lint] linting $n SystemVerilog files with verible-verilog-lint"
if [ "$n" -eq 0 ]; then
	echo "[lint] nothing to lint"
	exit 0
fi

# Run verible. Don't `exec` so we get a trailing pass/fail summary.
# --check_syntax=false : Verible's parser is stricter than xsim's; we
#                        rely on xsim/abc for syntax validation
# --ruleset=none       : disable all built-in rules; opt-in via configs
# --rules_config_search=true : walk up from each source file looking
#                        for .rules.verible_lint
set +e
verible-verilog-lint \
	--check_syntax=false \
	--ruleset=none \
	--rules_config_search=true \
	"$@" \
	"${srcs[@]}"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
	echo "[lint] PASS — $n files clean against $(grep -c '^+' "$repo_root/.rules.verible_lint" 2>/dev/null || echo "?") enabled rule(s)"
	exit 0
fi

# 126/127 (not executable / not found) and 128+n (killed by a signal) are the
# shell's and the kernel's codes, not verible's -- verible reports lint
# violations as 1. A run that ended that way produced no verdict, so it must
# not be printed as one; ct_need_verible above already excludes the static
# cases, this catches a linter that dies mid-run.
if [ "$rc" -ge 126 ]; then
	echo "[lint] TOOL — verible-verilog-lint did not complete (exit $rc); no lint verdict" >&2
	exit "$CT_E_TOOL"
fi

echo "[lint] FAIL — verible-verilog-lint exited $rc"
exit "$rc"
