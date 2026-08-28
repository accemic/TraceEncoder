#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""CTTE KV260 dashboard server.

Serves the register/pipeline visualization (index.html + regmap.json) and a
small JSON API over the live hardware:

    GET  /api/scenarios              catalogue of loadable apps + active one
    POST /api/scenario               {"id":"cva6_linux","load":true} switch
                                     scenario (load=true also runs xmutil)
    GET  /api/state                  poll set (CTRL + key encoder CSRs)
    GET  /api/read?region=enc&off=0x400&n=32     bulk 32-bit word read
                                     (409 on the memory window of a RUNNING
                                     core and on the destructive fifo0/fifo1
                                     RDFD windows -- see region_hold_reason)
    GET  /api/trace?off=0&n=512      captured ATB bytes (hex string)
    GET  /api/mode                   {"mode":"demo"|"live","live_available":..}
    POST /api/mode                   {"mode":"live"} runtime switch Demo|Live
    GET  /api/dump?src=uram|ddr      raw captured trace (binary download,
                                     chronological order, ring/circular aware)
    GET  /api/decode?src=uram|ddr    run NexRv decode server-side
                                     (&pcout=0|1|2 downloads that target's PCs)
    GET  /api/console?since=N        guest console bytes since offset N
    POST /api/console                {"data":"ls\\n"} type into the guest
                                     (only on bitstreams with the UART RX path)
    GET  /api/livepc?tail=N          decode the last N ring bytes and symbolise
                                     them: current function, hot list, bit/instr
    GET  /api/insight                accumulated live view (hot map, coverage,
                                     measured decoder throughput, rate history)
    POST /api/symbols                upload a System.map/nm table
    POST /api/pcinfo?target=0|1|2    upload a pcinfo for /api/decode
    GET  /api/wp/status              AXIS watchpoint counters (drops/fill/ovf
                                     per core, FTIME, rates) -- "wp" scenarios
    GET  /api/wp/records?n=100       the last N watchpoint records (PC->symbol
                                     from wp_set); its UI is /wp.html
    POST /api/wp/load                {"slots":[{"addr":..,"cmd":..},..]} load
                                     the WP table -- ONLY while core_run=0 and
                                     trTeControl.Active=0, otherwise HTTP 409
    POST /api/write                  {"region":"enc","offset":0,"value":103}
                                     409 if the field is Enable-locked and the
                                     encoder is armed (the write would be
                                     dropped WITHOUT an error response), or if
                                     the region belongs to a running core;
                                     {"ok": false, "not_taken": [...]} if the
                                     readback disagrees with what was written
    POST /api/elf?target=ram|ram1|cva6  raw ELF32/ELF64/hex body -> program RAM;
                                     cva6 = phys write into the reserved DDR
                                     window 0x6400_0000 (SPEC_board_memory_map)
    POST /api/ctl                    {"action":"run|stop|trace_on|trace_off|clear|flush|irq_on|irq_off|cva6_run|cva6_stop|ddr_*|pib_*"}
                                     {"action":"core_run|core_stop","core":N}
                                     starts/stops ONE core (U1: CONTROL b8/b9,
                                     effective = b0 | b(8+i)); run/stop remain
                                     the collective path over b0

Every register offset comes from `scenarios.json`, never from a literal in this
file: the CTRL maps of the apps differ (mbv/trio have AXIS_BEATS at 0x10 and
TRACE_BUFSZ at 0x14, the Linux CVA6 has TRACE_BUFSZ at 0x10, CON_BYTES at 0x14
and everything from SINK_CTRL shifted by four bytes). A hard-coded offset reads
plausible-looking nonsense on the other app without anything reporting it.

Runs on the Kria (needs /dev/mem => sudo). Off-board it starts in DEMO mode
(simulated registers seeded from regmap.json reset values, plus the recorded
Linux boot log as console content) so the UI can be developed/viewed anywhere.
Demo|Live is runtime-switchable via /api/mode; both buses stay instantiated
(the demo bus always, the HW bus when /dev/mem is mappable).

Usage:
    sudo python3 server.py [--port 8099] [--host 127.0.0.1] [--scenario cva6_linux]
Access from any machine:
    --host 0.0.0.0  ->  http://<board-ip>:8099/   straight from your network
    --host 127.0.0.1 (default) -> only via `ssh -L 8099:localhost:8099 <kria>`
Permanent operation on the board (survives a reboot, the app is loaded at boot):
    sudo bash board_dashboard_install.sh   # creates ctrace-app + ctrace-dashboard

The live bus is only brought up when `xmutil listapps` reports a known app in
the slot (see board_state()); without one the service stays in DEMO instead of
hanging the AXI interconnect on the first register read. That is the normal
case right after a reboot, until ctrace-app.service has loaded.
"""
import argparse
import csv
import ctypes
import hashlib
import json
import mmap
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

from scenario import Catalog
import insight
import wp_view

HERE = Path(__file__).resolve().parent
REGMAP = json.loads((HERE / "regmap.json").read_text(encoding="utf-8"))

# Scenario catalogue: WHICH app is loaded determines the regions AND the
# register map. `SC` is the active scenario; every register access goes
# through SC.co(<name>).
CAT = Catalog()
SC = CAT.active
INS = insight.InsightState()
WPV = wp_view.WpState()   # AXIS-Watchpoint-Ansicht (Paket H, /api/wp/*)
_LIVEPC_FAILS = 0  # ratenbegrenztes livepc-Fehler-Log (s. _livepc)


def REGIONS_OF(sc=None):
    return (sc or SC).regions

# ---------------------------------------------------------------------------
# Event log (forge_app_a12r pattern, data/client_events.log): one JSONL line
# per event {ts, level, msg, data, src}; server events and mirrored UI events
# share ONE file so a stall/restart can be reconstructed in exact order.
# Best-effort: logging never raises; size-capped to the last ~4000 lines.
# ---------------------------------------------------------------------------
EVENTS_LOG = HERE / "events.log"
_evt_lock = threading.Lock()


def log_event(level, msg, data=None, src="srv"):
    try:
        line = json.dumps({"ts": int(time.time() * 1000), "level": level,
                           "msg": msg, "data": data, "src": src},
                          ensure_ascii=False, default=str)
        with _evt_lock:
            with EVENTS_LOG.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
            if EVENTS_LOG.stat().st_size > 4_000_000:      # cap: keep the tail
                tail = EVENTS_LOG.read_text(encoding="utf-8",
                                            errors="replace").splitlines()[-4000:]
                EVENTS_LOG.write_text("\n".join(tail) + "\n", encoding="utf-8")
    except Exception:
        pass


# --------------------------------------------------------------------------
# Starting a guest. Reported 2026-08-10: the Linux on the Rocket cores could
# not be started from the dashboard.
#
# The UI simply had no way to do it: "Run" only releases the core, it does NOT
# reload the payload -- a guest that had already run has overwritten its own
# image and starts into changed code. Until now loading went exclusively
# through the board script, which a browser has no access to.
#
# Security principle: the script path comes from boot.json NEXT TO this server,
# never from the request. The browser picks a scenario id, nothing more --
# otherwise the button would be remote execution of arbitrary commands.
BOOT_CFG = HERE / "boot.json"
_boot_lock = threading.Lock()
_boot = {"running": False, "scen": None, "phase": None, "rc": None,
         "lines": [], "t0": None}


def boot_recipes():
    """The ids that have a boot recipe (empty if the directory is unreadable)."""
    try:
        return sorted(k for k in json.loads(
            BOOT_CFG.read_text(encoding="utf-8")) if not k.startswith("_"))
    except Exception:                            # noqa: BLE001
        return []


def boot_status():
    with _boot_lock:
        return {"running": _boot["running"], "scen": _boot["scen"],
                "recipes": boot_recipes(),
                "phase": _boot["phase"], "rc": _boot["rc"],
                "lines": list(_boot["lines"])[-40:], "t0": _boot["t0"]}


def _boot_say(line):
    with _boot_lock:
        _boot["lines"].append(line)
        del _boot["lines"][:-400]


def _boot_run(sid, cfg):
    """Run the phases of the board script one after another."""
    script = str(cfg.get("script") or "")
    phases = list(cfg.get("phases") or [])
    env0 = dict(cfg.get("env") or {})
    rc = 0
    try:
        for ph in phases:
            with _boot_lock:
                _boot["phase"] = ph
            _boot_say("=== PHASE %s ===" % ph)
            env = dict(os.environ)
            env.update(env0)
            env["PHASE"] = ph
            p = subprocess.Popen(["sudo", "-E", "bash", script],
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT,
                                 env=env, text=True, errors="replace")
            for ln in p.stdout:
                ln = ln.rstrip()
                if ln:
                    _boot_say(ln)
            rc = p.wait()
            if rc != 0:
                # Do NOT continue: a failed prep means the guest is not in
                # memory -- starting on top of that would produce exactly the
                # dead core this button is meant to prevent.
                _boot_say("PHASE %s aborted (rc=%d) -- stopping" % (ph, rc))
                break
    except Exception as e:                       # noqa: BLE001
        rc = -1
        _boot_say("ERROR: %s" % e)
    finally:
        with _boot_lock:
            _boot["running"] = False
            _boot["rc"] = rc
            _boot["phase"] = None
        log_event("event" if rc == 0 else "error",
                  "guest boot %s" % ("ok" if rc == 0 else "failed"),
                  {"scenario": sid, "rc": rc})


def boot_start(sid):
    try:
        cfg = json.loads(BOOT_CFG.read_text(encoding="utf-8")).get(sid)
    except Exception as e:                       # noqa: BLE001
        return {"ok": False, "reason": "boot.json unreadable: %s" % e}
    if not cfg:
        return {"ok": False,
                "reason": "no boot recipe for scenario %r" % sid}
    script = HERE / str(cfg.get("script") or "")
    if not script.is_file():
        return {"ok": False, "reason": "script missing: %s" % script}
    cfg = dict(cfg, script=str(script))
    with _boot_lock:
        if _boot["running"]:
            return {"ok": False, "reason": "boot already running (%s)"
                    % _boot["phase"]}
        _boot.update(running=True, scen=sid, phase=None, rc=None,
                     lines=[], t0=time.time())
    threading.Thread(target=_boot_run, args=(sid, cfg), daemon=True).start()
    return {"ok": True, "scen": sid, "phases": cfg.get("phases")}


# --------------------------------------------------------------------------
# bpi in FINE windows -- requested 2026-08-10: a 10 ms window, and two curves
# (maximum and average).
#
# Why here and not in the browser: 10 ms would mean 100 HTTP requests per
# second across two SSH hops -- what would be measured is the network latency,
# and the device under test would carry the load. The thread here sits next to
# /dev/mem, reads three registers per window and hands the browser the MAXIMUM
# and the MEAN of those windows once per second. Measure fast, transmit slow.
#
# The window duration is MEASURED, not assumed: Python threads sleep
# imprecisely, and a window booked as 10 ms that really took 14 ms skewed the
# rate by 40 %. For bpi the time cancels out (bits per instruction, not per
# second) -- the duration is carried along regardless, so that the label
# "10 ms" does not claim something untrue.
# 2 ms instead of 10 -- the window should be as small as possible so that a
# few maxima stand out. At 10 ms the maximum of every interval was nearly the
# same size and the curve drew a straight line. The shorter the window, the
# less it averages away. The duration ACTUALLY achieved is measured and
# reported; if the thread does not manage the 2 ms, that shows in the display
# instead of us claiming a number the clock never had.
BPI_MS = 2
_bpi_lock = threading.Lock()
_bpi_armed_ctr = 0
_bpi = {"win": [], "ms": [], "last": None, "on": False}


def bpi_snapshot():
    """Max/mean over the windows since the last call; empties the buffer."""
    with _bpi_lock:
        w = list(_bpi["win"]); ms = list(_bpi["ms"])
        _bpi["win"].clear(); _bpi["ms"].clear()
        on = _bpi["on"]
    if not w:
        return {"n": 0, "on": on, "nominal_ms": BPI_MS}
    return {"n": len(w), "on": on, "nominal_ms": BPI_MS,
            "max": max(w), "avg": sum(w) / len(w),
            "win_ms_avg": (sum(ms) / len(ms)) if ms else None,
            "win_ms_max": max(ms) if ms else None}


def _bpi_sampler(buses):
    """Clock the counters; a window without retires is DISCARDED."""
    while True:
        t0 = time.perf_counter()
        time.sleep(BPI_MS / 1000.0)
        try:
            bus = buses.current
            sc = SC
            if bus is None or sc is None or getattr(bus, "demo", False):
                continue
            offs = [sc.co("trace_bytes"), sc.co("retires"), sc.co("retires1")]
            if offs[0] is None or offs[1] is None:
                continue
            tb = bus.read("ctrl", offs[0])[0] >> 0
            r = bus.read("ctrl", offs[1])[0]
            if offs[2] is not None:
                r += bus.read("ctrl", offs[2])[0]
            # Do NOT read the encoder state per window: the fourth register
            # access cost more than the three counters together and pushed the
            # number of windows per second from ~470 down to ~28 (measured
            # 2026-08-10). Every 100 windows is enough -- it only changes when
            # somebody presses a button.
            global _bpi_armed_ctr
            _bpi_armed_ctr = (_bpi_armed_ctr + 1) % 100
            armed = _bpi.get("on", True)
            if _bpi_armed_ctr == 0:
                try:
                    armed = bool(bus.read("enc", 0)[0] & 1)
                except Exception:                # noqa: BLE001
                    armed = True
            dt = (time.perf_counter() - t0) * 1000.0
            with _bpi_lock:
                _bpi["on"] = armed
                prev = _bpi["last"]
                _bpi["last"] = (tb, r)
                if prev and armed and tb >= prev[0] and r > prev[1]:
                    db, dr = tb - prev[0], r - prev[1]
                    _bpi["win"].append(db * 8.0 / dr)
                    _bpi["ms"].append(dt)
                    del _bpi["win"][:-400]
                    del _bpi["ms"][:-400]
        except Exception:                        # noqa: BLE001
            # A sampling error must not kill the thread -- it would stop
            # silently and the display would simply show nothing any more.
            with _bpi_lock:
                _bpi["last"] = None


def _wp_sampler(buses):
    """AXIS watchpoint drain -- the ONLY FIFO reader in the system.

    Same pattern as _bpi_sampler: fetch the CURRENT bus and the CURRENT
    scenario on every tick (both change at runtime), and catch errors instead
    of dying. Live draining happens ONLY when (a) the scenario has a "wp"
    block, (b) the hardware bus belongs to that scenario (sc_id -- after a
    rebind a mapping would otherwise point at the wrong aperture) and (c) the
    WPCTRL magic matches (wp_view checks it per bus instance). Reading a FIFO
    is destructive (RDFD pops), which is why exactly this one thread drains;
    anyone who needs the F0 reader CLI directly on the board stops the
    service first.
    """
    last = time.monotonic()
    hist_t = 0.0
    while True:
        cfg = WPV.cfg
        time.sleep((int(cfg.get("poll_ms", 25)) if cfg else 250) / 1000.0)
        now = time.monotonic()
        dt, last = now - last, now
        try:
            sc = SC
            if sc is None or not sc.raw.get("wp"):
                WPV.drain_alive = False
                continue
            if WPV.sc is not sc:
                WPV.reset(sc)
            bus = buses.current
            if bus is None:
                WPV.drain_alive = False
                continue
            # A source change (demo<->live, bus rebind) empties the ring:
            # during an app load the server briefly falls back to DEMO, and the
            # SYNTHETIC records produced then would otherwise sit in the same
            # table in front of the real ones -- plausible-looking and wrong
            # (seen on the board: 1257 demo records per core before the first
            # live record).
            src = "demo" if bus.demo else "live:%d" % id(bus)
            if WPV.src != src:
                WPV.reset(sc)
                WPV.src = src
            if bus.demo:
                WPV.tick_demo(dt)
            else:
                if getattr(bus, "sc_id", None) != sc.id:
                    WPV.drain_alive = False
                    continue
                WPV.tick_live(bus)
            WPV.drain_alive = True
            # advance the rate window roughly every 250 ms (maxlen 40 = ~10 s)
            if now - hist_t >= 0.25:
                hist_t = now
                WPV.note_counters(time.time(),
                                  WPV.drops_by_core(bus, bus.demo))
        except Exception as e:                   # noqa: BLE001
            # A read error (the bus closed mid-rebind, say) must not kill the
            # thread -- next tick, fresh bus.
            WPV.drain_alive = False
            WPV.last_error = str(e)


def read_events(n=200):
    try:
        with _evt_lock:
            lines = EVENTS_LOG.read_text(encoding="utf-8",
                                         errors="replace").splitlines()[-n:]
        out = []
        for ln in lines:
            try:
                out.append(json.loads(ln))
            except ValueError:
                pass
        return out
    except OSError:
        return []

RAM_SIZE = {"ram": 0x20000, "ram1": 0x10000}   # MBV 128 KiB / TGC5B 64 KiB
TRACE_BRAM = 0x4000         # legacy first-fill capacity (pre-ring bitstreams)
HIST_BINS = 16              # CT_FIFO_HIST_BINS (eTIP FIFO fill histogram)

# trTeControl bits (rdl/ct_cs_cpuif.rdl)
TE_ACTIVE, TE_ENABLE, TE_ITRACE = 1 << 0, 1 << 1, 1 << 2

# ---------------------------------------------------------------------------
# Access truth. The question, asked 2026-08-14: are the accesses the dashboard
# offers really read/write? Many writes were thought to work only while the
# encoder is in reset.
#
# They are not: the interlock is not the reset but trTeControl.Enable. 501 of
# 628 fields are writable via swwel only while Enable=0, and a blocked write
# ends WITHOUT an error response (ct_cs_cpuif.sv:3519 ties cpuif_wr_err to 0).
# That is exactly why this interface used to report {"ok": true} without
# anything having happened.
# Two checks in front of it, both cheap:
#   1. read the gate before writing   -> HTTP 409 instead of a silent discard.
#   2. read back after the write      -> additionally catches WARL
#      legalisation and write masks (FUNNEL_CTRL 0x0001_0333).
# ---------------------------------------------------------------------------
REG_INDEX = {(r["region"], r["offset"]): r for r in REGMAP["regs"]}
ENC_REGIONS = ("enc", "enc1", "enc2")
# Regions whose READING destroys state: the PG080 FIFOs pop a word on every
# RDFD read (SPEC_axis_wp_memory_map.md §4). The server drain in wp_view.py is
# the only permitted reader.
DESTRUCTIVE_READ_REGIONS = ("fifo0", "fifo1")


def reg_at(region, off):
    """Register description for (region, offset) -- None when unknown.

    The RDL registers live in regmap.json under the region 'enc'; enc1/enc2
    are the same map at a different base (see the header of gen_regmap.py).
    """
    return REG_INDEX.get(("enc" if region in ENC_REGIONS else region, off))


def write_gate_reason(bus, region, off):
    """Why this write would fizzle out RIGHT NOW -- None otherwise."""
    if region not in ENC_REGIONS:
        return None
    r = reg_at(region, off)
    if not r:
        return None
    wr = [f for f in r["fields"] if "w" in f.get("sw", "")]
    gated = [f["name"] for f in wr if f.get("gated")]
    # Only refuse when the write can have NO effect at all -- that is, when
    # every writable field is locked. Mixed registers have to get through:
    # trTeControl carries the Enable bit ITSELF (a 409 on it would be a door
    # that only opens from the inside -- measured in the smoke test),
    # trTsControl keeps Active/Enable free next to a locked Type/Prescale, and
    # trTeDataControl its clear bits. Whatever does not arrive there is
    # reported field by field by the read-back; the UI additionally disables
    # the write button of the individual locked field.
    # CHANGED with the vendored sync onto CTTE 8b5e41eeda:
    # trTeInstFeatures used to be the second example of "mixed" -- eight
    # unlocked InstEn* bits next to SrcID/SrcBits. The CSR audit locked those
    # eight (the documentation had said so in two places, only the swwel block
    # had not), so the register is now fully locked and falls into the 409
    # case here.
    # This list is NOT maintained by hand but derived: it comes from
    # regmap.json, which gen_regmap.py generates from the RDL mirror.
    if not gated or len(gated) != len(wr):
        return None
    te = bus.read(region, 0)[0]
    if not (te & TE_ENABLE):
        return None
    # The closing sentence used to advise turning the encoder trace off --
    # and it was WRONG: `ctl trace_off` only clears InstTracing (b2), Enable
    # (b1) stays up and the same request gets another 409 (measured on the
    # board). A hint that sends the reader in a circle is worse than none, so
    # the message names the BIT and the control that actually drops it.
    return ("CONFLICT: %s+0x%03X (%s) is Enable-locked: %s writable only while "
            "trTeControl.Enable=0. The encoder of this region is armed "
            "(trTeControl=0x%08X) -- the write would be discarded WITHOUT an "
            "error response. Clear Enable first: write trTeControl (%s+0x000) "
            "with bit 1 = 0, or use the 'TE enabled' switch on the %s encoder "
            "card. 'Encoder trace off' does NOT clear Enable (it clears "
            "InstTracing only)."
            % (region, off, r["path"], "/".join(gated), te, region, region))


def readback_mask(r):
    """Bit mask of the fields that MUST carry the written value afterwards.

    Excluded are exactly those fields where written != read back is the RULE:
    read-only fields, pulse bits (they clear themselves), W1C bits (a 1
    clears) and everything the hardware writes itself (hw = w/rw). Without
    those exclusions the read-back comparison reported a failure on every
    second register that was none -- and a guard that keeps crying wolf gets
    switched off.
    """
    m = 0
    for f in r["fields"]:
        if "w" not in f.get("sw", ""):
            continue
        if f.get("pulse") or f.get("w1c"):
            continue
        if f.get("hw", "r") != "r":
            continue
        m |= ((1 << (f["msb"] - f["lsb"] + 1)) - 1) << f["lsb"]
    return m & 0xFFFFFFFF


def readback_diff(r, want, got):
    """Names of the fields that did NOT take the value that was written."""
    out = []
    m = readback_mask(r)
    if ((want ^ got) & m) == 0:
        return out
    for f in r["fields"]:
        w = (1 << (f["msb"] - f["lsb"] + 1)) - 1
        bits = w << f["lsb"]
        if not (bits & m):
            continue
        if ((want ^ got) & bits):
            out.append("%s: wrote 0x%X, reads 0x%X"
                       % (f["name"], (want >> f["lsb"]) & w, (got >> f["lsb"]) & w))
    return out


# ---------------------------------------------------------------------------
# Determining the build AT RUNTIME.
#
# `regmap.json` carries `"profile": "FULL (...)"` in its header, and the UI
# header prints it as a badge. That is a statement about the GENERATOR (it
# compiled the RDL without CT_PROFILE_NO_*), not about the bitstream currently
# in the PL -- for the running bitstream it happens to be true, but only
# because the vendored tree and the generator happen to be at the same
# vintage. Nobody checks that.
#
# Every bitstream answers the question itself, through two READ-ONLY
# registers:
#   trWpCap          @0x4020  Entries[15:0]   -- watchpoint slots
#   pc.trTeConstants @0x3008                  -- filters/comparators/perfcnt
# The expected values do NOT come from a constant but from the same RDL reset
# values that regmap.json is generated from -- a number maintained here would
# be the third place holding the truth, and the next one to drift.
DISCOVERY_PATHS = ("ct_cs_cpuif.trWpCap", "ct_cs_cpuif.pc.trTeConstants")


def discovery_expect():
    """Expected image of the discovery registers, from regmap.json reset values."""
    out = {}
    for r in REGMAP["regs"]:
        if r["path"] not in DISCOVERY_PATHS:
            continue
        word = 0
        fields = {}
        for f in r["fields"]:
            v = f.get("reset") or 0
            word |= v << f["lsb"]
            fields[f["name"]] = v
        out[r["path"]] = {"offset": r["offset"], "word": word, "fields": fields}
    return out


DISCOVERY_EXPECT = discovery_expect()


def read_discovery(bus, region="enc"):
    """What the bitstream says about its own build -- plus a expected/actual verdict.

    Returns, per register: the word that was read, the decoded fields, the
    expected word and a list of deviations. `ok` is true exactly when both
    registers deliver their expected image; then -- and only then -- does the
    register map really describe this bitstream. A deviation is a finding for
    the operator, not a reason to offer fields that do not exist in the
    silicon.
    """
    out = {"region": region, "regs": {}, "mismatch": [], "ok": True}
    for path, exp in DISCOVERY_EXPECT.items():
        r = REG_INDEX.get(("enc", exp["offset"]))
        try:
            got = bus.read(region, exp["offset"])[0]
        except Exception as e:                        # noqa: BLE001
            out["ok"] = False
            out["mismatch"].append("%s: not readable (%s)" % (path, e))
            continue
        fields = {}
        for f in (r["fields"] if r else []):
            w = (1 << (f["msb"] - f["lsb"] + 1)) - 1
            fields[f["name"]] = (got >> f["lsb"]) & w
            if fields[f["name"]] != exp["fields"].get(f["name"], 0):
                out["ok"] = False
                out["mismatch"].append(
                    "%s.%s: hardware %d, register map %d"
                    % (path.split(".")[-1], f["name"], fields[f["name"]],
                       exp["fields"].get(f["name"], 0)))
        out["regs"][path] = {"offset": exp["offset"], "value": got,
                             "expect": exp["word"], "fields": fields}
    wp = out["regs"].get("ct_cs_cpuif.trWpCap", {}).get("fields", {})
    out["wp_slots"] = wp.get("Entries", 0)
    return out


# ---------------------------------------------------------------------------
# Window policy, decided 2026-08-16 after the click test: not only the SIZE
# needs protecting but the OFFSET as well -- both read-only, because a window
# that can be moved around disturbs the hosting Ubuntu.
#
# Why this was necessary even though a HARDWARE interlock already exists: that
# interlock only bites while the sink is ARMED (ddr_en=1, SINK_STAT b4
# ddr_cfg_rej). With ddr_en=0 the hardware accepts any value -- proven on the
# board: `ctrl+0x1C = 0x80000000, readback 0x80000000`. And NOBODY checked the
# target: the reserved-memory check (`ddr_window_ok`) ran exclusively in the
# automatic bind path (`arm_default_sinks`), not on the write path. The DDR
# sink is an AXI WRITE master; a window outside the boot reservation means at
# best that the sink wedges (measured on the board: WPTR 0, every beat
# dropped, no BRESP -- and the wedge survives ddr_clear), at worst that it
# writes into the memory of the hosting Linux.
#
# Defence in depth: the UI now only displays both registers (no input field,
# no apply), and THIS interlock additionally applies to every other caller --
# curl included.
WINDOW_RO_KEYS = ("ddr_base", "ddr_size")
WINDOW_RO_NAMES = {"ddr_base": "soc.DDR_BASE", "ddr_size": "soc.DDR_SIZE"}


def window_policy_reason(sc, region, off):
    """DDR window registers are read-only by policy -- otherwise None.

    Data-driven like everything else here: the offset comes from the CTRL map
    of the SCENARIO (`ddr_base`/`ddr_size`), not from a constant. The layout
    depends on the build (tgc5b2 0x1C/0x20, MBV 0x20/0x24) -- a fixed number
    would have locked a foreign register on the other build and left the
    right one open.
    """
    if region != "ctrl":
        return None
    for key in WINDOW_RO_KEYS:
        o = sc.co(key)
        if o is None or o != off:
            continue
        return ("FORBIDDEN: ctrl+0x%03X (%s) is READ-ONLY in this dashboard. "
                "The DDR trace sink is an AXI write master: its window is "
                "fixed by the bitstream reset value and by the reserved-memory "
                "region declared at boot (ctrace-pl-ddr, no-map, "
                "vivado/kv260_app/ctrace_resmem.dtso; docs/SPEC_board_memory_"
                "map.md address plan v4). Moving base or size at run time "
                "points a DMA write master somewhere else -- outside the "
                "reservation that is the memory of the hosting Linux, and the "
                "U6 hardware interlock does NOT catch it (it only refuses the "
                "write while the sink is armed, SINK_STAT b4; at ddr_en=0 the "
                "hardware takes any value). Change the window in the bitstream "
                "and the device tree, then reload the app -- not here. Mode "
                "(circular/one shot), clear and on/off stay writable."
                % (off, WINDOW_RO_NAMES[key]))
    return None


def region_hold_reason(bus, sc, region):
    """The region belongs to a RUNNING core -> the access would hang.

    Since U1 this is a statement per core, no longer about "the cores": the
    loader window hangs off the core_rst_hold of ITS OWN wrapper. An access to
    the RAM of a running core never gets awready/arready, so the AXI4-Lite
    transaction stalls (SPEC_axis_wp_memory_map.md §10 item 2) -- on the board
    that is a hanging /dev/mem access which takes the service down with it.
    Hence this refuses instead of accessing.

    The run state comes from CONTROL, not from STATUS: on a bitstream older
    than U1 the STATUS mirrors read 0 while the core runs via b0.
    """
    core = sc.gate_core(region)
    if core is None or sc.co("control") is None:
        return None
    ctrl = bus.read("ctrl", sc.co("control"))[0]
    if not sc.core_running(ctrl, core):
        return None
    return ("CONFLICT: %s is the memory window of %s, and that core is RUNNING "
            "(CONTROL=0x%08X). The window of a running core never returns "
            "ready -- the access would HANG the AXI transaction until the core "
            "is stopped (SPEC_axis_wp_memory_map.md §10 point 2). Stop that "
            "core first (per-core stop, CONTROL b%d)."
            % (region, core.get("name") or ("core %s" % core.get("id")), ctrl,
               (sc.control_bits.get(core.get("run_bit") or "core_run") or 0)))


def protocol_lock_reason(bus, sc, idx=None):
    """Why starting this core NOW would produce an undecodable stream.

    The trio runs two trace protocols in one netlist: two encoders speak
    N-Trace, the third E-Trace. The funnel merges them correctly -- the frame
    length of every beat sits in the ATB signal ATBYTES (4 bytes for N-Trace,
    1 for E-Trace). NONE of the three sinks stores that signal. A merged
    stream is therefore not decodable at all: every E-Trace byte lands as
    `nn FF FF FF` in the ring, and a decode aborts at the framing
    (MSEO='10' is not allowed) -- for ALL targets, not only the third one.

    So the interlock is not a convenience. Without it the operator gets a
    full ring, counters that look healthy and a decode that fails with a
    framing error somewhere else entirely -- the class of defect where every
    number says "fine".

    Returns None when nothing speaks against it. `idx=None` asks about the
    COLLECTIVE start (CONTROL b0), which releases every core at once and is
    therefore refused outright in a mixed scenario.
    """
    protos = sc.protocols()
    if len(protos) < 2:
        return None
    C = sc.co("control")
    if C is None:
        return None
    mine = sc.core_protocol(sc.cores[idx]) if idx is not None else None
    if idx is not None and not mine:
        return None
    ctrl = bus.read("ctrl", C)[0]
    busy = [(i, c) for i, c in enumerate(sc.cores)
            if i != idx and sc.core_protocol(c)
            and sc.core_protocol(c) != mine and sc.core_running(ctrl, c)]
    if idx is None:
        return ("CONFLICT: the collective start releases every core, and this "
                "scenario mixes %s -- the sinks do not store ATBYTES, so a "
                "merged stream cannot be decoded. Start the cores of ONE "
                "protocol individually (core_run) instead."
                % " and ".join(protos))
    if not busy:
        return None
    other = ", ".join("%s (%s)" % (c.get("name") or "core %d" % i,
                                  sc.core_protocol(c)) for i, c in busy)
    return ("CONFLICT: %s speaks %s, and %s is running -- the sinks do not "
            "store ATBYTES, so the merged ring would carry two frame lengths "
            "and decode nowhere. Stop the other core first."
            % (sc.cores[idx].get("name") or "core %d" % idx, mine, other))


def set_core_run(bus, sc, idx, run):
    """Start/stop ONE core without disturbing the others.

    The collective bit b0 is OR-ed in (SPEC §10): stopping only core 0 means
    dropping b0 AND giving the still-running core 1 its own bit. So the
    effective state of ALL cores is read, the target core changed inside it,
    and the resulting set expressed exclusively through per-core bits (b0 =
    0). Cores without a bit of their own (single-core SoCs, bitstreams older
    than U1) fall back to the collective bit.

    Returns (ctrl_before, ctrl_after, note|None).
    """
    C = sc.co("control")
    ctrl = bus.read("ctrl", C)[0]
    cores = sc.cores
    eff = [sc.core_running(ctrl, c) for c in cores]
    eff[idx] = bool(run)
    new = ctrl
    for c in cores:
        new &= ~sc.core_run_mask(c)
    for i, c in enumerate(cores):
        if eff[i]:
            new |= sc.core_own_bit(c) or sc.core_run_mask(c)
    bus.write("ctrl", C, new & 0xFFFFFFFF)
    hint = None
    # Counter-check against the STATUS mirror: does the loaded bitstream carry
    # the per-core bits at all? On an older build b8/b9 is a write into
    # nothing, and dropping b0 would have halted BOTH cores -- so there the
    # request is declined instead of silently doing something else.
    so = sc.co("status")
    want_mirror = [i for i, c in enumerate(cores)
                   if eff[i] and sc.core_own_bit(c)
                   and sc.status_bits.get(_running_bit_name(c)) is not None]
    if so is not None and want_mirror:
        st = bus.read("ctrl", so)[0]
        cold = [i for i in want_mirror
                if not (st >> sc.status_bits[_running_bit_name(cores[i])]) & 1]
        if cold:
            bus.write("ctrl", C, ctrl & 0xFFFFFFFF)
            hint = ("bitstream WITHOUT per-core run bits (STATUS mirror stays 0 "
                    "for core %s) -- CONTROL restored to 0x%08X. This build only "
                    "knows the collective bit b0; use Run/Stop on the first core."
                    % (", ".join(str(i) for i in cold), ctrl))
            return ctrl, ctrl, hint
    return ctrl, new & 0xFFFFFFFF, hint


def w1c_mask(region, off):
    """The mask of the write-1-to-clear bits of a register (0 when there are none)."""
    r = reg_at(region, off)
    if not r:
        return 0
    m = 0
    for f in r["fields"]:
        if f.get("w1c"):
            m |= ((1 << (f["msb"] - f["lsb"] + 1)) - 1) << f["lsb"]
    return m


def rmw_value(region, off, value):
    """Whole-word write-back value WITHOUT the W1C bits.

    trTeControl.InstStallOrOverflow (b12) is rw WITH onwrite=woclr: writing
    the whole word back clears the overflow evidence along with it -- exactly
    the indication that trace was lost. The same holds for trTeDataControl
    b3/b5. Every read-modify-write path therefore goes through this function.
    """
    return value & ~w1c_mask(region, off) & 0xFFFFFFFF


def _running_bit_name(core):
    """STATUS mirror bit for a core's release bit (core0_run -> core0_running)."""
    rb = core.get("run_bit") or "core_run"
    return {"cva6_run": "cva6_running", "cva6_run2": "cva6_running"}.get(
        rb, rb.replace("_run", "_running"))


class HwBus:
    """32-bit word access to the KV260 aperture via /dev/mem."""

    def __init__(self, sc=None):
        sc = sc or SC
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.maps = {}
        for name, (base, size) in sc.regions.items():
            self.maps[name] = mmap.mmap(self.fd, size, mmap.MAP_SHARED,
                                        mmap.PROT_READ | mmap.PROT_WRITE,
                                        offset=base)
        self.lock = threading.Lock()
        self.demo = False
        self.sc_id = sc.id

    def close(self):
        for m in self.maps.values():
            try:
                m.close()
            except (BufferError, ValueError):
                pass        # another ctypes view still open: the GC cleans up
        self.maps = {}
        try:
            os.close(self.fd)
        except OSError:
            pass

    def read(self, region, off, n=1):
        # ctypes.c_uint32 accesses compile to single 32-bit loads/stores --
        # required for CSRs (a byte-wise memcpy would issue 4 partial-strobe
        # AXI writes/reads against registers with side effects).
        m = self.maps[region]
        with self.lock:
            return [ctypes.c_uint32.from_buffer(m, off + 4 * i).value
                    for i in range(n)]

    def write(self, region, off, value):
        m = self.maps[region]
        with self.lock:
            ctypes.c_uint32.from_buffer(m, off).value = value & 0xFFFFFFFF

    def write_block(self, region, off, data: bytes):
        # Word-wise via ctypes: a plain mmap slice write (glibc memcpy with
        # NEON/unaligned stores) SIGBUSes on Device-nGnRnE /dev/mem mappings.
        if len(data) % 4:
            data = data + b"\x00" * (4 - len(data) % 4)
        m = self.maps[region]
        words = struct.unpack("<%dI" % (len(data) // 4), data)
        with self.lock:
            for i, w in enumerate(words):
                ctypes.c_uint32.from_buffer(m, off + 4 * i).value = w

    def phys_read(self, addr, n):
        """Read n bytes from an arbitrary physical address (DDR sink buffer).

        The copy ALWAYS starts at the page boundary of the mapping, never at
        an odd address -- and more than style hangs on that here. The reserved
        window is `no-map`, so the /dev/mem mapping is device memory (nGnRE);
        a glibc memcpy that starts there with LDP/NEON at an address which is
        not 16-byte aligned raises an alignment fault. Same class as the write
        side (write_block, word by word via ctypes) -- there it has been in
        the code since G7, on the read side it went unnoticed because until U8
        every call started at DDR_BASE, which is page aligned.

        Measured on the board (2026-08-15): the capped raw dump read from
        `base + wptr - 32 MiB` = 0x5096FA3FC (page offset 0x3FC) and the
        service died with `status=7/BUS` and a core dump; the same range with
        a page-aligned copy start reads 32 MiB in 0.26 s.
        """
        page = addr & ~0xFFF
        off = addr - page
        # Round the length up to 16: the end of the copy should sit on an
        # edge as well. The surplus stays inside the page mapping.
        span = (off + n + 15) & ~15
        mlen = (off + n + 0xFFF) & ~0xFFF
        with self.lock:
            m = mmap.mmap(self.fd, mlen, mmap.MAP_SHARED, mmap.PROT_READ,
                          offset=page)
            try:
                raw = bytes(m[0:span])          # Start seitenausgerichtet
            finally:
                m.close()
        return raw[off:off + n]                 # Zuschnitt im normalen RAM

    # The reserved PL window per examples/kv260/SPEC_board_memory_map.md, address plan
    # **v3** (2026-07-26, verified on the board 2026-07-27):
    # 0x6000_0000 + 256 MiB. The upper bound 0x6800_0000 that used to stand
    # here was the v2 state (128 MiB) and would have refused every RV64 guest
    # load above 64 MiB -- the cv64a6/Rocket share is 192 MiB
    # (0x6400_0000..0x6FFF_FFFF).
    # The trace window does NOT touch this bound, and that is deliberate:
    # since address plan v4 it sits at 0x5000_0000 + 256 MiB, i.e. BELOW
    # PL_WIN_LO. Loading a guest program to 0x5xxx_xxxx therefore stays
    # refused -- that is where the trace buffer now lives, and a load there
    # would be a write into a running capture.
    PL_WIN_LO = 0x60000000
    PL_WIN_HI = 0x70000000

    def phys_write(self, addr, data):
        """Write bytes to a physical address inside the reserved PL window.
        Used for the guest program load into the DDR window at 0x6400_0000."""
        if not (self.PL_WIN_LO <= addr and addr + len(data) <= self.PL_WIN_HI):
            raise ValueError("phys_write outside reserved PL window 0x%08X..0x%08X"
                             % (self.PL_WIN_LO, self.PL_WIN_HI - 1))
        page = addr & ~0xFFF
        mlen = (addr + len(data) - page + 0xFFF) & ~0xFFF
        with self.lock:
            m = mmap.mmap(self.fd, mlen, mmap.MAP_SHARED,
                          mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
            try:
                m[addr - page:addr - page + len(data)] = data
            finally:
                m.close()


class DemoBus:
    """Register simulation seeded from regmap reset values (off-board dev)."""

    def __init__(self, sc=None):
        sc = sc or SC
        self.sc = sc
        self.sc_id = sc.id
        self.demo = True
        self.lock = threading.Lock()
        self.mem = {k: bytearray(size) for k, (base, size) in sc.regions.items()}
        encs = [r for r in ("enc", "enc1", "enc2") if r in self.mem]
        for r in REGMAP["regs"]:
            if r["region"] not in self.mem and r["region"] != "enc":
                continue
            v = 0
            for f in r["fields"]:
                if f.get("reset"):
                    v |= (f["reset"] << f["lsb"])
            if r["region"] == "enc":     # all encoders = identical reset values
                for e in encs:
                    struct.pack_into("<I", self.mem[e], r["offset"], v)
            else:
                struct.pack_into("<I", self.mem[r["region"]], r["offset"], v)
        # demo arming cosmetics: SrcBits + SrcID as on the board
        srcbits = int(sc.decode.get("srcbits", 0))
        for i, e in enumerate(encs):
            f = struct.unpack_from("<I", self.mem[e], 0x008)[0]
            f = (f & 0x0000FFFF) | (srcbits << 28) | (i << 16)
            struct.pack_into("<I", self.mem[e], 0x008, f)
            # ... and InhibitSrc along with it. The RDL reset of trTeControl
            # has b15 set (SRC OFF); a multi-source setup runs on the board
            # with b15 = 0 (ENC_CTRL 0x016602EF). Without this the demo of a
            # multi-core scenario showed "SRC off" while that very field is
            # what separates the sources there -- the demo would contradict
            # the board at the one point that makes the multi-core case.
            if len(encs) > 1:
                t = struct.unpack_from("<I", self.mem[e], 0x000)[0]
                struct.pack_into("<I", self.mem[e], 0x000, t & ~(1 << 15))
        # FUNNEL_CTRL lives in the SoC CTRL map, not in the encoder RDL -- so
        # the reset value above does not reach it, and the demo showed
        # "prio —" where the board has 0x11 (round robin). The value is the
        # MEASURED idle state of the two-hart run, not an invented one.
        if sc.co("funnel_ctrl") is not None:
            # One nibble per channel, priority 1 = round robin: 0x11 with two
            # channels, 0x111 with three. Printing a fixed 0x11 made the trio
            # view show "1/1/0" -- a disabled channel that does not exist.
            n = max(1, len(sc.raw.get("cores") or []))
            struct.pack_into("<I", self.mem["ctrl"], sc.co("funnel_ctrl"),
                             sum(1 << (4 * i) for i in range(n)))
        self.t0 = time.time()
        self.traced = 0
        self.maxfill = 0
        self.overflows = 0
        self.inject_overflow = False
        # Pump rate and density of the simulation, per scenario from
        # scenarios.json (the `demo` block, with its sources named there).
        # Without an entry the old random trickle stays (40-400 B per tick) --
        # that was enough for register tests, but the fill bars and the bpi
        # chart of a demonstration need the order of magnitude measured on the
        # board (found at the website demo 2026-08-12: the memories did not
        # fill up and the bpi chart stayed empty).
        dem = (sc.raw.get("demo") or {})
        self.byte_rate = int(dem.get("byte_rate", 0))       # B/s; 0 = Tropf
        self.sim_bpi = float(dem.get("bpi", 0.0))           # Bits je Retire
        self.retired = 0.0                                  # Retire-Akkumulator
        self.cap = min(0x100000, sc.regions.get("trace", (0, 0x100000))[1])
        if sc.co("trace_bufsz") is not None:
            struct.pack_into("<I", self.mem["ctrl"], sc.co("trace_bufsz"), self.cap)
        self.hist = [0] * HIST_BINS             # eTIP FIFO fill histogram
        self.hist_ptr = 0
        # Console demo: the REAL recorded Linux boot, replayed character by
        # character. No invented text -- what runs here is the recording from
        # the board.
        self.con_text = b""
        self.con_n = 0
        self.con_t0 = None
        if sc.console:
            # The scenario's own demo console first (make_demo_console.py) --
            # the Rocket boot is a different run from the CVA6 boot, and a CVA6
            # console underneath a Rocket diagram contradicted the picture at
            # its loudest point (website demo v2, 2026-08-11).
            for p in (HERE / "demo" / ("console_%s.txt" % sc.id),
                      HERE / "demo" / "console_linux.txt"):
                if p.is_file():
                    self.con_text = p.read_bytes()
                    break
        # Deterministic demo trace stream: a REAL merged dual-core capture if
        # present (demo/demo_trace.bin, from the green duo sim) -- looped --
        # else a deterministic byte pattern. Ring mem, DDR sink windows and
        # /api/dump all derive from the SAME stream, so they stay consistent.
        # A scenario-specific stream where one exists, the generic one
        # otherwise. For cva6_linux that is a slice of the REAL boot recording
        # (linuxboot.bin) -- it decodes against demo/cva6_linux.pcinfo and so
        # yields the same function names in demo mode as on the board, not
        # invented ones.
        for p in (HERE / "demo" / ("demo_trace_%s.bin" % sc.id),
                  HERE / "demo" / "demo_trace.bin"):
            if p.is_file():
                self.stream = p.read_bytes()
                break
        else:
            self.stream = None
        # DDR sink model: list of observed stream ranges [start, end) while
        # the sink was enabled (concatenated = the sink's input stream).
        self.ddr_runs = []
        threading.Thread(target=self._tick, daemon=True).start()

    def _sbyte(self, i):
        if self.stream:
            return self.stream[i % len(self.stream)]
        return (i * 2654435761 >> ((i & 3) * 8)) & 0xFF

    def _sbytes(self, start, n):
        return bytes(self._sbyte(i) for i in range(start, start + n))

    def _cu(self, name, default=0):
        """Read a CTRL register -- 0 when this app does not have it."""
        off = self.sc.co(name)
        return default if off is None else struct.unpack_from("<I", self.mem["ctrl"], off)[0]

    def _cp(self, name, value):
        off = self.sc.co(name)
        if off is not None:
            struct.pack_into("<I", self.mem["ctrl"], off, value & 0xFFFFFFFF)

    def _mirror_status(self):
        """STATUS mirror of the EFFECTIVE run state (RTL behaviour).

        In the RTL this is combinational wiring: the mirror is valid in the
        same access that wrote CONTROL. Hence it lives in the write path and
        not only in the 250 ms tick -- otherwise a read-after-write sees the
        OLD mirror, the capability probe in set_core_run mistakes the build
        for a pre-U1 one and withdraws the per-core stop (measured exactly
        like that in the smoke test).
        """
        so = self.sc.co("status")
        if so is None:
            return
        ctrl = struct.unpack_from("<I", self.mem["ctrl"], 0)[0]
        st = struct.unpack_from("<I", self.mem["ctrl"], so)[0]
        for c in (self.sc.cores or []):
            b = self.sc.status_bits.get(_running_bit_name(c))
            if b is None:
                continue
            st = (st | (1 << b)) if self.sc.core_running(ctrl, c) else (st & ~(1 << b))
        struct.pack_into("<I", self.mem["ctrl"], so, st & 0xFFFFFFFF)

    def _ddr_state(self):
        """(total_bytes, size, circ, oneshot_full, wrapped) of the DDR model."""
        sink = self._cu("sink_ctrl")
        size = self._cu("ddr_size") & ~3
        circ = bool(sink & 0x4)
        total = sum(e - s for s, e in self.ddr_runs)
        if not circ and size:
            total = min(total, size)            # one shot: stops when full
        return total, size, circ, (not circ and size and total >= size), \
            (circ and size and total >= size)

    def ddr_dump(self):
        """Chronological DDR buffer content per mode (demo model)."""
        total, size, circ, _full, _wr = self._ddr_state()
        data = b"".join(self._sbytes(s, e - s) for s, e in self.ddr_runs)
        if not circ:
            return data[:min(total, size or len(data))]
        return data[-size:] if size and len(data) > size else data

    def uram_dump(self):
        held = min(self.traced, self.cap)
        return self._sbytes(self.traced - held, held)

    def con_dump(self):
        """Konsolen-Ring-Inhalt (Demo: Praefix des echten Boot-Mitschnitts)."""
        return self.con_text[:self.con_n]

    def _tick(self):
        import random
        while True:
            time.sleep(0.25)
            with self.lock:
                ctrl = struct.unpack_from("<I", self.mem["ctrl"], 0)[0]
                encs = [r for r in ("enc", "enc1", "enc2") if r in self.mem]
                tes = {e: struct.unpack_from("<I", self.mem[e], 0)[0] for e in encs}
                eff = lambda t: (t & TE_ACTIVE) and (t & TE_ENABLE) and (t & TE_ITRACE)
                # Run state PER CORE (effective = b0 | b(8+i)). The stream
                # flows for as long as at least one core runs AND its encoder
                # is armed -- there used to be a fixed `ctrl & 1` here, which
                # did not see a core started through its own bit.
                dcores = self.sc.cores or [{"enc": "enc"}]
                run_i = [self.sc.core_running(ctrl, c) for c in dcores]
                running = any(r and eff(tes.get(c.get("enc") or "enc", 0))
                              for r, c in zip(run_i, dcores))
                # STATUS mirror as in the RTL: the EFFECTIVE state, not the
                # wish (tgc5b2_axis_soc_top.sv:584). Without it the demo showed
                # a core as stopped that it was in fact running. (It is already
                # set on the write path; this catches up in case trace_clear
                # zeroed the mirror along the way.)
                self._mirror_status()
                # timestamp counter
                ts = int((time.time() - self.t0) * 75e6) & ((1 << 64) - 1)
                struct.pack_into("<Q", self.mem["enc"], 0x48, ts)
                sink = self._cu("sink_ctrl")
                # console: replay the real capture in real time as soon as
                # the core is running (2000 characters/s ~ 115200 8N1).
                if self.con_text and (ctrl & self.sc.cbit("core_run")):
                    if self.con_t0 is None:
                        self.con_t0 = time.time()
                    want = int((time.time() - self.con_t0) * 2000)
                    self.con_n = min(len(self.con_text), max(self.con_n, want))
                    self._cp("con_bytes", self.con_n)
                    cw = self.sc.console
                    if cw and "con" in self.mem:
                        blob = self.con_text[:self.con_n]
                        blob += b"\x00" * ((-len(blob)) % 4)
                        self.mem["con"][:len(blob)] = blob
                if running:
                    if self.byte_rate:
                        # board order of magnitude, with some life (+-15 %).
                        burst = int(self.byte_rate * 0.25 *
                                    random.uniform(0.85, 1.15))
                    else:
                        burst = random.randint(40, 400)
                    # Keep the retire counters consistent with the byte rate
                    # wherever the scenario has them (rocket2:
                    # ctrl.retires/retires1). The UI's bpi panel computes
                    # d(bytes)*8/d(retires) -- without maintained counters it
                    # stays empty. The density comes from the scenario's demo
                    # block (values measured on the board).
                    if self.sim_bpi > 0 and self.sc.co("retires") is not None:
                        self.retired += burst * 8.0 / self.sim_bpi
                        r = int(self.retired)
                        # Two harts do not split the work exactly in half -- a
                        # fixed 55/45 ratio looks like SMP rather than like a
                        # copy.
                        self._cp("retires", int(r * 0.55) & 0xFFFFFFFF)
                        if self.sc.co("retires1") is not None:
                            self._cp("retires1", int(r * 0.45) & 0xFFFFFFFF)
                    old = self.traced
                    new = self.traced + burst
                    if sink & 0x8:                # URAM one shot: stop when full
                        new = min(new, self.cap)
                    self.traced = new
                    fill = random.randint(0, 900) + (8000 if self.inject_overflow else 0)
                    self.maxfill = max(self.maxfill, min(fill, 0x7FFF))
                    b = min(HIST_BINS - 1, fill * HIST_BINS // 16384)
                    for i in range(b + 1):
                        self.hist[i] = min(self.hist[i] + random.randint(0, 3), 0xFFFF)
                    if self.inject_overflow:
                        self.overflows = min(self.overflows + random.randint(1, 60), 0x7FFF)
                    for i in range(old & ~3, self.traced, 4):
                        struct.pack_into("<I", self.mem["trace"], i % self.cap,
                                         int.from_bytes(self._sbytes(i, 4), "little"))
                    self._cp("trace_beats", self.traced // 4)
                    self._cp("trace_bytes", self.traced)
                    wrapped = 1 if (self.traced >= self.cap and not (sink & 0x8)) else 0
                    self._cp("status", wrapped)
                    # DDR-Sink beobachtet denselben Strom, solange enabled.
                    if sink & 0x1 and self.traced > old:
                        if self.ddr_runs and self.ddr_runs[-1][1] == old:
                            self.ddr_runs[-1][1] = self.traced
                        else:
                            self.ddr_runs.append([old, self.traced])
                        # DDR_BEATS counts the OFFERED beats (0x38) -- not the
                        # written ones. That difference is the whole point of
                        # the counter: accepted = BEATS - DROPS, and in the
                        # one-shot case it keeps running while DDR_WPTR
                        # stands still.
                        self._cp("ddr_beats",
                                 min(self._cu("ddr_beats")
                                     + (self.traced - old) // 4, 0xFFFFFFFF))
                    if sink & 0x10:
                        div = (sink >> 8) & 7 or 1
                        rate_ok = (1 << (div + 1)) <= 8    # grobe Demo-Heuristik
                        if not rate_ok:
                            self._cp("pib_drops",
                                     min(self._cu("pib_drops") + random.randint(0, 9),
                                         0xFFFFFFFF))
                # Sink status every round (idle too: a mode change stays visible)
                total, size, circ, full, ddr_wr = self._ddr_state()
                uram_stop = 1 if (sink & 0x8) and self.traced >= self.cap else 0
                self._cp("ddr_wptr", total if circ else min(total, size or total))
                self._cp("sink_stat", (1 if full else 0) | ((1 if ddr_wr else 0) << 2)
                         | (uram_stop << 3))
                # trTeTipFifoStatus: respect the two W1-clear-and-hold bits
                st = struct.unpack_from("<I", self.mem["enc"], 0xE04)[0]
                mf = 0 if st & 0x8000 else self.maxfill
                ov = 0 if st & 0x80000000 else self.overflows
                if st & 0x8000:
                    self.maxfill = 0
                if st & 0x80000000:
                    self.overflows = 0
                    self.inject_overflow = False
                struct.pack_into("<I", self.mem["enc"], 0xE04,
                                 (st & 0x80008000) | (mf & 0x7FFF) | ((ov & 0x7FFF) << 16))

    def read(self, region, off, n=1):
        with self.lock:
            if region in ("enc", "enc1", "enc2") and off == 0xE14 and n == 1:  # serial hist
                p = self.hist_ptr
                self.hist_ptr = (p + 1) % (HIST_BINS // 2)
                return [self.hist[2 * p] | (self.hist[2 * p + 1] << 16)]
            return list(struct.unpack_from("<%dI" % n, self.mem[region], off))

    def write(self, region, off, value):
        with self.lock:
            if region == "ctrl" and off == self.sc.co("control"):
                if value & self.sc.cbit("trace_clear"):
                    self.traced = 0
                    self._cp("status", 0)
                    self._cp("trace_beats", 0)
                    self._cp("trace_bytes", 0)
                if self.sc.cbit("con_clear") and (value & self.sc.cbit("con_clear")):
                    self.con_n = 0
                    self.con_t0 = None
                    self._cp("con_bytes", 0)
                    self._cp("con_drops", 0)
            if region == "ctrl" and off is not None and off == self.sc.co("sink_ctrl"):
                if value & 0x2:   # ddr_clear (W1)
                    self.ddr_runs = []
                    self._cp("ddr_wptr", 0)
                    self._cp("sink_stat", 0)
                    self._cp("ddr_drops", 0)
                    self._cp("ddr_beats", 0)
                if value & 0x20:  # pib_clear (W1)
                    self._cp("pib_drops", 0)
                value &= ~0x22    # do not store pulse bits (as in HW)
            if region in ("enc", "enc1", "enc2") and off == 0xE10:
                if value & 2:  # RdRewind
                    self.hist_ptr = 0
                if value & 1:  # HistClear
                    self.hist = [0] * HIST_BINS
                    self.hist_ptr = 0
            # --- the two rules the demo used to LIE about (and would thereby
            # have hidden a fault the board really makes) ---
            # (1) swwel: a field write while trTeControl.Enable=1 is discarded
            #     by the hardware -- without an error response
            #     (cpuif_wr_err = 0).
            if region in ("enc", "enc1", "enc2"):
                r = reg_at(region, off)
                gate = 0
                if r:
                    for f in r["fields"]:
                        if f.get("gated"):
                            gate |= ((1 << (f["msb"] - f["lsb"] + 1)) - 1) << f["lsb"]
                if gate:
                    te = struct.unpack_from("<I", self.mem[region], 0)[0]
                    if te & TE_ENABLE:
                        old = struct.unpack_from("<I", self.mem[region], off)[0]
                        value = (value & ~gate) | (old & gate)
            # (2) onwrite = woclr: a 1 CLEARS the bit, a 0 leaves it standing
            #     -- exactly why writing the whole word back destroys the
            #     overflow evidence.
            m = w1c_mask(region, off)
            if m:
                old = struct.unpack_from("<I", self.mem[region], off)[0]
                value = (value & ~m) | (old & m & ~value)
            struct.pack_into("<I", self.mem[region], off, value & 0xFFFFFFFF)
            if region == "ctrl" and off == self.sc.co("control"):
                self._mirror_status()

    def write_block(self, region, off, data: bytes):
        with self.lock:
            self.mem[region][off:off + len(data)] = data


class Buses:
    """Runtime-switchable Demo|Live bus pair (/api/mode). The demo bus always
    exists; the HW bus is created lazily (first LIVE switch / startup)."""

    def __init__(self, force_demo=False):
        self.force_demo = force_demo
        self.demo_bus = DemoBus()
        self.hw_bus = None
        self.live_error = None
        if not force_demo:
            self._try_hw()
        self.current = self.hw_bus or self.demo_bus

    def rebind(self, sc):
        """Scenario changed: move both buses over to the new regions.

        The hardware bus MUST be remapped -- the regions sit at different
        physical addresses and have different sizes. Carrying an old mapping
        over would silently read the wrong aperture.
        """
        was_live = self.current is self.hw_bus and self.hw_bus is not None
        if self.hw_bus is not None:
            self.hw_bus.close()
            self.hw_bus = None
        self.demo_bus = DemoBus(sc)
        if not self.force_demo:
            self._try_hw(sc)
        self.current = (self.hw_bus if (was_live and self.hw_bus) else
                        (self.hw_bus or self.demo_bus))
        return self.mode()

    def _try_hw(self, sc=None):
        if self.hw_bus is None:
            if PL_GUARD:
                want = sc or SC
                st = board_state()
                # Tightened 2026-08-08: it used to be enough that "SOME known
                # app is loaded". With that the UI read the CTRL map of the
                # SELECTED scenario on the aperture of a DIFFERENT design --
                # and the offsets are NOT congruent between mbv/trio,
                # cva6_linux and rocket64 (see the header of scenarios.json),
                # so the result was plausible-looking wrong numbers. Now the
                # loaded app has to belong to the SELECTED scenario; otherwise
                # DEMO, with a reason.
                if st["safe"] and st["active_app"] not in want.apps:
                    other = CAT.by_app(st["active_app"])
                    self.live_error = (
                        "loaded is '%s'%s, selected is scenario '%s' "
                        "(expected: %s) -- the register maps differ, live "
                        "would be silently wrong. Switch the scenario or "
                        "load the matching bitstream."
                        % (st["active_app"],
                           " (scenario '%s')" % other.id if other else "",
                           want.id, ", ".join(want.apps)))
                    return None
                if not st["safe"]:
                    # NO live bus on an unprogrammed or foreign PL: the first
                    # read of 0xA000_0000 otherwise hangs the AXI interconnect
                    # and the board is dead (three frozen boards on
                    # 2026-07-27/28). On an autostart after boot that is
                    # exactly the normal case, for as long as
                    # ctrace-app.service has not loaded the app yet -- the
                    # service has to come up in DEMO there, not take the board
                    # down with it.
                    self.live_error = (
                        "PL not programmed: fpga_manager=%s, active app=%s "
                        "(expected one of: %s) -- load an app first "
                        "(xmutil loadapp / 'Load bitstream' button), then live"
                        % (st["fpga_state"], st["active_app"],
                           ", ".join(sorted(CAT.by_id_apps()))))
                    return None
            try:
                self.hw_bus = HwBus(sc)
                self.live_error = None
            except (OSError, PermissionError, ValueError, AttributeError) as e:
                # AttributeError: os.O_SYNC fehlt auf Windows (Workstation-Demo)
                self.live_error = str(e)
        return self.hw_bus

    def set_mode(self, mode):
        if mode == "demo":
            self.current = self.demo_bus
        elif mode == "live":
            if not self._try_hw():
                raise ValueError("live mode unavailable: %s" % self.live_error)
            self.current = self.hw_bus
        else:
            raise ValueError("mode must be 'demo' or 'live'")
        return self.mode()

    def mode(self):
        return "demo" if self.current.demo else "live"


# --- decoder configuration (CLI-overridable, see main()) --------------------
PL_GUARD = True       # live bus only with an app loaded (--no-pl-guard lifts it)
ARM_SINKS_ON_SELECT = False   # write the sink defaults on a scenario change?
                              # Default OFF: see _select_scenario -- the
                              # automatic access was the most dangerous one.
NEXRV = None          # path to the decoder binary (name kept for compat, see
                       # find_decoder() -- the tool itself is CTTD now)
PCINFO_CLI = {}       # target -> path from --pcinfo0/--pcinfo1
SRCBITS = 2           # SrcBits of the merged stream (TB/board contract)

# --------------------------------------------------------------------------
# Board sensors (ZynqMP AMS + the Kria on-board measurement)
#
# WHY THROUGH THE PS AND NOT THROUGH THE PL APERTURE: a register access to
# 0xA000_0000 hangs the AXI interconnect when no design is answering there
# (README trap 2, hit twice on 2026-08-18). But temperature is exactly the
# value one wants to see in such a moment -- so it is read from the PS, where
# it is available independently of the PL state:
#
#   /sys/bus/iio/devices/iio:device*  name=ams     -> in_temp{0_ps,1_remote,2_pl}_temp_raw
#   /sys/class/hwmon/hwmon*           name=ina260* -> power1/curr1/in1_input (board measurement)
#   /sys/class/hwmon/hwmon*           name=pwmfan  -> pwm1 (fan setpoint 0..255)
#
# Both sources are read (IIO first, hwmon as the twin); values that cannot be
# read are simply absent instead of making the call fail.
def _read_first(*paths):
    for p in paths:
        try:
            with open(p, "r") as fh:
                return fh.read().strip()
        except Exception:                        # noqa: BLE001
            continue
    return None


def read_sensors():
    """Board temperatures, power and fan setpoint (read on the PS side)."""
    out = {"available": False, "source": None}
    base = Path("/sys/bus/iio/devices")
    ams = None
    if base.is_dir():
        for d in sorted(base.glob("iio:device*")):
            if (_read_first(str(d / "name")) or "") == "ams":
                ams = d
                break
    if ams is not None:
        out["source"] = str(ams)
        for key, chan in (("ps", "in_temp0_ps_temp_raw"),
                          ("remote", "in_temp1_remote_temp_raw"),
                          ("pl", "in_temp2_pl_temp_raw")):
            raw = _read_first(str(ams / chan))
            if raw is None:
                continue
            try:
                out["temp_%s_c" % key] = round(int(raw) / 1000.0, 1)
                out["available"] = True
            except ValueError:
                pass
    hw = Path("/sys/class/hwmon")
    if hw.is_dir():
        for d in sorted(hw.glob("hwmon*")):
            nm = _read_first(str(d / "name")) or ""
            if nm == "ams" and "temp_ps_c" not in out:
                for i, key in ((1, "ps"), (2, "remote"), (3, "pl")):
                    raw = _read_first(str(d / ("temp%d_input" % i)))
                    if raw is not None:
                        try:
                            out["temp_%s_c" % key] = round(int(raw) / 1000.0, 1)
                            out["available"] = True
                        except ValueError:
                            pass
            elif nm.startswith("ina260"):
                for field, key, div in (("power1_input", "power_w", 1e6),
                                        ("curr1_input", "current_a", 1e3),
                                        ("in1_input", "voltage_v", 1e3)):
                    raw = _read_first(str(d / field))
                    if raw is not None:
                        try:
                            out[key] = round(int(raw) / div, 3)
                            out["available"] = True
                        except ValueError:
                            pass
            elif nm == "pwmfan":
                raw = _read_first(str(d / "pwm1"))
                if raw is not None:
                    try:
                        out["fan_pwm"] = int(raw)
                        out["fan_percent"] = round(int(raw) * 100.0 / 255.0)
                        out["available"] = True
                    except ValueError:
                        pass
    return out


# Decoder names, newest first. NexRv was renamed to CEDARtools.TraceDecoder
# (CTTD); "cttd" is the binary this repo now builds and pins, "NexRv" is the
# name every tree built before the rename still carries in its bin/ (kept as
# a fallback so an older checkout, or a bin/ populated from an old release,
# keeps working without a re-fetch).
DECODER_NAMES = ("cttd", "NexRv")


def find_decoder(explicit=None):
    """Locate the trace decoder binary.

    Search order (first match wins). This mirrors scripts/ct_env.sh's own
    resolution (repo bin/, then PATH) so a decoder scripts/ct_env.sh picks
    up is the same one the dashboard uses -- the two used to disagree
    because this function pointed at the predecessor repository's third_party/ layout,
    which does not exist in this repository:

      1. an explicit path (--nexrv / --decoder CLI flag)
      2. the NEXRV environment variable, as exported by
         `. scripts/ct_env.sh` (or set by hand) -- the variable name
         predates the CTTD rename, ct_env.sh in this repo still exports it
      3. repo bin/: bin/cttd(.exe), then the legacy bin/NexRv(.exe)
      4. PATH: cttd(.exe), then the legacy NexRv(.exe)
    """
    exe = ".exe" if os.name == "nt" else ""
    repo_root = HERE.parents[1]     # examples/dashboard -> examples -> repo root
    candidates = []
    if explicit:
        candidates.append(explicit)
    env_nexrv = os.environ.get("NEXRV")
    if env_nexrv:
        candidates.append(env_nexrv)
    # bin/ holds the PINNED file under its platform name
    # (scripts/fetch_cttd.py writes cttd-windows-x64.exe / cttd-linux-x86_64 /
    # cttd-linux-arm64), NOT under a bare "cttd". Without these names the
    # server did not find the freshly fetched decoder and fell back to an old
    # one from PATH -- whereupon every multi-target scenario failed with "No
    # entry in -pcinfo found" although the right decoder was sitting right
    # next to it (measured 2026-08-18 on duo and trio).
    plat = []
    if os.name == "nt":
        plat = ["cttd-windows-x64.exe"]
    else:
        import platform as _pf
        plat = (["cttd-linux-arm64"] if _pf.machine() in ("aarch64", "arm64")
                else ["cttd-linux-x86_64"])
    # Look NEXT TO the dashboard as well: on a board the dashboard is deployed
    # to ~/ctrace_dashboard/ and is precisely NOT inside the repository --
    # there HERE.parents[1] is the home directory and a bin/ next to it does
    # not exist. Measured 2026-08-19 on the KV260: the decoder sitting locally
    # alongside was not found and /api/decode reported "decoder binary not
    # found".
    candidates += [str(HERE / "bin" / n) for n in plat]
    candidates += [str(HERE / "bin" / (name + exe)) for name in DECODER_NAMES]
    candidates += [str(repo_root / "bin" / n) for n in plat]
    candidates += [str(repo_root / "bin" / (name + exe))
                   for name in DECODER_NAMES]
    candidates += [shutil.which(name + exe) or "" for name in DECODER_NAMES]
    for cand in candidates:
        if cand and Path(cand).is_file():
            return cand
    return None


def load_program(bus, data: bytes, target: str = "ram", sc=None) -> int:
    """Halt the core, clear the capture, write an ELF (32/64) or hex into RAM.

    A module function rather than a handler method, so that the startup
    preload (--preload / scenarios.json "preload") takes the same path as
    POST /api/elf -- no second place where loading is defined.
    """
    sc = sc or SC
    size = sc.regions.get(target, (0, RAM_SIZE.get(target, 0)))[1]
    C = sc.co("control")
    B_RUN, B_CLR = sc.cbit("core_run"), sc.cbit("trace_clear")
    # Halt the core of THIS window, not "the core". Core 1 can run via b9
    # while b0 = 0 -- the old sequence (clear b0) would not have stopped the
    # running core, and the write would have stalled inside the AXI
    # transaction (SPEC §10 item 2). Conversely, loading RAM0 must not stop
    # core 1 as well: set_core_run holds exactly one core and re-expresses the
    # run state of the others through their own bits.
    core = sc.gate_core(target)
    if core is not None:
        idx = next((i for i, c in enumerate(sc.cores)
                    if c.get("id") == core.get("id")), 0)
        set_core_run(bus, sc, idx, False)
    ctrl = bus.read("ctrl", C)[0]
    hold = sc.core_run_mask(core) if core is not None else B_RUN
    bus.write("ctrl", C, (ctrl & ~hold) | B_CLR)    # halt + trace_clear
    bus.write("ctrl", C, ctrl & ~(hold | B_CLR))    # release
    total = 0
    if data[:4] == b"\x7fELF":
        for paddr, seg in parse_elf(data):
            if paddr + len(seg) > size:
                raise ValueError("segment 0x%x+0x%x exceeds %d KiB RAM"
                                 % (paddr, len(seg), size // 1024))
            bus.write_block(target, paddr, seg)
            total += len(seg)
    else:  # prog.hex: one 32-bit hex word per line
        words = [int(w, 16) for w in re.findall(r"[0-9a-fA-F]{1,8}", data.decode("ascii", "ignore"))]
        if 4 * len(words) > size:
            raise ValueError("hex image exceeds %d KiB RAM" % (size // 1024))
        bus.write_block(target, 0, struct.pack("<%dI" % len(words), *words))
        total = 4 * len(words)
    if total == 0:
        raise ValueError("no loadable data found")
    return total


# --------------------------------------------------------------------------
# Sink defaults per scenario (found 2026-08-15: visibly nothing arrived in the
# DDR4)
#
# SINK_CTRL is reset-inert (ct_trace_sinks.sv: `sink_ctrl_reg <= '0`) -- that
# is the intended contract, because a sink that starts writing into memory by
# itself after a load would be a surprise. In operation the consequence was:
# the URAM ring always captures, the DDR sink NEVER does, and the DDR4 card
# stood at 0/64 MiB next to a full ring. The earlier proof had set ddr_en by
# hand; no path of the dashboard ever did.
#
# Hence a DATA-DRIVEN default here: a scenario may carry `sink_defaults` in
# scenarios.json, and that state is established after every bind. No scenario
# without the key changes its behaviour (the existing ones do not carry it) --
# the same discipline as with the CTRL offsets: no identifier in the code, no
# effect without an entry.
SINK_BITS = {"ddr_en": 0, "ddr_circ": 2, "uram_oneshot": 3, "pib_en": 4}
SINK_PULSE_MASK = 0x22          # b1 ddr_clear, b5 pib_clear -- NIE dauerhaft
SINK_ARM = {"state": "not attempted"}   # last result, for /api/state


def resmem_ranges():
    """Reserved DDR windows from the device tree -- [] when unreadable.

    The DDR sink is an AXI WRITE master. Arming it on a window that is not
    reserved means overwriting Linux memory -- so the target is checked before
    anything arms automatically, instead of trusting that the RTL reset is
    already right. By hand (the DDR card / ddr_on) everything stays possible
    as before; this check only caps the AUTOMATIC path.
    """
    root = Path("/proc/device-tree/reserved-memory")
    if not root.is_dir():
        return []
    def cells(name, dflt):
        p = root / name
        try:
            return int.from_bytes(p.read_bytes()[:4], "big")
        except OSError:
            return dflt
    ac, sc_ = cells("#address-cells", 2), cells("#size-cells", 2)
    out = []
    for node in sorted(root.iterdir()):
        reg = node / "reg"
        if not reg.is_file():
            continue
        try:
            b = reg.read_bytes()
        except OSError:
            continue
        n = 4 * (ac + sc_)
        for i in range(0, len(b) - n + 1, n):
            base = int.from_bytes(b[i:i + 4 * ac], "big")
            size = int.from_bytes(b[i + 4 * ac:i + n], "big")
            out.append((base, size, node.name))
    return out


def ddr_window_ok(base, size):
    """(ok, note) -- does [base, base+size) lie entirely inside a resmem window?"""
    if not size:
        return False, "DDR_SIZE reads 0 -- no buffer configured"
    rs = resmem_ranges()
    if not rs:
        return False, ("no /proc/device-tree/reserved-memory on this host -- "
                       "cannot prove the window is safe to write")
    for rb, rsz, name in rs:
        if base >= rb and base + size <= rb + rsz:
            return True, ("0x%08X+0x%X inside reserved '%s' (0x%X+0x%X)"
                          % (base, size, name, rb, rsz))
    return False, ("0x%08X+0x%X is NOT inside any reserved-memory window (%s) "
                   "-- refusing to arm a DMA write master into kernel memory"
                   % (base, size,
                      ", ".join("%s 0x%X+0x%X" % (n, b, s) for b, s, n in rs)))


def _ps_reg(addr, value=None):
    """Read (or write) ONE 32-bit PS register through /dev/mem.

    Deliberately separate from the bus objects: those map the PL aperture and
    the reserved DDR window, and both are guarded -- `phys_write` refuses
    anything outside the reserved window, which is exactly right for what it
    guards. The AFIFM registers are neither: they are PS configuration space,
    always present, and touching them cannot wedge the interconnect the way
    an unbacked PL access can.

    32-bit access through ctypes, never a slice assignment: these are device
    mappings, and glibc's memcpy would issue wide/unaligned stores there.
    """
    page = addr & ~0xFFF
    off = addr - page
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
        try:
            cell = ctypes.c_uint32.from_buffer(m, off)
            if value is not None:
                cell.value = value & 0xFFFFFFFF
            return cell.value
        finally:
            del cell
            m.close()
    finally:
        os.close(fd)


def phys_read32(addr):
    return _ps_reg(addr)


def phys_write32(addr, value):
    return _ps_reg(addr, value)


AFIFM2_RDCTRL = 0xFD380000     # saxigp2 = the trace sink's PS port
AFIFM2_WRCTRL = 0xFD380014
AFIFM3_RDCTRL = 0xFD390000     # saxigp3 = the guest memory port
AFIFM3_WRCTRL = 0xFD390014
AFIFM_WIDTH_32 = 0x2           # FABRIC_WIDTH[1:0]: 0 = 128 bit, 1 = 64, 2 = 32
AFIFM_WIDTH_64 = 0x1


def ensure_afifm_32bit():
    """Make the trace sink's PS port 32 bit wide. Returns a step dict.

    WHY THIS EXISTS, AND WHY ITS ABSENCE WAS INVISIBLE (measured 2026-08-19).

    The DDR trace sink is a 32-bit AXI master on `saxigp2`. The PS port it
    lands on resets to **128 bit**, and the one thing that would set it --
    `psu_init` -- does not run for a DFX app. So on a freshly booted board
    the port is wide, the sink's 32-bit beats each occupy a 16-byte slot,
    and the capture in DDR is unreadable: one useful word every four.

    Nothing announces that. `DDR_WPTR` counts up, `DDR_DROPS` stays zero,
    `SINK_STAT` is clean -- every number says the sink is healthy, and only
    a decode attempt (or writing a known pattern into the window first, as
    the finding did) shows the gaps. With the port at 32 bit the same run
    decodes 4,209,664 instructions with zero error messages.

    The board recipes under `boot/` have always set this; the dashboard's
    own `ddr_on`/`arm_sinks` path never did, which is why the sink was
    broken for exactly the people who use the UI.

    This is a PS register, not the PL aperture: it is readable and writable
    whether or not a bitstream is loaded, and it cannot wedge the
    interconnect the way an unbacked PL access can.
    """
    try:
        rd = phys_read32(AFIFM2_RDCTRL)
        wr = phys_read32(AFIFM2_WRCTRL)
    except Exception as e:
        return {"cmd": "afifm2", "rc": 1, "out": "cannot read AFIFM2: %s" % e}
    if (rd & 0x3) == AFIFM_WIDTH_32 and (wr & 0x3) == AFIFM_WIDTH_32:
        return {"cmd": "afifm2", "rc": 0,
                "out": "already 32 bit (rd=0x%08x wr=0x%08x)" % (rd, wr)}
    try:
        phys_write32(AFIFM2_RDCTRL, (rd & ~0x3) | AFIFM_WIDTH_32)
        phys_write32(AFIFM2_WRCTRL, (wr & ~0x3) | AFIFM_WIDTH_32)
        rd2 = phys_read32(AFIFM2_RDCTRL)
        wr2 = phys_read32(AFIFM2_WRCTRL)
    except Exception as e:
        return {"cmd": "afifm2", "rc": 1, "out": "cannot write AFIFM2: %s" % e}
    ok = (rd2 & 0x3) == AFIFM_WIDTH_32 and (wr2 & 0x3) == AFIFM_WIDTH_32
    return {"cmd": "afifm2", "rc": 0 if ok else 1,
            "out": "set to 32 bit (rd 0x%08x->0x%08x, wr 0x%08x->0x%08x)"
                   % (rd, rd2, wr, wr2)}


def ensure_afifm3_64bit():
    """The GUEST MEMORY port, 64 bit. Same reset trap, different victim.

    AFIFM3 carries `saxigp3`, over which a soft core fetches its own code and
    data. Its reset width is 128 bit as well, and `psu_init` does not run for
    a DFX app either -- so on a fresh board a guest core's very first fetch
    goes to a port that does not match, and the core produces nothing at all.
    The repository has said so in plain words for a while
    (`cva6_linux_boot_trace.sh`: "Without this the first CVA6 fetch hangs"),
    and every example that owns a board recipe sets it there.

    `trio` owns none -- it is the only design with a DDR guest that has
    neither a `board/` directory nor an entry in `boot.json`. Measured
    2026-08-19: with the ports at their reset value its CVA6 branch delivered
    **zero** bytes of trace; with AFIFM2 at 32 bit and AFIFM3 at 64 bit the
    same setup delivered 262,144. Nothing in between announced anything.
    """
    try:
        rd = phys_read32(AFIFM3_RDCTRL)
        wr = phys_read32(AFIFM3_WRCTRL)
    except Exception as e:
        return {"cmd": "afifm3", "rc": 1, "out": "cannot read AFIFM3: %s" % e}
    if (rd & 0x3) == AFIFM_WIDTH_64 and (wr & 0x3) == AFIFM_WIDTH_64:
        return {"cmd": "afifm3", "rc": 0,
                "out": "already 64 bit (rd=0x%08x wr=0x%08x)" % (rd, wr)}
    try:
        phys_write32(AFIFM3_RDCTRL, (rd & ~0x3) | AFIFM_WIDTH_64)
        phys_write32(AFIFM3_WRCTRL, (wr & ~0x3) | AFIFM_WIDTH_64)
        rd2 = phys_read32(AFIFM3_RDCTRL)
        wr2 = phys_read32(AFIFM3_WRCTRL)
    except Exception as e:
        return {"cmd": "afifm3", "rc": 1, "out": "cannot write AFIFM3: %s" % e}
    ok = (rd2 & 0x3) == AFIFM_WIDTH_64 and (wr2 & 0x3) == AFIFM_WIDTH_64
    return {"cmd": "afifm3", "rc": 0 if ok else 1,
            "out": "set to 64 bit (rd 0x%08x->0x%08x, wr 0x%08x->0x%08x)"
                   % (rd, rd2, wr, wr2)}


def arm_default_sinks(bus, sc):
    """Bring SINK_CTRL to the scenario's `sink_defaults`. Idempotent.

    Idempotent literally: if the required bits are already set, NOTHING is
    written. A bind must not touch a running sink -- a write to SINK_CTRL
    costs no counters as such, but every unnecessary change to an active
    write master is a change that has to be explained in the protocol.

    The two pulse bits (b1/b5) are ALWAYS masked out: they are W1 pulses, and
    a permanently co-written ddr_clear would wipe the sink's counters on every
    bind.
    """
    want = dict(sc.raw.get("sink_defaults") or {})
    if not want:
        return {"state": "no sink_defaults for scenario %r" % sc.id}
    off = sc.co("sink_ctrl")
    if off is None:
        return {"state": "scenario %r has no SINK_CTRL register" % sc.id}
    unknown = [k for k in want if k not in SINK_BITS]
    if unknown:
        return {"state": "unknown sink_defaults key(s): %s" % ", ".join(unknown)}
    try:
        cur = bus.read("ctrl", off)[0]
    except Exception as e:                       # noqa: BLE001
        return {"state": "SINK_CTRL not readable: %s" % e}
    res = {"before": "0x%X" % cur, "want": want, "wrote": False}
    # Check the target window BEFORE ddr_en is set (only the live bus really
    # writes into memory; the demo bus has no DDR and is not checked).
    if want.get("ddr_en") and not getattr(bus, "demo", False):
        base = bus.read("ctrl", sc.co("ddr_base"))[0] if sc.co("ddr_base") is not None else 0
        size = bus.read("ctrl", sc.co("ddr_size"))[0] if sc.co("ddr_size") is not None else 0
        ok, note = ddr_window_ok(base, size)
        res["ddr_window"] = note
        if not ok:
            res["state"] = "refused: %s" % note
            log_event("warn", "sink defaults NOT applied", res)
            return res
    new = cur & ~SINK_PULSE_MASK
    for k, v in want.items():
        m = 1 << SINK_BITS[k]
        new = (new | m) if v else (new & ~m)
    if new == cur:
        res["state"] = "already armed"
        return res
    bus.write("ctrl", off, new)
    back = bus.read("ctrl", off)[0]
    res.update(wrote=True, after="0x%X" % back, requested="0x%X" % new)
    if back != new:
        # The older app variants do not have the sink window at all: there
        # 0x18..0x38 read as 0 and the write fizzles out. That is not an error,
        # but it must not pass as "armed".
        res["state"] = ("readback 0x%X != 0x%X -- this bitstream variant has no "
                        "sink window (writes are no-ops)" % (back, new))
        log_event("warn", "sink defaults did not stick", res)
    else:
        res["state"] = "armed"
        log_event("event", "sink defaults applied", res)
    return res


def pcinfo_path(t, sc=None, live=False):
    """pcinfo for target t: upload > CLI arg > scenario default in demo/.

    `live=True` prefers a LEAN variant (`pcinfo_<id>_src<t>_live.pcinfo`).
    The reason is measured, not precautionary: NexRv reads the pcinfo in full
    on EVERY call, and that dominates the live path completely. On the KV260
    (Cortex-A53) the 114 MiB listing of the Linux boot costs

        18.06 s per window -- and 18.08 s even with a ZERO-byte trace,

    while the same window with the 775 KiB OpenSBI listing takes 0.14 s. The
    decode itself is practically free in both cases. Without a lean variant
    the live view is therefore unusable on the board.
    """
    sc = sc or SC
    demo = ""
    for tg in sc.decode.get("targets", []):
        if int(tg["id"]) == int(t):
            demo = tg.get("pcinfo", "")
            if live and tg.get("live_pcinfo"):
                demo = tg["live_pcinfo"]
    cands = []
    if live:
        cands += [HERE / ("pcinfo_%s_src%d_live.pcinfo" % (sc.id, t)),
                  HERE / ("pcinfo_src%d_live.pcinfo" % t)]
    cands += [HERE / ("pcinfo_%s_src%d.pcinfo" % (sc.id, t)),
              HERE / ("pcinfo_src%d.pcinfo" % t),
              Path(PCINFO_CLI.get(t, "")) if PCINFO_CLI.get(t) else None,
              (HERE / "demo" / demo) if demo else None,
              (HERE / demo) if demo else None]
    for p in cands:
        if p and p.is_file():
            return p
    return None


# Cap for the raw dump. The DDR window is 256 MiB (address plan v4), so
# `min(wptr, size)` would be a 256 MB HTTP response per click, which the
# server first reads fully into memory (and the decode path then hands on to
# the decoder). On the KV260 that is not a comfort problem but a memory
# question: 256 MiB of payload plus a copy in the response against 4 GiB of
# total memory, while the capture is running.
# The cap therefore takes the NEWEST bytes -- the same semantics as trace_tail
# and the same a ring buffer means. Anyone who needs more says so explicitly
# (?max=), and the response states in its header what it left out.
DUMP_CAP_DEFAULT = 32 << 20        # 32 MiB
DUMP_CAP_MAX = 256 << 20           # explicitly requested maximum


def dump_cap_arg(q):
    """?max=<bytes> -> cap; 0 = as much as allowed (DUMP_CAP_MAX)."""
    raw = (q.get("max") or [None])[0]
    if raw is None:
        return DUMP_CAP_DEFAULT
    n = int(raw, 0)
    if n <= 0:
        return DUMP_CAP_MAX
    return min(n, DUMP_CAP_MAX)


def dump_bytes(bus, src, sc=None, cap=DUMP_CAP_DEFAULT, info=None):
    """Chronological captured trace bytes of a sink (ring/circular aware).

    `cap` caps the output to the NEWEST bytes (0/None = uncapped).
    `info`, when a dict is passed, receives the balance
    (available/returned/capped) -- the caller has to be able to name the
    truncation instead of shipping a truncated file as a complete one.
    """
    sc = sc or SC
    if info is None:
        info = {}

    def done(raw, avail):
        info.update(available=avail, returned=len(raw),
                    capped=len(raw) < avail)
        return raw

    if src == "uram":
        if bus.demo:
            raw = bus.uram_dump()
            return done(raw[-cap:] if cap and len(raw) > cap else raw, len(raw))
        nbytes = bus.read("ctrl", sc.co("trace_bytes"))[0]
        # NOT `cap` -- that is the cap parameter. The ring capacity is called
        # `ring` here; the old double use of the name would have silently set
        # the cap to 1 MiB.
        ring = bus.read("ctrl", sc.co("trace_bufsz"))[0] or TRACE_BRAM
        if nbytes > ring:                      # ring wrapped: [wr..ring)+[0..wr)
            beats = bus.read("ctrl", sc.co("trace_beats"))[0]
            wr = (beats % (ring // 4)) * 4
            w1 = bus.read("trace", wr, (ring - wr) // 4)
            w2 = bus.read("trace", 0, wr // 4)
            raw = (struct.pack("<%dI" % len(w1), *w1)
                   + struct.pack("<%dI" % len(w2), *w2))
        else:
            words = bus.read("trace", 0, (nbytes + 3) // 4) if nbytes else []
            raw = struct.pack("<%dI" % len(words), *words)[:nbytes]
        return done(raw[-cap:] if cap and len(raw) > cap else raw, len(raw))
    if src == "ddr":
        if not sc.sinks.get("ddr"):
            raise ValueError("scenario %r has no DDR sink" % sc.id)
        if bus.demo:
            raw = bus.ddr_dump()
            return done(raw[-cap:] if cap and len(raw) > cap else raw, len(raw))
        base = bus.read("ctrl", sc.co("ddr_base"))[0]
        size = bus.read("ctrl", sc.co("ddr_size"))[0]
        wptr = bus.read("ctrl", sc.co("ddr_wptr"))[0]
        sink = bus.read("ctrl", sc.co("sink_ctrl"))[0]
        stat = bus.read("ctrl", sc.co("sink_stat"))[0]
        held = min(wptr, size)
        if not held:
            return done(b"", 0)
        n = min(held, cap) if cap else held
        # The start of the capped window is rounded UP to the 32-byte edge --
        # that is the sink's burst edge (8-beat INCR from a 32-byte alignment,
        # ct_soc_ddr_sink.sv:138). The dump therefore begins on a burst
        # boundary instead of in the middle of a burst, and it becomes at most
        # 31 bytes SHORTER, never longer than the cap.
        # Alignment happens ONLY when there really is a cap: a full dump has
        # to stay complete, otherwise the cap would start swallowing bytes
        # where nobody asked for it.
        al = lambda v: (v + 31) & ~31                        # noqa: E731
        if (sink & 0x4) and (stat & 0x4):      # circular + wrapped
            # In chronological order the buffer is [off..size) ++ [0..off), so
            # the NEWEST n bytes end at `off` and start n bytes before it --
            # modulo size, because that start can itself wrap around the
            # buffer.
            off = wptr % size
            if n >= held:
                return done(bus.phys_read(base + off, size - off)
                            + bus.phys_read(base, off), held)
            start = al((off - n) % size) % size
            n = (off - start) % size or n
            if start + n <= size:
                return done(bus.phys_read(base + start, n), held)
            return done(bus.phys_read(base + start, size - start)
                        + bus.phys_read(base, n - (size - start)), held)
        if n >= held:
            return done(bus.phys_read(base, held), held)
        start = al(held - n)
        return done(bus.phys_read(base + start, held - start), held)
    raise ValueError("src must be uram or ddr")


def trace_tail(bus, n, sc=None):
    """The last n bytes of the URAM ring, in chronological order."""
    sc = sc or SC
    if bus.demo:
        raw = bus.uram_dump()
        return raw[-n:] if n and len(raw) > n else raw
    nbytes = bus.read("ctrl", sc.co("trace_bytes"))[0]
    cap = bus.read("ctrl", sc.co("trace_bufsz"))[0] or TRACE_BRAM
    held = min(nbytes, cap)
    n = min(n, held)
    if not n:
        return b""
    beats = bus.read("ctrl", sc.co("trace_beats"))[0]
    wr = (beats % (cap // 4)) * 4
    start = (wr - n) % cap if nbytes > cap else max(0, held - n)
    a0 = start & ~3
    n0 = min(n + (start - a0), cap - a0)
    words = bus.read("trace", a0, (n0 + 3) // 4)
    raw = struct.pack("<%dI" % len(words), *words)[start - a0:start - a0 + n]
    if len(raw) < n:                            # remainder from the ring start
        rem = n - len(raw)
        words = bus.read("trace", 0, (rem + 3) // 4)
        raw += struct.pack("<%dI" % len(words), *words)[:rem]
    return raw


def run_decode(raw, targets=None, sc=None, timeout=300, live=False):
    """Run the decoder over raw trace bytes.

    Single-source scenarios (mbv, cva6_linux) are invoked WITHOUT
    `-target`/`-src`, the same way the board scripts do it. Only the trio
    stream carries source tags and needs the multi-target form.
    Returns (summary dict, {target: pcout text bytes}).
    """
    sc = sc or SC
    if not NEXRV or not Path(NEXRV).is_file():
        raise ValueError("decoder binary not found (cttd or legacy NexRv; "
                          "start the server with --decoder/--nexrv, set "
                          "NEXRV, or place it in repo bin/)")
    multi = bool(sc.decode.get("multi_target"))
    srcbits = int(sc.decode.get("srcbits", SRCBITS))
    if targets is None:
        targets = [int(t["id"]) for t in sc.decode.get("targets", [{"id": 0}])]
    td = Path(tempfile.mkdtemp(prefix="ctdeco_"))
    try:
        binf = td / "trace.bin"
        binf.write_bytes(raw)
        cmd = [str(NEXRV), "-deco", str(binf)]
        pcouts = {}
        for t in targets:
            p = pcinfo_path(t, sc, live)
            if not p:
                continue
            o = td / ("core%d.pcout" % t)
            if multi:
                cmd += ["-target", str(t)]
            cmd += ["-pcinfo", str(p), "-pcout", str(o)]
            pcouts[t] = o
        if not pcouts:
            raise ValueError("no pcinfo available -- upload via POST /api/pcinfo?target=<n>")
        if multi:
            cmd += ["-src", str(srcbits)]
        cmd += ["-stat"]
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        dt = time.time() - t0
        out = (r.stdout or "") + (r.stderr or "")
        texts = {t: (o.read_bytes() if o.is_file() else b"")
                 for t, o in pcouts.items()}
        res = {"ok": "Decoded OK" in out, "exit": r.returncode,
               "bytes": len(raw), "srcbits": srcbits if multi else None,
               "multi_target": multi, "scenario": sc.id,
               "seconds": round(dt, 3),
               "mb_per_s": round(len(raw) / dt / 1e6, 3) if dt > 0 else None,
               "pcinfo": {str(t): str(pcinfo_path(t, sc, live)) for t in pcouts},
               "pcs": {str(t): texts[t].count(b"\n") for t in pcouts},
               "log_tail": out.splitlines()[-15:]}
        tot = sum(res["pcs"].values())
        res["instr"] = tot
        res["bits_per_instr"] = round(len(raw) * 8.0 / tot, 3) if tot else None
        res["minstr_per_s"] = round(tot / dt / 1e6, 3) if dt > 0 and tot else None
        return res, texts
    finally:
        shutil.rmtree(td, ignore_errors=True)


class ConsoleReader:
    """Record the guest console ring losslessly and advance the read pointer.

    Two jobs that belong together:

    1. **Recording.** The ring holds CON_BYTES characters. Returning just the
       current ring content on every poll loses everything that was
       overwritten between two polls. So the server keeps a growing buffer of
       its own and appends only what is REALLY new (the difference of the
       monotonic CON_BYTES counter).

    2. **Advancing the read pointer.** The ring drops as soon as the PS falls
       more than one ring length behind. Without the CON_RPTR feedback the
       console would go mute after CON_BYTES characters -- precisely the
       reason the ring was built circular in the first place.

    The write-back doubles as the **capability proof**: only a bitstream WITH
    the RX path has CON_RPTR as a register at all. If the written value does
    not come back, it is an older bitstream and input stays locked --
    regardless of what scenarios.json claims.
    """

    MAX_BUF = 4 << 20        # 4 MiB of session capture, then trim at the front

    def __init__(self):
        self.buf = bytearray()
        self.total = 0
        self.drops = 0
        self.dropped_head = 0     # removed from the front of the buffer
        self.rptr_ok = None       # None = not testable yet
        self.lost = 0             # overwritten by the ring before we read it

    def reset(self):
        self.__init__()

    def poll(self, bus, sc):
        c = sc.console
        if not c:
            raise ValueError("scenario %r has no console" % sc.id)
        total = bus.read("ctrl", sc.co(c["bytes"]))[0]
        do = sc.co(c["drops"])
        self.drops = bus.read("ctrl", do)[0] if do is not None else 0
        if bus.demo:
            self.buf = bytearray(bus.con_dump())
            self.total = total
            return
        cap = int(c.get("size") or sc.regions[c["region"]][1])
        if total < self.total:            # con_clear
            self.buf = bytearray()
            self.total = 0
        new = total - self.total
        if new > 0:
            if new > cap:                 # the ring was faster than we were
                self.lost += new - cap
                new = cap
            start = (total - new) % cap
            need = start + new
            words = bus.read(c["region"], 0, min(cap, ((need if need <= cap else cap) + 3) // 4))
            blob = struct.pack("<%dI" % len(words), *words)
            if need <= cap:
                self.buf += blob[start:start + new]
            else:                         # across the ring boundary
                self.buf += blob[start:cap] + blob[:need - cap]
            self.total = total
            if len(self.buf) > self.MAX_BUF:
                cut = len(self.buf) - self.MAX_BUF
                del self.buf[:cut]
                self.dropped_head += cut
        # advance the read pointer + check the capability
        ro = sc.co(c.get("rptr_reg") or "")
        if ro is not None:
            try:
                bus.write("ctrl", ro, total)
                self.rptr_ok = (bus.read("ctrl", ro)[0] == total) if total else self.rptr_ok
            except (OSError, ValueError, KeyError):
                self.rptr_ok = False


CONREAD = ConsoleReader()


class PacketRate:
    """Message and byte rate from two samples of the monotonic counter.

    The message rate is NOT estimated from the window size but computed from
    the measured byte growth times the density observed in that window
    (messages per byte). The counter is hardware, the density is a
    measurement -- both observed, nothing modelled.
    """

    def __init__(self):
        self.prev = None

    def sample(self, t, trace_bytes, msgs, window_bytes):
        prev, self.prev = self.prev, (t, trace_bytes)
        if prev is None or t <= prev[0] or trace_bytes < prev[1]:
            return {"bytes_per_s": None, "msgs_per_s": None}
        bps = (trace_bytes - prev[1]) / (t - prev[0])
        density = (msgs / window_bytes) if window_bytes else 0
        return {"bytes_per_s": bps,
                "msgs_per_s": bps * density if density else None}


PKTRATE = PacketRate()


def interactive_now(bus, sc=None):
    """Can input get through RIGHT NOW? A property of the loaded bitstream.

    scenarios.json says what the bitstream SHOULD be able to do. Whether it
    can is answered by the CON_RPTR write-back test in ConsoleReader.poll -- a
    bitstream without the RX path does not decode the register at all and
    returns 0. While that test has no verdict yet for lack of output
    (rptr_ok is None) the scenario value stands; in demo mode there is no RX
    path, so never interactive.
    """
    sc = sc or SC
    if not (sc.console and sc.interactive_console):
        return False
    if bus.demo:
        return False
    return True if CONREAD.rptr_ok is None else bool(CONREAD.rptr_ok)


# The ELF classes this dashboard can load. Both core families of the KV260
# stand side by side here, neither of them a special case: RV32 (MBV, TGC5B,
# CVA6 cv32a6) produces ELF32, RV64 (CVA6 cv64a6_imac_sv39, Rocket64t1)
# produces ELF64.
#
# The difference is NOT only the field width -- the program headers have a
# different ORDER. ELF32: type, offset, vaddr, paddr, filesz, memsz, flags.
# ELF64: type, FLAGS, offset, vaddr, paddr, filesz, memsz.
#
# Measured on an RV64 payload: relaxing only the class check while keeping the
# ELF32 layout reads e_phoff=0x0 and e_phnum=0 (instead of 0x40 / 6) and
# therefore finds NO segment -- the load reports "no loadable data found". And
# even at the correct e_phoff, `<6I` yields p_paddr=0 and p_memsz=0 (it keeps
# reading p_flags as p_offset), so the segment falls through the p_memsz==0
# filter. Both times the result is a silent no-op, not an error message.
#
#   Feld       ELF32-Offset/Breite   ELF64-Offset/Breite
#   e_phoff    28 / 4                32 / 8
#   e_phentsz  42 / 2                54 / 2
#   e_phnum    44 / 2                56 / 2
_ELF_CLASS = {
    1: {"name": "ELF32", "phoff": (28, "<I"), "phnum": 42,
        "ph": "<8I", "idx": (0, 1, 3, 4, 5)},        # type, offset, paddr, filesz, memsz
    2: {"name": "ELF64", "phoff": (32, "<Q"), "phnum": 54,
        "ph": "<2I6Q", "idx": (0, 2, 4, 5, 6)},      # same, but p_flags is field 1
}
PT_LOAD = 1


def elf_class(data: bytes):
    """'ELF32' | 'ELF64' for an ELF header, otherwise None (e.g. prog.hex)."""
    if len(data) >= 6 and data[:4] == b"\x7fELF":
        c = _ELF_CLASS.get(data[4])
        if c and data[5] == 1:
            return c["name"]
    return None


def parse_elf(data: bytes):
    """Yield (paddr, bytes) per PT_LOAD segment of a little-endian ELF.

    Covers ELF32 and ELF64 with the same code (table `_ELF_CLASS`); the
    addresses are Python ints and therefore independent of the word width.

    Malformed headers are reported, not skipped over: a segment whose file
    slice does not lie inside the file would otherwise be written to RAM
    silently truncated, and the core would run into garbage. No silent drop.
    """
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    cls = _ELF_CLASS.get(data[4] if len(data) > 4 else 0)
    if cls is None:
        raise ValueError("unknown EI_CLASS %r (need 1=ELF32 or 2=ELF64)"
                         % (data[4] if len(data) > 4 else None))
    if data[5] != 1:
        raise ValueError("need little-endian ELF (EI_DATA=%r)" % data[5])
    off, fmt = cls["phoff"]
    e_phoff, = struct.unpack_from(fmt, data, off)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, cls["phnum"])
    want = struct.calcsize(cls["ph"])
    if e_phentsize < want:
        raise ValueError("%s: e_phentsize %d < %d" % (cls["name"], e_phentsize, want))
    i_type, i_off, i_paddr, i_filesz, i_memsz = cls["idx"]
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        if o + want > len(data):
            raise ValueError("%s: program header %d beyond end of file" % (cls["name"], i))
        f = struct.unpack_from(cls["ph"], data, o)
        if f[i_type] != PT_LOAD or f[i_memsz] == 0:
            continue
        p_off, p_paddr = f[i_off], f[i_paddr]
        p_filesz, p_memsz = f[i_filesz], f[i_memsz]
        if p_filesz > p_memsz:
            raise ValueError("%s: segment %d p_filesz 0x%x > p_memsz 0x%x"
                             % (cls["name"], i, p_filesz, p_memsz))
        if p_off + p_filesz > len(data):
            raise ValueError("%s: segment %d file range 0x%x+0x%x beyond end of file (0x%x)"
                             % (cls["name"], i, p_off, p_filesz, len(data)))
        seg = data[p_off:p_off + p_filesz] + b"\x00" * (p_memsz - p_filesz)
        yield p_paddr, seg


def _run(cmd, timeout=120, env=None):
    """Run a command; `env` is MERGED into the inherited environment.

    Merged, not replaced: kv260_plclk.sh is a /bin/sh script that needs PATH to
    find busybox. Handing it a bare {"MHZ": "68"} would leave it without one.
    """
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           env=(dict(os.environ, **env) if env else None))
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except (OSError, subprocess.SubprocessError) as e:
        return -1, str(e)


def lan_addr():
    """The address the board can be reached at on the local network.

    Determined via the routing table (a UDP `connect` sends nothing) --
    `gethostbyname(hostname)` returns 127.0.1.1 on the Kria and would be
    worthless as a notice in the log.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 9))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


# ---------------------------------------------------------------------------
# Clock, build identity, closure -- the three facts a picture has to PROVE
#
# Until 2026-08-14 the clock sat in the core cards as a static number out of
# scenarios.json (field `mhz`). That is a claim inside the picture: it knows
# neither the board nor the loaded bitstream, and it still read 75 MHz while
# the board was clocking at 100 or 68.182 MHz. Exactly that number was spotted
# in figure 2 of the CTTE paper.
#
# Here the values are read back instead of claimed:
#
#   * pl_clk0 from CRL_APB.PL0_REF_CTRL @ 0xFF5E00C0 -- with the SAME integer
#     division as kv260_plclk.sh (1500000000/(div0*div1)); a different
#     rounding path would yield 68000000 instead of 68181818 and make every
#     comparison fail on a rounding difference;
#   * the identity of the LOADED artefact as the md5 of the .bit.bin that
#     xmutil put into the slot -- the app NAME does not carry, names get
#     reused across rebuilds;
#   * and from those the closure status against kv260_closure.csv, the same
#     registry the closure verifier uses.
#
# The ground rule is the one from the gates: NO EVIDENCE MEANS NO VALUE. Every
# branch that finds nothing returns `null` plus a reason, and the UI then shows
# "—". A substitute value would be precisely the defect this block fixes.
# ---------------------------------------------------------------------------
CRL_PL0_REF_CTRL = 0xFF5E00C0
# PL0_REF_CTRL[2:0] SRCSEL per the ZynqMP TRM. Only the IOPLL rate is proven
# on the board (1500 MHz); for RPLL/DPLL nothing is guessed -- there hz stays
# null and the reason is stated alongside.
_PL_CLK_SRC = {0: ("IOPLL", 1500000000), 1: ("IOPLL", 1500000000),
               2: ("RPLL", None), 3: ("DPLL", None)}
# Record of the SET operation (which value was programmed). It is written by
# the deployment side from the output of kv260_plclk.sh, not typed by hand. If
# it is missing, the UI shows only the read-back value -- a "programmed"
# figure without a record would be guesswork.
PLCLK_RECORD = Path(__file__).resolve().parent / "plclk_programmed.json"
CLOSURE_CSV = Path(__file__).resolve().parent / "kv260_closure.csv"

# --- Expected clock per scenario -------------------------------------------
# Until 2026-08-19 this service only READ pl_clk0. Nobody ever set it: the
# tool for that is in the tree but had never been deployed to the board. The
# consequence, measured 2026-08-19: pl_clk0 stood at 150 MHz while the designs
# are constrained to 71.114 MHz -- `PHASE=prep` of every boot recipe then
# aborts cleanly with PLCLK_WRONG, and in the dashboard the Linux scenarios
# look like "runs empty" although the cause is the clock.
#
# The expected value lives in plclk.json, WITH its source per entry; only the
# mechanics live here. If an entry is missing, nothing is guessed and nothing
# is done silently -- the response states explicitly that the clock was left
# untouched (silent inaction is the dangerous option here).
PLCLK_MAP = Path(__file__).resolve().parent / "plclk.json"
# The three labels kv260_plclk.sh knows, with their divisors. Source:
# examples/kv260/common/board/kv260_plclk.sh, `case "$MHZ"`. The integer
# division is mandatory, not a matter of taste: divisor 22 gives 68181818 Hz,
# a different rounding path gives 68000000 -- and the comparison would then
# fail on a rounding difference instead of on a defect (the same reason as at
# pl_clk0_state above).
PLCLK_DIV = {68: 22, 75: 20, 100: 15}
# Where kv260_plclk.sh may sit on the board. board_dashboard_install.sh puts
# it in /usr/local/share/ctrace/; the two other places cover a copy placed by
# hand next to the server or in /tmp.
PLCLK_TOOL_PATHS = ("kv260_plclk.sh",
                    "/usr/local/share/ctrace/kv260_plclk.sh",
                    "/tmp/kv260_plclk.sh")


def plclk_wanted(sid):
    """The expected entry from plclk.json, or None (no evidence -> no value)."""
    try:
        doc = json.loads(PLCLK_MAP.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    rec = doc.get(sid)
    if not isinstance(rec, dict) or rec.get("mhz") not in PLCLK_DIV:
        return None
    return rec


def plclk_tool():
    """Path to kv260_plclk.sh, or None."""
    for p in PLCLK_TOOL_PATHS:
        q = (Path(__file__).resolve().parent / p) if not p.startswith("/") else Path(p)
        if q.is_file():
            return q
    return None


def set_pl_clk0(mhz, steps):
    """Set pl_clk0. MUST ONLY BE CALLED WHILE THE PL IS UNLOADED.

    A frequency jump under a running design is a clock glitch in the middle of
    the logic; no state is trustworthy afterwards. kv260_plclk.sh checks this
    itself and refuses the change while the slot is occupied -- this code does
    NOT rely on that; the caller keeps the order.
    """
    want_hz = 1500000000 // PLCLK_DIV[mhz]
    tool = plclk_tool()
    if tool is None:
        steps.append({"cmd": "pl_clk0 -> %d MHz" % mhz, "rc": 1,
                      "out": "kv260_plclk.sh not found (looked in %s) -- clock "
                             "NOT changed; run board_dashboard_install.sh"
                             % ", ".join(PLCLK_TOOL_PATHS)})
        return False
    rc, out = _run(["sh", str(tool)], timeout=30, env={"MHZ": str(mhz)})
    got = pl_clk0_state().get("hz")
    ok = (rc == 0 and got == want_hz)
    steps.append({"cmd": "pl_clk0 -> %d MHz (%s)" % (mhz, tool), "rc": 0 if ok else 1,
                  "out": "%s | readback %s Hz, wanted %d Hz"
                         % (out.strip()[-200:], got, want_hz)})
    return ok


def pl_clk0_state():
    """Read pl_clk0 back from the CRL register. A pure PS access."""
    st = {"reg": "0x%08X" % CRL_PL0_REF_CTRL, "raw": None, "srcsel": None,
          "src": None, "div0": None, "div1": None, "clkact": None,
          "hz": None, "error": None}
    try:
        # O_SYNC only exists on POSIX; off the board the open() fails anyway
        # -- this branch should produce a REASON there, not a crash.
        fd = os.open("/dev/mem", os.O_RDWR | getattr(os, "O_SYNC", 0))
    except OSError as e:
        st["error"] = "/dev/mem not readable (%s)" % (e.strerror or e)
        return st
    try:
        page = CRL_PL0_REF_CTRL & ~0xFFF
        m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                      mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
        try:
            # A single 32-bit access as in HwBus.read -- a slice would be a
            # memcpy on a Device-nGnRnE page.
            raw = ctypes.c_uint32.from_buffer(m, CRL_PL0_REF_CTRL - page).value
        finally:
            m.close()
    except (OSError, ValueError) as e:
        st["error"] = "PL0_REF_CTRL read failed (%s)" % e
        return st
    finally:
        os.close(fd)
    st["raw"] = "0x%08X" % raw
    st["clkact"] = (raw >> 24) & 1
    st["div0"] = (raw >> 8) & 0x3F
    st["div1"] = (raw >> 16) & 0x3F
    st["srcsel"] = raw & 0x7
    name, pll_hz = _PL_CLK_SRC.get(st["srcsel"], (None, None))
    st["src"] = name
    if pll_hz is None:
        st["error"] = "clock source %s: rate not established on this board" % (
            name or ("SRCSEL=%d" % st["srcsel"]))
    elif st["div0"] and st["div1"]:
        st["hz"] = pll_hz // (st["div0"] * st["div1"])
    else:
        st["error"] = "divisor 0 -- clock stopped"
    return st


def plclk_programmed():
    """The recorded SET operation, if there was one."""
    try:
        rec = json.loads(PLCLK_RECORD.read_text())
    except (OSError, ValueError):
        return None
    return rec if isinstance(rec, dict) else None


_BITBIN_MD5 = {}     # (path, mtime_ns, size) -> md5


def bitstream_identity(app):
    """md5 of the .bit.bin that sits in the firmware directory for this app."""
    st = {"app": app, "file": None, "size": None, "md5": None, "error": None}
    if not app:
        st["error"] = "no app in the active slot"
        return st
    d = Path("/lib/firmware/xilinx") / app
    cands = sorted(d.glob("*.bit.bin")) if d.is_dir() else []
    if not cands:
        st["error"] = "no .bit.bin under %s" % d
        return st
    p = cands[0]
    try:
        sr = p.stat()
    except OSError as e:
        st["error"] = str(e)
        return st
    st["file"] = p.name
    st["size"] = sr.st_size
    key = (str(p), sr.st_mtime_ns, sr.st_size)
    md5 = _BITBIN_MD5.get(key)
    if md5 is None:
        h = hashlib.md5()
        try:
            with p.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
        except OSError as e:
            st["error"] = str(e)
            return st
        md5 = h.hexdigest()
        _BITBIN_MD5.clear()          # only the current entry counts
        _BITBIN_MD5[key] = md5
    st["md5"] = md5
    return st


def closure_state(bit, clk):
    """Is the clock that was read back inside the closure of THIS artefact?

    The same arithmetic the closure verifier uses:
    achieved = 1000/(target period - WNS), with the target period taken FROM
    THE REPORT.
    """
    st = {"verdict": None, "achieved_mhz": None, "margin_mhz": None,
          "target_ns": None, "wns_ns": None, "report_state": None,
          "note": None}
    if not CLOSURE_CSV.is_file():
        st["verdict"] = "NO_REGISTRY"
        st["note"] = "kv260_closure.csv not deployed next to server.py"
        return st
    row = None
    try:
        with CLOSURE_CSV.open(newline="") as fh:
            for r in csv.DictReader(fh):
                if r.get("app") == (bit or {}).get("app"):
                    row = r
                    break
    except (OSError, csv.Error) as e:
        st["verdict"] = "NO_REGISTRY"
        st["note"] = str(e)
        return st
    if row is None:
        st["verdict"] = "APP_UNKNOWN"
        st["note"] = "app not in the closure registry"
        return st
    st["report_state"] = row.get("report_state") or None
    if not bit.get("md5"):
        st["verdict"] = "NO_BOARD_HASH"
        st["note"] = bit.get("error") or "bitstream not hashable"
        return st
    if row.get("bitbin_md5") != bit["md5"]:
        st["verdict"] = "BITSTREAM_UNMATCHED"
        st["note"] = ("board carries %s, registry holds %s"
                      % (bit["md5"][:8], (row.get("bitbin_md5") or "-")[:8]))
        return st
    if (row.get("report_state") or "") != "Routed":
        st["verdict"] = "NOT_ROUTED"
        return st
    try:
        st["target_ns"] = float(row["target_ns"])
        st["wns_ns"] = float(row["wns_ns"])
        st["achieved_mhz"] = float(row["achieved_mhz"])
        fail = int(row.get("failing_endpoints") or 0)
    except (KeyError, TypeError, ValueError) as e:
        st["verdict"] = "NO_REGISTRY"
        st["note"] = "registry row unreadable (%s)" % e
        return st
    if fail:
        st["verdict"] = "CONSTRAINTS_UNMET"
        st["note"] = "%d failing endpoints in the routed report" % fail
        return st
    if not clk.get("hz"):
        st["verdict"] = "NO_CLOCK"
        st["note"] = clk.get("error") or "pl_clk0 unknown"
        return st
    mhz = clk["hz"] / 1e6
    st["margin_mhz"] = round(st["achieved_mhz"] - mhz, 3)
    st["verdict"] = "OK" if mhz <= st["achieved_mhz"] else "EXCEEDED"
    return st


def board_state():
    """What the board currently has loaded -- and whether the aperture is safe.

    The distinction is not cosmetic: an access to 0xA000_0000 with an
    unprogrammed PL (or with a FOREIGN app in the slot) has no target, hangs
    the AXI interconnect, and the board is dead -- only a power cycle helps
    (found 2026-07-27/28, three frozen boards). `xmutil listapps` says which
    app holds the active slot; only then may anything be read.
    """
    st = {"fpga_state": None, "active_app": None, "apps": [], "safe": False}
    try:
        p = Path("/sys/class/fpga_manager/fpga0/state")
        if p.is_file():
            st["fpga_state"] = p.read_text(errors="replace").strip()
    except OSError:
        pass
    rc, out = _run(["xmutil", "listapps"], timeout=20)
    if rc == 0:
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) >= 2:
                st["apps"].append(f[0])
                if f[-1] not in ("-1", ""):
                    st["active_app"] = f[0]
    st["safe"] = bool(st["active_app"] and st["active_app"] in CAT.by_id_apps())
    # Which core is inside the loaded bitstream? The app name is the only
    # information the PS has about that -- CT_XLEN and the core type appear in
    # no CSR. So this maps rather than guesses.
    owner = CAT.by_app(st["active_app"])
    st["scenario"] = owner.id if owner else None
    var = owner.variant_of(st["active_app"]) if owner else None
    st["variant"] = var
    st["enc_xlen"] = (var or {}).get("enc_xlen")
    st["core_xlen"] = owner.xlen if owner else None
    # The case that silently produces wrong numbers: design A is loaded while
    # the UI reads the CTRL map of design B. It is named, not kept quiet.
    st["matches_active_scenario"] = bool(st["active_app"] and
                                         st["active_app"] in SC.apps)
    # Clock, build identity and closure -- read back, not claimed.
    st["pl_clk"] = pl_clk0_state()
    st["plclk_programmed"] = plclk_programmed()
    st["bitstream"] = bitstream_identity(st["active_app"])
    st["closure"] = closure_state(st["bitstream"], st["pl_clk"])
    return st


def _slots():
    """{app: slot entry} according to `xmutil listapps` -- loaded apps only.

    CAREFUL: this is NOT an occupancy report for the PL slot. The dfx-mgrd
    base design (k26-starter-kits) occupies slot 0 but shows up here with -1
    (measured 2026-08-03) -- see load_app().
    """
    rc, out = _run(["xmutil", "listapps"], timeout=20)
    per_app = {}
    if rc == 0:
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) >= 2 and f[-1] not in ("-1", ""):
                per_app[f[0]] = f[-1]
    return per_app


def load_app(sc, bus_now=None):
    """Load the scenario's bitstream via xmutil -- with proof at the slot.

    Two quirks of dfx-mgr, both measured on the board on 2026-08-03, are
    encoded here; together they had made the board unusable:

    1. `rc == 0` is NOT proof. Measured: xmutil reported "Loaded with
       slot_handle 0", after which `listapps` showed -1 for EVERY app, and the
       next load attempt died in the kernel with "fpga_region region0: Region
       already has overlay applied" (-22). Trusting rc reports success to the
       operator and leaves them staring at a DEMO dashboard. So the slot is
       read back (with a grace period -- dfx-mgrd does not record it at once).
    2. `unloadapp` ALWAYS runs, even when `listapps` shows no occupied slot:
       on startup dfx-mgrd loads its own base design (k26-starter-kits) into
       slot 0 WITHOUT listing it in the slot->handle column. A `loadapp` on
       top of that fails with "Remove previously loaded accelerator, no empty
       slot" -- so that column is not an occupancy proof, only a proof for
       *our* apps. (The converse, "no row occupied => skip the unload", was a
       fallacy and produced exactly this failure.)
    """
    if not sc.app:
        return {"ok": False, "error": "scenario has no app name"}
    if not shutil.which("xmutil"):
        return {"ok": False, "error": "xmutil not available (board only)"}
    steps = []

    # ------------------------------------------------------------------
    # BEFORE unloading: quiesce the trace path of the design that is STILL
    # loaded.
    #
    # Reproduced on 2026-08-19 in a soak run: the hang occurred exactly where
    # the same app was loaded a second time -- immediately after
    # trace_on -> run -> stop. `stop` only clears core_run; the ENCODER stays
    # on and an armed DDR sink remains an active AXI write master. `xmutil
    # unloadapp` then pulls the ground out from under the design while a
    # transaction is open -- and the interconnect hangs, which only a power
    # cycle resolves.
    #
    # Hence: sinks off first, then the encoder off, then halt the cores -- and
    # only then unload. Every step is deliberately FAULT TOLERANT: if one fails
    # (a foreign design in the slot, a register map that does not match, a bus
    # that is already gone), it is logged and the sequence continues; aborting
    # here would be worse, because then nothing would be unloaded at all.
    def quiesce_current():
        if bus_now is None or getattr(bus_now, "demo", False):
            return
        try:
            C = SC.co("control")
            so = SC.co("sink_ctrl")
            if so is not None:
                cur = bus_now.read("ctrl", so)[0]
                # drop ddr_en (b0) and pib_en (b4), mask the pulse bits
                bus_now.write("ctrl", so, cur & ~SINK_PULSE_MASK & ~0x11)
                steps.append({"cmd": "quiesce sinks", "rc": 0,
                              "out": "SINK_CTRL 0x%X -> 0x%X" % (cur, cur & ~SINK_PULSE_MASK & ~0x11)})
            for e in [r for r in ("enc", "enc1", "enc2") if r in SC.regions]:
                t = bus_now.read(e, 0)[0]
                bus_now.write(e, 0, rmw_value(e, 0, t & ~(TE_ENABLE | TE_ITRACE)))
                steps.append({"cmd": "quiesce %s" % e, "rc": 0, "out": "0x%08X -> Enable/ITrace off" % t})
            if C is not None:
                ctrl = bus_now.read("ctrl", C)[0]
                mask = 0
                for c in SC.cores:
                    for b in SC.core_run_bits(c):
                        bb = SC.cbit(b)
                        if bb:
                            mask |= bb
                bus_now.write("ctrl", C, ctrl & ~mask)
                steps.append({"cmd": "quiesce cores", "rc": 0,
                              "out": "CONTROL 0x%X -> 0x%X" % (ctrl, ctrl & ~mask)})
        except Exception as e:                    # noqa: BLE001
            steps.append({"cmd": "quiesce", "rc": 1, "out": "skipped: %s" % e})

    # ------------------------------------------------------------------
    # IS THE WANTED APP ALREADY THERE? Then do NOT reload.
    #
    # Reproduced twice (2026-08-19, soak logs): the board hangs precisely when
    # the SAME app is loaded a second time -- an unloadapp+loadapp onto a
    # design that is already in the slot. Both times at the same place:
    # `cva6_2_rv32` was the last scenario of one round and the first of the
    # next.
    #
    # The obvious explanation (the trace path is still active during the
    # unload) is REFUTED: the second run had quiesced encoder, sinks and cores
    # beforehand and hung at the same place regardless. What remains is the
    # load/unload cycle itself -- and it is not needed here at all: if the app
    # is already in the slot, doing nothing is the right outcome.
    want = plclk_wanted(getattr(sc, "id", "") or "")
    already = _slots().get(sc.app)
    if already:
        steps.append({"cmd": "already loaded", "rc": 0,
                      "out": "%s in slot %s -- no unload/load" % (sc.app, already)})
        note = ("app was already in the slot; reloading the SAME app has "
                "wedged the AXI bus twice (2026-08-19), so it is skipped")
        # The clock canNOT be set in this branch -- it may only change
        # between unloadapp and loadapp, and nothing is unloaded here on
        # purpose. If it does not match, the right answer is a NAMED hint:
        # unloading for the sake of a clock change would be exactly the
        # load/unload cycle that wedged the bus twice.
        if want:
            got = pl_clk0_state().get("hz")
            need = 1500000000 // PLCLK_DIV[want["mhz"]]
            if got is not None and got != need:
                hint = ("app already loaded, pl_clk0 is %d Hz, scenario needs "
                        "%d Hz (label %d MHz) -- unload manually "
                        "(xmutil unloadapp) to change it" % (got, need, want["mhz"]))
                steps.append({"cmd": "pl_clk0 check", "rc": 1, "out": hint})
                note += "; " + hint
        return {"ok": True, "app": sc.app, "slot": already, "steps": steps,
                "note": note}

    quiesce_current()

    def attempt():
        rc, out = _run(["xmutil", "unloadapp"], timeout=60)
        steps.append({"cmd": "unloadapp", "rc": rc, "out": out.strip()[-300:]})
        time.sleep(1.0)
        # HERE and only here the PL is unloaded -- the one moment at which
        # pl_clk0 may change. A failure does NOT abort the load: the design
        # then runs at the wrong clock and `prep` says so with PLCLK_WRONG,
        # which is far better than an app that never gets loaded at all and a
        # dashboard stuck in DEMO.
        if want:
            set_pl_clk0(want["mhz"], steps)
        else:
            steps.append({"cmd": "pl_clk0", "rc": 0,
                          "out": "no entry in plclk.json for scenario %r -- "
                                 "clock left untouched"
                                 % (getattr(sc, "id", "") or "?")})
        rc, out = _run(["xmutil", "loadapp", sc.app], timeout=120)
        steps.append({"cmd": "loadapp " + sc.app, "rc": rc, "out": out.strip()[-300:]})
        for _ in range(5):
            time.sleep(1.5)
            slot = _slots().get(sc.app)
            if slot:
                return slot
        return None

    slot = attempt()
    if not slot:
        # A measured way out (2026-08-03): after several load/unload cycles
        # dfx-mgrd gets into a state where `loadapp` reports success but NEVER
        # records the slot -- watched for eight seconds, from a plain root
        # shell as well. Restarting the daemon resets it; afterwards the same
        # sequence records the slot again (observed three times). The order
        # matters: restart first, then unload+load.
        rc, out = _run(["systemctl", "restart", "dfx-mgr"], timeout=60)
        steps.append({"cmd": "restart dfx-mgr", "rc": rc, "out": out.strip()[-200:]})
        time.sleep(5.0)
        slot = attempt()
    ok = bool(slot)
    if ok:
        # SETTLING TIME AFTER THE SLOT PROOF. `listapps` records the slot
        # before the design necessarily answers on the bus -- the repository
        # documents that unreliability itself (README trap 3: "a loadapp that
        # looks successful is not a proof"). If the first register access
        # falls into that gap, the AXI interconnect hangs and the board is
        # only reachable through the power switch; it happened twice on
        # 2026-08-18. The pause is NOT a proof that the design is ready --
        # there is no consequence-free probe access on this platform. It is
        # the cheapest measure against the observed window; whoever does not
        # want it sets CTTE_SETTLE=0.
        settle = float(os.environ.get("CTTE_SETTLE", "2.0"))
        if settle > 0:
            time.sleep(settle)
            steps.append({"cmd": "settle", "rc": 0, "out": "%.1fs" % settle})
    res = {"ok": ok, "app": sc.app, "slot": slot, "steps": steps}
    if not ok:
        res["error"] = ("xmutil reports success, but `listapps` assigns no "
                        "slot to the app -- dfx-mgr/overlay state is wedged "
                        "(dmesg: 'Region already has overlay applied', "
                        "journalctl -u dfx-mgr). The only safe way out is a "
                        "board reboot; until then the dashboard stays in "
                        "DEMO (PL_GUARD) and the board takes no damage")
    log_event("event" if ok else "error", "xmutil loadapp %s" % sc.app,
              {"ok": ok, "slot": slot, "steps": steps})
    return res


def nexrv_state():
    return {"path": NEXRV, "available": bool(NEXRV and Path(NEXRV).is_file())}


# --------------------------------------------------------------------------
# Build stamp of the served user interface
#
# The reason is a real confusion: on 2026-08-15 someone operated a page whose
# write lock did not bite -- while the service had demonstrably been carrying
# the newer state for over an hour (md5 of the served files == the git blob,
# and /api/write answered correctly with 409). A browser tab loads index.html
# and regmap.json EXACTLY ONCE; after a deployment the tab keeps running the
# old logic while the server already has the new one. Without a visible
# marker that is indistinguishable from a real defect -- and one looks in the
# server for a fault that lives in the browser.
#
# Hence: a short hash over the served files, computed once at startup (they do
# not change while the service runs) and delivered with EVERY /api/state. The
# page remembers the value of its first request and speaks up as soon as it
# changes.
UI_FILES = ("index.html", "wp.html", "regmap.json", "block_csrs.json",
            "scenarios.json", "server.py")
_UI_BUILD = None


def ui_build_id():
    """Short hash over the served files -- '?' when they cannot be read."""
    global _UI_BUILD
    if _UI_BUILD is None:
        h = hashlib.md5()
        for name in UI_FILES:
            p = HERE / name
            h.update(name.encode())
            h.update(p.read_bytes() if p.is_file() else b"-")
        _UI_BUILD = h.hexdigest()[:8]
    return _UI_BUILD


def coverage_tree(sc, top_prefixes=14):
    """Hierarchy for the coverage treemap: region -> name prefix -> function.

    **Area and colour encode DIFFERENT things**, otherwise the map would be a
    bar chart drawn twice: the area is the static size (how much code there
    is), the colour the executed instructions (how much of it ran). Only that
    way does the map show what did NOT execute -- which is the actual question
    in coverage.

    Grouping is by address region (from the scenario) and then by the name
    prefix up to the first '_'. That is not a real module structure -- no
    symbol table has one -- but for C code a surprisingly good approximation
    (`sbi_*`, `fdt_*`, `uart8250_*`).
    """
    st = INS.symbols
    if not st.count:
        return {"regions": [], "note": "no symbol table loaded"}
    # Fallback region: the WHOLE address space, not the lower 4 GiB. The old
    # value (base 0, size 0xFFFFFFFF) silently threw every symbol above 4 GiB
    # out of the map on an RV64 core -- and that is exactly where the Sv39
    # kernel lives (0xFFFFFFC0_00000000). A map that keeps symbols to itself
    # is worse than no map.
    regions = sc.raw.get("code_regions") or [
        {"name": "Code", "base": 0, "size": 1 << 64}]
    parsed = []
    for r in regions:
        b = int(r["base"], 0) if isinstance(r["base"], str) else int(r["base"])
        s = int(r["size"], 0) if isinstance(r["size"], str) else int(r["size"])
        parsed.append({"name": r["name"], "lo": b, "hi": b + s,
                       "groups": {}, "size": 0, "instr": 0, "seen": 0,
                       "funcs": 0})
    counts = INS.func_counts
    clamped = 0
    outside = 0
    for name, addr, size, was_clamped in st.sizes():
        if size <= 0:
            continue
        reg = None
        for r in parsed:
            if r["lo"] <= addr < r["hi"]:
                reg = r
                break
        if reg is None:
            # Not dropped silently: counted and reported. A symbol outside
            # every code_region means the scenario's address plan does not
            # cover reality (typically after a kernel relocation, or when the
            # Sv39 range is missing).
            outside += 1
            continue
        if was_clamped:
            clamped += 1
        instr = counts.get(addr, 0)
        pfx = name.split("_")[0] if "_" in name else name
        g = reg["groups"].setdefault(pfx, {"name": pfx, "size": 0, "instr": 0,
                                           "funcs": [], "seen": 0})
        g["size"] += size
        g["instr"] += instr
        # `addr` goes out as a HEX STRING, not as a number. JSON numbers
        # become IEEE-754 doubles in the browser: an Sv39 kernel address
        # (0xFFFFFFC0_... = 1.8e19) loses its low bits there before any JS code
        # touches it. See test_addr64.mjs.
        g["funcs"].append({"name": name, "addr": "0x%x" % addr,
                           "size": size, "instr": instr})
        g["seen"] += 1 if instr else 0
        reg["size"] += size
        reg["instr"] += instr
        reg["funcs"] += 1
        reg["seen"] += 1 if instr else 0
    out = []
    for r in parsed:
        if not r["size"]:
            continue
        gs = sorted(r["groups"].values(), key=lambda g: -g["size"])
        keep, rest = gs[:top_prefixes], gs[top_prefixes:]
        if rest:
            # The remainder is summarised rather than dropped -- a map that
            # silently withholds area lies about the total size.
            merged = {"name": "other (%d)" % len(rest), "size": 0, "instr": 0,
                      "funcs": [], "seen": 0}
            for g in rest:
                merged["size"] += g["size"]
                merged["instr"] += g["instr"]
                merged["seen"] += g["seen"]
                merged["funcs"] += g["funcs"]
            keep.append(merged)
        for g in keep:
            g["funcs"].sort(key=lambda f: -f["size"])
            del g["funcs"][512:]        # cap per group, otherwise the JSON grows huge
        out.append({"name": r["name"], "size": r["size"], "instr": r["instr"],
                    "funcs": r["funcs"], "seen": r["seen"], "groups": keep})
    return {
        "regions": out,
        "total_instr": INS.total_instr,
        "windows": INS.windows,
        "clamped": clamped,
        "outside_regions": outside,
        "max_func_bytes": st.MAX_FUNC_BYTES,
        "scope": "Function-level coverage over %d decoded windows (%d instructions). "
                 "Area = static size, colour = executed instructions. "
                 "NOT instruction-accurate and NOT over the whole run.%s%s"
                 % (INS.windows, INS.total_instr,
                    (" %d symbols span an address gap and are capped at %d B "
                     "-- their area is an estimate."
                     % (clamped, st.MAX_FUNC_BYTES)) if clamped else "",
                    (" %d symbols lie outside every code_region of this scenario "
                     "and are NOT in the map." % outside) if outside else ""),
    }


def load_symbol_files(sc, symbols=None, sites=None):
    """Load the scenario's symbol table and its call/return sites.

    Both are optional: without symbols the live view shows addresses instead
    of names, without sites the call depth stays empty (with a reason given)
    -- both of which are better than a wrong number.
    """
    out = {"symbols": 0, "sites": 0}
    for cand in ([Path(symbols)] if symbols else []) + \
            [HERE / ("symbols_%s.map" % sc.id)] + \
            ([HERE / sc.symbols] if sc.symbols else []):
        if cand.is_file():
            out["symbols"] = INS.load_symbols(cand).count
            break
    else:
        # If NO table is found, the old one is discarded rather than kept.
        # Measured 2026-08-08: after switching cva6_linux -> cva6_linux64 the
        # RV32 table (83,074 symbols) was still hanging around in the server
        # and the coverage map showed 41,911 RV32 functions under the RV64
        # region names -- plausible-looking and completely wrong. A scenario
        # without symbols of its own shows addresses, not the names of its
        # predecessor.
        INS.set_symbols_text("", None)
    for cand in ([Path(sites)] if sites else []) + \
            [HERE / ("sites_%s.map" % sc.id)] + \
            ([HERE / sc.sites] if sc.sites else []):
        if cand.is_file():
            out["sites"] = INS.load_sites(cand).count
            break
    else:
        INS.sites = type(INS.sites)()       # empty call sites, nothing inherited
    return out


def read_core_pc(bus, sc):
    """The last retired PC from HARDWARE -- 64 bit, read without a tear.

    Two things can go wrong here, and both would be silent:

    1. **A tear between the halves.** PC_LO and PC_HI are two separate 32-bit
       reads while the core keeps running. If a 4 GiB carry falls exactly
       between them, the result is a PC the core never executed. Hence
       HI-LO-HI with a retry, as for any split counter (the rdtime pattern).

    2. **The value as a JSON number.** An Sv39 address exceeds 2**53 and would
       be rounded in the browser before anyone displays it. So `pc` goes out
       as a hex string (see test_addr64.mjs).

    Returns None when this design has no observation channel -- a missing
    capability is not presented as 0.
    """
    cp = sc.raw.get("core_pc")
    if not cp:
        return None
    o_lo, o_hi = sc.co(cp.get("lo", "")), sc.co(cp.get("hi", ""))
    if o_lo is None or o_hi is None:
        return None
    M = 0xFFFFFFFF
    hi = bus.read("ctrl", o_hi)[0] & M
    lo, retries, stable = 0, 0, False
    for _ in range(4):
        lo = bus.read("ctrl", o_lo)[0] & M
        hi2 = bus.read("ctrl", o_hi)[0] & M
        if hi2 == hi:
            stable = True
            break
        hi, retries = hi2, retries + 1
    # `torn` stays TRUE when a tear occurred and only the retry produced a
    # consistent pair. Clearing it on success would be the comfortable but
    # wrong variant: the viewer would then never learn that the value needed a
    # second attempt -- and a PERSISTENT tear (a core running quickly across a
    # 4 GiB boundary) would look like a quiet value.
    out = {"pc": "0x%x" % ((hi << 32) | lo), "torn": retries > 0,
           "retries": retries, "stable": stable}
    o_ret = sc.co(cp.get("retires", ""))
    if o_ret is not None:
        out["retires"] = bus.read("ctrl", o_ret)[0]
    st = bus.read("ctrl", sc.co("status"))[0] if sc.co("status") is not None else 0
    if cp.get("priv_bits"):
        out["priv"] = (st >> int(cp["priv_lsb"])) & ((1 << int(cp["priv_bits"])) - 1)
    if cp.get("obs_bits"):
        obs = (st >> int(cp["obs_lsb"])) & ((1 << int(cp["obs_bits"])) - 1)
        out["obs"] = [n for i, n in enumerate(cp.get("obs_names", [])) if obs >> i & 1]
        out["obs_raw"] = obs
    we = cp.get("win_err")
    if we:
        c = sc.co(we.get("count", ""))
        if c is not None:
            wl, wh = sc.co(we.get("lo", "")), sc.co(we.get("hi", ""))
            out["win_err"] = {
                "count": bus.read("ctrl", c)[0],
                "sticky": bool(st >> int(we.get("sticky_bit", 2)) & 1),
                "was_write": bool(st >> int(we.get("was_write_bit", 3)) & 1),
                "addr": ("0x%x" % ((bus.read("ctrl", wh)[0] << 32)
                                   | bus.read("ctrl", wl)[0]))
                        if (wl is not None and wh is not None) else None,
            }
    return out


def build_poll(sc):
    """Poll set from the scenario: CTRL registers by NAME (not by offset),
    plus the core CSRs of every encoder that exists.

    A register this app does not have drops out here instead of being read at
    an offset where this app keeps something else.
    """
    poll = [(k, "ctrl", off) for k, off in sc.ctrl.items()]
    ENC_CORE = [("trTeControl", 0x000), ("trTeImpl", 0x004),
                ("trTeInstFeatures", 0x008), ("trTeInstFilters", 0x00C),
                ("trTeDataControl", 0x010),
                ("trTsControl", 0x040), ("trTsLow", 0x048), ("trTsHigh", 0x04C),
                ("trTeCsrControl", 0xE00), ("trTeTipFifoStatus", 0xE04),
                ("trTeSyncStatus", 0xE08),
                ("trAtbBridgeControl", 0x1000), ("trAtbBridgeImpl", 0x1004),
                ("trPcControl", 0x3000), ("trWpControl", 0x4000),
                ("trDfControl", 0x5000)]
    ENC_EXTRA = [("trTeControl", 0x000), ("trTeInstFeatures", 0x008),
                 ("trTeInstFilters", 0x00C), ("trTeTipFifoStatus", 0xE04),
                 ("trAtbBridgeControl", 0x1000)]
    for name, off in ENC_CORE:
        if "enc" in sc.regions:
            poll.append((name, "enc", off))
    for rg, sfx in (("enc1", "1"), ("enc2", "2")):
        if rg in sc.regions:
            for name, off in ENC_EXTRA:
                poll.append((name + sfx, rg, off))
    return poll


def make_handler(buses):
    POLL_CACHE = {}

    def POLL_FOR(sc):
        if sc.id not in POLL_CACHE:
            POLL_CACHE[sc.id] = build_poll(sc)
        return POLL_CACHE[sc.id]

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def _json(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _file(self, path, ctype):
            body = (HERE / path).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            # Having no cache header was a DEFECT, not an omission: without
            # Cache-Control/ETag/Last-Modified the browser may cache
            # heuristically, and that is exactly what it did. On 2026-08-10,
            # after several hash-verified deployments, the old page was still
            # showing -- the artefact at the target was right, the display was
            # not. A dashboard that has to be reloaded by hand for a
            # deployment to take effect is a trap for everyone who uses it.
            self.send_header("Cache-Control", "no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.end_headers()
            self.wfile.write(body)

        def _bin(self, body: bytes, fname: str, ctype="application/octet-stream",
                 extra=None):
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Disposition",
                             'attachment; filename="%s"' % fname)
            self.send_header("Cache-Control", "no-store")
            # Extra headers: this is where the raw dump states how much it
            # left out. A truncated file without that statement cannot be
            # told apart from a complete one.
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            bus = buses.current
            try:
                if u.path in ("/", "/index.html"):
                    self._file("index.html", "text/html; charset=utf-8")
                elif u.path in ("/wp", "/wp.html"):
                    self._file("wp.html", "text/html; charset=utf-8")
                elif u.path == "/regmap.json":
                    self._file("regmap.json", "application/json")
                elif u.path == "/themes.json":
                    self._file("themes.json", "application/json")
                elif u.path == "/block_csrs.json":
                    # block->CSR relevance of the architecture view (H3 finding 7)
                    self._file("block_csrs.json", "application/json")
                elif u.path == "/api/scenarios":
                    self._json(dict(CAT.list_json(),
                                    board=board_state(), nexrv=nexrv_state()))
                elif u.path == "/api/state":
                    vals = {k: bus.read(rg, off)[0] for k, rg, off in POLL_FOR(SC)}
                    vals["demo"] = bus.demo
                    vals["mode"] = buses.mode()
                    vals["scenario"] = SC.id
                    vals["live_available"] = buses.hw_bus is not None
                    vals["t"] = time.time()
                    # Build stamp: a page that has been open longer than the
                    # last deployment recognises that by itself.
                    vals["ui_build"] = ui_build_id()
                    # What the bind did with the sinks -- so that the DDR card
                    # can state a reason instead of only "0 B".
                    vals["sink_arm"] = SINK_ARM.get("state")
                    # The build FROM THE BITSTREAM: the header should no
                    # longer claim what the generator compiled, but show what
                    # the hardware says about itself.
                    if "enc" in SC.regions:
                        vals["caps_hw"] = read_discovery(bus, "enc")
                    # The raw dump's cap: the UI should be able to STATE the
                    # number rather than assert it a second time -- another
                    # value in the HTML would be the next thing to drift.
                    vals["dump_cap"] = DUMP_CAP_DEFAULT
                    # Byte rate from two samples of the monotonic counter --
                    # measured, not modelled.
                    tb = vals.get("trace_bytes")
                    if tb is not None:
                        bps = INS.note_counters(vals["t"], tb)
                        vals["trace_bytes_per_s"] = bps
                    # Fine-window bpi: maximum and mean of the 10 ms windows
                    # since the last request. The request EMPTIES the buffer --
                    # so every point of the curve covers exactly one poll
                    # interval and nothing is counted twice.
                    vals["bpi_win"] = bpi_snapshot()
                    # Hardware PC: only where the design has one. If the
                    # observation channel is missing, nothing appears here --
                    # not a 0x0.
                    cpc = read_core_pc(bus, SC)
                    if cpc is not None:
                        vals["core_pc"] = cpc
                    self._json(vals)
                elif u.path == "/api/console":
                    since = int(q.get("since", ["0"])[0], 0)
                    CONREAD.poll(bus, SC)
                    raw = bytes(CONREAD.buf)
                    chunk = raw[since:] if since < len(raw) else b""
                    live = interactive_now(bus)
                    self._json({
                        "since": since, "total": CONREAD.total, "held": len(raw),
                        "drops": CONREAD.drops, "next": len(raw),
                        "lost": CONREAD.lost, "trimmed": CONREAD.dropped_head,
                        "text": chunk.decode("utf-8", "replace"),
                        "interactive": live,
                        "capacity": int((SC.console or {}).get("size") or 0),
                        "note": (SC.console or {}).get("note_readonly")
                                if not live else None,
                    })
                elif u.path == "/api/livepc":
                    self._json(self._livepc(bus, q))
                elif u.path == "/api/insight":
                    self._json(INS.to_json())
                elif u.path == "/api/packets":
                    tail = min(int(q.get("tail", ["65536"])[0], 0), 1 << 20)
                    raw = trace_tail(bus, tail, SC)
                    counts, msgs, idle, ok = insight.scan_messages(raw)
                    tb = bus.read("ctrl", SC.co("trace_bytes"))[0]
                    now = time.time()
                    rate = PKTRATE.sample(now, tb, msgs, len(raw))
                    rows = sorted(
                        ({"tcode": t, "name": insight.TCODE_NAMES.get(t, "TCODE %d" % t),
                          "count": c, "share": c / msgs if msgs else 0}
                         for t, c in counts.items()),
                        key=lambda r: -r["count"])
                    self._json({
                        "window": len(raw), "messages": msgs, "idle_bytes": idle,
                        "aligned": ok, "rows": rows,
                        "bytes_per_msg": (len(raw) - idle) / msgs if msgs else None,
                        "trace_bytes": tb, **rate,
                    })
                elif u.path == "/api/wp/status":
                    st = WPV.status_json(bus, bus.demo)
                    # The slot count of the scenario map NEXT TO the one the
                    # bitstream states itself (trWpCap.Entries@0x4020). Until
                    # now only the maintained number from scenarios.json stood
                    # there -- a map belonging to a different build therefore
                    # went unnoticed. It is NOT replaced: the map still caps
                    # the load path, the hardware number is the cross-check
                    # against it.
                    if "enc" in SC.regions:
                        d = read_discovery(bus, "enc")
                        st["wp_slots_hw"] = d["wp_slots"]
                        st["caps_ok"] = d["ok"]
                        if not d["ok"]:
                            st["caps_mismatch"] = d["mismatch"]
                    self._json(st)
                elif u.path == "/api/wp/records":
                    n = min(int(q.get("n", ["100"])[0], 0), 1000)
                    self._json(WPV.records_json(n))
                elif u.path == "/api/coverage":
                    self._json(coverage_tree(SC))
                elif u.path == "/api/symbols":
                    self._json({"count": INS.symbols.count,
                                "source": INS.symbols.source,
                                "expected": SC.symbols})
                elif u.path == "/api/sensors":
                    # Readable independently of the PL state (see read_sensors).
                    self._json(read_sensors())
                elif u.path == "/api/mode":
                    self._json({"mode": buses.mode(),
                                "live_available": buses.hw_bus is not None,
                                "live_error": buses.live_error})
                elif u.path == "/api/dump":
                    src = q.get("src", ["uram"])[0]
                    # Capped to the NEWEST bytes. The file name carries the
                    # marker `_tail` so that a truncated file is not later read
                    # as a full dump -- a cut recording otherwise looks like a
                    # recording that simply stopped earlier.
                    info = {}
                    raw = dump_bytes(bus, src, cap=dump_cap_arg(q), info=info)
                    log_event("event", "dump %s" % src,
                              dict(info, bytes=len(raw)))
                    self._bin(raw, "trace_%s_%s%s.bin"
                              % (src, time.strftime("%Y%m%d_%H%M%S"),
                                 "_tail" if info.get("capped") else ""),
                              extra={"X-Dump-Available": str(info.get("available", len(raw))),
                                     "X-Dump-Returned": str(len(raw)),
                                     "X-Dump-Capped": "1" if info.get("capped") else "0"})
                elif u.path == "/api/decode":
                    src = q.get("src", ["uram"])[0]
                    # Demo: decode the FULL demo capture (deterministic; the
                    # live windows may start mid-message after ring wraps).
                    if bus.demo and getattr(bus, "stream", None):
                        raw, note = bus.stream, "demo capture (full file)"
                    else:
                        # The same cap as for the raw dump: the decoder reads
                        # the buffer in one piece, and 256 MiB there is not a
                        # longer run but an unusable one.
                        dinfo = {}
                        raw = dump_bytes(bus, src, cap=dump_cap_arg(q),
                                         info=dinfo)
                        note = ("newest %d of %d bytes (server dump cap; "
                                "?max=0 for the full buffer)"
                                % (dinfo["returned"], dinfo["available"])
                                ) if dinfo.get("capped") else None
                    res, texts = run_decode(raw)
                    res["src"], res["note"] = src, note
                    log_event("event", "decode %s" % src,
                              {"ok": res["ok"], "bytes": res["bytes"],
                               "pcs": res["pcs"]})
                    if "pcout" in q:
                        t = int(q["pcout"][0])
                        self._bin(texts.get(t, b""), "core%d.pcout.txt" % t,
                                  "text/plain; charset=utf-8")
                    else:
                        self._json(res)
                elif u.path == "/api/boot":
                    self._json(boot_status())
                elif u.path == "/api/events":
                    n = min(int(q.get("n", ["200"])[0], 0), 4000)
                    self._json({"events": read_events(n)})
                elif u.path == "/api/read":
                    region = q.get("region", ["enc"])[0]
                    off = int(q.get("off", ["0"])[0], 0)
                    n = min(int(q.get("n", ["1"])[0], 0), 4096)
                    # Scenario regions, NOT a module global: `REGIONS` existed
                    # before the switch to scenarios; the leftover name raised
                    # a NameError in live operation -> the register panel and
                    # writes in the GUI were dead ("live does nothing",
                    # 2026-08-03).
                    base, size = REGIONS_OF(SC)[region]
                    if off < 0 or off + 4 * n > size or off % 4:
                        raise ValueError("range")
                    # The PG080 FIFO windows are locked here. An RDFD read
                    # POPS a record -- a curious look through the API eats
                    # exactly the data the drain will then never see. The drain
                    # in wp_view.py reads directly over the bus and is not
                    # affected.
                    if region in DESTRUCTIVE_READ_REGIONS:
                        raise ValueError(
                            "region %r is not readable through this endpoint: "
                            "reading the PG080 RDFD window is DESTRUCTIVE (every "
                            "read pops a record, SPEC_axis_wp_memory_map.md §4). "
                            "Use /api/wp/status and /api/wp/records -- the "
                            "server-side drain is the only reader." % region)
                    # The window of a RUNNING core would stall the AXI
                    # transaction, not merely return nonsense.
                    hold = region_hold_reason(bus, SC, region)
                    if hold:
                        log_event("warn", "read refused", {"region": region,
                                                           "reason": hold})
                        self._json({"error": hold}, 409)
                        return
                    self._json({"region": region, "off": off, "words": bus.read(region, off, n)})
                elif u.path == "/api/trace":
                    # Ring-aware: `tail=N` returns the last N bytes of the
                    # capture in chronological order (recommended); `off`/`n`
                    # keep the legacy linear window into the buffer.
                    # For the download-and-decode-locally workflow use
                    # /api/dump instead: a `tail` window starts in the middle
                    # of a message and the decoder rejects it ("Message must
                    # start from MSEO='00'"; measured 2026-08-03, error #1 on
                    # ring_tail.bin).
                    nbytes = bus.read("ctrl", SC.co("trace_bytes"))[0]
                    cap = bus.read("ctrl", SC.co("trace_bufsz"))[0] or TRACE_BRAM
                    held = min(nbytes, cap)
                    if "tail" in q:
                        n = min(int(q["tail"][0], 0), 65536, held)
                        raw = trace_tail(bus, n, SC)
                        self._json({"tail": n, "nbytes": nbytes, "cap": cap, "hex": raw.hex()})
                    else:
                        off = int(q.get("off", ["0"])[0], 0) & ~3
                        n = min(int(q.get("n", ["512"])[0], 0), 16384, max(0, held - off))
                        words = bus.read("trace", off, (n + 3) // 4) if n else []
                        raw = struct.pack("<%dI" % len(words), *words)[:n]
                        self._json({"off": off, "nbytes": nbytes, "cap": cap, "hex": raw.hex()})
                elif u.path == "/api/fifohist":
                    # eTIP FIFO fill histogram, serial read-out (trTeTipFifoHist*).
                    # region=enc|enc1 selects the encoder instance.
                    enc = q.get("region", ["enc"])[0]
                    if enc not in ("enc", "enc1", "enc2"):
                        raise ValueError("region must be enc, enc1 or enc2")
                    if not bus.demo and bus.read("ctrl", SC.co("trace_bufsz"))[0] == 0:
                        raise ValueError("bitstream without FIFO-histogram support (TRACE_BUFSZ=0)")
                    te = bus.read(enc, 0x0)[0]
                    quiescent = not (te & TE_ENABLE)
                    bus.write(enc, 0xE10, 0x2)              # RdRewind (pointer only)
                    bins = []
                    for _ in range(HIST_BINS // 2):
                        w = bus.read(enc, 0xE14)[0]
                        bins += [w & 0xFFFF, (w >> 16) & 0xFFFF]
                    log_event("event", "fifohist read",
                              {"bins": bins, "quiescent": quiescent})
                    self._json({"bins": bins, "quiescent": quiescent,
                                "note": None if quiescent else
                                "trTeControl.Enable=1: reads may tear (documented contract)"})
                else:
                    self._json({"error": "not found"}, 404)
            except Exception as e:
                log_event("error", "GET %s failed" % u.path, {"error": str(e)})
                self._json({"error": str(e)}, 400)

        def _body(self):
            return self.rfile.read(int(self.headers.get("Content-Length", 0)))

        def do_POST(self):
            u = urlparse(self.path)
            bus = buses.current
            try:
                if u.path == "/api/mode":
                    req = json.loads(self._body())
                    mode = buses.set_mode(str(req.get("mode", "")))
                    log_event("event", "mode switch", {"mode": mode})
                    self._json({"ok": True, "mode": mode,
                                "live_available": buses.hw_bus is not None})
                elif u.path == "/api/boot":
                    # The id comes from the request, the recipe from
                    # boot.json. Without an id: the ACTIVE scenario -- so the
                    # button still does the right thing when the UI has just
                    # switched.
                    req = json.loads(self._body() or "{}")
                    sid = str(req.get("id") or getattr(SC, "id", ""))
                    self._json(boot_start(sid))
                elif u.path == "/api/scenario":
                    req = json.loads(self._body())
                    self._json(self._select_scenario(str(req.get("id", "")),
                                                     bool(req.get("load"))))
                elif u.path == "/api/theme":
                    req = json.loads(self._body())
                    self._json(self._save_theme(str(req.get("id", "")),
                                                req.get("tokens")))
                elif u.path == "/api/console":
                    req = json.loads(self._body())
                    self._json(self._console_tx(bus, str(req.get("data", ""))))
                elif u.path == "/api/symbols":
                    q2 = parse_qs(u.query)
                    kind = q2.get("kind", ["symbols"])[0]
                    name = q2.get("name", ["upload"])[0]
                    data = self._body()
                    if not data:
                        raise ValueError("empty body")
                    text = data.decode("utf-8", "replace")
                    if kind == "sites":
                        cs = insight.CallSites.from_text(text, name)
                        if not cs.count:
                            raise ValueError(
                                "no call/return sites found -- expected the format of "
                                "dis_to_symbols.py --sites: 'C <hex>' or 'R <hex>' per line")
                        INS.sites = cs
                        (HERE / ("sites_%s.map" % SC.id)).write_bytes(data)
                        log_event("event", "call sites uploaded",
                                  {"scenario": SC.id, "sites": cs.count})
                        self._json({"ok": True, "kind": "sites", "count": cs.count,
                                    "calls": len(cs.calls), "rets": len(cs.rets)})
                    else:
                        st = INS.set_symbols_text(text, name)
                        if not st.count:
                            raise ValueError(
                                "no executable symbols found -- expected System.map/nm "
                                "format: '<hex-address> <type> <name>'")
                        (HERE / ("symbols_%s.map" % SC.id)).write_bytes(data)
                        log_event("event", "symbols uploaded",
                                  {"scenario": SC.id, "symbols": st.count})
                        self._json({"ok": True, "kind": "symbols",
                                    "count": st.count, "source": name})
                elif u.path == "/api/wp/load":
                    req = json.loads(self._body())
                    try:
                        res = WPV.load_table(bus, SC, req.get("slots"),
                                             req.get("encoders"))
                    except ValueError as e:
                        if str(e).startswith("CONFLICT"):
                            # Not a 400: the client sent nothing wrong, it is
                            # the STATE that forbids it right now (running
                            # cores / active trace) -- 409.
                            log_event("warn", "wp load rejected",
                                      {"error": str(e)})
                            self._json({"error": str(e)}, 409)
                            return
                        raise
                    log_event("event", "wp table loaded", res)
                    self._json(res)
                elif u.path == "/api/insight/reset":
                    INS.reset()
                    self._json({"ok": True})
                elif u.path == "/api/pcinfo":
                    q2 = parse_qs(u.query)
                    t = int(q2.get("target", ["0"])[0])
                    if t not in (0, 1, 2):
                        raise ValueError("target must be 0, 1 or 2")
                    data = self._body()
                    if not data:
                        raise ValueError("empty pcinfo body")
                    (HERE / ("pcinfo_src%d.pcinfo" % t)).write_bytes(data)
                    log_event("event", "pcinfo uploaded",
                              {"target": t, "bytes": len(data)})
                    self._json({"ok": True, "target": t, "bytes": len(data)})
                elif u.path == "/api/write":
                    req = json.loads(self._body())
                    region = req.get("region", "enc")
                    off, val = int(req["offset"]), int(req["value"])
                    base, size = REGIONS_OF(SC)[region]  # s. /api/read: NameError-Altlast

                    if off < 0 or off + 4 > size or off % 4:
                        raise ValueError("range")
                    # Gate first, then the write, then the read-back.
                    # Before, the write always went out and the answer was
                    # always {"ok": true} -- with Enable=1 the hardware
                    # discarded it and the log line looked like success.
                    # The window policy sits IN FRONT of both hardware gates
                    # and answers 403 rather than 409 -- 409 means "not right
                    # now" (set Enable, halt the core, then it works), 403
                    # means "never here". A caller who sees 409 sensibly tries
                    # again after disarming the sink; that second attempt is
                    # exactly the path the window policy closes.
                    for reason, code in (
                            (window_policy_reason(SC, region, off), 403),
                            (write_gate_reason(bus, region, off), 409),
                            (region_hold_reason(bus, SC, region), 409)):
                        if reason:
                            log_event("warn", "write refused",
                                      {"region": region, "offset": "0x%X" % off,
                                       "reason": reason, "status": code})
                            self._json({"error": reason}, code)
                            return
                    bus.write(region, off, val)
                    rb = bus.read(region, off)[0]
                    r = reg_at(region, off)
                    diff = readback_diff(r, val & 0xFFFFFFFF, rb) if r else []
                    log_event("event" if not diff else "warn", "reg write",
                              {"region": region, "offset": "0x%X" % off,
                               "value": "0x%08X" % (val & 0xFFFFFFFF),
                               "readback": "0x%08X" % rb,
                               **({"not_taken": diff} if diff else {})})
                    if diff:
                        # Not an error of the request but a finding about the
                        # hardware: WARL legalisation, a write mask, or an
                        # interlock regmap.json does not know about. It belongs
                        # in the response, not only in the log.
                        self._json({"ok": False, "readback": rb,
                                    "not_taken": diff,
                                    "error": "write did not take effect: "
                                             + "; ".join(diff)})
                        return
                    self._json({"ok": True, "readback": rb})
                elif u.path == "/api/elf":
                    q2 = parse_qs(urlparse(self.path).query)
                    target = q2.get("target", ["ram"])[0]
                    if target == "cva6":
                        # CVA6 boots out of the reserved PS DDR window
                        # (0x6400_0000, SPEC_board_memory_map): write the
                        # segments physically, halt the core first (CONTROL
                        # b5).
                        data = self._body()
                        loaded = self._load_cva6(data)
                        log_event("event", "cva6 program loaded",
                                  {"bytes": loaded,
                                   "kind": "elf" if data[:4] == b"\x7fELF" else "hex"})
                        self._json({"ok": True, "loaded_bytes": loaded, "target": target})
                        return
                    if target not in SC.regions:
                        raise ValueError(
                            "target %r does not exist in scenario %r (available: %s)"
                            % (target, SC.id, ", ".join(sorted(SC.regions))))
                    data = self._body()
                    loaded = self._load_program(data, target)
                    log_event("event", "program loaded",
                              {"target": target, "bytes": loaded,
                               "kind": "elf" if data[:4] == b"\x7fELF" else "hex"})
                    self._json({"ok": True, "loaded_bytes": loaded, "target": target})
                elif u.path == "/api/ctl":
                    req = json.loads(self._body())
                    action = req.get("action", "")
                    res = self._ctl(action, req)
                    log_event("event", "ctl %s" % action,
                              {"control": "0x%X" % res["control"],
                               "trTeControl": "0x%08X" % res["trTeControl"],
                               **({"hint": res["hint"]} if res.get("hint") else {})})
                    self._json(res)
                elif u.path == "/api/client-log":
                    # Mirror one UI event-log entry (forge_app pattern) so the
                    # dev/agent sees what the UI did without the browser.
                    req = json.loads(self._body())
                    log_event(str(req.get("level", "info"))[:10],
                              str(req.get("msg", ""))[:500],
                              req.get("data"), src="ui")
                    self._json({"ok": True})
                elif u.path == "/api/demo" and bus.demo:
                    req = json.loads(self._body())
                    bus.inject_overflow = bool(req.get("overflow"))
                    log_event("event", "demo overflow inject",
                              {"on": bus.inject_overflow})
                    self._json({"ok": True})
                else:
                    self._json({"error": "not found"}, 404)
            except Exception as e:
                log_event("error", "POST %s failed" % u.path, {"error": str(e)})
                self._json({"error": str(e)}, 400)

        # ------------------------------------------------------------------
        # scenario switch
        # ------------------------------------------------------------------
        # ----- persist a colour theme into themes.json --------------------
        # The panel keeps a change in the browser only. This call is what
        # makes it permanent for everyone. Non-base themes are boiled down to
        # their DIFFERENCE from the base in the process -- otherwise every
        # theme grows to the full token set and a later base update no longer
        # reaches it.
        _TOKEN_KEY = re.compile(r"^[a-z][a-z0-9-]{0,40}$")

        def _save_theme(self, tid, tokens):
            path = HERE / "themes.json"
            if not isinstance(tokens, dict) or not tokens:
                return {"ok": False, "error": "no tokens supplied"}
            clean = {}
            for k, v in tokens.items():
                if not isinstance(k, str) or not self._TOKEN_KEY.match(k):
                    return {"ok": False, "error": "illegal token name: %r" % (k,)}
                if not isinstance(v, str) or len(v) > 120 or ";" in v or "}" in v:
                    return {"ok": False, "error": "illegal value for %s" % k}
                clean[k] = v.strip()
            try:
                doc = json.loads(path.read_text(encoding="utf-8"))
            except Exception as e:
                return {"ok": False, "error": "themes.json not readable: %s" % e}
            themes = doc.get("themes") or {}
            if tid not in themes:
                return {"ok": False, "error": "unknown theme: %s" % tid}
            base_id = doc.get("default") or "forge"
            base = dict((themes.get(base_id) or {}).get("tokens") or {})
            if tid == base_id:
                themes[tid]["tokens"] = clean
            else:
                themes[tid]["tokens"] = {k: v for k, v in clean.items()
                                         if base.get(k) != v}
            # Write alongside first, then replace: a crash in the middle of
            # writing must not leave the file half finished.
            tmp = path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
                           encoding="utf-8")
            tmp.replace(path)
            log_event("event", "theme saved", {"theme": tid,
                                               "tokens": len(themes[tid]["tokens"])})
            return {"ok": True, "id": tid, "tokens": len(themes[tid]["tokens"])}

        def _select_scenario(self, sid, load):
            global SC
            sc = CAT.select(sid)
            SC = sc
            INS.reset()
            CONREAD.reset()
            WPV.reset(sc)         # the WP ring/counters belong to the scenario
            load_symbol_files(sc)
            mode = buses.rebind(sc)
            res = {"ok": True, "active": sc.id, "mode": mode,
                   "symbols": INS.symbols.count, "loaded": False}
            if load:
                res["load"] = load_app(sc, buses.current)
                res["loaded"] = bool(res["load"].get("ok"))
                # After programming the PL every mapping is stale -- the
                # hardware bus is set up afresh, otherwise the mmaps point at
                # an aperture that did not exist in the meantime.
                buses.rebind(sc)
            # Establish the scenario's sink defaults. AFTER the last rebind,
            # otherwise it would write onto the old bus -- and with the CURRENT
            # bus, because after an app load the earlier one is closed.
            global SINK_ARM
            if ARM_SINKS_ON_SELECT:
                SINK_ARM = arm_default_sinks(buses.current, sc)
            else:
                # A scenario change no longer touches ANY register by itself.
                # arm_default_sinks() used to run immediately after the app
                # load -- and its first step is a READ of
                # SINK_CTRL/DDR_BASE/DDR_SIZE, exactly the access that can
                # fall into the window described above. So the most dangerous
                # access of the session was, of all things, the automatic one.
                # Whoever wants the sink defaults asks for them explicitly
                # (POST /api/ctl {"action":"arm_sinks"}) or starts the server
                # with --arm-sinks.
                want = dict(sc.raw.get("sink_defaults") or {})
                SINK_ARM = {"state": ("not armed automatically (sink_defaults: %s) "
                                      "-- use action 'arm_sinks' or --arm-sinks"
                                      % (want or "none"))}
            res["sinks"] = SINK_ARM
            # Program images are DELIBERATELY not placed automatically here.
            # A preload is a write into the RAM window of the design that was
            # just loaded -- exactly the access that falls into the window
            # after an app load, the one the AXI hang of 2026-08-19 came from
            # (see ARM_SINKS_ON_SELECT above). Instead the response SAYS that
            # one is pending: silent inaction would be the worse half of both
            # here, because a scenario without a program looks alive in the UI
            # and delivers 40 bytes of trace.
            pre = dict(sc.raw.get("preload") or {})
            if pre and mode != "demo":
                res["preload_pending"] = {
                    "targets": sorted(pre),
                    "note": "scenario declares program images; POST "
                            "/api/ctl {\"action\":\"preload\"} with the cores "
                            "stopped to stage them"}
            log_event("event", "scenario select",
                      {"id": sc.id, "load": load, "mode": mode,
                       "symbols": INS.symbols.count})
            return res

        # ------------------------------------------------------------------
        # console: input to the guest
        # ------------------------------------------------------------------
        def _console_tx(self, bus, data):
            c = SC.console
            if not c:
                raise ValueError("scenario %r has no console" % SC.id)
            if not interactive_now(bus):
                raise ValueError(
                    (c.get("note_readonly") or "input not possible")
                    + " (checked: CON_RPTR does not read back)")
            off = SC.co(c.get("tx_reg") or "")
            if off is None:
                raise ValueError("scenario has no CON_TX register")
            payload = data.encode("utf-8")[:4096]
            sent = dropped = 0
            for ch in payload:
                # One character per write access; b8 = 'valid' (RTL contract).
                # Check the fill level first: the RX FIFO holds CON_RX_BYTES
                # (256), so a character written into it blindly would be
                # silently gone -- the user would have typed and nothing would
                # have happened.
                used = bus.read("ctrl", off)[0] & 0xFFFF
                if used >= 250:
                    dropped = len(payload) - sent
                    break
                bus.write("ctrl", off, 0x100 | ch)
                sent += 1
            log_event("event", "console tx", {"bytes": sent, "dropped": dropped})
            res = {"ok": True, "sent": sent}
            if dropped:
                res["dropped"] = dropped
                res["note"] = ("RX FIFO full: %d characters not sent. The guest only "
                               "picks them up on the next poll of the 8250 driver "
                               "(DT node without 'interrupts')." % dropped)
            return res

        # ------------------------------------------------------------------
        # Live PC: decode a window out of the ring and symbolise it
        # ------------------------------------------------------------------
        def _livepc(self, bus, q):
            if not SC.has("live_pc"):
                raise ValueError("scenario %r has no live-PC view" % SC.id)
            tail = min(int(q.get("tail", ["16384"])[0], 0), 1 << 20)
            raw = trace_tail(bus, tail, SC)
            payload, head, tailcut = insight.align_to_messages(raw)
            if not payload:
                return {"ok": False, "window": len(raw), "instr": 0,
                        "reason": "no complete Nexus message in the window "
                                  "(not enough trace yet)"}
            t0 = time.time()
            res, texts = run_decode(payload, sc=SC, timeout=60, live=True)
            dt = time.time() - t0
            # Reproducibility log, rate limited: the live poll runs every
            # 2.5 s -- logged are only STATE CHANGES (ok<->fail, with the
            # decoder's log tail) and every 50th persistent failure. A silent
            # livepc defect (0 instructions, exit 9) was otherwise visible only
            # in the browser and could not be reconstructed.
            global _LIVEPC_FAILS
            if not res.get("ok"):
                _LIVEPC_FAILS += 1
                if _LIVEPC_FAILS == 1 or _LIVEPC_FAILS % 50 == 0:
                    log_event("warn", "livepc decode failing",
                              {"consecutive": _LIVEPC_FAILS,
                               "exit": res.get("exit"),
                               "window": len(payload),
                               "log_tail": res.get("log_tail", [])[-3:]})
            elif _LIVEPC_FAILS:
                log_event("info", "livepc decode recovered",
                          {"after_fails": _LIVEPC_FAILS})
                _LIVEPC_FAILS = 0
            target = int(q.get("target", [str(next(iter(texts), 0))])[0])
            pcs = insight.parse_pcout(texts.get(target, b""))
            # A fixed instruction width only while the C extension is OFF --
            # otherwise 'pc+4' would not be a valid stride and the call depth
            # would be guessed rather than computed.
            core = next((c for c in SC.cores if int(c.get("id", 0)) == target),
                        SC.cores[0] if SC.cores else {})
            fixed = "C" not in str(core.get("isa", "")).split()[0][5:]
            last = INS.add_window(pcs, len(payload), dt, fixed_width=fixed)
            return {"ok": True, "window": len(raw), "decoded_bytes": len(payload),
                    "trimmed_head": head, "trimmed_tail": tailcut,
                    "target": target, "core": core.get("name"),
                    "fixed_width": fixed, "decode": res, **last}

        # Fallback when the scenario says nothing: the board-proven RV32 CVA6
        # state (address plan v2). Scenarios carry their window themselves
        # (`load_base`/`load_size`/`load_guest_base` on the core), because it
        # differs per design: cv32a6 64 MiB, cv64a6 192 MiB, and the Rocket
        # sees its RAM from GUEST address 0x8000_0000 while it physically
        # sits at 0x6400_0000 (window guard in the rocket_soc_synth_wrap).
        CVA6_WIN_BASE = 0x64000000
        CVA6_WIN_SIZE = 0x04000000

        def _ddr_window(self):
            """(ps_base, size, guest_base) of this scenario's DDR-loaded core."""
            core = next((c for c in SC.cores if c.get("load") == "cva6"), None) or {}
            def _n(key, dflt):
                v = core.get(key)
                return dflt if v is None else (int(v, 0) if isinstance(v, str) else int(v))
            base = _n("load_base", self.CVA6_WIN_BASE)
            return (base, _n("load_size", self.CVA6_WIN_SIZE), _n("load_guest_base", base))

        def _load_cva6(self, data: bytes) -> int:
            """Halt the core, write an ELF/hex into the reserved DDR window
            (physically; in demo mode: validate only).

            The segment addresses of an ELF are the CORE's view. On the Rocket
            that is 0x8000_0000, while the same byte physically sits at
            0x6400_0000 -- hence the translation, instead of handing the guest
            address to /dev/mem. On every design so far both bases are equal
            and the translation is the identity.
            """
            bus = buses.current
            C = SC.co("control")
            ctrl = bus.read("ctrl", C)[0]
            bus.write("ctrl", C, ctrl & ~(SC.cbit("cva6_run") or SC.cbit("core_run")))
            total = 0
            segs = []
            ps_base, win_size, guest_base = self._ddr_window()
            if data[:4] == b"\x7fELF":
                for paddr, seg in parse_elf(data):
                    if not (guest_base <= paddr and
                            paddr + len(seg) <= guest_base + win_size):
                        raise ValueError(
                            "segment 0x%x+0x%x outside core window 0x%x+0x%x"
                            % (paddr, len(seg), guest_base, win_size))
                    segs.append((paddr - guest_base + ps_base, seg))
            else:  # hex: one 32-bit word per line, starting at the window base
                words = [int(w, 16) for w in re.findall(r"[0-9a-fA-F]{1,8}",
                                                        data.decode("ascii", "ignore"))]
                segs.append((ps_base, struct.pack("<%dI" % len(words), *words)))
            for paddr, seg in segs:
                if not bus.demo:
                    bus.phys_write(paddr, seg)
                total += len(seg)
            if total == 0:
                raise ValueError("no loadable data found")
            return total

        def _load_program(self, data: bytes, target: str = "ram") -> int:
            return load_program(buses.current, data, target, SC)

        def _ctl(self, action: str, req=None):
            req = req or {}
            bus = buses.current
            C = SC.co("control")
            ctrl = bus.read("ctrl", C)[0]
            # ONLY the encoder regions this scenario actually has.
            encs = [r for r in ("enc", "enc1", "enc2") if r in SC.regions]
            tev = {e: bus.read(e, 0)[0] for e in encs}
            te = tev.get("enc", 0)
            te1 = tev.get("enc1", 0)
            te2enc = tev.get("enc2", 0)
            sink = (bus.read("ctrl", SC.co("sink_ctrl"))[0]
                    if SC.co("sink_ctrl") is not None else 0)
            B_RUN = SC.cbit("core_run")
            B_CLR = SC.cbit("trace_clear")
            B_FLUSH = SC.cbit("trace_flush")
            B_IRQ = SC.cbit("irq_gen_en")
            B_CVA6 = SC.cbit("cva6_run")
            B_CON = SC.cbit("con_clear")
            # b0 is the collective bit and stays that way. What takes effect,
            # though, is b0 | b(8+i) -- a "stop" that only clears b0 would NOT
            # halt a core running through its own bit. The collective path
            # therefore touches every bit of the cores that hang off b0.
            B_ALL = B_RUN
            for c in SC.cores:
                if "core_run" in SC.core_run_bits(c):
                    B_ALL |= SC.core_run_mask(c)
            per_core = [i for i, c in enumerate(SC.cores) if SC.core_own_bit(c)]
            core_hint = None
            preload_result = None
            afifm_step = None
            if action == "run":
                # The collective start releases EVERY core -- in a scenario
                # that mixes trace protocols that is exactly the merged,
                # undecodable stream the interlock exists for.
                lock = protocol_lock_reason(bus, SC, None)
                if lock:
                    raise ValueError(lock)
                # Deterministic (re)start: if the core is already running, a
                # plain core_run=1 is a no-op (the board report read "Run --
                # nothing happens"). Pulse reset so Run always restarts the
                # program from PC 0.
                if ctrl & B_ALL:
                    bus.write("ctrl", C, ctrl & ~B_ALL)
                    time.sleep(0.02)
                bus.write("ctrl", C, (ctrl & ~B_ALL) | B_RUN)
            elif action == "stop":
                bus.write("ctrl", C, ctrl & ~B_ALL)
            elif action in ("core_run", "core_stop"):
                # A single core. The index comes from the request and refers
                # to the scenario's cores[].
                idx = int(req.get("core", 0))
                if not (0 <= idx < len(SC.cores)):
                    raise ValueError("core index %d out of range (scenario %r "
                                     "has %d cores)" % (idx, SC.id, len(SC.cores)))
                if idx not in per_core:
                    raise ValueError(
                        "scenario %r has no own run bit for core %d -- this "
                        "design starts its cores together (CONTROL b0); use "
                        "run/stop" % (SC.id, idx))
                want = action == "core_run"
                if want:
                    lock = protocol_lock_reason(bus, SC, idx)
                    if lock:
                        raise ValueError(lock)
                if want and SC.core_running(ctrl, SC.cores[idx]):
                    # The same promise as the collective run: the core
                    # restarts at PC 0, instead of a second set doing nothing.
                    set_core_run(bus, SC, idx, False)
                    time.sleep(0.02)
                _b, _a, core_hint = set_core_run(bus, SC, idx, want)
            elif action == "trace_on":
                # Arm every encoder of THIS scenario (trio: one merged
                # stream).
                # Live decodability: without periodic syncs the decoder can
                # NEVER anchor a window cut out of the middle of the ring --
                # /api/livepc delivered 0 instructions for 2047 consumed
                # messages (found 2026-08-03). So trace_on programs the
                # InstSyncMode along with it (field [19:16], period
                # 2^(4+max) instructions in field [23:20]); scenarios.json can
                # override via "live_sync": {"mode": M, "max": N} (mode 0 =
                # off).
                ls = SC.raw.get("live_sync") or {"mode": 6, "max": 4}
                for e in encs:
                    # InstSyncMode/-Max are swwel-locked (writable only while
                    # Enable=0) and trace_off leaves Enable on -- hence THREE
                    # steps: drop Enable, write the fields while Enable=0,
                    # then arm. (The first version wrote in one go: the field
                    # write was silently discarded and trTeControl stayed at
                    # 0x010080E7 with SyncMode=0.)
                    # rmw_value: b12 InstStallOrOverflow is W1C -- writing the
                    # whole word back with that bit set clears the overflow
                    # evidence. So of all things "trace off" used to erase the
                    # indication that trace had been lost.
                    bus.write(e, 0, rmw_value(e, 0, tev[e] & ~(TE_ENABLE | TE_ITRACE)))
                    t = ((bus.read(e, 0)[0] & ~(0xFF << 16))
                         | ((ls.get("mode", 6) & 0xF) << 16)
                         | ((ls.get("max", 4) & 0xF) << 20))
                    # MULTI-SOURCE: set SrcBits/SrcID and clear InhibitSrc --
                    # in the same Enable=0 window, because both fields are
                    # swwel-locked.
                    #
                    # Why this was missing and what it cost (measured
                    # 2026-08-19 on the trio): the RDL reset of trTeControl has
                    # b15 SET, i.e. SRC off. The live path never touched it,
                    # and it never touched the FEAT registers (SrcBits/SrcID)
                    # either. The consequence: a multi-source stream out of the
                    # dashboard carries NO source field. It decodes cleanly --
                    # 49,135 messages, 0 errors -- and yields 0 instructions
                    # per target, because nothing can be attributed. Exactly
                    # what these scenarios are meant to show was therefore
                    # missing, silently. The demo bus had been setting b15 and
                    # FEAT correctly all along (see the DemoBus arming) and the
                    # UI displayed "SRC on" -- the mock-up was more correct
                    # than the hardware.
                    #
                    # The values are the ones the board runner uses:
                    # FEAT = SrcBits<<28 | SrcID<<16, ENC_CTRL b15 = 0.
                    if len(encs) > 1 and int(SC.decode.get("srcbits", 0)):
                        sb = int(SC.decode["srcbits"]) & 0xF
                        sid = encs.index(e)
                        feat = (bus.read(e, 0x008)[0] & 0x0000FFFF)                             | (sb << 28) | (sid << 16)
                        bus.write(e, 0x008, feat)
                        t &= ~(1 << 15)
                    bus.write(e, 0, rmw_value(e, 0, t | TE_ACTIVE))
                    bus.write(e, 0, rmw_value(e, 0,
                                              bus.read(e, 0)[0] | TE_ENABLE | TE_ITRACE))
            elif action == "trace_off":
                for e in encs:
                    bus.write(e, 0, rmw_value(e, 0, tev[e] & ~TE_ITRACE))
                time.sleep(0.05)
                if B_FLUSH:                          # ATB flush (Funnel global)
                    bus.write("ctrl", C, ctrl | B_FLUSH)
                    time.sleep(0.05)
                    bus.write("ctrl", C, ctrl & ~B_FLUSH)
            elif action == "cva6_run":
                # Only AFTER the program has been loaded into the DDR window
                # (elf?target=cva6)
                bus.write("ctrl", C, ctrl | (B_CVA6 or B_RUN))
            elif action == "cva6_stop":
                bus.write("ctrl", C, ctrl & ~(B_CVA6 or B_RUN))
            elif action in ("ddr_on", "ddr_off", "ddr_clear", "pib_on", "pib_off"):
                so = SC.co("sink_ctrl")
                if so is None:
                    raise ValueError("scenario %r has no sink control path" % SC.id)
                if action == "ddr_on":
                    # Port width BEFORE arming: see ensure_afifm_32bit().
                    # Arming a 32-bit master onto a 128-bit port produces a
                    # capture that every counter calls healthy and no decoder
                    # can read.
                    if not bus.demo:
                        afifm_step = [ensure_afifm_32bit(), ensure_afifm3_64bit()]
                    bus.write("ctrl", so, sink | 0x1)
                elif action == "ddr_off":
                    bus.write("ctrl", so, sink & ~0x1)
                elif action == "ddr_clear":
                    if sink & 0x1:
                        raise ValueError("ddr_clear only while DDR sink is off")
                    bus.write("ctrl", so, sink | 0x2)   # W1-Puls
                elif action == "pib_on":
                    bus.write("ctrl", so, sink | 0x10)
                else:
                    bus.write("ctrl", so, sink & ~0x10)
            elif action == "arm_sinks":
                if not bus.demo:
                    afifm_step = [ensure_afifm_32bit(), ensure_afifm3_64bit()]
                # Establish the scenario's sink defaults EXPLICITLY. Since
                # 2026-08-19 this no longer runs automatically on a scenario
                # change (see _select_scenario): the automatic access fell into
                # the window after an app load and could hang the AXI bus. As
                # an action it is available unchanged -- only now when somebody
                # asks for it.
                global SINK_ARM
                SINK_ARM = arm_default_sinks(bus, SC)
            elif action == "preload":
                # Place the scenario's program images into their RAM windows.
                # Until 2026-08-19 this ran ONLY at server start and ONLY for
                # the scenario active at that moment -- after a switch the
                # cores ran with whatever the fabric had left there at power
                # up. Measured that day: a trio run after a switch delivered
                # 40 bytes of trace. The action requires halted cores, because
                # load_program only applies then.
                if ctrl & B_ALL:
                    preload_result = {"ok": False,
                                      "note": "cores are running -- stop first"}
                else:
                    preload_result = run_preload(bus, SC)
            elif action == "clear":
                bus.write("ctrl", C, ctrl | B_CLR)
                bus.write("ctrl", C, ctrl & ~B_CLR)
            elif action == "con_clear":
                if not B_CON:
                    raise ValueError("scenario %r has no console ring" % SC.id)
                bus.write("ctrl", C, ctrl | B_CON)
                bus.write("ctrl", C, ctrl & ~B_CON)
                # The recording held in the server belongs to the cleared ring
                # -- otherwise the old text would keep hanging in the display
                # while the counters stand at 0.
                CONREAD.reset()
            elif action == "flush":
                if not B_FLUSH:
                    raise ValueError("scenario %r has no trace_flush" % SC.id)
                bus.write("ctrl", C, ctrl | B_FLUSH)
                time.sleep(0.05)
                bus.write("ctrl", C, ctrl & ~B_FLUSH)
            elif action in ("irq_on", "irq_off"):
                if not B_IRQ:
                    raise ValueError("scenario %r has no IRQ generator" % SC.id)
                bus.write("ctrl", C, (ctrl | B_IRQ) if action == "irq_on"
                          else (ctrl & ~B_IRQ))
            else:
                raise ValueError("unknown action %r" % action)
            ctrl2 = bus.read("ctrl", C)[0]
            after = {e: bus.read(e, 0)[0] for e in encs}
            hint = core_hint
            if action in ("run", "core_run"):
                if action == "run" and (ctrl & B_ALL):
                    hint = "cores were already running -> restarted from PC 0"
                eff = lambda t: (t & TE_ACTIVE and t & TE_ENABLE and t & TE_ITRACE)
                cold = [e for e in encs if not eff(after[e])]
                if cold:
                    hint = ((hint + "; ") if hint else "") + \
                        "effective tracing is OFF on %s -> press 'Trace on'" % \
                        ", ".join(cold)
            res = {"ok": True, "control": ctrl2,
                   "trTeControl": after.get("enc", 0), "hint": hint}
            if action == "arm_sinks":
                res["sinks"] = SINK_ARM
            if afifm_step is not None:
                res["afifm2"] = afifm_step
            if action == "preload":
                res["preload"] = preload_result
            # Effective run state per core -- computed from CONTROL (valid on
            # every bitstream) and, where the build has it, read from the
            # STATUS mirror. If the two disagree, THAT is the message.
            if SC.cores:
                res["cores_running"] = [SC.core_running(ctrl2, c) for c in SC.cores]
                if SC.co("status") is not None and any(
                        SC.status_bits.get(_running_bit_name(c)) is not None
                        for c in SC.cores):
                    st = bus.read("ctrl", SC.co("status"))[0]
                    res["status"] = st
                    res["cores_running_status"] = [
                        bool(st >> SC.status_bits[_running_bit_name(c)] & 1)
                        if SC.status_bits.get(_running_bit_name(c)) is not None
                        else None for c in SC.cores]
            for e, sfx in (("enc1", "1"), ("enc2", "2")):
                if e in after:
                    res["trTeControl" + sfx] = after[e]
            return res

    return H


def run_preload(bus, sc, preloads=None):
    """Stage the scenario's program images into their RAM windows.

    Returns one dict per target: {"target", "file", "bytes", "note", "ok"}.
    Never raises -- a missing image must not take the server or a scenario
    switch down; it is reported instead.

    WHY THIS IS A FUNCTION AND NOT A STARTUP LOOP. Until 2026-08-19 the
    preload ran exactly once, at server start, for whichever scenario was
    active then. Switching to another scenario left its cores with whatever
    the fabric powered up with. Measured that day: a `trio` run after such a
    switch produced **40 bytes** of trace -- a scenario that looks alive in
    the UI and carries nothing. The cores are held in reset around the call
    (`load_program` is only valid while `core_run = 0`), which is exactly
    the state a scenario switch leaves them in.
    """
    if bus.demo:
        return []
    if preloads is None:
        preloads = dict(sc.raw.get("preload") or {})
    steps = []
    for target, path in preloads.items():
        try:
            p = Path(path)
            if not p.is_absolute():
                p = HERE / p
            data = p.read_bytes()
            n = load_program(bus, data, target, sc)
            log_event("event", "elf preloaded",
                      {"target": target, "file": str(p), "bytes": n})
            steps.append({"target": target, "file": p.name, "bytes": n,
                          "note": "%d B" % n, "ok": True})
        except Exception as e:
            log_event("warn", "elf preload failed",
                      {"target": target, "file": str(path), "error": str(e)})
            steps.append({"target": target, "file": str(path), "bytes": 0,
                          "note": "FAILED: %s" % e, "ok": False})
    return steps


def main():
    global NEXRV, SRCBITS, SC, PL_GUARD
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind address; 127.0.0.1 = reachable via ssh -L only, "
                         "0.0.0.0 = directly in the lab segment (no tunnel, but "
                         "no authentication either -- see README)")
    ap.add_argument("--no-pl-guard", action="store_true",
                    help="disable the aperture guard (live bus even without a "
                         "loaded app -- can hang the board, diagnosis only)")
    ap.add_argument("--demo", action="store_true",
                    help="start in demo mode (live stays switchable via /api/mode)")
    ap.add_argument("--scenario", default=None,
                    help="start scenario (%s); default from scenarios.json"
                         % ", ".join(CAT.order))
    ap.add_argument("--nexrv", default=None,
                    help="decoder binary for /api/decode (kept for backward "
                         "compatibility; use --decoder for new setups). "
                         "Default: repo bin/ (cttd, falling back to the "
                         "legacy NexRv name) or PATH -- see find_decoder()")
    ap.add_argument("--decoder", default=None,
                    help="decoder binary for /api/decode (CTTD or legacy "
                         "NexRv); same as --nexrv, --nexrv wins if both are "
                         "given")
    ap.add_argument("--pcinfo0", default=None, help="pcinfo for target 0")
    ap.add_argument("--pcinfo1", default=None, help="pcinfo for target 1")
    ap.add_argument("--pcinfo2", default=None, help="pcinfo for target 2")
    ap.add_argument("--symbols", default=None,
                    help="System.map/nm file for PC symbolisation")
    ap.add_argument("--sites", default=None,
                    help="call/return sites (dis_to_symbols.py --sites); "
                         "without them the call depth stays empty")
    ap.add_argument("--srcbits", type=int, default=2,
                    help="SrcBits of the merged stream (multi-target scenarios only)")
    ap.add_argument("--preload", action="append", default=[],
                    help="target=elfpath to preload into RAM at start (repeatable, "
                         "e.g. --preload ram=branch_test.elf); default from "
                         "scenarios.json 'preload'; paths relative to the server dir")
    args = ap.parse_args()

    SRCBITS = args.srcbits
    PL_GUARD = not args.no_pl_guard
    for i, v in ((0, args.pcinfo0), (1, args.pcinfo1), (2, args.pcinfo2)):
        if v:
            PCINFO_CLI[i] = v
    if args.scenario:
        SC = CAT.select(args.scenario)
    elif not args.demo:
        # No --scenario: follow the board rather than the file. Whoever loads
        # a bitstream has thereby said which core is meant; a service that
        # instead insists on its json default reads the wrong CTRL map or falls
        # into DEMO for no reason. The default from scenarios.json stays the
        # fallback when nothing (recognisable) is loaded -- for instance on an
        # autostart before ctrace-app.service.
        try:
            _st = board_state()
        except OSError as e:                     # no xmutil / no board
            _st = {"active_app": None, "scenario": None, "error": str(e)}
        _owner = _st.get("scenario")
        if _owner and _owner != SC.id:
            SC = CAT.select(_owner)
            print("scenario: '%s' adopted from loaded app '%s' "
                  "(--scenario overrides this)" % (SC.id, _st["active_app"]),
                  file=sys.stderr)
    # preload catalogue: scenario default, overridden by --preload target=path.
    preloads = dict(SC.raw.get("preload") or {})
    for spec in args.preload:
        t, _, p = spec.partition("=")
        if not p:
            t, p = "ram", t
        preloads[t] = p
    NEXRV = find_decoder(args.nexrv or args.decoder)
    # symbol table + call sites: CLI > scenario-specific > json default
    got = load_symbol_files(SC, args.symbols, args.sites)
    print("symbols: %d | call/ret sites: %d" % (got["symbols"], got["sites"]),
          file=sys.stderr)

    buses = Buses(force_demo=args.demo)
    bus = buses.current
    if bus.demo and not args.demo:
        print("NOTE: /dev/mem unavailable (%s) -> DEMO mode"
              % buses.live_error, file=sys.stderr)

    # Start the fine sampling only once the bus is up -- otherwise the thread
    # runs into nothing and fills the log with errors.
    threading.Thread(target=_bpi_sampler, args=(buses,), daemon=True).start()
    # AXIS-WP drain: does nothing for as long as the active scenario has no
    # "wp" block -- it then costs one 250 ms sleep per round.
    WPV.reset(SC)
    threading.Thread(target=_wp_sampler, args=(buses,), daemon=True).start()
    srv = ThreadingHTTPServer((args.host, args.port), make_handler(buses))
    mode = "DEMO" if bus.demo else "LIVE (/dev/mem)"

    # Startup: TWO events. The first is written before any PL register access;
    # the register snapshot follows as a second event. If the log shows the
    # first without the second, the very first /dev/mem access hung -- i.e.
    # the app/bitstream was not loaded (or the PL is wedged): the prime
    # "a fresh start hangs" signature.
    # Log the start CONFIGURATION in full, for later reproducibility -- without
    # the decoder/pcinfo/symbols paths a later difference in a decode cannot be
    # reconstructed.
    log_event("info", "server start (pre-snapshot)",
              {"mode": mode, "port": args.port, "pid": os.getpid(),
               "regmap_regs": len(REGMAP["regs"]),
               "scenario": SC.id, "nexrv": str(NEXRV) if NEXRV else None,
               "pcinfo": {str(t): str(p) for t, p in PCINFO_CLI.items()},
               "symbols": args.symbols, "sites": args.sites,
               "srcbits": SRCBITS, "preload": preloads, "argv": sys.argv[1:]})
    try:
        # Scenario offsets, no literals: 0x14 would be CON_BYTES on
        # cva6_linux (the class of error scenarios.json exists to kill).
        snap = {"control": "0x%X" % bus.read("ctrl", SC.co("control"))[0],
                "status": "0x%X" % bus.read("ctrl", SC.co("status"))[0],
                "trace_bufsz": "0x%X" % bus.read("ctrl", SC.co("trace_bufsz"))[0],
                "trTeControl": "0x%08X" % bus.read("enc", 0x00)[0],
                "trTeImpl": "0x%08X" % bus.read("enc", 0x04)[0]}
    except Exception as e:
        snap = {"snapshot_error": str(e)}
    log_event("info", "startup register snapshot", snap)

    # Sink defaults of the start scenario. Only AFTER the snapshot: if the
    # first /dev/mem access fails, that is in the log before a write master is
    # armed here.
    global SINK_ARM
    SINK_ARM = arm_default_sinks(bus, SC)
    print("sinks: %s" % SINK_ARM.get("state"), file=sys.stderr)

    # ELF preload, for convenience: after the server starts, the cores
    # already have a program in RAM -- one only presses Run. Sources:
    # --preload target=path (CLI, repeatable), otherwise scenarios.json
    # "preload": {"ram": "branch_test.elf"} (paths relative to the server
    # directory). Live mode only; failures do NOT abort the start (a warn
    # event), so that a missing ELF does not prevent the server from coming
    # up.
    if not bus.demo:
        for step in run_preload(bus, SC, preloads):
            print("preload: %(target)s <- %(file)s (%(note)s)" % step)

    print("CTTE dashboard [%s] on http://%s:%d/" % (mode, args.host, args.port))
    if args.host in ("0.0.0.0", "::"):
        ip = lan_addr()
        print("Directly reachable: http://%s:%d/  (no tunnel needed)"
              % (ip or "<board-ip>", args.port))
    else:
        print("Remote access:  ssh -L %d:localhost:%d <user>@<kria>"
              % (args.port, args.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log_event("info", "server stop (SIGINT)")
        raise


if __name__ == "__main__":
    main()
