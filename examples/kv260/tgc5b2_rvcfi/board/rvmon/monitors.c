/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * monitors.c -- the five runtime-verification monitors.
 *
 * They see the same merged, time-ordered record stream and disagree on
 * purpose. Each answers a different question, and the interesting cases are
 * the ones where only some of them fire:
 *
 *   mon_cfg      Did control flow go where the program says it should?
 *   mon_proto    Was every shared access inside a critical section?
 *   mon_lockset  Is there a lock that consistently protects each object?
 *   mon_hb       Were two conflicting accesses actually unordered?
 *   mon_order    Do the two cores agree on the order locks are taken in?
 *
 * The demo's five modes are built so that each mode lights up a different
 * subset. In particular RV_MODE_RACE_WRONG_LOCK produces a lockset finding
 * WITHOUT the accesses ever having to overlap in time -- which is the whole
 * argument for lockset analysis over "did they happen close together".
 * And RV_MODE_LOCK_ORDER produces an order finding for a deadlock that did
 * NOT occur, which is the whole argument for runtime verification.
 */

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "rvmon.h"

#define RV_MAX_LOCKS 8
#define RV_MAX_OBJS  16
#define RV_MAX_CORES 2

/* Objects that both cores legitimately touch. The ring is deliberately NOT
 * in here: it is single-producer/single-consumer and correct by
 * construction, so it is the control -- a monitor that reports it is wrong,
 * and the demo would rather find that out here than in front of a customer. */
static int obj_is_shared(unsigned obj)
{
	return obj == 1u /* balance */ || obj == 2u /* count */ || obj == 3u /* checksum */;
}

static void add(rv_findings_t *out, const char *mon, const char *klass,
                const rv_rec_t *a, const rv_rec_t *b, const char *fmt, ...)
{
	rv_finding_t f;
	va_list ap;
	memset(&f, 0, sizeof f);
	f.monitor = mon;
	f.klass = klass;
	if (a) { f.pc_a = a->pc; f.core_a = a->core; f.ts_a = a->ts_unrolled; }
	if (b) { f.pc_b = b->pc; f.core_b = b->core; f.ts_b = b->ts_unrolled; }
	va_start(ap, fmt);
	vsnprintf(f.text, sizeof f.text, fmt, ap);
	va_end(ap);
	rv_finding_add(out, &f);
}

static const char *site_func(const rv_sitemap_t *m, uint32_t pc, int core)
{
	const rv_site_t *s = rv_sitemap_find(m, pc, core);
	return s ? s->func : "?";
}

/* THE RUNTIME-PREFERENCE RULE
 *
 * A sync event can reach the stream twice: as an ACT-ST record whose tag was
 * fixed when the watchpoint table was LOADED, and as an ACT-CAP record whose
 * tag the program computed at RUN time. When both exist they can disagree --
 * that is not a bug, it is the wrong-lock scenario's whole mechanism: the
 * static tag says "lock 0" because the table cannot know a lock the mode
 * chose at run time.
 *
 * So whenever the stream contains ANY runtime sync events, the lock-state
 * tracking of every monitor uses ONLY those, and the static sync tags are
 * kept for display but ignored for state. Mixing the two would be worse
 * than either alone: the mis-labelled static events would poison the very
 * state the runtime events got right (measured -- the phantom-conflict
 * episode in this file's history came from exactly that kind of poisoning).
 * Streams without ACT-CAP (EN_ACTCAP=0 builds) fall back to the static tags
 * and lose only what those cannot express. */
static int stream_has_runtime_sync(const rv_rec_t *r, size_t n)
{
	size_t i;
	for (i = 0; i < n; i++) {
		rv_tag_t t;
		rv_tag_decode(r[i].tag, &t);
		if (t.kind == RV_K_SYNC && t.from_actcap) return 1;
	}
	return 0;
}

