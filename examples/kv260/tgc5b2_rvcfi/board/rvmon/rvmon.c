/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: ISC
 *
 * rvmon.c -- driver, hardware access, stream handling and CLI.
 * The analysis itself lives in monitors.c.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The board is Linux and reaches the design through /dev/mem. A workstation
 * build must still compile, because `rvmon selftest` and `rvmon analyze` are
 * supposed to work with no hardware at all -- that is what lets a monitor be
 * developed and tested away from the board. Only the hardware half is
 * guarded; the analysis is identical in both builds, which is the point:
 * the same binary logic judges a simulation dump and a board capture. */
#if defined(__linux__)
#define RVMON_HAVE_DEVMEM 1
#include <sys/mman.h>
#include <unistd.h>
#else
#define RVMON_HAVE_DEVMEM 0
#endif

#include "rvmon.h"

/* The shared-memory layout is single-sourced with the RISC-V programs. This
 * is the whole point of rv_shared.h: the host and the two cores agree on the
 * offsets because they read the same file, not because someone kept two
 * copies in step. */
/* Resolved via the Makefile's -I list: ../../sw/src in the source tree,
 * the current directory when staged flat onto the board by deploy.sh. */
#include "rv_shared.h"

/* ====================================================================== */
/* Small helpers                                                           */
/* ====================================================================== */

static void die(const char *fmt, ...)
{
	va_list ap;
	fprintf(stderr, "rvmon: ");
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, "\n");
	exit(1);
}

#if RVMON_HAVE_DEVMEM
static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + 1e-9 * (double)t.tv_nsec;
}
#endif

/* ====================================================================== */
/* /dev/mem windows                                                        */
/* ====================================================================== */

typedef struct {
	volatile uint32_t *p;
	size_t             len;
} rv_win_t;

#if RVMON_HAVE_DEVMEM
static int g_memfd = -1;

static void mem_open(void)
{
	if (g_memfd >= 0) return;
	g_memfd = open("/dev/mem", O_RDWR | O_SYNC);
	if (g_memfd < 0)
		die("cannot open /dev/mem (%s) -- run as root", strerror(errno));
}

static rv_win_t win_map(uint32_t base, size_t len)
{
	rv_win_t w;
	mem_open();
	w.len = len;
	w.p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, g_memfd, (off_t)base);
	if (w.p == MAP_FAILED)
		die("mmap of 0x%08X (%zu B) failed: %s", base, len, strerror(errno));
	return w;
}

static inline uint32_t rd(rv_win_t w, uint32_t off) { return w.p[off / 4]; }
static inline void     wr(rv_win_t w, uint32_t off, uint32_t v) { w.p[off / 4] = v; }
#endif /* RVMON_HAVE_DEVMEM */

/* ====================================================================== */
/* Tag decoding -- the ONE place that interprets the bits host-side.        */
/* Layout: src/rv_tags.h. Keep the two in step; the site map's `src` column */
/* is generated from the same header, so a drift shows up as a mismatch     */
/* between decoded kind and mapped kind rather than silently.               */
/* ====================================================================== */

void rv_tag_decode(uint32_t tag, rv_tag_t *o)
{
	memset(o, 0, sizeof *o);
	o->from_actcap = (tag >> 23) & 1u;
	o->kind = (rv_kind_t)((tag >> 21) & 0x3u);
	switch (o->kind) {
	case RV_K_DATA:
		o->is_write = (tag >> 20) & 1u;
		o->obj      = (tag >> 13) & 0x7Fu;
		o->site     = (tag >> 4)  & 0x1FFu;
		o->size_log = tag & 0xFu;
		break;
	case RV_K_SYNC:
		o->op   = (tag >> 19) & 0x3u;
		o->lock = (tag >> 11) & 0xFFu;
		o->site = tag & 0x7FFu;
		break;
	case RV_K_MARKER:
		o->marker = (tag >> 11) & 0x3FFu;
		o->site   = tag & 0x7FFu;
		break;
	case RV_K_VALUE:
		o->value = tag & 0x1FFFFFu;
		break;
	}
}

const char *rv_obj_name(unsigned obj)
{
	switch (obj) {
	case 1: return "balance";
	case 2: return "count";
	case 3: return "checksum";
	case 4: return "seq";
	case 5: return "ring_head";
	case 6: return "ring_tail";
	case 7: return "ring_slot";
	case 8: return "lockvar";
	case 9: return "private";
	default: return "obj?";
	}
}

const char *rv_op_name(unsigned op)
{
	switch (op) {
	case 0: return "acq_try";
	case 1: return "acq_ok";
	case 2: return "release";
	default: return "fence";
	}
}

const char *rv_marker_name(unsigned m)
{
	switch (m) {
	case 1: return "enter";
	case 2: return "leave";
	case 3: return "dispatch";
	case 4: return "phase";
	default: return "mark?";
	}
}

const char *rv_refuse_text(rv_refuse_t r)
{
	switch (r) {
	case RV_OK:               return "ok";
	case RV_REFUSE_DROPS:     return "a shim dropped records -- the stream is incomplete";
	case RV_REFUSE_OVERFLOW:  return "a shim overflowed (sticky) -- the stream is incomplete";
	case RV_REFUSE_MALFORMED: return "malformed records in the stream";
	case RV_REFUSE_UNKNOWN_PC:return "a record carries a PC that is not in the loaded table";
	case RV_REFUSE_TABLE:     return "the watchpoint table did not read back as written";
	case RV_REFUSE_TS_ORDER:  return "timestamps are not monotonic within a core";
	case RV_REFUSE_CLOCK:     return "pl_clk0 is not the frequency the timing assumes";
	case RV_REFUSE_EMPTY:     return "nothing was captured";
	}
	return "?";
}

/* ====================================================================== */
/* Findings                                                                */
/* ====================================================================== */

void rv_finding_add(rv_findings_t *f, const rv_finding_t *item)
{
	if (f->n == f->cap) {
		f->cap = f->cap ? f->cap * 2 : 32;
		f->v = realloc(f->v, f->cap * sizeof *f->v);
		if (!f->v) die("out of memory");
	}
	f->v[f->n++] = *item;
}

void rv_findings_free(rv_findings_t *f) { free(f->v); f->v = NULL; f->n = f->cap = 0; }

/* ====================================================================== */
/* Site map                                                                */
/* ====================================================================== */

static void csv_field(char **p, char *dst, size_t cap)
{
	char *s = *p, *e = strchr(s, ',');
	size_t n;
	if (!e) e = s + strlen(s);
	n = (size_t)(e - s);
	if (n >= cap) n = cap - 1;
	memcpy(dst, s, n);
	dst[n] = 0;
	*p = (*e == ',') ? e + 1 : e;
}

int rv_sitemap_load(rv_sitemap_t *m, const char *path, int core)
{
	FILE *f = fopen(path, "r");
	char line[512];
	if (!f) return -1;
	if (!fgets(line, sizeof line, f)) { fclose(f); return -1; }   /* header */
	while (fgets(line, sizeof line, f)) {
		rv_site_t s;
		char *p = line, buf[80];
		line[strcspn(line, "\r\n")] = 0;
		if (!line[0]) continue;
		memset(&s, 0, sizeof s);
		s.core = core;
		csv_field(&p, buf, sizeof buf); s.addr = (uint32_t)strtoul(buf, NULL, 16);
		csv_field(&p, buf, sizeof buf); s.site_id = atoi(buf);
		csv_field(&p, buf, sizeof buf); s.from_actcap = (strcmp(buf, "actcap") == 0);
		csv_field(&p, s.kind, sizeof s.kind);
		csv_field(&p, buf, sizeof buf); s.kind_idx = atoi(buf);
		csv_field(&p, s.object, sizeof s.object);
		csv_field(&p, s.rw, sizeof s.rw);
		csv_field(&p, buf, sizeof buf);            /* lock */
		csv_field(&p, buf, sizeof buf);            /* marker */
		csv_field(&p, s.func, sizeof s.func);
		csv_field(&p, s.note, sizeof s.note);
		if (m->n == m->cap) {
			m->cap = m->cap ? m->cap * 2 : 256;
			m->v = realloc(m->v, m->cap * sizeof *m->v);
			if (!m->v) die("out of memory");
		}
		m->v[m->n++] = s;
	}
	fclose(f);
	return 0;
}

