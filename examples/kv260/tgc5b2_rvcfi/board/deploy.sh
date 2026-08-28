#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# deploy.sh -- put the RV/CFI demo on a KV260 and take it off again.
#
#   deploy.sh --board <ip> [--user ubuntu] [--jump <host>] [--sudo-pass <pw>]
#             [--app <name>] [--bit <path>] [--pl-mhz 75] [--dry-run]
#             [--skip-package]   (pkg/ came from the build host -- no bootgen here)
#             [--prebuilt]       (fast path: use the committed fpga/prebuilt app,
#                                 manifest-verified; no Vivado anywhere)
#   deploy.sh --board <ip> --restore
#
# Phases, in the order they must happen:
#
#   package   turn the routed .bit into a loadable app directory (no board)
#   stage     copy rvmon sources, the program images, the watchpoint tables
#             and the site maps to /tmp/rvcfi/ on the board
#   build     compile rvmon ON the board (no libraries, no toolchain fuss)
#   load      stop the dashboard service, unload the previous app, set
#             pl_clk0, load this app, verify by reading MAGIC back
#   restore   put back whatever was there before
#
# THREE TRAPS THIS SCRIPT EXISTS TO AVOID
# ---------------------------------------
# 1. `scp -r` onto an EXISTING directory nests instead of replacing, and the
#    board then runs yesterday's bits while every log line says today. The
#    staging directory is removed first, every time.
# 2. Touching the PL while the dashboard service is running wedges the AXI
#    interconnect, and only a power cycle recovers it. The service is stopped
#    before the app is unloaded, not after.
# 3. "App listed" is not evidence that the right bitstream is live. The load
#    is verified by reading the design's own MAGIC (0x52564349 "RVCI")
#    through /dev/mem -- if that does not match, nothing else matters.
#
# pl_clk0 comes back at 100 MHz after a power cycle, and both the timing
# closure and the timestamp-to-seconds conversion assume 75. It is set
# explicitly here rather than hoped for.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ex="$(cd "$here/.." && pwd)"
repo="$(cd "$ex/../../.." && pwd)"

BOARD=""
USER_NAME="ubuntu"
JUMP="${KV260_JUMP:-}"
SUDO_PASS="${KV260_SUDO_PASS:-}"
APP="tgc5b2_rvcfi"
BIT="$ex/fpga/proj/tgc5b2_rvcfi.runs/impl_1/tgc5b2_rvcfi_kv260_top.bit"
PL_MHZ=75
DRY=0
RESTORE=0
SKIP_PKG=0
PREBUILT=0
REMOTE=/tmp/rvcfi

while [ $# -gt 0 ]; do
	case "$1" in
		--board)     BOARD="$2"; shift 2 ;;
		--user)      USER_NAME="$2"; shift 2 ;;
		--jump)      JUMP="$2"; shift 2 ;;
		--sudo-pass) SUDO_PASS="$2"; shift 2 ;;
		--app)       APP="$2"; shift 2 ;;
		--bit)       BIT="$2"; shift 2 ;;
		--pl-mhz)    PL_MHZ="$2"; shift 2 ;;
		--dry-run)      DRY=1; shift ;;
		--skip-package) SKIP_PKG=1; shift ;;
		--prebuilt)     PREBUILT=1; SKIP_PKG=1; shift ;;
		--restore)      RESTORE=1; shift ;;
		-h|--help)   sed -n '3,35p' "$0"; exit 0 ;;
		*) echo "deploy.sh: unknown option $1" >&2; exit 1 ;;
	esac
done