/* Decode a record's tag for lock-state purposes.
 *
 * REVISED after the first full round: state comes from the STATIC sync
 * records only. The runtime (ACT-CAP) records carry the true lock identity,
 * but they travel a SHORTER pipeline than the ACT-ST records (which pass the
 * ~40-cycle watchpoint search tree), so in the stream they OVERTAKE the data
 * accesses that retired before them -- and a happens-before monitor fed with
 * out-of-order releases reports phantom conflicts on correct code (measured:
 * 8 of them on M0). The fix is the pairing pre-pass in rvmon.c: it grafts
 * each runtime record's lock id onto its static twin (same core, same op,
 * program order) and then RETIRES the runtime record from state duty. So
 * here: identity from the runtime path, POSITION from the static path, and
 * this function only has to insist on static records. */
static int sync_for_state(const rv_rec_t *rec, int runtime_sync, rv_tag_t *t)
{
	(void)runtime_sync;
	rv_tag_decode(rec->tag, t);
	if (t->kind != RV_K_SYNC) return 0;
	if (t->from_actcap) return 0;       /* runtime records: identity donors only */
	return 1;
}

/* ===================================================================== */
/* mon_cfg -- the checkpoint sequence against the program's own plan       */
/* ===================================================================== */
/* The dispatch order is a fixed LCG over the function table, so the host can
 * REPLAY it and knows which function each iteration should enter. A
 * mismatch means the indirect call landed somewhere the call site never
 * legitimately reaches: a forward-edge CFI violation, detectable even though
 * nothing crashed and no memory was corrupted.
 *
 * Note what this does NOT need: a disassembly-derived CFG. The expected
 * control flow of this program is a formula, and comparing against a formula
 * is both cheaper and sharper. */
static unsigned lcg_next(unsigned *s)
{
	*s = (*s * 1664525u) + 1013904223u;
	return *s;
}

static int func_number(const char *name)
{
	/* "rv_tNNN" -> NNN */
	if (strncmp(name, "rv_t", 4) != 0) return -1;
	return atoi(name + 4);
}

unsigned rv_cfg_seed = 0x1234u;      /* set from the shared control area */
unsigned rv_cfg_nfuncs = 100u;

static void mon_cfg(const rv_rec_t *r, size_t n, const rv_sitemap_t *map,
                    rv_findings_t *out)
{
	unsigned seed[RV_MAX_CORES];
	unsigned iter[RV_MAX_CORES];
	int reported = 0;
	size_t i;

	for (i = 0; i < RV_MAX_CORES; i++) {
		seed[i] = rv_cfg_seed + (unsigned)i;
		iter[i] = 0;
	}

	for (i = 0; i < n; i++) {
		rv_tag_t t;
		const rv_site_t *s;
		int observed, expected;
		unsigned c = r[i].core & 1u;

		rv_tag_decode(r[i].tag, &t);
		if (t.kind != RV_K_MARKER || t.marker != 1u /* enter */)
			continue;

		s = rv_sitemap_find(map, r[i].pc, (int)c);
		if (!s)
			continue;
		observed = func_number(s->func);
		expected = (int)(lcg_next(&seed[c]) % rv_cfg_nfuncs);
		iter[c]++;

		if (observed >= 0 && observed != expected && reported < 8) {
			add(out, "mon_cfg", "cfi-forward-edge", &r[i], NULL,
			    "core %u iteration %u: indirect call entered %s (function %d) "
			    "but the dispatch sequence says function %d -- control arrived "
			    "at a target this call site never legitimately reaches",
			    c, iter[c] - 1u, s->func, observed, expected);
			reported++;
			/* resynchronise so one corrupted index does not report the
			 * whole rest of the run */
			seed[c] = seed[c];
		}
	}
}

