<!--
SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
SPDX-License-Identifier: CC-BY-4.0
-->

# Formal gates for the emission core

Property checking of the encoder's emission path over the licence-free
SymbiYosys route.

Motivation: all three encoder defect classes that the hardware robustness
campaigns produced — trap anchor, resume-anchor race, flush clobber — were
local cycle collisions with a small state space. Dynamically they were only
visible by luck; formally they fall in seconds. The evidence is in this
directory: the red counter-proof of the resume-anchor race fails on the
pre-fix revision at **BMC step 6**, the flush-clobber one at **BMC step 4**
(see below).

## Toolchain

| Tool | Version used | Where |
|---|---|---|
| OSS CAD Suite (yosys, sby, solvers) | 2026-08-02 (Yosys 0.67+137, Z3 4.15.5, Yices 2.7, btormc) | `$OSS_CAD_SUITE` |
| sv2v | v0.0.13 | `$SV2V_HOME` |

The environment is set up **per session** by [`common/env.sh`](common/env.sh)
— nothing is added to a global PATH. It probes the common install roots in
order (`/opt/oss-cad-suite`, `D:/tools/oss-cad-suite`, `$HOME/oss-cad-suite`,
and the same for sv2v) and names the variable to set when none of them fits;
`OSS_CAD_SUITE` and `SV2V_HOME` stay overridable. Run a target with
`bash <target>/run.sh [tasks…]`, its counter-proof with
`bash <target>/run_red.sh`. In CI: `scripts/run_formal.sh` (`TARGETS=…`,
`RED=1` for the counter-proofs).

### Timeouts — a run out of clock is not a failed property

`FORMAL_TIMEOUT` (default 3600) is a per-task budget; a target's wall-clock
limit is that budget times the number of tasks it declares.
`FORMAL_TIMEOUT_<target>` overrides the total for one target and switches the
scaling off.

It used to be one flat 3600 s around a whole target regardless of how much
work it declared, and the summary read `FAIL  mseo_mdo` when the clock ran
out. A formal FAIL says a property was violated; a package spent a triage
round finding out that this one did not.

Where the time goes, **measured** on `mseo_mdo`, 2026-08-06: `sby` runs the
tasks of one `.sby` concurrently and they contend, so the limit is one wall
clock for the whole target. All three tasks passed, and each took most of an
hour:

| task | elapsed | verdict |
|---|---|---|
| `live` | 0:52:42 (3162 s) | DONE (PASS, rc=0) |
| `bmc` | 0:56:15 (3375 s) | DONE (PASS, rc=0) |
| `cover` | 0:56:17 (3377 s) | DONE (PASS, rc=0) |

Against the old flat 3600 s that is a 6 % margin for the whole target under
the load of a single session. Anything else on the machine pushes it over,
and the run then reported FAIL — which is how a green target came to cost a
triage round.

The contention has a named cause, and it is the P9 observation again: the
`live` task carries a second engine (`smtbmc bitwuzla`) that was still
grinding at step 68 of 120 after 51 minutes of engine time on a bound the
first engine (`btor btormc`) had already cleared; `cover` made essentially no
progress while it ran. **Raising the budget is the symptom fix; scoping that
engine away from `live` is the cause fix.** The latter changes the proof
configuration, so it is recorded here as a measured recommendation rather
than done silently.

A timeout is now its own verdict and names the knob:

```
TIMEOUT  mseo_mdo (bmc cover live) -- killed after 60s; NOT a property
  failure. Raise FORMAL_TIMEOUT_mseo_mdo=<seconds> (total for this target)
  or FORMAL_TIMEOUT=<seconds> (per task).
```

Every leg's wall-clock time is printed in the summary, so the next person
setting a budget has a number instead of a guess.

## Flow per target

`sv2v -E Assert [-E SeverityTask] <pkgs+rtl+wrapper> | sed/perl > build/*.v`
→ `sby` (smtbmc/yices). The mechanical post-processing steps, each justified
in the target's own `run.sh`:

1. `uwire` → `wire`: the yosys Verilog front end does not know `uwire`
   (IEEE 1364-2005); the substitution is semantics-preserving for a formal
   build.
2. **Strip module-name prefixes** (`s/\bf_<wrapper>\.//`). sv2v inlines
   modules that have interface ports as named generate blocks and writes
   parent-scope references anchored on the module name (`f_x.osnk.cnt`).
   **yosys does not bind such references and leaves the target undriven
   without an error** — found through a counter-example in which `osnk.cnt`
   was free at step 0. See "Tool traps" below. Without the prefix the
   references bind lexically as intended.
3. msg_gen: remove the `else $error(…)` action blocks after `assert` (yosys
   parses immediate assertions but not their action blocks; the check itself
   remains), and cut the two concurrent SVA properties (I6/I7) — the free
   yosys front end has no SVA. Both are restated one-to-one as immediate
   assertions in the wrapper (`A_i6` / `A_i7`).
4. msg_gen: the modport function import from `source_if.sv`
   (`import have_available`) is removed in the build only — an sv2v parser
   limitation; msg_gen never calls the function.
5. nexus_formatter: strip the `$display` statements inside the sim-only
   `SimulationOutput` task (sv2v ignores the `translate_off` pragma, and the
   `tcode.name()` enum method has no formal meaning); the — now empty — task
   itself stays, so the call sites remain untouched.

The RTL's own `pragma translate_off` immediate assertions (the drift guards in
msg_gen) run **along with** the formal build: sv2v ignores synthesis comment
pragmas, which is what we want here.

## Targets, properties, results

### ovf_injector — `formal/ovf_injector/` — **PROVE PASS (unbounded, k=30) + COVER PASS**

Full functional correspondence against an independent mirror model, both
variants in one run: `SEQ_INJECT=0/P=2` and `SEQ_INJECT=1/P=1`. Token
abstraction `T=logic[3:0]` (the injector is type-generic and never inspects
the payload).

