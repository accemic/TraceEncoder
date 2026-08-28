/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Linker script for rvcfi_demo (after the common/tgc5b prog/ pattern).
 * Everything is placed contiguously from address 0 (the core's reset vector
 * and the RAM base) so the resulting flat binary loads into the
 * word-addressed SoC RAM via $readmemh from index 0, or word-wise via
 * devmem on the board.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
	. = 0x00000000;
	.text   : { *(.text.start) *(.text*) } > RAM
	.rodata : { *(.rodata*) } > RAM
	.data   : { *(.data*) }   > RAM
	. = ALIGN(4);
	__bss_start = .;
	.bss    : { *(.sbss*) *(.bss*) } > RAM
	. = ALIGN(4);
	__bss_end = .;
	. = ALIGN(4);
	_end = .;
}
