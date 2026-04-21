#!/usr/bin/env python

# Copyright 2026
# Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Author: Nik Erlandsson

import matplotlib.pyplot as plt
import pandas as pd

# Read the CSV file
df = pd.read_csv('results-1.0.csv', skipinitialspace=True)

# Define sparsity order for better visualization
sparsity_order = sorted(df['sparsity'].unique())

# Create figure with two subplots
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 6))

# First plot: Latency
for sparsity in sparsity_order:
    subset = df[df['sparsity'] == sparsity].sort_values('mat_size')
    
    if sparsity == 1.0:
        label = 'Dense'
        marker = 's'
    else:
        label = f'Sparse: {sparsity*100:.0f}%'
        marker = 'o'
        
    ax1.plot(subset['mat_size'], subset['avg_cycles'], marker=marker, label=label, linewidth=2.5, markersize=6)

ax1.set_xlabel('Matrix Size', fontsize=12)
ax1.set_ylabel('Latency (Cycles)', fontsize=12)
ax1.set_title('Matmul Latency vs Matrix Size', fontsize=14, fontweight='bold')
ax1.set_yscale('log')
ax1.set_xscale('log')
mat_sizes = sorted(df['mat_size'].unique())
ax1.set_xticks(mat_sizes)
ax1.set_xticklabels(mat_sizes)
ax1.legend(fontsize=10, loc='best')
ax1.grid(True, alpha=0.3)

# Second plot: Instructions
for sparsity in sparsity_order:
    subset = df[df['sparsity'] == sparsity].sort_values('mat_size')
    
    if sparsity == 1.0:
        label = 'Dense'
        marker = 's'
    else:
        label = f'Sparse: {sparsity*100:.0f}%'
        marker = 'o'
        
    ax2.plot(subset['mat_size'], subset['avg_instructions'], marker=marker, label=label, linewidth=2.5, markersize=6)

ax2.set_xlabel('Matrix Size', fontsize=12)
ax2.set_ylabel('Instructions', fontsize=12)
ax2.set_title('Matmul Instructions vs Matrix Size', fontsize=14, fontweight='bold')
ax2.set_yscale('log')
ax2.set_xscale('log')
ax2.set_xticks(mat_sizes)
ax2.set_xticklabels(mat_sizes)
ax2.legend(fontsize=10, loc='best')
ax2.grid(True, alpha=0.3)

fig.tight_layout()
plt.savefig('latency_plot.png', dpi=300)
print("Plot saved as latency_plot.png")



