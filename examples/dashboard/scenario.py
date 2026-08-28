#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Scenario model of the CTTE dashboard.

A *scenario* is an app loadable on the KV260 (bitstream + device tree
overlay) together with everything the server and the UI need to know about
it: aperture regions, CTRL register map, cores/encoders, sinks, console,
decode configuration.

The reason for this layer is a concrete defect, not architectural cosmetics:
the CTRL register maps of the apps are NOT congruent. In `mbv`/`trio`, 0x10
holds `AXIS_BEATS` and 0x14 `TRACE_BUFSZ`; on the Linux CVA6, 0x10 holds
`TRACE_BUFSZ`, 0x14 `CON_BYTES`, 0x18 `CON_DROPS` -- and everything from
`SINK_CTRL` on is shifted by four bytes. A server with hard-wired offsets
reads silently wrong numbers on the other app (a ring capacity as a character
count, say) without anything reporting it.

Hence: no offset in the code, every offset from `scenarios.json`, and a
missing register name yields `None` instead of a wrong number.
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
CATALOG = HERE / "scenarios.json"


def _addr(v):
    """'0xA0000000' | 2684354560 -> int."""
    return int(v, 0) if isinstance(v, str) else int(v)


class Scenario:
    """One app variant. Every offset and base comes from scenarios.json."""

    def __init__(self, d):
        self.raw = d
        self.id = d["id"]
        self.title = d["title"]
        self.subtitle = d.get("subtitle", "")
        self.accent = d.get("accent", "#39d0ff")
        self.app = d.get("app")
        self.bitbin = d.get("bitbin")
        # A scenario can sit on the board in several bitstream variants that
        # are only distinguishable BY NAME: the encoder's address width
        # (`CT_XLEN`) is a synthesis parameter and appears in NO CSR. Without
        # this list the PL check mistakes a loaded 64-bit variant for a
        # foreign app and falls back to DEMO.
        self.app_variants = d.get("app_variants") or (
            [{"app": self.app, "enc_xlen": int(d.get("xlen", 32))}] if self.app else [])
        self.apps = [v["app"] for v in self.app_variants if v.get("app")]
        self.xlen = int(d.get("xlen", 32))          # address width of the CORE
        self.headline = d.get("headline", [])
        self.regions = {k: (_addr(v["base"]), int(v["size"]))
                        for k, v in d["regions"].items()}
        self.region_meta = d["regions"]
        self.ctrl = dict(d.get("ctrl", {}))
        self.control_bits = dict(d.get("control_bits", {}))
        self.status_bits = dict(d.get("status_bits", {}))
        self.cores = d.get("cores", [])
        self.sinks = d.get("sinks", {})
        self.console = d.get("console")
        self.decode = d.get("decode", {})
        self.symbols = d.get("symbols")
        self.sites = d.get("sites")
        self.features = set(d.get("features", []))

    # --- register access --------------------------------------------------
    def co(self, name):
        """The CTRL offset of a register -- None when this app does not have it.

        Deliberately None and not 0: a missing register should force the
        caller into a case distinction, not silently read CONTROL.
        """
        return self.ctrl.get(name)

    def cbit(self, name):
        """The bit mask of a CONTROL bit (0 when this app does not have it)."""
        b = self.control_bits.get(name)
        return 0 if b is None else (1 << b)

    def has(self, feature):
        return feature in self.features

    # --- Run state per core ---------------------------------------------
    # Every core has its OWN enable bit (CONTROL b8/b9, trio additionally
    # b10), and what takes effect is the OR with the older collective bit b0:
    # core_i_run_eff = b0 | b(8+i) (SPEC §10). Both bits are therefore listed
    # per core in `run_bits`; `run_bit` stays the core's OWN one.
    #
    # Why not STATUS b8/b9 as the source, even though it mirrors the effective
    # state: on a bitstream older than U1 those bits read 0 while the core
    # runs via b0 -- the view then reported "stopped" and the next RAM access
    # stalled the AXI transaction. CONTROL is right on both vintages, STATUS
    # only on the newer one.
    def core_run_bits(self, core):
        """Names of all CONTROL bits that enable this core."""
        rb = core.get("run_bits")
        if rb is None:
            rb = [core.get("run_bit") or "core_run"]
        return [b for b in rb if b in self.control_bits]

    def core_run_mask(self, core):
        """The mask of all release bits of this core (0 = core not controllable)."""
        m = 0
        for b in self.core_run_bits(core):
            m |= self.cbit(b)
        return m

    def core_protocol(self, core):
        """The trace protocol of this core's encoder, or None if undeclared.

        A DATA field, not a name comparison: which back end an encoder
        instance carries is a synthesis parameter, and the register that
        reports it (trTeProtocolSel) is read-only. A scenario that mixes
        protocols has to say so here, because the consequence is not visible
        anywhere else until a decode run fails.
        """
        p = core.get("protocol")
        return p.strip().lower() if isinstance(p, str) and p.strip() else None

    def protocols(self):
        """The distinct declared protocols of this scenario, sorted.

        Fewer than two means: nothing to interlock -- either the scenario is
        uniform, or it does not declare protocols at all (every scenario
        before the trio).
        """
        return sorted({p for p in (self.core_protocol(c) for c in self.cores)
                       if p})

    def core_own_bit(self, core):
        """The core's OWN enable bit (mask) -- 0 if only the collective bit exists."""
        return self.cbit(core.get("run_bit") or "")

    def core_running(self, ctrl, core):
        m = self.core_run_mask(core)
        return bool(m and (ctrl & m))

    def gate_core(self, region):
        """The core whose run state locks access to this region.

        Taken from the region's `gate_core` data field (scenarios.json), NOT
        from its label text: the rule has to be machine-evaluable, otherwise
        it lives in a caption and nobody checks it.
        """
        gc = (self.region_meta.get(region) or {}).get("gate_core")
        if gc is None:
            return None
        for c in self.cores:
            if c.get("id") == gc:
                return c
        return None

    def enc_regions(self):
        """Encoder regions in core order (enc, enc1, enc2 ...)."""
        return [c["enc"] for c in self.cores if c.get("enc") in self.regions]

    @property
    def interactive_console(self):
        return bool(self.console and self.console.get("interactive"))

    def variant_of(self, app):
        """The bitstream variant for a loaded app name -- None when it is foreign."""
        for v in self.app_variants:
            if v.get("app") == app:
                return v
        return None

    # --- Serialization for the UI ---------------------------------------
    def to_json(self):
        d = dict(self.raw)
        d.pop("_comment", None)
        d["regions"] = {k: {"base": "0x%08X" % b, "base_int": b, "size": s,
                            "label": self.region_meta[k].get("label", k)}
                        for k, (b, s) in self.regions.items()}
        return d


