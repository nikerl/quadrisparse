# QuadriSparse

`QuadriSparse` is a sparse dense matrix mulitplication (SpMM) accelerator and RISC-V ISA extention based on the matrix multiplication co-processor [Quadrilatero](https://github.com/pulp-platform/quadrilatero). It uses the CORE-V-X-IF interface to interface with `OpenHW Group` CPUs and the OBI protocol to interface with memories.

This project was developed as part of a masters thesis at Chalmers Univeristy of Technology. 

## Dependencies
- Verilator: SV simulator
- Bender: dependency management tool available [here](https://github.com/pulp-platform/bender)
- Make

## Usage
Ensure the dependencies above are installed:
```bash
verilator -V
bender -V
```

Then compile and run:
```bash
make run
```

## ISA Extention
`QuadriSparse` is based on a RISC-V matrix extension available [here](https://github.com/esl-epfl/xheep_matrix_spec). Below are listed the instructions added by this project and their encodings.

All instructions share `7'b0101011` (CUSTOM 1) as the major opcode, and func3 is `3'b000`.

### Arithmetic Instructions
| mnemonic  |31–27 | 26–25 | 24 | 23–21 | 20–18 | 17–15 | 14–12 | 11–10 | 9–7 | 6–0 |
| ----- | ---- | --- | ---- | ----- | ----- | ----- | ----- | --- | --- | -- |
| spmac.w | 11110 | 00 | 0 | ms2 | ms1 | md | func3 | 10 | 000 | major opcode

### Memory Instructions
| mnemonic |31–27 |26–25 |24–18 |17–15 |14–12 |11–10 |9–7 |6–0 | 
| ------- | ---- | ---- |----- | ---- | ---- | ---- | -- | -- |
| spld.w | 00100	|00 | 0000000 | nnz to load	|func3	|10	|md	|major opcode	|
| dld.w | 00010	|00 | 0000000 | sp matrix reg |func3	|10	|md	|major opcode	|

## Directory Structure
- `/rtl` contains the SystemVerilog files describing the co-processor
- `/sw` contains example programs that can be used with the [x-heep](https://github.com/x-heep/x-heep) platform
- `/tb` contains a standalone testbench which can be used to verify the functionality of the accelerator

## Licence
Unless otherwise specified in their respective file headers all files in this repository are made available under Apache License v2.0 (`Apache-2.0`). Most RTL files are licenced under the Solderpad Hardware License v2.1 (`SHL-2.1`), see LICENCE.md.
