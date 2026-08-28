#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Syntax-check the /dev/mem half of rvmon.c on a NON-Linux workstation.
#
# `run`, `drain`, `load` and `status` are compiled out on a workstation
# (RVMON_HAVE_DEVMEM=0), which means a typo in them is invisible until the
# code reaches the board -- and the board is the most expensive place to
# discover a missing semicolon. This forces the guarded half through the
# compiler with a stub for the two Linux-only headers.
#
# It checks SYNTAX, not behaviour. The behaviour of that half is only ever
# established by running it on the board.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
stub="$(mktemp -d)"
mkdir -p "$stub/sys"
cat > "$stub/sys/mman.h" <<'H'
#ifndef STUB_MMAN_H
#define STUB_MMAN_H
#include <stddef.h>
#define PROT_READ 1
#define PROT_WRITE 2
#define MAP_SHARED 1
#define MAP_FAILED ((void *)-1)
void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off);
#endif
H
"${CC:-gcc}" -fsyntax-only -std=c99 -Wall -Wextra -Wno-unused-parameter \
	-D__linux__ -DO_SYNC=0 -I"$stub" -I"$here/../../sw/src" -c "$here/rvmon.c"
rm -rf "$stub"
echo "SYNTAXCHECK_OK (board-only code compiles)"
