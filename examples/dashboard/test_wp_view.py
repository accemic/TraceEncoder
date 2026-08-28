#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""Gate H (offline): the AXIS watchpoint view without a board.

Checks what is checkable without /dev/mem:
  * scenario `tgc5b2_axis_wp` loads, all wp offsets lie inside their
    aperture, the map matches the SPEC (docs/SPEC_axis_wp_memory_map).
  * the wp_set symbol table loads from the repository path (PC -> name).
  * the demo generator is DETERMINISTIC: two fresh states deliver the same
    (core, pc, slot, ts) sequence.
  * records_json/status_json have the shape wp.html consumes.
  * the load_table safety contract: core_run=1 -> CONFLICT (handler: 409);
    trTeControl.Active=1 -> CONFLICT; otherwise writes to ENCx+0x4100+8i with
    a slot 0 readback (counter-check: the rejection MUST come, otherwise the
    protection would be decoration).
  * regression: DemoBus can be instantiated for EVERY scenario and
    build_poll only delivers regions that exist (the existing scenarios stay
    loadable).
  * U2: indexed register instances sit under ONE collapsed parent node. What
    is checked is the SHIPPED JS code -- groupRegRows/grpNode/
    renderRegGroups are cut out of index.html and executed against a DOM
    stub (needs `node`; without node the guard reports RED instead of
    skipping).

Invocation:  py tools/ctrace_dashboard/test_wp_view.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import server                       # noqa: E402
import wp_view                      # noqa: E402
from scenario import Catalog        # noqa: E402

FAILS = []
NCHECK = 0
SKIPS = []


def check(name, ok, info=""):
    global NCHECK
    NCHECK += 1
    print("  %-4s %s%s" % ("OK" if ok else "FAIL", name,
                           ("  " + info) if info else ""))
    if not ok:
        FAILS.append(name + ((" -- " + info) if info else ""))
    return ok


def skip(name, reason):
    """Record a clean skip -- distinct from FAILS, never turns the gate red."""
    SKIPS.append(name + ((" -- " + reason) if reason else ""))
    print("  SKIP %s%s" % (name, ("  " + reason) if reason else ""))


class FakeBus:
    """read/write mock in the dashboard bus format ({region: {off: val}})."""

    demo = False

    def __init__(self, init=None):
        self.mem = {}
        for region, vals in (init or {}).items():
            self.mem[region] = dict(vals)

    def read(self, region, off, n=1):
        m = self.mem.setdefault(region, {})
        return [m.get(off + 4 * i, 0) for i in range(n)]

    def write(self, region, off, value):
        self.mem.setdefault(region, {})[off] = value & 0xFFFFFFFF


# --- the shipped grouping code, against a DOM mock --------------------------
# Modelled on test_addr64.mjs: what gets checked is what the browser receives
# -- groupRegRows/grpNode/renderRegGroups are CUT OUT of index.html and
# executed. A reimplementation in Python would be a lie after the first edit to
# index.html; the Python mirror in test_block_csrs.py is therefore reconciled
# against exactly this run below.
# The mock cannot parse HTML -- and it does not need to: grpNode() fetches its
# two containers through querySelector('.ghead'/'.gbody'), and those are
# exactly what the mock returns (stable per selector), together with classList
# and appendChild. That makes the TREE STRUCTURE checkable (parent node ->
# instance node -> rows) without a jsdom dependency.
JS_GROUP_PROBE = r"""
import {readFileSync} from 'node:fs';
const [IDX, RMP, EDGEJSON] = process.argv.slice(2);
const HTML = readFileSync(IDX, 'utf8').replace(/\r\n/g, '\n');
const RES = [];
/* Keep the info texts to ASCII: the output goes through a Windows console
   in cp1252, and a caret glyph out of the innerHTML would abort the test run
   with a UnicodeEncodeError instead of judging it. */
const ck = (n, ok, info) => RES.push({name: n, ok: !!ok,
  info: info === undefined ? '' : String(info).replace(/[^\x20-\x7e]/g, '.')
                                              .slice(0, 160)});
function fn(name){
  const s = HTML.indexOf('function ' + name + '(');
  if (s < 0) throw new Error('function ' + name + '() is missing from index.html');
  const e = HTML.indexOf('\n}\n', s);
  if (e < 0) throw new Error('end of ' + name + '() not found');
  return HTML.slice(s, e + 2);
}
function cst(name){
  const m = new RegExp('^const ' + name + '=.*$', 'm').exec(HTML);
  if (!m) throw new Error('const ' + name + ' is missing from index.html');
  return m[0];
}
class El{
  constructor(tag){this.tag=tag;this._c=new Set();this._h='';this.kids=[];this._q={};}
  set className(v){this._c=new Set(String(v).split(/\s+/).filter(Boolean));}
  get className(){return [...this._c].join(' ');}
  get classList(){const s=this._c;return{
    add:c=>s.add(c), remove:c=>s.delete(c), contains:c=>s.has(c),
    toggle:c=>{if(s.has(c)){s.delete(c);return false;} s.add(c);return true;}};}
  set innerHTML(h){this._h=String(h);} get innerHTML(){return this._h;}
  appendChild(c){this.kids.push(c);return c;}
  querySelector(sel){return this._q[sel]||(this._q[sel]=new El(sel));}
}
try{
  const src = [cst('esc'), cst('REGGRP_OPEN'), cst('ARRIDX'),
               fn('groupRegRows'), fn('grpNode'), fn('renderRegGroups')].join('\n');
  const api = new Function('document', src +
    '\nreturn {groupRegRows, grpNode, renderRegGroups, REGGRP_OPEN};')(
      {createElement: t => new El(t)});
  const regs = JSON.parse(readFileSync(RMP, 'utf8')).regs;
  const paths = regs.map(r => r.path);
  const mk = ls => ls.map(l => ({label: l, el: {row: l}}));
  const flat = ns => {const o=[]; for(const n of ns){ if(n.leaf){o.push(n.leaf.label);}
    else{for(const i of n.group.idxs)for(const it of n.group.insts.get(i))o.push(it.label);} } return o;};
  const nodes = api.groupRegRows(mk(paths));
  const fil = nodes.filter(n => n.group).map(n => n.group)
                   .find(g => g.prefix.endsWith('trTeFilter'));
  ck('JS: parent node ct_cs_cpuif.te.trTeFilter[0..15] built',
     fil && fil.label === 'ct_cs_cpuif.te.trTeFilter[0..15]', fil ? fil.label : 'none');
  ck('JS: 16 instances / 112 registers under the node',
     fil && fil.insts.size === 16 && fil.n === 112,
     fil ? fil.insts.size + '/' + fil.n : '-');
  ck('JS: no register lost (expanded content == input)',
     JSON.stringify(flat(nodes)) === JSON.stringify(paths),
     flat(nodes).length + ' of ' + paths.length);
  ck('JS: non-array registers stay flat rows',
     nodes.filter(n => n.leaf).length === paths.filter(p => !p.includes('[')).length,
     nodes.filter(n => n.leaf).length + ' leaves');

  const list = new El('div');
  api.renderRegGroups(list, mk(paths), 'all', false);
  ck('DOM: the register card shows 56 nodes instead of 258', list.kids.length === 56,
     String(list.kids.length));
  const gel = list.kids.find(k => (k.innerHTML||'').includes('trTeFilter[0..15]'));
  ck('DOM: parent node present and COLLAPSED (default)',
     gel && !gel.classList.contains('open'), gel ? gel.className : 'missing');
  const gb = gel.querySelector('.gbody');
  ck('DOM: expanding shows 16 instance nodes', gb.kids.length === 16, String(gb.kids.length));
  const nrows = gb.kids.reduce((a, k) => a + k.querySelector('.gbody').kids.length, 0);
  ck('DOM: the instance nodes together carry 112 register rows', nrows === 112, String(nrows));
  ck('DOM: the header names the instance and register count',
     /16 instances/.test(gel.innerHTML) && /112 registers/.test(gel.innerHTML),
     gel.innerHTML.replace(/\s+/g, ' ').slice(0, 120));
  ck('DOM: instance node is named ct_cs_cpuif.te.trTeFilter[3]',
     gb.kids[3].innerHTML.includes('ct_cs_cpuif.te.trTeFilter[3]'),
     gb.kids[3].innerHTML.replace(/\s+/g, ' ').slice(0, 90));

  const l2 = new El('div');
  api.renderRegGroups(l2, mk(paths.filter(p => p.includes('trTeFilter'))), 'all', true);
  ck('DOM: a search expands the group (otherwise the filter counts invisible rows)',
     l2.kids[0].classList.contains('open'), l2.kids[0].className);
  ck('DOM: a search expands the instance nodes too',
     l2.kids[0].querySelector('.gbody').kids.every(k => k.classList.contains('open')));

  const l3 = new El('div');
  api.renderRegGroups(l3, mk(paths), 'all', false);
  l3.kids.find(k => (k.innerHTML||'').includes('trTeFilter[0..15]'))
    .querySelector('.ghead').onclick({stopPropagation(){}});
  ck('state: a click records the node in the client',
     api.REGGRP_OPEN['all:ct_cs_cpuif.te.trTeFilter'] === true,
     JSON.stringify(Object.keys(api.REGGRP_OPEN)));
  const l4 = new El('div');
  api.renderRegGroups(l4, mk(paths), 'all', false);
  ck('state: a redraw keeps the expansion',
     l4.kids.find(k => (k.innerHTML||'').includes('trTeFilter[0..15]')).classList.contains('open'));
  const l5 = new El('div');
  api.renderRegGroups(l5, mk(paths), 'panel:filters', false);
  ck('state: the panel has a namespace of its OWN (stays closed)',
     !l5.kids.find(k => (k.innerHTML||'').includes('trTeFilter[0..15]')).classList.contains('open'));

  const gapItems = mk(['f[0].A', 'f[1].A', 'f[5].A', 'f[5].B']);
  const gp = api.groupRegRows(gapItems);
  ck('gap: ONE node f[0..5] instead of sub-ranges',
     gp.length === 1 && gp[0].group.label === 'f[0..5]',
     gp.map(n => n.leaf ? n.leaf.label : n.group.label).join(','));
  const l6 = new El('div');
  api.renderRegGroups(l6, gapItems, 'x', false);
  ck('gap: the header names the missing indices',
     /not contiguous \(missing 2, 3, 4\)/.test(l6.kids[0].innerHTML),
     l6.kids[0].innerHTML.replace(/\s+/g, ' ').slice(0, 130));
  const one = api.groupRegRows(mk(['x[0].A', 'x[0].B', 'y']));
  ck('a single instance stays flat (no click without gain)',
     one.length === 3 && one.every(n => n.leaf));
  const l7 = new El('div');
  api.renderRegGroups(l7, mk(['y[0].A', 'y[1].A']), 'x', false);
  ck('an instance with ONE register skips the second level',
     l7.kids[0].querySelector('.gbody').kids.length === 2
     && l7.kids[0].querySelector('.gbody').kids.every(k => k.row));

  /* The mirror comparison runs over the real register list PLUS edge
     cases: the real card only knows rows with three or more instances, so a
     two-instance row or a gap would not occur in it at all -- the comparison
     would be blind to exactly those rules that are easiest to get wrong
     (measured: the mutation "threshold 2 -> 3" stayed undetected without the
     edge cases). */
  const edge = JSON.parse(EDGEJSON || '[]');
  const summary = api.groupRegRows(mk(paths.concat(edge))).map(n => n.leaf
    ? {kind: 'leaf', label: n.leaf.label}
    : {kind: 'group', label: n.group.label, prefix: n.group.prefix,
       insts: n.group.insts.size, n: n.group.n, gaps: n.group.gaps});
  console.log('U2SUMMARY ' + JSON.stringify(summary));
}catch(e){
  ck('the grouping code from index.html is executable', false, e.message);
}
console.log('U2RESULT ' + JSON.stringify(RES));
"""


# --- the SHIPPED display logic, against real fields from regmap.json --------
# The same construction as the probe above and for the same reason: a
# reimplementation in Python would be a lie after the first edit to
# index.html. What gets checked are the four functions the access truth in
# the browser hangs on -- badge, gate state and the run state per core.
JS_U4_PROBE = r"""
import {readFileSync} from 'node:fs';
const [IDX, RMP] = process.argv.slice(2);
const HTML = readFileSync(IDX, 'utf8').replace(/\r\n/g, '\n');
const RES = [];
const ck = (n, ok, info) => RES.push({name: n, ok: !!ok,
  info: info === undefined ? '' : String(info).replace(/[^\x20-\x7e]/g, '.')
                                              .slice(0, 160)});
function fn(name){
  const s = HTML.indexOf('function ' + name + '(');
  if (s < 0) throw new Error('function ' + name + '() is missing from index.html');
  const e = HTML.indexOf('\n}\n', s);
  if (e < 0) throw new Error('end of ' + name + '() not found');
  return HTML.slice(s, e + 2);
}
try{
  const STATE = {control: 0, status: 0, trTeControl: 0, trTeControl1: 0,
                 trTeControl2: 0};
  const SCEN = {control_bits: {core_run: 0, core0_run: 8, core1_run: 9},
                status_bits: {core0_running: 8, core1_running: 9},
                cores: [{id: 0, run_bit: 'core0_run', run_bits: ['core_run','core0_run']},
                        {id: 1, run_bit: 'core1_run', run_bits: ['core_run','core1_run']}]};
  const api = new Function('STATE', 'SCEN',
    [fn('accBadge'), fn('teEnabledOf'), fn('runningBitName'),
     fn('coreRunControl'), fn('coreRunStatus'), fn('coreRunning')].join('\n') +
    '\nreturn {accBadge, teEnabledOf, runningBitName, coreRunControl,' +
    ' coreRunStatus, coreRunning};')(STATE, SCEN);

  /* --- badge: real fields from regmap.json, no invented example -------- */
  const RM = JSON.parse(readFileSync(RMP, 'utf8'));
  const fieldOf = (path, name) => {
    const r = RM.regs.find(r => r.path.endsWith(path));
    return r && r.fields.find(f => f.name === name);
  };
  const b = (path, name) => api.accBadge(fieldOf(path, name));
  ck('badge: a locked field says Enable=0 (not "rw")',
     b('te.trTeControl','InstMode').txt === 'rw (Enable=0)',
     b('te.trTeControl','InstMode').txt);
  ck('badge: a W1C bit says w1c (RMW would clear it unnoticed otherwise)',
     b('te.trTeControl','InstStallOrOverflow').cls === 'w1c' &&
     b('te.trTeControl','InstStallOrOverflow').txt.indexOf('w1c') >= 0,
     b('te.trTeControl','InstStallOrOverflow').txt);
  ck('badge: a pulse bit says w1 pulse (always reads 0)',
     b('te.trTeControl','InstSyncReq').txt === 'w1 pulse',
     b('te.trTeControl','InstSyncReq').txt);
  ck('badge: a read side effect is marked',
     b('trWpReadHigh','Cmd').txt.indexOf('side-eff') >= 0,
     b('trWpReadHigh','Cmd').txt);
  ck('badge: a truly free field stays green rw',
     b('te.trTeTipFifoStatus','trTeTipFifoMaxFillClear').cls === 'rw',
     b('te.trTeTipFifoStatus','trTeTipFifoMaxFillClear').txt);
  ck('badge: a read-only field stays r',
     b('te.trTeImpl','VerMajor').txt === 'r' &&
     b('te.trTeImpl','VerMajor').cls === 'r',
     b('te.trTeImpl','VerMajor').txt);
  ck('counter-check: locked beats free (the colour is a warning, not green)',
     b('te.trTeControl','InstMode').cls === 'gated');

  /* --- gate state per region --- */
  STATE.trTeControl = 0x2; STATE.trTeControl1 = 0x0;
  ck('teEnabledOf: enc locked, enc1 open (per region, not global)',
     api.teEnabledOf('enc') === true && api.teEnabledOf('enc1') === false);

  /* --- run state per core (b0 | b(8+i)) --- */
  const set = (c, s) => {STATE.control = c; STATE.status = s;};
  set(0x1, 0x300);
  ck('b0 lets BOTH cores run',
     api.coreRunning(SCEN.cores[0]) && api.coreRunning(SCEN.cores[1]));
  set(0x200, 0x200);
  ck('b9 alone: only core 1 runs',
     !api.coreRunning(SCEN.cores[0]) && api.coreRunning(SCEN.cores[1]));
  set(0x0, 0x0);
  ck('nothing set: both are halted',
     !api.coreRunning(SCEN.cores[0]) && !api.coreRunning(SCEN.cores[1]));
  set(0x100, 0x0);          // bitstream without the mirror: it does not follow
  ck('bitstream without a mirror: CONTROL decides (core 0 runs)',
     api.coreRunning(SCEN.cores[0]) === true);
  ck('runningBitName: core1_run -> core1_running',
     api.runningBitName(SCEN.cores[1]) === 'core1_running');
  ck('runningBitName: cva6_run -> cva6_running (b5/b10 share the mirror)',
     api.runningBitName({run_bit: 'cva6_run'}) === 'cva6_running');
}catch(e){
  ck('the U4 display logic from index.html is executable', false, e.message);
}
console.log('U4RESULT ' + JSON.stringify(RES));
"""


