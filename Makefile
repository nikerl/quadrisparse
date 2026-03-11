# Basic standalone simulation flow for quadrilatero_xif_tb.
# Requires: bender, verilator

SHELL := /bin/bash

TOP      ?= quadrilatero_xif_tb
TB_FILE  ?= tb/quadrilatero_xif_tb.sv
BUILD_DIR ?= build
FLIST    ?= $(BUILD_DIR)/flist.f
SIMV     ?= $(BUILD_DIR)/simv
OBJ_DIR  ?= $(BUILD_DIR)/obj_dir

VERILATOR ?= verilator
VERILATOR_FLAGS ?= --binary --timing -Wall -Wno-fatal

# Optional fallback flow (kept for convenience)
IVERILOG ?= iverilog
VVP      ?= vvp
BENDER   ?= bender

.PHONY: help deps flist compile verilate run compile-iverilog run-iverilog clean

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
flist: | $(BUILD_DIR)
	$(BENDER) script flist-plus | grep -v 'pad_functional\.sv' > $(FLIST)
	printf "%s\n" "$(TB_FILE)" >> $(FLIST)

compile: verilate

verilate: flist
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module $(TOP) -f $(FLIST) --Mdir $(OBJ_DIR) -o $(notdir $(SIMV))

run: compile
	$(OBJ_DIR)/$(notdir $(SIMV))

compile-iverilog: flist
	$(IVERILOG) -g2012 -s $(TOP) -o $(SIMV) -f $(FLIST)

run-iverilog: compile-iverilog
	$(VVP) $(SIMV)

clean:
	rm -rf $(BUILD_DIR)
