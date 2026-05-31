#!/usr/bin/env python3
"""
generate_charts.py — Produce thesis charts from benchmark sweep results.

Reads per-profile metrics.csv + annotations.csv from results/{ideal,high_latency,packet_loss}/
and individual run directories for raw RTT and CPU data.

Charts produced in results/charts/:
  chart1_throughput_by_protocol.png  — Throughput by protocol/runtime (ideal, log scale)
  chart2_packet_loss_resilience.png  — WS vs WebTransport ideal vs packet_loss (log scale)
  chart3_latency_cdf.png             — RTT CDF for selected runs (ideal)
  chart4_cpu_over_time.png           — Server CPU % over time for WebTransport runs (ideal)

Usage:
    python tools/generate_charts.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
import pandas as pd
import seaborn as sns

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).parent.parent
RESULTS_BASE = REPO_ROOT / "results"
PROFILES = ["ideal", "high_latency", "packet_loss"]

RUNTIME_PALETTE = {"Node": "#339933", "Deno": "#1A1A1A", "Bun": "#F472B6"}
PROFILE_PALETTE = {"Ideal": "#4c8eda", "Packet Loss (1%, 20ms)": "#e05c5c"}

PROTO_LABELS: dict[str, str] = {
    "ws": "WebSocket",
    "sse": "SSE",
    "short-polling": "Short-Polling",
    "long-polling": "Long-Polling",
    "webtransport": "WebTransport\n(Deno native)",
    "webtransport-vmeansdev": "WebTransport\n(vmeansdev)",
    "webtransport-fails-components": "WebTransport\n(fails-components)",
}
RUNTIME_LABELS: dict[str, str] = {"node": "Node", "deno": "Deno", "bun": "Bun"}

# Desired X-axis order for chart 1
PROTO_ORDER = [
    "WebSocket",
    "SSE",
    "Short-Polling",
    "Long-Polling",
    "WebTransport\n(Deno native)",
    "WebTransport\n(vmeansdev)",
    "WebTransport\n(fails-components)",
]

# ---------------------------------------------------------------------------
# Data loading helpers
# ---------------------------------------------------------------------------


def load_all() -> pd.DataFrame:
    """Load and merge metrics + annotations for all available profiles."""
    frames: list[pd.DataFrame] = []
    for profile in PROFILES:
        metrics_path = RESULTS_BASE / profile / "metrics.csv"
        annotations_path = RESULTS_BASE / profile / "annotations.csv"
        if not metrics_path.exists():
            print(f"  [warn] missing {metrics_path} — skipping profile '{profile}'")
            continue
        if not annotations_path.exists():
            print(f"  [warn] missing {annotations_path} — skipping profile '{profile}'")
            continue
        df = pd.read_csv(metrics_path)
        ann = pd.read_csv(annotations_path)
        merged = df.merge(ann, on="Timestamp", how="left")
        merged["Profile"] = profile
        frames.append(merged)

    if not frames:
        print("No benchmark data found. Run orchestration/run_benchmark.sh first.")
        sys.exit(1)

    result = pd.concat(frames, ignore_index=True)
    result["RuntimeLabel"] = result["Runtime"].map(RUNTIME_LABELS)
    result["ProtoLabel"] = result["ProtocolVariant"].map(PROTO_LABELS)
    return result


def build_run_dir_map(profile: str) -> dict[tuple[str, str], Path]:
    """
    Return a dict mapping (runtime, protocol_variant) -> run directory Path.

    Run directories and annotation rows are both in chronological order;
    zipping them 1:1 gives the correct mapping.
    """
    profile_dir = RESULTS_BASE / profile
    if not profile_dir.exists():
        return {}

    run_dirs = sorted(
        p for p in profile_dir.iterdir()
        if p.is_dir() and not p.name.startswith(".")
    )
    ann_path = profile_dir / "annotations.csv"
    if not ann_path.exists():
        return {}

    ann = pd.read_csv(ann_path).sort_values("Timestamp").reset_index(drop=True)
    result: dict[tuple[str, str], Path] = {}
    for i, row in ann.iterrows():
        if i < len(run_dirs):
            result[(row["Runtime"], row["ProtocolVariant"])] = run_dirs[i]
    return result


# ---------------------------------------------------------------------------
# pidstat parser
# ---------------------------------------------------------------------------


def parse_pidstat(path: Path) -> list[float]:
    """
    Parse %CPU values from a pidstat.log file.

    Format (repeating):
        Linux banner line
        blank line
        # Time  UID  PID  %usr  %system  %guest  %wait  %CPU  CPU  ...
        HH:MM:SS AM/PM  UID  PID  val  val  val  val  CPU_VAL  ...

    After split(), %CPU is at index 8 (time is two tokens: HH:MM:SS + AM/PM).
    """
    cpu_vals: list[float] = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("Linux"):
                continue
            parts = line.split()
            if len(parts) < 9:
                continue
            try:
                cpu_vals.append(float(parts[8]))
            except ValueError:
                continue
    return cpu_vals


# ---------------------------------------------------------------------------
# Chart 1 — Throughput by Protocol (ideal, log scale)
# ---------------------------------------------------------------------------


def chart_throughput_by_protocol(df: pd.DataFrame, out_dir: Path) -> None:
    ideal = df[df["Profile"] == "ideal"].copy()
    if ideal.empty:
        print("  [warn] no ideal data — skipping chart 1")
        return

    # Keep only rows where ProtoLabel is known
    ideal = ideal[ideal["ProtoLabel"].notna()].copy()

    # Build display order: only proto labels present in data, in canonical order
    present_protos = set(ideal["ProtoLabel"].unique())
    x_order = [p for p in PROTO_ORDER if p in present_protos]

    runtime_order = ["Node", "Deno", "Bun"]

    fig, ax = plt.subplots(figsize=(15, 7))
    sns.barplot(
        data=ideal,
        x="ProtoLabel",
        y="Throughput",
        hue="RuntimeLabel",
        hue_order=[r for r in runtime_order if r in ideal["RuntimeLabel"].unique()],
        order=x_order,
        palette=RUNTIME_PALETTE,
        ax=ax,
    )
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax.set_title("Throughput by Protocol — Ideal Network Conditions", fontsize=14, fontweight="bold")
    ax.set_xlabel("Protocol Variant", fontsize=12)
    ax.set_ylabel("Throughput (msg/s, log scale)", fontsize=12)
    ax.tick_params(axis="x", labelsize=9)
    ax.legend(title="Runtime", fontsize=10)
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    plt.tight_layout()
    out_path = out_dir / "chart1_throughput_by_protocol.png"
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  wrote {out_path}")


# ---------------------------------------------------------------------------
# Chart 2 — Packet Loss Resilience (log scale)
# ---------------------------------------------------------------------------


def chart_packet_loss_resilience(df: pd.DataFrame, out_dir: Path) -> None:
    wt_variants = {"webtransport", "webtransport-vmeansdev", "webtransport-fails-components"}
    target_variants = {"ws"} | wt_variants
    target_profiles = {"ideal", "packet_loss"}

    subset = df[
        df["Profile"].isin(target_profiles) & df["ProtocolVariant"].isin(target_variants)
    ].copy()

    if subset.empty:
        print("  [warn] no ws/webtransport data for chart 2 — skipping")
        return

    profile_label_map = {"ideal": "Ideal", "packet_loss": "Packet Loss (1%, 20ms)"}
    subset["ProfileLabel"] = subset["Profile"].map(profile_label_map)
    subset["GroupLabel"] = subset["RuntimeLabel"] + "\n" + subset["ProtoLabel"].str.replace("\n", " ")

    # Determine a stable x-axis order (ideal throughput descending)
    order_df = subset[subset["Profile"] == "ideal"].groupby("GroupLabel")["Throughput"].mean()
    x_order = order_df.sort_values(ascending=False).index.tolist()

    profile_order = [profile_label_map[p] for p in ["ideal", "packet_loss"] if p in subset["Profile"].values]

    fig, ax = plt.subplots(figsize=(16, 7))
    sns.barplot(
        data=subset,
        x="GroupLabel",
        y="Throughput",
        hue="ProfileLabel",
        hue_order=profile_order,
        order=x_order,
        palette=PROFILE_PALETTE,
        ax=ax,
    )
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax.set_title(
        "Packet Loss Resilience — WebSocket vs WebTransport (Ideal vs 1% Packet Loss)",
        fontsize=13, fontweight="bold",
    )
    ax.set_xlabel("Runtime / Protocol", fontsize=12)
    ax.set_ylabel("Throughput (msg/s, log scale)", fontsize=12)
    ax.tick_params(axis="x", labelsize=8)
    ax.legend(title="Network Profile", fontsize=10)
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    plt.tight_layout()
    out_path = out_dir / "chart2_packet_loss_resilience.png"
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  wrote {out_path}")


# ---------------------------------------------------------------------------
# Chart 3 — Latency CDF
# ---------------------------------------------------------------------------

# Each entry: (runtime, variant, display_label, color, linestyle, linewidth, alpha)
# Grouping rules:
#   WebSocket lines  — dashed (--),  alpha=0.6, lw=1.8   (background reference)
#   WebTransport FC  — solid  (-),   alpha=1.0, lw=2.4   (primary comparison)
#   WT vmeansdev     — dash-dot (-.), alpha=1.0, lw=2.4   (distinct Bun WT variant)
CDF_RUNS = [
    # runtime                 variant                         label                              color      ls     lw    alpha
    ("node", "ws",                            "Node WS (baseline)",              "#339933", "--",  1.8,  0.6),
    ("deno", "ws",                            "Deno WS (baseline)",              "#1A1A1A", "--",  1.8,  0.6),
    ("bun",  "ws",                            "Bun WS (baseline)",               "#F472B6", "--",  1.8,  0.6),
    ("deno", "webtransport",                  "Deno WebTransport (native)",       "#1A1A1A", "-",   2.4,  1.0),
    ("node", "webtransport-fails-components", "Node WebTransport (fails-components)",           "#339933", "-",   2.4,  1.0),
    ("bun",  "webtransport-fails-components", "Bun WebTransport (fails-components)",            "#F472B6", "-",   2.4,  1.0),
    ("bun",  "webtransport-vmeansdev",        "Bun WebTransport (vmeansdev)",     "#c4448c", "-",   2.4,  1.0),
]

_RNG = np.random.default_rng(42)
_MAX_RTT_SAMPLES = 200_000
# Hard x-axis cap in ms: p99 of the worst run (Deno WT) is ~6.6ms; 15ms gives
# clean headroom without compressing the WebSocket curves to the left edge.
_CDF_XLIM_MS = 8.0


def load_rtts_sampled(rtts_path: Path, max_rows: int = _MAX_RTT_SAMPLES) -> np.ndarray:
    """Read rtts.csv, returning a random sample of at most max_rows rtt_ms values."""
    chunks: list[np.ndarray] = []
    for chunk in pd.read_csv(rtts_path, usecols=["rtt_ms"], chunksize=100_000):
        chunks.append(chunk["rtt_ms"].to_numpy(dtype=np.float64))

    all_rtts = np.concatenate(chunks)
    if len(all_rtts) > max_rows:
        all_rtts = _RNG.choice(all_rtts, size=max_rows, replace=False)
    return all_rtts


def chart_latency_cdf(out_dir: Path) -> None:
    run_map = build_run_dir_map("ideal")
    if not run_map:
        print("  [warn] no ideal run dirs found — skipping chart 3")
        return

    fig, ax = plt.subplots(figsize=(12, 7))
    plotted = False

    for runtime, variant, label, color, ls, lw, alpha in CDF_RUNS:
        run_dir = run_map.get((runtime, variant))
        if run_dir is None:
            print(f"  [warn] chart 3: no run dir for ({runtime}, {variant}) — skipping line")
            continue
        rtts_path = run_dir / "rtts.csv"
        if not rtts_path.exists():
            print(f"  [warn] chart 3: {rtts_path} not found — skipping line")
            continue

        rtts = load_rtts_sampled(rtts_path)
        if len(rtts) == 0:
            continue

        rtts_sorted = np.sort(rtts)
        # CDF x values: all samples ≤ xlim cap
        mask = rtts_sorted <= _CDF_XLIM_MS
        x = rtts_sorted[mask]
        # y: fraction of the *full* sample set (so the curve reaches ~1 at xlim if p99 < xlim)
        y = np.arange(1, len(x) + 1) / len(rtts_sorted)

        ax.plot(x, y, label=label, color=color, linestyle=ls, linewidth=lw, alpha=alpha)
        plotted = True

    if not plotted:
        print("  [warn] chart 3: no data plotted — skipping")
        plt.close(fig)
        return

    ax.set_title(
        "Latency CDF — All WebTransport & WebSocket Implementations (Ideal Network)",
        fontsize=13, fontweight="bold",
    )
    ax.set_xlabel("Round-Trip Time (ms)", fontsize=12)
    ax.set_ylabel("Cumulative Probability", fontsize=12)
    ax.set_ylim(0, 1.02)
    ax.set_xlim(0, _CDF_XLIM_MS)
    # Two-section legend: WebTransport entries first (solid/dash-dot), then WS baselines
    handles, labels = ax.get_legend_handles_labels()
    wt_idx = [i for i, l in enumerate(labels) if "WebTransport" in l]
    ws_idx = [i for i, l in enumerate(labels) if "WS" in l]
    ordered_h = [handles[i] for i in wt_idx + ws_idx]
    ordered_l = [labels[i]  for i in wt_idx + ws_idx]
    ax.legend(ordered_h, ordered_l, fontsize=9, title="Protocol (dashed = WebSocket baseline)")
    ax.grid(linestyle="--", alpha=0.4)
    plt.tight_layout()
    out_path = out_dir / "chart3_latency_cdf.png"
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  wrote {out_path}")


# ---------------------------------------------------------------------------
# Chart 4 — Server CPU Over Time
# ---------------------------------------------------------------------------

# Each entry: (runtime, variant, label, color, linestyle, linewidth, alpha)
# Mirrors CDF chart styling: WebSocket = dashed/low-opacity, WT FC = solid, WT vmeansdev = dash-dot
CPU_RUNS = [
    ("node", "ws",                            "Node WS (baseline)",              "#339933", "--", 1.5, 0.6),
    ("deno", "ws",                            "Deno WS (baseline)",              "#1A1A1A", "--", 1.5, 0.6),
    ("bun",  "ws",                            "Bun WS (baseline)",               "#F472B6", "--", 1.5, 0.6),
    ("deno", "webtransport",                  "Deno WebTransport (native)",       "#1A1A1A", "-",  2.0, 1.0),
    ("node", "webtransport-fails-components", "Node WebTransport (fails-components)",           "#339933", "-",  2.0, 1.0),
    ("bun",  "webtransport-fails-components", "Bun WebTransport (fails-components)",            "#F472B6", "-",  2.0, 1.0),
    ("bun",  "webtransport-vmeansdev",        "Bun WebTransport (vmeansdev)",     "#c4448c", "-", 2.0, 1.0),
]


def chart_cpu_over_time(out_dir: Path) -> None:
    run_map = build_run_dir_map("ideal")
    if not run_map:
        print("  [warn] no ideal run dirs found — skipping chart 4")
        return

    fig, ax = plt.subplots(figsize=(11, 6))
    plotted = False

    for runtime, variant, label, color, ls, lw, alpha in CPU_RUNS:
        run_dir = run_map.get((runtime, variant))
        if run_dir is None:
            print(f"  [warn] chart 4: no run dir for ({runtime}, {variant}) — skipping line")
            continue
        pidstat_path = run_dir / "pidstat.log"
        if not pidstat_path.exists():
            print(f"  [warn] chart 4: {pidstat_path} not found — skipping line")
            continue

        cpu_vals = parse_pidstat(pidstat_path)
        if not cpu_vals:
            print(f"  [warn] chart 4: no CPU data in {pidstat_path} — skipping line")
            continue

        elapsed = list(range(len(cpu_vals)))
        ax.plot(elapsed, cpu_vals, label=label, color=color, linestyle=ls, linewidth=lw, alpha=alpha)
        plotted = True

    if not plotted:
        print("  [warn] chart 4: no data plotted — skipping")
        plt.close(fig)
        return

    ax.set_title(
        "Server CPU Utilization Over Time — WebTransport vs WebSocket (Ideal Network)",
        fontsize=13, fontweight="bold",
    )
    ax.set_xlabel("Elapsed Time (seconds)", fontsize=12)
    ax.set_ylabel("Server CPU Utilization (%)", fontsize=12)
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)
    ax.legend(fontsize=10)
    ax.grid(linestyle="--", alpha=0.4)
    plt.tight_layout()
    out_path = out_dir / "chart4_cpu_over_time.png"
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  wrote {out_path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    print("Loading benchmark data...")
    df = load_all()
    print(f"  loaded {len(df)} rows across {df['Profile'].nunique()} profile(s)")

    out_dir = RESULTS_BASE / "charts"
    out_dir.mkdir(exist_ok=True)

    print("Generating charts...")
    chart_throughput_by_protocol(df, out_dir)
    chart_packet_loss_resilience(df, out_dir)
    chart_latency_cdf(out_dir)
    chart_cpu_over_time(out_dir)

    print(f"\nDone. Charts in {out_dir}/")


if __name__ == "__main__":
    main()