class Catalog:
    """All scenarios plus the active one."""

    def __init__(self, path=CATALOG):
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
        self.version = doc.get("version", 1)
        self.order = [s["id"] for s in doc["scenarios"]]
        self.by_id = {s["id"]: Scenario(s) for s in doc["scenarios"]}
        self.default = doc.get("default") or self.order[0]
        self.active_id = self.default

    @property
    def active(self):
        return self.by_id[self.active_id]

    def select(self, sid):
        if sid not in self.by_id:
            raise ValueError("unknown scenario %r (known: %s)"
                             % (sid, ", ".join(self.order)))
        self.active_id = sid
        return self.active

    def by_id_apps(self):
        """xmutil app names of all scenarios -- for the aperture safety check.

        Contains ALL variants, not just the primary one: a loaded 64-bit
        variant is just as much a known app as its 32-bit sibling.
        """
        out = set()
        for s in self.by_id.values():
            out.update(s.apps)
        return out

    def by_app(self, app):
        """The scenario a loaded app name belongs to -- None when foreign.

        This is the reverse lookup that takes work off the operator: someone
        loads the bitstream, and the dashboard should know which core is now
        inside it instead of waiting for a matching manual selection. Without
        this mapping the server reads the CTRL map of the WRONG design --
        exactly the silent read error this file exists for.
        """
        if not app:
            return None
        for i in self.order:
            if app in self.by_id[i].apps:
                return self.by_id[i]
        return None

    def list_json(self):
        return {"active": self.active_id, "version": self.version,
                "scenarios": [self.by_id[i].to_json() for i in self.order]}
