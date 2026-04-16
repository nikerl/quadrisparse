# Basic standalone simulation flow for quadrilatero_xif_tb.
# Requires: bender, verilator

SHELL := /bin/bash

# Use all available CPU cores by default unless jobs are explicitly configured.
ifeq (,$(filter -j% --jobs=% --jobs% --jobserver%,$(MAKEFLAGS)))
MAKEFLAGS += -j$(shell nproc)
endif

TOP      ?= quadrilatero_xif_tb
TB_FILE  ?= tb/quadrilatero_xif_tb.sv
BUILD_DIR ?= build
FLIST    ?= $(BUILD_DIR)/flist.f
SIMV     ?= $(BUILD_DIR)/simv
OBJ_DIR  ?= $(BUILD_DIR)/obj_dir
VERILATOR_SIMV ?= $(OBJ_DIR)/$(notdir $(SIMV))

VERILATOR ?= verilator
VERILATOR_FLAGS ?= --binary --timing -Wall -Wno-fatal

# Optional fallback flow (kept for convenience)
IVERILOG ?= iverilog
VVP      ?= vvp
BENDER   ?= bender

# Local HDL sources that should trigger recompilation when edited.
RTL_SRCS := $(shell find rtl tb -type f \( -name '*.sv' -o -name '*.svh' \))

.PHONY: help deps compile verilate run compile-iverilog run-iverilog clean

help:
	@echo "Targets:"
	@echo "  make deps     - fetch/update Bender dependencies"
	@echo "  make flist    - generate simulator file list"
	@echo "  make compile  - compile $(TOP) with verilator"
	@echo "  make run      - compile and run the testbench with verilator"
	@echo "  make compile-iverilog - optional compile with iverilog"
	@echo "  make run-iverilog     - optional run with iverilog"
	@echo "  make clean    - remove build artifacts"

deps:
	$(BENDER) update

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Generate a Verilator-friendly file list from Bender sources, then append the testbench.
# Keep timestamp stable when content is unchanged to preserve incremental builds.
flist: $(FLIST)

$(FLIST): | $(BUILD_DIR)
	@tmp="$@.tmp"; \
	$(BENDER) script flist-plus | grep -v 'pad_functional\.sv' > "$$tmp"; \
	printf "%s\n" "+incdir+tb" >> "$$tmp"; \
	printf "%s\n" "$(TB_FILE)" >> "$$tmp"; \
	if [ -f "$@" ] && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

compile: $(VERILATOR_SIMV)

verilate: compile

$(VERILATOR_SIMV): $(FLIST) $(RTL_SRCS) Bender.yml
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module $(TOP) -f $(FLIST) --Mdir $(OBJ_DIR) -o $(notdir $(SIMV))

run: $(VERILATOR_SIMV)
	$(VERILATOR_SIMV)

compile-iverilog: flist
	$(IVERILOG) -g2012 -s $(TOP) -o $(SIMV) -f $(FLIST)

run-iverilog: compile-iverilog
	$(VVP) $(SIMV)

clean:
	rm -rf $(BUILD_DIR)
