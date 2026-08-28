/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * malloc_demo.c -- newlib malloc on a bare-metal TGC5B, every allocation
 * reported through ACT-CAP: id, requested size, the pointer that came back,
 * the caller, and each time the heap grows.
 *
 * WHY THIS EXISTS. The rvcfi programs are -nostdlib; this one links
 * newlib (nano) and gives it a heap with the one hook it needs, _sbrk().
 * Nothing about the SoC changes: the same private 64 KiB RAM, the same
 * doorbell, the same shim and FIFO. The point is to show what a *runtime*
 * value looks like in the record stream -- a pointer nobody knew before the
 * program ran -- next to the static things a watchpoint can carry.
 *
 * MEMORY MAP (private RAM, per core):
 *   0x0000 .. _end      code, rodata, data, bss (this image)
 *   _end   .. 0xD000    the heap, grown by _sbrk() on demand (~45 KiB)
 *   0xE000 .. 0xEFFF    scratch page (unused here, kept free as in rvcfi)
 *   0xF000              initial stack pointer, growing down
 *
 * PROTOCOL WITH THE HOST. Same as rvcfi's main.c so that `rvmon load/run`
 * and the e2e simulation bench work unchanged: wait for the host's magic,
 * wait at the start barrier, run, publish the result mailbox with the done
 * magic. mode / iters / pace are read but only `iters` is used (how many
 * times the allocation script repeats; 0 or 1 = once).
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "rv_shared.h"
#include "rv_tags.h"
#include "rv_console.h"
#include "md_cap.h"

#ifndef RV_CORE
#error "build with -DRV_CORE=0 or -DRV_CORE=1"
#endif
#define SH RV_SHARED

volatile uint32_t md_cap_issued;

/* ---- newlib glue --------------------------------------------------------
 * newlib's allocator asks for memory through _sbrk(); this is the whole
 * "operating system" it sees. The break starts at the end of the image and
 * may grow up to MD_HEAP_LIMIT; a request beyond that fails with ENOMEM and
 * malloc() returns NULL -- which the demo exercises deliberately at the end.
 */
extern char _end;
#define MD_HEAP_LIMIT 0xD000u

static char *md_brk;

void *_sbrk(int incr)
{
	char *prev;
	if (md_brk == 0) md_brk = &_end;
	prev = md_brk;
	if ((uintptr_t)md_brk + (uintptr_t)incr > MD_HEAP_LIMIT) {
		errno = ENOMEM;
		return (void *)-1;
	}
	md_brk += incr;
	MD_CAP(MD_F_SBRK, (uint32_t)(uintptr_t)md_brk);
	return prev;
}

/* ---- instrumented wrappers ------------------------------------------- */
#define MD_REG_SLOTS 32
static struct { void *p; uint32_t id; } md_reg[MD_REG_SLOTS];
static uint32_t md_next_id;

static void md_reg_add(void *p, uint32_t id)
{
	int i;
	for (i = 0; i < MD_REG_SLOTS; i++)
		if (md_reg[i].p == 0) { md_reg[i].p = p; md_reg[i].id = id; return; }
}

static uint32_t md_reg_take(void *p)
{
	int i;
	for (i = 0; i < MD_REG_SLOTS; i++)
		if (md_reg[i].p == p) { uint32_t id = md_reg[i].id; md_reg[i].p = 0; return id; }
	return 0u;
}

/* noinline so that __builtin_return_address(0) is the CALLER of md_malloc,
 * i.e. the address in the demo script that the pointer is returned to. */
static void * __attribute__((noinline)) md_malloc(size_t n)
{
	uint32_t caller = (uint32_t)(uintptr_t)__builtin_return_address(0);
	uint32_t id = ++md_next_id;
	void *p;

	MD_CAP(MD_F_MALLOC, id);
	MD_CAP(MD_F_SIZE, (uint32_t)n);
	p = malloc(n);                 /* SBRK records may land in here */
	MD_CAP(MD_F_PTR, (uint32_t)(uintptr_t)p);
	MD_CAP(MD_F_CALLER, caller);
	if (p) md_reg_add(p, id);
	return p;
}

static void __attribute__((noinline)) md_free(void *p)
{
	uint32_t caller = (uint32_t)(uintptr_t)__builtin_return_address(0);
	uint32_t id = md_reg_take(p);

	MD_CAP(MD_F_FREE, id);
	MD_CAP(MD_F_FREE_PTR, (uint32_t)(uintptr_t)p);
	MD_CAP(MD_F_FREE_CALLER, caller);
	free(p);
}

