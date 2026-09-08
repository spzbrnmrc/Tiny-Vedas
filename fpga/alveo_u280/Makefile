# Copyright (c) 2025 Siliscale Consulting, LLC
# SPDX-License-Identifier: Apache-2.0

BOARD_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(BOARD_DIR)/../..)
WORK_DIR  ?= $(BOARD_DIR)/work
PART      := xcu280-fsvh2892-2L-e
PYTHON    ?= /usr/bin/python3
VENV_PYTHON ?= $(REPO_ROOT)/venv/bin/python
SMOKE_TLIST ?= $(REPO_ROOT)/tests/smoke.tlist
# Prepended under sudo so run_gen can rebuild ELFs (riscv64-unknown-elf-gcc).
RISCV_BIN ?= /tools/riscv/bin

VIVADO ?= vivado

BIT ?= $(WORK_DIR)/tiny_vedas_u280.bit

.PHONY: bitstream bd config program smoke clean

# Generate work/include/{global,hw_config}.svh (must run outside Vivado —
# Vivado sets PYTHONHOME and breaks system python3).
config:
	mkdir -p $(WORK_DIR)
	$(PYTHON) $(BOARD_DIR)/scripts/gen_fpga_config.py \
		--board-dir $(BOARD_DIR) --work-dir $(WORK_DIR)

bitstream: config
	@command -v $(VIVADO) >/dev/null || { echo "error: vivado not on PATH (need 2023.2)"; exit 1; }
	$(VIVADO) -mode batch -nojournal -log $(WORK_DIR)/vivado_build.log \
		-source $(BOARD_DIR)/tcl/build.tcl \
		-tclargs $(BOARD_DIR) $(WORK_DIR)

bd: config
	@command -v $(VIVADO) >/dev/null || { echo "error: vivado not on PATH (need 2023.2)"; exit 1; }
	$(VIVADO) -mode batch -nojournal -log $(WORK_DIR)/vivado_bd.log \
		-source $(BOARD_DIR)/tcl/create_bd_only.tcl \
		-tclargs $(BOARD_DIR) $(WORK_DIR)

# JTAG program + PCIe remove/rescan + VERSION check (needs sudo).
program:
	@command -v $(VIVADO) >/dev/null || { echo "error: vivado not on PATH (need 2023.2)"; exit 1; }
	@test -f $(BIT) || { echo "error: missing $(BIT) — run 'make bitstream' first"; exit 1; }
	sudo $(PYTHON) $(BOARD_DIR)/scripts/program_fpga.py --bit $(BIT)

# Slice C: load smoke.tlist over PCIe (needs sudo BAR mmap).
smoke:
	@test -x $(VENV_PYTHON) || { echo "error: missing $(VENV_PYTHON) — create the repo venv first"; exit 1; }
	@test -f $(SMOKE_TLIST) || { echo "error: missing $(SMOKE_TLIST)"; exit 1; }
	sudo env PATH="$(RISCV_BIN):$(PATH)" $(VENV_PYTHON) \
		$(BOARD_DIR)/scripts/fpga_runner.py -t $(SMOKE_TLIST) --skip-oversized

clean:
	rm -rf $(WORK_DIR)
