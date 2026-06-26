# QuadriSparse

`QuadriSparse` is a sparse dense matrix mulitplication (SpMM) accelerator and RISC-V ISA extention based on the matrix multiplication co-processor [Quadrilatero](https://github.com/pulp-platform/quadrilatero). It uses the CORE-V-X-IF interface to interface with `OpenHW Group` CPUs and the OBI protocol to interface with memories.

This project was developed as part of a master's thesis at Chalmers Univeristy of Technology. 

## Dependencies
- Verilator: SV simulator
- Bender: dependency management tool available [here](https://github.com/pulp-platform/bender)
- Make
- Python3

## Usage
### Setup
Ensure the dependencies above are installed:
```bash
verilator -V
bender -V
```

Setup Python virtual envirmoment:
```bash
python -m venv venv
source venv/bin/activate
pip install numpy
```

### Running simulation
Generate test data. SIZE: number of rows, SPARSITY: Ammount of sparsity 0-1,  MAXVAL: Maximum value of the elements (optional).
```bash
make matgen SIZE=16 SPARSITY=0.8 MAXVAL=15
```

Compile and run. MODE (sparse, dense) switches between the new sparse optimized multiplication and the traditional dense. 
```bash
make run DATA_PREFIX=mat_16_0.8 SIZE=16 MODE=sparse
```

### Notes
If you want to bring your own test data it has to be formatted as follows: 
- All files are flat text files containing one hex formatted 32 bit number per row
- The sparse matrix in CSR format consisting of 3 files, xx_a_row.hex, xx_a_col.hex, xx_a_val.hex
- The dense matrix file: xx_b.hex
- The result reference matrix: xx_ref.hex
- xx is the DATA_PREFIX argument in the run command

## ISA Extention
`QuadriSparse` is based on a RISC-V matrix extension available [here](https://github.com/esl-epfl/xheep_matrix_spec). Below are listed the instructions added by this project and their encodings.

All instructions share `7'b0101011` (CUSTOM 1) as the major opcode, and func3 is `3'b000`.

| mnemonic | 31-27 | 26-25 | 24  | 23-21 | 20-18 | 17-15  | 14-12 | 11-10 | 9-7 | 6-0     |
| -------- | ----- | ----- |---- | ----- | ----- | ------ | ----- | ----- | --- | ------- |
| SPLD_W   | 00100 | 00    | 0   | 000   | 000   | nnz $^3$    | func3 | 10    | md  | 0101011 |
| DLD_W    | 00010 | 00    | 0   | 000   | 000   | ms1 $^1$   | func3 | 10    | md  | 0101011 |
| SPMAC_W  | 11110 | 00    | 0   | ms1 $^1$  | ms2 $^2$  | md     | func3 | 10    | 000 | 0101011 |

1. Sparse register
2. Dense register 
3. The numeber of non zero elements to load form the CSR values array

## Directory Structure
- `/rtl` contains the SystemVerilog files describing the co-processor
- `/sw` contains example programs that can be used with the [x-heep](https://github.com/x-heep/x-heep) platform as well as helper functions to generate test data
- `/tb` contains a standalone testbench which can be used to verify the functionality of the accelerator

## Limitations
- DLD_W instruction requires the dense matrix's number of columns to be divisible by 4 or zero-padded
- The instructions are completely un-pipelined

## Licence
Unless otherwise specified in their respective file headers all files in this repository are made available under Apache License v2.0 (`Apache-2.0`). Most RTL files are licenced under the Solderpad Hardware License v2.1 (`SHL-2.1`), see LICENCE.md.
