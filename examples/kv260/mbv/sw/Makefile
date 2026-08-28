# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Builds the RV32 bare-metal test programs for the mbv KV260 example. Builds,
# per program, an ELF + disassembly (.dump) + a static oracle CSV
# (.oracle.csv). Toolchain verified: riscv64-unknown-elf-gcc (GCC 10.1.0,
# rv32im/ilp32 multilib). Invocation (git-bash or the toolchain's make.exe): make
#
# This Makefile is Vivado-independent: it produces the stimulus + the static
# oracle. The actual TRACE-bus comparison happens in Vivado XSIM/on the FPGA
# (see ../README.md).
#
# Migrated from an internal predecessor repository
# (2026-08-17).

RISCV_BIN ?= C:/SysGCC/risc-v/bin
CROSS     ?= riscv64-unknown-elf-
CC        := $(RISCV_BIN)/$(CROSS)gcc
OBJDUMP   := $(RISCV_BIN)/$(CROSS)objdump
OBJCOPY   := $(RISCV_BIN)/$(CROSS)objcopy
SIZE      := $(RISCV_BIN)/$(CROSS)size
PYTHON    ?= py

# Baseline: RV32, C extension OFF. rv32im covers the MicroBlaze-V baseline ISA;
# CSR instructions (mtvec/mret/ecall) are part of base-I under GCC 10.1. If a
# newer binutils rejects that and demands csr explicitly: set MARCH=rv32im_zicsr.
MARCH ?= rv32im
MABI  ?= ilp32

CFLAGS  := -march=$(MARCH) -mabi=$(MABI) -Os -g -ffreestanding -fno-inline \
           -fno-builtin -fno-common -Wall -Wextra -mcmodel=medany
ASFLAGS := -march=$(MARCH) -mabi=$(MABI) -g
LDFLAGS := -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
           -T link_mbv_rv32.ld -Wl,--gc-sections -Wl,-Map,

BUILD := build
STARTUP := crt0.S
LDSCRIPT := link_mbv_rv32.ld

# oracle/memh/coe/syms use three small Python helpers that live in this
# repository's scripts/ (migrated from the predecessor repository/tools on 2026-08-17, R1 of
# the consolidation): the retired-PC oracle from objdump, the $readmemh/COE
# BRAM init from the raw binary, and the nm symbol map as JSON.
ORACLE_TOOL ?= ../../../../scripts/objdump_to_oracle.py
MEMH_TOOL   ?= ../../../../scripts/bin_to_memh.py
NM_TOOL     ?= ../../../../scripts/nm_to_json.py
NM          := $(RISCV_BIN)/$(CROSS)nm

# Test programs (source -> program name)
ASM_TESTS := trace_test trap_test illegal_test misaligned_test sijump_test jalr_storm_test rob_stress
C_TESTS   := branch_test interrupt_test data_trace_test
TESTS     := $(ASM_TESTS) $(C_TESTS)

ELFS    := $(addprefix $(BUILD)/,$(addsuffix .elf,$(TESTS)))
DUMPS   := $(addprefix $(BUILD)/,$(addsuffix .dump,$(TESTS)))
ORACLES := $(addprefix $(BUILD)/,$(addsuffix .oracle.csv,$(TESTS)))

MEMHS := $(addprefix $(BUILD)/,$(addsuffix .memh,$(TESTS)))
BINS  := $(addprefix $(BUILD)/,$(addsuffix .bin,$(TESTS)))
SYMS  := $(addprefix $(BUILD)/,$(addsuffix .syms.json,$(TESTS)))

.PRECIOUS: $(BUILD)/%.bin
.PHONY: all elf dump oracle memh coe size syms clean
coe: $(addprefix $(BUILD)/,$(addsuffix .coe,$(TESTS)))
syms: $(SYMS)
all: elf dump size
elf:    $(ELFS)
dump:   $(DUMPS)
oracle: $(ORACLES)
memh:   $(MEMHS)

$(BUILD):
	mkdir -p $(BUILD)

# --- SPECIAL CASE rvc_test: built with the C extension (RVC raw-encoding
# measurement, NOT part of the baseline). The baseline is RV32-without-C; this
# one program needs rv32imc to actually generate 16-bit instructions. crt0.S
# stays uncompressed via `.option norvc`.
$(BUILD)/rvc_test.elf: rvc_test.S $(STARTUP) $(LDSCRIPT) | $(BUILD)
	$(CC) -march=rv32imc -mabi=$(MABI) -g -nostdlib -nostartfiles -T $(LDSCRIPT) \
	      -Wl,-Map,$(BUILD)/rvc_test.map -o $@ $(STARTUP) $<
	$(SIZE) $@

# --- Assembly programs: crt0 + <test>.S -----------------------------------
$(BUILD)/%.elf: %.S $(STARTUP) $(LDSCRIPT) | $(BUILD)
	$(CC) $(ASFLAGS) -nostdlib -nostartfiles -T $(LDSCRIPT) \
	      -Wl,-Map,$(BUILD)/$*.map -o $@ $(STARTUP) $<
	$(SIZE) $@

# --- C programs: crt0 + <test>.c -------------------------------------------
$(BUILD)/%.elf: %.c $(STARTUP) $(LDSCRIPT) | $(BUILD)
	$(CC) $(CFLAGS) -nostdlib -nostartfiles -T $(LDSCRIPT) \
	      -Wl,-Map,$(BUILD)/$*.map -Wl,--gc-sections -o $@ $(STARTUP) $<
	$(SIZE) $@

# --- Disassembly (human-readable static program image) ---------------------
$(BUILD)/%.dump: $(BUILD)/%.elf
	$(OBJDUMP) -d -M no-aliases,numeric $< > $@

# --- Static oracle CSV (addr,word,mnemonic,cf_class,itype_candidate) -------
# no-aliases,numeric is mandatory: the alias form hides rd -> itype misclassification.
$(BUILD)/%.oracle.csv: $(BUILD)/%.elf
	$(OBJDUMP) -d -M no-aliases,numeric $< | $(PYTHON) $(ORACLE_TOOL) > $@

# --- Raw binary + 32-bit $readmemh (fallback BRAM init for XSIM, 32-bit LMB BRAM) ----
$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/%.memh: $(BUILD)/%.bin
	$(PYTHON) $(MEMH_TOOL) $< > $@

# --- Symbol table as JSON (robustness campaigns: the board agent addresses
#     rob_params/rob_status without needing the toolchain) ------------------
$(BUILD)/%.syms.json: $(BUILD)/%.elf
	$(NM) $< | $(PYTHON) $(NM_TOOL) > $@

# COE for blk_mem_gen init (32-bit LMB BRAM, 128 KiB = 32768 words) -- sim BRAM preload
$(BUILD)/%.coe: $(BUILD)/%.bin
	$(PYTHON) $(MEMH_TOOL) --coe $< 32768 > $@

size: elf
	@echo "== Sizes =="
	@$(SIZE) $(ELFS)

clean:
	rm -rf $(BUILD)
