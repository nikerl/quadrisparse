#!/usr/bin/env python3
import csv
import sys
import argparse
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from collections import defaultdict


def read_trace(path):
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


def assign_lanes(spans_for_unit):
    """Greedy interval-graph coloring: pack overlapping spans into sub-rows."""
    sorted_spans = sorted(spans_for_unit, key=lambda s: s[3])
    lane_ends = []
    assignments = {}
    for span in sorted_spans:
        start, end = span[3], span[4]
        placed = False
        for i, lane_end in enumerate(lane_ends):
            if lane_end <= start:
                lane_ends[i] = end
                assignments[span] = i
                placed = True
                break
        if not placed:
            assignments[span] = len(lane_ends)
            lane_ends.append(end)
    return assignments, max(len(lane_ends), 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", nargs="?", default="benchmark/timeline.csv")
    parser.add_argument("--head", type=float, default=0.40,
                        help="Fraction of timeline to keep at the start (default 0.40)")
    parser.add_argument("--tail", type=float, default=0.40,
                        help="Fraction of timeline to keep at the end (default 0.40)")
    parser.add_argument("-o", default="timeline.pdf")
    args = parser.parse_args()

    spans = read_trace(args.trace)
    if not spans:
        print("No spans found.")
        return

    # Assign absolute sequential IDs per instruction type, ordered by start cycle
    instr_counters = defaultdict(int)
    span_abs_id = {}
    for span in sorted(spans, key=lambda s: s[3]):
        span_abs_id[span] = instr_counters[span[1]]
        instr_counters[span[1]] += 1

    t_min = min(s[3] for s in spans)
    t_max = max(s[4] for s in spans)
    duration = t_max - t_min

    head_end =  83 #t_min + duration * args.head
    tail_start = 115 #t_max - duration * args.tail
    do_cut = head_end < tail_start

    # Cut gap — just wide enough for the "..." label
    cut_w = (head_end - t_min) * 0.06

    def remap(cycle):
        if not do_cut or cycle <= head_end:
            return float(cycle - t_min)
        elif cycle >= tail_start:
            return (head_end - t_min) + cut_w + float(cycle - tail_start)
        return None

    # Include any span that overlaps with either visible window (will be clipped when drawn)
    relevant = [s for s in spans if s[3] <= head_end or (do_cut and s[4] >= tail_start)]

    UNIT_ORDER = ["PERM", "LSU", "SA"]
    UNIT_LABELS = {
        "PERM": "Perm\nUnit",
        "LSU": "LSU",
        "SA": "Systolic\nArray",
    }
    COLORS = {
        "MZERO": "#ffd351",
        "MLD":   "#cc6060",
        "SPLD":  "#e47900",
        "DLD":   "#cc6060",
        "MMASA": "#60b860",
        "SPMAC": "#60b860",
        "MST":   "#9060b0",
    }
    ABBREV = {
        "MZERO": "mz",
        "MLD":   "mld",
        "SPLD":  "spld",
        "DLD":   "dld",
        "MMASA": "mmac",
        "SPMAC": "spmac",
        "MST":   "mst",
    }

    # Group relevant spans by unit and assign lanes
    unit_spans = {u: [] for u in UNIT_ORDER}
    for s in relevant:
        if s[0] in unit_spans:
            unit_spans[s[0]].append(s)

    unit_lane_assign = {}
    unit_num_lanes = {}
    for u in UNIT_ORDER:
        if unit_spans[u]:
            asgn, n = assign_lanes(unit_spans[u])
        else:
            asgn, n = {}, 1
        unit_lane_assign[u] = asgn
        unit_num_lanes[u] = n

    # Compact layout: thin lanes, small gaps between units
    LANE_H   = 0.30
    UNIT_GAP = 0.18

    unit_base_y = {}
    y_cursor = 0.0
    for u in UNIT_ORDER:
        unit_base_y[u] = y_cursor
        y_cursor += unit_num_lanes[u] * LANE_H + UNIT_GAP
    total_y = y_cursor - UNIT_GAP

    # Figure height scales with total lane count; width fits cycle resolution
    fig_h = max(2.5, total_y * 1.6 + 0.8)
    fig_w = max(16, duration * 0.13)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))

    for span in relevant:
        unit, instr, _, start, end = span
        lane  = unit_lane_assign[unit].get(span, 0)
        bar_y = unit_base_y[unit] + lane * LANE_H

        # Build the visible portion(s): clip to head window and/or tail window
        portions = []
        if start <= head_end:                          # overlaps head
            portions.append((start, min(end, head_end)))
        if do_cut and end >= tail_start:               # overlaps tail
            portions.append((max(start, tail_start), end))

        for cs, ce in portions:
            r_start = remap(cs)
            r_end   = remap(ce)
            if r_start is None or r_end is None:
                continue
            bar_w = r_end - r_start
            if bar_w <= 0:
                continue

            ax.barh(
                y=bar_y,
                width=bar_w,
                left=r_start,
                height=LANE_H * 0.88,
                color=COLORS.get(instr, "#aaaaaa"),
                edgecolor="#333333",
                linewidth=0.4,
                align="edge",
            )

            is_clipped = (cs != start or ce != end)
            label = f"{ABBREV.get(instr, instr)} {span_abs_id[span]}"
            if bar_w >= 1.0 and not is_clipped:
                ax.text(
                    r_start + bar_w / 2,
                    bar_y + LANE_H * 0.44,
                    label,
                    va="center",
                    ha="center",
                    fontsize=15,
                    rotation=0,
                )

    # Per-cycle vertical grid lines in both visible windows
    head_cycles = range(t_min, int(head_end) + 1)
    tail_cycles = range(int(tail_start), t_max + 1)
    grid_x = [remap(c) for c in head_cycles] + [remap(c) for c in tail_cycles]
    ax.vlines(grid_x, ymin=-0.28, ymax=total_y + 0.05, color="#cccccc", linewidth=0.4, zorder=0)

    # Cut region visual
    if do_cut:
        cut_x0 = head_end - t_min
        cut_x1 = cut_x0 + cut_w
        ax.axvspan(cut_x0, cut_x1, color="white", zorder=5)
        for xv in (cut_x0, cut_x1):
            ax.axvline(xv, color="#888888", linestyle="--", linewidth=1, zorder=6)
        ax.text(
            (cut_x0 + cut_x1) / 2, total_y / 2,
            "...",
            ha="center", va="center", fontsize=15, color="#555555", zorder=7,
        )

    # Y-axis: one centred label per unit
    ytick_pos, ytick_labels = [], []
    for u in UNIT_ORDER:
        mid = unit_base_y[u] + unit_num_lanes[u] * LANE_H / 2
        ytick_pos.append(mid)
        ytick_labels.append(UNIT_LABELS.get(u, u))

    ax.set_yticks(ytick_pos)
    ax.set_yticklabels(ytick_labels, fontsize=15)

    # X-axis: label every 5 cycles, shifted so the first cycle is zero
    cycle_offset = t_min
    tick_step = 5
    head_ticks = [c for c in range(t_min, int(head_end) + 1) if (c - t_min) % tick_step == 0]
    tail_ticks = [c for c in range(int(tail_start), t_max + 1) if (c - t_min) % tick_step == 0]
    tick_x      = [remap(c) for c in head_ticks + tail_ticks]
    tick_labels = [str(c - cycle_offset) for c in head_ticks + tail_ticks]
    ax.set_xticks(tick_x)
    ax.set_xticklabels(tick_labels, fontsize=12)
    ax.set_xlabel("Cycles", labelpad=4, fontsize=15)
    ax.set_title("Instruction Timeline", fontsize=25, pad=10, weight="bold")
    max_x = remap(t_max)
    ax.set_xlim(left=0, right=max_x + 0.5)
    ax.set_ylim(-0.28, total_y + 0.05)
    ax.invert_yaxis()

    plt.tight_layout()
    plt.savefig(args.o, format="pdf", bbox_inches="tight")
    print(f"Saved to {args.o}")
    plt.show()


if __name__ == "__main__":
    main()
