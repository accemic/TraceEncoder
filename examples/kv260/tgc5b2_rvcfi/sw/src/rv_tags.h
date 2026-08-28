/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * rv_tags.h -- the 24-bit tag that gives every instrumentation event its
 * meaning, plus the ACT-CAP command word that carries it.
 *
 * ONE definition, THREE users: `gen_sites.py` builds the ACT-ST table from
 * it, the two RISC-V programs build ACT-CAP command words from it, and
 * `rvmon` decodes both. Written once and included everywhere, because a tag
 * format mirrored between producer and consumer is the classic silent
 * drift: nothing errors, the events just mean something slightly different
 * than the analyser thinks, and the findings become fiction.
 *
 * WHERE THE TAG COMES FROM DIFFERS, AND THAT IS THE POINT
 * ------------------------------------------------------
 *   ACT-ST  the tag sits in the watchpoint table entry, so it is fixed at
 *           load time and costs the program nothing at all.
 *   ACT-CAP the tag sits in the word the program stores to the doorbell, so
 *           it can be COMPUTED at run time -- an index, a value, a lock
 *           mask. That is the one thing ACT-ST structurally cannot do.
 *
 * Bit 23 (`SRC`) says which of the two produced the record, so a merged
 * stream stays separable without consulting the site map.
 */

#ifndef RV_TAGS_H
#define RV_TAGS_H

/* ---- field positions (24-bit tag) ------------------------------------- */
#define RV_TAG_SRC_SHIFT     23          /* 0 = ACT-ST (hardware), 1 = ACT-CAP (software) */
#define RV_TAG_KIND_SHIFT    21          /* 2 bits */
#define RV_TAG_KIND_MASK     0x3u

#define RV_SRC_ACTST         0u
#define RV_SRC_ACTCAP        1u

#define RV_KIND_DATA         0u
#define RV_KIND_SYNC         1u
#define RV_KIND_MARKER       2u
#define RV_KIND_VALUE        3u          /* runtime payload -- ACT-CAP only */

/* KIND_DATA:   [20] RW  [19:13] OBJ  [12:4] SITE  [3:0] SIZE_LOG */
#define RV_DATA_RW_SHIFT     20
#define RV_DATA_OBJ_SHIFT    13
#define RV_DATA_OBJ_MASK     0x7Fu
#define RV_DATA_SITE_SHIFT   4
#define RV_DATA_SITE_MASK    0x1FFu
#define RV_DATA_SIZE_MASK    0xFu

/* KIND_SYNC:   [20:19] OP  [18:11] LOCK  [10:0] SITE */
#define RV_SYNC_OP_SHIFT     19
#define RV_SYNC_OP_MASK      0x3u
#define RV_SYNC_LOCK_SHIFT   11
#define RV_SYNC_LOCK_MASK    0xFFu
#define RV_SYNC_SITE_MASK    0x7FFu

/* KIND_MARKER: [20:11] MARKER  [10:0] SITE */
#define RV_MARK_ID_SHIFT     11
#define RV_MARK_ID_MASK      0x3FFu
#define RV_MARK_SITE_MASK    0x7FFu

/* KIND_VALUE:  [20:0] free runtime value */
#define RV_VALUE_MASK        0x1FFFFFu

/* ---- enumerations ------------------------------------------------------ */
#define RV_RW_READ           0u
#define RV_RW_WRITE          1u

#define RV_OBJ_BALANCE       1u
#define RV_OBJ_COUNT         2u
#define RV_OBJ_CHECKSUM      3u
#define RV_OBJ_SEQ           4u
#define RV_OBJ_RING_HEAD     5u
#define RV_OBJ_RING_TAIL     6u
#define RV_OBJ_RING_SLOT     7u
#define RV_OBJ_LOCKVAR       8u   /* the lock words themselves */
#define RV_OBJ_PRIVATE       9u   /* core-local, never contended */

#define RV_SYNC_ACQ_TRY      0u
#define RV_SYNC_ACQ_OK       1u
#define RV_SYNC_RELEASE      2u
#define RV_SYNC_FENCE        3u

#define RV_MARK_ENTER        1u
#define RV_MARK_LEAVE        2u
#define RV_MARK_DISPATCH     3u
#define RV_MARK_PHASE        4u

/* ---- builders ---------------------------------------------------------- */
#define RV_TAG_DATA(src, rw, obj, site, szlog)                    \
	((((unsigned)(src)   & 1u)                 << RV_TAG_SRC_SHIFT)  | \
	 (((unsigned)RV_KIND_DATA & RV_TAG_KIND_MASK) << RV_TAG_KIND_SHIFT) | \
	 (((unsigned)(rw)    & 1u)                 << RV_DATA_RW_SHIFT)  | \
	 (((unsigned)(obj)   & RV_DATA_OBJ_MASK)   << RV_DATA_OBJ_SHIFT) | \
	 (((unsigned)(site)  & RV_DATA_SITE_MASK)  << RV_DATA_SITE_SHIFT)| \
	  ((unsigned)(szlog) & RV_DATA_SIZE_MASK))