/* Touch what was allocated -- the first and the last bytes -- so the block
 * is really used without turning the demo into a memset benchmark: every
 * byte access costs about ten cycles on this dBus, and a record-free stretch
 * of a few thousand cycles is what the e2e bench (and rvmon) read as "the
 * cores have finished". A 4 KiB fill would be ~90 000 silent cycles. */
#define MD_TOUCH 32u
static uint32_t __attribute__((noinline)) md_use(void *p, size_t n, uint32_t seed)
{
	uint8_t *b = (uint8_t *)p;
	uint32_t sum = 0;
	size_t i, k = (n < 2u * MD_TOUCH) ? n : MD_TOUCH;
	if (!p) return 0;
	for (i = 0; i < k; i++) b[i] = (uint8_t)(seed + i);
	for (i = 0; i < k; i++) b[n - 1u - i] = (uint8_t)(seed - i);
	for (i = 0; i < k; i++) sum += b[i] + b[n - 1u - i];
	return sum;
}

/* ---- console (uninstrumented, see rv_console.h) ----------------------- */
static void md_put_hex(uint32_t v)
{
	static const char hx[] = "0123456789abcdef";
	int i;
	for (i = 28; i >= 0; i -= 4) rv_putc(hx[(v >> i) & 0xFu]);
}

static void md_put_dec(uint32_t v)
{
	char buf[11];
	int n = 0;
	if (v == 0) { rv_putc('0'); return; }
	while (v) { buf[n++] = (char)('0' + v % 10u); v /= 10u; }
	while (n) rv_putc(buf[--n]);
}

/* ---- the allocation script ------------------------------------------- */
static uint32_t md_script(uint32_t seed)
{
	void *a, *b, *c, *d, *e, *f, *big;
	void *blk[8];
	uint32_t sum = 0;
	int i;

	a = md_malloc(24);            sum += md_use(a, 24, seed);
	b = md_malloc(100);           sum += md_use(b, 100, seed);
	c = md_malloc(512);           sum += md_use(c, 512, seed);
	md_free(b);                   /* leaves a 100-byte hole between a and c */
	d = md_malloc(64);            sum += md_use(d, 64, seed);   /* first fit: lands in the hole */
	e = md_malloc(4096);          sum += md_use(e, 4096, seed);

	for (i = 0; i < 8; i++) {     /* a ramp of small blocks */
		blk[i] = md_malloc(32u + 16u * (uint32_t)i + 8u * (uint32_t)RV_CORE);
		sum += md_use(blk[i], 32u + 16u * (uint32_t)i, seed + (uint32_t)i);
	}
	for (i = 7; i >= 0; i--) md_free(blk[i]);

	md_free(a); md_free(c); md_free(d); md_free(e);
	f = md_malloc(2000);          sum += md_use(f, 2000, seed);   /* after coalescing */
	md_free(f);

	big = md_malloc(60000);       /* deliberately beyond the heap limit: PTR = 0 */
	if (big) md_free(big);

	return sum;
}

int main(void)
{
	unsigned iters, i;
	uint32_t sum = 0;

	while (SH->magic != RV_MAGIC) { /* uninstrumented spin */ }

	iters = SH->iters;
	if (iters == 0u) iters = 1u;
	if (iters > 8u)  iters = 8u;          /* the registry and the FIFO are small */

	SH->result[RV_CORE].done       = 0u;
	SH->result[RV_CORE].iters_done = 0u;
	md_cap_issued = 0u;
	md_next_id    = 0u;
	memset(md_reg, 0, sizeof md_reg);

	while (SH->go == 0u) { /* start barrier */ }

	/* Same console handshake as the rvcfi programs: greet, echo the RX. */
	rv_puts("hello core ");
	rv_putc((char)('0' + RV_CORE));
	rv_putc('\n');
	{
		int ch;
		while ((ch = rv_getc()) >= 0) rv_putc((char)ch);
	}

	for (i = 0; i < iters; i++) {
		sum += md_script(0x5Au + (uint32_t)RV_CORE + i);
		SH->result[RV_CORE].iters_done = i + 1u;
	}

	SH->result[RV_CORE].local_sum     = sum;
	SH->result[RV_CORE].local_count   = md_next_id;         /* allocations made */
	SH->result[RV_CORE].acct_snapshot = (uint32_t)(uintptr_t)md_brk;   /* final heap top */
	SH->result[RV_CORE].actcap_issued = md_cap_issued;
	SH->result[RV_CORE].done          = RV_DONE_MAGIC;

	rv_puts("malloc demo: ");   md_put_dec(md_next_id);
	rv_puts(" allocations, ");  md_put_dec(md_cap_issued);
	rv_puts(" ACT-CAP records, heap top 0x"); md_put_hex((uint32_t)(uintptr_t)md_brk);
	rv_putc('\n');
	return 0;                             /* crt0 parks in its halt loop */
}