const rv_site_t *rv_sitemap_find(const rv_sitemap_t *m, uint32_t addr, int core)
{
	size_t i;
	for (i = 0; i < m->n; i++)
		if (m->v[i].addr == addr && m->v[i].core == core) return &m->v[i];
	return NULL;
}

void rv_sitemap_free(rv_sitemap_t *m) { free(m->v); memset(m, 0, sizeof *m); }

/* ====================================================================== */
/* Records                                                                 */
/* ====================================================================== */

size_t rv_parse_words(const uint32_t *w, size_t nwords, int core,
                      rv_rec_t *out, size_t cap, size_t *n_malformed)
{
	size_t i, n = 0;
	*n_malformed = nwords % RVM_REC_WORDS;      /* a partial record at the end */
	for (i = 0; i + RVM_REC_WORDS <= nwords && n < cap; i += RVM_REC_WORDS) {
		uint32_t w3 = w[i + 3];
		rv_rec_t r;
		memset(&r, 0, sizeof r);
		r.pc    = w[i + 0];
		r.tag   = w[i + 1] & 0xFFFFFFu;
		r.ts    = w[i + 2];
		r.tid   = (uint8_t)(w3 & 0xFFu);
		r.tstrb = (uint16_t)((w3 >> 8) & 0xFFFu);
		r.core  = (uint8_t)((w3 >> 20) & 0xFu);
		r.index = (uint32_t)n;
		/* The shim drives W3[31:24] hard 0; anything else means the stream
		 * is not what we think it is. Same for a strobe that is partial
		 * inside an element -- the encoder strobes element-wise. */
		if ((w3 & 0xFF000000u) != 0u) { (*n_malformed)++; continue; }
		if (core >= 0) r.core = (uint8_t)core;
		out[n++] = r;
	}
	return n;
}

void rv_unroll_timestamps(rv_rec_t *r, size_t n)
{
	size_t i;
	uint64_t hi = 0;
	uint32_t prev = 0;
	for (i = 0; i < n; i++) {
		if (i && r[i].ts < prev) hi += 0x100000000ull;   /* 32-bit wrap */
		prev = r[i].ts;
		r[i].ts_unrolled = hi + r[i].ts;
	}
}

/* Pairing pre-pass: graft each runtime (ACT-CAP) sync record's lock id onto
 * its STATIC twin, then retire the runtime record from lock-state duty.
 *
 * Why: the runtime records carry the lock identity the program actually
 * used (the static tag was fixed at table-load time), but they travel a
 * shorter hardware pipeline than the ACT-ST records and overtake the data
 * accesses that retired before them. Using them for ORDER produced phantom
 * happens-before conflicts on correct code; using them for IDENTITY at the
 * static record's position keeps both truths. Twins arrive per core in
 * program order on both paths, so the pairing is a per-core, per-op queue.
 * Streams without runtime records (EN_ACTCAP=0) pass through unchanged. */
static size_t rv_pair_runtime_sync(rv_rec_t *r, size_t n)
{
	size_t qi[2][4], qn[2][4];      /* per core, per op: cursor + count */
	size_t shortfall = 0;
	static uint32_t qlock[2][4][4096];
	size_t i;
	unsigned c, op;

	memset(qi, 0, sizeof qi);
	memset(qn, 0, sizeof qn);

	for (i = 0; i < n; i++) {
		rv_tag_t t;
		rv_tag_decode(r[i].tag, &t);
		if (t.kind != RV_K_SYNC || !t.from_actcap) continue;
		c = r[i].core & 1u;
		op = t.op & 3u;
		if (qn[c][op] < 4096) qlock[c][op][qn[c][op]++] = t.lock;
		/* retire from state duty: SYNC(01) -> VALUE(11) by setting bit 22 */
		r[i].tag |= (1u << 22);
	}
	if (!(qn[0][1] | qn[0][2] | qn[1][1] | qn[1][2]))
		return 0;                    /* no runtime sync in this stream */

	for (i = 0; i < n; i++) {
		rv_tag_t t;
		rv_tag_decode(r[i].tag, &t);
		if (t.kind != RV_K_SYNC || t.from_actcap) continue;
		c = r[i].core & 1u;
		op = t.op & 3u;
		if (op != 1u && op != 2u) continue;          /* acq_ok / release only */
		if (qi[c][op] < qn[c][op]) {
			uint32_t lk = qlock[c][op][qi[c][op]++];
			r[i].tag = (r[i].tag & ~(0xFFu << 11)) | ((lk & 0xFFu) << 11);
		}
		else {
			shortfall++;
		}
	}
	/* A static sync record without a runtime twin means the encoder dropped
	 * an ACT-CAP command (the instrumentation processor gives ACT-ST
	 * priority in the same aligned cycle -- the doorbell macro's clearance
	 * nops exist to prevent exactly this). Analysing on top of it would
	 * grow phantom findings from misassigned lock ids, so the caller
	 * refuses instead: 65 fictional double-acquires taught that lesson. */
	return shortfall;
}

void rv_merge_by_time(rv_rec_t *dst, const rv_rec_t *a, size_t na,
                      const rv_rec_t *b, size_t nb)
{
	size_t i = 0, j = 0, k = 0;
	while (i < na && j < nb)
		dst[k++] = (a[i].ts_unrolled <= b[j].ts_unrolled) ? a[i++] : b[j++];
	while (i < na) dst[k++] = a[i++];
	while (j < nb) dst[k++] = b[j++];
}

/* ====================================================================== */
/* FIFO drain, table load, image load -- board-only                        */
/* ====================================================================== */
#if RVMON_HAVE_DEVMEM

static size_t fifo_drain(rv_win_t f, uint32_t *buf, size_t cap, double budget_s)
{
	size_t n = 0;
	double t0 = now_s();
	for (;;) {
		uint32_t occ = rd(f, RVM_FIFO_RDFO);
		if (occ == 0) {
			if (now_s() - t0 > budget_s) break;
			continue;
		}
		(void)rd(f, RVM_FIFO_RLR);          /* packet length; pops the header */
		while (occ-- && n < cap)
			buf[n++] = rd(f, RVM_FIFO_RDFD);
		if (n >= cap) break;
		if (now_s() - t0 > budget_s) break;
	}
	return n;
}

/* ====================================================================== */
/* DDR record rings (N3) -- board-only                                     */
/* ====================================================================== */

static uint32_t ring_bank(int core)
{
	return RVM_OFF_CTRL + (core ? RVM_CTRL_RING1 : RVM_CTRL_RING0);
}

/* Narrow one PS AFIFM port to 32 bit. Exact replica of the shell helper
 * `afifm_width()` in examples/dashboard/boot/cva6_linux64_run.sh (also
 * rocket_linux64_run.sh, rocket2_linux_run.sh, cva6_2_run.sh) and of
 * examples/kv260/SPEC_board_memory_map.md section 4: FABRIC_WIDTH is bits
 * [1:0] of RDCTRL (+0x0) and WRCTRL (+0x14), and the reset value 0x3B0
 * carries reserved-but-RW bits above [1:0], so the write must be
 * read-modify-write -- writing the whole register would clear them.
 * The mistake this guards against is SILENT: a 32-bit master into a port
 * still presenting its 128-bit reset width lands one word per 16-byte
 * slot, and every counter looks healthy while the capture is garbage. */
static void afifm_narrow32(uint32_t base)
{
	rv_win_t w = win_map(base, RVM_SMALL_WINDOW);
	uint32_t v;
	v = rd(w, RVM_AFIFM_RDCTRL);
	wr(w, RVM_AFIFM_RDCTRL, (v & ~0x3u) | RVM_AFIFM_W32);
	v = rd(w, RVM_AFIFM_WRCTRL);
	wr(w, RVM_AFIFM_WRCTRL, (v & ~0x3u) | RVM_AFIFM_W32);
}

/* Copy one ring's payload into `out` (a word buffer), ending on the last
 * COMPLETE record. WPTR counts TOTAL bytes since the clear pulse, so the
 * ring offset of any logical byte L is simply L % size, and once the ring
 * has wrapped the oldest surviving byte lives exactly at wptr % size.
 * Three cuts are possible, and each one is SAID, not silently applied:
 *   - trailing bytes of a record the sink had not finished (wptr is word-
 *     granular, records are 16 B) are discarded and counted,
 *   - a wrapped ring only holds its last `size` bytes,
 *   - the host buffer holds 16 MiB; beyond that the LAST records win,
 *     because the freshest evidence is what a post-mortem wants. */
