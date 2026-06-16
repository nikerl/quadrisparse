#!/usr/bin/env python

# Copyright 2026
# Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Author: Nik Erlandsson

import os
import sys
import random
import argparse
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("--size", type=int, help="Size of the matrices")
parser.add_argument("--sparsity", type=float, help="Sparsity of the matrices")
parser.add_argument("--max_val", type=int, nargs="?", default=15, help="Maximum value for random numbers")
parser.add_argument("--path", type=str, default=".", help="Path to save the generated matrices and result")


def generate_spmm_test_data(args): 
    SIZE = int(args.size)
    SPARSITY = float(args.sparsity)
    MAX_VAL = int(args.max_val)
    PATH = args.path
    
    if not os.path.isdir(PATH):
        os.makedirs(PATH)

    print(f"Generating SpMM test data with size {SIZE} and sparsity {SPARSITY}")
    
    dense_matrix = np.zeros((SIZE, SIZE), dtype=np.int32)
    sparse_matrix = np.zeros((SIZE, SIZE), dtype=np.int32)
    
    # Dense matrix
    with open(f"{PATH}/mat_{SIZE}_{SPARSITY}_b.hex", "w") as f_dense:
        for i in range(SIZE):
            for j in range(SIZE):
                val = random.randint(0, MAX_VAL)
                dense_matrix[i][j] = val
                f_dense.write(f"{val:08x}\n")
                
            
    # Sparse matrix in CSR format
    with open(f"{PATH}/mat_{SIZE}_{SPARSITY}_a_val.hex", "w") as f_val, \
         open(f"{PATH}/mat_{SIZE}_{SPARSITY}_a_col.hex", "w") as f_col, \
         open(f"{PATH}/mat_{SIZE}_{SPARSITY}_a_row.hex", "w") as f_row, \
         open(f"{PATH}/mat_{SIZE}_{SPARSITY}_a.hex", "w") as f_sparse:
        
        # Generate non zero values based on the specified sparsity
        nnz = int(SIZE * SIZE * (1 - SPARSITY))
        non_zero_values = np.random.randint(1, MAX_VAL, size=nnz)
        
        # Randomly place the non-zero values in the sparse matrix
        for nz in non_zero_values:
            while True: 
                i = random.randint(0, SIZE - 1)
                j = random.randint(0, SIZE - 1)
                if sparse_matrix[i][j] == 0:
                    sparse_matrix[i][j] = nz
                    break
                else:
                    continue
        
        # Write the sparse matrix in both dense and CSR formats
        for i in range(SIZE):
            for j in range(SIZE):
                f_sparse.write(f"{sparse_matrix[i][j]:08x}\n")
                if sparse_matrix[i][j] != 0:
                    f_val.write(f"{sparse_matrix[i][j]:08x}\n")
                    f_col.write(f"{j:08x}\n")

        # Generate row_ptr based on the non-zero values
        row_ptr = 0
        f_row.write(f"{row_ptr:08x}\n")
        for i in range(SIZE):
            row_ptr += np.count_nonzero(sparse_matrix[i])
            f_row.write(f"{row_ptr:08x}\n")
            
    
    result = np.dot(sparse_matrix, dense_matrix)
    with open(f"{PATH}/mat_{SIZE}_{SPARSITY}_ref.hex", "w") as f_result:
        for i in range(SIZE):
            for j in range(SIZE):
                f_result.write(f"{result[i][j]:08x}\n")
    
    print("\n######## Dense matrix ########")
    print(dense_matrix)
    print("\n######## Sparse matrix ########")
    print(sparse_matrix)
    print("\n######## Result matrix ########")
    print(result)
    

if __name__ == "__main__":
    args = parser.parse_args()
    generate_spmm_test_data(args)
    