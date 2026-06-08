.PHONY: deps smoke smoke-verilator decodes clean clean-sim clean-pd clean-pyvedas config sv2v rtl2gds pd-report timing mul-sweep

RUN = ./scripts/with_env.sh

PD_PLATFORM ?= asap7
HW_CONFIG ?= hw/presets/rv32im_scalar.yaml
ORFS_TARGET ?= all
export ORFS_TARGET

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