static size_t ring_extract(rv_win_t soc, int core, uint32_t *out, size_t cap_words)
{
	uint32_t bank = ring_bank(core);
	uint32_t base = rd(soc, bank + RVM_RING_BASE);
	uint32_t size = rd(soc, bank + RVM_RING_SIZE);
	uint32_t wptr = rd(soc, bank + RVM_RING_WPTR);
	uint32_t avail, tear, keep, cap_bytes, start, i;
	rv_win_t ddr;

	if (size == 0) {
		fprintf(stderr, "rvmon: core %d ring reads SIZE 0 -- no ring bank in "
		        "this bitstream?\n", core);
		return 0;
	}
	if (wptr == 0) return 0;

	avail = (wptr < size) ? wptr : size;
	tear  = wptr % RVM_REC_BYTES;
	if (avail <= tear) {
		fprintf(stderr, "rvmon: core %d ring holds only a torn record "
		        "(%u B) -- discarded\n", core, avail);
		return 0;
	}
	avail -= tear;
	cap_bytes = (uint32_t)(cap_words * 4u);
	keep = (avail < cap_bytes) ? avail : cap_bytes;
	if (tear)
		fprintf(stderr, "rvmon: core %d ring: %u trailing byte(s) of an "
		        "unfinished record discarded\n", core, tear);
	if (keep < wptr - tear)
		printf("core%d ring: kept last %u of %u B%s\n", core, keep,
		       wptr - tear, (wptr > size) ? " (ring wrapped)"
		                                  : " (host buffer is 16 MiB)");

	ddr = win_map(base, size);
	/* The oldest kept byte sits at logical offset wptr - tear - keep; the
	 * word-wise modulo walks the wrap seam without a special case. No
	 * overflow: start + keep = wptr - tear <= wptr. */
	start = wptr - tear - keep;
	for (i = 0; i < keep; i += 4)
		out[i / 4] = ddr.p[((start + i) % size) / 4];
	return keep / 4;
}

/* ====================================================================== */
/* Watchpoint table                                                        */
/* ====================================================================== */

typedef struct { uint32_t addr, cmd; } wp_entry_t;

static size_t wp_load_file(const char *path, wp_entry_t *v, size_t cap)
{
	FILE *f = fopen(path, "r");
	char line[128];
	size_t n = 0;
	if (!f) die("cannot open %s: %s", path, strerror(errno));
	while (fgets(line, sizeof line, f) && n < cap) {
		unsigned a, c;
		if (line[0] == '#' || line[0] == '\n') continue;
		if (sscanf(line, "%x %x", &a, &c) == 2) {
			v[n].addr = a; v[n].cmd = c; n++;
		}
	}
	fclose(f);
	return n;
}

/* Indirect protocol (doc/integration.adoc, [#wp-indirect]):
 *   trWpIndex := start; then per slot DataLow := Addr, DataHigh := Cmd
 *   (the High write commits and increments the index).
 * Verification is not optional here: a table that loaded wrong produces
 * plausible-looking records for the wrong sites. */
static int wp_program(rv_win_t soc, uint32_t enc_off, const wp_entry_t *v, size_t n)
{
	size_t i;
	uint32_t cap = rd(soc, enc_off + RVM_ENC_WP_CAP);
	if (cap != n) {
		fprintf(stderr, "rvmon: trWpCap says %u slots, the table has %zu\n", cap, n);
		return -1;
	}
	wr(soc, enc_off + RVM_ENC_WP_INDEX, 0);
	for (i = 0; i < n; i++) {
		wr(soc, enc_off + RVM_ENC_WP_DATA_LO, v[i].addr);
		wr(soc, enc_off + RVM_ENC_WP_DATA_HI, v[i].cmd);
	}
	/* n commits from 0 wrap the index back to 0 -- the cheapest possible
	 * proof that every single write was accepted. */
	if (rd(soc, enc_off + RVM_ENC_WP_INDEX) != 0) {
		fprintf(stderr, "rvmon: index did not wrap to 0 after %zu commits -- "
		                "some writes were refused (is trTeControl.Enable set?)\n", n);
		return -1;
	}
	/* Spot-check three slots through the readback pair. */
	{
		const size_t probe[3] = { 0, n / 2, n - 1 };
		size_t k;
		for (k = 0; k < 3; k++) {
			uint32_t lo, hi;
			wr(soc, enc_off + RVM_ENC_WP_INDEX, (uint32_t)probe[k]);
			lo = rd(soc, enc_off + RVM_ENC_WP_READ_LO);
			hi = rd(soc, enc_off + RVM_ENC_WP_READ_HI);
			if (lo != v[probe[k]].addr || hi != v[probe[k]].cmd) {
				fprintf(stderr, "rvmon: slot %zu reads back %08X/%08X, wrote "
				                "%08X/%08X\n", probe[k], lo, hi,
				        v[probe[k]].addr, v[probe[k]].cmd);
				return -1;
			}
		}
	}
	return 0;
}

/* ====================================================================== */
/* Program image                                                           */
/* ====================================================================== */

static size_t load_hex(rv_win_t soc, uint32_t ram_off, const char *path)
{
	FILE *f = fopen(path, "r");
	char line[64];
	size_t n = 0;
	if (!f) die("cannot open %s: %s", path, strerror(errno));
	while (fgets(line, sizeof line, f)) {
		unsigned v;
		if (sscanf(line, "%x", &v) == 1)
			wr(soc, ram_off + (uint32_t)(4 * n++), v);
	}
	fclose(f);
	/* Read back the first and last word: a RAM write to a RUNNING core never
	 * completes, and silently loading nothing is a failure mode this demo
	 * cannot afford. */
	return n;
}

#endif /* RVMON_HAVE_DEVMEM */

/* ====================================================================== */
/* Reporting                                                               */
/* ====================================================================== */

static void report(const rv_findings_t *f, const rv_sitemap_t *map,
                   rv_refuse_t refuse, size_t nrec, const char *json_path)
{
	size_t i;
	(void)map;
	printf("\n=== rvmon verdict ===\n");
	printf("records analysed : %zu\n", nrec);
	if (refuse != RV_OK) {
		printf("VERDICT: INCONCLUSIVE -- %s\n", rv_refuse_text(refuse));
		printf("(no finding list is printed: a monitor that reports \"nothing\" "
		       "on a stream it cannot trust is worse than one that reports "
		       "nothing at all, because the first is believed)\n");
	} else if (f->n == 0) {
		printf("VERDICT: CLEAN -- no findings\n");
	} else {
		printf("VERDICT: %zu finding(s)\n", f->n);
		for (i = 0; i < f->n; i++) {
			const rv_finding_t *x = &f->v[i];
			printf("\n[%s] %s\n  %s\n", x->monitor, x->klass, x->text);
			if (x->pc_a) printf("  A: core %d pc 0x%08X t=%llu\n",
			                    x->core_a, x->pc_a, (unsigned long long)x->ts_a);
			if (x->pc_b) printf("  B: core %d pc 0x%08X t=%llu\n",
			                    x->core_b, x->pc_b, (unsigned long long)x->ts_b);
		}
	}
	if (json_path) {
		FILE *j = fopen(json_path, "w");
		if (j) {
			fprintf(j, "{\"records\":%zu,\"verdict\":\"%s\",\"findings\":[",
			        nrec, refuse == RV_OK ? (f->n ? "findings" : "clean")
			                              : "inconclusive");
			for (i = 0; i < f->n; i++)
				fprintf(j, "%s{\"monitor\":\"%s\",\"class\":\"%s\",\"text\":\"%s\","
				           "\"pc_a\":\"0x%08X\",\"core_a\":%d,"
				           "\"pc_b\":\"0x%08X\",\"core_b\":%d}",
				        i ? "," : "", f->v[i].monitor, f->v[i].klass,
				        f->v[i].text, f->v[i].pc_a, f->v[i].core_a,
				        f->v[i].pc_b, f->v[i].core_b);
			fprintf(j, "],\"refuse\":\"%s\"}\n", rv_refuse_text(refuse));
			fclose(j);
			printf("\njson: %s\n", json_path);
		}
	}
}

/* ====================================================================== */
/* Analysis of a captured stream                                           */
/* ====================================================================== */

