/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * md_cap.h -- ACT-CAP instrumentation of a heap: one doorbell store per
 * field, each landing as one timestamped AXIS record.
 *
 * WHAT A RECORD CARRIES. The demo uses DAQ_PC_CURR beats only, because that
 * is the one command that carries a timestamp: element 0 = the PC of the
 * doorbell store, element 1 = the 24-bit DirectData tag below, element 2 =
 * the shared fabric timestamp. A malloc therefore becomes FOUR records
 * (MALLOC id, SIZE, PTR, CALLER), a free THREE, and every heap growth one
 * SBRK record from inside newlib's _sbrk() -- so the reader can watch
 * newlib ask for memory in the middle of a malloc.
 *
 * THE TAG. Compatible with rv_tags.h (SRC = ACT-CAP, KIND = VALUE, so the
 * rvcfi analyser would classify it as a runtime payload rather than reject
 * it), and inside the 21-bit VALUE field:
 *
 *     [20:18] field   MD_F_*  (what the 18-bit value means)
 *     [17:0]  value   id / size in bytes / address / caller PC
 *
 * 18 bits cover the 64 KiB private RAM that holds heap, stack and code
 * (0x0000..0xFFFF), with room for a 256 KiB shared-memory heap offset.
 */
#ifndef MD_CAP_H
#define MD_CAP_H

#include <stdint.h>
#include "rv_shared.h"
#include "rv_tags.h"

#define MD_F_MALLOC   0u   /* value = allocation id (start of a malloc) */
#define MD_F_SIZE     1u   /* value = requested size in bytes */
#define MD_F_PTR      2u   /* value = pointer malloc returned (0 = failed) */
#define MD_F_CALLER   3u   /* value = return address into the caller */
#define MD_F_FREE     4u   /* value = allocation id being freed (0 = unknown) */
#define MD_F_FREE_PTR 5u   /* value = pointer handed to free */
#define MD_F_FREE_CALLER 6u
#define MD_F_SBRK     7u   /* value = new program break (heap top) after growth */

#define MD_FIELD_SHIFT 18
#define MD_VALUE_MASK  0x3FFFFu

#define MD_TAG(field, value)                                              \
	((1u << RV_TAG_SRC_SHIFT) |                                           \
	 (((unsigned)RV_KIND_VALUE & RV_TAG_KIND_MASK) << RV_TAG_KIND_SHIFT) | \
	 (((unsigned)(field) & 7u) << MD_FIELD_SHIFT) |                       \
	 ((unsigned)(value) & MD_VALUE_MASK))

#define MD_WORD(field, value) \
	RV_ACT_WORD(RV_ACT_CMD_DAQ_PC_CURR, RV_ACT_SINK_AXIS, MD_TAG(field, value))

extern volatile uint32_t md_cap_issued;

/* One store to the doorbell = one ACT-CAP command. The six nops are the
 * same clearance rv_site.h documents: an ACT-ST site retiring while the
 * doorbell beat lands would outrank and drop the command. */
#define MD_CAP(field, value)                                              \
	do {                                                                  \
		uint32_t md__w = MD_WORD((field), (value));                       \
		__asm__ __volatile__("sw %1, 0(%0)\n"                             \
		                     "nop;nop;nop;nop;nop;nop"                    \
		                     :: "r"(RV_ACTCAP_DOORBELL), "r"(md__w)       \
		                      : "memory");                                \
		md_cap_issued++;                                                  \
	} while (0)

#endif /* MD_CAP_H */