# --- the bpi source and the empty graph, from the SHIPPED code --------------
# The same construction as the probes above. Two things have to hold here and
# neither of them can be reimplemented in Python without lying:
#   * bpiPoint() picks the source -- the hardware retire counter where one
#     exists, otherwise the decoded window, and there the decode figure
#     (denominator over ALL sources) rather than the single-target figure
#     next to it.
#   * drawSpark() draws into a canvas; what a context mock checks is WHICH
#     texts it sets. An empty graph without a reason was exactly the
#     reported finding.
JS_U5_PROBE = r"""
import {readFileSync} from 'node:fs';
const [IDX] = process.argv.slice(2);
const HTML = readFileSync(IDX, 'utf8').replace(/\r\n/g, '\n');
const RES = [];
const ck = (n, ok, info) => RES.push({name: n, ok: !!ok,
  info: info === undefined ? '' : String(info).replace(/[^\x20-\x7e]/g, '.')
                                              .slice(0, 160)});
function fn(name){
  const s = HTML.indexOf('function ' + name + '(');
  if (s < 0) throw new Error('function ' + name + '() is missing from index.html');
  const e = HTML.indexOf('\n}\n', s);
  if (e < 0) throw new Error('end of ' + name + '() not found');
  return HTML.slice(s, e + 2);
}
try{
  /* --- source selection: bpiPoint() -------------------------------------- */
  let SCEN = {ctrl: {control: 0, trace_bytes: 12, retires: 0x44}};
  const mk = () => new Function('SCEN',
    [fn('hasRetireCounter'), fn('bpiPoint')].join('\n') +
    '\nreturn {hasRetireCounter, bpiPoint};')(SCEN);
  let api = mk();
  const ON = {trTeControl: 1}, OFF = {trTeControl: 0};
  ck('a scenario WITH a retire counter is recognised', api.hasRetireCounter() === true);
  ck('hardware path: 800 bit over 100 instructions = 8.0 bpi',
     api.bpiPoint(ON, 1100, 1100, {r: 1000, b: 1000}, null) === 8,
     api.bpiPoint(ON, 1100, 1100, {r: 1000, b: 1000}, null));
  ck('hardware path: no value without a reference point (not 0)',
     api.bpiPoint(ON, 1100, 1100, null, null) === null);
  ck('hardware path: no retires -> null instead of 0 (0 would look like '
     + 'perfect compression)',
     api.bpiPoint(ON, 1000, 1100, {r: 1000, b: 1000}, null) === null);
  ck('the hardware path: encoder OFF -> null (instructions without bytes)',
     api.bpiPoint(OFF, 1100, 1100, {r: 1000, b: 1000}, null) === null);
  ck('the hardware path wins: a decoded window is NOT taken when there '
     + 'are counters',
     api.bpiPoint(ON, 1000, 1100, {r: 1000, b: 1000},
                  {ok: true, decode: {ok: true, bits_per_instr: 4.9}}) === null);

  /* --- SoC WITHOUT a retire counter (tgc5b2): the decoded window ------- */
  SCEN = {ctrl: {control: 0, trace_bytes: 12}};   // no 'retires'
  api = mk();
  const LIVE_OK = {ok: true, bits_per_instr: 9.81,
                   decode: {ok: true, bits_per_instr: 4.907}};
  ck('a scenario WITHOUT a retire counter is recognised', api.hasRetireCounter() === false);
  ck('the fallback source delivers the value of the decoded window',
     api.bpiPoint(ON, 0, 0, null, LIVE_OK) === 4.907,
     api.bpiPoint(ON, 0, 0, null, LIVE_OK));
  ck('the fallback source takes the decode number (denominator over ALL '
     + 'sources), NOT the single-target number beside it',
     api.bpiPoint(ON, 0, 0, null, LIVE_OK) !== LIVE_OK.bits_per_instr);
  ck('fallback source: failed decode -> null',
     api.bpiPoint(ON, 0, 0, null,
                  {ok: true, decode: {ok: false, bits_per_instr: 4.9}}) === null);
  ck('fallback source: no window yet -> null',
     api.bpiPoint(ON, 0, 0, null, null) === null);
  ck('fallback source: encoder OFF -> null',
     api.bpiPoint(OFF, 0, 0, null, LIVE_OK) === null);

  /* --- the empty graph names its reason (drawSpark) ---------------------- */
  const texts = [];
  const ctx = new Proxy({}, {get: (t, k) => {
    if (k === 'fillText') return (s) => texts.push(String(s));
    if (k === 'measureText') return () => ({width: 10});
    if (k === 'canvas') return {};
    return (typeof k === 'string' && /^(font|fillStyle|strokeStyle|lineWidth|textAlign|textBaseline)$/.test(k))
      ? '' : (() => {});
  }, set: () => true});
  const canvas = {width: 300, height: 60,
                  getBoundingClientRect: () => ({width: 300, height: 60}),
                  getContext: () => ctx};
  const env = {
    $: (id) => (id === 'spark' ? canvas : null),
    getComputedStyle: () => ({getPropertyValue: () => ''}),
    document: {documentElement: {}},
    pollMs: 1000, WINS: 30,
    STATE: {trTeControl: 1, control: 1},
    SCEN: {ctrl: {control: 0}, cores: [{id: 0, run_bit: 'core0_run',
                                        run_bits: ['core_run', 'core0_run']}],
           control_bits: {core_run: 0, core0_run: 8}, status_bits: {}},
    LIVE: null, BPI: [], BPIMAX: [],
  };
  const names = Object.keys(env);
  const mkSpark = (over) => {
    const e = Object.assign({}, env, over || {});
    return new Function(...names,
      [fn('hasRetireCounter'), fn('runningBitName'), fn('coreRunControl'),
       fn('coreRunStatus'), fn('coreRunning'), fn('drawSpark')].join('\n') +
      '\nreturn drawSpark;')(...names.map(k => e[k]));
  };
  const run = (over) => {texts.length = 0; mkSpark(over)(); return texts.join(' | ');};

  let t = run({BPI: [null, null], STATE: {trTeControl: 1, control: 0x101}});
  ck('an empty graph names a REASON instead of nothing',
     /no decoded window|Trace & Decode|waiting for/.test(t), t);
  t = run({BPI: [null], STATE: {trTeControl: 0, control: 0x101}});
  ck('the reason "encoder off" is named as such',
     /encoder trace is off/.test(t), t);
  t = run({BPI: [null], STATE: {trTeControl: 1, control: 0}});
  ck('the reason "no core is running" is named as such',
     /no core is running/.test(t), t);
  t = run({BPI: [null], STATE: {trTeControl: 1, control: 0x101},
           LIVE: {ok: true, decode: {ok: true, bits_per_instr: 4.9}}});
  ck('with a healthy decode it says "waiting for the first window"',
     /waiting for the first decode window/.test(t), t);
  t = run({BPI: [null], STATE: {trTeControl: 1, control: 0x101},
           LIVE: {ok: true, decode: {ok: false, bits_per_instr: 14342}}});
  ck('a FAILED decode is named as such (not as "nothing there yet") -- '
     + 'and its nonsense number is NOT drawn',
     /decode of the ring window FAILED/.test(t) && !/14342/.test(t), t);
  t = run({BPI: [4.9, 5.1], STATE: {trTeControl: 1, control: 0x101}});
  ck('with values there is NO empty hint left',
     !/no bpi|Trace & Decode|waiting for/.test(t), t);
  ck('the source is stated at the curve as long as there are no counters',
     /decoded window/.test(t), t);
  t = run({BPI: [4.9, 5.1],
           SCEN: Object.assign({}, env.SCEN,
                               {ctrl: {control: 0, retires: 0x44}})});
  ck('counter-check: WITH a retire counter "decoded window" is NOT there',
     !/decoded window/.test(t), t);

  /* --- build stamp: does the tab notice that it is outdated? ---------- */
  const badge = {style: {}, textContent: '', title: ''};
  const logs = [];
  const chk = new Function('UIBUILD', 'UISTALE', '$', 'log',
    fn('checkUiBuild') + '\nreturn checkUiBuild;')(
      null, false, (id) => (id === 'uibuild' ? badge : null),
      (m, warn) => logs.push(String(m)));
  chk('aaaaaaaa');
  ck('the build stamp of the first fetch is visible in the header',
     badge.textContent === 'ui aaaaaaaa' && badge.style.display === '',
     badge.textContent);
  chk('aaaaaaaa');
  ck('the same stamp -> no message (no permanent noise)',
     logs.length === 0 && badge.textContent === 'ui aaaaaaaa');
  chk('bbbbbbbb');
  ck('a different stamp -> the tab reports itself as STALE',
     /STALE, press F5/.test(badge.textContent) && logs.length === 1,
     badge.textContent + ' | ' + logs.join(' '));
  ck('the message names both states (old -> new)',
     /aaaaaaaa/.test(logs[0]) && /bbbbbbbb/.test(logs[0]), logs[0]);
  chk('cccccccc');
  ck('and it comes exactly ONCE, not on every fetch',
     logs.length === 1, String(logs.length));
}catch(e){
  ck('the U5 bpi logic from index.html is executable', false, e.message);
}
console.log('U5RESULT ' + JSON.stringify(RES));
"""


# --- the TE enable switch on the encoder card -------------------------------
# The same construction as the probes above: the SHIPPED code is executed, not
# a reimplementation. Three things have to hold, and none of them can be read
# off the source text:
#   * teLeds() builds one switch per card carrying the region of ITS OWN card
#     (a fixed 'enc' switched the wrong encoder in every multi-core scenario --
#     the same trap as the fixed row masks used to be), and it names the state
#     as a WORD, not only as a colour.
#   * setTeEnable() writes trTeControl.Enable through the EXISTING /api/write
#     path, leaves the remaining bits standing and masks out the W1C bits
#     (otherwise a whole-word write-back clears the overflow evidence in b12).
#   * one click triggers EXACTLY ONE write, even after many render passes
#     (teLeds runs on every poll tick -- with addEventListener instead of
#     assignment the handler stack grows and with it the number of writes).
JS_U7_PROBE = r"""
import {readFileSync} from 'node:fs';
const [IDX, RMP] = process.argv.slice(2);
const HTML = readFileSync(IDX, 'utf8').replace(/\r\n/g, '\n');
const RES = [];
const ck = (n, ok, info) => RES.push({name: n, ok: !!ok,
  info: info === undefined ? '' : String(info).replace(/[^\x20-\x7e]/g, '.')
                                              .slice(0, 160)});
function fn(name){
  const s = HTML.indexOf('function ' + name + '(');
  if (s < 0) throw new Error('function ' + name + '() is missing from index.html');
  const e = HTML.indexOf('\n}\n', s);
  if (e < 0) throw new Error('end of ' + name + '() not found');
  return HTML.slice(s, e + 2);
}
function cst(name){
  const m = new RegExp('^const ' + name + '=.*$', 'm').exec(HTML);
  if (!m) throw new Error('const ' + name + ' is missing from index.html');
  return m[0];
}
/* async functions need their keyword: fn() starts at 'function' and would
   leave the 'async ' in front of it behind -- the excerpt then contains an
   `await` in a non-async function and the build fails. It happened once,
   which is why it is held here instead of patched at the caller. */
function afn(name){
  const s = HTML.indexOf('async function ' + name + '(');
  if (s < 0) throw new Error('async function ' + name + '() is missing from index.html');
  const e = HTML.indexOf('\n}\n', s);
  if (e < 0) throw new Error('end of ' + name + '() not found');
  return HTML.slice(s, e + 2);
}
try{
  const RM = JSON.parse(readFileSync(RMP, 'utf8'));
  const writes = [];
  const logs = [];
  /* The mock only has to do what the switch touches -- innerHTML (text),
     classList, closest() and the one fetch substitute. */
  class El{
    constructor(){this._c=new Set();this._h='';this.onclick=null;this.onkeydown=null;}
    set innerHTML(h){this._h=String(h);} get innerHTML(){return this._h;}
    get classList(){const s=this._c;return{
      add:c=>s.add(c), remove:c=>s.delete(c), contains:c=>s.has(c),
      toggle:c=>{if(s.has(c)){s.delete(c);return false;} s.add(c);return true;}};}
  }
  const STATE = {trTeControl: 0, trTeControl1: 0, trTeControl2: 0};
  const swEl = new El();
  const env = {
    document: {querySelector: () => swEl},
    STATE, RM,
    api: async (p, o) => {const b = JSON.parse(o.body);
      writes.push(Object.assign({path: p}, b));
      return {ok: true, readback: b.value};},
    log: (m) => logs.push(String(m)),
    logEvent: () => {},
    render: () => {},
    paintGateState: () => {},
  };
  const names = Object.keys(env);
  const api = new Function(...names,
    [cst('esc'), cst('hex'), fn('teSwTitle'), fn('teLeds'),
     afn('setTeEnable')].join('\n') +
    '\nreturn {teSwTitle, teLeds, setTeEnable};')(...names.map(k => env[k]));

  /* --- what the card shows --------------------------------------------- */
  const card = new El();
  api.teLeds(card, 0x00000007, 'enc');          // Act|Enable|ITrace
  ck('the card carries a switch with the region of ITS card',
     /data-tesw="enc"/.test(card.innerHTML), card.innerHTML.slice(-90));
  ck('the state is a WORD, not just a colour',
     /TE enabled/.test(card.innerHTML), card.innerHTML.slice(-60));
  ck('the switch is reachable by keyboard (role+tabindex)',
     /role="button"/.test(card.innerHTML) && /tabindex="0"/.test(card.innerHTML));
  const card0 = new El();
  api.teLeds(card0, 0x00000005, 'enc');          // Enable = 0
  ck('Enable=0 -> the word changes (not just the class)',
     /TE disabled/.test(card0.innerHTML), card0.innerHTML.slice(-60));
  ck('Enable=0 also carries the warning class (colour BESIDE the word)',
     /class="tesw off"/.test(card0.innerHTML), card0.innerHTML.slice(-90));
  const card1 = new El();
  api.teLeds(card1, 0x00000007, 'enc1');
  ck('the second card carries enc1, not enc (the multi-core trap)',
     /data-tesw="enc1"/.test(card1.innerHTML), card1.innerHTML.slice(-90));

  /* --- the warning says what it costs ---------------------------------- */
  const tOn = api.teSwTitle('enc', true), tOff = api.teSwTitle('enc', false);
  ck('the warning names the price: the sinks run dry',
     /run dry/.test(tOn), tOn.slice(0, 80));
  ck('the warning names the gain: the locked CSRs become writable',
     /only way to unlock/.test(tOn));
  ck('the warning excludes the core (it keeps running)',
     /the core keeps running/.test(tOn));
  ck('the warning excludes the WP records too (not Enable-gated)',
     /not gated by Enable/.test(tOn));
  ck('counter-check: the switched-off state says that writing is allowed '
     + 'now',
     /writable right now/.test(tOff), tOff.slice(0, 80));

  /* --- what the click writes -------------------------------------------- */
  const trTe = RM.regs.find(r => r.region === 'enc' && r.offset === 0);
  const w1c = (trTe.fields || []).filter(f => f.w1c)
    .reduce((m, f) => (m | (((1 << (f.msb - f.lsb + 1)) - 1) << f.lsb)) >>> 0, 0);
  ck('regmap: trTeControl has a W1C bit (otherwise the next point checks '
     + 'nothing)', w1c !== 0, '0x' + w1c.toString(16));
  STATE.trTeControl = (0x014600EF | w1c) >>> 0;   // board value + overflow evidence
  writes.length = 0;
  await api.setTeEnable('enc', false);
  ck('a click writes EXACTLY ONCE', writes.length === 1, String(writes.length));
  ck('... and it does so over the existing path /api/write',
     writes[0] && writes[0].path === '/api/write', writes[0] && writes[0].path);
  ck('... on trTeControl of the RIGHT region (enc+0x000)',
     writes[0].region === 'enc' && writes[0].offset === 0,
     writes[0].region + '+' + writes[0].offset);
  ck('Enable (b1) falls', ((writes[0].value >>> 1) & 1) === 0,
     '0x' + (writes[0].value >>> 0).toString(16));
  ck('all remaining bits stay (no whole-word reset)',
     (writes[0].value & ~2 & ~w1c) === (STATE.trTeControl & ~2 & ~w1c),
     '0x' + (writes[0].value >>> 0).toString(16));
  ck('the W1C bit is MASKED OUT (the overflow evidence survives the switch)',
     (writes[0].value & w1c) === 0,
     '0x' + (writes[0].value >>> 0).toString(16));
  ck('the log names the consequence, not just the value',
     /Enable-locked CSRs are writable/.test(logs.join(' ')),
     logs.join(' ').slice(0, 120));

  STATE.trTeControl = 0x014600ED;                 // Enable = 0
  writes.length = 0;
  await api.setTeEnable('enc', true);
  ck('the other direction: Enable (b1) gets set',
     writes.length === 1 && ((writes[0].value >>> 1) & 1) === 1,
     '0x' + (writes[0].value >>> 0).toString(16));

  /* Region fidelity of the write path: enc1 must NOT read enc's trTeControl. */
  STATE.trTeControl = 0x00000002; STATE.trTeControl1 = 0x014600EF;
  writes.length = 0;
  await api.setTeEnable('enc1', false);
  ck('enc1 computes with trTeControl1 (not with the word of enc)',
     writes[0].region === 'enc1' &&
     (writes[0].value & ~2 & ~w1c) === (0x014600EF & ~2 & ~w1c),
     writes[0].region + ' 0x' + (writes[0].value >>> 0).toString(16));

  /* --- one click stays one write, even after 50 render passes ---------- */
  const card2 = new El();
  for (let i = 0; i < 50; i++) api.teLeds(card2, 0x00000007, 'enc');
  STATE.trTeControl = 0x00000007;
  writes.length = 0;
  const ev = {target: {closest: () => ({dataset: {tesw: 'enc'}})},
              stopPropagation: () => {}, preventDefault: () => {}};
  card2.onclick(ev);
  await new Promise(r => setImmediate(r));
  ck('50 render passes, one click -> one write (no handler pile-up)',
     writes.length === 1, String(writes.length));
  writes.length = 0;
  card2.onkeydown(Object.assign({key: 'Enter'}, ev));
  await new Promise(r => setImmediate(r));
  ck('the keyboard triggers the same single write', writes.length === 1,
     String(writes.length));
  writes.length = 0;
  card2.onkeydown(Object.assign({key: 'a'}, ev));
  await new Promise(r => setImmediate(r));
  ck('counter-check: an arbitrary key does NOT switch', writes.length === 0,
     String(writes.length));
  /* A click next to it (on a lamp) must write nothing. */
  writes.length = 0;
  card2.onclick({target: {closest: () => null}, stopPropagation: () => {}});
  await new Promise(r => setImmediate(r));
  ck('counter-check: a click beside the switch does not write',
     writes.length === 0, String(writes.length));
}catch(e){
  ck('the U7 switch logic from index.html is executable', false, e.message);
}
console.log('U7RESULT ' + JSON.stringify(RES));
"""

