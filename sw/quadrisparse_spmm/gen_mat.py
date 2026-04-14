import sys
import random
import numpy as np

MAX_VAL = 15

def generate_spmm_test_data(*args): 
    if len(args) != 2:
        raise ValueError("Expected 2 arguments: Size, Sparsity")
    
    size = int(args[0])
    sparsity = float(args[1])
    
    print(f"Generating SpMM test data with size {size} and sparsity {sparsity}")
    
    dense_matrix = np.zeros((size, size), dtype=np.int32)
    sparse_matrix = np.zeros((size, size), dtype=np.int32)
    
    # Dense matrix
    with open(f"mat_d_{size}_{sparsity}.hex", "w") as f_dense:
        for i in range(size):
            for j in range(size):
                val = random.randint(0, MAX_VAL)
                dense_matrix[i][j] = val
                f_dense.write(f"{val:08x}\n")
                
            
    # Sparse matrix in CSR format
    with open(f"mat_sp_val_{size}_{sparsity}.hex", "w") as f_val, \
         open(f"mat_sp_col_{size}_{sparsity}.hex", "w") as f_col, \
         open(f"mat_sp_row_{size}_{sparsity}.hex", "w") as f_row:

        row_ptr = 0
        for i in range(size):
            nnz = 0
            for j in range(size):
                if random.random() > sparsity:
                    nnz += 1
                    val = random.randint(0, MAX_VAL)
                    sparse_matrix[i][j] = val
                    f_val.write(f"{val:08x}\n")
                    f_col.write(f"{j:08x}\n")
                else:
                    sparse_matrix[i][j] = 0
            if nnz > 0:
                f_row.write(f"{row_ptr:08x}\n")
            row_ptr += 1
    
    result = np.dot(dense_matrix, sparse_matrix)
    with open(f"mat_res_{size}_{sparsity}.hex", "w") as f_result:
        for i in range(size):
            for j in range(size):
                f_result.write(f"{result[i][j]:08x}\n")
    
    print("\n######## Dense matrix ########")
    print(dense_matrix)
    print("\n######## Sparse matrix ########")
    print(sparse_matrix)
    print("\n######## Result matrix ########")
    print(result)
    


if __name__ == "__main__":
    generate_spmm_test_data(*sys.argv[1:])