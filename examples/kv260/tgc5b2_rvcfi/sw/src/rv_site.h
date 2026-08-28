/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * rv_site.h -- the instrumentation primitives, and the reason they are
 * inline assembly instead of plain C.
 *
 * WHY A LABEL ON THE INSTRUCTION, NOT NEXT TO IT
 * ----------------------------------------------
 * An ACT-ST watchpoint triggers on a RETIRED PROGRAM COUNTER. The table
 * therefore needs the address of one specific instruction, and the demo
 * needs to know which access that instruction performs. Writing
 *
 *     asm volatile("rvs_17:");        // label
 *     v = SH->balance;                // ... and hope the load lands here
 *
 * puts the label wherever the compiler happens to start the sequence -- very
 * possibly on an address computation that got hoisted out of the loop, so
 * the watchpoint would fire once instead of once per access, or not at all.
 * Nothing would error; the analysis would simply be built on the wrong
 * events.
 *
 * These macros emit the label and the access as ONE assembly instruction, so
 * the mapping site <-> instruction is exact by construction and
 * `check_consistency.py` can verify it against the disassembly rather than
 * trusting it.
 *
 * WHAT IS DELIBERATELY NOT INSTRUMENTED
 * -------------------------------------
 * Only labelled accesses are reported. The spin loop inside a lock acquire,
 * the stack traffic of the runtime and the IRQ path carry no labels, and
 * that is a design decision rather than an omission: a spin loop hits the
 * same address thousands of times per second and would drown the record
 * stream in exactly the situation that matters (contention). The monitors
 * are told about the boundary; see the tutorial's "what the trace does not
 * contain".
 */

#ifndef RV_SITE_H
#define RV_SITE_H

#include "rv_tags.h"

/* Concatenation helpers so `site` can be a macro argument. */
#define RV__CAT2(a, b) a##b
#define RV__CAT(a, b)  RV__CAT2(a, b)
#define RV__STR2(x)    #x
#define RV__STR(x)     RV__STR2(x)

/* One labelled 32-bit load. `site` is the numeric site id. */
#define RV_LD(dst, ptr, site)                                              \
	__asm__ __volatile__(".globl rvs_" RV__STR(site) "\n"                  \
	                     "rvs_" RV__STR(site) ": lw %0, 0(%1)"             \
	                     : "=r"(dst) : "r"(ptr) : "memory")

/* One labelled 32-bit store. */
#define RV_ST(ptr, val, site)                                              \
	__asm__ __volatile__(".globl rvs_" RV__STR(site) "\n"                  \
	                     "rvs_" RV__STR(site) ": sw %1, 0(%0)"             \
	                     :: "r"(ptr), "r"(val) : "memory")

/* A marker: one nop that exists only to be a watchpoint address. It costs a
 * cycle and buys an unambiguous control-flow checkpoint. */
#define RV_MARK(site)                                                      \
	__asm__ __volatile__(".globl rvs_" RV__STR(site) "\n"                  \
	                     "rvs_" RV__STR(site) ": nop" ::: "memory")

/* Software instrumentation: ONE store to the doorbell. The adapter turns it
 * into the CSR-write beat ACT-CAP decodes, so this is a full instrumentation
 * event with a RUNTIME payload -- the thing ACT-ST cannot do.
 *
 * The label is on the store itself for the same reason as above: the
 * consistency check wants to find it in the disassembly. */
#define RV_ACTCAP_AT(site, word)                                           \
	__asm__ __volatile__(".globl rvs_" RV__STR(site) "\n"                  \
	                     "rvs_" RV__STR(site) ": sw %1, 0(%0)\n"           \
	                     /* clearance nops: see RV_ACTCAP in rv_tags.h --  \
	                      * an ACT-ST site retiring while the doorbell     \
	                      * beat lands outranks and drops the command */   \
	                     "nop;nop;nop;nop;nop;nop"                         \
	                     :: "r"(RV_ACTCAP_DOORBELL_ADDR), "r"(word)        \
	                      : "memory")

#endif /* RV_SITE_H */
