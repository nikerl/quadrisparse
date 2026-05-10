#!/usr/bin/env python3
import csv
import sys
from collections import defaultdict
import matplotlib.pyplot as plt

def read_trace(path):
    # Collect start/end per (unit, instr, id)
    starts = {}
    spans = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            cycle = int(row["cycle"])
            key = (row["unit"], row["instr"], int(row["id"]))
            if row["event"] == "START":
                starts[key] = cycle
            elif row["event"] == "END" and key in starts:
                spans.append((key[0], key[1], key[2], starts[key], cycle))
    return spans

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "trace.csv"
    spans = read_trace(path)
    if not spans:
        print("No spans found in trace.")
        return

    # Lane per unit
    units = ["PERM", "LSU", "SA"]
    unit_y = {u: i for i, u in enumerate(units)}
    colors = {
        "MZERO": "#00a5f2",
        "SPLD":  "#ff8c8c",
        "DLD":   "#ffb45f",
        "SPMAC": "#7bd389",
        "MST":   "#c94cc2",
    }

    # Assign absolute IDs based on start time ordering
    spans_sorted = sorted(spans, key=lambda s: (s[3], s[0], s[1], s[2]))
    abs_id_map = {span: idx for idx, span in enumerate(spans_sorted)}

    fig, ax = plt.subplots(figsize=(12, 4))
    for unit, instr, iid, start, end in spans_sorted:
        y = unit_y.get(unit, 0)
        ax.barh(
            y=y,
            width=end - start,
            left=start,
            height=0.6,
            color=colors.get(instr, "#999999"),
            edgecolor="black",
        )
        abs_id = abs_id_map[(unit, instr, iid, start, end)]
        ax.text(
            start + (end - start) / 2,
            y,
            f"{instr} {abs_id}",
            va="center",
            ha="center",
            fontsize=8,
            rotation=90,
        )

    ax.set_yticks([unit_y[u] for u in units])
    ax.set_yticklabels(units)
    ax.set_xlabel("Cycle")
    ax.set_title("Instruction Timeline")
    ax.invert_yaxis()
    ax.grid(True, axis="x", linestyle="--", alpha=0.4)

    plt.tight_layout()
    plt.show()
    plt.savefig("timeline.png")

if __name__ == "__main__":
    main()