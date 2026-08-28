#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""AXIS watchpoint view of the dashboard.

Server-side state behind /api/wp/*: a background thread drains the two
`axi_fifo_mm_s` (PG080) of the tgc5b2_axis_wp bitstream into a ring buffer,
and the endpoints serve the latest records and the counters from it.

WHY THE SERVER DRAINS AND NOBODY ELSE: every read of RDFD pops a word out of
the RX FIFO -- reading is DESTRUCTIVE. Two concurrent readers (a second
process, /api/read on fifo0/fifo1, a second server) tear the RLR/RDFD
sequence apart and both see garbled words. That is why this thread is the
ONLY FIFO reader; the board start helper (wp_board_start.py) deliberately
does not touch the FIFO windows, and anyone who needs the reader CLI directly
on the board stops the dashboard service first.

The library is tools/axis_wp_host -- CONSUMED, not copied: `FifoMmS` for the
PG080 read loop (through a bus adapter onto the dashboard bus), and
`wp_records.Record` for the four-word format. Import path: first
`axis_wp_host/` NEXT TO this file (the board layout -- deployment copies the
library into the dashboard directory), then `tools/axis_wp_host` at the
repository root (the repo layout: examples/dashboard/wp_view.py -> examples ->
root -> tools/axis_wp_host -- NOT the parent directory of this file; that was
the predecessor repository's layout, where the dashboard sat directly under
tools/).

If the library is at NEITHER place (a fresh checkout of this example, say,
before tools/axis_wp_host has been migrated), the module still imports:
`AXIS_WP_HOST_AVAILABLE` becomes `False` and `tick_live`/`tick_demo` turn
into documented no-ops, instead of taking the whole server down at startup --
the server imports `wp_view` unconditionally, even in pure demo mode without
watchpoints.

TIMESTAMP CHECK: NONE. The D1 app delivers no TS element (W2 == 0, tstrb
0x0FF; the reader runs with --ts-mode off); the C0b app delivers an AXIS
timestamp (W2 = timestamp, tstrb 0xFFF) -- the view SHOWS the value but still
checks no monotonicity, because both app variants serve the same endpoint. A
candidate for a follow-up edit: checks.check_ts_monotonic(mode="wrap"), gated
on tstrb == 0xFFF.

Demo mode: a DETERMINISTIC generator (no randomness) walks the wp_set entries
cyclically -- tick index in, records out; starting twice yields the same
sequence. It shows the mechanics of the page, not the board load (the
measured production rate on the board is ~21k records/s per core); the demo
rate comes from the scenario (`wp.demo.rate_per_core`).

Every register offset comes from scenarios.json (the `wp` block), sourced
from docs/SPEC_axis_wp_memory_map.md -- no offset as a literal here (the same
convention as the CTRL maps, see the header of server.py).
"""
import sys
import threading
import time
from collections import deque
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Board layout first (deployment puts axis_wp_host/ into the dashboard
# directory), then this repository's layout: examples/dashboard/..
# (=examples)/.. (=repo root)/tools/axis_wp_host.
_REPO_ROOT_CAND = HERE.parents[1] if len(HERE.parents) > 1 else None
for _cand in (HERE, _REPO_ROOT_CAND):
    if _cand is not None and (_cand / "axis_wp_host" / "fifo_mm_s.py").is_file():
        if str(_cand) not in sys.path:
            sys.path.insert(0, str(_cand))
        break
    if _cand is not None and (_cand / "tools" / "axis_wp_host" / "fifo_mm_s.py").is_file():
        if str(_cand / "tools") not in sys.path:
            sys.path.insert(0, str(_cand / "tools"))
        break

try:
    from axis_wp_host.fifo_mm_s import FifoMmS, DrainStats   # noqa: E402
    from axis_wp_host.wp_records import Record                # noqa: E402
    AXIS_WP_HOST_AVAILABLE = True
except ImportError as _e:                                     # noqa: E402
    # tools/axis_wp_host has not landed in this repo yet (or a deploy did
    # not stage it next to this file). Do NOT let that take the whole
    # server down: server.py imports this module unconditionally, even for
    # the hardware-free demo mode that never touches a watchpoint FIFO.
    FifoMmS = DrainStats = Record = None
    AXIS_WP_HOST_AVAILABLE = False
    _AXIS_WP_HOST_IMPORT_ERROR = str(_e)
    print("wp_view: axis_wp_host not found (%s) -- watchpoint view disabled, "
          "everything else runs normally" % _AXIS_WP_HOST_IMPORT_ERROR,
          file=sys.stderr)


class RegionPort:
    """Bus adapter: FifoMmS expects r1(off)/write(off,val) on ONE window,
    while the dashboard bus speaks (region, off). Pass-through, no state."""

    def __init__(self, bus, region):
        self.bus = bus
        self.region = region

    def r1(self, off):
        return self.bus.read(self.region, off)[0]

    def write(self, off, value):
        self.bus.write(self.region, off, value)


def load_wp_symbols(candidates):
    """PC -> symbol name, from wp_set.txt.

    Line format as checks.load_addr_file defines it: ignore `#` lines and
    blank lines, the FIRST `0x` token is the address, and everything after it
    is the name (`0x000001c8 entry:f000`). Returns ({addr: name}, path) of the
    first candidate file that exists, otherwise ({}, None) -- a missing file
    is not an error, the table then shows addresses instead of names (and
    /api/wp/status reports the gap).
    """
    for cand in candidates:
        p = Path(cand)
        if not p.is_absolute():
            p = HERE / p
        if not p.is_file():
            continue
        syms = {}
        with p.open(encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                toks = s.split()
                for i, t in enumerate(toks):
                    if t[:2].lower() == "0x":
                        try:
                            addr = int(t, 16) & 0xFFFFFFFF
                        except ValueError:
                            break
                        name = " ".join(toks[i + 1:])
                        syms[addr] = name
                        break
        return syms, str(p)
    return {}, None


class WpState:
    """Ring, counters and drain state of the WP view (one active scenario).

    Concurrency: the drain thread writes, the HTTP handlers read -- all under
    `self.lock`. The thread itself lives in server.py (wp_sampler) so that,
    like _bpi_sampler, it picks up the CURRENT bus and the CURRENT scenario on
    every tick; this class holds only the state and the tick logic.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.reset(None)

    # -- Lifecycle ----------------------------------------------------------

    def reset(self, sc):
        """Scenario changed (or start): rebuild the state from scratch."""
        with self.lock:
            self.src = None             # drain source ("demo"/"live:<bus>")
            self.sc = sc
            self.cfg = (sc.raw.get("wp") if sc is not None else None) or None
            ring = int((self.cfg or {}).get("ring", 20000))
            self.ring = deque(maxlen=ring)
            self.seq = 0                    # running record number
            self.received = {}              # core -> records over the ring's life
            self.invalid = 0                # Record.valid == False
            self.malformed = 0              # packets with word count != 4
            self.magic_ok = None            # None = not checked yet
            self.magic_val = None
            self.magic_bus = None           # id(bus) of the last check
            self.last_error = None
            self.drain_alive = False
            self.demo_tick = 0
            self.demo_carry = {}
            self.hist = deque(maxlen=40)    # (t, {core: recv}, {core: drops})
            self.fifos = {}                 # region -> FifoMmS (live)
            self._misparse = {}             # region -> consecutive invalid records (resync)
            self.wp_syms, self.wp_syms_path = ({}, None)
            if self.cfg:
                self.wp_syms, self.wp_syms_path = \
                    load_wp_symbols(self.cfg.get("wp_set") or [])
            # Demo schedule: the first wp_slots distinct wp_set entries in
            # ascending address order -- the same set a real table would load.
            # Deterministic, no randomness.
            self.demo_sched = []
            if self.cfg and self.wp_syms:
                addrs = sorted(self.wp_syms)[:int(self.cfg.get("wp_slots", 15))]
                self.demo_sched = [(a, i) for i, a in enumerate(addrs)]

    def active(self):
        return self.cfg is not None

    # -- Live drain (one tick; caller = wp_sampler in server.py) ------------

    def _check_magic(self, bus):
        """Check MAGIC once per bus instance -- before the FIRST FIFO access.

        Board rule: only touch the PL aperture while an app is loaded. The bus
        only exists behind PL_GUARD anyway, but the MAGIC anchor additionally
        proves that the slot really holds the AXIS-WP design and not a foreign
        one with the same window layout.
        """
        if self.magic_ok is not None and self.magic_bus == id(bus):
            return self.magic_ok
        reg = self.cfg["wpctrl_region"]
        val = bus.read(reg, int(self.cfg.get("magic_off", 0)))[0]
        want = int(self.cfg["magic"], 0)
        self.magic_val = val
        self.magic_ok = (val == want)
        self.magic_bus = id(bus)
        if not self.magic_ok:
            self.last_error = ("WPCTRL MAGIC 0x%08X != 0x%08X -- no "
                               "AXIS-WP design in the slot, drain stays off"
                               % (val, want))
        return self.magic_ok

    def tick_live(self, bus):
        """Drain both FIFOs -- CAPPED, never 'until empty'.

        The producer can be faster than the Python /dev/mem drain (measured on
        the board: ~21k records/s per core produced against ~12.7k drained in
        total). A drain that runs 'until empty' then NEVER returns: the
        collecting list grows without bound, nothing gets pushed, and the
        memory suffocates the board (it really happened on 2026-08-12, board
        freeze). Hence a budget per tick and FIFO (`wp.drain_max`, default
        1024 records) and a push per FIFO batch; whatever backlog remains is
        shown honestly by fill/drops in the status.
        """
        if not AXIS_WP_HOST_AVAILABLE:
            self.last_error = ("axis_wp_host not found -- live watchpoint "
                                "drain disabled (%s)" % _AXIS_WP_HOST_IMPORT_ERROR)
            return
        if not self._check_magic(bus):
            return
        t = time.time()
        budget = int(self.cfg.get("drain_max", 1024))
        for f in self.cfg["fifos"]:
            region = f["region"]
            fifo = self.fifos.get(region)
            if fifo is None or fifo.bus.bus is not bus:
                # First binding of THIS process to the FIFO: RX RESET.
                # Without it the drain inherits the read state of its
                # PREDECESSOR -- a service restart in the middle of an
                # RLR/RDFD sequence leaves a half-read packet stream behind,
                # and the new drain permanently parses SHIFTED records (proven
                # live on 2026-08-13: core_ids 2..15 in the ring after a
                # systemctl restart; the same garbled-word class the header
                # warns about for TWO readers -- offset in time it applies to
                # one's own successor too). The reset discards the old
                # backlog (the drop balance of the WPCTRL counters is
                # untouched).
                fifo = FifoMmS(RegionPort(bus, region), reset_on_init=True)
                fifo.init()
                self.fifos[region] = fifo
                self._misparse[region] = 0
            stats = DrainStats()
            recs = []
            while stats.n_packets < budget:
                pkt = fifo.read_packet(stats)
                if pkt is None:
                    break
                if len(pkt) == int(self.cfg.get("record_words", 4)):
                    recs.append(Record(0, *pkt))
                else:
                    with self.lock:
                        self.malformed += 1
            if recs:
                with self.lock:
                    for r in recs:
                        self._push(t, r)
            # SELF-HEALING against misaligned packet boundaries (proven live
            # on 2026-08-13 at FIFO1): an RX reset while the producer writes
            # at full rate can catch the TLAST counting in the middle of a
            # record -- after which EVERY RLR packet delivers 4 words with
            # shifted content (valid=False), forever. Earlier bring-up
            # therefore only reset with the cores held, but the dashboard
            # drain must not stop a running demo. So: if a FIFO persistently
            # delivers ONLY invalid records, ITS RX is reset again (the next
            # tick checks once more) -- each attempt hits a different phase of
            # the stream and converges on aligned; a healthy stream (any valid
            # record among them) NEVER resets.
            if recs:
                if any(r.valid for r in recs):
                    self._misparse[region] = 0
                else:
                    self._misparse[region] = \
                        self._misparse.get(region, 0) + len(recs)
                    if self._misparse[region] >= int(
                            self.cfg.get("resync_after", 256)):
                        fifo.reset_rx()
                        self._misparse[region] = 0
                        with self.lock:
                            self.last_error = (
                                "%s: only invalid records after bind -- "
                                "RX resync triggered (packet-boundary "
                                "drift after reset under load)" % region)

    def _push(self, t, r):
        """Push a record into the ring (caller holds self.lock)."""
        self.seq += 1
        self.received[r.core_id] = self.received.get(r.core_id, 0) + 1
        if not r.valid:
            self.invalid += 1
        self.ring.append((self.seq, t, r))

    def note_counters(self, t, drops_by_core):
        """Advance the rate window (caller: sampler, once per tick)."""
        with self.lock:
            self.hist.append((t, dict(self.received), dict(drops_by_core)))

    # -- Demo generator (deterministic) --------------------------------------

    def tick_demo(self, dt):
        """Produce `dt` seconds of demo traffic -- purely from the tick index.

        Both cores walk the same slot sequence (the same walk on both cores,
        as on the board), with core 1 offset by half a lap -- so the table
        shows both ids alternating. ts keeps counting at clk_hz (the demo does
        what the board delivers once the AXIS timestamp is in; live records
        from before that carry W2==0 -- the UI states the difference).
        """
        if not AXIS_WP_HOST_AVAILABLE:
            # Record() lives in axis_wp_host -- without it there is nothing
            # to push. The rest of the demo (all other scenario traffic)
            # keeps running; only the watchpoint table stays empty.
            self.last_error = ("axis_wp_host not found -- watchpoint demo "
                                "traffic disabled (%s)" % _AXIS_WP_HOST_IMPORT_ERROR)
            return
        if not self.demo_sched:
            return
        rate = int((self.cfg.get("demo") or {}).get("rate_per_core", 300))
        clk = int(self.cfg.get("clk_hz", 75000000))
        n_sched = len(self.demo_sched)
        t = time.time()
        with self.lock:
            self.demo_tick += 1
            for core in (0, 1):
                carry = self.demo_carry.get(core, 0.0) + rate * dt
                n = int(carry)
                self.demo_carry[core] = carry - n
                base = self.received.get(core, 0) + (core * n_sched // 2)
                for k in range(n):
                    addr, slot = self.demo_sched[(base + k) % n_sched]
                    ts = int((self.demo_tick * dt * clk)
                             + core + 2 * k) & 0xFFFFFFFF
                    # W3 = {8'h00, core_id, tstrb=0xFFF (all 3 elements),
                    #       tid = core+1} -- demo mirrors the C0a final state
                    w3 = (core << 20) | (0xFFF << 8) | (core + 1)
                    self._push(t, Record(0, addr, slot, ts, w3))

    def demo_status(self):
        """A synthetic set of counters for /api/wp/status in demo mode."""
        with self.lock:
            fill = (self.demo_tick * 7) % 40        # deterministic sawtooth
            clk = int(self.cfg.get("clk_hz", 75000000))
            return {
                "magic_ok": True,
                "magic": self.cfg["magic"],
                "ftime": self.demo_tick * clk // 4,   # tick = 0.25 s
                "fifo_words": 4096,
                "shim_recs": 256,
                "cores": {str(c): {"drops": 0, "fill": fill, "ovf": 0}
                          for c in (0, 1)},
            }

    # -- JSON for the endpoints ----------------------------------------------

    def records_json(self, n=100):
        with self.lock:
            items = list(self.ring)[-n:]
            out = []
            for seq, t, r in items:
                out.append({
                    "seq": seq, "t": round(t, 3),
                    "core": r.core_id,
                    "pc": "0x%08X" % r.pc,
                    "sym": self.wp_syms.get(r.pc),
                    "slot": r.direct,               # W1 = Cmd[31:8] = Slot (SPEC §5)
                    "ts": "0x%08X" % r.ts,
                    "tid": r.tid, "tstrb": "0x%03X" % r.tstrb,
                    "valid": r.valid,
                    "errors": r.errors or None,
                })
            return {"records": out, "held": len(self.ring),
                    "total": dict((str(k), v) for k, v in self.received.items()),
                    "invalid": self.invalid, "malformed": self.malformed,
                    "wp_set": self.wp_syms_path,
                    "symbols": len(self.wp_syms)}

    def rates(self):
        """Records/s and drops/s per core, from the ~10 s rate window."""
        with self.lock:
            h = list(self.hist)
        if len(h) < 2:
            return {}
        t0, r0, d0 = h[0]
        t1, r1, d1 = h[-1]
        dt = t1 - t0
        if dt <= 0:
            return {}
        out = {}
        for core in sorted(set(r1) | set(d1)):
            out[str(core)] = {
                "rec_per_s": round((r1.get(core, 0) - r0.get(core, 0)) / dt, 1),
                "drop_per_s": round((d1.get(core, 0) - d0.get(core, 0)) / dt, 1),
            }
        return out

    def status_json(self, bus, demo):
        cfg = self.cfg
        base = {
            "scenario": self.sc.id if self.sc else None,
            "mode": "demo" if demo else "live",
            "drain_alive": self.drain_alive,
            "last_error": self.last_error,
            "received": dict((str(k), v) for k, v in self.received.items()),
            "invalid": self.invalid, "malformed": self.malformed,
            "held": len(self.ring),
            "rates": self.rates(),
            "wp_slots": int(cfg.get("wp_slots", 0)) if cfg else 0,
            "wp_set": self.wp_syms_path,
            "note": ("C0b state: 1023 WPs per encoder (loaded indirectly) + "
                     "AXIS TS (W2 = timestamp, tstrb 0xFFF). The D1 app "
                     "carries 15 slots (direct window) and W2=0 -- the "
                     "view still does not check TS monotonicity."),
        }
        if not cfg:
            return base
        if demo:
            base.update(self.demo_status())
            base["note"] += (" DEMO: deterministic generator (%d rec/s per "
                             "core) -- shows the mechanics, not the board load."
                             % int((cfg.get("demo") or {}).get("rate_per_core", 300)))
            return base
        # Live: the WPCTRL registers are read-only and free of side effects
        # (the one exception: FTIME_LO latches the snapshot -- hence LO BEFORE
        # HI).
        reg = cfg["wpctrl_region"]
        try:
            base["magic_ok"] = self._check_magic(bus)
            base["magic"] = "0x%08X" % (self.magic_val or 0)
            lo = bus.read(reg, int(cfg["ftime_lo"]))[0]
            hi = bus.read(reg, int(cfg["ftime_hi"]))[0]
            base["ftime"] = (hi << 32) | lo
            base["clk_hz"] = int(cfg.get("clk_hz", 0))
            base["fifo_words"] = bus.read(reg, int(cfg["fifo_words"]))[0]
            base["shim_recs"] = bus.read(reg, int(cfg["shim_recs"]))[0]
            cores = {}
            for f in cfg["fifos"]:
                cores[str(f["core"])] = {
                    "drops": bus.read(reg, int(f["drop"]))[0],
                    "fill": bus.read(reg, int(f["fill"]))[0],
                    "ovf": bus.read(reg, int(f["ovf"]))[0] & 1,
                }
            base["cores"] = cores
        except Exception as e:                     # noqa: BLE001
            base["status_error"] = str(e)
        return base

    def drops_by_core(self, bus, demo):
        """Drop counters per core for the rate window (live), or 0 (demo)."""
        if demo or not self.cfg:
            return {c: 0 for c in (0, 1)}
        reg = self.cfg["wpctrl_region"]
        return {f["core"]: bus.read(reg, int(f["drop"]))[0]
                for f in self.cfg["fifos"]}

    # -- Load WP table (POST /api/wp/load) -----------------------------------

    def load_table(self, bus, sc, slots, encs=None):
        """Write the WP table into the encoders -- ONLY while the cores stand.

        Safety contract (source: SPEC §6/§7):
          * the cores of the target encoders must be stopped (RAM/table
            consistency) -- this is checked PER CORE, no longer through a
            collective bit: a running core 0 must not block loading the table
            of core 1, the two have nothing to do with each other;
          * trTeControl.Active (b0) AND .Enable (b1) must be 0 on every target
            encoder. Enable is the HARDWARE interlock (swwel + the shim commit
            gate, SPEC §7); checking Active alone let through exactly the case
            where the hardware discards silently.
        A violation raises ValueError with the prefix 'CONFLICT' -- the
        handler turns that into HTTP 409.

        What gets written is the D1 DIRECT WINDOW `ENCx + wp_table_off + 8i`.
        That window no longer exists since the C0b rework (SPEC §7,
        ct_cs_cpuif_wb.sv:220-227), and the scenario map therefore no longer
        carries the key: if it is missing the request is refused instead of
        written without effect (the endpoint used to report ok=true for writes
        that reached no register). The indirect loader in the dashboard is
        still open.
        """
        cfg = self.cfg
        if not cfg:
            raise ValueError("scenario %r has no wp view" % (sc.id if sc else None))
        if cfg.get("wp_table_off") is None:
            raise ValueError(
                "this build has no direct watchpoint window: +0x4100 was "
                "removed with the C0b rebuild (1023 slots collide with the DF "
                "registers, docs/SPEC_axis_wp_memory_map.md §7) and a write "
                "there reaches NO register. Load the table indirectly instead "
                "(trWpIndex 0x400C / trWpDataLow 0x4010 / trWpDataHigh 0x4014 "
                "commit+autoincrement, ALL 1023 slots ascending): "
                "tools/axis_wp_host/wp_load_indirect. A dashboard-side "
                "indirect loader is open point H2 "
                "(docs/REPORT_axis_wp_completion.md §7).")
        n_max = int(cfg.get("wp_load_slots", cfg.get("wp_slots", 15)))
        if not slots or len(slots) > n_max:
            raise ValueError("need 1..%d slots, got %d" % (n_max, len(slots or [])))
        table = []
        for i, s in enumerate(slots):
            if isinstance(s, dict):
                a, c = s.get("addr"), s.get("cmd")
            else:
                a, c = s[0], s[1]
            a = int(a, 0) if isinstance(a, str) else int(a)
            c = int(c, 0) if isinstance(c, str) else int(c)
            table.append((i, a & 0xFFFFFFFF, c & 0xFFFFFFFF))
        C = sc.co("control")
        ctrl = bus.read("ctrl", C)[0]
        regions = [c_.get("enc") for c_ in sc.cores] if encs is None else encs
        # Only check the cores whose encoder is actually being written.
        for c_ in sc.cores:
            if c_.get("enc") in regions and sc.core_running(ctrl, c_):
                raise ValueError(
                    "CONFLICT: %s is running (CONTROL=0x%08X) -- load the WP "
                    "table of its encoder only while THAT core is halted; the "
                    "other cores may keep running (SPEC §10)"
                    % (c_.get("name") or ("core %s" % c_.get("id")), ctrl))
        off0 = int(cfg["wp_table_off"], 0) \
            if isinstance(cfg["wp_table_off"], str) else int(cfg["wp_table_off"])
        result = {}
        for region in regions:
            if region not in sc.regions:
                raise ValueError("unknown encoder region %r" % region)
            te = bus.read(region, 0)[0]
            # "disable trace first" reads like the "Encoder trace off" button
            # -- but that only clears InstTracing and leaves Enable standing
            # (measured on the board). So the message names the BIT and the
            # control that really drops it.
            if te & 0x3:               # trTeControl.Active (b0) / .Enable (b1)
                raise ValueError("CONFLICT: %s trTeControl %s=1 -- clear those "
                                 "bits first (trTeControl=0x%08X); Enable is "
                                 "the hardware lock (swwel), Active the "
                                 "search-tree rule. Use the 'TE enabled' switch "
                                 "on the encoder card -- 'Encoder trace off' "
                                 "clears InstTracing only"
                                 % (region,
                                    "/".join(n for n, b in (("Active", 1), ("Enable", 2))
                                             if te & b), te))
            for i, a, c in table:
                bus.write(region, off0 + 8 * i, a)
                bus.write(region, off0 + 8 * i + 4, c)
            result[region] = {
                "slot0_addr": "0x%08X" % bus.read(region, off0)[0],
                "slot0_cmd": "0x%08X" % bus.read(region, off0 + 4)[0],
            }
        return {"ok": True, "slots": len(table), "encoders": result}
