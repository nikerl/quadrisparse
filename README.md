# QuadriSparse

`QuadriSparse` is a sparse dense matrix muplitplication (SpMM) accelerator and RISC-V ISA extention based on the matrix multiplication co-processor [Quadrilatero](https://github.com/pulp-platform/quadrilatero). It uses the CORE-V-X-IF interface to interface with `OpenHW Group` CPUs and the OBI protocol to interface with memories.

This project was developed as part of a master thesis at Chalmers Univeristy of Technology. 

### Dependencies
- Verilator: SV simulator
- Bender: dependency management tool available [here](https://github.com/pulp-platform/bender)
- Make

### Usage
Ensure the dependencies above are installed:
```bash
verilator -V
bender -V
```

Then compile and run:
```bash
make run
```

### Directory Structure
- `/rtl` contains the SystemVerilog files describing the co-processor
- `/sw` contains example programs that can be used with the [x-heep](https://github.com/x-heep/x-heep) platform
- `/tb` contains a standalone testbench which can be used to verify the functionality of the accelerator


### Licence
Unless otherwise specified in their respective file headers all files into this repository are made available under Apache License v2.0 (`Apache-2.0`). Most RTL files are licenced under the Solderpad Hardware License v2.1 (`SHL-2.1`), see LICENCE.md.