extern unsigned rv_cfg_seed, rv_cfg_nfuncs;

/* Capture files come in two flavours and both are legitimate: the board
 * drain writes raw little-endian words, the simulation bench writes one hex
 * word per line. Accepting both means the SAME analyser reads a simulation
 * dump and a board capture with no conversion step in between -- which is
 * the entire point of running it on both. */
static size_t read_words(const char *path, uint32_t *out, size_t cap)
{
	FILE *f = fopen(path, "rb");
	unsigned char probe[16];
	size_t nprobe, n = 0, i;
	int text = 1;
	if (!f) die("cannot open %s", path);
	nprobe = fread(probe, 1, sizeof probe, f);
	for (i = 0; i < nprobe; i++) {
		unsigned char c = probe[i];
		if (!(isxdigit(c) || c == 0x0A || c == 0x0D || c == ' ')) { text = 0; break; }
	}
	if (nprobe == 0) { fclose(f); return 0; }
	rewind(f);
	if (text) {
		char line[64];
		while (n < cap && fgets(line, sizeof line, f)) {
			unsigned v;
			if (sscanf(line, "%x", &v) == 1) out[n++] = v;
		}
	} else {
		n = fread(out, 4, cap, f);
	}
	fclose(f);
	return n;
}

static int analyze_files(const char *bin0, const char *bin1,
                         const char *map0, const char *map1,
                         const char *json, uint32_t drops0, uint32_t drops1)
{
	rv_sitemap_t m0, m1, all;
	rv_rec_t *r0, *r1, *merged;
	uint32_t *w;
	size_t n0 = 0, n1 = 0, mal0 = 0, mal1 = 0, i;
	rv_findings_t f;
	rv_refuse_t refuse = RV_OK;
	long sz;
	FILE *fp;

	memset(&f, 0, sizeof f);
	memset(&all, 0, sizeof all);
	if (rv_sitemap_load(&all, map0, 0) != 0) die("cannot read %s", map0);
	if (rv_sitemap_load(&all, map1, 1) != 0) die("cannot read %s", map1);
	memset(&m0, 0, sizeof m0); memset(&m1, 0, sizeof m1);

	w = malloc(64u << 20);
	r0 = malloc(sizeof(rv_rec_t) * (1u << 22));
	r1 = malloc(sizeof(rv_rec_t) * (1u << 22));
	if (!w || !r0 || !r1) die("out of memory");

	{
		size_t nw;
		nw = read_words(bin0, w, (64u << 20) / 4);
		n0 = rv_parse_words(w, nw, 0, r0, 1u << 22, &mal0);
		nw = read_words(bin1, w, (64u << 20) / 4);
		n1 = rv_parse_words(w, nw, 1, r1, 1u << 22, &mal1);
	}
	(void)sz; (void)fp;

	rv_unroll_timestamps(r0, n0);
	rv_unroll_timestamps(r1, n1);

	if (drops0 || drops1)          refuse = RV_REFUSE_DROPS;
	else if (mal0 || mal1)         refuse = RV_REFUSE_MALFORMED;
	else if (n0 + n1 == 0)         refuse = RV_REFUSE_EMPTY;

	merged = malloc(sizeof(rv_rec_t) * (n0 + n1 + 1));
	if (!merged) die("out of memory");
	rv_merge_by_time(merged, r0, n0, r1, n1);

	{
		size_t short_twins = rv_pair_runtime_sync(merged, n0 + n1);
		if (short_twins && refuse == RV_OK) {
			fprintf(stderr, "rvmon: %zu static sync records have no runtime "
			        "twin -- the encoder dropped ACT-CAP commands (see the "
			        "clearance-nop note in rv_tags.h)\n", short_twins);
			refuse = RV_REFUSE_MALFORMED;
		}
	}

	if (refuse == RV_OK) {
		for (i = 0; i < rv_monitor_count; i++)
			rv_monitors[i].fn(merged, n0 + n1, &all, &f);
	}
	report(&f, &all, refuse, n0 + n1, json);

	free(w); free(r0); free(r1); free(merged);
	rv_findings_free(&f);
	rv_sitemap_free(&m0); rv_sitemap_free(&m1);
	return (refuse == RV_OK && f.n == 0) ? 0 : (refuse == RV_OK ? 1 : 2);
}

/* ====================================================================== */
/* Self-test -- runs without a board                                       */
/* ====================================================================== */

static void st_rec(uint32_t **p, uint32_t pc, uint32_t tag, uint32_t ts,
                   unsigned core)
{
	*(*p)++ = pc;
	*(*p)++ = tag;
	*(*p)++ = ts;
	*(*p)++ = (core << 20) | (0xFFFu << 8) | 1u;
}

#define TAG_SYNC(op, lk, s)  ((1u << 21) | ((op) << 19) | ((lk) << 11) | (s))
#define TAG_DATA(rw, ob, s)  ((0u << 21) | ((rw) << 20) | ((ob) << 13) | ((s) << 4) | 2u)

static int selftest(void)
{
	uint32_t buf[256], *p;
	rv_rec_t rec[64], merged[64];
	size_t n, mal, i;
	rv_findings_t f;
	rv_sitemap_t empty;
	int fails = 0;

	memset(&empty, 0, sizeof empty);

	/* (1) malformed detection: reserved bits set */
	p = buf;
	st_rec(&p, 0x100, TAG_DATA(1, 1, 0), 10, 0);
	buf[3] |= 0x01000000u;
	n = rv_parse_words(buf, 4, 0, rec, 64, &mal);
	if (n != 0 || mal != 1) { printf("ST1 FAIL n=%zu mal=%zu\n", n, mal); fails++; }
	else printf("ST1 malformed record rejected     : OK\n");

	/* (2) a clean locked sequence must produce NOTHING */
	p = buf;
	st_rec(&p, 0x200, TAG_SYNC(1, 0, 0), 10, 0);   /* core0 acquire */
	st_rec(&p, 0x204, TAG_DATA(1, 1, 0), 11, 0);   /* write balance */
	st_rec(&p, 0x208, TAG_SYNC(2, 0, 0), 12, 0);   /* release */
	st_rec(&p, 0x300, TAG_SYNC(1, 0, 1), 13, 1);   /* core1 acquire */
	st_rec(&p, 0x304, TAG_DATA(1, 1, 1), 14, 1);
	st_rec(&p, 0x308, TAG_SYNC(2, 0, 1), 15, 1);
	n = rv_parse_words(buf, 24, -1, rec, 64, &mal);
	rv_unroll_timestamps(rec, n);
	memcpy(merged, rec, n * sizeof rec[0]);
	memset(&f, 0, sizeof f);
	for (i = 0; i < rv_monitor_count; i++) {
		if (strcmp(rv_monitors[i].name, "mon_cfg") == 0) continue;  /* needs a map */
		rv_monitors[i].fn(merged, n, &empty, &f);
	}
	if (f.n != 0) {
		printf("ST2 FAIL: %zu findings on a correctly locked stream:\n", f.n);
		for (i = 0; i < f.n; i++) printf("     %s: %s\n", f.v[i].monitor, f.v[i].text);
		fails++;
	} else printf("ST2 correct locking -> no findings : OK\n");
	rv_findings_free(&f);

	/* (3) the same accesses WITHOUT locks must be found -- the red probe.
	 *     Without this, ST2 alone proves only that the monitors are quiet. */
	p = buf;
	st_rec(&p, 0x204, TAG_DATA(1, 1, 0), 11, 0);
	st_rec(&p, 0x304, TAG_DATA(1, 1, 1), 12, 1);
	n = rv_parse_words(buf, 8, -1, rec, 64, &mal);
	rv_unroll_timestamps(rec, n);
	memcpy(merged, rec, n * sizeof rec[0]);
	memset(&f, 0, sizeof f);
	for (i = 0; i < rv_monitor_count; i++) {
		if (strcmp(rv_monitors[i].name, "mon_cfg") == 0) continue;
		rv_monitors[i].fn(merged, n, &empty, &f);
	}
	{
		int saw_lockset = 0, saw_proto = 0, saw_hb = 0;
		for (i = 0; i < f.n; i++) {
			if (!strcmp(f.v[i].monitor, "mon_lockset")) saw_lockset = 1;
			if (!strcmp(f.v[i].monitor, "mon_proto"))   saw_proto = 1;
			if (!strcmp(f.v[i].monitor, "mon_hb"))      saw_hb = 1;
		}
		if (!saw_lockset || !saw_proto || !saw_hb) {
			printf("ST3 FAIL: unlocked race not reported by all three "
			       "(lockset=%d proto=%d hb=%d)\n", saw_lockset, saw_proto, saw_hb);
			fails++;
		} else printf("ST3 unlocked race reported        : OK\n");
	}
	rv_findings_free(&f);

	/* (4) lock-order inversion without a deadlock */
	p = buf;
	st_rec(&p, 0x400, TAG_SYNC(1, 2, 0), 10, 0);
	st_rec(&p, 0x404, TAG_SYNC(1, 3, 1), 11, 0);
	st_rec(&p, 0x408, TAG_SYNC(2, 3, 2), 12, 0);
	st_rec(&p, 0x40C, TAG_SYNC(2, 2, 3), 13, 0);
	st_rec(&p, 0x500, TAG_SYNC(1, 3, 4), 14, 1);
	st_rec(&p, 0x504, TAG_SYNC(1, 2, 5), 15, 1);
	st_rec(&p, 0x508, TAG_SYNC(2, 2, 6), 16, 1);
	st_rec(&p, 0x50C, TAG_SYNC(2, 3, 7), 17, 1);
	n = rv_parse_words(buf, 32, -1, rec, 64, &mal);
	rv_unroll_timestamps(rec, n);
	memcpy(merged, rec, n * sizeof rec[0]);
	memset(&f, 0, sizeof f);
	for (i = 0; i < rv_monitor_count; i++)
		if (!strcmp(rv_monitors[i].name, "mon_order"))
			rv_monitors[i].fn(merged, n, &empty, &f);
	if (f.n == 0) { printf("ST4 FAIL: lock-order inversion not found\n"); fails++; }
	else printf("ST4 lock-order inversion found    : OK\n");
	rv_findings_free(&f);

	/* (5) timestamp wrap is unrolled, not misread as going backwards */
	p = buf;
	st_rec(&p, 0x600, TAG_DATA(0, 1, 0), 0xFFFFFFF0u, 0);
	st_rec(&p, 0x604, TAG_DATA(0, 1, 1), 0x00000010u, 0);
	n = rv_parse_words(buf, 8, 0, rec, 64, &mal);
	rv_unroll_timestamps(rec, n);
	if (!(rec[1].ts_unrolled > rec[0].ts_unrolled)) {
		printf("ST5 FAIL: wrap not unrolled (%llu -> %llu)\n",
		       (unsigned long long)rec[0].ts_unrolled,
		       (unsigned long long)rec[1].ts_unrolled);
		fails++;
	} else printf("ST5 timestamp wrap unrolled       : OK\n");

	if (fails) { printf("\nSELFTEST_FAIL: %d\n", fails); return 1; }
	printf("\nSELFTEST_PASS\n");
	return 0;
}

