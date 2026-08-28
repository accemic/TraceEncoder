#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Deploy a packaged KV260 app directory (package_kv260_app.py output) onto a
# board and load it -- the Bash port of the predecessor repository's package_and_deploy.ps1
# deploy half (R1 of the consolidation task state). Transport is
# workstation -> jump host -> board, because the boards only take ssh from
# the jump host.
#
#   deploy_kv260_app.sh --app-dir <dir> [--board <ip>] [--jump <host>]
#                       [--user ubuntu] [--sudo-pass <pw>]
#
# The three documented deploy traps (examples/kv260/README.md) are honoured
# here, not in tribal memory:
#   1. never `scp -r` into an EXISTING target dir (it nests and the board keeps
#      the old file) -> the staging dir is removed first, on both hops;
#   2. never touch the PL aperture unless OUR app is in the active slot
#      (an access with no slave behind it wedges the AXI interconnect);
#   3. `xmutil listapps` slot column, never fpga_manager state, decides that.
# And the one rule from 2026-08-01: a deploy is verified ONLY by the bit.bin
# hash read back ON THE TARGET -- "app listed" is not evidence.
set -euo pipefail

APPDIR="" BOARD="${KV260_BOARD:-}" JUMP="${KV260_JUMP:-}" USER_="ubuntu" SUDO_PASS="${KV260_SUDO_PASS:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --app-dir) APPDIR="$2"; shift 2;;
        --board) BOARD="$2"; shift 2;;
        --jump) JUMP="$2"; shift 2;;
        --user) USER_="$2"; shift 2;;
        --sudo-pass) SUDO_PASS="$2"; shift 2;;
        *) echo "deploy_kv260_app: unknown argument $1" >&2; exit 2;;
    esac
done
[ -n "$APPDIR" ] && [ -d "$APPDIR" ] || { echo "deploy_kv260_app: --app-dir <dir> required" >&2; exit 2; }
APP="$(basename "$APPDIR")"
BITBIN="$APPDIR/$APP.bit.bin"
[ -f "$BITBIN" ] && [ -f "$APPDIR/$APP.dtso" ] && [ -f "$APPDIR/shell.json" ] || {
    echo "deploy_kv260_app: $APPDIR lacks $APP.bit.bin / $APP.dtso / shell.json" >&2; exit 2; }

local_md5="$(md5sum "$BITBIN" | awk '{print $1}')"
echo "### DEPLOY $APP ($local_md5) via ${JUMP:-<direct>} -> $BOARD"

# An empty --jump means THIS machine already has ssh access to the board
# (it is its own jump host): hop 1 becomes a local copy and hop 2 runs in a
# local shell. First hit in the wild: running the deploy ON the jump host
# because the workstation's key is not in the board's authorized_keys.
jump_sh() {
    if [ -n "$JUMP" ]; then ssh "$JUMP" "$1"; else bash -c "$1"; fi
}

# hop 1: workstation -> jump host (fresh staging dir, trap 1)
jump_sh "rm -rf /tmp/$APP"
if [ -n "$JUMP" ]; then
    scp -q -r "$APPDIR" "$JUMP:/tmp/$APP"
else
    cp -r "$APPDIR" "/tmp/$APP"
fi

# hop 2 + load, all in one board session. Dashboard service stopped FIRST
# (trap 4, below); core stop only if OUR app is active (trap 2/3); then dtbo
# compile ON the board (dtc lives there), install, unloadapp, loadapp.
#
# TRAP 4 -- STOP THE DASHBOARD SERVICE BEFORE TOUCHING THE PL. If
# ctrace-dashboard.service is running it holds /dev/mem mappings onto the
# active design's aperture and polls them. An `xmutil unloadapp` then pulls
# the PL out from under a live AXI master, and the PS interconnect hangs:
# the board stops answering ssh and only the power switch brings it back.
# Measured 2026-08-21 on kria-kv260b -- THREE times in a row, once per
# attempt, until the service was stopped first; with the service stopped the
# very next attempt loaded cleanly ("Loaded with slot_handle 0").
#
# The service is NOT restarted here on purpose. After a deploy a different
# design sits in the PL than the one the dashboard was serving; bringing it
# back up automatically would point it at the wrong aperture. Restart it
# deliberately when the new design is the one it should serve:
#     sudo systemctl start ctrace-dashboard
jump_sh "ssh $USER_@$BOARD 'rm -rf /tmp/$APP' && scp -q -r /tmp/$APP $USER_@$BOARD:/tmp/$APP && ssh $USER_@$BOARD '
set -e
if systemctl is-active --quiet ctrace-dashboard 2>/dev/null; then
    echo $SUDO_PASS | sudo -S systemctl stop ctrace-dashboard
    echo \"[board] ctrace-dashboard stopped (restart it yourself once the new design is the one it should serve)\"
fi
if xmutil listapps 2>/dev/null | grep -qE \"^$APP[[:space:]].*[0-9]+->[0-9]+\"; then
    echo $SUDO_PASS | sudo -S busybox devmem 0xA0000000 32 0x0 2>/dev/null || true
    echo \"[board] our app was active -- core stopped\"
else
    echo \"[board] our app not active -- aperture untouched\"
fi
cd /tmp/$APP && dtc -@ -I dts -O dtb -o $APP.dtbo $APP.dtso
echo $SUDO_PASS | sudo -S bash -c \"mkdir -p /lib/firmware/xilinx/$APP && cp $APP.bit.bin $APP.dtbo shell.json /lib/firmware/xilinx/$APP/ && xmutil unloadapp >/dev/null 2>&1; xmutil loadapp $APP\"
md5sum /lib/firmware/xilinx/$APP/$APP.bit.bin
'" | tee /tmp/deploy_$APP.log

remote_md5="$(grep -E '^[0-9a-f]{32}  /lib/firmware' /tmp/deploy_$APP.log | awk '{print $1}' | tail -1)"
if [ "$remote_md5" != "$local_md5" ]; then
    echo "### HASH_MISMATCH -- local $local_md5 vs target '$remote_md5' -- DEPLOY INVALID"
    exit 1
fi
echo "### DEPLOY_OK $APP bit.bin $local_md5 (verified on target)"