#define RV_TAG_SYNC(src, op, lock, site)                          \
	((((unsigned)(src)   & 1u)                 << RV_TAG_SRC_SHIFT)  | \
	 (((unsigned)RV_KIND_SYNC & RV_TAG_KIND_MASK) << RV_TAG_KIND_SHIFT) | \
	 (((unsigned)(op)    & RV_SYNC_OP_MASK)    << RV_SYNC_OP_SHIFT)  | \
	 (((unsigned)(lock)  & RV_SYNC_LOCK_MASK)  << RV_SYNC_LOCK_SHIFT)| \
	  ((unsigned)(site)  & RV_SYNC_SITE_MASK))

#define RV_TAG_MARKER(src, id, site)                              \
	((((unsigned)(src)   & 1u)                 << RV_TAG_SRC_SHIFT)  | \
	 (((unsigned)RV_KIND_MARKER & RV_TAG_KIND_MASK) << RV_TAG_KIND_SHIFT) | \
	 (((unsigned)(id)    & RV_MARK_ID_MASK)    << RV_MARK_ID_SHIFT)  | \
	  ((unsigned)(site)  & RV_MARK_SITE_MASK))

#define RV_TAG_VALUE(v)                                           \
	((1u << RV_TAG_SRC_SHIFT) |                                   \
	 (((unsigned)RV_KIND_VALUE & RV_TAG_KIND_MASK) << RV_TAG_KIND_SHIFT) | \
	  ((unsigned)(v) & RV_VALUE_MASK))

/* ---- ACT-CAP command word --------------------------------------------- */
/* Layout from the encoder's RDL (trActCapStCmd):
 *   [5:0] Cmd   [7:6] Sink   [31:8] DirectData (the 24-bit tag)          */
#define RV_ACT_CMD_NONE          0u
#define RV_ACT_CMD_DAQ_PC_CURR   1u
#define RV_ACT_CMD_DAQ_DIRECT    3u
#define RV_ACT_CMD_DAQ_DADDR     5u
#define RV_ACT_CMD_CF_SYNC      12u
#define RV_ACT_CMD_TE           13u

#define RV_ACT_SINK_NEXUS        0u
#define RV_ACT_SINK_AXIS         1u
#define RV_ACT_SINK_AXIS_NEXUS   2u
#define RV_ACT_SINK_TE           3u

#define RV_ACT_WORD(cmd, sink, tag)                               \
	((((unsigned)(cmd)  & 0x3Fu))        |                        \
	 (((unsigned)(sink) & 0x3u)  << 6)   |                        \
	 (((unsigned)(tag)  & 0xFFFFFFu) << 8))

/* The one instrumentation primitive the programs use. A single store; the
 * adapter turns it into the CSR-write beat ACT-CAP decodes.
 *
 * `DAQ_PC_CURR` is the default command because it is the ONLY one that
 * carries a timestamp (element 2) -- without it there is no cross-core
 * ordering, and without cross-core ordering there is no race detection. */
#ifdef __riscv
/* The nop padding is load-bearing, not cosmetic.
 *
 * The doorbell store's DATA beat reaches the encoder a few bus cycles after
 * the instruction issued; if an ACT-ST site instruction happens to retire in
 * exactly that cycle, the encoder's instrumentation processor gives ACT-ST
 * priority and the ACT-CAP command is silently dropped (an upstream property
 * of ct_L23_preproc_act_proc -- "ACT_ST overrides ACT_CAP within the same
 * instruction" -- and the encoder core is not ours to change).
 *
 * Measured, not theorised: the release-path doorbell was followed by a
 * single-cycle nop SITE and lost 42 of 42 commands; the acquire-path
 * doorbell was followed by a bus-stalling load and lost 0 of 42. The
 * contract is therefore mechanical: after every doorbell store, a few
 * instruction slots that carry NO instrumented instruction, so whatever
 * retires while the beat lands cannot outrank it. Six uninstrumented nops
 * cover the bus latency with margin and cost ~80 ns per runtime tag. */
#define RV_ACTCAP(cmd, sink, tag)                                          \
	do {                                                                   \
		*(volatile unsigned *)RV_ACTCAP_DOORBELL_ADDR =                    \
			RV_ACT_WORD((cmd), (sink), (tag));                             \
		__asm__ __volatile__("nop;nop;nop;nop;nop;nop" ::: "memory");      \
	} while (0)
#define RV_ACTCAP_DOORBELL_ADDR 0x40000000u
#define RV_EMIT_VALUE(v)   RV_ACTCAP(RV_ACT_CMD_DAQ_PC_CURR, RV_ACT_SINK_AXIS, RV_TAG_VALUE(v))
#endif

#endif /* RV_TAGS_H */
