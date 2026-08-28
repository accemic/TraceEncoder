/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * rvmon.h -- the host-side runtime-verification monitor for the two-core
 * RV/CFI demo. Runs on the KV260's PS Linux, needs nothing but a C compiler
 * and /dev/mem.
 *
 * WHY C AND NOT PYTHON
 * --------------------
 * Throughput is this demo's one real operating limit. Unthrottled, the two
 * cores generate roughly half a million watchpoint records per second EACH;
 * the Python reader of the neighbouring testbed drains about 4 660/s per
 * core, which was measured, not guessed. On a stream that lossy a race
 * detector reports fiction. The reader is therefore C, and the program
 * REFUSES a verdict if the shims dropped anything (see `rv_refuse_t`) rather
 * than quietly analysing a sample.
 */

#ifndef RVMON_H
#define RVMON_H

#include <stdint.h>
#include <stdio.h>

/* ---------------------------------------------------------------------- */
/* Hardware map (from examples/kv260/tgc5b2_rvcfi/fpga/tgc5b2_rvcfi_kv260_top.sv
 * and rtl/tgc5b2_rvcfi_soc_top.sv -- keep in step with those headers).     */
/* ---------------------------------------------------------------------- */
#define RVM_SOC_BASE        0xA0000000u
#define RVM_WPCTRL_BASE     0xA0400000u
#define RVM_FIFO0_BASE      0xA0410000u
#define RVM_FIFO1_BASE      0xA0420000u
#define RVM_WINDOW_SIZE     0x00400000u   /* SoC aperture, 22 bit */
#define RVM_SMALL_WINDOW    0x00010000u   /* WPCTRL / FIFO register sets */

/* SoC aperture offsets */
#define RVM_OFF_CTRL        0x000000u
#define RVM_OFF_ENC0        0x010000u
#define RVM_OFF_ENC1        0x020000u
#define RVM_OFF_SHARED      0x040000u
#define RVM_OFF_RAM1        0x080000u
#define RVM_OFF_RAM0        0x100000u

/* CTRL registers */
#define RVM_CTRL_CONTROL    0x00u
#define RVM_CTRL_STATUS     0x04u
/* RV/CFI observation bank (read-only) */
#define RVM_CTRL_DB0_HITS   0x40u
#define RVM_CTRL_DB0_LAST   0x44u
#define RVM_CTRL_DB1_HITS   0x48u
#define RVM_CTRL_DB1_LAST   0x4Cu
#define RVM_CTRL_ACTCAP0    0x50u
#define RVM_CTRL_ACTCAP1    0x54u
#define RVM_CTRL_SHARED_SZ  0x58u
#define RVM_CTRL_MAGIC      0x5Cu
/* Console (N1): per-core char channel, PS side. STAT = {tx_cnt, rx_free};
 * POP is a side-effect read (bit 31 valid, [7:0] char, FWFT); the PUSH
 * offset is written with the char in [7:0] and READS as the RX drop
 * counter (pushes into a full RX are counted, never silent). */
#define RVM_CTRL_CON0_STAT  0x60u
#define RVM_CTRL_CON0_POP   0x64u
#define RVM_CTRL_CON0_PUSH  0x68u
#define RVM_CTRL_CON1_STAT  0x70u
#define RVM_CTRL_CON1_POP   0x74u
#define RVM_CTRL_CON1_PUSH  0x78u
#define RVM_MAGIC_VALUE     0x52564349u   /* "RVCI" */

#define RVM_CONTROL_CORE0_RUN  (1u << 8)
#define RVM_CONTROL_CORE1_RUN  (1u << 9)
#define RVM_STATUS_CORE0_RUN   (1u << 8)
#define RVM_STATUS_CORE1_RUN   (1u << 9)

/* DDR record rings (N3): per-core register bank in the CTRL window, core 0
 * at 0x80, core 1 at 0xA0 (stride 0x20). The bank routes each core's record
 * stream EITHER into its MM-FIFO (route_ddr=0, the pre-N3 path, bit-
 * identical) OR into a 128-MiB DDR4 ring inside the reserved 256-MiB window
 * -- where the shim sees an always-ready consumer, so a slow PS drain can no
 * longer turn into shim drops. Layout: rtl/tgc5b2_rvcfi_soc_top.sv header. */
