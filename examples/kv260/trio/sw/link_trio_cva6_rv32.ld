/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Linker script for the trio example's CVA6 branch (cv32a60x, RV32IMA,
 * M-mode only). Same layout as ../../mbv/sw/link_mbv_rv32.ld -- only the
 * origin differs, and that is the whole point of a separate file:
 *
 *   mbv   ORIGIN 0x0000_0000   the MicroBlaze V's own LMB BRAM
 *   trio  ORIGIN 0x6400_0000   the reserved PS-DDR window, which is where
 *                              this core has its code and data (it has no
 *                              local RAM at all) and where BOOT_ADDR points
 *                              (see ../rtl/trio_soc_top.sv and
 *                              ../../SPEC_board_memory_map.md §1)
 *
 * Everything else -- the reset-vector rule, the .bss alignment requirement
 * that crt0's word stores impose -- is inherited unchanged and documented in
 * the mbv script. Read that one for the reasoning.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	RAM (rwx) : ORIGIN = 0x64000000, LENGTH = 1M
}

_stack_size = 4K;

SECTIONS
{
	/* Reset vector: crt0's _start MUST sit at ORIGIN(RAM) (= C_BASE_VECTORS). */
	.text.init ORIGIN(RAM) : { KEEP(*(.text.init)) } > RAM

	.text : {
		*(.text .text.*)
	} > RAM

	.rodata : {
		*(.rodata .rodata.*)
		*(.srodata .srodata.*)
	} > RAM

	.data : {
		*(.data .data.*)
		*(.sdata .sdata.*)
	} > RAM

	.bss (NOLOAD) : {
		/* REQUIRED: crt0 zeroes .bss with WORD stores (sw) -> _bss_start MUST be
		 * 4-byte aligned. Without this ALIGN, an RVC build's .text could end on a
		 * 2-byte boundary -> _bss_start unaligned -> `sw x0,0(t0)` traps
		 * MISALIGNED_STORE (cause 6) before crt0 even sets mtvec -> trap to vector 0
		 * -> infinite restart. (Found empirically during an RVC-focused measurement
		 * run.) */
		. = ALIGN(4);
		_bss_start = .;
		*(.sbss .sbss.*)
		*(.bss .bss.*)
		*(COMMON)
		. = ALIGN(4);
		_bss_end = .;
	} > RAM

	. = ALIGN(16);
	_stack_bottom = .;
	. = . + _stack_size;
	. = ALIGN(16);
	_stack_top = .;

	_end = .;

	/DISCARD/ : { *(.comment) *(.note .note.*) *(.riscv.attributes) }
}
