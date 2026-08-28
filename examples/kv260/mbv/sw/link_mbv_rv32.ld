/* SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
 * SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
 *
 * Linker script for the MicroBlaze-V RV32 bare-metal test programs.
 *
 * The memory base and length are bound to the mbv example SoC's LMB BRAM
 * (128 KiB @ 0x0, see ../rtl/mbv_soc_top.sv MEM_WORDS and
 * ../fpga/create_bd.tcl's C_BASE_VECTORS). Default 0x0 is the MicroBlaze-V
 * standard reset vector. RV32 without the C extension (baseline) -> every
 * instruction is 4 bytes, except rvc_test.S which is built separately with
 * rv32imc (see ../sw/Makefile).
 *
 * Migrated from an internal predecessor repository
 * (2026-08-17).
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 128K
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
