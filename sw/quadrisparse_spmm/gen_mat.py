import sys
import random
import numpy as np


def generate_spmm_test_data(*args): 
    if len(args) < 2:
        raise ValueError("Expected 3 arguments: Size, Sparsity, MaxVal")
    if len(args) == 2:
        MAX_VAL = 15
    else:
        MAX_VAL = int(args[2])
    
    SIZE = int(args[0])
    SPARSITY = float(args[1])

    print(f"Generating SpMM test data with size {SIZE} and sparsity {SPARSITY}")
    
    dense_matrix = np.zeros((SIZE, SIZE), dtype=np.int32)
    sparse_matrix = np.zeros((SIZE, SIZE), dtype=np.int32)
    
    # Dense matrix
    with open(f"mat_{SIZE}_{SPARSITY}_b.hex", "w") as f_dense:
        for i in range(SIZE):
            for j in range(SIZE):
                val = random.randint(0, MAX_VAL)
                dense_matrix[i][j] = val
                f_dense.write(f"{val:08x}\n")
                
            
    # Sparse matrix in CSR format
    with open(f"mat_{SIZE}_{SPARSITY}_a_val.hex", "w") as f_val, \
         open(f"mat_{SIZE}_{SPARSITY}_a_col.hex", "w") as f_col, \
         open(f"mat_{SIZE}_{SPARSITY}_a_row.hex", "w") as f_row:

        row_ptr = 0
        f_row.write(f"{row_ptr:08x}\n")
        for i in range(SIZE):
            nnz = 0
            for j in range(SIZE):
                if random.random() > SPARSITY:
                    nnz += 1
                    val = random.randint(0, MAX_VAL)
                    sparse_matrix[i][j] = val
                    f_val.write(f"{val:08x}\n")
                    f_col.write(f"{j:08x}\n")
                    row_ptr += 1
                else:
                    sparse_matrix[i][j] = 0
            f_row.write(f"{row_ptr:08x}\n")
            
    
    result = np.dot(sparse_matrix, dense_matrix)
    with open(f"mat_{SIZE}_{SPARSITY}_ref.hex", "w") as f_result:
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
    generate_spmm_test_data(*sys.argv[1:])