# The compact number formatting of the cards. What gets checked is the
# SHIPPED code, not a Python reimplementation -- a second implementation
# would be exactly the drift the guard is meant to prevent.
JS_U9_PROBE = r"""
import {readFileSync} from 'node:fs';
const [IDX] = process.argv.slice(2);
const HTML = readFileSync(IDX, 'utf8').replace(/\r\n/g, '\n');
const RES = [];
const ck = (n, ok, info) => RES.push({name: n, ok: !!ok,
  info: info === undefined ? '' : String(info).replace(/[^\x20-\x7e]/g, '.')
                                              .slice(0, 160)});
try{
  /* One contiguous excerpt of the page instead of individual functions:
     fmtCnt hangs on fmtN, WP_DROP_SAT and the two constants. Whoever moves
     one of them shows up here -- and that is the point. */
  const s = HTML.indexOf('function fmtB(');
  const e = HTML.indexOf('function renderLive(');
  if (s < 0 || e < 0 || e <= s) throw new Error('number block not found');
  const CODE = HTML.slice(s, e);
  const els = {};
  const $ = id => els[id] || (els[id] = {textContent: '', title: ''});
  const STATE = {};
  const api = new Function('$', 'STATE', CODE +
    '\nreturn {fmtCnt, setCnt, wpDropTxt, paintDdrWindow, CNT_COMPACT_FROM, '
    + 'CNT_UNITS};')($, STATE);
  const F = api.fmtCnt;

  ck('threshold stands as a constant (100 000)',
     api.CNT_COMPACT_FROM === 100000, String(api.CNT_COMPACT_FROM));
  const cases = [[0, '0'], [999, '999'], [12345, '12,345'],
                 [99999, '99,999'],          // last number written out in full
                 [100000, '100.0 k'],        // first compact one
                 [216251, '216.3 k'],        // from the screenshot
                 [1300000000, '1.3 G'],      // example from the requirement
                 [4294967295, 'saturated'],  // the saturation stop
                 [1500000, '1.5 M'], [2000000000000, '2.0 T']];
  for (const [v, want] of cases)
    ck('fmtCnt(' + v + ') = "' + want + '"', F(v) === want, F(v));
  ck('fmtCnt(null) stays the dash (no invented 0)', F(null) === '–',
     F(null));
  ck('fmtCnt(undefined) likewise', F(undefined) === '–', F(undefined));

  /* The actual promise is a LENGTH, not a format: the column has about ten
     characters, anything beyond that pushes the label out of the box. */
  let worst = {v: null, t: '', n: 0};
  for (let v = 0; v < 4294967296; v = v < 1000 ? v + 1 : Math.floor(v * 1.07) + 1) {
    const t = F(v);
    if (t.length > worst.n) worst = {v, t, n: t.length};
  }
  ck('no value below 2^32 gets longer than 9 characters (sampled over the '
     + 'whole range)', worst.n <= 9, 'longest: ' + worst.v + ' -> "'
     + worst.t + '" (' + worst.n + ')');
  ck('counter-check: the WRITTEN-OUT form would be longer (the problem that '
     + 'was reported)',
     (4294967294).toLocaleString('en-US').length > 9,
     (4294967294).toLocaleString('en-US'));

  /* setCnt: the number short, the exact value in the tooltip. Without the
     tooltip the rounding would be a loss of data. */
  api.setCnt('x1', 216251, 'beats dropped');
  ck('setCnt writes the compact number into the element',
     $('x1').textContent === '216.3 k', $('x1').textContent);
  ck('and the EXACT value into the tooltip',
     /216,251/.test($('x1').title) && /exact value/.test($('x1').title),
     $('x1').title);
  ck('the tooltip names WHAT is counted',
     /beats dropped/.test($('x1').title), $('x1').title);
  api.setCnt('x2', 4294967295, 'records dropped');
  ck('at the limit the word is there, and the tooltip says why',
     $('x2').textContent === 'saturated'
     && /SATURATED/.test($('x2').title), $('x2').title.slice(0, 90));
  api.setCnt('x3', null, 'AXIS beats');
  ck('a missing register stays the dash (not 0)',
     $('x3').textContent === '—', $('x3').textContent);
  api.setCnt('x4', 4096, 'beats');
  ck('a small number is written out in full on the card',
     $('x4').textContent === '4,096', $('x4').textContent);
  ck('wpDropTxt uses THE SAME function (no second rule)',
     api.wpDropTxt(216251) === F(216251)
     && api.wpDropTxt(4294967295) === 'saturated');

  /* The window display: the case the headless screenshot found -- control
     panel built before the first state had arrived. */
  api.paintDdrWindow();
  ck('empty state: a dash instead of "0x0 + 0 B"',
     $('d_win').textContent === '–' && /no value read yet/.test($('d_win').title),
     $('d_win').textContent + ' | ' + $('d_win').title.slice(0, 60));
  STATE.ddr_base = 0x50000000; STATE.ddr_size = 0x10000000;
  api.paintDdrWindow();
  ck('with state: base and size readable',
     $('d_win').textContent === '0x50000000 + 256.0 MiB', $('d_win').textContent);
  ck('and the tooltip names BOTH registers with their hex value',
     /DDR_BASE 0x50000000 \+ DDR_SIZE 0x10000000/.test($('d_win').title)
     && /403/.test($('d_win').title), $('d_win').title.slice(0, 120));
  STATE.ddr_size = 0x4000000;
  api.paintDdrWindow();
  ck('the display FOLLOWS a change (64 MiB instead of 256)',
     $('d_win').textContent === '0x50000000 + 64.0 MiB', $('d_win').textContent);
}catch(e){
  ck('the U9 number logic from index.html is executable', false, e.message);
}
console.log('U9RESULT ' + JSON.stringify(RES));
"""


def _run_tick_live_tests(sc, cfg):
    """Drain-Budget + RX-Resync: exercise WpState.tick_live() against a
    software-mocked FIFO bus.

    These mocks stand in for real hardware registers, but the PARSING they
    exercise (FifoMmS's PG080 read-packet loop) lives in axis_wp_host --
    tools/axis_wp_host, consumed not copied (wp_view.py docstring). Without
    it tick_live() is a documented no-op (see wp_view.AXIS_WP_HOST_AVAILABLE),
    real hardware or not, so this whole section is a clean SKIP rather than a
    FAIL when that library has not landed in this repository yet.
    """
    if not wp_view.AXIS_WP_HOST_AVAILABLE:
        skip("Drain-Budget + RX-Resync (tick_live via axis_wp_host)",
             "axis_wp_host not found -- tools/axis_wp_host is not part of "
             "this example")
        return

    print("== drain budget (board freeze class, finding 2) ==")
    # A FIFO that NEVER runs empty (producer faster than the drain -- about
    # 21k records/s produced per core against some 12.7k drained in total).
    # An "until empty" drain then never returns and suffocates the board (it
    # really happened). tick_live MUST return on its budget and must have
    # pushed the records it read.
    class EndlessFifoBus(FakeBus):
        def __init__(self, magic):
            super().__init__({"wpctrl": {0: magic}})
            self.pops = 0

        def read(self, region, off, n=1):
            if region in ("fifo0", "fifo1"):
                if off == 0x1C:                 # RDFO: always full
                    return [4096]
                if off == 0x24:                 # RLR: 16 B = 1 Record
                    return [16]
                if off == 0x20:                 # RDFD: counting pattern
                    self.pops += 1
                    k = self.pops - 1
                    core = 1 if region == "fifo1" else 0
                    w = (0xA6C, k & 0xFF, 0,
                         (core << 20) | (0xFFF << 8))[k % 4]
                    return [w]
            return super().read(region, off, n)

    w3 = wp_view.WpState()
    w3.reset(sc)
    bus3 = EndlessFifoBus(int(cfg["magic"], 0))
    w3.tick_live(bus3)                          # MUST return
    budget = int(cfg.get("drain_max", 1024))
    got = sum(w3.received.values())
    check("tick_live returns on a full FIFO (budget %d/FIFO)" % budget,
          got == 2 * budget, "received=%d" % got)
    check("budget records in the ring (pushed per batch, not only at the end)",
          len(w3.ring) == min(2 * budget, int(cfg.get("ring", 20000))))
    # The restart word-salad class (shown live on hardware): the FIRST bind
    # to a FIFO MUST reset the RX side (RDFR := 0xA5 + ISR W1C) -- otherwise
    # the drain inherits the half-read packet stream of the previous process
    # and permanently parses shifted records (core_ids 2..15).
    for reg in ("fifo0", "fifo1"):
        check("first bind %s: RX reset (RDFR=0xA5)" % reg,
              bus3.mem.get(reg, {}).get(0x18) == 0xA5)
        check("first bind %s: ISR W1C" % reg,
              bus3.mem.get(reg, {}).get(0x00) == 0xFFFFFFFF)

    print("== RX resync (packet boundary drift after a reset under load, H3) ==")
    # Shown live on hardware: a reset while the producer is writing can hit
    # the TLAST count in the middle of a record -- after that EVERY packet is
    # 4 words with shifted content (valid=False), permanently. The drain MUST
    # notice that and reset the affected FIFO again until the stream is
    # aligned; a healthy stream must NEVER be force-reset.
    class MisalignedFifoBus(FakeBus):
        """Delivers only shifted records until the SECOND RDFR reset."""

        def __init__(self, magic):
            super().__init__({"wpctrl": {0: magic}})
            self.resets = {"fifo0": 0, "fifo1": 0}
            self.k = 0

        def write(self, region, off, value):
            if region in self.resets and off == 0x18 and value == 0xA5:
                self.resets[region] += 1
            super().write(region, off, value)

        def read(self, region, off, n=1):
            if region in ("fifo0", "fifo1"):
                if off == 0x1C:
                    return [4096]
                if off == 0x24:
                    return [16]
                if off == 0x20:
                    self.k += 1
                    core = 1 if region == "fifo1" else 0
                    good = (0xA6C, 7, 0x1234,
                            (core << 20) | (0xFFF << 8) | (core + 1))
                    if self.resets[region] >= 2:
                        return [good[(self.k - 1) % 4]]
                    # shifted by one word: the W3 slot gets the PC ->
                    # tstrb partial -> Record.valid == False
                    return [good[self.k % 4]]
            return super().read(region, off, n)

    w4 = wp_view.WpState()
    w4.reset(sc)
    bus4 = MisalignedFifoBus(int(cfg["magic"], 0))
    for _ in range(4):
        w4.tick_live(bus4)
    check("resync triggered (2nd RDFR reset per FIFO)",
          bus4.resets["fifo0"] >= 2 and bus4.resets["fifo1"] >= 2,
          str(bus4.resets))
    with w4.lock:
        got_valid = sum(1 for _, _, r in w4.ring if r.valid)
    check("valid records flow after the resync", got_valid > 0,
          "valid=%d invalid=%d" % (got_valid, w4.invalid))
    check("resync reported in status (last_error)",
          bool(w4.last_error) and "resync" in (w4.last_error or "").lower())


