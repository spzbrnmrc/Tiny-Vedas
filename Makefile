.PHONY: deps smoke smoke-verilator decodes csrs soc clean clean-sim clean-pd clean-pyvedas clean-fpga config sv2v rtl2gds pd-report pd-annotate timing mul-sweep pd-synth fpga fpga_smoke gemm-directed gemm-cosim gemm-perf unit

RUN = ./scripts/with_env.sh

PD_PLATFORM ?= asap7
HW_CONFIG ?= hw/presets/rv32im_scalar.yaml
FPGA_HW_CONFIG ?= hw/presets/rv32im_zve32x.yaml
ORFS_TARGET ?= all
ORFS_IMAGE ?= openroad/orfs:26Q2-446-g85d92b593
SV2V_TAG ?= v0.0.13
export ORFS_TARGET ORFS_IMAGE SV2V_TAG

# `make fpga alveo_u280` / `make fpga_smoke alveo_u280` — second word is
# the board folder under fpga/
ifeq ($(filter $(firstword $(MAKECMDGOALS)),fpga fpga_smoke),$(firstword $(MAKECMDGOALS)))
  FPGA_NAME := $(word 2,$(MAKECMDGOALS))
  ifneq ($(FPGA_NAME),)
    .PHONY: $(FPGA_NAME)
    $(FPGA_NAME):
	@:
  endif
endif

deps:
	./scripts/install_deps.sh

smoke:
	$(RUN) ./tools/sim_manager.py -s xsim -t tests/smoke.tlist --hw-config $(HW_CONFIG)

smoke-verilator:
	$(RUN) ./tools/sim_manager.py -s verilator -t tests/smoke.tlist --hw-config $(HW_CONFIG)

gemm-directed:
	$(RUN) python3 tools/gemm_cosim.py --directed

gemm-cosim:
	$(RUN) python3 tools/gemm_cosim.py --directed --random --seeds 100

gemm-perf:
	$(RUN) python3 tools/gemm_cosim.py --perf

unit:
	$(RUN) python3 -m unittest discover -s tests/unit -v

decodes:
	$(RUN) python3 open-decode-tables/src/main.py -t open-decode-tables/tables/rv32im.yaml -o rtl/idu
	@if [ -f open-decode-tables/tables/zve32x.yaml ]; then \
		$(RUN) python3 open-decode-tables/src/main.py -t open-decode-tables/tables/zve32x.yaml -o rtl/idu; \
	fi

csrs:
	$(RUN) python3 open-csrs/src/main.py -t open-csrs/tables/csrs.yaml -o rtl/csr

soc:
	$(RUN) python3 hw/scripts/gen_soc.py

config:
	python3 pd/scripts/gen_active_config.py --hw $(HW_CONFIG) --platform $(PD_PLATFORM)

sv2v: config
	./pd/scripts/sv2v.sh

rtl2gds: config
	./pd/scripts/rtl2gds.sh

pd-report:
	python3 pd/scripts/report_timing.py

pd-annotate:
	python3 pd/scripts/annotate_layout.py

timing: rtl2gds pd-report

pd-synth:
	python3 open-decode-tables/src/main.py -t open-decode-tables/tables/rv32im.yaml -o rtl/idu
	@if [ -f open-decode-tables/tables/zve32x.yaml ]; then \
		python3 open-decode-tables/src/main.py -t open-decode-tables/tables/zve32x.yaml -o rtl/idu; \
	fi
	ORFS_TARGET=synth PD_PLATFORM=ci-asap7 HW_CONFIG=$(HW_CONFIG) \
		./scripts/pd_docker.sh make rtl2gds

mul-sweep:
	python3 pd/scripts/sweep_mul_pipeline.py -j $(shell nproc)

fpga:
	@test -n "$(FPGA_NAME)" || { echo "Usage: make fpga <board>   e.g. make fpga alveo_u280"; exit 1; }
	@test -d fpga/$(FPGA_NAME) || { echo "error: unknown FPGA board '$(FPGA_NAME)' (expected fpga/$(FPGA_NAME)/)"; exit 1; }
	$(MAKE) -C fpga/$(FPGA_NAME) bitstream HW_CONFIG=$(abspath $(FPGA_HW_CONFIG))

# Host PCIe smoke (needs programmed bit + sudo BAR mmap + RISC-V toolchain on PATH).
fpga_smoke:
	@test -n "$(FPGA_NAME)" || { echo "Usage: make fpga_smoke <board>   e.g. make fpga_smoke alveo_u280"; exit 1; }
	@test -d fpga/$(FPGA_NAME) || { echo "error: unknown FPGA board '$(FPGA_NAME)' (expected fpga/$(FPGA_NAME)/)"; exit 1; }
	$(MAKE) -C fpga/$(FPGA_NAME) smoke HW_CONFIG=$(abspath $(FPGA_HW_CONFIG))

clean: clean-sim clean-pd clean-pyvedas clean-fpga

clean-sim:
	rm -rf work obj_dir .Xil xsim.dir xcelium.d
	rm -f *.log *.vcd *.wdb *.zip *.jou *.pb

clean-pd:
	rm -rf pd/work
	rm -f pd/active.mk pd/include/global.svh pd/include/mul_pd_config.svh

clean-pyvedas:
	$(MAKE) -C pyvedas clean

clean-fpga:
	rm -rf fpga/*/work

