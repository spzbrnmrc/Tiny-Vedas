PYVEDAS_ROOT := $(abspath .)
WORK := $(PYVEDAS_ROOT)/work/out
INC := $(PYVEDAS_ROOT)/runtime/include
PYTHON := $(if $(wildcard $(PYVEDAS_ROOT)/.venv/bin/python3),$(PYVEDAS_ROOT)/.venv/bin/python3,python3)

.PHONY: jit host clean

EXAMPLE := $(abspath ../tests/pyvedas/vector_add.py)

jit:
	$(PYTHON) -m jit --model-spec $(EXAMPLE) -o $(WORK)

jit-target:
	$(PYTHON) -m jit --model-spec $(EXAMPLE) -o $(WORK) --target

host: jit
	gcc -std=c11 -O2 -I$(INC) \
		$(WORK)/generated.c \
		$(PYVEDAS_ROOT)/runtime/c/aten_add_Tensor.c \
		-o $(WORK)/aten_add_Tensor_host

run-host: host
	$(WORK)/aten_add_Tensor_host

clean:
	rm -rf work