def main():
    cat = Catalog()
    print("== scenario map ==")
    check("scenario present", "tgc5b2_axis_wp" in cat.by_id)
    sc = cat.by_id["tgc5b2_axis_wp"]
    cfg = sc.raw.get("wp") or {}
    check("wp block present", bool(cfg))

    # window layout per SPEC §1
    spec_regions = {"ctrl": 0xA0000000, "enc": 0xA0010000, "enc1": 0xA0020000,
                    "ram1": 0xA0080000, "ram": 0xA0100000, "trace": 0xA0200000,
                    "wpctrl": 0xA0400000, "fifo0": 0xA0410000,
                    "fifo1": 0xA0420000}
    for name, base in spec_regions.items():
        b, s = sc.regions.get(name, (None, 0))
        check("region %s @0x%08X" % (name, base), b == base,
              "is 0x%08X" % (b or 0))

    # WPCTRL offsets per SPEC §3 (word positions) -- in the aperture?
    wsize = sc.regions["wpctrl"][1]
    offs = {"magic_off": 0x00, "ftime_lo": 0x1C, "ftime_hi": 0x20,
            "fifo_words": 0x24, "shim_recs": 0x28}
    for k, want in offs.items():
        v = int(cfg.get(k, -1))
        check("wp.%s == 0x%02X" % (k, want), v == want, "is %r" % v)
        check("wp.%s in aperture" % k, 0 <= v < wsize)
    fifo_offs = {(0, "drop"): 0x04, (0, "fill"): 0x08, (0, "ovf"): 0x0C,
                 (1, "drop"): 0x10, (1, "fill"): 0x14, (1, "ovf"): 0x18}
    for f in cfg.get("fifos", []):
        for fld in ("drop", "fill", "ovf"):
            want = fifo_offs[(f["core"], fld)]
            check("wp.fifos[core %d].%s == 0x%02X" % (f["core"], fld, want),
                  int(f[fld]) == want)
        check("wp.fifos[core %d].region exists" % f["core"],
              f["region"] in sc.regions)
    check("MAGIC == AWP1", int(cfg.get("magic", "0"), 0) == 0x41575031)

    # --- sink window + ring size of the C0B_SINK3 build (SPEC §9) --------
    # The breakage this checks against really happened: in the C0B_DDR build
    # DDR_BEATS sat at 0x30, and since the shared sink window
    # (ct_trace_sinks) PIB_DROPS lives there. Whoever keeps the old number
    # reads discarded PIB beats and calls them DDR beats -- a plausible wrong
    # number, exactly the class scenarios.json exists for. The counter-check
    # against the RTL file header is done by test_rv64_scenarios; what stands
    # here is the SPEC position.
    sink_offs = {"sink_ctrl": 0x18, "ddr_base": 0x1C, "ddr_size": 0x20,
                 "ddr_wptr": 0x24, "sink_stat": 0x28, "ddr_drops": 0x2C,
                 "pib_drops": 0x30, "ddr_beats": 0x38}
    for k, want in sink_offs.items():
        check("ctrl.%s == 0x%02X (SPEC §9)" % (k, want), sc.co(k) == want,
              "is %r" % sc.co(k))
    check("0x30 is PIB_DROPS, NOT DDR_BEATS (the T2 break)",
          sc.co("ddr_beats") != 0x30 and sc.co("pib_drops") == 0x30)
    # The window size is no longer a number that stands here: the ring grew
    # from 256 KiB to 1 MiB, and TRACE_BUFSZ @0x10 reports it itself. The
    # region has to COVER the larger ring (mmap window), otherwise the dump
    # breaks off at the top end.
    check("the TRACE region covers the 1 MiB ring", sc.regions["trace"][1] >= 1 << 20,
          "%d B" % sc.regions["trace"][1])
    check("TRACE base unchanged 0xA0200000", sc.regions["trace"][0] == 0xA0200000)
    check("TRACE_BUFSZ sits at 0x10 (hosts read the size there)",
          sc.co("trace_bufsz") == 0x10, "is %r" % sc.co("trace_bufsz"))

    # --- app variants -- which build has the sinks? -----------------------
    vars_by_app = {v["app"]: v for v in sc.app_variants}
    check("app_variants knows tgc5b2_axis_wp_c0b_sink3 (PL_GUARD)",
          "tgc5b2_axis_wp_c0b_sink3" in vars_by_app,
          ", ".join(sorted(vars_by_app)))
    check("scenario sinks = the C0B_SINK3 build (URAM+DDR+PIB)",
          all(sc.sinks.get(k) for k in ("uram", "ddr", "pib")), repr(sc.sinks))
    for app in ("tgc5b2_axis_wp", "tgc5b2_axis_wp_c0b"):
        v = vars_by_app.get(app) or {}
        s2 = v.get("sinks") or {}
        check("%s: own sink declaration without DDR/PIB" % app,
              bool(s2) and not s2.get("ddr") and not s2.get("pib")
              and s2.get("uram"), repr(s2))
    check("the C0B_SINK3 variant inherits the scenario sinks (no override)",
          "sinks" not in (vars_by_app.get("tgc5b2_axis_wp_c0b_sink3") or {}))
    # And the user interface has to USE that distinction. A scenario field
    # nobody reads is decoration: s.sinks would take over again, and under
    # the old bitstream the tile would claim a DDR4 sink that does not exist
    # there (mirror check as for REG_HOME).
    idx = (HERE / "index.html").read_text(encoding="utf-8")
    check("index.html has scenSinks() (the variant beats the scenario)",
          "function scenSinks(" in idx)
    check("index.html reads sinks ONLY through scenSinks()",
          idx.count("scenSinks(") >= 4 and "SCEN?.sinks?.ddr" not in idx
          and "s.sinks&&s.sinks[k]" not in idx,
          "%d calls" % idx.count("scenSinks("))

    print("== wp_set / Demo-Generator ==")
    w = wp_view.WpState()
    w.reset(sc)
    # wp_set.txt lives in sw/axis_wp_demo/ (scenarios.json "wp_set"
    # candidates), which is the tgc5b2_axis_wp example's own bare-metal
    # payload -- not part of the dashboard-only migration this file is in
    # (examples/dashboard/, plan AP5), it lands with the tgc5b2_axis_wp
    # package under AP4. tick_demo() needs BOTH that symbol set (to build
    # its deterministic schedule) AND axis_wp_host (for the Record wire
    # format) -- either being absent makes the whole demo-generator section
    # a clean SKIP, not a FAIL, exactly like the RTL-tree sections in
    # test_rv64_scenarios.py.
    wp_demo_ready = wp_view.AXIS_WP_HOST_AVAILABLE and bool(w.wp_syms)
    if not wp_demo_ready:
        reasons = []
        if not wp_view.AXIS_WP_HOST_AVAILABLE:
            reasons.append("axis_wp_host not found (tools/axis_wp_host is "
                            "not part of this example)")
        if not w.wp_syms:
            reasons.append("wp_set.txt not found (sw/axis_wp_demo/ is not "
                            "part of this example)")
        skip("wp_set / Demo-Generator + records_json/status_json form",
             "; ".join(reasons))
    else:
        check("wp_set loaded", bool(w.wp_syms), "path=%s" % w.wp_syms_path)
        check("symbol name matches (0x1C8 -> entry:f000)",
              w.wp_syms.get(0x1C8) == "entry:f000",
              "is %r" % w.wp_syms.get(0x1C8))
        # wp_slots carries the C0b build size (1023); the wp_set batch has
        # fewer distinct addresses -- the schedule is the minimum of the two.
        check("Demo-Schedule = min(wp_slots, wp_set)",
              len(w.demo_sched) == min(int(cfg.get("wp_slots", 15)),
                                       len(set(w.wp_syms))),
              "sched=%d slots=%s set=%d" % (len(w.demo_sched),
                                            cfg.get("wp_slots"),
                                            len(set(w.wp_syms))))
        check("wp_slots is the C0b build (1023)",
              int(cfg.get("wp_slots", 0)) == 1023)
        check("wp_load_slots caps the D1 direct path (15)",
              int(cfg.get("wp_load_slots", 0)) == 15)

        def demo_seq(ticks):
            s = wp_view.WpState()
            s.reset(sc)
            for _ in range(ticks):
                s.tick_demo(0.25)
            return [(r.core_id, r.pc, r.direct, r.ts)
                    for _, _, r in list(s.ring)]

        a, b = demo_seq(4), demo_seq(4)
        check("demo deterministic (2 runs identical)", a == b and len(a) > 0,
              "%d records" % len(a))
        check("both cores present", {c for c, _, _, _ in a} == {0, 1})

        rj = w.records_json(10)
        check("records_json empty before any ticks", rj["records"] == [])
        for _ in range(2):
            w.tick_demo(0.25)
        rj = w.records_json(10)
        r0 = rj["records"][0]
        check("records_json shape",
              all(k in r0 for k in ("seq", "t", "core", "pc", "sym", "slot",
                                    "ts", "tid", "valid")))
        check("symbol resolved in the record", bool(r0["sym"]))
        st = w.status_json(FakeBus(), demo=True)
        check("status_json (demo) shape",
              all(k in st for k in ("scenario", "mode", "cores", "received",
                                    "rates", "wp_slots", "note")))
        check("status_json demo hint", "DEMO" in st["note"])
        check("the note names the C0b state (finding 5)",
              "C0b" in st["note"] and "1023" in st["note"], st["note"][:70])

    print("== load_table safety contract ==")
    w2 = wp_view.WpState()
    w2.reset(sc)
    # (0) WITHOUT a direct window the write is rejected instead of going
    # into the void. The scenario no longer carries `wp_table_off` --
    # +0x4100 does not exist in the C0b build (SPEC §7), yet the endpoint
    # used to report ok=true on writes that hit no register at all.
    check("the scenario carries NO direct window any more (0x4100 is gone)",
          cfg.get("wp_table_off") is None, str(cfg.get("wp_table_off")))
    try:
        w2.load_table(FakeBus({"ctrl": {0: 0}}), sc,
                      [{"addr": "0xA6C", "cmd": "0x41"}])
        check("rejected without a direct window", False, "no exception")
    except ValueError as e:
        check("rejected without a direct window",
              "no direct watchpoint window" in str(e), str(e)[:60])
        check("the rejection names the indirect path (migration instead of a dead end)",
              "0x400C" in str(e) and "wp_load_indirect" in str(e))
    # For the remaining cases, mimic the older app: ONE key more, otherwise
    # the same scenario -- the direct path is meant to live on unchanged for
    # that app.
    import copy
    raw_d1 = copy.deepcopy(sc.raw)
    raw_d1["wp"]["wp_table_off"] = "0x4100"
    from scenario import Scenario                                  # noqa: E402
    sc_d1 = Scenario(raw_d1)
    w2.reset(sc_d1)
    # (a) running TARGET CORE -> CONFLICT (the handler turns that into 409)
    bus = FakeBus({"ctrl": {0: 1}})
    try:
        w2.load_table(bus, sc_d1, [{"addr": "0xA6C", "cmd": "0x41"}])
        check("core_run=1 rejected", False, "no exception")
    except ValueError as e:
        check("core_run=1 rejected", str(e).startswith("CONFLICT"), str(e)[:60])
    # (a2) The core's OWN bit counts just as much -- b0=0, b9=1 means
    # "core 1 is running", and its table must not be loaded then.
    bus = FakeBus({"ctrl": {0: 0x200}})
    try:
        w2.load_table(bus, sc_d1, [{"addr": "0xA6C", "cmd": "0x41"}],
                      encs=["enc1"])
        check("CONTROL b9 (only core 1 runs) rejected", False, "no exception")
    except ValueError as e:
        check("CONTROL b9 (only core 1 runs) rejected",
              str(e).startswith("CONFLICT") and "core 1" in str(e).lower(),
              str(e)[:70])
    # (a3) ... and the running NEIGHBOUR no longer blocks: core 1 is
    # running, and the table being loaded is core 0's. That used to be
    # forbidden.
    bus = FakeBus({"ctrl": {0: 0x200}})
    res = w2.load_table(bus, sc_d1, [{"addr": "0xA6C", "cmd": "0x41"}],
                        encs=["enc"])
    check("a running neighbour core does NOT block the other table",
          res["ok"] and list(res["encoders"]) == ["enc"])
    # (b) active encoder -> CONFLICT
    bus = FakeBus({"ctrl": {0: 0}, "enc": {0: 1}})
    try:
        w2.load_table(bus, sc_d1, [{"addr": "0xA6C", "cmd": "0x41"}])
        check("Active=1 rejected", False, "no exception")
    except ValueError as e:
        check("Active=1 rejected", str(e).startswith("CONFLICT"), str(e)[:60])
    # (b2) Enable=1 is the HARDWARE bar (swwel + shim commit gate) and used
    # to be UNCHECKED -- exactly the case where the hardware discards
    # silently and the endpoint reported success.
    bus = FakeBus({"ctrl": {0: 0}, "enc": {0: 2}})
    try:
        w2.load_table(bus, sc_d1, [{"addr": "0xA6C", "cmd": "0x41"}])
        check("Enable=1 rejected (HW bar)", False, "no exception")
    except ValueError as e:
        check("Enable=1 rejected (HW bar)",
              str(e).startswith("CONFLICT") and "Enable" in str(e), str(e)[:70])
    # (c) good case: writes to 0x4100/0x4104 + readback
    bus = FakeBus({"ctrl": {0: 0}})
    res = w2.load_table(bus, sc_d1, [{"addr": "0x00000A6C", "cmd": "0x00000041"},
                                     ["0x1C8", "0x141"]])
    check("good case ok", res["ok"] and res["slots"] == 2)
    check("ENC-Write Slot0 addr", bus.mem["enc"].get(0x4100) == 0xA6C)
    check("ENC-Write Slot1 cmd", bus.mem["enc"].get(0x410C) == 0x141)
    check("both encoders described", "enc1" in res["encoders"])
    check("Readback Slot0", res["encoders"]["enc"]["slot0_addr"] == "0x00000A6C")
    # (d) slot cap
    try:
        w2.load_table(bus, sc_d1, [["0x0", "0x0"]] * 16)
        check("16 slots rejected (max 15)", False)
    except ValueError:
        check("16 slots rejected (max 15)", True)
    w2.reset(sc)

    # ------------------------------------------------------------------
    # access truth + per-core start/stop (server side)
    # ------------------------------------------------------------------
    print("== U4: gate, read-back comparison, W1C, destructive windows ==")
    # (1) Enable bar: a locked field with the encoder armed is REJECTED
    # instead of being discarded silently. The counter-check (Enable=0) has
    # to pass -- a bar that always locks is not a bar.
    gb = FakeBus({"enc": {0: 0x2}})            # trTeControl.Enable = 1
    r_gate = server.write_gate_reason(gb, "enc", 0x400)   # trTeFilter[0].Control
    check("a locked field while Enable=1 -> CONFLICT",
          bool(r_gate) and r_gate.startswith("CONFLICT"), (r_gate or "")[:60])
    check("the reason names the silence (no error code from the hardware)",
          bool(r_gate) and "WITHOUT an error response" in r_gate)
    check("counter-check Enable=0 -> no interlock",
          server.write_gate_reason(FakeBus({"enc": {0: 0}}), "enc", 0x400) is None)
    check("counter-check, an unlocked field (trTeTipFifoStatus) -> no interlock",
          server.write_gate_reason(gb, "enc", 0xE04) is None)
    # Regression (measured in the smoke run): the bar must NOT sit in front
    # of the register that carries the Enable bit itself -- otherwise it is a
    # door that only opens from the inside, and "trace off" fails on the very
    # lock it is meant to lift. The same holds for mixed registers: a 409
    # would forbid a permitted live change there. The example is trTsControl
    # (Type/Prescale locked, Active/Enable free) -- NOT trTeInstFeatures any
    # more, see below.
    check("trTeControl stays writable (it carries the Enable bit itself)",
          server.write_gate_reason(gb, "enc", 0x000) is None)
    check("a mixed register (trTsControl) is not rejected",
          server.write_gate_reason(gb, "enc", 0x040) is None)
    # Since the vendored sync to CTTE 8b5e41eeda the eight InstEn* bits
    # are themselves Enable-locked. That makes trTeInstFeatures NO LONGER a
    # mixed register -- all ten writable fields are locked, and the bar has
    # to catch it in front. This very line used to be the counter-check "is
    # not rejected"; it went red with the sync and is deliberately inverted
    # here.
    r_feat = server.write_gate_reason(gb, "enc", 0x008)
    check("trTeInstFeatures is rejected while Enable=1 (U11: all 10 fields locked)",
          bool(r_feat) and r_feat.startswith("CONFLICT"), (r_feat or "")[:60])
    for _f in ("InstEnImplicitReturn", "InstEnBranchPrediction",
               "InstEnJumpTargetCache", "InstEnRepeatedHistory",
               "InstEnRepeatBranch", "InstEnWideIcnt", "InstEnIbhs",
               "InstEnRepeatInstr", "SrcID", "SrcBits"):
        check("... and names %s explicitly" % _f, _f in (r_feat or ""))
    check("counter-check Enable=0: trTeInstFeatures passes",
          server.write_gate_reason(FakeBus({"enc": {0: 0}}), "enc", 0x008) is None)
    check("... and the read-back comparison reports a fizzled field field by field",
          any("SrcID" in d for d in server.readback_diff(
              server.reg_at("enc", 0x008), 0x00010000, 0x0)),
          "; ".join(server.readback_diff(server.reg_at("enc", 0x008),
                                         0x00010000, 0x0))[:60])
    # Count check against regmap.json: eight InstEn* fields carry the gate.
    _feat = server.reg_at("enc", 0x008)
    check("regmap.json: 8 InstEn* fields carry gated",
          sum(1 for f in _feat["fields"]
              if f["name"].startswith("InstEn") and f.get("gated")) == 8,
          str(sum(1 for f in _feat["fields"]
                  if f["name"].startswith("InstEn") and f.get("gated"))))
    check("counter-check, the SoC window (ctrl) -> no Enable interlock",
          server.write_gate_reason(gb, "ctrl", 0x00) is None)

    # (2) Read-back: the intended value has to arrive in the fields that CAN
    # carry it. Pulse/W1C/HW fields are excluded, otherwise the guard cries
    # wolf constantly and ends up switched off.
    te = server.reg_at("enc", 0x000)
    check("readback_mask kennt trTeControl", te is not None and
          server.readback_mask(te) != 0)
    check("readback_mask leaves the W1C bit b12 OUT",
          not (server.readback_mask(te) >> 12) & 1)
    check("the deviation is named (field name + expected/actual)",
          any("InstTracing" in d for d in
              server.readback_diff(te, 0x7, 0x3)),
          "; ".join(server.readback_diff(te, 0x7, 0x3))[:80])
    check("counter-check: the same value -> no deviation",
          server.readback_diff(te, 0x7, 0x7) == [])

    # (3) W1C mask: the overflow evidence survives a whole-word write-back.
    check("w1c_mask(trTeControl) == b12", server.w1c_mask("enc", 0x000) == 1 << 12,
          hex(server.w1c_mask("enc", 0x000)))
    check("w1c_mask(trTeDataControl) == b3|b5",
          server.w1c_mask("enc", 0x010) == (1 << 3 | 1 << 5),
          hex(server.w1c_mask("enc", 0x010)))
    check("rmw_value clears the W1C bit from the write-back value",
          server.rmw_value("enc", 0x000, 0x1FFF) == 0x1FFF & ~(1 << 12))
    check("counter-check: a register without W1C stays unchanged",
          server.rmw_value("enc", 0xE04, 0xFFFF) == 0xFFFF)

    # (4) Read side effects are a DATA PROPERTY in regmap.json -- the poller
    # filters on that, not on names (the old name filter caught
    # TipFifoHistData and missed trWpReadHigh).
    se = [r["path"] for r in server.REGMAP["regs"] if r.get("read_side_effect")]
    check("regmap marks EXACTLY the two read-side-effect registers",
          sorted(se) == ["ct_cs_cpuif.te.trTeTipFifoHistData",
                         "ct_cs_cpuif.trWpReadHigh"], ", ".join(sorted(se)))
    check("trWpReadHigh.Cmd carries swacc",
          any(f.get("swacc") for f in server.reg_at("enc", 0x401C)["fields"]))

    print("== U4/U1: per-core start/stop and window gating ==")

    class FakeSocBus(FakeBus):
        """CTRL window like the SoC top: STATUS mirrors the EFFECTIVE run
        state (b8/b9 = b0 | b(8+i), tgc5b2_axis_soc_top.sv:584).
        `mirror=False` reproduces a bitstream BEFORE U1 -- there the mirror
        bits read a constant 0 although b0 lets the cores run."""

        def __init__(self, scn, ctrl=0, mirror=True):
            super().__init__({"ctrl": {0: ctrl, 4: 0}})
            self.scn, self.mirror = scn, mirror
            self._sync()

        def _sync(self):
            ctrl = self.mem["ctrl"].get(0, 0)
            st = 0
            if self.mirror:
                for c in self.scn.cores:
                    b = self.scn.status_bits.get(server._running_bit_name(c))
                    if b is not None and self.scn.core_running(ctrl, c):
                        st |= 1 << b
            self.mem["ctrl"][4] = st

        def write(self, region, off, value):
            super().write(region, off, value)
            if region == "ctrl" and off == 0:
                self._sync()

    check("core 0 carries b8, core 1 carries b9 (SPEC §10)",
          sc.core_own_bit(sc.cores[0]) == 0x100
          and sc.core_own_bit(sc.cores[1]) == 0x200)
    check("effective is b0 OR b(8+i)",
          sc.core_run_mask(sc.cores[0]) == 0x101
          and sc.core_run_mask(sc.cores[1]) == 0x201)
    check("b0 alone lets BOTH cores run (the collective bit stays valid)",
          sc.core_running(0x1, sc.cores[0]) and sc.core_running(0x1, sc.cores[1]))
    check("counter-check: b9 alone lets ONLY core 1 run",
          not sc.core_running(0x200, sc.cores[0])
          and sc.core_running(0x200, sc.cores[1]))

    # A single-core stop out of the collective state: b0 has to fall and the
    # other core gets ITS bit -- otherwise the stop takes the neighbour along.
    b = FakeSocBus(sc, ctrl=0x1)
    before, after, hint = server.set_core_run(b, sc, 0, False)
    check("single stop from b0: core 0 stands still", not sc.core_running(after, sc.cores[0]),
          "CONTROL 0x%X -> 0x%X" % (before, after))
    check("single stop from b0: core 1 KEEPS running (b9 set)",
          sc.core_running(after, sc.cores[1]) and (after & 0x200), hex(after))
    check("single stop from b0: no hint needed", hint is None, str(hint))
    check("the STATUS mirror follows (b9 set, b8 not)",
          b.read("ctrl", 4)[0] == 0x200, hex(b.read("ctrl", 4)[0]))
    _, after2, _ = server.set_core_run(b, sc, 1, True)
    check("starting core 1 afterwards does not change core 0",
          not sc.core_running(after2, sc.cores[0]))
    _, after3, _ = server.set_core_run(b, sc, 0, True)
    check("both started individually -> b8|b9", after3 & 0x300 == 0x300, hex(after3))

    # A bitstream without the per-core bits: the mirror does not follow ->
    # undo it and say why. Without this probe a single-core stop would have
    # halted BOTH cores there and nobody would have learned about it.
    old = FakeSocBus(sc, ctrl=0x1, mirror=False)
    b4, a4, hint4 = server.set_core_run(old, sc, 0, False)
    check("bitstream before U1: CONTROL is reset", a4 == b4 == 0x1, hex(a4))
    check("bitstream before U1: the hint names the missing mirror",
          bool(hint4) and "WITHOUT per-core run bits" in hint4, str(hint4)[:70])

    # Window gating PER CORE: the RAM of the running core is locked, that of
    # the halted one is not -- exactly the capability per-core control adds.
    g = FakeSocBus(sc, ctrl=0x200)             # only core 1 is running
    check("RAM1 while core 1 runs -> rejected (a hanging AXI is prevented)",
          bool(server.region_hold_reason(g, sc, "ram1")))
    check("the rejection names the hang, not just 'forbidden'",
          "HANG" in (server.region_hold_reason(g, sc, "ram1") or ""))
    check("RAM0 while core 0 is stopped -> allowed (reloading during operation)",
          server.region_hold_reason(g, sc, "ram") is None)
    g2 = FakeSocBus(sc, ctrl=0x1)              # collective bit: both are running
    check("b0: BOTH RAM windows locked",
          bool(server.region_hold_reason(g2, sc, "ram"))
          and bool(server.region_hold_reason(g2, sc, "ram1")))
    g3 = FakeSocBus(sc, ctrl=0x0)
    check("counter-check: stopped cores -> both windows open",
          server.region_hold_reason(g3, sc, "ram") is None
          and server.region_hold_reason(g3, sc, "ram1") is None)
    check("non-RAM regions are never gated (encoders hang on Enable)",
          server.region_hold_reason(g2, sc, "enc") is None
          and server.region_hold_reason(g2, sc, "wpctrl") is None)
    check("destructive read windows are named (fifo0/fifo1)",
          tuple(server.DESTRUCTIVE_READ_REGIONS) == ("fifo0", "fifo1"))

    # The rule is a DATA FIELD, not a label text -- otherwise the server
    # could not evaluate it.
    for sid, want in (("tgc5b2_axis_wp", {"ram": 0, "ram1": 1}),
                      ("trio", {"ram": 0, "ram1": 1}),
                      ("mbv", {"ram": 0})):
        s2 = cat.by_id[sid]
        for reg, cid in want.items():
            gc = s2.gate_core(reg)
            check("%s/%s: gate_core -> core %d" % (sid, reg, cid),
                  gc is not None and gc.get("id") == cid,
                  str(gc and gc.get("id")))
    check("trio: the CVA6 does NOT hang on the collective bit b0",
          cat.by_id["trio"].core_run_mask(cat.by_id["trio"].cores[2]) == 0x420,
          hex(cat.by_id["trio"].core_run_mask(cat.by_id["trio"].cores[2])))
    check("trio: b10 is the alias of the historical b5",
          cat.by_id["trio"].control_bits.get("cva6_run") == 5
          and cat.by_id["trio"].control_bits.get("cva6_run2") == 10)

    # Regression (measured in the smoke run): the demo bus has to follow the
    # STATUS mirror IMMEDIATELY, the way the RTL wires it combinationally. If
    # it only followed on the 250 ms tick, the capability probe in
    # set_core_run read the OLD mirror, took the build for an older one and
    # undid every single-core stop -- the function was completely dead in
    # DEMO.
    db = server.DemoBus(sc)
    db.write("ctrl", 0, 0x200)
    check("DemoBus: the STATUS mirror follows in the SAME access (b9)",
          db.read("ctrl", 4)[0] & 0x300 == 0x200, hex(db.read("ctrl", 4)[0]))
    db.write("ctrl", 0, 0x1)
    check("DemoBus: the collective bit mirrors both cores",
          db.read("ctrl", 4)[0] & 0x300 == 0x300, hex(db.read("ctrl", 4)[0]))
    db.write("ctrl", 0, 0x0)
    check("DemoBus: the mirror falls back to 0",
          db.read("ctrl", 4)[0] & 0x300 == 0, hex(db.read("ctrl", 4)[0]))
    # ... and the W1C evidence survives a whole-word write-back.
    db.write("enc", 0x000, 0x1000)
    check("DemoBus: a write cannot SET the W1C bit",
          not (db.read("enc", 0)[0] >> 12) & 1, hex(db.read("enc", 0)[0]))

    _run_tick_live_tests(sc, cfg)

    # ------------------------------------------------------------------
    # the protocol interlock: N-Trace and E-Trace must not run together
    # ------------------------------------------------------------------
    # The trio carries two N-Trace encoders and one E-Trace encoder in one
    # netlist. The funnel merges them correctly -- but the frame length of
    # every beat sits in the ATB signal ATBYTES, and NONE of the three sinks
    # stores it. A merged ring is therefore undecodable for ALL targets, not
    # only the third one: the decode aborts at the framing.
    #
    # Without the interlock nothing announces that. The ring fills, the
    # counters look healthy, and the decode fails somewhere else entirely --
    # the class of defect where every number says "fine".
    print("== protocol interlock: not two protocols at once ==")
    tri = cat.by_id.get("trio")
    check("the trio declares its protocols as DATA (not by name)",
          tri is not None and tri.protocols() == ["etrace", "ntrace"],
          repr(tri.protocols()) if tri else "no trio")
    check("... per core: two speak N-Trace, one E-Trace",
          [tri.core_protocol(c) for c in tri.cores]
          == ["ntrace", "ntrace", "etrace"],
          repr([tri.core_protocol(c) for c in tri.cores]))

    # An N-Trace core is running; the E-Trace core must be refused.
    g_n = FakeSocBus(tri, ctrl=tri.core_own_bit(tri.cores[0]))
    lock = server.protocol_lock_reason(g_n, tri, 2)
    check("N-Trace runs -> starting the E-Trace core is REFUSED",
          bool(lock) and lock.startswith("CONFLICT"), repr(lock)[:70])
    check("... and the refusal names the reason (ATBYTES), not just 'no'",
          bool(lock) and "ATBYTES" in lock, repr(lock)[:70])

    # The counter-check that makes the interlock a bar rather than a wall:
    # the SECOND N-Trace core may start, because that stream stays uniform.
    check("counter-check: the second N-Trace core is NOT refused",
          server.protocol_lock_reason(g_n, tri, 1) is None,
          repr(server.protocol_lock_reason(g_n, tri, 1))[:60])

    # And the other direction, so the rule is not one-sided.
    g_e = FakeSocBus(tri, ctrl=tri.core_own_bit(tri.cores[2]))
    check("E-Trace runs -> starting an N-Trace core is REFUSED",
          bool(server.protocol_lock_reason(g_e, tri, 0)),
          repr(server.protocol_lock_reason(g_e, tri, 0))[:70])

    # Nothing running: every core may start.
    g_0 = FakeSocBus(tri, ctrl=0)
    check("nothing running -> no core is refused",
          all(server.protocol_lock_reason(g_0, tri, i) is None
              for i in range(len(tri.cores))))

    # The collective bit releases EVERY core at once -- in a mixed scenario
    # that is exactly the merged stream, so it is refused outright.
    check("the collective start is refused in a mixed scenario",
          bool(server.protocol_lock_reason(g_0, tri, None)),
          repr(server.protocol_lock_reason(g_0, tri, None))[:70])
    check("... and it names the way out (start the cores individually)",
          "core_run" in (server.protocol_lock_reason(g_0, tri, None) or ""))

    # The interlock must not fire where it must not: a scenario that declares
    # no protocols keeps behaving exactly as before.
    for other in ("rocket2", "duo", "cva6_linux"):
        o = cat.by_id.get(other)
        if not o:
            continue
        ob = FakeSocBus(o, ctrl=o.core_own_bit(o.cores[0]) or 1)
        check("counter-check %s: uniform scenario, interlock stays silent" % other,
              o.protocols() == []
              and all(server.protocol_lock_reason(ob, o, i) is None
                      for i in range(len(o.cores)))
              and server.protocol_lock_reason(ob, o, None) is None,
              repr(o.protocols()))

    # The user interface has to say it BEFORE the click. A button that
    # answers with an error is worse than one that says why it is closed.
    check("index.html computes the reason from the scenario data",
          "function protoLockReason(" in idx and "c.protocol" in idx)
    check("... and passes it into runStop for every core row",
          idx.count("protoLockReason(") >= 4)
    check("... the shown reason names ATBYTES, not just 'blocked'",
          "do not store ATBYTES" in idx)
    _srv = (HERE / "server.py").read_text(encoding="utf-8")
    check("the server refuses the same combination (single core AND collective)",
          "protocol_lock_reason(bus, SC, idx)" in _srv
          and "protocol_lock_reason(bus, SC, None)" in _srv)

    print("== regression: the existing scenarios ==")
    for sid in cat.order:
        s = cat.by_id[sid]
        try:
            server.DemoBus(s)
            poll = server.build_poll(s)
            ok = all(rg in s.regions or rg == "ctrl" for _, rg, _ in poll)
            check("scenario %s: DemoBus + poll" % sid, ok,
                  "%d poll entries" % len(poll))
        except Exception as e:                   # noqa: BLE001
            check("scenario %s: DemoBus + poll" % sid, False, str(e))

    print("== architecture geometry (defect class: trio fallback) ==")
    # rebuildArch() SILENTLY keeps the last geometry it built when a
    # scenario has no ARCH_BY_SCEN entry -- that is exactly how
    # tgc5b2_axis_wp ended up with the trio layout (funnel 78x666,
    # te_inst/tePktz, TIP only in row 0). The guard: EVERY scenario of the
    # catalogue carries its OWN geometry.
    import json as _json
    import re as _re
    idx = (HERE / "index.html").read_text(encoding="utf-8")
    m = _re.search(r"const ARCH_BY_SCEN=(\{.*?\});\n", idx, _re.S)
    check("ARCH_BY_SCEN blob present", bool(m))
    geo = _json.loads(m.group(1)) if m else {}
    for sid in cat.order:
        check("geometry for %s" % sid, sid in geo)
    g = geo.get("tgc5b2_axis_wp") or {"nodes": [], "edges": []}
    ids = {n["id"] for n in g["nodes"]}
    check("tgc5b2: NO E-Trace blocks (finding 2, CT_EN_ETRACE=0)",
          not any(i.startswith(("teinst", "tepktz")) for i in ids))
    check("tgc5b2: H2E->TIP in BOTH rows (finding 3)",
          {"tip0", "tip1"} <= ids)
    check("tgc5b2: AXIS-WP chain per row (finding 6)",
          {"wpshim0", "wpfifo0", "kriaps0",
           "wpshim1", "wpfifo1", "kriaps1"} <= ids)
    check("tgc5b2: funnel + URAM (finding 1)", {"funnel", "uram"} <= ids)
    ed = {(e["s"], e["t"]) for e in g["edges"]}
    for want in (("preproc0", "wpshim0"), ("wpshim0", "wpfifo0"),
                 ("wpfifo0", "kriaps0"), ("preproc1", "wpshim1"),
                 ("wpshim1", "wpfifo1"), ("wpfifo1", "kriaps1"),
                 ("cpu1", "tip1"), ("funnel", "uram")):
        check("tgc5b2: edge %s->%s" % want, want in ed)

    # The THREE sinks of the sink subsystem (ct_trace_sinks.sv) hang
    # ADDITIVELY off the funnel output -- one ATB beat input, three sinks in
    # parallel. For a while the drawing showed only the URAM ring:
    # scenarios.json already carried the sinks, the SVG was from the day
    # before.
    check("tgc5b2: all three sinks drawn (T4)",
          {"uram", "ddr", "pib"} <= ids,
          "missing: %s" % sorted({"uram", "ddr", "pib"} - ids))
    for sid_sink in ("ddr", "pib"):
        check("tgc5b2: edge funnel->%s" % sid_sink,
              ("funnel", sid_sink) in ed)
    # The sinks hang off the FUNNEL, not off an encoder row: an edge
    # mseomdo*->sink would be drawn hardware that does not exist (the merge
    # happens before the sinks, ct_trace_sinks has ONE beat input).
    check("tgc5b2: no sink directly on an encoder row",
          not [1 for s, t in ed
               if t in ("uram", "ddr", "pib") and s != "funnel"])

    # Defect class GENERATED-ARTEFACT DRIFT, for EVERY scenario: the sink
    # set of the drawing is the one from scenarios.json
    # (gui/compact_layout.py, line
    # `want = [s for s in ("ddr","uram","pib") if sinks.get(s)]`). Whoever
    # changes the sinks in the catalogue and does not run the generator gets
    # red here instead of a view that keeps quiet about a sink -- exactly the
    # earlier finding, only visible immediately the next time.
    for sid in cat.order:
        gg = geo.get(sid) or {"nodes": []}
        gids = {n["id"] for n in gg["nodes"]}
        sk = cat.by_id[sid].raw.get("sinks") or {}
        want_sink = {k for k in ("uram", "ddr", "pib") if sk.get(k)} or {"uram"}
        have_sink = gids & {"uram", "ddr", "pib"}
        check("geometry %s: sinks == scenarios.json" % sid,
              have_sink == want_sink,
              "drawing %s vs. catalog %s"
              % (sorted(have_sink), sorted(want_sink)))
    # layoutWires() does NOT draw edges without a 'path' (the sync import
    # from pure image exports loses them silently -- really observed when
    # export_drawio dumps covered the sync sources).
    for sid in cat.order:
        gg = geo.get(sid) or {"edges": []}
        pathless = [e for e in gg["edges"]
                    if not e.get("path") or len(e["path"]) < 2]
        check("geometry %s: all edges with a gradient" % sid,
              not pathless, "%d without a path" % len(pathless))

    print("== U2: indexed instances under ONE parent node ==")
    # Requirement: te.trTeFilter[0].Control through
    # te.trTeFilter[15].Control are to sit under ONE parent row
    # te.trTeFilter[0..15] that expands and only then shows the individual
    # instances.
    # The rule is generic (every indexed row, both register lists, all
    # scenarios); the data side is checked by test_block_csrs.py, here the
    # SHIPPED JS code itself runs.
    import json as _j
    import subprocess                                   # noqa: S404
    import tempfile
    import test_block_csrs as _tbc                      # mirror counterpart

    check("the register tab groups (buildAll, a search expands the hits)",
          "renderRegGroups(list,items,'all',!!q)" in idx)
    check("the block panel groups the register rows",
          "'panel:'+b,false)" in idx)
    check("the memory rows go through the same folding",
          "'panel:'+b+':mem',false)" in idx)
    # Counter-check for completeness: if an ungrouped
    # list.appendChild(regRow(...)) were left standing anywhere, the folding
    # would be half done -- exactly the class that only shows up in the panel
    # on a click.
    check("no ungrouped register row left over (counter-check)",
          "list.appendChild(regRow(" not in idx)
    check("COLLAPSED by default, expanding only through the class (CSS)",
          ".rgrp>.gbody{display:none" in idx
          and ".rgrp.open>.gbody{display:block}" in idx)
    check("fold state lives in the client (REGGRP_OPEN per node)",
          "const REGGRP_OPEN=" in idx and "REGGRP_OPEN[key]" in idx)
    # Without ?open= the EXPANDED state can only be produced by hand --
    # neither a headless screenshot nor a board spot check could show it (the
    # same reasoning as for ?tab=/?sel= above in the init).
    check("expanding is checkable without a click (?open=<list>:<prefix>)",
          "getAll('open')" in idx and "REGGRP_OPEN[k]=true" in idx)

    try:
        nv = subprocess.run(["node", "--version"], capture_output=True,
                            text=True)
        node_ok = nv.returncode == 0
        node_ver = (nv.stdout or "").strip()
    except OSError as e:                                 # noqa: BLE001
        node_ok, node_ver = False, str(e)
    # NO skip: without node the grouping is merely claimed, and a skipped
    # guard that reports green is the most expensive kind.
    check("node available (the guard executes the shipped code)",
          node_ok, node_ver)
    # Edge cases that do NOT occur in the real regmap.json (there every row
    # has >= 3 instances): a two-instance row, a gap, a single instance, a
    # row without an index. Without them the mirror comparison below would be
    # blunt -- measured against the mutation "threshold 2 -> 3", which it
    # would otherwise not see.
    EDGE = ["zz.pair[0].A", "zz.pair[1].A",
            "zz.gap[0].A", "zz.gap[1].A", "zz.gap[5].A", "zz.gap[5].B",
            "zz.single[7].A", "zz.single[7].B", "zz.plain"]
    if node_ok:
        rm_path = HERE / "regmap.json"
        with tempfile.TemporaryDirectory() as td:
            probe = Path(td) / "u2_group_probe.mjs"
            probe.write_text(JS_GROUP_PROBE, encoding="utf-8")
            p = subprocess.run(["node", str(probe), str(HERE / "index.html"),
                                str(rm_path), _j.dumps(EDGE)],
                               capture_output=True, text=True,
                               encoding="utf-8")
        res, summ = [], None
        for ln in (p.stdout or "").splitlines():
            if ln.startswith("U2RESULT "):
                res = _j.loads(ln[len("U2RESULT "):])
            elif ln.startswith("U2SUMMARY "):
                summ = _j.loads(ln[len("U2SUMMARY "):])
        check("grouping probe ran (node, rc=0)",
              p.returncode == 0 and bool(res),
              "rc=%d %s" % (p.returncode, (p.stderr or "")[:160]))
        for r in res:
            check(r["name"], r["ok"], r.get("info", ""))
        # The Python mirror in test_block_csrs.py carries some 40 checks
        # there -- it must not drift apart from what is shipped.
        paths = [r["path"] for r in
                 _j.loads(rm_path.read_text(encoding="utf-8"))["regs"]] + EDGE
        mirror = _j.loads(_j.dumps(_tbc.group_summary(paths)))
        check("python mirror (test_block_csrs.group_rows) == JS result"
              " (real map + 4 edge cases)",
              summ == mirror,
              "" if summ == mirror else "first deviation: %s" % next(
                  ("%r != %r" % (a, b) for a, b in
                   zip(summ or [], mirror) if a != b), "length %s/%s"
                  % (len(summ or []), len(mirror))))

        # --- badge, gate state, run state per core ------------------------
        with tempfile.TemporaryDirectory() as td:
            probe4 = Path(td) / "u4_access_probe.mjs"
            probe4.write_text(JS_U4_PROBE, encoding="utf-8")
            p4 = subprocess.run(["node", str(probe4), str(HERE / "index.html"),
                                 str(rm_path)],
                                capture_output=True, text=True,
                                encoding="utf-8")
        res4 = []
        for ln in (p4.stdout or "").splitlines():
            if ln.startswith("U4RESULT "):
                res4 = _j.loads(ln[len("U4RESULT "):])
        check("U4 display probe ran (node, rc=0)",
              p4.returncode == 0 and bool(res4),
              "rc=%d %s" % (p4.returncode, (p4.stderr or "")[:160]))
        for r in res4:
            check(r["name"], r["ok"], r.get("info", ""))

        # --- bpi source + the empty graph with a reason --------------------
        with tempfile.TemporaryDirectory() as td:
            probe5 = Path(td) / "u5_bpi_probe.mjs"
            probe5.write_text(JS_U5_PROBE, encoding="utf-8")
            p5 = subprocess.run(["node", str(probe5), str(HERE / "index.html")],
                                capture_output=True, text=True,
                                encoding="utf-8")
        res5 = []
        for ln in (p5.stdout or "").splitlines():
            if ln.startswith("U5RESULT "):
                res5 = _j.loads(ln[len("U5RESULT "):])
        check("U5 bpi probe ran (node, rc=0)",
              p5.returncode == 0 and bool(res5),
              "rc=%d %s" % (p5.returncode, (p5.stderr or "")[:160]))
        for r in res5:
            check(r["name"], r["ok"], r.get("info", ""))

        # --- the TE enable switch on the encoder card ----------------------
        with tempfile.TemporaryDirectory() as td:
            probe7 = Path(td) / "u7_te_enable_probe.mjs"
            probe7.write_text(JS_U7_PROBE, encoding="utf-8")
            p7 = subprocess.run(["node", str(probe7), str(HERE / "index.html"),
                                 str(rm_path)],
                                capture_output=True, text=True,
                                encoding="utf-8")
        res7 = []
        for ln in (p7.stdout or "").splitlines():
            if ln.startswith("U7RESULT "):
                res7 = _j.loads(ln[len("U7RESULT "):])
        check("U7 switch probe ran (node, rc=0)",
              p7.returncode == 0 and bool(res7),
              "rc=%d %s" % (p7.returncode, (p7.stderr or "")[:160]))
        for r in res7:
            check(r["name"], r["ok"], r.get("info", ""))

    # --- sink defaults of the scenario ------------------------------------
    # The default is DATA, not a special case in the code: a scenario without
    # the key must not behave any differently than before.
    sd = sc.raw.get("sink_defaults") or {}
    check("tgc5b2_axis_wp carries sink_defaults", bool(sd), str(sd))
    check("the default switches the DDR sink ON (that was the field finding)",
          sd.get("ddr_en") is True)
    check("the default selects the RING, not one shot (otherwise the sink "
          "sits at FULL after ~1.6 s and only counts drops -- T3 point 7)",
          sd.get("ddr_circ") is True)
    check("the default names NO pulse bit (b1/b5 are W1 pulses)",
          not ({"ddr_clear", "pib_clear"} & set(sd)))
    check("all keys of the default are known to the server",
          all(k in server.SINK_BITS for k in sd),
          "unknown: %s" % [k for k in sd if k not in server.SINK_BITS])
    for other in ("rocket2", "trio", "cva6_linux", "mbv"):
        if other in cat.by_id:
            check("existing scenario %s stays without a default (unchanged)" % other,
                  not (cat.by_id[other].raw.get("sink_defaults")))

    dbus = server.DemoBus(sc)
    so = sc.co("sink_ctrl")
    r1 = server.arm_default_sinks(dbus, sc)
    check("bind armed: SINK_CTRL 0x0 -> 0x5 (ddr_en | ddr_circ)",
          r1.get("state") == "armed" and dbus.read("ctrl", so)[0] == 0x5,
          "%s -> 0x%X" % (r1.get("state"), dbus.read("ctrl", so)[0]))
    r2 = server.arm_default_sinks(dbus, sc)
    check("a second bind does NOT write again (idempotent, a running sink "
          "is not touched)",
          r2.get("state") == "already armed" and r2.get("wrote") is False,
          str(r2))
    # Pulse bits: if they stand in the register (for whatever reason),
    # arming must not write them along -- a permanent ddr_clear would wipe
    # the counters on every bind.
    dbus.write("ctrl", so, 0x22)
    r3 = server.arm_default_sinks(dbus, sc)
    check("arming masks out the pulse bits b1/b5",
          (dbus.read("ctrl", so)[0] & 0x22) == 0
          and (dbus.read("ctrl", so)[0] & 0x5) == 0x5,
          "0x%X (%s)" % (dbus.read("ctrl", so)[0], r3.get("state")))
    for other in ("rocket2", "trio"):
        if other in cat.by_id:
            osc = cat.by_id[other]
            ob = server.DemoBus(osc)
            before = ob.read("ctrl", osc.co("sink_ctrl"))[0]
            ores = server.arm_default_sinks(ob, osc)
            check("the bind of %s does not touch SINK_CTRL" % other,
                  ob.read("ctrl", osc.co("sink_ctrl"))[0] == before
                  and "no sink_defaults" in ores.get("state", ""),
                  str(ores))

    # Target window: a DMA WRITE master is not armed on the off chance.
    # Without evidence from the device tree it stays off.
    _real_rr = server.resmem_ranges
    try:
        server.resmem_ranges = lambda: [(0x50000000, 0x20000000, "ctrace-pl-ddr")]
        check("a target window inside the reserved area is accepted",
              server.ddr_window_ok(0x60000000, 0x04000000)[0] is True)
        check("a window that reaches past the reserved area is "
              "rejected",
              server.ddr_window_ok(0x6F000000, 0x04000000)[0] is False)
        check("a window outside it (Linux memory!) is rejected",
              server.ddr_window_ok(0x00100000, 0x00010000)[0] is False)
        check("DDR_SIZE 0 is rejected",
              server.ddr_window_ok(0x60000000, 0)[0] is False)
        server.resmem_ranges = lambda: []
        check("without device-tree evidence: NO arming (counter-check)",
              server.ddr_window_ok(0x60000000, 0x04000000)[0] is False)

        class _LiveBus(FakeBus):
            demo = False
        lb = _LiveBus({"ctrl": {so: 0, sc.co("ddr_base"): 0x60000000,
                                sc.co("ddr_size"): 0x04000000}})
        rl = server.arm_default_sinks(lb, sc)
        check("a live bus without resmem evidence is NOT armed",
              rl.get("state", "").startswith("refused")
              and lb.read("ctrl", so)[0] == 0, str(rl)[:120])
        server.resmem_ranges = lambda: [(0x50000000, 0x20000000, "ctrace-pl-ddr")]
        rl2 = server.arm_default_sinks(lb, sc)
        check("a live bus WITH evidence is armed (counter-check to the rejection)",
              rl2.get("state") == "armed" and lb.read("ctrl", so)[0] == 0x5,
              str(rl2)[:120])
    finally:
        server.resmem_ranges = _real_rr

    # --- U5: build stamp (finding 3) ----------------------------------------
    b = server.ui_build_id()
    check("the build stamp is an 8-digit hex value",
          len(b) == 8 and all(c in "0123456789abcdef" for c in b), b)
    check("the build stamp covers the files a tab loads ONCE",
          {"index.html", "regmap.json", "scenarios.json"} <= set(server.UI_FILES),
          str(server.UI_FILES))
    check("the build stamp is stable (two fetches, one value)",
          server.ui_build_id() == b)

    # --- the places in the shipped HTML that are not a function call
    # (filter, mask, button set). Text checks, as with scenSinks() -- they
    # stop exactly the roll-backs that arrive labelled "simplification".
    check("the poller filters on the DATA PROPERTY read_side_effect",
          "filter(r=>!r.read_side_effect)" in idx)
    check("the poller no longer hangs on the register name TipFifoHistData",
          "path.includes('TipFifoHistData')" not in idx)
    check("no access to a store 'watchpoints' any more (it does not exist)",
          "includes('watchpoints')" not in idx)
    check("a field write masks W1C bits out of the write-back value",
          "f.w1c" in idx and "cur&~mask&~w1c" in idx)
    check("the write button carries the gate property (it is locked live)",
          "data-gated" in idx and "b.disabled=locked" in idx)
    check("core 1 has start/stop buttons of its own",
          'id="btn_run1"' in idx and 'id="btn_stop1"' in idx)
    check("the per-core path sends the CORE INDEX to the server",
          "action:run?'core_run':'core_stop',core:i" in idx.replace(" ", ""))
    check("the collective path stays reachable (Run all/Stop all in the panel)",
          "'Run all','run'" in idx and "'Stop all','stop'" in idx)
    check("the empty catch in the poller is gone (silent errors were the cause)",
          "}catch(e){}" not in idx.split("function refreshPanelVals")[1]
          .split("function paintPanelVals")[0])

    # --- what the cards show and what the click does (text checks) --------
    check("the DDR card says in plain words when the sink is OFF",
          "'disabled'" in idx and "DDR4 sink is DISABLED (SINK_CTRL b0 = 0)" in idx)
    check("the PIB card says so too",
          "Parallel trace port is DISABLED (SINK_CTRL b4 = 0)" in idx)
    check("both state words are buttons (keyboard included)",
          'id="ddr_wrapn" class="sinksw" role="button" tabindex="0"' in idx
          and 'id="pib_state" class="sinksw" role="button" tabindex="0"' in idx)
    check("the card switch takes the EXISTING server path (no second "
          "write path for the same thing)",
          "sinkSw('ddr_wrapn',0x1,'ddr_on','ddr_off'" in idx
          and "sinkSw('pib_state',0x10,'pib_on','pib_off'" in idx)
    check("the card switch stops the click from propagating (otherwise "
          "the panel opens at the same time)",
          "e.onclick=ev=>{ev.stopPropagation();go();};" in idx)
    check("the URAM card explains that a full RING is the normal case",
          "is the NORMAL full state of a ring" in idx)
    check("URAM stays without a card switch (one shot stops the recording)",
          "sinkSw('cap_wrapn'" not in idx)
    check("the bpi tooltip names the source when there are no counters",
          "Bits per decoded instruction." in idx
          and "This SoC has NO hardware retire " in idx
          and "instructions of " in idx)
    check("an empty graph carries the hint about Trace & Decode",
          "run Trace & Decode to populate" in idx)
    check("the build stamp is compared on EVERY fetch",
          "checkUiBuild(s.ui_build)" in idx and "STALE, press F5" in idx)
    check("no automatic reload (that used to tear away a running measurement)",
          "location.reload" not in idx)
    # --- WP shim card -- width from the GENERATOR plus the stop -----------
    # The card is absolutely positioned and clips with overflow:hidden.
    # Whether text fits cannot be rendered in the test -- but it can be
    # computed: the card font is --fs-s = 10 model units monospace (~6 per
    # character), plus 5+5 block padding and 2 of .cnt inner spacing.
    check("the WP shim card no longer wraps (nowrap)",
          'id="wp_sdrop0">' in idx
          and '<div class="cnt" style="white-space:nowrap">drop <b id="wp_sdrop0"'
              in idx)
    check("no truncation stopgap any more now that the block is wide "
          "(the crutch is retired, not added to)",
          "function fmtK(" not in idx and "fmtK(" not in idx)
    check("the limit is shown as a limit, not as a measurement",
          "function wpDropTxt(" in idx and "'saturated'" in idx
          and "WP_DROP_SAT=0xFFFFFFFF" in idx)
    check("the hover panel names the limit by its name as well",
          "= SATURATED (the counter stops here, it does not " in idx)
    check("the limit is not marked by colour alone (word + class)",
          ".cnt b.sat{" in idx and "classList.toggle('sat'" in idx)

    # --- the TE enable switch (text side; the logic is driven by the node
    # probe above). The request was "the interface has no control path for
    # Enable=0" -- and CSR editing hangs on exactly that.
    print("== U7: the TE enable switch on the encoder card ==")
    check("the encoder card carries a switch (a frame, not just a word)",
          "data-tesw=" in idx and ".tesw{" in idx)
    check("each card's switch carries ITS region (enc/enc1/enc2)",
          "teLeds($('te_leds_0'),te0,'enc');" in idx
          and "teLeds($('te_leds_1'),te1,'enc1');" in idx
          and "teLeds($('te_leds_2'),te2,'enc2');" in idx)
    seg = idx.split("async function setTeEnable(")[1].split("\n}\n")[0]
    check("the switch takes the EXISTING write path /api/write "
          "(no second path for the same thing)",
          "api('/api/write'" in seg and "offset:0" in seg)
    check("the switch invents no new ctl command",
          "ctl(" not in seg and "'te_enable'" not in idx)
    check("the switch masks out the W1C bits (the overflow evidence survives)",
          "f.w1c" in seg and "&~w1c" in seg)
    check("the lock display is updated IMMEDIATELY after switching",
          "paintGateState();" in seg)
    # The wrong operating instruction must not stand anywhere any more -- it
    # sent the reader in a circle ("encoder trace off" leaves Enable set).
    srv = (HERE / "server.py").read_text(encoding="utf-8")
    wpv = (HERE / "wp_view.py").read_text(encoding="utf-8")
    for name, txt in (("index.html", idx), ("server.py", srv)):
        check("%s: the wrong advice 'switch the encoder trace off first' "
              "is gone" % name,
              "Switch the encoder trace off first." not in txt)
    check("index.html: the lock display names the path that WORKS",
          "clear Enable with the \"TE enabled\" switch" in idx)
    check("index.html: 'Encoder trace on/off' says itself that it does "
          "NOT touch Enable",
          "It does NOT unlock the " in idx
          and "clears InstTracing and leaves " in idx)
    # The same truth on the server side -- and from a REAL call, not read
    # out of the source text.
    r409 = server.write_gate_reason(FakeBus({"enc": {0: 0x2}}), "enc", 0x400)
    check("the 409 reason now names the BIT and the operating path",
          "bit 1 = 0" in (r409 or "")
          and "'TE enabled' switch" in (r409 or ""), (r409 or "")[-90:])
    check("the 409 reason warns about the trap 'Encoder trace off'",
          "does NOT clear Enable" in (r409 or ""))
    check("wp_view: the same correction in the WP load path",
          "'TE enabled' switch" in wpv and "clears InstTracing only" in wpv)

    # --- the 409 -> 200 -> 409 chain OFFLINE, on the demo bus -------------
    # The board proof was run by hand over /api/write. Here the guard drives
    # it: the demo bus mirrors the swwel bar, so it also has to show that the
    # SWITCH opens it and closes it again.
    d7 = server.DemoBus(sc)
    d7.write("enc", 0x000, 0x00000007)                 # Active|Enable|ITrace
    check("demo: encoder armed, a locked field is rejected (409)",
          (server.write_gate_reason(d7, "enc", 0x400) or "").startswith(
              "CONFLICT"))
    before = d7.read("enc", 0x400)[0]
    d7.write("enc", 0x400, 0x00000001)
    check("demo: the rejected write would fizzle out SILENTLY (hence 409)",
          d7.read("enc", 0x400)[0] == before, hex(d7.read("enc", 0x400)[0]))
    # ... now the switch: Enable itself is NOT locked (the door).
    d7.write("enc", 0x000, server.rmw_value("enc", 0, d7.read("enc", 0)[0] & ~2))
    check("demo: the switch gets Enable to 0 (Enable is not swwel)",
          not (d7.read("enc", 0)[0] >> 1) & 1, hex(d7.read("enc", 0)[0]))
    check("demo: interlock open -> no 409 any more",
          server.write_gate_reason(d7, "enc", 0x400) is None)
    d7.write("enc", 0x400, 0x00000001)
    check("demo: and the write ARRIVES (the 200 case)",
          d7.read("enc", 0x400)[0] & 1 == 1, hex(d7.read("enc", 0x400)[0]))
    d7.write("enc", 0x000, server.rmw_value("enc", 0, d7.read("enc", 0)[0] | 2))
    check("demo: switched back -> 409 again (bar closes)",
          (server.write_gate_reason(d7, "enc", 0x400) or "").startswith(
              "CONFLICT")
          and (d7.read("enc", 0)[0] >> 1) & 1 == 1)
    check("demo: the switch did NOT clear the overflow evidence "
          "(b12 was 0 and stays 0 -- w1c)",
          not (d7.read("enc", 0)[0] >> 12) & 1)

    # --- and what the switch does to the STREAM (demo pump, 3 windows) ----
    # The warning next to the switch claims "the sinks run dry". A claim in a
    # tooltip is not a measurement -- here it is measured.
    import time as _t
    d8 = server.DemoBus(sc)
    d8.write("enc", 0x000, 0x00000007)
    for e in ("enc1", "enc2"):
        if e in d8.mem:
            d8.write(e, 0x000, 0x00000007)
    d8.write("ctrl", sc.co("control"), 0x1)            # both cores go
    _t.sleep(0.8)
    b1 = d8.read("ctrl", sc.co("trace_bytes"))[0]
    _t.sleep(0.8)
    b2 = d8.read("ctrl", sc.co("trace_bytes"))[0]
    check("demo pump runs at all (reference window)", b2 > b1,
          "%d -> %d" % (b1, b2))
    for e in ("enc", "enc1", "enc2"):
        if e in d8.mem:
            d8.write(e, 0x000,
                     server.rmw_value(e, 0, d8.read(e, 0)[0] & ~2))
    _t.sleep(0.6)
    b3 = d8.read("ctrl", sc.co("trace_bytes"))[0]
    _t.sleep(0.8)
    b4 = d8.read("ctrl", sc.co("trace_bytes"))[0]
    check("Enable=0 -> the stream dries up while the cores are RUNNING",
          b4 == b3 and d8.read("ctrl", sc.co("control"))[0] & 1 == 1,
          "%d -> %d, CONTROL=0x%X"
          % (b3, b4, d8.read("ctrl", sc.co("control"))[0]))
    for e in ("enc", "enc1", "enc2"):
        if e in d8.mem:
            d8.write(e, 0x000, server.rmw_value(e, 0, d8.read(e, 0)[0] | 2))
    _t.sleep(0.8)
    b5 = d8.read("ctrl", sc.co("trace_bytes"))[0]
    check("Enable=1 -> it comes back (counter-check; otherwise it would be a hang)",
          b5 > b4, "%d -> %d" % (b4, b5))

    # --- 256 MiB window, rejection display, cap for the raw dump ----------
    # Three things the bitstream brings to the board and the dashboard has to
    # carry along. The most expensive mistake here would NOT be a wrong
    # number but a number that lives in the dashboard instead of in the
    # register: the window size holds PER BITSTREAM VARIANT (rocket/cva6_*
    # stay at 64 MiB), and a constant in the code would be wrong there
    # immediately.
    print("== U8: DDR window 256 MiB, SINK_STAT b4, dump cap ==")
    rm = _j.loads((HERE / "regmap.json").read_text(encoding="utf-8"))
    byp = {r["path"]: r for r in rm["regs"]}
    f_of = lambda p, n: next(  # noqa: E731
        (f for f in byp[p]["fields"] if f["name"] == n), None)
    # A drift guard against the RTL, not against itself: the reset values of
    # the register map are READ from ct_trace_sinks.sv. Exactly that coupling
    # was missing before -- the old map value 0x6000_0000 was still in place
    # long after the RTL had moved to 0x5000_0000.
    # rtl/board_kv260/ is the KV260 SoC-top tree, migrated under AP4 (this
    # file only covers the dashboard, AP5) -- without it, the drift GUARD
    # cannot run, but that is not the same as the guarded FACT being wrong.
    # SKIP, not FAIL, and do not silently drop the two regmap-only checks
    # below it either -- reset() below still runs.
    sinks_sv_path = HERE.parents[1] / "rtl" / "board_kv260" / "ct_trace_sinks.sv"
    if not sinks_sv_path.is_file():
        skip("RTL reset drift guard (ct_trace_sinks.sv vs. regmap.json)",
             "%s is not part of this example (KV260 RTL migrates under AP4)"
             % sinks_sv_path)
        rtl_base = f_of("soc.DDR_BASE", "Value")["reset"]
        rtl_size = f_of("soc.DDR_SIZE", "Value")["reset"]
    else:
        sinks_sv = sinks_sv_path.read_text(encoding="utf-8")
        m_b = _re.search(r"DDR_BASE_RST\s*=\s*32'h([0-9a-fA-F_]+)", sinks_sv)
        m_s = _re.search(r"DDR_SIZE_RST\s*=\s*32'h([0-9a-fA-F_]+)", sinks_sv)
        rtl_base = int(m_b.group(1).replace("_", ""), 16) if m_b else None
        rtl_size = int(m_s.group(1).replace("_", ""), 16) if m_s else None
        check("RTL reset read from ct_trace_sinks.sv (address plan v4)",
              (rtl_base, rtl_size) == (0x50000000, 0x10000000),
              "0x%X + 0x%X" % (rtl_base or 0, rtl_size or 0))
        check("register tab: DDR_BASE reset == RTL",
              f_of("soc.DDR_BASE", "Value")["reset"] == rtl_base,
              "0x%X" % (f_of("soc.DDR_BASE", "Value")["reset"] or 0))
        check("register tab: DDR_SIZE reset == RTL (256 MiB)",
              f_of("soc.DDR_SIZE", "Value")["reset"] == rtl_size,
              "0x%X" % (f_of("soc.DDR_SIZE", "Value")["reset"] or 0))
    check("the register tab names the variant dependency (the tops with "
          "their own sink wiring stay at 0x6000_0000)",
          "0x6000_0000" in byp["soc.DDR_BASE"]["desc"]
          and "cva6_linux" in byp["soc.DDR_BASE"]["desc"])
    rej = f_of("soc.SINK_STAT", "ddr_cfg_rej")
    check("SINK_STAT carries b4 ddr_cfg_rej (U6 bar)",
          rej is not None and rej["lsb"] == 4 and rej["msb"] == 4
          and rej["sw"] == "r", str(rej and (rej["lsb"], rej["sw"])))
    for p in ("soc.DDR_BASE", "soc.DDR_SIZE"):
        check("%s: access_rule says that a write at ddr_en=1 is REJECTED "
              "(no longer 'freely writable')" % p,
              "REFUSED" in f_of(p, "Value")["access_rule"]
              and "ddr_cfg_rej" in f_of(p, "Value")["access_rule"])
    check("the ddr_clear description names the new bit as clearable",
          "ddr_cfg_rej" in f_of("soc.SINK_CTRL", "ddr_clear")["desc"])

    # The server's window check against the NEW window -- the same resmem
    # proof as before, only with the numbers of the current bitstream.
    _real_rr2 = server.resmem_ranges
    try:
        server.resmem_ranges = lambda: [(0x50000000, 0x20000000,
                                         "ctrace-pl-ddr")]
        ok256, note256 = server.ddr_window_ok(0x50000000, 0x10000000)
        check("resmem evidence carries 0x5000_0000 + 256 MiB (U6 reset)",
              ok256 is True, note256)
        check("counter-check: 0x5000_0000 + 768 MiB reaches past and is "
              "rejected",
              server.ddr_window_ok(0x50000000, 0x30000000)[0] is False)

        class _LiveBus8(FakeBus):
            demo = False
        lb8 = _LiveBus8({"ctrl": {sc.co("sink_ctrl"): 0,
                                  sc.co("ddr_base"): 0x50000000,
                                  sc.co("ddr_size"): 0x10000000}})
        r8 = server.arm_default_sinks(lb8, sc)
        check("the bind arms with the U6 defaults (0x5 in SINK_CTRL)",
              r8.get("state") == "armed"
              and lb8.read("ctrl", sc.co("sink_ctrl"))[0] == 0x5, str(r8)[:120])
        check("and the evidence in the log names the new window",
              "0x50000000+0x10000000" in (r8.get("ddr_window") or ""),
              r8.get("ddr_window"))
    finally:
        server.resmem_ranges = _real_rr2

    # Cap: numbers first, then the bytes. `?max=` is the explicit way to a
    # full dump -- without it the cap would amount to data loss.
    check("the cap default is 32 MiB, the maximum 256 MiB",
          server.DUMP_CAP_DEFAULT == 32 << 20
          and server.DUMP_CAP_MAX == 256 << 20)
    check("without ?max the default applies",
          server.dump_cap_arg({}) == server.DUMP_CAP_DEFAULT)
    check("?max=0 raises the cap to the maximum",
          server.dump_cap_arg({"max": ["0"]}) == server.DUMP_CAP_MAX)
    check("?max=1024 is accepted",
          server.dump_cap_arg({"max": ["1024"]}) == 1024)
    check("?max beyond the maximum is clamped (no suicide on "
          "request)",
          server.dump_cap_arg({"max": ["0x40000000"]}) == server.DUMP_CAP_MAX)

    class _DdrBus(FakeBus):
        """Live bus stub with physical memory behind the window."""
        demo = False

        def __init__(self, init, base, blob):
            super().__init__(init)
            self.base, self.blob, self.reads = base, blob, []

        def phys_read(self, addr, n):
            self.reads.append((addr, n))
            off = addr - self.base
            assert 0 <= off and off + n <= len(self.blob), \
                "read access 0x%X+%d leaves the buffer" % (addr, n)
            return self.blob[off:off + n]

    BASE, SIZE = 0x50000000, 4096
    blob = bytes((i * 7 + 3) & 0xFF for i in range(SIZE))
    mk_bus = lambda ctl, stat, wptr: _DdrBus(  # noqa: E731
        {"ctrl": {sc.co("ddr_base"): BASE, sc.co("ddr_size"): SIZE,
                  sc.co("ddr_wptr"): wptr, sc.co("sink_ctrl"): ctl,
                  sc.co("sink_stat"): stat}}, BASE, blob)

    # (a) linear, not yet wrapped: the NEWEST bytes sit at the end. The start
    # moves FORWARD onto the 32-byte burst edge (al(600) = 608), which makes
    # the dump at most 31 bytes shorter than the cap -- never longer, and
    # never at a misaligned address (that was the SIGBUS).
    inf = {}
    bus_a = mk_bus(0x1, 0x0, 1000)
    got = server.dump_bytes(bus_a, "ddr", sc=sc, cap=400, info=inf)
    check("cap, linear: the newest bytes from the burst edge 608",
          got == blob[608:1000] and len(got) == 392, "%d B" % len(got))
    check("and the balance names the truncation",
          inf == {"available": 1000, "returned": 392, "capped": True},
          str(inf))
    inf2 = {}
    bus_f = mk_bus(0x1, 0x0, 1000)
    full = server.dump_bytes(bus_f, "ddr", sc=sc, cap=0, info=inf2)
    check("without a cap the same dump as before (counter-check: nothing "
          "missing, not even 31 bytes through the alignment)",
          full == blob[:1000] and inf2["capped"] is False, "%d B" % len(full))

    # (b) circular + wrapped: chronologically it is [off..size) ++ [0..off).
    WP = SIZE + 300                      # wrapped once, off = 300
    chrono = blob[300:] + blob[:300]
    inf3 = {}
    bus_c = mk_bus(0x5, 0x4, WP)
    got3 = server.dump_bytes(bus_c, "ddr", sc=sc, cap=0, info=inf3)
    check("ring uncapped: chronological order unchanged",
          got3 == chrono and inf3["available"] == SIZE, "%d B" % len(got3))
    inf4 = {}
    bus_d = mk_bus(0x5, 0x4, WP)
    got4 = server.dump_bytes(bus_d, "ddr", sc=sc, cap=500, info=inf4)
    check("ring capped: the newest bytes end at the write pointer "
          "(start on the burst edge 3904)",
          got4 == chrono[-492:] and got4 == blob[3904:4096] + blob[:300],
          "%d B" % len(got4))
    check("and the cap does not read past the window "
          "(two pieces instead of one that is too long)",
          inf4 == {"available": SIZE, "returned": 492, "capped": True}
          and bus_d.reads == [(BASE + 3904, 192), (BASE, 300)],
          "%s %s" % (inf4, bus_d.reads))
    b5 = mk_bus(0x5, 0x4, WP)
    server.dump_bytes(b5, "ddr", sc=sc, cap=200, info={})
    check("ring capped without a seam: ONE read access, directly in front "
          "of the write pointer", b5.reads == [(BASE + 128, 172)], str(b5.reads))
    # The guard for the crash class: EVERY physical read address sits on the
    # 32-byte edge. On the board exactly one misaligned address
    # (0x5096FA3FC, page offset 0x3FC) ended the service with SIGBUS -- the
    # reserved window is `no-map`, so the mapping is device memory, and a
    # memcpy using LDP/NEON walks into an alignment trap there.
    capreads = bus_a.reads + bus_d.reads + b5.reads
    check("every CAPPED read address sits on the 32-byte burst edge "
          "(%d accesses)" % len(capreads),
          all(a % 32 == 0 for a, _ in capreads),
          str([hex(a) for a, _ in capreads if a % 32]))
    # The uncapped ring dump starts at the write offset and is ONLY 4-byte
    # aligned (0x5000012C in the example) -- that was already the case before
    # and it is fine, BECAUSE the alignment is now ensured inside phys_read
    # instead of at the caller. That is exactly what the next guard checks,
    # and it checks it by executing: a mapping mock that behaves like device
    # memory and REJECTS a misaligned copy start.
    class BusFault(Exception):
        """stands here for the SIGBUS a real kernel would send."""

    class _DevMap:
        """mmap stub with the strictness of Device-nGnRE memory."""

        def __init__(self, blob):
            self.blob = blob

        def __getitem__(self, sl):
            if (sl.start or 0) % 16:
                raise BusFault("unaligned bulk copy on device memory (SIGBUS)")
            return self.blob[sl]

        def close(self):
            pass

    import threading as _thr

    class _Stub:
        fd = -1
        lock = _thr.Lock()

    phys = bytes((i * 13 + 5) & 0xFF for i in range(2 * 4096))

    class _FakeMmapMod:
        """Stand-in for the mmap module: the constants MAP_SHARED/PROT_READ do
        not exist on Windows at all -- the guard is meant to check the logic,
        not the host system."""
        MAP_SHARED, PROT_READ = 1, 1

        @staticmethod
        def mmap(fd, ln, flags=0, prot=0, offset=0):
            base = offset - 0x50000000
            return _DevMap(phys[base:base + ln])

    real_mmap = server.mmap
    try:
        server.mmap = _FakeMmapMod
        def _pr(addr, n):
            """The stub throws where the kernel would send SIGBUS -- a throw
            must not abort the guard, it is its RED result."""
            try:
                return server.HwBus.phys_read(_Stub(), addr, n)
            except BusFault as e:                            # noqa: BLE001
                return e

        got_p = _pr(0x50000000 + 0x3FC, 1024)
        check("phys_read reads from an ODD address without error "
              "(the device stub would reject an odd copy start)",
              got_p == phys[0x3FC:0x3FC + 1024], str(got_p)[:90])
        got_q = _pr(0x50000000 + 0x1000, 64)
        check("and the aligned case delivers the same as before",
              got_q == phys[0x1000:0x1040], str(got_q)[:90])
    finally:
        server.mmap = real_mmap
    check("phys_read copies from the PAGE START (not from the odd "
          "address) -- the fix of the crash class for ALL callers",
          "raw = bytes(m[0:span])" in srv and "span = (off + n + 15) & ~15" in srv)
    inf6 = {}
    got6 = server.dump_bytes(mk_bus(0x1, 0x0, 0), "ddr", sc=sc, cap=400,
                             info=inf6)
    check("an empty buffer stays empty (no truncation claimed)",
          got6 == b"" and inf6 == {"available": 0, "returned": 0,
                                   "capped": False}, str(inf6))

    check("server: /api/state names the cap (the user interface does not "
          "invent it)", 'vals["dump_cap"] = DUMP_CAP_DEFAULT' in srv)
    check("server: the truncated dump has a different file name (_tail)",
          '"_tail" if info.get("capped") else ""' in srv)
    check("server: the answer carries the balance in its header",
          "X-Dump-Available" in srv and "X-Dump-Capped" in srv)
    check("server: the decode path uses THE SAME cap (NexRv does not get "
          "256 MiB)",
          srv.count("cap=dump_cap_arg(q)") == 2)
    check("server: the ring window is no longer called `cap` (the old "
          "double use would have set the cap to 1 MiB)",
          "ring = bus.read(\"ctrl\", sc.co(\"trace_bufsz\"))" in srv)

    # User interface: display of the rejected window write + the cap hint.
    check("index.html: b4 has a name in the code (not a bare 0x10)",
          "const DDR_CFG_REJ=0x10;" in idx)
    check("the DDR card shows the rejection as a WORD",
          "drej?'cfg!'" in idx and "classList.toggle('rej',drej)" in idx)
    # Measured on the board: the DDR card is 112 model units wide and clips
    # with overflow:hidden -- an appended "cfg refused" was gone. The
    # rejection therefore REPLACES the mode word. What gets checked is the
    # only promise this change can make: it does NOT make the line longer
    # than it already was (the existing line "ring · w8" already barely
    # fits; shortening it is the business of whoever touches the geometry in
    # the generator -- gui/ is off limits here).
    ddrw = next((n["w"] for n in (geo.get("tgc5b2_axis_wp") or {})["nodes"]
                 if n["id"] == "ddr"), 0)
    rej_line, old_line = len("cfg! · drops 0"), len("ring · w8 · drops 0")
    check("the rejection line is SHORTER than the existing line (%d < %d "
          "characters at %d units of block width)" % (rej_line, old_line, ddrw),
          rej_line < old_line and ddrw > 0)
    check("the rejection replaces the mode (no appending that would get "
          "truncated)",
          "dw.textContent=drej?'cfg!'" in idx)
    check("the long form goes where there is room (the log, ONCE per "
          "rejection)",
          "let DDRREJ=false;" in idx and "if(drej&&!DDRREJ){" in idx
          and "DDR window write REFUSED (SINK_STAT b4 ddr_cfg_rej)" in idx)
    check("the rejection is not marked by colour alone",
          ".sinksw.rej{" in idx)
    check("the hover panel of the DDR card carries the state as a row of its own",
          "['window write'," in idx and "REFUSED while armed" in idx)
    # This used to prove that `apply` reads back instead of reporting
    # "applied". The button has since been REMOVED -- the proof therefore
    # moves into the read-only block below (no input field, no apply, server
    # 403). The old check stays in its NEGATIVE form: it speaks up if the
    # path comes back.
    check("the apply panel of U8 is GONE (U9: the window is display only now)",
          "#b_dapply" not in idx
          and "Size and base are REFUSED while the sink is armed" not in idx)
    check("the dump cap is stated at BOTH buttons (panel + "
          "Trace & Decode)",
          "esc(dumpHint(src))" in idx and "$('dl_cap').textContent" in idx)
    check("the hint takes the number from /api/state, not from the HTML",
          "(STATE||{}).dump_cap" in idx and "dump_cap=" not in idx)
    check("the hint names the way to the full dump",
          "append &max=0 to " in idx)

    # ------------------------------------------------------------------
    # the DDR window is display only, and the server says no
    # ------------------------------------------------------------------
    # Requirement after the click test: Apply went through without a murmur,
    # so not only the SIZE has to be protected but the OFFSET as well -- both
    # read-only, because a window that can be shoved around the address space
    # disturbs the hosting Ubuntu. Found on the board: DDR_BASE = DDR_SIZE =
    # 0x8000_0000, sink armed, WPTR 0, every beat discarded.
    print("== U9: DDR window read-only (user interface + server) ==")
    check("the panel has NO input field for size/base any more",
          'id="in_dsz"' not in idx and 'id="in_dba"' not in idx)
    check("and no write path to the two registers (not even a "
          "hidden one)",
          "ctrlOff('ddr_size')" not in idx and "ctrlOff('ddr_base')" not in idx)
    seg9 = idx.split('<span class="hint">Mode:</span>\n        <select class="wv"'
                     ' id="m_ddr">')[1].split("row.querySelector('#m_ddr')")[0]
    check("the window is there as a DISPLAY (an element of its own, not an input)",
          'id="d_win"' in seg9 and "<input" not in seg9, seg9[:80])
    # The screenshot showed it: set only while the control panel is built, it
    # read "0x0 + 0 B" when the block was selected BEFORE the first
    # /api/state (URL lever ?sel=ddr). For a display-only element that is the
    # class "the display keeps quiet about a state".
    check("the display is updated on build AND on the polling tick",
          "paintDdrWindow();" in seg9
          and "paintDdrWindow();          // the window display follows" in idx)
    check("paintDdrWindow names base AND size and both registers in the "
          "tooltip",
          "e.textContent=b+' + '+fmtB(s.ddr_size>>>0);" in idx
          and "'DDR_BASE '+b+' + DDR_SIZE '+z" in idx)
    check("the hint is English and names the source of the ruling",
          "fixed by the bitstream / reserved-memory layout" in seg9)
    check("it says that the server rejects too (defence in depth)",
          "HTTP 403" in seg9 and "curl included" in seg9)
    check("it names the reason, not just the rule (an AXI write master "
          "into Linux)", "AXI write master" in seg9
          and "memory of the hosting Linux" in seg9)
    check("it says what the U6 interlock CANNOT do (only while the sink is armed)",
          "only catches it while the sink is armed" in seg9)
    check("it names the legitimate way to change the window",
          "change the bitstream and the device tree" in seg9)
    check("the mode stays operable (the lock is only for the window)",
          'id="m_ddr"' in idx and "DDR mode: " in idx
          and "circular (wraps" in seg9)
    check("clear/on/off stay operable",
          "'ddr_clear'" in idx and "act==='ddr_on'" in idx
          and "act==='ddr_off'" in idx)

    # Server side: from a REAL call, not read out of the source text.
    for key, name in (("ddr_base", "soc.DDR_BASE"), ("ddr_size", "soc.DDR_SIZE")):
        r9 = server.window_policy_reason(sc, "ctrl", sc.co(key))
        check("server refuses %s" % name,
              (r9 or "").startswith("FORBIDDEN") and name in (r9 or ""),
              (r9 or "no reason")[:70])
        check("and gives the reserved window as the reason (%s)" % key,
              "reserved-memory" in (r9 or "") and "ctrace-pl-ddr" in (r9 or ""))
        check("and says that the hardware interlock does NOT cover it (%s)" % key,
              "at ddr_en=0 the hardware takes any value" in (r9 or ""))
        check("and names the path that remains (%s)" % key,
              "Mode (circular/one shot), clear and on/off stay writable"
              in (r9 or ""))
    # Counter-checks: the lock must hit ONLY these two registers. A policy
    # that takes the neighbour along shows up at the first mode change.
    for key in ("sink_ctrl", "control", "ddr_wptr", "sink_stat"):
        if sc.co(key) is None:
            continue
        check("counter-check: %s stays free" % key,
              server.window_policy_reason(sc, "ctrl", sc.co(key)) is None)
    check("counter-check: the same number in a different region hits nothing",
          server.window_policy_reason(sc, "enc", sc.co("ddr_base")) is None)
    # Data driven, not hard wired: the CTRL layout is build dependent
    # (tgc5b2 0x1C/0x20, MBV 0x20/0x24). A fixed number would have locked the
    # wrong register on the other build -- exactly the class the board has
    # already shown once (see the ctrlOff comment).
    nsc = 0
    for other in cat.by_id.values():
        ob, os_ = other.co("ddr_base"), other.co("ddr_size")
        if ob is None or os_ is None:
            continue
        nsc += 1
        ok = (server.window_policy_reason(other, "ctrl", ob) or "").startswith(
            "FORBIDDEN") and (
            server.window_policy_reason(other, "ctrl", os_) or "").startswith(
            "FORBIDDEN") and server.window_policy_reason(
                other, "ctrl", other.co("sink_ctrl")) is None
        check("scenario %s: the policy hits 0x%02X/0x%02X, not SINK_CTRL"
              % (other.id, ob, os_), ok)
    check("more than one scenario checked (the layouts differ)",
          nsc >= 2, "%d scenarios" % nsc)
    check("server: the interlock sits BEFORE the hardware gates in the "
          "write path, with 403 instead of 409",
          "(window_policy_reason(SC, region, off), 403)" in srv
          and srv.index("(window_policy_reason(SC, region, off), 403)")
              < srv.index("(write_gate_reason(bus, region, off), 409)"))
    check("server: the answer carries the code the policy demands "
          "(no fixed 409 any more)",
          "self._json({\"error\": reason}, code)" in srv)
    check("server: the rejection is in the log (with its status)",
          '"reason": reason, "status": code' in srv)
    # Register card: the policy also stands where the operator opens the
    # register -- otherwise card and control panel contradict each other.
    for p in ("soc.DDR_BASE", "soc.DDR_SIZE"):
        f9 = f_of(p, "Value")
        check("%s: the map lists the field as read-only-by-policy" % p,
              f9.get("policy_ro") is True
              and "READ-ONLY BY POLICY" in f9["access_rule"])
        check("%s: and still tells the HARDWARE truth (sw stays rw)" % p,
              f9["sw"] == "rw" and "U6 interlock" in f9["access_rule"])

    # Compact number format: against the shipped code, in node.
    if node_ok:
        with tempfile.TemporaryDirectory() as td:
            probe9 = Path(td) / "u9_count_probe.mjs"
            probe9.write_text(JS_U9_PROBE, encoding="utf-8")
            p9 = subprocess.run(["node", str(probe9), str(HERE / "index.html")],
                                capture_output=True, text=True,
                                encoding="utf-8")
        res9 = []
        for ln in (p9.stdout or "").splitlines():
            if ln.startswith("U9RESULT "):
                res9 = _j.loads(ln[len("U9RESULT "):])
        check("U9 number probe ran (node, rc=0)",
              p9.returncode == 0 and bool(res9),
              "rc=%d %s" % (p9.returncode, (p9.stderr or "")[:160]))
        for r in res9:
            check(r["name"], r["ok"], r.get("info", ""))
    # And the application: the card counters ALL go through setCnt. A
    # forgotten counter is exactly the one that overflows later.
    for cid, what in (("ddr_drops", "DDR"), ("pib_drops", "PIB"),
                      ("axis_beats", "AXIS"), ("wp_sdrop'+r", "WP-Shim"),
                      ("wp_rate'+r", "WP-FIFO")):
        check("card counter %s (%s) goes through setCnt" % (cid, what),
              ("setCnt('%s" % cid) in idx, cid)
    check("counter-check: no card counter goes directly through opt() any more",
          "opt('ddr_drops'" not in idx and "opt('pib_drops'" not in idx
          and "opt('axis_beats'" not in idx)

    # The cheapest guard here, and the one with the greatest leverage: does
    # the SHIPPED page still parse at all? The node probes above cut out
    # individual functions -- a typo outside them (and this change touches
    # card text, control panel and download path) turns the whole page white
    # without a single check going red.
    if node_ok:
        with tempfile.TemporaryDirectory() as td:
            # .js, not .mjs: a <script> block runs in sloppy mode in the
            # browser; the module check would be stricter than reality.
            blocks = _re.findall(r"<script>(.*?)</script>", idx, _re.S)
            check("index.html has exactly ONE script block (otherwise the "
                  "guard checks only a part)", len(blocks) == 1,
                  "%d blocks" % len(blocks))
            jsf = Path(td) / "index_script.js"
            jsf.write_text(blocks[0] if blocks else "", encoding="utf-8")
            pc = subprocess.run(["node", "--check", str(jsf)],
                                capture_output=True, text=True,
                                encoding="utf-8")
            check("the shipped page is syntactically compilable "
                  "(node --check)", pc.returncode == 0,
                  (pc.stderr or "").strip().splitlines()[-1][:140]
                  if pc.returncode else "")

    # ---------------------------------------------------------------
    # Build variant FROM THE BITSTREAM instead of from the generator.
    print("== U11: discovering the build at runtime ==")
    exp = server.DISCOVERY_EXPECT
    check("the expected picture knows both discovery registers",
          sorted(exp) == ["ct_cs_cpuif.pc.trTeConstants",
                          "ct_cs_cpuif.trWpCap"], ", ".join(sorted(exp)))
    # The expected values are COMPUTED (the report names them explicitly as
    # unread) -- here against the RDL reset values, on the board against the
    # register itself.
    check("trWpCap expected word = 0x000003FF (1023 slots)",
          exp["ct_cs_cpuif.trWpCap"]["word"] == 0x3FF,
          hex(exp["ct_cs_cpuif.trWpCap"]["word"]))
    check("trTeConstants expected word = 0x00EE6710 (16/8/3/3/7/7)",
          exp["ct_cs_cpuif.pc.trTeConstants"]["word"] == 0x00EE6710,
          hex(exp["ct_cs_cpuif.pc.trTeConstants"]["word"]))
    for nm, want in (("num_trace_filter", 16), ("num_trace_comparators", 8),
                     ("num_perfcnt_ifetch_th_ranges", 3),
                     ("num_perfcnt_data_rd_th_ranges", 3),
                     ("num_perfcnt_data_rd_ranges", 7),
                     ("num_perfcnt_data_wr_ranges", 7)):
        check("... field %s = %d" % (nm, want),
              exp["ct_cs_cpuif.pc.trTeConstants"]["fields"][nm] == want)
    # Reading: the demo bus is seeded from the same reset values, so it MUST
    # deliver the expected picture -- that makes the decode path testable
    # without a board; the board then tests the silicon.
    db = server.DemoBus(sc)
    d11 = server.read_discovery(db, "enc")
    check("the demo bus delivers the expected picture (ok, no deviation)",
          d11["ok"] and not d11["mismatch"], "; ".join(d11["mismatch"])[:80])
    check("wp_slots comes from trWpCap.Entries, not from the scenario map",
          d11["wp_slots"] == 1023, str(d11["wp_slots"]))
    check("the words read are in the answer together with their offset",
          d11["regs"]["ct_cs_cpuif.trWpCap"]["offset"] == 0x4020
          and d11["regs"]["ct_cs_cpuif.pc.trTeConstants"]["offset"] == 0x3008)
    # Counter-check: a bitstream of a different build must NOT count as fitting.
    db2 = server.DemoBus(sc)
    db2.write("enc", 0x4020, 15)                  # a 15-slot bitstream of the older kind
    d12 = server.read_discovery(db2, "enc")
    check("counter-check: 15 slots instead of 1023 -> deviation reported",
          (not d12["ok"]) and any("Entries" in m for m in d12["mismatch"]),
          "; ".join(d12["mismatch"])[:80])
    check("... and the message names both numbers",
          any("hardware 15" in m and "register map 1023" in m
              for m in d12["mismatch"]), "; ".join(d12["mismatch"])[:80])
    db3 = server.DemoBus(sc)
    db3.write("enc", 0x3008, 0x00EE6710 ^ 0x1)    # one filter less
    d13 = server.read_discovery(db3, "enc")
    check("counter-check: deviating trTeConstants -> deviation reported",
          (not d13["ok"]) and any("num_trace_filter" in m
                                  for m in d13["mismatch"]),
          "; ".join(d13["mismatch"])[:80])
    # Server: the response carries the build variant so that the header line
    # can show it without claiming it.
    check("server: /api/state carries caps_hw",
          'vals["caps_hw"] = read_discovery(bus, "enc")' in srv)
    check("server: /api/wp/status carries the slot count of the bitstream",
          'st["wp_slots_hw"] = d["wp_slots"]' in srv)
    check("server: the expected values come from regmap.json, not from a "
          "constant here", 'f.get("reset") or 0' in srv
          and "DISCOVERY_PATHS = " in srv)
    # User interface: the badge is painted from the state, not set once from
    # regmap.json (the same class as paintDdrWindow).
    check("index.html: the profile badge follows the polling tick",
          "paintProfileBadge(s.caps_hw);" in idx
          and "paintProfileBadge(null);" in idx)
    check("... and turns red when the map does not match the bitstream",
          "CAPS MISMATCH" in idx and "el.style.color='var(--err)'" in idx)
    check("... the tooltip names both registers with their address",
          "trWpCap.Entries@0x4020" in idx
          and "pc.trTeConstants@0x3008" in idx)
    check("... and in the good case the slot count that was read",
          "+fmtCnt(c.wp_slots)+' WP'" in idx)
    check("counter-check: the old one-off assignment from RM.profile is gone",
          "$('profile').textContent=RM.profile" not in idx)

    # bitstream identifier: same app name, different build (U4 pattern).
    av = {v.get("app"): v for v in (sc.raw.get("app_variants") or [])}
    s3 = av.get("tgc5b2_axis_wp_c0b_sink3") or {}
    check("app_variants: C0B_SINK3 carries the md5 of the U11 bitstream",
          s3.get("bit_md5") == "6dd0778b842e16f145af81c1df2e3ca8",
          str(s3.get("bit_md5")))
    check("and the note names the predecessors, so an old build stays "
          "recognisable",
          "0378884e" in (s3.get("note") or "")
          and "f9ff404d" in (s3.get("note") or "")
          and "fef8ace2" in (s3.get("note") or ""))
    check("the label names the 256 MiB window",
          "256 MiB" in (s3.get("label") or ""), s3.get("label"))

    # Geometry: the number that has to fit, against the generated width.
    gw = {n["id"]: n for n in (geo.get("tgc5b2_axis_wp") or {}).get("nodes", [])}
    need = len("drop 4,294,967,294") * 6 + 12
    for nid in ("wpshim0", "wpshim1"):
        w = (gw.get(nid) or {}).get("w", 0)
        check("%s is wide enough for the longest line (%d >= %d)"
              % (nid, w, need), w >= need)
    # ... and it must not run into the funnel from the side.
    fx = (gw.get("funnel") or {}).get("x", 1e9)
    for nid in ("kriaps0", "kriaps1"):
        g0 = gw.get(nid) or {}
        check("%s stays left of the funnel (%d + %d <= %d)"
              % (nid, g0.get("x", 0), g0.get("w", 0), fx),
              g0.get("x", 0) + g0.get("w", 0) <= fx - 20)
    # No overlap inside the chain (the blocks have grown).
    for a, b in (("wpshim0", "wpfifo0"), ("wpfifo0", "kriaps0"),
                 ("wpshim1", "wpfifo1"), ("wpfifo1", "kriaps1")):
        ga, gb = gw.get(a) or {}, gw.get(b) or {}
        gap = gb.get("x", 0) - (ga.get("x", 0) + ga.get("w", 0))
        check("%s -> %s: room for the arrow, no overlap (%d)"
              % (a, b, gap), gap >= 40, "gap %d" % gap)

    print()
    if FAILS:
        print("H_WP_FAIL  %d/%d checks red:" % (len(FAILS), NCHECK))
        for f in FAILS:
            print("  - " + f)
        return 1
    print("H_WP_ALL_PASS  (%d checks)" % NCHECK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