/* ===================================================================== */
/* mon_proto -- was every shared access inside a critical section?         */
/* ===================================================================== */
static void mon_proto(const rv_rec_t *r, size_t n, const rv_sitemap_t *map,
                      rv_findings_t *out)
{
	unsigned held[RV_MAX_CORES];          /* bitmask of locks held */
	uint32_t worst_pc[RV_MAX_CORES];
	unsigned unprot[RV_MAX_CORES];
	size_t   first_idx[RV_MAX_CORES];
	size_t   i;

	memset(held, 0, sizeof held);
	memset(unprot, 0, sizeof unprot);
	memset(worst_pc, 0, sizeof worst_pc);
	for (i = 0; i < RV_MAX_CORES; i++) first_idx[i] = (size_t)-1;

	{
	int runtime_sync = stream_has_runtime_sync(r, n);
	for (i = 0; i < n; i++) {
		rv_tag_t t;
		unsigned c = r[i].core & 1u;
		rv_tag_decode(r[i].tag, &t);

		if (t.kind == RV_K_SYNC) {
			if (!sync_for_state(&r[i], runtime_sync, &t))
				continue;                    /* display-only static tag */
			if (t.op == 1u /* acq_ok */) {
				held[c] |= (1u << (t.lock & (RV_MAX_LOCKS - 1)));
			} else if (t.op == 2u /* release */) {
				held[c] &= ~(1u << (t.lock & (RV_MAX_LOCKS - 1)));
			} else if (t.op == 0u /* acq_try */ && (held[c] & (1u << (t.lock & 7)))) {
				add(out, "mon_proto", "double-acquire", &r[i], NULL,
				    "core %u re-acquires lock %u it already holds (%s)",
				    c, t.lock, site_func(map, r[i].pc, (int)c));
			}
			continue;
		}
		if (t.kind == RV_K_DATA && obj_is_shared(t.obj) && held[c] == 0u) {
			if (first_idx[c] == (size_t)-1) {
				first_idx[c] = i;
				worst_pc[c] = r[i].pc;
			}
			unprot[c]++;
		}
	}
	}

	for (i = 0; i < RV_MAX_CORES; i++) {
		if (unprot[i]) {
			const rv_rec_t *fr = &r[first_idx[i]];
			add(out, "mon_proto", "access-without-lock", fr, NULL,
			    "core %zu made %u accesses to a shared object while holding no "
			    "lock; first at %s (pc 0x%08X)",
			    i, unprot[i], site_func(map, worst_pc[i], (int)i), worst_pc[i]);
		}
	}
}

/* ===================================================================== */
/* mon_lockset -- Eraser                                                   */
/* ===================================================================== */
/* Per object, the candidate set starts as "every lock" and is intersected
 * with the set actually held at each access. If it empties and at least one
 * access was a write, no lock consistently protects the object.
 *
 * This is the monitor that finds RV_MODE_RACE_WRONG_LOCK: both cores hold a
 * lock at every access, so nothing ever looks unprotected and the accesses
 * need never overlap -- but the intersection across cores is empty, and that
 * is exactly the defect. */
