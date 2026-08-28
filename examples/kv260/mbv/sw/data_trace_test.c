/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * data_trace_test.c -- load/store stimulus.
 *
 * SCOPE: data trace is **not a program-flow MVP goal** -- this program is
 * offered as a stimulus for later data-trace work, not exercised by the
 * program-flow gates the other files in this directory target. A store is
 * derivable from the MicroBlaze-V `TRACE` bus
 * (Trace_Data_Write/_Address/_Byte_Enable/_Write_Value); load VALUES are
 * NOT directly available (Trace_New_Reg_Value is ambiguous for that
 * purpose). This file only supplies deterministic store/load traffic as a
 * future stimulus and as a measurement object for "is Trace_Data_*
 * retirement-cycle-aligned?".
 */

#define N 16
static volatile unsigned buf[N];    /* target for stores/loads (volatile -> real memory accesses) */

__attribute__((noinline)) static void fill(unsigned seed)
{
	for (int i = 0; i < N; i++)
		buf[i] = seed + (unsigned)(i * 7);   /* word stores (dsize=2 -> 4 bytes) */
}

__attribute__((noinline)) static unsigned checksum(void)
{
	unsigned s = 0;
	for (int i = 0; i < N; i++)
		s += buf[i];                          /* word loads */
	return s;
}

int main(void)
{
	/* mixed access sizes, for later dsize characterization */
	volatile unsigned char *bp = (volatile unsigned char *)buf;

	fill(0x1000);                             /* stores */
	bp[0] = 0xAA;                             /* byte store  (dsize=0) */
	*(volatile unsigned short *)&bp[4] = 0xBEEF; /* halfword store (dsize=1) */

	unsigned c = checksum();                  /* loads */
	return (int)c;
}
