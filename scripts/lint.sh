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
#   - examples/*/cpu/       : vendored third-party CPU cores (e.g. the MINRES
#                            TGC5B example core) keep their upstream style
#
# Everything else is linted, including the per-module testbenches under
# `rtl/<subsystem>/test/` and `tests/lib/test/`, and the vendored sources
# under `rtl/external/`.
#
# Usage: scripts/lint.sh [extra verible-verilog-lint args]

set -euo pipefail

repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"

EXCLUDE_DIRS=(
    "./bld"
    "./.git"
    "./examples/*/cpu"
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