| Property | Form | Result |
|---|---|---|
| P-INJ-1 conservation (accepted == forwarded + counted-discarded + cleared, mod 2³²) | unbounded | PASS |
| P-INJ-2 episode debt (d0/d1 exactly once each before forwarding resumes) | unbounded | PASS |
| P-INJ-3 inject_done exactly in the emission cycle of the last marker | unbounded | PASS |
| P-INJ-4 inject_hold blocks the anchor marker, dropping continues | unbounded | PASS |
| Cover: episode, INJ2, discard-under-drop, clear, force_inject, double beat | — | all reached |

Assumption: **ASM-INJ-1** `isnk.cnt <= P` (the counted-vector contract; the
cnt_t encoding P=2 → "3" is illegal). rst, clear, full, hold and the rest are
free.

Semantic detail, documented and not a defect: a `clear` discards concurrent
discards from the counter (RTL: `clear ? '0 : cnt+discards`). The conservation
invariant books them into the cleared account.

### ct_L23_preproc_sync — `formal/preproc_sync/` — **PROVE PASS (unbounded) + COVER + LIVE(≤64) + LIVECOVER + QUOTA + TEREQ + REQCOLL PASS**; mutation counter-proofs 8/8 red

| Property | Form | Result |
|---|---|---|
| **P-SYNC-1 resume-anchor regression** (no periodic sync while a TRACE_ENABLE re-anchor is outstanding, including the edge cycle) | unbounded | PASS |
| P-SYNC-2 one-shot semantics (every emitted one-shot sync was armed; a pause discards event pendings) | unbounded | PASS |
| P-SYNC-3 anchor qualification (SyncReason only from sync_anchor_ok cycles) | unbounded | PASS |
| P-SYNC-4 liveness (sustained overflow + fair retires ⇒ sync gap ≤ 64 cycles; the guard does not starve the periodic arm) | bounded (BMC 200, deterministic environment) | PASS |
| P-SYNC-5 trace-output quota (a: mode gating in the free environment; b: window bound between two syncs, closed through the real CDC pairs with an exact egress-counter model) | unbounded (a) / bounded BMC 160 (b) | PASS |
| P-SYNC-6 no lost quota request (a held overflow level leads to a sync within a bounded number of cycles) | bounded (BMC 160) | PASS |
| P-SYNC-7 no double quota request (a second quota PERIODIC needs an intervening counter rearm) | bounded (BMC 160) | PASS |
| **P-SYNC-9 no lost request over the TE register** (after a WRITE a message follows within 32 cycles — the trigger is the software event, only a MESSAGE stops the clock; loop closed through the shim's real `ct_sync_req_pacer` and both real `signal_cdc` instances) | bounded (BMC 80, `tereq`) | PASS |
| **P-SYNC-10 no double request over the TE register** (every message consumes one launched request: credit counter, plus the bound that the pacing keeps at most one in flight) | bounded (BMC 80, `tereq`) | PASS |
| **P-SYNC-11 request meets quota** (both sources live in one environment: on a beat where the crossed quota level and a TE request stand at the arm together the message is the explicit request — and neither source starves the other: window bound, request liveness and credit all hold with the other one running) | bounded (BMC 160, `reqcoll`) | PASS |
| **P-SYNC-12 the request survives a reset of the CONSUMER's domain alone** (`ev_peer_rst` is free: the pending latch is cleared without an acknowledgement while the pacing keeps running. A request the consumer never took is not dropped — once it runs again the request is taken and answered within 40 cycles. A request it HAD taken counts as answered by its acknowledgement even if the reset then wiped the message out of the sync pipe: the EXIT_FROM_SYS_RST anchor owed right afterwards is the re-anchor software asked for) | bounded (BMC 100, `tereqrst`) | PASS |
| **P-SYNC-8 completeness** (every arming condition the DUT states sets its one-shot in the next cycle; the only escape is a same-cycle consumption, observable as that SyncReason) | unbounded | PASS |
| Cover: all seven SyncReason classes + the resume/periodic collision (re-anchor wins) + pause-with-pending + a SYNC=6 produced by the TCI trigger action ALONE (C_trig_action4) + quota witnesses + TE-request witnesses (served; served twice; a write landing while one is outstanding producing that SECOND message) + collision witnesses (one message serves the request while the quota level stands; a quota PERIODIC still follows) | — | all reached |

**Why P-SYNC-8 exists** (P7 audit A-2). P-SYNC-2 and the `A_*_impl`
strengthenings put the wrapper model on the CONCLUSION side
(`DUT one-shot → model armed`). A model that arms in more states makes them
monotonically WEAKER, and a DUT that never arms satisfies them vacuously:
they catch a spurious event, never a missing one. Measured rather than
argued — with the P7 trigger action removed from the RTL
(`cs_tip.trTeTrigExtInAction0 -> 4'd0`) the suite still reported
*successful proof by k-induction*. P-SYNC-8 is red on exactly that
mutation (`A_trig_complete`). A new event source in this module has to be
added to BOTH directions; extending only the model looks like a
strengthening and is the opposite.

The internal one-shot registers are observed through hierarchical probes.
**Canary assertions** — exact mirrors of two DUT registers plus a pipe tap —
fire in the base case if a probe were silently unbound.

Assumptions: **ASM-SYNC-1** reset in cycle 0 (uninitialized counter and pipe
registers) · **ASM-SYNC-2** trTeInstSyncMode/Max stable (the quasi-static CSR
contract: writes only while Enable=0) · **ASM-SYNC-3** wall_clk == clk
(single-clock abstraction; the handshake CDCs are deterministic under one
clock) · **~~ASM-SYNC-4~~ retired (D1)** — `counter_if.add == 0` held while
the DUT drove no add port; since the half-word cadence counter drives one it
would be a contradiction, and F-1 is fixed at its root, so the assumption is
gone from every top ·
**ASM-SYNC-5** one reset for both domains — in every top EXCEPT `f_tereqrst`.
`ct_encoder` carries `tip_rst` and `wb_rst` as independent inputs, so this is
a real assumption and not a formality; it was unstated until the P8 closing
audit (B-N1) and `f_tereqrst` is the top that drops it. What that top does
NOT drop is ASM-SYNC-3: the two domains are reset apart there, still clocked
together — the two-clock half of the same question is
`scripts/cli_syncreqrst_test.sh` (stage-2 gate `syncreqrst`, with its red
control).
Enable/InstTracing, that is the whole pause/resume dynamic, and all tip events
are FREE; the safety proofs deliberately run with a free `add` as well.

**Red counter-proof for the resume-anchor race** (`run_red.sh`, two-sided):
P-SYNC-1 only (`-DRED_CLASS9`) **PASSES** on the fixed RTL (BMC 80) and
**FAILS at step 6** on the pre-fix worktree — the solver constructs the race
in seconds.

**Mutation counter-proofs** (same `run_red.sh`, build-local one-line defects
via the `MUTATE` hook; each must fail on ITS OWN target property, which the
runner checks by mapping every failing model line back to the property's
signal tokens): `MA` mode gate dropped → A_sync5_mode · `MB` rearm dropped →
A_sync7_rearm · `MC` periodic silent → A_sync5_win · `MD` quota level dead →
A_sync6_live · `ME` acknowledgement dropped → A_sync9_live (the request path
stalls for good: exactly the lost-request class the ack exists to prevent) ·
`MF` pending latch never cleared → A_sync10_credit (one request, a stream of
messages) · `MG` acknowledgement WITHOUT a message → A_sync9_live (isolated
with `-DRED_MASK_SYNC10`, since the credit bound has the shallower
counterexample) · `MH` the request arm steps aside for a standing quota level
→ A_sync11_prio · `MI` the pacer stops holding the request level (the retired
strobe design in one line) → A_sync12_rstlive. `ME` changed its target with the
B-N1 redesign and says so in `run_red.sh`: under a held level an
unacknowledged request is not lost but served again and again, so it now falls
on A_sync10_credit. Last run 2026-08-06, re-run 2026-08-09 after the D1
half-word-counter change: **9/9 red where they must be** (log
`bld/v1_formal_red.log`).

**Vacuity counter-proof (V1, 2026-08-09) — what an over-constrained
environment actually does here.** A mutation falsifies a property by breaking
the DUT. It cannot reach the opposite failure mode: an `assume` that shrinks
the model so far that the properties hold over nothing and the run reports
PASS. D1 removed such an assumption (ASM-SYNC-4, retired above) without being
able to show what it had prevented, because nothing in the suite could put it
back. The `MUTATE_WRAPPER` hook in `run.sh` can. Re-inserting
`assume (dut.cnt_tiphalfword.add == 0)` into all six tops and running the full
task set (log `bld/v1_formal_vacuity.log`):

| Task | Mode | Result with the assumption back |
|---|---|---|
| `prove` | k-induction, free environment | **PASS** — a green safety proof over a model that cannot retire an instruction |
| `cover` · `livecover` · `quotacover` · `tereqcover` · `reqcollcover` · `tereqrstcover` | cover | **FAIL (rc=2)**, all six, with named unreached cover statements |
| `live` · `quota` · `tereq` · `reqcoll` · `tereqrst` | BMC | **ERROR (rc=16)**, `Assumptions are unsatisfiable! Status: PREUNSAT` |

Two lessons, and the second one is the reason this table is here rather than a
sentence:

1. **The cover legs are the detector, and they work.** Every one of the six
   went red. This is why each top in `preproc_sync.sby` has a cover companion,
   and why that pairing is not a nicety.
2. **Only `prove` goes SILENTLY green.** `yosys-smtbmc` runs a pre-SAT check
   and reports PREUNSAT loudly, so the five BMC tops would have failed
   visibly. The k-induction task has no such check. The blast radius of a
   contradictory assumption is therefore narrower than "everything is
   vacuously green" — but it covers exactly the unbounded safety proof, which
   is the strongest claim this gate makes.

Consequence for the other targets: a top whose only task is `prove` (or `bmc`
without a cover companion) is in precisely the configuration that was just
shown to go silently green. Two such tops exist — see Findings F-2.

**What the TE-request environments do and do not close over** (P8 audit B-2).
`f_tereq`, `f_reqcoll` and `f_tereqrst` instantiate the CSR shim's real pacing
module `ct_sync_req_pacer` and the two real `signal_cdc` crossings the shim
wires around it, so the loop is the RTL software actually talks to and no
hand-copied mirror can drift away from it. The crossings run at **equal
clocks** here (ASM-SYNC-3, the assumption this whole wrapper carries): what is
proven is that the four-phase handshake loses no request and serves none twice
at a common clock. That two INDEPENDENT clocks do not break a two-flop level
synchronizer is a CDC-methodology argument (plus the timing constraints), not
a result of this proof — the two-clock evidence is the stage-2 gate
`syncreqrst`, which sweeps reset length, parity, a queued second request and a
write during the reset at two unrelated clocks, and shows its red control. The
rest of the CSR shim — address decoding, the generated register block, the
field's self-clear — is covered by simulation
(`scripts/cli_tesyncreq_test.sh`), not here.

**Why a level handshake and not paced strobes** (P8 closing audit B-N1). The
first design paced two strobes across two toggle synchronizers, and
`f_tereqrst` is the environment that refuted it: with the two domains reset
apart, a strobe the consumer's reset destroys cannot be recovered, and an
acknowledgement already travelling when the reset lands arrives BEFORE any
synchronised view of that reset could, so no amount of reset-watching on the
launch side repairs it (counterexample at step 58 of the first attempt).
Mutation `MI` turns the held request level back into a one-cycle pulse and is
red on `A_sync12_rstlive`. What `f_tereqrst` deliberately does NOT claim is
that exactly one message follows a reset: a request whose acknowledgement the
reset destroyed is asked for again, and one extra anchor is harmless.

`f_tereq` runs with `InstSyncMode = OFF`, so after the startup anchor the only
message that can appear is a served request — which is at the same time the
mode-independence claim for the field. Its bookkeeping is a **credit counter,
not a flag**: a launch can happen while the previous message is still in the
reason pipe, and a flag loses it — the property then fails on itself instead
of on the DUT (seen at step 7 with two perfectly legitimate requests).

P-SYNC-9's trigger is the **software write**, not the pacer's Busy flag. The
first version keyed it on Busy, and the DUT's own acknowledgement clears Busy:
a DUT that acknowledged without emitting anything kept the property green and
was caught only by the auxiliary credit bound — an assertion that did not
enforce the behaviour in its name (P8 audit C-2, the P7 A-2 class). Mutation
`MG` is exactly that defect and is red on `A_sync9_live` now.

`f_reqcoll` exists because "collision tested" must mean more than "both ran in
the same simulation": the byte events and the write are free, so the solver
puts the quota level and the request on the SAME beat, and the cover
`C_coll_on_one_beat` shows that it does (one message, acknowledging the
request, while the crossed quota level stands at the arm — step 26; a quota
PERIODIC still follows at step 50).

### ct_L2_msg_gen — `formal/msg_gen/` — **BMC(50) + COVER**; red counter-proof for the flush clobber

A conservation layer with abstracted payload: the eTIP is reduced to
{sub_type, do_flush, token fields}, and the DF/DAQ/OTHER views reinterpret the
union bits. The CSR feature enables are free but stable, which subsumes both
the all-features-off profile and the full suite profile in a single run.

| Property | Form | Result |
|---|---|---|
| **P-MSG-1 flush-clobber regression** (no consume beat ever coincides with a flush-marker emission; presence for sync-CF/DF/DAQ consumption) | BMC 50 | PASS |
| P-MSG-2 backpressure stability (`!ready_in` ⇒ TraceMsg bit-stable) | BMC 50 | PASS |
| P-MSG-3 holds emit their drain message and never consume; ack == consume_etip | BMC 50 | PASS |
| P-MSG-4 flush debt: latched until settled; a free emission slot settles it immediately (a safety form, stronger than bounded-N) | BMC 50 | PASS |
| P-MSG-4b the same debt claim WITHOUT any hold enumeration: with a debt outstanding, a ready non-consuming beat never goes out empty (`A_msg4_no_idle_beat`) | BMC 50 | PASS |
| **Hold-mirror completeness** (`A_consume_decomposition`): the wrapper's drain-hold list equals the RTL's, derived rather than counted | BMC 50 | PASS |
| I6/I7 (standing invariants, restated from SVA) + all RTL-internal drift guards | BMC 50 | PASS |
| Cover: sync composition, flush emission, clobber collision, drain hold, backpressure hold, debt during consumption, **free slot reached**, **debt beat whose slot a drain took** | — | 8/8 reached |

A note on the form of P-MSG-1: `consume_is_silent` is NOT the same as
"composed" — flush-latch beats and silent shapes with do_flush legitimately
consume without composing, and silent OTHER/RESERVED icnt beats exist too.
Clobber freedom is therefore stated without classification, which is exactly
the else-if semantics of the fix, plus presence checks for the consumption
classes that can be classified exactly.

Assumptions: **ASM-MSG-1** reset in cycle 0 · **ASM-MSG-2** CSRs stable
(quasi-static) · **ASM-MSG-3** FWFT source contract (item and valid stable
until ack, which is cvs_fifo behaviour) · **ASM-MSG-4** sub_type ∈ {0..4} ·
**ASM-MSG-5** composer rcode contract (only NONE, ICNT_OVERFLOW,
TRACE_DISABLED, CORR_DEBUG_ENTRY, CORR_LOW_POWER — free encodings such as 7
never occur on the eTIP and would route the consumption past the drift-guard
mirrors).

#### The hold mirror is derived, not counted — and why that took a red gate to learn

`f_any_hold` mirrors the drain-hold arms that precede `else if (consume_etip)`
in the RTL. A hold missing from that list does not weaken a check, it makes one
WRONG: the wrapper then reads a cycle in which the RTL legitimately drains as a
free emission slot, and P-MSG-4 reports an RTL defect that does not exist.

That happened. The list was complete when it was written on 2026-08-02 with
seven arms. On 2026-08-12 `ee25d098f85` added an eighth
(`cf_sync_icnt_overflow_hold`) touching only `rtl/ct_L2_msg_gen.sv` — 55 lines,
`formal/` untouched. Nine days later the gates ran in CI for the first time
(`cf7f77ace05`) and `A_msg4_slot_pays` failed at step 20 with a counterexample
in which the RTL had emitted `SUB_MSG_CF` + `RESOURCE_FULL` from
`send_icnt_overflow_msg` — the drain, not a starved flush marker. The message
CONTENT is what separates the two readings; the `consume_etip` that is also
high one cycle later is a decoy.

Two additions keep the next such arm from costing the same forensic detour:

* **`A_consume_decomposition`.** `consume_etip` is *defined* as
  `eligible && !<any hold>`. Restating that definition with the wrapper's two
  mirrors and comparing it against the probed signal —
  `assert (f_consume == (f_eligible && !f_any_hold))` — catches drift in both
  mirrors and in both directions: a hold arm the list lost, and an eligibility
  mirror that is too weak. A ninth arm therefore turns *this* check red, by
  name, instead of producing a misleading P-MSG-4 trace. It is also the canary
  for the hold probes themselves: an upward reference yosys failed to bind
  reads 0 and shows up here.
* **`A_msg4_no_idle_beat`.** The debt claim restated without the hold set at
  all: with a request outstanding, a ready non-consuming beat never goes out
  empty — either a drain uses the slot or the marker is paid. This one stays
  sound even if both mirrors drift.

Completing a hold list can also make a property vacuous instead of true, which
is why `C_freeslot_reached` was added: the free-slot antecedent is reachable
(step 4), so `A_msg4_slot_pays` still has something to say. `C_debt_slot_drained`
covers the exact state of the old counterexample, now as a witness of legitimate
behaviour.

**Mutation counter-proof for P-MSG-4 and the drift guard** (`run_red_p4.sh`):
each run disables exactly one mechanism and demands a named assertion turn red
— a mutation that stays green would mean the assertion cannot fail and is
decoration. Measured 2026-08-24 on the pinned
toolchain:

| Mutation | assertion it must trip | result |
|---|---|---|
| MUT-0 control, unmutated | — | **GREEN** at depth 50 |
| MUT-A the free-slot arm drops the marker but still clears the request | `A_msg4_debt_kept` | **RED**, step 4 |
| MUT-B … `A_msg4_debt_kept` disabled | `A_msg4_slot_pays` | **RED**, step 4 |
| MUT-C … `A_msg4_slot_pays` also disabled | `A_msg4_no_idle_beat` | **RED**, step 4 |
| MUT-D the stale mirror itself (clean RTL, all three P-MSG-4 assertions off) | `A_consume_decomposition` | **RED**, step 18 |

MUT-D is the one that matters: the guard catches the exact state that went
unnoticed for nine days, and it catches it BY NAME. The script attributes each
failure by a signature in the generated Verilog rather than by the reported line
number, and aborts when the expected and the actual assertion disagree — the
first draft of it did use the line number and consequently credited MUT-A to
`A_msg4_slot_pays` when the assertion that fired was `A_msg4_debt_kept`.

**Red counter-proof for the flush clobber** (`run_red.sh`, two-sided):
P-MSG-1 only (`-DRED_CLASS8`, the sync-CF variant, which also compiles on the
pre-fix revision) **PASSES** on the fixed RTL (BMC 30) and **FAILS at step 4**
on the pre-fix worktree — the trailing `if (FlushRequest)` overwrites the
message composed in the same cycle. The class that survived three narrowly
targeted simulation reproducers and two hardware campaigns falls formally in
four cycles.

k-induction for msg_gen: the internal drift guards reference deep
reachability invariants (the repeated-history and RepeatBranch states) and are
not inductive without additional strengthening invariants. The `prove` task is
kept configured as an attempt; the accepted criterion for this target is BMC
depth 50.

### MDO/MSEO output stage — `formal/mseo_mdo/` — **BMC(40) + COVER + LIVE(120) PASS**; mutation counter-proofs 3/3 red

The last emission stage (nexus_message_t → MDO/MSEO chunks → ATB beats):
msg_buffer → bit_slicer (MDO=6, the product width) → mseo_controller (dual) →
atb_chunk_packer, with the glue equations copied one-to-one from
`ct_L2_mseo_mdo_formatter.sv`. sv2v does not pass interface instances through
two levels of inlining, so the wrapper is built without interfaces and without
cross-module references — which turned out to be the most robust form anyway,
see "Tool traps". The seam is modelled as an ideal FWFT queue of the real
depth, 8.

| Property | Form | Result |
|---|---|---|
| P-MDO-1 MSEO legality (the reserved code 2'b10 is never emitted) | BMC 40 | PASS |
| P-MDO-2 dual-pin encoding table (EOM=11 · end-of-variable-field=01 · data=00; ISTO-5001 table 5-1) | BMC 40 | PASS |
| P-MDO-3 conservation (an accepted non-flush message ⇔ exactly one EOM; difference counter without underflow, bound 2) + SOM/EOM pairing | BMC 40 | PASS |
| P-MDO-4 seam has no overflow (occupancy ≤ 8, no write into full, no fire from empty) | BMC 40 | PASS |
| P-MDO-5 beat alignment (after an EOM lane only alignment padding — no message starts mid-beat) | BMC 40 | PASS |
| P-MDO-6 stall stability (valid && !ready holds bits and flags) | BMC 40 | PASS |
| P-MDO-7 flush isolation (marker beats only from an empty emission path) | BMC 40 | PASS |
| No starvation: the next EOM within 64 cycles given pending work and a free drain | bounded (BMC 120, btormc + bitwuzla) | PASS |
| Cover: EOM, end of variable field, EOM mid-beat with padding, flush beats, diff=2, stall, three-field message, seam full | — | all reached |

Assumptions: **ASM-MDO-1** reset in cycle 0 · **ASM-MDO-2** producer contract
(nexus_formatter: contiguous valid fields, data_width ≥ 1, message stable
until accepted) · **ASM-MDO-3** bounded-shape abstraction (at most three valid
fields of at most 12 bits, data above bit 15 zero; slicer data-path parameter
16 instead of 192 — the slice algorithm is width-generic and the full path
only exceeds the SMT parser's nesting limit, measured at 2122) ·
**ASM-MDO-4** the seam is modelled as an ideal FWFT queue of the real depth
(the CDC library FIFO is a separately hardened component, outside this gate's
scope).

Explicitly out of scope here and covered by simulation instead: the CDC FIFO
internals, the ATB drive and flush-detect logic, and the chain_empty / I8
path.

**Mutation counter-proofs** (`run_red.sh`). No historical defect commit exists
for this stage, so falsifiability is demonstrated by mutation:
M1 wrong EOM code (11→01) → A_mseo_eom **red at step 5** ·
M2 missing full gate at the packer → the seam properties **red at step 18** ·
M3 suppressed end_of_message → the conservation bound **red at step 7**.
Unmutated everything is green, so every property family is demonstrably
sharp.

**A liveness lesson, recorded for later reuse:** the first formulation of the
latency counter measured the entire in-flight period, which grows without any
starvation under a gap-free back-to-back stream (a spurious counter-example at
step 67). The second read `chk.*` hierarchically — and yosys left the
module-instance cross-module references silently unbound, so the counter ran
against a free `m_diff`. This is the same phantom-signal trap as below, this
time inside our own harness. The final form exports observer **ports**;
cross-module references are now banned from the formal wrappers entirely.

### ct_L2_nexus_formatter — `formal/nexus_formatter/` — **BMC(40) + COVER + PROVE PASS**; mutation counter-proofs 3/3 red

The P3 data-address compression machine: the DF reference register
(`RefDaddr`), the sticky re-anchor flag (`DfReanchor`) and the TCODE
substitution 5→13 / 6→14 all sit in the formatter, a single registered
field-table stage without FIFO or CDC — so the machine is proven directly,
unbounded. The generic trace message is abstracted to tokens (tcode /
sub_type / ts / DF address / DF data); the rest of the packed union never
gates the DF control flow under test.

| Property | Form | Result |
|---|---|---|
| P-FMT-1 13/14 anchor: after every emitted upgrade the reference equals the transmitted FULL address (`A_fmt1_ref_eq_addr`), and the upgrade direction follows the 5/6 input (`A_fmt1_tcode_dir`) | BMC 40 + k-induction | PASS |
| P-FMT-2 reference upkeep: `RefDaddr` advances ONLY on an emission beat (`A_fmt2_ref_stable`) and a DF emission re-seats it on exactly the offered address (`A_fmt2_ref_seated`) | BMC 40 + k-induction | PASS |
| P-FMT-3 OFF-mode neutrality: with `DataAddrCompress = FULL` the upgrade decision can never fire (`A_fmt3_full_no_upgrade`) | BMC 40 + k-induction | PASS |
| P-FMT-4 sticky re-anchor (T2): an independently written contract mirror equals `DfReanchor` at all times (`A_fmt4_pend_mirror`, also the induction anchor), and a DF offer under an outstanding obligation fires the upgrade (`A_fmt4_reanchor_upgrade`) | BMC 40 + k-induction | PASS |
| P-FMT-5 XOR correctness: the emitted delta is `daddr ^ RefDaddr` — the reference the decoder reconstructs against (`A_fmt5_xor_value`) | BMC 40 + k-induction | PASS |
| Cover: 13 emitted · 14 emitted · XOR form · re-anchor after ERROR · DataTracing edge during a stall · FULL-mode DF emission | — | all 6 reached (steps 3–4) |

Assumptions: **ASM-FMT-1** reset in cycle 0 · **ASM-FMT-2** legal `sub_type`
encoding · **ASM-FMT-3** msg_gen never offers TCODE 13/14 (the sync upgrade is
the formatter's own job; verified msg_gen contract) · **ASM-FMT-4**
`DataAddrCompress` / `InhibitSrc` / `TsEnable` are quasi-static (CSR
programming contract: writable only while `trTeControl.Enable = 0`), while
`trTeDataTracing` stays FREE per cycle — its edges are the T2(b) re-anchor
trigger under test, including edges during a `ready_in` stall.

**Model boundary (deliberate split of duties):** because of the sv2v
packed-struct-literal defect below, the properties bind to the DF-compression
STATE (`RefDaddr` / `DfReanchor`) and to the combinational DECISION nets
(`df_sync_now` / `df_sync_tcode` / `daddr_xor`), each probe guarded by the
canary `A_canary_probe`. The on-wire FIELD layer (the TCODE substitution
inside the field array, the ADDR/UADDR slots) is covered by the simulation
gate `scripts/cli_dfcompress_test.sh` instead: exact TCODE sequence
13,5,5,5,6,6,6,6,14,5, full decode round-trip against the oracle, and the
no-13/14-in-FULL greps. Formal owns the state and decision core, simulation
owns the wire format.

**Mutation counter-proofs** (`run_red.sh`; each is a single-line defect on a
build-local copy of the DUT — the tree is never touched). No historical defect
commit exists for the DF-compression family, so falsifiability is shown by
mutation:
M-A the emission gate is removed from the whole reference/flag update →
`A_fmt4_pend_mirror` **red at step 2** ·
M-B the sticky set on sync/ERROR emission is deleted →
`A_fmt4_pend_mirror` **red at step 3** ·
M-C the gate is removed from the `RefDaddr` assignment ALONE (mirror intact)
→ `A_fmt2_ref_stable` **red at step 3**, which pins the reference family on
its own. Every red run maps *every* failing model line back to the property
source, so a defect that trips an unrelated family is reported as such.

#### Width leg — the same BMC in a 64-bit address net

`nexus_formatter_xlen64` in `scripts/run_formal.sh` runs `bmc` a second
time against a source copy whose only difference is
`ct_pkg::CT_XLEN = 64`. Until R1.1 every gate in this directory had only
ever seen 32-bit addresses, while the wrappers re-type ports by hand to
match the DUT and several of those widths are derived from `CT_XLEN`
(`wrapper.sv:88,173,194,258,259` here, and `composer_slots/wrapper.sv`) —
a wrapper that truncated in a 64-bit build would have proven a property
about a net nobody builds, and nothing here would have said so. The R1.1
closing audit found the hole and closed it by hand for that package
(finding C-6); this is the standing leg.

Measured: **`DONE (PASS, rc=0)` after 777 s** (2026-08-08, copy of the
tree at commit `f20dc6469`). The leg copies `rtl/` + `formal/` (tracked
plus new-but-not-ignored files) into `bld/formal_xlen64/`, flips the knob
with a `sed` and **reads it back** — a renamed declaration would make the
`sed` a no-op and run the 32-bit proof twice under the 64-bit name, which
is the one failure mode this leg cannot be allowed to have. Only
`nexus_formatter` is registered: a target that has never been run at 64
would turn the stage red for an unknown reason. Run one by hand first,
then add it.

### eTIP slot bound — `formal/composer_slots/` — **PROVE PASS (unbounded, k-induction) for `SPLIT_DATA_ACCESS` 0 and 1**; refuted one slot lower

`ct_L23_preproc_composer_etip` allocates the eTIP slots of one tip beat by
incrementing `msg_id_next` at **thirteen** independent sites and writing
`etip_msg_next[msg_id_next]`. The array has `ct_pkg::ETIP_PAR_MSG` entries, so
an out-of-range index writes **nowhere** — an exceeded bound loses messages
*silently*, in the field, with no error indication on the wire. The constant
used to be a closed-form sum over five of the thirteen sites; the P4 re-audit
(finding B-1) showed that three allocation sources sat outside every term of
it. This gate replaces the argument with a proof.

| Property | Form | Result |
|---|---|---|
| **P-SLOT-1** `msg_id_next <= ETIP_PAR_MSG` at the allocation site — the composer's OWN immediate assertion `a_p4_slot_bound`, unmodified | k-induction, unbounded | PASS for `f_slots0` (`SPLIT_DATA_ACCESS = 0`) and `f_slots1` (`= 1`) |

The property is the RTL's assertion, not a mirror: the wrapper adds **no**
probe and no observer port, so the cross-module-reference trap below cannot
apply here.

Assumptions: **ASM-SLOT-1** reset in cycle 0 (the module's registers carry
SystemVerilog initialisers, which yosys does not honour) · **ASM-SLOT-2**
bounded-shape abstraction (same pattern as ASM-MDO-3): the eTIP *payload*
widths, the CVS queue depth (128 → 4), the return-stack depth and the
timestamp width are cut down in build-local copies of `ct_pkg` /
`ct_etip_pkg`. `msg_id_next` has no data dependence on any of them — its
thirteen guards read `tip.*`, `act_cap_st.*`, `sync.reason`, the two
qualifiers, `cs_tip.*` and the module's own control registers, never a
payload field and never a queue entry. Without the cut, yosys' `PROC_MUX`
pass does not terminate in useful time (measured: > 13 GB RSS, no progress).
The feature enables, `ETIP_PAR_MSG` and `ETIP_SLOT_SITES` are **not**
touched — they are the subject of the proof. Everything else is FREE,
including the CSR view: the quasi-static programming contract is
deliberately *not* assumed, so the proof also covers mid-stream
reprogramming.

**What the proof found (the reason this gate exists).** With the formula as
committed before the re-audit, the bound is broken **at BMC step 1**:

```
SBY [composer_slots_bmc0] summary:   failed assertion f_slots0.env.…
    at composer_slots_formal.v:1554.7-1554.50 step 1
SBY [composer_slots_bmc0] DONE (FAIL, rc=2)
```

The counter-example is one beat that carries **eight** slots: a trace-on edge
(device ID + config) on which a *sticky* trace-off correlation from the
previous beat is still pending, together with a low-power entry marker, a
processed retire with a sync verdict (CF + ownership), a qualified data
access and an ACT-ST watchpoint command. Raising the constant one at a time:
7 is still refuted (step 3), 8 passes BMC depth 45 **and** k-induction for
`SPLIT_DATA_ACCESS = 0`; with `SPLIT_DATA_ACCESS = 1` the second data-flow
arm makes 8 fail (step 3) and 9 pass by k-induction.

Two exclusions carry the difference between the thirteen sites and the value
of the formula, and both are *combinational* — which is why the induction
goes through with completely free state:

* the ICNT pre-drain and the debug/low-power entry marker **share one slot**:
  the marker block runs first and sets `icnt_cum_next = 0`, after which the
  pre-drain condition (cumulated + at most 8 ≥ 256) cannot hold;
* the watchpoint arm and the DAQ arm **share one slot**: same beat qualifier,
  mutually exclusive command codes, at most one ACT-ST command per beat.

**Red cross-checks** (`run_red.sh`), two directions, because a bound property
can fail in two ways:
R-TIGHT — shrinking `ETIP_PAR_MSG` by one slot must break the assertion,
otherwise the constant is padded and the proof says nothing about the real
demand. The shrink is applied to the *generated* model (`SLOT_MINUS1=1`), so
the check never carries a second, hand-maintained copy of the formula;
R-EXCL — removing `Cmd != ACT_CAP_ST_WATCHPOINT` from the DAQ arm must break
it too, otherwise the slot-sharing argument that keeps `CT_EN_WATCHPOINT_MSG`
at +0 slots is unchecked.

Both run in the **`f_slots1`** top, and that is not a detail. The package
constant has to cover both settings of a module parameter it cannot see, so in
the shipped `SPLIT_DATA_ACCESS = 0` build it carries exactly one slot of
deliberate margin (with that setting a bound of 8 also passes k-induction,
while the formula gives 9). A tightness check run in the margin-carrying
configuration is vacuous — measured, not assumed: both mutations first came
back **GREEN** on `bmc0`, which is what pointed at the wrong top.

**A second finding, fixed with the gate:** `msg_id_next` was declared
`$clog2(ETIP_PAR_MSG+2)` wide — 3 bits, i.e. 0…7, for a profile with nine
simultaneously enabled allocation sites. A beat needing eight slots would
have **wrapped the counter to 0 and passed the check**; the guard would have
been exactly as silent as the defect it guards. The width now follows
`ct_pkg::ETIP_SLOT_SITES`, and `run.sh` counts the real
`msg_id_next = msg_id_next + 1` statements in the source before every run, so
a newly added arm fails the gate instead of the field.

**Not covered by a simulation leg, and why:** the counter-example needs
`inst_trace_active` to fall and rise on *consecutive tip beats*. The
instruction-level test harness drives that level through CSR writes
(`env.csr.Set_te_trTeControl_InstTracing`), which take tens of cycles, so the
beat cannot be constructed there. The mechanised guards for this defect class
are therefore the formal gate, the R-TIGHT cross-check and the run-time
immediate assertion `a_p4_slot_bound`, whose log scan already fails
`scripts/cli_status_test.sh`.

## Findings

- **F-1 `counter.sv` saturation escape — FIXED (D1, 2026-08-09).** The
  MODE_SATURATION add path tested `wide > overflow_value`, so equality did NOT
  set the overflow flag, while the increment path tests
  `Count+1 == overflow_value`. Landing exactly on `overflow_value` via `add`
  and then incrementing made the counter keep counting without ever setting
  the flag. The solver found it through the free `add` in the P-SYNC-4
  starvation counter-example; it was unreachable while `counter_if.add` was
  undriven in `ct_L23_preproc_sync`, and was therefore parked as low-priority
  backlog.

  It stopped being unreachable when the half-word cadence counter was
  repaired (B-R13-1): that counter has to use the `add` port, its step is
  even and the threshold is a power of two, so landing exactly on it is the
  normal case rather than a corner. Both halves of the recommendation above
  are now implemented — `>=` in the add path, and all four `add` ports of
  `ct_L23_preproc_sync` driven explicitly (three at '0). ASM-SYNC-4 is
  retired with it.
- **F-2 two formal tops have no vacuity leg (V1, 2026-08-09, OPEN).** The
  vacuity counter-proof above measured that a top proven only by `prove` (or
  by `bmc` without a cover companion) reports PASS over an over-constrained
  model without anything going red. Two tops are in that state:
  * `composer_slots` `f_slots0` and `f_slots1` — tasks `bmc0/prv0` and
    `bmc1/prv1`, and `formal/composer_slots/wrapper.sv` contains **no `cover`
    statement at all**, so a cover task added today would pass trivially and
    be worth nothing. Closing this means writing reachability witnesses for
    the slot allocator (a slot really allocated, the P4 bound really
    approached), which needs the allocator's own semantics and is a change to
    the proof, not to its plumbing.
  * `mseo_mdo` `f_mdo_live` — this one has the opposite problem: the top DOES
    carry a witness (`C_live_deep`, `cover (f_lat > 8'd20)`) and the `.sby`
    simply never declared a task that evaluates it. Adding one was TRIED and
    is recorded here because the attempt is the useful part: a `livecover`
    task (`mode cover`, depth 120, engines as for `live`) ran for **1:29:35**
    and did **not** conclude — `smtbmc bitwuzla` died at step 109 of 120 with
    `terminate called after throwing an instance of 'std::bad_alloc'`, and
    `btor btormc` returned no status. Five of the seven witnesses in that cone
    were reached (steps 3–5); `C_live_deep` and the `f_full` seam witness were
    not reached BEFORE the abort — which is not the same as unreachable, and
    must not be read as one. Log `bld/v1_formal_mseo_livecover.log`.
    The task is therefore NOT in the `.sby`: an unproven CI task is the same
    failure class as the missing one. The next attempt should scope the
    bitwuzla engine away — `scripts/run_formal.sh` already records that
    this engine is the long pole on this target's `live` task and recommends
    the same thing — and/or lower the cover depth, which is a change to the
    proof configuration and belongs with its author.
  Reported rather than fixed for `composer_slots` too: writing reachability
  witnesses for the slot allocator needs the allocator's semantics.
- **Tool trap: sv2v cannot parse `var` before a `type(...)` declaration
  (V1, 2026-08-09).** IEEE 1800-2023 6.8 requires the keyword there, and
  `rtl/external/stream/cvs_fifo.sv` carries it since `953857f05` (that is what
  makes yosys-slang accept the encoder in the open ASIC flow). sv2v 0.0.13
  aborts with `Parse error: unexpected statement token`, so the
  `composer_slots` gate was RED from that commit until it was next run — the
  commit verified xvlog and yosys-slang, the two front ends it was about, and
  sv2v was not among them. `formal/composer_slots/run.sh` now strips the
  keyword build-locally (with a read-back guard); the tree keeps the
  LRM-correct spelling and the formal model is unchanged, because
  `automatic type(...)` is exactly what the file said before.
- **Tool trap: yosys leaves module-name-anchored hierarchical write targets
  silently unbound.** The sv2v output `f_wrapper.osnk.cnt = …` parses without
  error but drives nothing; the target becomes free in the formal model.
  Symptom: a counter-example with "impossible" signal values from step 0.
  Safeguard: canary assertions on exact register mirrors. Fix: strip the
  prefix so the reference binds lexically.
- **Tool trap (Windows): the suite `yosys.exe` ships with a 2-MiB PE stack
  reserve — deep backend-writer recursion dies with `0xC00000FD`
  (STATUS_STACK_OVERFLOW) and sby reports only "engine did not return a
  status".** Hit 2026-08-04 by the nexus_formatter model (variable-index
  `fields[idx+N]` writes on the wide message register); `write_smt2`,
  `write_btor` and the ywmap/info writers all crashed, gate-level mapping
  did not help (the ywmap writer still recursed too deep). Fix: patch the
  PE header field `SizeOfStackReserve` from 0x200000 to 0x8000000 (128 MiB)
  in `$OSS_CAD_SUITE/bin/yosys.exe` (backup kept as `yosys.exe.orig_stack`;
  8-byte little-endian value at `e_lfanew+0x18+0x48`, PE32+). Like the
  smtio patch, this is suite-local and must be RE-APPLIED after a suite
  update. `scripts/run_formal.sh` checks the field before running and
  aborts loudly if a suite update reverted it.
- **Tool trap: sv2v drops the padding of POSITIONAL packed-struct literals.**
  `NexusMsg.fields[i] <= '{TCODE, FIXED, tcode, 6}` on a 210-bit
  `nexus_field_t` becomes the UNPADDED concat `{9'h00c, <6-bit enum>, 6}`
  (47 bits), left-zero-extended into the field slot — so every struct member
  ends up at the wrong bit offset and the field register does NOT represent
  the RTL. Found 2026-08-04 through counter-example bit forensics on the
  nexus_formatter model; the generated line is directly visible in
  `build/nexus_formatter_formal.v`. The RTL itself is correct (XSIM and
  synthesis pad member-wise), and only POSITIONAL literals are affected —
  msg_gen writes its fields by member assignment and is unaffected.
  Consequence: **a formal property must not bind to a packed-struct register
  written by positional literals.** Measured discriminator (scratch
  experiment, cover depth 25): covers on the field's own name tag
  (`fields[0].name == TCODE`) and on the substituted TCODE value
  (`fields[0].data[5:0] == 14`) are BOTH unreachable, while the identical
  event on the state layer (`p_dfsync_q && !p_dfwrite_q`) is reached in
  step 3 — i.e. an unreachable field-layer witness is a model artifact, not
  an RTL finding.

## Limits — what is deliberately NOT proven

- No end-to-end proof: the composition composer → msg_gen → formatter remains
  the responsibility of the simulation battery and the hardware campaigns.
- msg_gen: payload and field CORRECTNESS (byte identity) is not the subject
  here, only conservation and arbitration. The byte contract is covered by the
  byte-identity legs of the simulation battery.
- The CDC instances are proven under a single clock; metastability is not a
  formal subject.
- Address width: only `nexus_formatter bmc` has a 64-bit leg (above). The
  other five targets are proven at `CT_XLEN = 32` only, and
  `composer_slots/wrapper.sv` re-types address ports the same way
  `nexus_formatter`'s does — so its 64-bit soundness is untested, not
  established.
- Every `assume` is justified individually above; there are no others.