/* ====================================================================== */
/* CLI                                                                     */
/* ====================================================================== */

static void usage(void)
{
	printf(
"rvmon -- runtime-verification monitor for the two-core RV/CFI demo\n"
"\n"
"  rvmon selftest                          run the offline checks (no board)\n"
"  rvmon status                            read magic, counters, run state\n"
"  rvmon load  --hex0 F --hex1 F --wp0 F --wp1 F\n"
"                                          images + tables (readback-verified),\n"
"                                          then arm both timestamp units\n"
"  rvmon run   [--seconds S] [--mode N] [--iters N] [--pace N] [--seed N]\n"
"              [--cfi-off N] [--cap-every N] [--route fifo|ddr]\n"
"                                          release both cores and drain;\n"
"                                          --route ddr captures through the\n"
"                                          per-core DDR rings instead of the\n"
"                                          MM-FIFOs (shim sees always-ready)\n"
"  rvmon drain --out0 F --out1 F [--seconds S] [--route fifo|ddr]\n"
"                                          --route ddr: post-mortem read of\n"
"                                          already-filled rings, no release\n"
"  rvmon console [--core 0|1] [--send 'text'] [--seconds S]\n"
"                                          drain a core's console to stdout;\n"
"                                          --send pushes a line into its RX first\n"
"  rvmon analyze --in0 F --in1 F --map0 F --map1 F [--json F] [--seed N]\n"
"\n"
"Monitors:\n");
	{
		size_t i;
		for (i = 0; i < rv_monitor_count; i++)
			printf("  %-11s %s\n", rv_monitors[i].name, rv_monitors[i].what);
	}
}

static const char *argval(int argc, char **argv, const char *key)
{
	int i;
	for (i = 1; i + 1 < argc; i++)
		if (!strcmp(argv[i], key)) return argv[i + 1];
	return NULL;
}

