#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Run verible-verilog-lint across the SystemVerilog sources of this
# repo. Rules live in `.rules.verible_lint` at the repo root, with
# per-directory overrides (e.g. `rtl/pkg/.rules.verible_lint` for
# generated/imported packages). The rule set is **opt-in**: --ruleset=none
# disables all built-in rules, and only the `+rule` lines in the
# config files take effect.
#
# Excluded paths:
#   - tests/legacy/        : pre-import legacy testbenches, pending refactor
#   - rtl/external/        : vendored deps from sibling modules; linted in
#                            their upstream repo, kept as-is here
#   - bld/, .git/          : build artefacts / VCS metadata
#
# Usage: scripts/lint.sh [extra verible-verilog-lint args]

set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

EXCLUDE_DIRS=(
    "./tests/legacy"
    "./rtl/external"
    "./bld"
    "./.git"
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
else
    echo "[lint] FAIL — verible-verilog-lint exited $rc"
fi
exit "$rc"