[ -n "$BOARD" ] || { echo "deploy.sh: --board is required" >&2; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$JUMP" ]; then SSH_OPTS+=(-J "$JUMP"); fi

# A phase that fails must STOP the deploy: the first real run compiled
# nothing and still went on to load the app. Steps that may legitimately
# fail carry their own `|| true` inside the remote command.
set -e

say() { printf '[deploy] %s\n' "$*"; }

run() {   # run a command on the board
	if [ "$DRY" = 1 ]; then
		printf '[dry-run] ssh %s@%s %s\n' "$USER_NAME" "$BOARD" "$*"
		return 0
	fi
	ssh "${SSH_OPTS[@]}" "$USER_NAME@$BOARD" "$@"
}

sudo_run() {   # ... as root, password on stdin so it never reaches the log
	if [ "$DRY" = 1 ]; then
		printf '[dry-run] ssh %s@%s sudo %s\n' "$USER_NAME" "$BOARD" "$*"
		return 0
	fi
	ssh "${SSH_OPTS[@]}" "$USER_NAME@$BOARD" \
		"printf '%s\n' '$SUDO_PASS' | sudo -S -p '' $*"
}

copy() {
	if [ "$DRY" = 1 ]; then
		printf '[dry-run] scp %s -> %s:%s\n' "$1" "$BOARD" "$2"
		return 0
	fi
	# "$1" only -- "$@" would pass the destination a second time as a LOCAL
	# source, and scp then fails on a path that only exists on the board.
	# (Found on first real run; the dry-run prints never exercised this line.)
	scp "${SSH_OPTS[@]}" -q "$1" "$USER_NAME@$BOARD:$2"
}

# ---------------------------------------------------------------- restore --
if [ "$RESTORE" = 1 ]; then
	say "restoring the board"
	sudo_run "xmutil unloadapp || true"
	sudo_run "systemctl start ctrace-dashboard || true"
	sudo_run "xmutil listapps || true"
	say "RESTORE_DONE"
	exit 0
fi

# ---------------------------------------------------------------- package --
PKG="$ex/fpga/pkg"
if [ "$PREBUILT" = 1 ]; then
	# The fast path: use the manifest-verified app committed under
	# fpga/prebuilt/ (see its README for provenance). Verified BEFORE the
	# copy, so a corrupted checkout fails here and not on the board.
	say "using the prebuilt app from fpga/prebuilt/$APP"
	[ -d "$ex/fpga/prebuilt/$APP" ] || { echo "deploy.sh: no prebuilt app at $ex/fpga/prebuilt/$APP" >&2; exit 2; }
	( cd "$ex/fpga/prebuilt/$APP" && sha256sum -c MANIFEST.sha256 --quiet ) \
		|| { echo "deploy.sh: prebuilt app fails its MANIFEST.sha256" >&2; exit 2; }
	rm -rf "$PKG"; mkdir -p "$PKG"
	cp -r "$ex/fpga/prebuilt/$APP" "$PKG/$APP"
fi
if [ "$SKIP_PKG" = 1 ]; then
	# Packaging needs bootgen (a Vivado tool). When the deploy runs from a
	# jump host that has ssh access to the board but no Vivado -- the auth
	# layout this option exists for -- the package phase runs on the build
	# host first and the pkg/ directory travels with the sources.
	say "using pre-packaged app dir $PKG/$APP (packaged on the build host)"
	[ -d "$PKG/$APP" ] || { echo "deploy.sh: --skip-package, but no app dir at $PKG/$APP" >&2; exit 2; }
else
	say "packaging $BIT"
	[ -f "$BIT" ] || { echo "deploy.sh: no bitstream at $BIT (build it first)" >&2; exit 2; }
	rm -rf "$PKG"; mkdir -p "$PKG"
	PY="${PY:-}"
	if [ -z "$PY" ]; then
		if command -v py >/dev/null 2>&1; then PY=py; else PY=python3; fi
	fi
	if [ "$DRY" = 0 ]; then
		# CLI verified against the script's own --help (the flag is --app, not
		# --name -- checked rather than assumed, section 14.3's lesson applies to
		# more than exit codes).
		"$PY" "$repo/examples/kv260/common/board/package_kv260_app.py" \
			--bit "$BIT" --app "$APP" --out "$PKG"
	else
		say "(dry-run: skipping the packaging step)"
	fi
fi

# ------------------------------------------------------------------ stage --
say "staging to $BOARD:$REMOTE"
# Trap 1: remove first. `scp -r` onto an existing directory NESTS.
run "rm -rf $REMOTE && mkdir -p $REMOTE"
copy "$here/rvmon/rvmon.c" "$REMOTE/"
copy "$here/rvmon/monitors.c" "$REMOTE/"
copy "$here/rvmon/rvmon.h" "$REMOTE/"
copy "$here/rvmon/Makefile" "$REMOTE/"
copy "$here/run_board_verdicts.sh" "$REMOTE/"
copy "$ex/sw/rvcfi_core0.hex" "$REMOTE/"
copy "$ex/sw/rvcfi_core1.hex" "$REMOTE/"
copy "$ex/sw/wp_table_core0_full.txt" "$REMOTE/"
copy "$ex/sw/wp_table_core1_full.txt" "$REMOTE/"
copy "$ex/sw/wp_table_core0_hot.txt" "$REMOTE/"
copy "$ex/sw/wp_table_core1_hot.txt" "$REMOTE/"
copy "$ex/sw/sites_core0.csv" "$REMOTE/"
copy "$ex/sw/sites_core1.csv" "$REMOTE/"
# rvmon includes the shared-memory layout from the source tree; staged it
# sits FLAT next to the sources, where the Makefile's -I. finds it -- that
# single-sourcing is the whole reason the host and the cores agree on the
# offsets. (The first real run staged it under ../rvcfi_sw/src, which no
# include path ever looked at -- the build phase is the check that counts.)
copy "$ex/sw/src/rv_shared.h" "$REMOTE/"
# The pl_clk setter the load phase runs. Without it the `test -x ... ||
# true` guard skips silently and the PL keeps the 100 MHz power-on default
# -- the design closed timing at 75, and the timestamp-to-seconds
# conversion assumes 75. Staged explicitly so the guard has something to
# find.
copy "$repo/examples/kv260/common/board/kv260_plclk.sh" "$REMOTE/../kv260_plclk.sh"
run "chmod +x $REMOTE/../kv260_plclk.sh"

# ------------------------------------------------------------------ build --
say "building rvmon on the board"
# No `| tail` here: the pipe would return tail's status and a failed compile
# would sail on into the load phase (it did, once).
run "cd $REMOTE && make 2>&1"
run "cd $REMOTE && set -o pipefail && ./rvmon selftest 2>&1 | tail -2"

# ------------------------------------------------------------------- load --
say "loading the app (dashboard stopped first -- trap 2)"
sudo_run "systemctl stop ctrace-dashboard || true"
sudo_run "xmutil unloadapp || true"
# Clock BEFORE the app, and MHZ as an environment variable -- both are the
# plclk script's own contract: a frequency jump under a loaded design is
# forbidden, and a positional argument makes it show-only (which is exactly
# how the first silicon run ended up at the 100 MHz power-on default).
# No `|| true`: the script is staged above, and a clock left at 100 MHz
# breaks both the 75 MHz timing closure and the timestamp conversion.
sudo_run "MHZ=$PL_MHZ bash $REMOTE/../kv260_plclk.sh"
if [ "$DRY" = 0 ]; then
	bash "$repo/examples/kv260/common/board/deploy_kv260_app.sh" \
		--app-dir "$PKG/$APP" --board "$BOARD" --user "$USER_NAME" \
		${JUMP:+--jump "$JUMP"} ${SUDO_PASS:+--sudo-pass "$SUDO_PASS"}
fi

# ----------------------------------------------------------------- verify --
# Trap 3: the design's own MAGIC, read through /dev/mem. Anything else is a
# statement about the tooling, not about what is in the PL.
say "verifying by reading MAGIC"
sudo_run "$REMOTE/rvmon status"

say "DEPLOY_OK -- next: rvmon load --mode <0..4> ... (see TUTORIAL §8)"