static void mon_lockset(const rv_rec_t *r, size_t n, const rv_sitemap_t *map,
                        rv_findings_t *out)
{
	unsigned held[RV_MAX_CORES];
	unsigned cand[RV_MAX_OBJS];
	int      seen[RV_MAX_OBJS], wrote[RV_MAX_OBJS], cores[RV_MAX_OBJS];
	size_t   first[RV_MAX_OBJS], second[RV_MAX_OBJS];
	size_t   i;
	unsigned o;

	memset(held, 0, sizeof held);
	memset(seen, 0, sizeof seen);
	memset(wrote, 0, sizeof wrote);
	memset(cores, 0, sizeof cores);
	int runtime_sync = stream_has_runtime_sync(r, n);
	for (o = 0; o < RV_MAX_OBJS; o++) {
		cand[o] = 0xFFFFFFFFu;
		first[o] = second[o] = (size_t)-1;
	}

	for (i = 0; i < n; i++) {
		rv_tag_t t;
		unsigned c = r[i].core & 1u;
		rv_tag_decode(r[i].tag, &t);

		if (t.kind == RV_K_SYNC) {
			if (!sync_for_state(&r[i], runtime_sync, &t))
				continue;
			if (t.op == 1u) held[c] |= (1u << (t.lock & 7));
			else if (t.op == 2u) held[c] &= ~(1u << (t.lock & 7));
			continue;
		}
		if (t.kind != RV_K_DATA || !obj_is_shared(t.obj))
			continue;
		o = t.obj % RV_MAX_OBJS;
		cand[o] &= held[c];
		seen[o] = 1;
		if (t.is_write) wrote[o] = 1;
		cores[o] |= (1 << c);
		if (first[o] == (size_t)-1) first[o] = i;
		else if (r[first[o]].core != r[i].core && second[o] == (size_t)-1) second[o] = i;
	}

	for (o = 0; o < RV_MAX_OBJS; o++) {
		if (!seen[o] || cand[o] != 0u) continue;
		if (!wrote[o]) continue;             /* read-only sharing is fine */
		if (cores[o] != 0x3) continue;       /* only one core touched it */
		{
			const rv_rec_t *a = (first[o] != (size_t)-1) ? &r[first[o]] : NULL;
			const rv_rec_t *b = (second[o] != (size_t)-1) ? &r[second[o]] : NULL;
			add(out, "mon_lockset", "data-race", a, b,
			    "object '%s' is written from both cores and NO lock is held "
			    "consistently across all of its accesses (lockset empty); "
			    "first core-%d access at %s, first core-%d access at %s",
			    rv_obj_name(o), a ? a->core : -1,
			    a ? site_func(map, a->pc, a->core) : "?",
			    b ? b->core : -1,
			    b ? site_func(map, b->pc, b->core) : "?");
		}
	}
}

/* ===================================================================== */
/* mon_hb -- happens-before over two threads                               */
/* ===================================================================== */
/* Two conflicting accesses are a race only if nothing ORDERS them. Locks
 * order them: a release on one core happens-before the next acquire of the
 * same lock on the other. With two threads a vector clock is two counters,
 * so this is small -- and it is the monitor that keeps the demo honest when
 * timestamps happen to be close but the accesses were properly ordered. */
static void mon_hb(const rv_rec_t *r, size_t n, const rv_sitemap_t *map,
                   rv_findings_t *out)
{
	unsigned vc[RV_MAX_CORES][RV_MAX_CORES];   /* vc[core] = its vector clock */
	unsigned rel[RV_MAX_LOCKS][RV_MAX_CORES];  /* clock published at release */
	/* last write per object, with the writer's clock at that moment */
	struct { int valid, core; unsigned clk[RV_MAX_CORES]; size_t idx; } lastw[RV_MAX_OBJS];
	size_t i;
	int reported = 0;

	int runtime_sync = stream_has_runtime_sync(r, n);
	memset(vc, 0, sizeof vc);
	memset(rel, 0, sizeof rel);
	memset(lastw, 0, sizeof lastw);

	for (i = 0; i < n; i++) {
		rv_tag_t t;
		unsigned c = r[i].core & 1u, o, k;
		rv_tag_decode(r[i].tag, &t);
		vc[c][c]++;                              /* local tick per event */

		if (t.kind == RV_K_SYNC) {
			if (!sync_for_state(&r[i], runtime_sync, &t))
				continue;
			k = t.lock & (RV_MAX_LOCKS - 1);
			if (t.op == 2u) {                    /* release: publish */
				for (o = 0; o < RV_MAX_CORES; o++) rel[k][o] = vc[c][o];
			} else if (t.op == 1u) {             /* acquire: absorb */
				for (o = 0; o < RV_MAX_CORES; o++)
					if (rel[k][o] > vc[c][o]) vc[c][o] = rel[k][o];
			}
			continue;
		}
		if (t.kind != RV_K_DATA || !obj_is_shared(t.obj))
			continue;
		o = t.obj % RV_MAX_OBJS;

		if (lastw[o].valid && lastw[o].core != (int)c) {
			/* ordered iff this core's clock already covers the writer's */
			unsigned wcore = (unsigned)lastw[o].core;
			int ordered = (vc[c][wcore] >= lastw[o].clk[wcore]);
			if (!ordered && reported < 8) {
				add(out, "mon_hb", "unordered-conflict", &r[lastw[o].idx], &r[i],
				    "conflicting accesses to '%s' are NOT ordered by any lock: "
				    "core %d wrote at %s, core %u %s at %s, time delta %llu",
				    rv_obj_name(o), lastw[o].core,
				    site_func(map, r[lastw[o].idx].pc, lastw[o].core), c,
				    t.is_write ? "wrote" : "read", site_func(map, r[i].pc, (int)c),
				    (unsigned long long)(r[i].ts_unrolled - r[lastw[o].idx].ts_unrolled));
				reported++;
			}
		}
		if (t.is_write) {
			lastw[o].valid = 1;
			lastw[o].core = (int)c;
			lastw[o].idx = i;
			memcpy(lastw[o].clk, vc[c], sizeof vc[c]);
		}
	}
}

