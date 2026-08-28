/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Minimal startup for rvcfi_demo, after the common/tgc5b prog/ pattern:
 * the core resets to 0x0, so this stub (placed first via .text.start) sets
 * up a stack, zeroes .bss, calls main, and parks in a halt loop — which a
 * simulation testbench detects (stable PC) to stop tracing and flush. On
 * the board main() never returns when the endless switch is set (see
 * main.c: the run ends after CTRL.iters transactions).
 */

	.section .text.start
	.globl _start

_start:
	li    sp, 0x0000F000             /* stack near top of 64 KiB RAM */

	/* Zero .bss: the flat image carries no .bss, and on hardware the RAM
	 * keeps its previous content across runs — without this, globals start
	 * with stale values. */
	la    t0, __bss_start
	la    t1, __bss_end
1:	bgeu  t0, t1, 2f
	sw    zero, 0(t0)
	addi  t0, t0, 4
	j     1b

2:	call  main

halt:
	j     halt                       /* park — testbench stops on the stable PC */
