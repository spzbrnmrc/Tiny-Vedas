# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

SW_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(SW_DIR)/../../..)
PREBUILT := $(SW_DIR)/prebuilt

RISCV_PREFIX ?= /tools/Xilinx/Vitis/2023.2/gnu/riscv/lin/riscv64-unknown-elf/bin/riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

CFLAGS := -march=rv32im -mabi=ilp32 -nostdlib -I$(REPO_ROOT)/sw/include -Wl,-Ttext=0x00100000

.PHONY: all clean

all: $(PREBUILT)/eot_smoke.bin $(PREBUILT)/uart_eot_smoke.bin

$(PREBUILT):
	mkdir -p $@

$(PREBUILT)/%.bin: $(SW_DIR)/%.S | $(PREBUILT)
	$(CC) $(CFLAGS) -o $(PREBUILT)/$*.elf $<
	$(OBJCOPY) -O binary -j .text $(PREBUILT)/$*.elf $@
	$(OBJDUMP) -d $(PREBUILT)/$*.elf > $(PREBUILT)/$*.dis
	@echo "built $@"

clean:
	rm -f $(PREBUILT)/*.elf $(PREBUILT)/*.dis
