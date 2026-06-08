.PHONY: deps smoke smoke-verilator decodes clean clean-sim clean-pd clean-pyvedas config sv2v rtl2gds pd-report timing mul-sweep pd-synth

RUN = ./scripts/with_env.sh

PD_PLATFORM ?= asap7
HW_CONFIG ?= hw/presets/rv32im_scalar.yaml
ORFS_TARGET ?= all
ORFS_IMAGE ?= openroad/orfs:26Q2-446-g85d92b593
SV2V_TAG ?= v0.0.13
export ORFS_TARGET ORFS_IMAGE SV2V_TAG

deps:
	./scripts/install_deps.sh

smoke:
	$(RUN) ./tools/sim_manager.py -s xsim -t tests/smoke.tlist

smoke-verilator:
	$(RUN) ./tools/sim_manager.py -s verilator -t tests/smoke.tlist

decodes:
	$(RUN) python3 open-decode-tables/src/main.py -t open-decode-tables/tables/rv32im.yaml -o rtl/idu

config:
	python3 pd/scripts/gen_active_config.py --hw $(HW_CONFIG) --platform $(PD_PLATFORM)

sv2v: config
	./pd/scripts/sv2v.sh

rtl2gds: config
	./pd/scripts/rtl2gds.sh

pd-report:
	python3 pd/scripts/report_timing.py

timing: rtl2gds pd-report

pd-synth:
	python3 open-decode-tables/src/main.py -t open-decode-tables/tables/rv32im.yaml -o rtl/idu
	ORFS_TARGET=synth PD_PLATFORM=ci-asap7 ./scripts/pd_docker.sh make rtl2gds

mul-sweep:
	python3 pd/scripts/sweep_mul_pipeline.py -j $(shell nproc)

clean: clean-sim clean-pd clean-pyvedas

clean-sim:
	rm -rf work obj_dir .Xil xsim.dir xcelium.d
	rm -f *.log *.vcd *.wdb *.zip *.jou *.pb

clean-pd:
	rm -rf pd/work
	rm -f pd/active.mk pd/include/global.svh pd/include/mul_pd_config.svh

clean-pyvedas:
	$(MAKE) -C pyvedas clean

