/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * hello_trace — a small bare-metal RV32I(+Zicsr) C program for the TGC5B +
 * CEDARtools.TraceEncoder example SoC. It needs NO CEDARtools.TraceEncoder awareness: the testbench / sim.sh
 * acts as the trace host and enables the encoder over the config port before
 * the core starts, so any program linked at 0x0 can be traced unmodified.
 *
 * It runs a mix of control flow the N-Trace encoder must reproduce — linear
 * code, call/return, taken/not-taken branches, loads/stores — and takes two
 * asynchronous machine interrupts (INTERRUPT itype + mret interrupt-return):
 *
 *   - a software interrupt, raised by writing the CLINT msip register;
 *   - a timer interrupt: mtimecmp is armed to mtime + TIMER_DELAY, and when
 *     it fires the handler calls timer_tick() — a function invoked purely
 *     "after some time" rather than from program flow.
 *
 * The single mtvec handler dispatches on mcause. After main returns, crt0.S
 * parks in a halt loop (which the testbench detects to stop and flush).
 *
 * Verified by ct_soc_tb: the NexRv-decoded PC stream is checked against the
 * core's own uncompressed golden trace (core_trace_pc). See the example README.
 */

#include <stdint.h>

/* CLINT (PERIPH base 0x1000_0000; see rdl/ct_soc/ct_clint.rdl). */
#define CLINT_MSIP       (*(volatile uint32_t *)0x10000000u)
#define CLINT_MTIMECMPLO (*(volatile uint32_t *)0x10000004u)
#define CLINT_MTIMECMPHI (*(volatile uint32_t *)0x10000008u)
#define CLINT_MTIMELO    (*(volatile uint32_t *)0x1000000Cu)
#define CLINT_MTIMEHI    (*(volatile uint32_t *)0x10000010u)

#define SCRATCH          ((volatile uint32_t *)0x0000E000u)

#define MCAUSE_MSOFT     0x80000003u    /* machine software interrupt */
#define MCAUSE_MTIMER    0x80000007u    /* machine timer interrupt    */

#define TIMER_DELAY      2000u          /* clk ticks until the timer fires */

/* Zero-initialized by the crt0.S .bss-clear loop before main() runs. */
static volatile uint32_t sw_irq_seen;
static volatile uint32_t timer_seen;

/* mtime is 64-bit and free-runs from PL reset (on hardware it can be far past
 * 2^32 by the time the program starts), so read it with the standard
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

/* The function the timer interrupt invokes "after some time". */
static void __attribute__((noinline)) timer_tick(void)
{
	SCRATCH[3] = 0x71C0FFEEu;
	timer_seen = 1;
}

/* Leaf function: exercises CALL / RETURN plus taken branches ending in one
 * not-taken branch (the loop exit). */
static uint32_t __attribute__((noinline)) compute(uint32_t n)
{
	uint32_t acc = 7;
	for (uint32_t i = 0; i < n; i++)
		acc += i + 3;
	return acc;
}

/* Machine trap handler (single mtvec entry, direct mode): dispatch on mcause.
 * The interrupt attribute makes GCC save/restore every register the handler
 * (and its callees) may touch and return with mret (interrupt-return itype) —
 * the interrupts are asynchronous and must not corrupt the interrupted code. */
__attribute__((interrupt("machine")))
static void trap_handler(void)
{
	uint32_t cause;
	__asm__ volatile ("csrr %0, mcause" : "=r"(cause));

	if (cause == MCAUSE_MSOFT) {
		CLINT_MSIP  = 0;            /* deassert sw_irq */
		sw_irq_seen = 1;
	} else if (cause == MCAUSE_MTIMER) {
		mtimecmp_write(~0ull);      /* one-shot: disarm (deasserts tim_irq) */
		timer_tick();
	}
}

int main(void)
{
	/* Machine-interrupt setup (Zicsr): mtvec = trap_handler (direct mode),
	 * enable the machine software + timer interrupts (mie.MSIE/MTIE) and
	 * interrupts globally (mstatus.MIE). */
	__asm__ volatile ("csrw mtvec, %0"   :: "r"(trap_handler));
	__asm__ volatile ("csrs mie, %0"     :: "r"((1u << 3) | (1u << 7)));
	__asm__ volatile ("csrs mstatus, %0" :: "r"(1u << 3));

	SCRATCH[0] = compute(4);        /* call + return, stores            */
	SCRATCH[1] = SCRATCH[0] + 1;    /* load + store                     */

	/* Software interrupt: with msip = 1 the core traps to trap_handler
	 * within a few instructions — i.e. inside the wait loop below — the
	 * handler clears msip, and mret resumes the loop, which then reads
	 * sw_irq_seen = 1 and falls through. */
	CLINT_MSIP = 1;
	while (!sw_irq_seen)
		;

	/* Timer interrupt: arm mtimecmp TIMER_DELAY ticks ahead; the handler
	 * fires mid-wait-loop and calls timer_tick(). */
	mtimecmp_write(mtime_read() + TIMER_DELAY);
	while (!timer_seen)
		;

	SCRATCH[2] = compute(3);        /* second call + return             */
	return 0;
}
