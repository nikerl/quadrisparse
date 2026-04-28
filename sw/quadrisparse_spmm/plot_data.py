#!/usr/bin/env python

# Copyright 2026
# Solderpad Hardware License, Version 2.1,see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Author: Nik Erlandsson


import numpy as np
import matplotlib.pyplot as plt
import pandas as pd


def plot_speedup_bar(df):
    # Only consider mat_size >= 64 and sparsity >= 0.7
    df = df[df['mat_size'] >= 64]
    df = df[df['sparsity'] >= 0.7]

    # Get all unique sparsity levels (excluding dense for now)
    sparsity_levels = sorted(df['sparsity'].unique())
    sparse_levels = [s for s in sparsity_levels if s < 1.0]

    # Compute speedups and keep (sparsity, label, speedup) tuples
    bar_data = [('Dense', 0.0, 1.0)]  # Dense always first, sparsity=0.0 for sorting

    for sparsity in sparse_levels:
        sparse_rows = df[(df['sparsity'] == sparsity) & (df['mode'].str.strip() == 'sparse')]
        ratios = []
        for mat_size in sparse_rows['mat_size'].unique():
            sparse_cycles = sparse_rows[sparse_rows['mat_size'] == mat_size]['avg_cycles'].values
            dense_cycles = df[(df['sparsity'] == 1.0) & (df['mat_size'] == mat_size) & (df['mode'].str.strip() == 'dense')]['avg_cycles'].values
            if len(sparse_cycles) > 0 and len(dense_cycles) > 0:
                ratios.append(dense_cycles[0] / sparse_cycles[0])
        speedup = np.mean(ratios) if ratios else np.nan
        percent_label = f"{int(round(sparsity*100))}%"
        bar_data.append((percent_label, sparsity, speedup))


    # Sort by speedup (slowest first, fastest last)
    bar_data_sorted = sorted(bar_data, key=lambda x: (x[2] if not np.isnan(x[2]) else -np.inf))
    labels = [x[0] for x in bar_data_sorted]
    speedups = [x[2] for x in bar_data_sorted]

    # Plot
    fig, ax = plt.subplots(figsize=(8, 5))
    # Color: black for Dense, teal for others
    bar_colors = ['black' if lbl == 'Dense' else 'teal' for lbl in labels]
    ax.bar(labels, speedups, color=bar_colors)
    ax.set_xlabel('Sparsity')
    ax.set_ylabel('Average Speedup (Dense/Sparse)')
    ax.set_title('Average Speedup vs Dense (mat_size ≥ 64)')
    for i, v in enumerate(speedups):
        if not np.isnan(v):
            ax.text(i, v + 0.03, f"{v:.2f}", ha='center', va='bottom', fontsize=9)
    fig.tight_layout()
    plt.savefig('speedup_bar.png', dpi=300)
    print("Plot saved as speedup_bar.png")


# Read the CSV file
df = pd.read_csv('benchmark/results-1.0.csv', skipinitialspace=True)
df.columns = df.columns.str.strip()

# Define sparsity order for better visualization
sparsity_order = sorted(df['sparsity'].unique())


# Loop over y-axis options and generate one plot for each
plot_configs = [
    {
        'y': 'avg_cycles',
        'ylabel': 'Latency (Cycles)',
        'title': 'Matmul Latency vs Matrix Size',
        'filename': 'latency_plot.png'
    },
    {
        'y': 'avg_instructions',
        'ylabel': 'Instructions',
        'title': 'Matmul Instructions vs Matrix Size',
        'filename': 'instructions_plot.png'
    }
]


mat_sizes = sorted(df['mat_size'].unique())

for config in plot_configs:
    fig, ax = plt.subplots(figsize=(10, 6))
    colors = ["red", "blue", "green", "orange", "magenta", "cyan"]
    color_idx = 0
    for sparsity in sparsity_order:
        subset = df[df['sparsity'] == sparsity].sort_values('mat_size')
        if sparsity < 0.7:
            continue
        if sparsity == 1.0:
            label = 'Dense'
            marker = 's'
            color = 'black'
        else:
            label = f'Sparse: {sparsity*100:.0f}%'
            marker = 'o'
            color = colors[color_idx % len(colors)]
            color_idx += 1
        ax.plot(subset['mat_size'], subset[config['y']], color=color, marker=marker, label=label, linewidth=2.5, markersize=6)
    ax.set_xlabel('Matrix Size', fontsize=12)
    ax.set_ylabel(config['ylabel'], fontsize=12)
    ax.set_title(config['title'], fontsize=14, fontweight='bold')
    ax.set_yscale('log')
    ax.set_xscale('log')
    ax.set_xticks(mat_sizes)
    ax.set_xticklabels(mat_sizes)
    ax.legend(fontsize=10, loc='best')
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    plt.savefig(config['filename'], dpi=300)
    print(f"Plot saved as {config['filename']}")


# --- Bar graph for speedup ---
plot_speedup_bar(df)
