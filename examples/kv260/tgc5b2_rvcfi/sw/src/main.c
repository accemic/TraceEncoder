/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * main.c -- the driver both cores run. One source, two builds
 * (-DRV_CORE=0 producer, -DRV_CORE=1 consumer).
 *
 * THE DETERMINISM CONTRACT
 * ------------------------
 * A race detector can only be judged against an expectation, and an
 * expectation only exists if the run is reproducible. So:
 *
 *   - the sequence of transactions is a fixed LCG over the dispatch table,
 *     seeded from shared memory: the same seed gives the same sequence of
 *     CALL SITES on every run, on hardware and in simulation;
 *   - what varies between runs is only the INTERLEAVING of the two cores,
 *     which is precisely the thing under study;
 *   - no timer interrupt drives the workload. The pacing loop is plain
 *     instructions, so pacing changes the RATE without changing the
 *     sequence -- which is what lets the same expectation hold for a
 *     throttled run and a full-speed burst.
 *
 * THE PACING LOOP IS NOT DECORATION
 * ---------------------------------
 * Unthrottled, the two cores generate roughly half a million watchpoint
 * records per second EACH, and the host drains far fewer. Records would be
 * dropped, and a race detector on a sampled stream reports fiction. So the
 * host sets `pace_div` from the drain rate it measured, and `rvmon` refuses
 * a verdict if the shims dropped anything. See the tutorial's throughput
 * chapter -- this is the demo's one real operating limit.
 */

#include "rv_shared.h"
#include "rv_tags.h"
#include "rv_site.h"
#include "rv_funcs.h"
#include "rv_console.h"

#ifndef RV_CORE
#error "build with -DRV_CORE=0 (producer) or -DRV_CORE=1 (consumer)"
#endif

#define SH RV_SHARED

/* Deterministic dispatch order. Numerical Recipes LCG -- small, no
 * multiplier table, and the same on host and target. */
static unsigned lcg(unsigned *s)
{
	*s = (*s * 1664525u) + 1013904223u;
	return *s;
}

static void pace(unsigned n)
{
	volatile unsigned i;
	for (i = 0; i < n; i++) {
		/* plain instructions: no memory traffic, so pacing does not add
		 * instrumentation events of its own */
		__asm__ __volatile__("" ::: "memory");
	}
}

int main(void)
{
	unsigned seed, iters, mode, pace_div, cfi_off, cap_every;
	unsigned i, idx;

	/* Wait for the host to publish a valid control area. URAM comes up with
	 * whatever the previous run left, so "looks plausible" is not enough --
	 * the magic is the only thing that says the host has been here. */
	while (SH->magic != RV_MAGIC) {
		/* uninstrumented spin */
	}

	mode     = SH->mode;
	iters    = SH->iters;
	pace_div = SH->pace_div;
	seed     = SH->seed + (unsigned)RV_CORE;   /* different order per core */
	cfi_off  = SH->cfi_off;
	cap_every = SH->cap_every;

	SH->result[RV_CORE].done       = 0u;
	SH->result[RV_CORE].iters_done = 0u;
	rv_local_sum    = 0u;
	rv_private      = 0u;
	rv_actcap_issued = 0u;

	/* Start barrier: both cores are released by separate CONTROL bits and
	 * therefore at slightly different times. Without this they would not
	 * overlap at the start, and the first transactions -- the ones a short
	 * burst capture actually contains -- would never contend. */
	while (SH->go == 0u) {
		/* uninstrumented spin */
	}

	/* Console proof, both directions: announce ourselves, then echo whatever
	 * the host queued into RX before the run. The end-to-end bench pushes
	 * "PING" and expects it back -- with that, one run demonstrates the whole
	 * channel without any interactive step. Console I/O is uninstrumented
	 * (see rv_console.h), so none of this appears in the record stream. */
	rv_puts("hello core ");
	rv_putc((char)('0' + RV_CORE));
	rv_putc('\n');
	{
		int ch;
		while ((ch = rv_getc()) >= 0) {
			rv_putc((char)ch);
		}
	}

	for (i = 0; i < iters; i++) {
		idx = lcg(&seed) % RV_N_FUNCS;

		/* RV_MODE_CFI_SKIP: corrupt the dispatch index once, midway. The
		 * call goes through a function-pointer table, so this is a genuine
		 * forward-edge CFI violation: control arrives at a target the call
		 * site never legitimately reaches, and the checkpoint sequence says
		 * so even though no memory is corrupted and nothing crashes. */
		if (mode == RV_MODE_CFI_SKIP && i == (iters / 2u)) {
			idx = (idx + cfi_off) % RV_N_FUNCS;
		}

		rv_table[idx]();

		/* Software instrumentation with a runtime payload, spread across
		 * the run rather than clustered at the start. */
		if (cap_every != 0u && (i % cap_every) == 0u && (idx % 4u) == 0u) {
			rv_cap_table[(idx / 4u) % RV_N_CAP]();
		}

		/* RV_MODE_LOCK_ORDER: take two locks in opposite order per core.
		 * No deadlock is provoked here -- the point is that the ORDER GRAPH
		 * is cyclic, which a runtime monitor can see in a run that happened
		 * to go well. That is the whole idea of runtime verification. */
		if (mode == RV_MODE_LOCK_ORDER) {
			rv_lock_order();
		}

		SH->result[RV_CORE].iters_done = i + 1u;
		pace(pace_div);
	}

	SH->result[RV_CORE].local_sum     = rv_local_sum;
	SH->result[RV_CORE].local_count   = iters;
	SH->result[RV_CORE].acct_snapshot = SH->balance;
	SH->result[RV_CORE].actcap_issued = rv_actcap_issued;
	SH->result[RV_CORE].done          = RV_DONE_MAGIC;

	return 0;   /* crt0 parks in a halt loop: a stable PC the bench detects */
}
