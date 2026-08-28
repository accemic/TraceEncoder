/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * rv_shared.h -- layout of the shared memory block, and the demo's control
 * interface between the host and the two cores.
 *
 * ONE definition, THREE readers: the two RISC-V programs, the site
 * generator, and the host analyser `rvmon`. That is deliberate. A layout
 * mirrored in three places drifts, and the drift shows up as a "race" in
 * exactly the object whose offset moved -- which is the most expensive kind
 * of bug this demo could have, because it looks like a success.
 *
 * Addresses:
 *   core side  0x3000_0000  (identical view from BOTH cores)
 *   PS side    0xA004_0000  (only while BOTH cores are held, see the SoC top)
 *
 * The block lives in UltraRAM and therefore has NO bitstream initialization:
 * every field is whatever the previous run left there until the host writes
 * it. `rvmon load` writes the whole control area and reads it back.
 */

#ifndef RV_SHARED_H
#define RV_SHARED_H

#ifndef RV_NO_STDINT
#include <stdint.h>
#endif

#define RV_SHARED_BASE_CORE   0x30000000u
#define RV_ACTCAP_DOORBELL    0x40000000u   /* one store here = one ACT-CAP command */

#define RV_MAGIC              0x52565348u   /* "RVSH" -- host wrote the control area */
#define RV_DONE_MAGIC         0x0E0DDA7Au   /* a core finished its run */

/* Modes. The WP table does NOT depend on the mode: every site exists in
 * every mode, some simply do not execute. That keeps one table valid for
 * all five runs, which is what makes the comparison between them honest. */
#define RV_MODE_SAFE            0u   /* correct locking -- the detector must find NOTHING */
#define RV_MODE_RACE_OPEN       1u   /* no lock around the account update */
#define RV_MODE_RACE_WRONG_LOCK 2u   /* both lock, but DIFFERENT locks */
#define RV_MODE_LOCK_ORDER      3u   /* two locks, opposite order (no deadlock in this run) */
#define RV_MODE_CFI_SKIP        4u   /* corrupted dispatch index -- forward-edge CFI violation */

#define RV_N_LOCKS            4u
#define RV_RING_SLOTS         60u

/* Peterson's algorithm, two participants. The TGC5B is RV32I: no atomics,
 * so mutual exclusion is software, and that is a feature here -- the lock is
 * visible in the source and one deleted line turns it into a race. */
typedef struct {
	volatile uint32_t flag[2];   /* +0x0, +0x4  -- ADJACENT, which is why the */
	volatile uint32_t turn;      /* +0x8           shared memory stores one word */
	volatile uint32_t pad;       /* +0xC           per URAM address, see its header */
} rv_lock_t;

typedef struct {
	/* -- control, written by the host before the cores are released ------ */
	volatile uint32_t magic;      /* 0x000 RV_MAGIC */
	volatile uint32_t mode;       /* 0x004 RV_MODE_* */
	volatile uint32_t iters;      /* 0x008 transactions per core */
	volatile uint32_t pace_div;   /* 0x00C delay iterations between transactions */
	volatile uint32_t go;         /* 0x010 start barrier: cores spin until != 0 */
	volatile uint32_t seed;       /* 0x014 dispatch sequence seed */
	volatile uint32_t cfi_off;    /* 0x018 RV_MODE_CFI_SKIP: dispatch index offset */
	volatile uint32_t cap_every;  /* 0x01C ACT-CAP block every Nth iteration;
	                               *       0 = software instrumentation OFF.
	                               *       The demo measures the probe effect
	                               *       by running the SAME binary with and
	                               *       without it. */

	/* -- synchronization ------------------------------------------------- */
	rv_lock_t         lock[RV_N_LOCKS];   /* 0x020 .. 0x05F */

	/* -- the contended object -------------------------------------------- */
	volatile uint32_t balance;    /* 0x060 read-modify-write from both cores */
	volatile uint32_t count;      /* 0x064 */
	volatile uint32_t checksum;   /* 0x068 */
	volatile uint32_t seq;        /* 0x06C */
	volatile uint32_t rsv1[4];    /* 0x070 .. 0x07F */

	/* -- SPSC ring: the loose coupling, and the CONTRAST class ------------ */
	/* Correct by construction (one producer, one consumer), so a detector
	 * that reports a race here is wrong -- which is exactly why it is in the
	 * demo next to an object that really does race. */
	volatile uint32_t ring_head;  /* 0x080 producer only */
	volatile uint32_t ring_tail;  /* 0x084 consumer only */
	volatile uint32_t ring_drops; /* 0x088 producer only */
	volatile uint32_t rsv2;       /* 0x08C */
	volatile uint32_t ring[RV_RING_SLOTS];  /* 0x090 .. 0x17F */

	/* -- per-core result mailbox, read by the host after the run ---------- */
	struct {
		volatile uint32_t done;        /* RV_DONE_MAGIC when finished */
		volatile uint32_t iters_done;
		volatile uint32_t local_sum;   /* what this core added to balance */
		volatile uint32_t local_count;
		volatile uint32_t acct_snapshot;
		volatile uint32_t actcap_issued; /* doorbell stores this core issued */
		volatile uint32_t rsv[2];
	} result[2];                  /* 0x180 .. 0x1BF */
} rv_shared_t;

/* Compile-time layout guard. If a field moves, this fails at build time
 * instead of at analysis time -- see the note at the top about drift. */
#ifndef RV_NO_LAYOUT_ASSERT
#define RV_LAYOUT_ASSERT(cond, name) \
	typedef char rv_layout_##name[(cond) ? 1 : -1]
RV_LAYOUT_ASSERT(sizeof(rv_lock_t) == 16, lock_size);
RV_LAYOUT_ASSERT(__builtin_offsetof(rv_shared_t, lock)      == 0x020, lock_at);
RV_LAYOUT_ASSERT(__builtin_offsetof(rv_shared_t, balance)   == 0x060, balance_at);
RV_LAYOUT_ASSERT(__builtin_offsetof(rv_shared_t, ring_head) == 0x080, ring_at);
RV_LAYOUT_ASSERT(__builtin_offsetof(rv_shared_t, ring)      == 0x090, ringslots_at);
RV_LAYOUT_ASSERT(__builtin_offsetof(rv_shared_t, result)    == 0x180, result_at);
#endif

#define RV_SHARED ((rv_shared_t *)RV_SHARED_BASE_CORE)

#endif /* RV_SHARED_H */
