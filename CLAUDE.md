# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**QuadriSparse** is a sparse-dense matrix multiplication (SpMM) accelerator and RISC-V ISA extension built on top of [Quadrilatero](https://github.com/pulp-platform/quadrilatero). It integrates with OpenHW Group CPUs via the CORE-V-X-IF coprocessor interface and uses OBI for memory access. This is a master's thesis project from Chalmers University of Technology.

## Build and Simulation Commands

```bash
make deps       # Fetch/update Bender dependencies
make run        # Compile and run testbench with Verilator (most common)
make compile    # Compile only (Verilator)
make flist      # Regenerate simulator file list from Bender
make clean      # Remove build artifacts in build/

# Optional iverilog flow
make run-iverilog
```

**Dependencies**: `verilator` (SV simulator) and `bender` (PULP dependency manager).

## Architecture

### Interfaces
- **X-IF (CORE-V-X-IF)**: Coprocessor interface connecting QuadriSparse to RISC-V CPUs. Three channels: Issue (offload), Commit (retire/kill), Result (writeback).
- **OBI**: Memory bus protocol used by the LSU to fetch matrix data from memory.

### Module Hierarchy
```
quadrilatero_wrapper          ← OBI adapter wrapper
  └── quadrilatero            ← Top-level coprocessor
        ├── quadrilatero_decoder
        ├── quadrilatero_dispatcher
        ├── quadrilatero_regfile   ← 8 × 128-bit matrix registers (4×4 tiles)
        ├── quadrilatero_lsu       ← Load/store unit (dense + sparse)
        │     ├── quadrilatero_register_lsu
        │     ├── quadrilatero_register_lsu_controller
        │     ├── quadrilatero_to_obi
        │     └── quadrilatero_spld  ← Sparse tile load (new in QuadriSparse)
        └── quadrilatero_systolic_array   ← 4×4 PE mesh
              ├── quadrilatero_systolic_array_controller
              ├── quadrilatero_pe (×16)
              │     ├── quadrilatero_mac_int
              │     └── quadrilatero_mac_float
              ├── quadrilatero_skewer / quadrilatero_deskewer
              ├── quadrilatero_perm_unit
              └── quadrilatero_rf_sequencer
```

### Key Parameters (in `rtl/include/quadrilatero_pkg.sv`)
- `N_REGS = 8` — matrix register file entries
- `BUS_WIDTH = 128` — register file port width
- `N_ROWS = N_COLS = 4` — systolic array and tile dimensions
- 3 functional units: `FU_SYSTOLIC_ARRAY`, `FU_LSU`, `FU_RF`

### ISA Extension
Defined in `rtl/include/quadrilatero_instr_pkg.sv`:

| Instruction | Description |
|---|---|
| `MLD.W` | Dense matrix tile load |
| `SPLD.W` | Sparse tile load (QuadriSparse addition) |
| `MST.{B\|H\|W}` | Matrix store |
| `MMAQA.B` / `MMADA.H` / `MMASA.W` | Integer matrix multiply-accumulate |
| `FMMACC.{B\|H\|S}` | FP matrix multiply-accumulate |
| `MZERO` | Zero a matrix register |

### SpMM Algorithm (from TODO.md)
- **A** (sparse) stored in CSR format in memory; **B** (dense) stored row-major
- `SPLD.W`: loads 4 non-zeros + column indices into top two rows of a matrix register
- Dense tile load uses sparse tile column indices to fetch the corresponding rows of B
- Multiply: 4 parallel scalar×vector multiplications, results reduced via adder tree, accumulated into output register

### Testbench
`tb/quadrilatero_xif_tb.sv` is a standalone testbench with an integrated memory model and instruction stimulus generators. It exercises the X-IF interface directly and is the primary verification vehicle.

### Software Examples
`sw/` contains C programs for the [x-heep](https://github.com/x-heep/x-heep) platform with test matrices for int8/int16/int32/fp32 and Python scripts (`gen_stimuly_*.py`) to regenerate test data.
