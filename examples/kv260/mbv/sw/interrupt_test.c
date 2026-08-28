/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * interrupt_test.c -- external interrupt + handler + mret.
 *
 * IMPORTANT (SoC-dependent): a *real* external machine interrupt needs an
 * interrupt source in the SoC (AXI-INTC / GPIO / timer) wired to the
 * MicroBlaze-V `Interrupt` port -- see ../rtl/mbv_soc_top.sv's CONTROL b3 HW
 * IRQ pulse generator, which is what this example's board flow uses to
 * inject one deterministically. This file fully sets up the *core-side*
 * preparation (mtvec via crt0, mie.MEIE, mstatus.MIE) and overrides the weak
 * `mei_handler` hook.
 *
 * Measurement purpose: the coupling "interrupt attributed to the preceding
 * instruction" (iretire=1, itype=INTERRUPT) vs. a faulting representation.
 * This program supplies the deterministic foreground/background code against
 * which the TRACE-bus semantics are measured.
 */

#define CSR_MSTATUS 0x300
#define CSR_MIE     0x304
#define MSTATUS_MIE (1u << 3)       /* global interrupt enable (M-mode) */
#define MIE_MEIE    (1u << 11)      /* machine external interrupt enable */

static inline void csr_set(int csr, unsigned mask)
{
	/* csrrs x0, csr, mask -- without GCC CSR intrinsics, portable */
	switch (csr) {
	case CSR_MSTATUS: __asm__ volatile("csrs mstatus, %0" :: "r"(mask)); break;
	case CSR_MIE:     __asm__ volatile("csrs mie, %0"     :: "r"(mask)); break;
	default: break;
	}
}

volatile unsigned g_irq_count;      /* incremented by the handler */
static volatile unsigned g_work;    /* foreground "payload" */

/* Overrides the weak crt0 default. Called from the trap handler when
 * mcause[31]=1. NOTE: this is where acknowledging the source belongs
 * (INTC-EOI / timer reload) once one is wired in, otherwise the interrupt
 * re-triggers immediately. For now just a counter. */
void mei_handler(void)
{
	g_irq_count++;
}

int main(void)
{
	g_irq_count = 0;
	g_work = 0;

	/* core-side interrupt enable. */
	csr_set(CSR_MIE, MIE_MEIE);
	csr_set(CSR_MSTATUS, MSTATUS_MIE);

	/* deterministic foreground code, running long enough for an injected
	 * external interrupt to arrive at a well-defined point. */
	for (unsigned i = 0; i < 200; i++) {
		g_work += (i ^ (i << 1));
		/* the injection would be triggered here, at a known i. */
	}

	/* the return value depends on g_irq_count, so the optimizer cannot
	 * discard anything. */
	return (int)(g_work + g_irq_count);
}