#define RVM_CTRL_RING0      0x80u
#define RVM_CTRL_RING1      0xA0u
#define RVM_RING_STRIDE     0x20u
/* register offsets within one bank */
#define RVM_RING_CTRL       0x00u
#define RVM_RING_BASE       0x04u   /* WARL: 32-byte aligned, inside the window */
#define RVM_RING_SIZE       0x08u   /* WARL: multiple of 32, > 0 */
#define RVM_RING_WPTR       0x0Cu   /* ro: TOTAL bytes written, monotonic */
#define RVM_RING_STAT       0x10u
#define RVM_RING_DROPS      0x14u   /* ro: saturating */
#define RVM_RING_BEATS      0x18u   /* ro: words offered while enabled */
/* RING_CTRL bits */
#define RVM_RING_EN         (1u << 0)
#define RVM_RING_CLEAR      (1u << 1)   /* W1 pulse, only meaningful at en=0 */
#define RVM_RING_CIRC       (1u << 2)   /* reset 1 = circular */
#define RVM_RING_ROUTE_DDR  (1u << 3)   /* reset 0 = FIFO route */
/* RING_STAT bits */
#define RVM_RING_ST_FULL    (1u << 0)   /* one-shot (circ=0) only */
#define RVM_RING_ST_AXIERR  (1u << 1)
#define RVM_RING_ST_WRAP    (1u << 2)
#define RVM_RING_ST_CFGREJ  (1u << 3)   /* sticky; clear pulse resets */

/* PS AFIFM port-width controls. `psu_init` -- which would set them -- does
 * not run for a DFX app, so the ports sit at their 128-bit reset value until
 * a board-side write narrows them; a 32-bit master writing into a 128-bit
 * port lands ONE word per 16-byte slot while every counter looks healthy
 * (examples/kv260/SPEC_board_memory_map.md section 4 -- learned twice).
 * AFIFM2 = saxigp2, AFIFM3 = saxigp3: the two ring sinks' write ports. */
#define RVM_AFIFM2_BASE     0xFD380000u
#define RVM_AFIFM3_BASE     0xFD390000u
#define RVM_AFIFM_RDCTRL    0x00u
#define RVM_AFIFM_WRCTRL    0x14u
#define RVM_AFIFM_W32       2u          /* FABRIC_WIDTH code: 0=128 1=64 2=32 */

/* Encoder CSRs (rdl/ct_cs_cpuif.rdl) */
#define RVM_ENC_TE_CONTROL  0x0000u
#define RVM_ENC_TS_CONTROL  0x0040u
#define RVM_ENC_WP_INDEX    0x400Cu
#define RVM_ENC_WP_DATA_LO  0x4010u
#define RVM_ENC_WP_DATA_HI  0x4014u
#define RVM_ENC_WP_READ_LO  0x4018u
#define RVM_ENC_WP_READ_HI  0x401Cu
#define RVM_ENC_WP_CAP      0x4020u

/* trTsControl value that arms the timestamp unit -- the same word the e2e
 * bench writes (sim/tb_rvcfi_e2e.sv): Active[0] | Count[1] |
 * Type[6:4] = TR_TS_CORE (3) | Enable[15]. TR_TS_CORE because the SoC feeds
 * the shared fabric counter into tip._time. Type is writable only while
 * trTeControl.Enable = 0 -- the reset state, and it stays so here: the
 * watchpoint/AXIS path does not use the Nexus trace engine. Without this
 * every record carries ts = 0: well-formed, and useless for cross-core
 * ordering (the first silicon run). Width[29:24] resets to 63 and is not
 * part of the compare. */
#define RVM_TS_CONTROL_ARMED 0x00008033u
#define RVM_TS_CONTROL_MASK  0x0000FFFFu

/* axi_fifo_mm_s (PG080), same offsets the Python reader uses */
#define RVM_FIFO_ISR        0x00u
#define RVM_FIFO_IER        0x04u
#define RVM_FIFO_RDFR       0x18u
#define RVM_FIFO_RDFO       0x1Cu
#define RVM_FIFO_RDFD       0x20u
#define RVM_FIFO_RLR        0x24u
#define RVM_FIFO_SRR        0x28u
#define RVM_FIFO_RESET_KEY  0xA5u

/* WPCTRL (shim status; layout per the kv260 top) */
#define RVM_WP_MAGIC        0x00u
#define RVM_WP_SHIM0_DROPS  0x04u
#define RVM_WP_SHIM0_FILL   0x08u
#define RVM_WP_SHIM0_STAT   0x0Cu
#define RVM_WP_SHIM1_DROPS  0x10u
#define RVM_WP_SHIM1_FILL   0x14u
#define RVM_WP_SHIM1_STAT   0x18u

/* ---------------------------------------------------------------------- */
/* Records                                                                  */
/* ---------------------------------------------------------------------- */
/* One AXIS beat, serialised by ct_axis_wp_shim into four 32-bit words:
 *   W0 PC (DAQ_PC_CURR element 0)
 *   W1 DirectData -- the 24-bit tag, zero-extended
 *   W2 Timestamp[31:0] (element 2; the ONLY element that gives cross-core
 *      ordering, which is why every site uses DAQ_PC_CURR)
 *   W3 {8'h00, core_id[3:0], tstrb[11:0], tid[7:0]}
 */
#define RVM_REC_WORDS 4
#define RVM_REC_BYTES 16

typedef struct {
	uint32_t pc;
	uint32_t tag;        /* 24 bit meaningful */
	uint32_t ts;
	uint8_t  tid;        /* ACT-CAP/ACT-ST command */
	uint16_t tstrb;      /* 12 bit */
	uint8_t  core;       /* 0 or 1 */
	uint32_t index;      /* position in the drained stream */
	uint64_t ts_unrolled;/* 32-bit wrap resolved */
} rv_rec_t;

