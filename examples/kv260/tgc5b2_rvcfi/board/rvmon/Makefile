# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# rvmon builds with nothing but a C compiler. On the board:  make
# On a workstation (for `rvmon selftest`, which needs no hardware):  make
CC      ?= cc
CFLAGS  ?= -O2 -std=c99 -Wall -Wextra -Wno-unused-parameter
LDFLAGS ?=
# rv_shared.h lives in the source tree (../../sw/src); deploy.sh stages it
# FLAT next to the sources on the board, where -I. picks it up. Kept out of
# CFLAGS so a caller overriding CFLAGS cannot lose the include path.
INCS    = -I. -I../../sw/src

rvmon: rvmon.c monitors.c rvmon.h
	$(CC) $(CFLAGS) $(INCS) -o $@ rvmon.c monitors.c $(LDFLAGS)

.PHONY: selftest clean
selftest: rvmon
	./rvmon selftest

clean:
	rm -f rvmon
