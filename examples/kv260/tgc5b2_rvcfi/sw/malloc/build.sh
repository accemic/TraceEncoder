#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Build the malloc demo for both cores: the rvcfi startup + linker script,
# but linked against newlib (nano) instead of -nostdlib. Outputs here:
#   malloc_core<N>.{elf,dis,sym,hex}   and   wp_table_none.txt (1023 empty slots)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/src"
rvsrc="$here/../src"
RAM_BYTES="${RAM_BYTES:-65536}"

if [ -z "${CROSS:-}" ]; then
	if command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then CROSS=riscv32-unknown-elf-
	elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then CROSS=riscv64-unknown-elf-
	else echo "[build] ERROR: no RISC-V toolchain (set CROSS=)" >&2; exit 1; fi
fi
GCC="${CROSS}gcc"; OBJCOPY="${CROSS}objcopy"; OBJDUMP="${CROSS}objdump"; NM="${CROSS}nm"
MARCH="${MARCH:-rv32i_zicsr}"

CFLAGS="-march=$MARCH -mabi=ilp32 -O2 -g -ffreestanding -fno-builtin -fno-common \
	-Wall -Wextra -Werror -I$src -I$rvsrc"
# newlib nano: malloc/free with the small footprint; nosys supplies the stubs
# the demo never calls (write, close, ...). _sbrk is the program's own.
LDFLAGS="-nostartfiles -specs=nano.specs -specs=nosys.specs -T $rvsrc/prog.ld \
	-Wl,--no-warn-rwx-segments -Wl,--gc-sections"

echo "[build] CROSS=$CROSS  MARCH=$MARCH"
for core in 0 1; do
	out="$here/malloc_core${core}"
	"$GCC" $CFLAGS -DRV_CORE=$core $LDFLAGS "$rvsrc/crt0.S" "$src/malloc_demo.c" -o "${out}.elf"
	"$OBJDUMP" -d -S "${out}.elf" > "${out}.dis"
	"$NM" -n "${out}.elf" > "${out}.sym"
	"$OBJCOPY" -O binary "${out}.elf" "${out}.bin"
	size=$(wc -c < "${out}.bin")
	if [ "$size" -gt "$RAM_BYTES" ]; then echo "[build] ERROR: image $size B > RAM $RAM_BYTES B" >&2; exit 2; fi
	od -An -tx4 -v -w4 "${out}.bin" | tr -d ' ' | grep -v '^$' > "${out}.hex"
	heap_lo=$(grep -E ' _end$' "${out}.sym" | awk '{print $1}')
	echo "[build] core $core: ${size} B / ${RAM_BYTES} B  ($(wc -l < "${out}.hex") words), heap from 0x${heap_lo} to 0xD000"
	rm -f "${out}.bin"
done

# A watchpoint table with no live site: rvmon load insists on exactly
# trWpCap (1023) entries, and the encoder's search tree wants strictly
# ascending, unique keys (gen_sites.py, "programming rules"). Odd addresses
# above the 64 KiB RAM can never be a retired PC; the NONE command on top.
{
	echo "# malloc demo: no ACT-ST sites -- 1023 padding slots (odd, ascending, above RAM)"
	python3 -c 'print("\n".join("%08X 00000000" % (0x00010001 + 2*i) for i in range(1023)))'
} > "$here/wp_table_none.txt"
echo "BUILD_OK"
