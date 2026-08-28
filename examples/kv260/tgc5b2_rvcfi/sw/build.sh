#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Build the two RV/CFI demo programs (after the tgc5b2_axis_wp sw/ pattern).
#
# Inputs (src/): crt0.S prog.ld main.c rv_*.h and the GENERATED
# rv_funcs_core{0,1}.c + rv_funcs.h -- re-run `py gen_program.py` before
# building if you changed the generator.
#
# Outputs (this directory; the .elf is gitignored, everything else committed
# so a sim or board run needs neither toolchain nor Python):
#   rvcfi_core<N>.elf   linked ELF
#   rvcfi_core<N>.dis   objdump -d disassembly  (input for gen_sites.py)
#   rvcfi_core<N>.hex   $readmemh image, one 32-bit word per line
#   rvcfi_core<N>.sym   symbol table            (input for gen_sites.py)
#
# Toolchain: override with CROSS=... ; auto-detection order is
# riscv32-unknown-elf- (PATH) -> riscv64-unknown-elf- (PATH) -> the SysGCC
# install C:/SysGCC/risc-v/bin (GCC 10.1.0).
#
# -march: rv32i_zicsr is probed first; GCC 10.1.0 rejects the _zicsr suffix
# but its default ISA spec 2.2 includes the CSR instructions in plain rv32i.
#
# Size guard: the image must fit the core's RAM. A silent overflow would
# show up much later as a program that behaves almost right, so the build
# refuses instead.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/src"
RAM_BYTES="${RAM_BYTES:-65536}"

# --- toolchain -------------------------------------------------------------
if [ -z "${CROSS:-}" ]; then
	if command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
		CROSS=riscv32-unknown-elf-
	elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
		CROSS=riscv64-unknown-elf-
	elif [ -x /c/SysGCC/risc-v/bin/riscv64-unknown-elf-gcc.exe ]; then
		CROSS=/c/SysGCC/risc-v/bin/riscv64-unknown-elf-
	else
		echo "[build] ERROR: no RISC-V toolchain found (set CROSS=)" >&2
		exit 1
	fi
fi
GCC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"
OBJDUMP="${CROSS}objdump"
NM="${CROSS}nm"

march_ok() {
	echo 'int main(void){return 0;}' > "$here/.march_probe.c"
	"$GCC" -march="$1" -mabi=ilp32 -c "$here/.march_probe.c" \
		-o "$here/.march_probe.o" >/dev/null 2>&1
	local rc=$?
	rm -f "$here/.march_probe.c" "$here/.march_probe.o"
	return $rc
}
MARCH="${MARCH:-}"
if [ -z "$MARCH" ]; then
	if march_ok rv32i_zicsr; then MARCH=rv32i_zicsr; else MARCH=rv32i; fi
fi

LDFLAGS_EXTRA=""
if "$GCC" -Wl,--no-warn-rwx-segments -nostdlib -march="$MARCH" -mabi=ilp32 \
	-x c /dev/null -o /dev/null >/dev/null 2>&1; then
	LDFLAGS_EXTRA="-Wl,--no-warn-rwx-segments"
fi

CFLAGS="-march=$MARCH -mabi=ilp32 -O2 -g -ffreestanding -fno-builtin \
	-fno-common -Wall -Wextra -Werror -I$src"
LDFLAGS="-nostdlib -nostartfiles -T $src/prog.ld $LDFLAGS_EXTRA"

# RV32I has no hardware divide, so `%` becomes a call to __umodsi3 -- which
# -nostdlib leaves unresolved. Link libgcc explicitly rather than banning the
# operator: the alternative is masking tricks that only work while the table
# sizes stay powers of two, and a demo whose arithmetic silently constrains
# `--funcs` is a trap for whoever changes it next. The routine is
# register-only and carries no instrumentation labels, so it contributes
# nothing to the record stream.
LIBGCC="$("$GCC" -march="$MARCH" -mabi=ilp32 -print-libgcc-file-name)"
if [ ! -f "$LIBGCC" ]; then
	echo "[build] ERROR: libgcc not found for -march=$MARCH ($LIBGCC)" >&2
	exit 3
fi

echo "[build] CROSS=$CROSS  MARCH=$MARCH"

for core in 0 1; do
	out="$here/rvcfi_core${core}"
	echo "[build] core $core"
	"$GCC" $CFLAGS -DRV_CORE=$core $LDFLAGS \
		"$src/crt0.S" "$src/main.c" "$src/rv_funcs_core${core}.c" \
		"$LIBGCC" -o "${out}.elf"

	"$OBJDUMP" -d -S "${out}.elf" > "${out}.dis"
	"$NM" -n "${out}.elf" > "${out}.sym"
	"$OBJCOPY" -O binary "${out}.elf" "${out}.bin"

	size=$(wc -c < "${out}.bin")
	if [ "$size" -gt "$RAM_BYTES" ]; then
		echo "[build] ERROR: core $core image is $size B, RAM is $RAM_BYTES B." >&2
		echo "[build]        Reduce --funcs in gen_program.py, or raise MEM_WORDS" >&2
		echo "[build]        in the SoC top (and RAM_BYTES here) to match." >&2
		exit 2
	fi

	# $readmemh image: one 32-bit little-endian word per line.
	od -An -tx4 -v -w4 "${out}.bin" | tr -d ' ' | grep -v '^$' > "${out}.hex"
	words=$(wc -l < "${out}.hex")
	echo "[build]   ${size} B / ${RAM_BYTES} B  (${words} words)"
	rm -f "${out}.bin"
done

# Regenerate the watchpoint tables and the site map in the SAME step.
#
# They are derived from the ELF's symbol addresses, so ANY code change moves
# them. Leaving that to be remembered is not a workflow, it is a trap: a
# stale table shifts every tag by one site, and the result is not an error
# message but a plausible-looking record stream that means something else.
#
# Measured here on 2026-08-25. A rebuild moved the code by 12 bytes, the
# tables were not regenerated, and every lock acquisition vanished from the
# analysis -- a correctly locked run produced 13 "findings", all of them
# fiction. Nothing warned; the records were well-formed and the tags valid,
# just one site off.
PY="${PY:-}"
if [ -z "$PY" ]; then
	if command -v py >/dev/null 2>&1; then PY=py; else PY=python3; fi
fi
echo "[build] regenerating tables + site map"
"$PY" "$here/gen_sites.py" || {
	echo "[build] ERROR: gen_sites.py failed -- the tables do NOT match the" >&2
	echo "[build]        binaries now. Do not run with them." >&2
	exit 4
}

echo "BUILD_OK"
