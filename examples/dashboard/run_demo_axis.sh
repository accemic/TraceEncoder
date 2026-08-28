#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec > "$HERE/demo_axis_server.log" 2>&1
cd "$HERE" || exit 9
exec py server.py --demo --scenario tgc5b2_axis_wp --port 8151
