/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * rv_console.h -- the core side of the per-core character channel.
 *
 * The hardware is ct_soc_console (TX and RX FIFO behind three registers at
 * 0x4000_0100, next to the ACT-CAP doorbell). This header is the whole
 * "driver": a blocking putchar, a non-blocking getchar, and nothing else.
 *
 * Two properties matter for the demo:
 *
 *   - `rv_putc` spins on TX free space, and the spin is UNINSTRUMENTED like
 *     every other spin here (no labelled site, no doorbell), so console
 *     traffic never appears in the record stream it would otherwise distort.
 *   - Console I/O is plain `lw`/`sw` on a private segment -- it touches
 *     neither the shared memory nor the watchpointed objects, so printing
 *     does not perturb the race analysis (beyond the cycles it costs, which
 *     is why the demo prints around the measured region, not inside it).
 */

#ifndef RV_CONSOLE_H
#define RV_CONSOLE_H

#define RV_CON_BASE 0x40000100u
#define RV_CON ((volatile unsigned *)RV_CON_BASE)
/*  RV_CON[0]  W: push char / R: TX free space
 *  RV_CON[1]  R: RX count
 *  RV_CON[2]  R: RX pop -- bit 31 valid, [7:0] char (FWFT)
 *  RV_CON[3]  R: TX drops (writes into a full TX are counted, never silent)
 */

static inline void rv_putc(char c)
{
	while (RV_CON[0] == 0u) {
		/* uninstrumented spin -- see header */
	}
	RV_CON[0] = (unsigned char)c;
}

static inline void rv_puts(const char *s)
{
	while (*s) rv_putc(*s++);
}

/* Non-blocking: -1 if nothing is waiting. */
static inline int rv_getc(void)
{
	unsigned v = RV_CON[2];
	return (v & 0x80000000u) ? (int)(v & 0xFFu) : -1;
}

static inline unsigned rv_rx_count(void)
{
	return RV_CON[1];
}

#endif /* RV_CONSOLE_H */