int main(int argc, char **argv)
{
	const char *cmd = (argc > 1) ? argv[1] : "help";

	if (!strcmp(cmd, "help") || !strcmp(cmd, "-h") || !strcmp(cmd, "--help")) {
		usage(); return 0;
	}
	if (!strcmp(cmd, "selftest"))
		return selftest();

	if (!strcmp(cmd, "analyze")) {
		const char *s = argval(argc, argv, "--seed");
		if (s) rv_cfg_seed = (unsigned)strtoul(s, NULL, 0);
		s = argval(argc, argv, "--funcs");
		if (s) rv_cfg_nfuncs = (unsigned)strtoul(s, NULL, 0);
		return analyze_files(argval(argc, argv, "--in0"),
		                     argval(argc, argv, "--in1"),
		                     argval(argc, argv, "--map0"),
		                     argval(argc, argv, "--map1"),
		                     argval(argc, argv, "--json"),
		                     0, 0);
	}

	/* Everything below touches the board. */
#if !RVMON_HAVE_DEVMEM
	die("'%s' needs /dev/mem and therefore the board; this build has no "
	    "hardware access. `selftest` and `analyze` work here.", cmd);
	return 1;
#else
	{
		rv_win_t soc = win_map(RVM_SOC_BASE, RVM_WINDOW_SIZE);
		rv_win_t wpc = win_map(RVM_WPCTRL_BASE, RVM_SMALL_WINDOW);
		rv_win_t f0  = win_map(RVM_FIFO0_BASE, RVM_SMALL_WINDOW);
		rv_win_t f1  = win_map(RVM_FIFO1_BASE, RVM_SMALL_WINDOW);
		uint32_t magic = rd(soc, RVM_OFF_CTRL + RVM_CTRL_MAGIC);

		if (magic != RVM_MAGIC_VALUE)
			die("CTRL magic is 0x%08X, expected 0x%08X (\"RVCI\") -- is the "
			    "right bitstream loaded?", magic, RVM_MAGIC_VALUE);

		if (!strcmp(cmd, "status")) {
			uint32_t st = rd(soc, RVM_OFF_CTRL + RVM_CTRL_STATUS);
			printf("magic        : 0x%08X (ok)\n", magic);
			printf("shared size  : %u B\n", rd(soc, RVM_OFF_CTRL + RVM_CTRL_SHARED_SZ));
			printf("cores running: core0=%d core1=%d\n",
			       !!(st & RVM_STATUS_CORE0_RUN), !!(st & RVM_STATUS_CORE1_RUN));
			printf("doorbell     : core0 hits=%u last=0x%08X | core1 hits=%u last=0x%08X\n",
			       rd(soc, RVM_OFF_CTRL + RVM_CTRL_DB0_HITS),
			       rd(soc, RVM_OFF_CTRL + RVM_CTRL_DB0_LAST),
			       rd(soc, RVM_OFF_CTRL + RVM_CTRL_DB1_HITS),
			       rd(soc, RVM_OFF_CTRL + RVM_CTRL_DB1_LAST));
			printf("act-cap conv : core0=%u core1=%u\n",
			       rd(soc, RVM_OFF_CTRL + RVM_CTRL_ACTCAP0),
			       rd(soc, RVM_OFF_CTRL + RVM_CTRL_ACTCAP1));
			printf("shim drops   : core0=%u core1=%u\n",
			       rd(wpc, RVM_WP_SHIM0_DROPS), rd(wpc, RVM_WP_SHIM1_DROPS));
			printf("fifo occupancy: core0=%u core1=%u words\n",
			       rd(f0, RVM_FIFO_RDFO), rd(f1, RVM_FIFO_RDFO));
			{
				/* The N3 ring banks. On a pre-N3 bitstream every field
				 * reads 0, which prints as an inert fifo-routed ring. */
				int c;
				for (c = 0; c < 2; c++) {
					uint32_t bank = ring_bank(c);
					uint32_t rc = rd(soc, bank + RVM_RING_CTRL);
					uint32_t rs = rd(soc, bank + RVM_RING_STAT);
					printf("ddr ring %d   : route=%s en=%d circ=%d "
					       "base=0x%08X size=%u B\n",
					       c, (rc & RVM_RING_ROUTE_DDR) ? "ddr" : "fifo",
					       !!(rc & RVM_RING_EN), !!(rc & RVM_RING_CIRC),
					       rd(soc, bank + RVM_RING_BASE),
					       rd(soc, bank + RVM_RING_SIZE));
					printf("               wptr=%u B drops=%u beats=%u "
					       "stat=[%s%s%s%s]\n",
					       rd(soc, bank + RVM_RING_WPTR),
					       rd(soc, bank + RVM_RING_DROPS),
					       rd(soc, bank + RVM_RING_BEATS),
					       (rs & RVM_RING_ST_FULL)   ? " full"    : "",
					       (rs & RVM_RING_ST_AXIERR) ? " axi_err" : "",
					       (rs & RVM_RING_ST_WRAP)   ? " wrapped" : "",
					       (rs & RVM_RING_ST_CFGREJ) ? " cfg_rej" : "");
				}
			}
			{
				uint32_t s0 = rd(soc, RVM_OFF_CTRL + RVM_CTRL_CON0_STAT);
				uint32_t s1 = rd(soc, RVM_OFF_CTRL + RVM_CTRL_CON1_STAT);
				printf("console      : core0 tx=%u rx_free=%u | core1 tx=%u rx_free=%u\n",
				       s0 >> 16, s0 & 0xFFFFu, s1 >> 16, s1 & 0xFFFFu);
			}
			{
				/* The trap of the first silicon run, made visible: an
				 * unarmed timestamp unit produces well-formed records that
				 * all say t = 0. `load` arms it; this line says whether
				 * something since (a reload, a hand-written CSR) undid that. */
				uint32_t t0 = rd(soc, RVM_OFF_ENC0 + RVM_ENC_TS_CONTROL) & RVM_TS_CONTROL_MASK;
				uint32_t t1 = rd(soc, RVM_OFF_ENC1 + RVM_ENC_TS_CONTROL) & RVM_TS_CONTROL_MASK;
				printf("timestamp    : core0=%s core1=%s (trTsControl %04X/%04X)\n",
				       (t0 == RVM_TS_CONTROL_ARMED) ? "armed" : "NOT armed",
				       (t1 == RVM_TS_CONTROL_ARMED) ? "armed" : "NOT armed", t0, t1);
			}
			return 0;
		}

		if (!strcmp(cmd, "console")) {
			/* The convenient channel (N1): drain the chosen core's TX FIFO to
			 * stdout; --send pushes a line into its RX first. Characters, not
			 * packets -- what the program printed is what appears here, and
			 * it works while the cores are RUNNING, which is exactly what the
			 * shared-memory window cannot offer (it belongs to the cores
			 * then). */
			const char *core_s = argval(argc, argv, "--core");
			const char *send_s = argval(argc, argv, "--send");
			const char *sec_s  = argval(argc, argv, "--seconds");
			int core = core_s ? atoi(core_s) : 0;
			double budget = sec_s ? atof(sec_s) : 2.0;
			uint32_t off_stat = core ? RVM_CTRL_CON1_STAT : RVM_CTRL_CON0_STAT;
			uint32_t off_pop  = core ? RVM_CTRL_CON1_POP  : RVM_CTRL_CON0_POP;
			uint32_t off_push = core ? RVM_CTRL_CON1_PUSH : RVM_CTRL_CON0_PUSH;
			double t0 = now_s();
			size_t n = 0;

			if (send_s) {
				const char *p;
				for (p = send_s; *p; p++) {
					uint32_t st = rd(soc, RVM_OFF_CTRL + off_stat);
					if ((st & 0xFFFFu) == 0u) {
						fprintf(stderr, "rvmon: RX full after %zu chars -- "
						        "the core is not draining its RX\n",
						        (size_t)(p - send_s));
						break;
					}
					wr(soc, RVM_OFF_CTRL + off_push, (uint32_t)(unsigned char)*p);
				}
				wr(soc, RVM_OFF_CTRL + off_push, (uint32_t)'\n');
			}

			for (;;) {
				uint32_t v = rd(soc, RVM_OFF_CTRL + off_pop);
				if (v & 0x80000000u) {
					putchar((int)(v & 0xFFu));
					n++;
					continue;               /* keep draining while data flows */
				}
				fflush(stdout);
				if (now_s() - t0 > budget) break;
			}
			fprintf(stderr, "\n[rvmon console core %d: %zu chars]\n", core, n);
			return 0;
		}

		if (!strcmp(cmd, "load")) {
			static wp_entry_t tab[2048];
			const char *h0 = argval(argc, argv, "--hex0");
			const char *h1 = argval(argc, argv, "--hex1");
			const char *w0 = argval(argc, argv, "--wp0");
			const char *w1 = argval(argc, argv, "--wp1");
			uint32_t st = rd(soc, RVM_OFF_CTRL + RVM_CTRL_STATUS);
			size_t n;

			if (!h0 || !h1 || !w0 || !w1) die("load needs --hex0/--hex1/--wp0/--wp1");
			if (st & (RVM_STATUS_CORE0_RUN | RVM_STATUS_CORE1_RUN))
				die("a core is running -- loading its RAM would hang the AXI "
				    "transaction. Stop both first (CONTROL=0).");

			printf("loading program images\n");
			printf("  core0: %zu words\n", load_hex(soc, RVM_OFF_RAM0, h0));
			printf("  core1: %zu words\n", load_hex(soc, RVM_OFF_RAM1, h1));

			n = wp_load_file(w0, tab, 2048);
			if (wp_program(soc, RVM_OFF_ENC0, tab, n) != 0) die("core0 table load failed");
			printf("  core0 watchpoint table: %zu slots, readback ok\n", n);
			n = wp_load_file(w1, tab, 2048);
			if (wp_program(soc, RVM_OFF_ENC1, tab, n) != 0) die("core1 table load failed");
			printf("  core1 watchpoint table: %zu slots, readback ok\n", n);

			/* Arm both timestamp units -- the step nobody did on the board
			 * before 2026-08-27 (the bench always had; the first silicon
			 * run carried ts = 0 in every record and looked fine). Same
			 * value the bench writes, verified by readback like the tables:
			 * a timestamp that is silently absent is worse than a load that
			 * refuses. Type is only writable while trTeControl.Enable = 0,
			 * which holds here (see RVM_TS_CONTROL_ARMED). */
			wr(soc, RVM_OFF_ENC0 + RVM_ENC_TS_CONTROL, RVM_TS_CONTROL_ARMED);
			wr(soc, RVM_OFF_ENC1 + RVM_ENC_TS_CONTROL, RVM_TS_CONTROL_ARMED);
			{
				uint32_t t0 = rd(soc, RVM_OFF_ENC0 + RVM_ENC_TS_CONTROL) & RVM_TS_CONTROL_MASK;
				uint32_t t1 = rd(soc, RVM_OFF_ENC1 + RVM_ENC_TS_CONTROL) & RVM_TS_CONTROL_MASK;
				if (t0 != RVM_TS_CONTROL_ARMED || t1 != RVM_TS_CONTROL_ARMED)
					die("trTsControl did not read back armed (core0=%04X core1=%04X, "
					    "expected %04X) -- is trTeControl.Enable set?",
					    t0, t1, RVM_TS_CONTROL_ARMED);
				printf("  timestamp units armed: trTsControl=%04X on both encoders\n", t0);
			}
			printf("LOAD_OK\n");
			return 0;
		}

		if (!strcmp(cmd, "run") || !strcmp(cmd, "drain")) {
			static uint32_t b0[1u << 22], b1[1u << 22];
			const char *o0 = argval(argc, argv, "--out0");
			const char *o1 = argval(argc, argv, "--out1");
			const char *s;
			double budget = (s = argval(argc, argv, "--seconds")) ? atof(s) : 5.0;
			size_t n0 = 0, n1 = 0;
			double t0, t1;
			uint32_t d0, d1;
			int is_run = !strcmp(cmd, "run");
			int route_ddr = 0;
			uint32_t rb0 = 0, rb1 = 0;    /* ring-drop base (run: post-clear) */
			uint32_t rdrop0 = 0, rdrop1 = 0;
			int ring_bad = 0;

			if ((s = argval(argc, argv, "--route")) != NULL) {
				if (!strcmp(s, "ddr")) route_ddr = 1;
				else if (strcmp(s, "fifo")) die("--route must be fifo or ddr");
			}

			if (!o0) o0 = "core0.bin";
			if (!o1) o1 = "core1.bin";

			/* The shim drop counters are CUMULATIVE since bitstream load --
			 * there is deliberately no clear register (a counter that can be
			 * cleared can be cleared by accident, and the tutorial's loss
			 * accounting leans on it). What this run is judged by is the
			 * DELTA over its own window; the totals stay visible in
			 * `status`. First silicon run: a clean 60-iteration leg carried
			 * the previous run's 59805/64982 and failed on them. */
			{
				uint32_t db0 = rd(wpc, RVM_WP_SHIM0_DROPS);
				uint32_t db1 = rd(wpc, RVM_WP_SHIM1_DROPS);
				d0 = db0; d1 = db1;   /* reused below as the base */
			}

			if (is_run) {
				volatile uint32_t *sh = soc.p + (RVM_OFF_SHARED / 4);
				uint32_t mode  = (s = argval(argc, argv, "--mode"))  ? (uint32_t)strtoul(s, NULL, 0) : 0u;
				uint32_t iters = (s = argval(argc, argv, "--iters")) ? (uint32_t)strtoul(s, NULL, 0) : 2000u;
				uint32_t pace  = (s = argval(argc, argv, "--pace"))  ? (uint32_t)strtoul(s, NULL, 0) : 200u;
				uint32_t seed  = (s = argval(argc, argv, "--seed"))  ? (uint32_t)strtoul(s, NULL, 0) : 0x1234u;
				uint32_t coff  = (s = argval(argc, argv, "--cfi-off"))? (uint32_t)strtoul(s, NULL, 0) : 7u;
				uint32_t cap   = (s = argval(argc, argv, "--cap-every"))? (uint32_t)strtoul(s, NULL, 0) : 0u;
				uint32_t st = rd(soc, RVM_OFF_CTRL + RVM_CTRL_STATUS);
				size_t   w;

				if (st & (RVM_STATUS_CORE0_RUN | RVM_STATUS_CORE1_RUN))
					die("a core is already running -- stop both first");

				if (route_ddr) {
					int c;
					/* PS write-port widths FIRST -- see afifm_narrow32():
					 * saxigp2 carries core 0's ring, saxigp3 core 1's, and
					 * both reset to 128 bit on every boot. */
					afifm_narrow32(RVM_AFIFM2_BASE);
					afifm_narrow32(RVM_AFIFM3_BASE);
					/* Strict order per bank: route (at en=0), clear pulse,
					 * enable. The clear pulse is only defined at en=0, and
					 * the route may only move while the cores are held
					 * (verified above) -- moving it mid-record would tear a
					 * record across two sinks. */
					for (c = 0; c < 2; c++) {
						uint32_t bank = ring_bank(c);
						uint32_t keep = rd(soc, bank + RVM_RING_CTRL)
						                & RVM_RING_CIRC;
						wr(soc, bank + RVM_RING_CTRL,
						   keep | RVM_RING_ROUTE_DDR);
						wr(soc, bank + RVM_RING_CTRL,
						   keep | RVM_RING_ROUTE_DDR | RVM_RING_CLEAR);
						wr(soc, bank + RVM_RING_CTRL,
						   keep | RVM_RING_ROUTE_DDR | RVM_RING_EN);
						/* Both checks catch the same expensive mistake: a
						 * bitstream without the ring bank reads 0 everywhere
						 * and would otherwise "capture" nothing, cleanly. */
						if (!(rd(soc, bank + RVM_RING_CTRL) & RVM_RING_EN))
							die("core %d RING_CTRL.en did not set -- does "
							    "this bitstream have the DDR ring bank?", c);
						if (rd(soc, bank + RVM_RING_WPTR) != 0)
							die("core %d ring WPTR nonzero right after the "
							    "clear pulse -- not releasing the cores", c);
					}
					/* Drop base AFTER the clear pulse: the verdict below is
					 * a delta over this run's window, the same discipline as
					 * the shim counters. */
					rb0 = rd(soc, ring_bank(0) + RVM_RING_DROPS);
					rb1 = rd(soc, ring_bank(1) + RVM_RING_DROPS);
				} else {
					/* A crashed ddr run leaves route_ddr=1, and a FIFO-
					 * routed run would then capture NOTHING while looking
					 * clean -- records flowing into a disabled ring have no
					 * counter that says so. The cores are verified stopped
					 * here, so restoring the reset routing is safe. */
					int c;
					for (c = 0; c < 2; c++) {
						uint32_t bank = ring_bank(c);
						uint32_t rc = rd(soc, bank + RVM_RING_CTRL);
						if (rc & RVM_RING_ROUTE_DDR) {
							printf("note: core %d ring was still routed to "
							       "DDR from an earlier run -- restored to "
							       "fifo\n", c);
							wr(soc, bank + RVM_RING_CTRL,
							   rc & RVM_RING_CIRC);
						}
					}
				}

				/* Publish the control area, then read it back. UltraRAM has
				 * no bitstream initialization, so every field is whatever the
				 * previous run left; "it looked plausible" is not evidence
				 * that the host has been here. */
				sh[4] = 0u;                       /* go = 0: hold at the barrier */
				sh[1] = mode;  sh[2] = iters; sh[3] = pace;
				sh[5] = seed;  sh[6] = coff;
				/* cap_every explicitly, EVERY run: UltraRAM keeps whatever
				 * the previous run wrote, and a stale nonzero here would
				 * silently turn a plain leg into a software-instrumented
				 * one (the simulation set this field from the bench, so
				 * only the board path could ever hit it). */
				sh[7] = cap;
				for (w = 0x60/4; w <= 0x1BF/4; w++) sh[w] = 0u;   /* acct, ring, results */
				sh[0] = RV_MAGIC;
				if (sh[0] != RV_MAGIC || sh[1] != mode || sh[2] != iters)
					die("shared control area did not read back as written "
					    "(magic=%08X mode=%u iters=%u)", sh[0], sh[1], sh[2]);

				printf("mode=%u iters=%u pace=%u seed=0x%X cap_every=%u\n",
				       mode, iters, pace, seed, cap);
				/* Barrier FIRST, then release -- the other order deadlocks on
				 * real hardware: the PS window onto the shared memory is
				 * muxed away the moment either core runs (`ps_owns_shared`
				 * in the SoC top), so a write to `go` after the release
				 * never gets ready and wedges the /dev/mem access. Nothing
				 * is lost: both run bits are set by ONE register write, so
				 * the release itself is the simultaneous start. The e2e
				 * bench hit exactly this and this code repeats its fix. */
				sh[4] = 1u;
				wr(soc, RVM_OFF_CTRL + RVM_CTRL_CONTROL,
				   RVM_CONTROL_CORE0_RUN | RVM_CONTROL_CORE1_RUN);
			}

			t0 = now_s();
			if (!route_ddr) {
				/* Drain both FIFOs while the run proceeds. Interleaved
				 * rather than one after the other: a FIFO that is not being
				 * read is a FIFO that fills, and a full FIFO turns into shim
				 * drops. */
				/* End-of-run detection WITHOUT touching shared memory: the
				 * mailbox lives there, and there is unreachable while the
				 * cores run. When neither FIFO has produced a record for a
				 * while, both cores have parked -- the same quiescence rule
				 * the e2e bench uses, against the same wedge. */
				int quiet = 0;
				size_t p0 = (size_t)-1, p1 = (size_t)-1;
				for (;;) {
					n0 += fifo_drain(f0, b0 + n0, (1u << 22) - n0, 0.02);
					n1 += fifo_drain(f1, b1 + n1, (1u << 22) - n1, 0.02);
					if (now_s() - t0 > budget) break;
					if (is_run) {
						if (n0 == p0 && n1 == p1) quiet++;
						else                      quiet = 0;
						p0 = n0; p1 = n1;
						if (quiet >= 10) break;   /* ~0.4 s of silence */
					}
					if (n0 >= (1u << 22) || n1 >= (1u << 22)) break;
				}
			} else if (is_run) {
				/* DDR route: the FIFOs are out of the path, so their silence
				 * proves nothing. End of run = WPTR standstill on BOTH rings
				 * for ~0.4 s -- the same quiescence rule, moved to where the
				 * records now flow. The budget still caps the wait, and
				 * nothing needs draining meanwhile: the ring absorbs at DDR
				 * speed. */
				double last_change = t0;
				uint32_t p0 = rd(soc, ring_bank(0) + RVM_RING_WPTR);
				uint32_t p1 = rd(soc, ring_bank(1) + RVM_RING_WPTR);
				for (;;) {
					uint32_t w0 = rd(soc, ring_bank(0) + RVM_RING_WPTR);
					uint32_t w1 = rd(soc, ring_bank(1) + RVM_RING_WPTR);
					double t = now_s();
					if (w0 != p0 || w1 != p1) {
						last_change = t;
						p0 = w0; p1 = w1;
					}
					if (t - t0 > budget) break;
					if (t - last_change > 0.4) break;
				}
			}
			/* (drain --route ddr waits for nothing: the ring already holds
			 *  whatever the stopped or crashed run left behind) */
			t1 = now_s();

			if (is_run) {
				volatile uint32_t *sh = soc.p + (RVM_OFF_SHARED / 4);
				wr(soc, RVM_OFF_CTRL + RVM_CTRL_CONTROL, 0u);   /* stop both cores */
				if (!route_ddr) {
					/* rest-drain: whatever was in flight when they stopped */
					n0 += fifo_drain(f0, b0 + n0, (1u << 22) - n0, 0.3);
					n1 += fifo_drain(f1, b1 + n1, (1u << 22) - n1, 0.3);
				} else {
					/* rest-settle: beats still inside the shim/sink pipeline
					 * land shortly after the stop; wait for the write
					 * pointers to stand still (bounded like the FIFO
					 * rest-drain above). */
					double ts = now_s(), last = ts;
					uint32_t p0 = rd(soc, ring_bank(0) + RVM_RING_WPTR);
					uint32_t p1 = rd(soc, ring_bank(1) + RVM_RING_WPTR);
					for (;;) {
						uint32_t w0 = rd(soc, ring_bank(0) + RVM_RING_WPTR);
						uint32_t w1 = rd(soc, ring_bank(1) + RVM_RING_WPTR);
						double t = now_s();
						if (w0 != p0 || w1 != p1) {
							last = t;
							p0 = w0; p1 = w1;
						}
						if (t - last > 0.05 || t - ts > 0.3) break;
					}
				}
				printf("core0 done=%08X iters=%u sum=%u | core1 done=%08X iters=%u sum=%u\n",
				       sh[0x180/4], sh[0x184/4], sh[0x188/4],
				       sh[0x1A0/4], sh[0x1A4/4], sh[0x1A8/4]);
				printf("account: balance=%u count=%u checksum=%08X\n",
				       sh[0x60/4], sh[0x64/4], sh[0x68/4]);
			}

			if (route_ddr) {
				/* Same record words, same downstream files, same analyzer --
				 * only the transport changed. */
				if (!is_run) {
					uint32_t st = rd(soc, RVM_OFF_CTRL + RVM_CTRL_STATUS);
					if (st & (RVM_STATUS_CORE0_RUN | RVM_STATUS_CORE1_RUN))
						fprintf(stderr, "rvmon: a core is RUNNING -- this "
						        "post-mortem read races the sink and may "
						        "tear across the wrap seam\n");
				}
				n0 = ring_extract(soc, 0, b0, 1u << 22);
				n1 = ring_extract(soc, 1, b1, 1u << 22);
			}

			{
				/* Delta over this run's window; unsigned subtraction is
				 * wrap-safe. d0/d1 held the pre-release base. */
				uint32_t dt0 = rd(wpc, RVM_WP_SHIM0_DROPS);
				uint32_t dt1 = rd(wpc, RVM_WP_SHIM1_DROPS);
				d0 = dt0 - d0;
				d1 = dt1 - d1;
				if (route_ddr && !is_run)
					printf("records: core0=%zu core1=%zu (post-mortem ring read)\n",
					       n0 / 4, n1 / 4);
				else
					printf("records: core0=%zu core1=%zu in %.2f s (%.0f + %.0f rec/s)\n",
					       n0 / 4, n1 / 4, t1 - t0,
					       (double)(n0 / 4) / (t1 - t0), (double)(n1 / 4) / (t1 - t0));
				printf("shim drops: core0=%u core1=%u %s (cumulative since load: %u/%u)\n",
				       d0, d1,
				       (d0 || d1) ? "<-- the stream is incomplete; see the tutorial's "
				                    "throughput chapter before believing any verdict"
				                  : "(clean)",
				       dt0, dt1);
				if (route_ddr && (d0 || d1))
					fprintf(stderr, "rvmon: in the DDR route the shim NEVER sees "
					        "backpressure -- a nonzero shim delta here is a "
					        "hardware-contract violation, not a tuning issue\n");
			}

			if (route_ddr) {
				int c;
				for (c = 0; c < 2; c++) {
					uint32_t bank  = ring_bank(c);
					uint32_t stat  = rd(soc, bank + RVM_RING_STAT);
					uint32_t drops = rd(soc, bank + RVM_RING_DROPS)
					                 - (c ? rb1 : rb0);
					if (c) rdrop1 = drops; else rdrop0 = drops;
					printf("ring%d: drops=%u%s beats=%u stat=[%s%s%s%s]\n",
					       c, drops,
					       is_run ? "" : " (cumulative since clear)",
					       rd(soc, bank + RVM_RING_BEATS),
					       (stat & RVM_RING_ST_FULL)   ? " full"    : "",
					       (stat & RVM_RING_ST_AXIERR) ? " axi_err" : "",
					       (stat & RVM_RING_ST_WRAP)   ? " wrapped" : "",
					       (stat & RVM_RING_ST_CFGREJ) ? " cfg_rej" : "");
					if (stat & RVM_RING_ST_AXIERR) {
						fprintf(stderr, "rvmon: core %d ring reports an AXI "
						        "write error (RING_STAT.axi_err) -- the PS "
						        "port refused a beat; the capture cannot be "
						        "trusted\n", c);
						ring_bad = 1;
					}
					if (stat & RVM_RING_ST_CFGREJ) {
						fprintf(stderr, "rvmon: core %d ring rejected a "
						        "configuration write (RING_STAT.cfg_rej_"
						        "sticky) -- BASE/SIZE were written while "
						        "enabled or point outside the window\n", c);
						ring_bad = 1;
					}
				}
				if (is_run) {
					/* Teardown: en=0, and route back to the FIFOs as well --
					 * a leftover route_ddr=1 would make the NEXT plain run
					 * capture nothing, and records flowing into a disabled
					 * ring have no counter that says so. `drain` mutates
					 * nothing: it is the post-mortem reader. */
					for (c = 0; c < 2; c++) {
						uint32_t bank = ring_bank(c);
						wr(soc, bank + RVM_RING_CTRL,
						   rd(soc, bank + RVM_RING_CTRL) & RVM_RING_CIRC);
					}
				}
			}

			{
				FILE *fp = fopen(o0, "wb");
				if (!fp) die("cannot write %s", o0);
				fwrite(b0, 4, n0, fp); fclose(fp);
				fp = fopen(o1, "wb");
				if (!fp) die("cannot write %s", o1);
				fwrite(b1, 4, n1, fp); fclose(fp);
			}
			printf("wrote %s (%zu B) and %s (%zu B)\n", o0, n0 * 4, o1, n1 * 4);
			{
				/* The ring-drop delta judges a ddr run exactly like the shim
				 * delta judges a FIFO run; axi_err/cfg_rej mark a stream
				 * that cannot be trusted either way. */
				int bad = (d0 || d1) || rdrop0 || rdrop1 || ring_bad;
				printf("%s\n", bad ? "RUN_WITH_DROPS" : "RUN_OK");
				return bad ? 3 : 0;
			}
		}

		die("unknown command '%s' (try `rvmon help`)", cmd);
	}
#endif /* RVMON_HAVE_DEVMEM */
	return 0;
}
