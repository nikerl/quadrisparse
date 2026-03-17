### Memory layout
- A sparse in memory as CSR
- B dense in memory as row major

### Load instructions
- load a sparse tile: 4 non zero + col index into a matrix reg using the top two rows. since we are doing one row at a time the row index can be kept track of in software
- load a dense tile: use the sparse tile to load the rows corresponding to the col indicies into a matrix reg

### Multiplication
- set up a 4 scalar x vector multipliers
- load the matrix into the multiplier array
- broadcast the sparse non zeros to all multipliers in the row
- do all 16 multiplications in parallel

### Reduce and accumulate
- reducde the rows with a adder tree
- accumulate to the output reg


### TODO:
- sparse matrix load instruction: "spmld" csr_col_base_addr csr_val_base_addr -> mat_reg
- dense matrix load instruction: "dmld" spm_reg dm_base_addr -> mat_reg
- quadrisparse instruction, 4 parallel scalar x vector
    reduced and accumulated to one partial vector segment: "spmmac" spm_reg dm_reg -> output_acc
- output vector store instruction: "ovst" output_acc output_base_addr -> void
- maybe modifiy the matrix register file to get some vector regs for the output and some 2x4 regs for the sparse matix