/* ===================================================================== */
/* mon_order -- lock acquisition order                                     */
/* ===================================================================== */
/* An edge A->B means some core held A while acquiring B. A cycle means the
 * two cores can wait on each other -- a deadlock that this run did not have
 * to demonstrate to be real. */
static void mon_order(const rv_rec_t *r, size_t n, const rv_sitemap_t *map,
                      rv_findings_t *out)
{
	unsigned held[RV_MAX_CORES];
	unsigned char edge[RV_MAX_LOCKS][RV_MAX_LOCKS];
	size_t idx_of_edge[RV_MAX_LOCKS][RV_MAX_LOCKS];
	unsigned a, b;
	size_t i;

	int runtime_sync = stream_has_runtime_sync(r, n);
	memset(held, 0, sizeof held);
	memset(edge, 0, sizeof edge);
	memset(idx_of_edge, 0, sizeof idx_of_edge);
	(void)map;

	for (i = 0; i < n; i++) {
		rv_tag_t t;
		unsigned c = r[i].core & 1u, k;
		if (!sync_for_state(&r[i], runtime_sync, &t))
			continue;
		k = t.lock & (RV_MAX_LOCKS - 1);
		if (t.op == 1u) {
			for (a = 0; a < RV_MAX_LOCKS; a++) {
				if (held[c] & (1u << a)) {
					if (!edge[a][k]) idx_of_edge[a][k] = i;
					edge[a][k] = 1;
				}
			}
			held[c] |= (1u << k);
		} else if (t.op == 2u) {
			held[c] &= ~(1u << k);
		}
	}

	for (a = 0; a < RV_MAX_LOCKS; a++) {
		for (b = 0; b < RV_MAX_LOCKS; b++) {
			if (a < b && edge[a][b] && edge[b][a]) {
				add(out, "mon_order", "lock-order-inversion",
				    &r[idx_of_edge[a][b]], &r[idx_of_edge[b][a]],
				    "locks %u and %u are acquired in BOTH orders (%u then %u, "
				    "and %u then %u) -- the two cores can wait on each other. "
				    "This run did not deadlock; the order graph says it could",
				    a, b, a, b, b, a);
			}
		}
	}
}

/* ===================================================================== */

const rv_monitor_t rv_monitors[] = {
	{ "mon_cfg",     "checkpoint sequence against the dispatch plan", mon_cfg },
	{ "mon_proto",   "every shared access inside a critical section", mon_proto },
	{ "mon_lockset", "a lock that consistently protects each object", mon_lockset },
	{ "mon_hb",      "conflicting accesses ordered by a lock",        mon_hb },
	{ "mon_order",   "both cores agree on lock ordering",             mon_order },
};
const size_t rv_monitor_count = sizeof rv_monitors / sizeof rv_monitors[0];
