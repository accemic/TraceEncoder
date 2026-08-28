/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * axis_wp_demo — deterministic, timer-IRQ-paced walk over ~300 generated
 * noinline functions (src/funcs.c, emitted by gen_program.py). Target: the
 * TGC5B example SoC (CLINT @ 0x1000_0000, RAM 64 KiB @ 0x0, machine mode),
 * after the common/tgc5b prog/ pattern.
 *
 * Determinism contract (CFI pre-stage — the watchpoint hit sequence must be
 * predictable from expected_walk.txt alone):
 *
 *   - the timer interrupt is ONLY a pacer: its handler re-arms mtimecmp and
 *     increments g_tick — it calls no walk function;
 *   - main waits for the next tick, then runs the next phase's sequence
 *     (walk_phases[phase % WALK_NUM_PHASES]) EXACTLY once. If a phase ever
 *     took longer than a timer period, phases simply run back-to-back —
 *     the ORDER of function entries never depends on IRQ timing.
 *
 * Run length (sim vs. board):
 *
 *   - default: WALK_TOTAL_PHASES phases (== WALK_NUM_PHASES, i.e. each
 *     generated phase once), then main returns and crt0.S parks in the
 *     halt loop (stable PC for a simulation testbench);
 *   - board, option 1 (memory cell): write a non-zero word to WALK_CTRL
 *     (address 0x0000E800, outside .bss/.data, below the stack guard) AFTER
 *     loading the image and BEFORE releasing the core — the walk then wraps
 *     around the phase table endlessly (sequence stays deterministic and
 *     periodic);
 *   - board, option 2 (compile switch): build with -DWALK_ENDLESS=1 to
 *     force the endless walk regardless of WALK_CTRL.
 */

#include <stdint.h>
#include "walk.h"

/* CLINT (PERIPH base 0x1000_0000; see common/tgc5b rdl/ct_soc/ct_clint.rdl). */
#define CLINT_MTIMECMPLO (*(volatile uint32_t *)0x10000004u)
#define CLINT_MTIMECMPHI (*(volatile uint32_t *)0x10000008u)
#define CLINT_MTIMELO    (*(volatile uint32_t *)0x1000000Cu)
#define CLINT_MTIMEHI    (*(volatile uint32_t *)0x10000010u)

#define MCAUSE_MTIMER    0x80000007u    /* machine timer interrupt */

/* Progress/debug scratch (same area the common/tgc5b program uses). */
#define SCRATCH          ((volatile uint32_t *)0x0000E000u)

/* Endless-walk control cell: NOT in .bss/.data (crt0 zeroes .bss, the image
 * load overwrites .data), 2 KiB below the stack top 0xF000 — the host pokes
 * it via devmem before releasing the core. */
#define WALK_CTRL        (*(volatile uint32_t *)0x0000E800u)

#ifndef TIMER_PERIOD
#define TIMER_PERIOD     2000u          /* clk ticks per walk phase (pacer) */
#endif

#ifndef WALK_TOTAL_PHASES
#define WALK_TOTAL_PHASES WALK_NUM_PHASES
#endif

/* Zero-initialized by the crt0.S .bss-clear loop before main() runs. */
static volatile uint32_t g_tick;        /* incremented by the timer IRQ */

/* mtime is 64-bit and free-runs from PL reset (on hardware it can be far
 * past 2^32 by the time the program starts), so read it with the standard
 * hi/lo/hi sequence. */
static uint64_t mtime_read(void)
{
	uint32_t hi, lo;
	do {
		hi = CLINT_MTIMEHI;
		lo = CLINT_MTIMELO;
	} while (hi != CLINT_MTIMEHI);
	return ((uint64_t)hi << 32) | lo;
}

/* Arm (or, with ~0, disarm) the timer: tim_irq asserts while mtime >=
 * mtimecmp, so write the high word to all-ones first to avoid a spurious
 * match between the two word writes. */
static void mtimecmp_write(uint64_t v)
{
	CLINT_MTIMECMPHI = 0xFFFFFFFFu;
	CLINT_MTIMECMPLO = (uint32_t)v;
	CLINT_MTIMECMPHI = (uint32_t)(v >> 32);
}

/* Machine trap handler (single mtvec entry, direct mode). Pacer only: no
 * walk function is ever called from interrupt context, so no watchpoint
 * address executes asynchronously (see the determinism contract above). */
__attribute__((interrupt("machine")))
static void trap_handler(void)
{
	uint32_t cause;
	__asm__ volatile ("csrr %0, mcause" : "=r"(cause));

	if (cause == MCAUSE_MTIMER) {
		mtimecmp_write(mtime_read() + TIMER_PERIOD);   /* periodic re-arm */
		g_tick++;
	}
}

int main(void)
{
	/* Machine-interrupt setup (Zicsr): mtvec = trap_handler (direct mode),
	 * enable the machine timer interrupt (mie.MTIE) and interrupts
	 * globally (mstatus.MIE). */
	__asm__ volatile ("csrw mtvec, %0"   :: "r"(trap_handler));
	__asm__ volatile ("csrs mie, %0"     :: "r"(1u << 7));
	__asm__ volatile ("csrs mstatus, %0" :: "r"(1u << 3));

	mtimecmp_write(mtime_read() + TIMER_PERIOD);

	for (uint32_t phase = 0; ; phase++) {
		if (phase >= WALK_TOTAL_PHASES) {
#ifndef WALK_ENDLESS
			if (WALK_CTRL == 0u)
				break;                 /* sim: park via crt0 halt loop */
#endif
		}
		while (g_tick <= phase)        /* wait for the pacer tick */
			;
		walk_phases[phase % WALK_NUM_PHASES]();
		SCRATCH[0] = phase + 1u;       /* progress marker for the host */
		SCRATCH[1] = g_acc;
	}

	mtimecmp_write(~0ull);             /* disarm before parking */
	SCRATCH[2] = 0x0E0DDA7Au;          /* end-of-walk marker */
	return 0;
}
