# uv (and often qemu) live in ~/.local/bin, which login shells may not export.
export PATH := $(HOME)/.local/bin:$(PATH)

PY ?= uv run python
RUFF ?= uv run ruff

# On arm64 Linux the SmartPy pip package ships x86_64 compiler binaries;
# run them under qemu user emulation (see README).
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),aarch64)
# PATH is injected explicitly: `export PATH` reaches recipes but, on some
# make versions, not $(shell ...) calls.
QEMU ?= $(shell PATH="$(PATH)" command -v qemu-x86_64-static 2>/dev/null || echo $(HOME)/.local/bin/qemu-x86_64-static)
SMARTPY_PKG := $(shell PATH="$(PATH)" $(PY) -c "import importlib.util; print(importlib.util.find_spec('smartpy').submodule_search_locations[0])")
export SMARTPY_OASIS := $(QEMU) $(SMARTPY_PKG)/smartpy-oasis-linux.exe
export SMARTPY_CANOPY := $(QEMU) $(SMARTPY_PKG)/smartpy-canopy-linux.exe
endif

# Deployment parameters for `make compile` (override on CLI).
ADMIN ?= tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb
MANAGER ?= tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb
LOCKER ?= tz1VSUr8wwNhLAzempoch5d6hLRiTh8Cjcjb
MAX_TOKENS ?= 10
PERIOD_SECONDS ?= 600
MAX_ITEMS_PER_BATCH ?= 10

SCENARIO_DIR := .scenarios

.PHONY: all compile test integration fmt lint clean

all: compile

# Compiles contract code + initial storage into build/.
# Contract code does not depend on the addresses; storage does.
compile:
	$(PY) scripts/compile.py \
	  --admin $(ADMIN) --manager $(MANAGER) --locker $(LOCKER) \
	  --max-tokens $(MAX_TOKENS) --period-seconds $(PERIOD_SECONDS) \
	  --max-items-per-batch $(MAX_ITEMS_PER_BATCH)

test:
	@mkdir -p $(SCENARIO_DIR)
	cd $(SCENARIO_DIR) && $(PY) ../tests/test_vault.py

# Sandbox integration tests (requires octez-client, see integration/README.md)
integration:
	$(PY) integration/run_sandbox_tests.py

fmt:
	$(RUFF) format .
	$(RUFF) check --fix .

lint:
	$(RUFF) format --check .
	$(RUFF) check .

clean:
	rm -rf $(SCENARIO_DIR) build
