/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * branch_test.c -- call/return classification: direct call, function body,
 * return, indirect call, indirect return.
 *
 * Covers the decoder's `itype` jump classes that follow from JAL/JALR + the
 * link-register relationship:
 *   - direct call   -> JAL rd=x1(ra)                -> INFERRABLE_CALL
 *   - return        -> JALR rd=x0, rs1=x1(ra)       -> RETURN
 *   - indirect call -> JALR rd=x1(ra), rs1=funcptr  -> UNINFERABLE_CALL
 * The compiler emits the concrete instructions; the exact itype expectation
 * is checked against the disassembly (oracle) and the decoder's own
 * classification. `-fno-inline` + `noinline` force real call/return edges
 * (otherwise the optimizer would fold them away and trace attribution would
 * break).
 */

/* volatile sink, so the optimizer cannot eliminate the calls. */
static volatile int g_sink;

__attribute__((noinline)) int leaf_add(int a, int b)
{
	/* function body */
	int r = a + b;
	r ^= (a << 1);
	return r;                       /* JALR x0, ra -> RETURN */
}

__attribute__((noinline)) int leaf_mul(int a, int b)
{
	int r = 0;
	for (int i = 0; i < b; i++)     /* a small internal branch loop */
		r += a;
	return r;                       /* RETURN */
}

/* function-pointer type for the indirect call. */
typedef int (*binop_t)(int, int);

/* volatile, so the compiler cannot devirtualize the call (a real JALR). */
static binop_t volatile g_op = leaf_mul;

int main(void)
{
	int x = 3, y = 4;

	/* direct call (JAL ra, leaf_add) -> INFERRABLE_CALL, then RETURN */
	int s = leaf_add(x, y);
	g_sink = s;

	/* indirect call through a function pointer (JALR ra, rs1) -> UNINFERABLE_CALL, then RETURN */
	binop_t op = g_op;
	int p = op(x, y);
	g_sink = p;

	/* a mixed sequence so call edges stand out clearly in the trace */
	for (int i = 0; i < 3; i++) {
		s = leaf_add(s, i);         /* repeated direct call/return */
		g_sink = s;
	}

	return s + p;                   /* RETURN to crt0 */
}
