#!/usr/bin/env bash

# Copyright 2026
# Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Author: Nik Erlandsson

BENCHMARK_DIR=benchmark
mkdir -p $BENCHMARK_DIR

NUM_RUNS=5

echo "mode, num_runs, mat_size, sparsity, avg_instructions, avg_cycles" > results.csv

run_sim() {
    local mode=$1
    local size=$2
    local sparsity=$3
    local temp_array=$4

    output=$(make run DATA_PREFIX=$BENCHMARK_DIR/mat_${size}_${sparsity} DIM=$size FLOW=$mode 2>&1)
    last_lines=$(echo "$output" | tail -n 15)
    if echo "$last_lines" | grep -q "PASS"; then
        stats_line=$(echo "$last_lines" | grep "\[TB\] Cycles:")
        if [ -n "$stats_line" ]; then
            cycles=$(echo "$stats_line" | sed -n 's/.*Cycles: \([0-9]*\),.*/\1/p')
            instructions=$(echo "$stats_line" | sed -n 's/.*Instructions: \([0-9]*\).*/\1/p')
            echo "$instructions $cycles" >> "$temp_array"
        fi
    else
        echo "Run $run for size $size and sparsity $sparsity failed for mode $mode. Output:"
        echo "$output"
        exit 1
    fi
}

for size in 8 16 32 64 128 256 512; do
    # Running sparse for all sparsity levels
    for sparsity in 0.5 0.6 0.7 0.8 0.9 0.95; do
        # Temporary files to store results for averaging
        tmp_sparse=$(mktemp)
        echo "Running size: $size, sparsity: $sparsity"

        # Running sparse multiple times for averaging because of variability from random matrix generation
        for run in {1..$NUM_RUNS}; do
            make matgen DIM=$size SPARSITY=$sparsity MATPATH=$BENCHMARK_DIR > /dev/null
            run_sim "sparse" $size $sparsity "$tmp_sparse"
        done
        # Average results for sparse
        avg_inst=$(awk '{sum+=$1} END {if (NR>0) print int(sum/NR); else print 0}' "$tmp_sparse")
        avg_cyc=$(awk '{sum+=$2} END {if (NR>0) print int(sum/NR); else print 0}' "$tmp_sparse")
        echo "sparse, $NUM_RUNS, $size, $sparsity, $avg_inst, $avg_cyc" >> results.csv

        rm -f "$tmp_sparse"
    done


    # Running dense
    tmp_dense=$(mktemp)
    echo "Running size: $size, dense"

    make matgen DIM=$size SPARSITY=1.0 MATPATH=$BENCHMARK_DIR > /dev/null

    # Running dense once, because it is not affected by sparsity or random matrix generation
    run_sim "dense" $size 1.0 "$tmp_dense"
    avg_inst=$(awk '{sum+=$1} END {if (NR>0) print int(sum/NR); else print 0}' "$tmp_dense")
    avg_cyc=$(awk '{sum+=$2} END {if (NR>0) print int(sum/NR); else print 0}' "$tmp_dense")
    echo "dense, 1, $size, 1.0, $avg_inst, $avg_cyc" >> results.csv

    rm -f "$tmp_dense"
done

rm -rf $BENCHMARK_DIR