/* Decoded tag (mirrors src/rv_tags.h; the ONE place that interprets bits) */
typedef enum { RV_K_DATA = 0, RV_K_SYNC = 1, RV_K_MARKER = 2, RV_K_VALUE = 3 } rv_kind_t;

typedef struct {
	int       from_actcap;   /* bit 23 */
	rv_kind_t kind;
	/* data */
	int       is_write;
	unsigned  obj;
	unsigned  site;
	unsigned  size_log;
	/* sync */
	unsigned  op;            /* 0 try, 1 ok, 2 release, 3 fence */
	unsigned  lock;
	/* marker */
	unsigned  marker;
	/* value */
	unsigned  value;
} rv_tag_t;

void rv_tag_decode(uint32_t tag, rv_tag_t *out);
const char *rv_obj_name(unsigned obj);
const char *rv_op_name(unsigned op);
const char *rv_marker_name(unsigned m);

/* ---------------------------------------------------------------------- */
/* Why a verdict may be refused                                             */
/* ---------------------------------------------------------------------- */
/* A monitor that reports "no findings" on a stream it cannot trust is worse
 * than one that reports nothing at all, because the first is believed. */
typedef enum {
	RV_OK = 0,
	RV_REFUSE_DROPS,          /* a shim dropped records */
	RV_REFUSE_OVERFLOW,       /* shim overflow sticky */
	RV_REFUSE_MALFORMED,      /* reserved bits / implausible tstrb */
	RV_REFUSE_UNKNOWN_PC,     /* a PC that is not in the loaded table */
	RV_REFUSE_TABLE,          /* table readback disagreed with what was written */
	RV_REFUSE_TS_ORDER,       /* timestamps not monotonic within a core */
	RV_REFUSE_CLOCK,          /* pl_clk0 is not what the timing assumes */
	RV_REFUSE_EMPTY           /* nothing captured at all */
} rv_refuse_t;

const char *rv_refuse_text(rv_refuse_t r);

/* ---------------------------------------------------------------------- */
/* Site map (sites_coreN.csv, produced by sw/gen_sites.py)                  */
/* ---------------------------------------------------------------------- */
typedef struct {
	uint32_t addr;
	int      core;       /* which core's program this site belongs to */
	int      site_id;
	int      from_actcap;
	char     kind[10];
	int      kind_idx;
	char     object[16];
	char     rw[4];
	char     func[16];
	char     note[80];
} rv_site_t;

typedef struct {
	rv_site_t *v;
	size_t     n, cap;
} rv_sitemap_t;

/* Both programs live at the SAME addresses in their own RAMs, so a lookup
 * that ignores the core resolves core 1 PCs against core 0 code and invents
 * findings.  appends, and every lookup takes the core. */
int  rv_sitemap_load(rv_sitemap_t *m, const char *path, int core);
const rv_site_t *rv_sitemap_find(const rv_sitemap_t *m, uint32_t addr, int core);
void rv_sitemap_free(rv_sitemap_t *m);

/* ---------------------------------------------------------------------- */
/* Findings and monitors                                                    */
/* ---------------------------------------------------------------------- */
typedef struct {
	const char *monitor;     /* which monitor produced it */
	const char *klass;       /* short machine-readable class */
	char        text[256];   /* human-readable */
	uint32_t    pc_a, pc_b;  /* the two sites involved (pc_b may be 0) */
	int         core_a, core_b;
	uint64_t    ts_a, ts_b;
} rv_finding_t;

typedef struct {
	rv_finding_t *v;
	size_t        n, cap;
} rv_findings_t;

void rv_finding_add(rv_findings_t *f, const rv_finding_t *item);
void rv_findings_free(rv_findings_t *f);

/* A monitor sees the whole (merged, time-ordered) record stream. Adding one
 * means writing a function of this shape and putting it in the table in
 * monitors.c -- see the tutorial's "build your own monitor". */
typedef void (*rv_monitor_fn)(const rv_rec_t *recs, size_t n,
                              const rv_sitemap_t *map, rv_findings_t *out);

typedef struct {
	const char   *name;
	const char   *what;
	rv_monitor_fn fn;
} rv_monitor_t;

extern const rv_monitor_t rv_monitors[];
extern const size_t rv_monitor_count;

/* ---------------------------------------------------------------------- */
/* Stream handling                                                          */
/* ---------------------------------------------------------------------- */
size_t rv_parse_words(const uint32_t *w, size_t nwords, int core,
                      rv_rec_t *out, size_t out_cap,
                      size_t *n_malformed);
void   rv_unroll_timestamps(rv_rec_t *r, size_t n);
void   rv_merge_by_time(rv_rec_t *dst, const rv_rec_t *a, size_t na,
                        const rv_rec_t *b, size_t nb);

#endif /* RVMON_H */
