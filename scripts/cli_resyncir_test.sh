#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
# Stage-2 gate wrapper: the E-Trace resync-x-implicit-return braid
# (tests/instruction/34_etrace_resync_ir, P10 S-1/S-2 regression guard;
# baseline red 332/336 before the fix family 73fbc06/b72c50b). The scenario
# lives in cli_etrace_test.sh; the stage-2 runner maps a gate name to
# scripts/cli_<gate>_test.sh with no arguments, so this wrapper is the
# registration (P10-Audit finding B-2: the leg was a CI orphan).
exec bash "$(dirname "$0")/cli_etrace_test.sh" resyncir
