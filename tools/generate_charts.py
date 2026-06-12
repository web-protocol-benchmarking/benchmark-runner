#!/usr/bin/env python3
"""
generate_charts.py — Produce thesis charts from benchmark sweep results.

Reads the self-describing per-profile metrics.csv from
results/{ideal,high_latency,packet_loss,crossover}/ (each row carries its own
Profile/Runtime/ProtocolVariant/PacketLossPct/DelayMs — no annotations.csv) and
maps runs to their raw RTT/CPU data via each run dir's metadata.json.

Every chartN_<name>.png is written alongside a chartN_<name>.csv containing
exactly the data plotted, with descriptive column names, so the raw numbers
behind each figure can be analysed directly.

Charts produced in results/charts/:
  chart1_throughput_by_protocol.png  — Throughput by protocol/runtime (ideal, log scale)
  chart2_packet_loss_resilience.png  — WS vs WebTransport ideal vs packet_loss (log scale)
  chart3_latency_cdf.png             — RTT CDF for selected runs (ideal)
  chart4_cpu_over_time.png           — Server CPU % over time for WebTransport runs (ideal)
  chart5_connect_time.png            — Mean connection establishment time by protocol/runtime (ideal)
  chart6_cpu_efficiency.png          — Throughput per 1% server CPU by protocol/runtime (ideal)
  chart7_crossover.png               — Throughput vs packet loss at 50ms latency (crossover sweep)

Usage:
    python tools/generate_charts.py
"""

from __future__ import annotations

import json
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
PROFILES = ["ideal", "high_latency", "packet_loss", "crossover"]

RUNTIME_PALETTE = {"Node": "#339933", "Deno": "#1A1A1A", "Bun": "#F472B6"}
PROFILE_PALETTE = {"Ideal": "#4c8eda", "Packet Loss (1%, 20ms)": "#e05c5c"}

PROTO_LABELS: dict[str, str] = {
    "ws": "WebSocket",
    "sse": "SSE",
    "short-polling": "Short-Polling",
    "long-polling": "Long-Polling",
    "webtransport": "WebTransport",
    "webtransport-vmeansdev": "WebTransport",
    "webtransport-fails-components": "WebTransport",
}
RUNTIME_LABELS: dict[str, str] = {"node": "Node", "deno": "Deno", "bun": "Bun"}

# Canonical runtime display order for EVERY chart (bars, lines, and legends),
# applied within each protocol grouping.
RUNTIME_ORDER = ["Bun", "Deno", "Node"]

# Desired X-axis order for chart 1
PROTO_ORDER = [
    "WebSocket",
    "SSE",
    "Short-Polling",
    "Long-Polling",
    "WebTransport",
]

# ---------------------------------------------------------------------------
# Data loading helpers
# ---------------------------------------------------------------------------


def load_all() -> pd.DataFrame:
    """Load the self-describing metrics.csv from each profile (no annotations)."""
    frames: list[pd.DataFrame] = []
    for profile in PROFILES:
        metrics_path = RESULTS_BASE / profile / "metrics.csv"
        if not metrics_path.exists():
            print(f"  [warn] missing {metrics_path} — skipping profile '{profile}'")
            continue
        df = pd.read_csv(metrics_path)
        # Profile is embedded per-row; fall back to the dir name if absent.
        if "Profile" not in df.columns:
            df["Profile"] = profile
        frames.append(df)

    if not frames:
        print("No benchmark data found. Run orchestration/sweep_benchmark.sh first.")
        sys.exit(1)

    result = pd.concat(frames, ignore_index=True)

    # Latest-run-wins: if results/ holds repeated runs of the same combination
    # (a sweep re-run without clearing), keep only the most recent row per combo
    # so the metrics-based charts agree with the raw CDF/CPU charts (which use
    # build_run_dir_map's latest-by-timestamp_start dir).
    if "Timestamp" in result.columns:
        dedup_keys = [k for k in
                      ["Profile", "Runtime", "ProtocolVariant", "PacketLossPct", "DelayMs"]
                      if k in result.columns]
        result = (
            result.sort_values("Timestamp")
            .drop_duplicates(subset=dedup_keys, keep="last")
            .reset_index(drop=True)
        )

    result["RuntimeLabel"] = result["Runtime"].map(RUNTIME_LABELS)
    result["ProtoLabel"] = result["ProtocolVariant"].map(PROTO_LABELS)
    return result


def build_run_dir_map(profile: str) -> dict[tuple[str, str], Path]:
    """
    Map (runtime, protocol_variant) -> run directory, read explicitly from each
    run's metadata.json. Order-independent — no chronological zip. On duplicate
    keys (re-runs) keep the latest by timestamp_start; skip failed runs
    (client_rc != 0).
    """
    profile_dir = RESULTS_BASE / profile
    if not profile_dir.exists():
        return {}

    chosen: dict[tuple[str, str], tuple[str, Path]] = {}
    for meta_path in profile_dir.glob("*/metadata.json"):
        try:
            meta = json.loads(meta_path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        rc = meta.get("client_rc")
        if rc is not None and rc != 0:
            continue
        key = (meta.get("runtime"), meta.get("protocol_variant"))
        ts = str(meta.get("timestamp_start", ""))
        prev = chosen.get(key)
        if prev is None or ts > prev[0]:
            chosen[key] = (ts, meta_path.parent)
    return {k: v[1] for k, v in chosen.items()}


def write_chart_csv(data, out_dir: Path, stem: str) -> None:
    """Write the exact data a chart plots to out_dir/<stem>.csv (LLM-readable)."""
    df = data if isinstance(data, pd.DataFrame) else pd.DataFrame(data)
    path = out_dir / f"{stem}.csv"
    df.to_csv(path, index=False)
    print(f"  wrote {path}")


# ---------------------------------------------------------------------------
# pidstat parser
# ---------------------------------------------------------------------------


def parse_pidstat(path: Path) -> list[float]:
    """
    Parse %CPU values from a pidstat log file (server_pidstat.log / client_pidstat.log).

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

    runtime_order = RUNTIME_ORDER

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

    csv_df = (
        ideal[["RuntimeLabel", "ProtocolVariant", "Protocol", "Throughput"]]
        .rename(columns={"RuntimeLabel": "Runtime", "Throughput": "Throughput_msg_s"})
        .sort_values(["Runtime", "ProtocolVariant"])
    )
    write_chart_csv(csv_df, out_dir, "chart1_throughput_by_protocol")


# ---------------------------------------------------------------------------
# Chart 5 — Connection Establishment Time (ideal, linear scale)
# ---------------------------------------------------------------------------


def chart_connect_time(df: pd.DataFrame, out_dir: Path) -> None:
    # Restrict to the ideal profile: injected netem delays in the other
    # profiles inflate the handshake and muddy the baseline connect cost.
    if "MeanConnect_ms" not in df.columns:
        print("  [warn] no MeanConnect_ms column in metrics.csv (pre-instrumentation data) — skipping chart 5")
        return

    ideal = df[df["Profile"] == "ideal"].copy()
    if ideal.empty:
        print("  [warn] no ideal data — skipping chart 5")
        return

    # Keep only rows with a known protocol label and a recorded connect time.
    # MeanConnect_ms is blank (NaN) when every client failed to connect.
    ideal = ideal[ideal["ProtoLabel"].notna()].copy()
    ideal["MeanConnect_ms"] = pd.to_numeric(ideal["MeanConnect_ms"], errors="coerce")
    ideal = ideal[ideal["MeanConnect_ms"].notna()].copy()
    if ideal.empty:
        print("  [warn] no MeanConnect_ms data — skipping chart 5")
        return

    present_protos = set(ideal["ProtoLabel"].unique())
    x_order = [p for p in PROTO_ORDER if p in present_protos]

    runtime_order = RUNTIME_ORDER

    fig, ax = plt.subplots(figsize=(15, 7))
    sns.barplot(
        data=ideal,
        x="ProtoLabel",
        y="MeanConnect_ms",
        hue="RuntimeLabel",
        hue_order=[r for r in runtime_order if r in ideal["RuntimeLabel"].unique()],
        order=x_order,
        palette=RUNTIME_PALETTE,
        ax=ax,
    )
    # Linear scale: connect times are small (~ms) and a log axis would
    # exaggerate near-zero handshakes; we want the absolute cost visible.
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.2f}"))
    ax.set_title("Connection Establishment Time by Protocol — Ideal Network Conditions", fontsize=14, fontweight="bold")
    ax.set_xlabel("Protocol Variant", fontsize=12)
    ax.set_ylabel("Mean Connection Time (ms)", fontsize=12)
    ax.tick_params(axis="x", labelsize=9)
    ax.legend(title="Runtime", fontsize=10)
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    plt.tight_layout()
    out_path = out_dir / "chart5_connect_time.png"
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (
        ideal[["RuntimeLabel", "ProtocolVariant", "MeanConnect_ms"]]
        .rename(columns={"RuntimeLabel": "Runtime"})
        .sort_values(["Runtime", "ProtocolVariant"])
    )
    write_chart_csv(csv_df, out_dir, "chart5_connect_time")


# ---------------------------------------------------------------------------
# Chart 6 — CPU Efficiency (ideal): throughput per 1% server CPU
# ---------------------------------------------------------------------------


def chart_cpu_efficiency(df: pd.DataFrame, out_dir: Path) -> None:
    # Restrict to the ideal profile: under netem impairment the server idles
    # waiting on the wire, deflating CPU and distorting the efficiency ratio.
    ideal = df[df["Profile"] == "ideal"].copy()
    if ideal.empty:
        print("  [warn] no ideal data — skipping chart 6")
        return

    ideal = ideal[ideal["ProtoLabel"].notna()].copy()

    # Map each ideal run to its run directory so we can read its server_pidstat.log.
    run_map = build_run_dir_map("ideal")
    if not run_map:
        print("  [warn] no ideal run dirs found — skipping chart 6")
        return

    records: list[dict] = []
    for _, row in ideal.iterrows():
        key = (row["Runtime"], row["ProtocolVariant"])
        run_dir = run_map.get(key)
        if run_dir is None:
            print(f"  [warn] chart 6: no run dir for {key} — skipping")
            continue

        pidstat_path = run_dir / "server_pidstat.log"
        if not pidstat_path.exists():
            print(f"  [warn] chart 6: {pidstat_path} not found — skipping {key}")
            continue

        cpu_vals = parse_pidstat(pidstat_path)
        if not cpu_vals:
            print(f"  [warn] chart 6: no CPU samples in {pidstat_path} — skipping {key}")
            continue

        avg_cpu = sum(cpu_vals) / len(cpu_vals)
        # Guard division by zero: a server pinned to one core that never
        # registered load gives avg_cpu == 0 — efficiency is undefined.
        if avg_cpu <= 0:
            print(f"  [warn] chart 6: avg CPU is {avg_cpu} for {key} — skipping (div-by-zero)")
            continue

        records.append({
            "RuntimeLabel": row["RuntimeLabel"],
            "ProtoLabel": row["ProtoLabel"],
            "ProtocolVariant": row["ProtocolVariant"],
            "Throughput": row["Throughput"],
            "AvgServerCPUPct": avg_cpu,
            "Efficiency": row["Throughput"] / avg_cpu,
        })

    if not records:
        print("  [warn] chart 6: no efficiency data computed — skipping")
        return

    eff = pd.DataFrame(records)

    present_protos = set(eff["ProtoLabel"].unique())
    x_order = [p for p in PROTO_ORDER if p in present_protos]
    runtime_order = RUNTIME_ORDER

    fig, ax = plt.subplots(figsize=(15, 7))
    sns.barplot(
        data=eff,
        x="ProtoLabel",
        y="Efficiency",
        hue="RuntimeLabel",
        hue_order=[r for r in runtime_order if r in eff["RuntimeLabel"].unique()],
        order=x_order,
        palette=RUNTIME_PALETTE,
        ax=ax,
    )
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax.set_title("CPU Efficiency by Protocol — Ideal Network Conditions", fontsize=14, fontweight="bold")
    ax.set_xlabel("Protocol Variant", fontsize=12)
    ax.set_ylabel("CPU Efficiency (Msg/sec per 1% CPU, log scale)", fontsize=12)
    ax.tick_params(axis="x", labelsize=9)
    ax.legend(title="Runtime", fontsize=10)
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    plt.tight_layout()
    out_path = out_dir / "chart6_cpu_efficiency.png"
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (
        eff[["RuntimeLabel", "ProtocolVariant", "Throughput", "AvgServerCPUPct", "Efficiency"]]
        .rename(columns={
            "RuntimeLabel": "Runtime",
            "Throughput": "Throughput_msg_s",
            "Efficiency": "Efficiency_msg_s_per_pct",
        })
        .sort_values(["Runtime", "ProtocolVariant"])
    )
    write_chart_csv(csv_df, out_dir, "chart6_cpu_efficiency")


# ---------------------------------------------------------------------------
# Chart 7 — Crossover: throughput vs packet loss at fixed 50ms latency
# ---------------------------------------------------------------------------


def chart_crossover(df: pd.DataFrame, out_dir: Path) -> None:
    cross = df[df["Profile"] == "crossover"].copy()
    if cross.empty:
        print("  [warn] no crossover data — skipping chart 7 (run orchestration/sweep_crossover.sh)")
        return

    # PacketLossPct is an embedded, self-describing metrics column.
    if "PacketLossPct" not in cross.columns:
        print("  [warn] crossover data has no PacketLossPct column — skipping chart 7")
        return

    cross = cross[cross["ProtoLabel"].notna()].copy()
    cross["PacketLossPct"] = pd.to_numeric(cross["PacketLossPct"], errors="coerce")
    cross = cross[cross["PacketLossPct"].notna()].copy()

    # The crossover thesis is strictly WebSocket (TCP) vs WebTransport (QUIC);
    # the polling/SSE protocols only clutter the chart and bury the comparison.
    cross = cross[cross["ProtoLabel"].isin(["WebSocket", "WebTransport"])].copy()
    if cross.empty:
        print("  [warn] no usable WS/WebTransport crossover rows — skipping chart 7")
        return

    # One line per Runtime+Protocol; average throughput if a (group, loss) pair
    # was sampled more than once.
    cross["Series"] = cross["RuntimeLabel"] + " " + cross["ProtoLabel"]
    grouped = (
        cross.groupby(["Series", "RuntimeLabel", "ProtoLabel", "PacketLossPct"])["Throughput"]
        .mean()
        .reset_index()
    )

    fig, ax = plt.subplots(figsize=(13, 8))

    # Explicit draw/legend order: protocol-major, runtime-minor (Bun, Deno, Node).
    present_series = set(grouped["Series"])
    proto_classes = [p for p in ["WebSocket", "WebTransport"] if p in set(grouped["ProtoLabel"])]
    series_order = [
        f"{rt} {proto}"
        for proto in proto_classes
        for rt in RUNTIME_ORDER
        if f"{rt} {proto}" in present_series
    ]

    # WebSocket lines dashed (the TCP baseline that should collapse);
    # WebTransport lines solid + thicker (the QUIC contender that should hold up).
    for series in series_order:
        g = grouped[grouped["Series"] == series].sort_values("PacketLossPct")
        runtime = g["RuntimeLabel"].iloc[0]
        proto = g["ProtoLabel"].iloc[0]
        color = RUNTIME_PALETTE.get(runtime, "#888888")
        is_wt = proto == "WebTransport"
        ax.plot(
            g["PacketLossPct"],
            g["Throughput"],
            label=series,
            color=color,
            linestyle="-" if is_wt else "--",
            linewidth=2.6 if is_wt else 1.6,
            marker="o" if is_wt else "x",
            markersize=6 if is_wt else 5,
            alpha=1.0 if is_wt else 0.7,
        )

    # Linear y-axis: at depth-1 with 50ms latency the closed-loop throughput is
    # RTT-bound (~250-470 msg/s), so the dynamic range is small and a log scale
    # would flatten the crossover. Switch to log only if a future config makes
    # the WS drop-off span orders of magnitude.
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax.set_ylim(bottom=0)
    # Pin ticks to the swept loss levels actually present.
    loss_ticks = sorted(grouped["PacketLossPct"].unique())
    ax.set_xticks(loss_ticks)
    ax.set_xticklabels([f"{int(v) if v == int(v) else v}%" for v in loss_ticks])
    ax.set_title(
        "Crossover — Throughput vs Packet Loss at 50ms Latency\n"
        "(dashed = WebSocket / TCP, solid = WebTransport / QUIC)",
        fontsize=13, fontweight="bold",
    )
    ax.set_xlabel("Packet Loss (%)", fontsize=12)
    ax.set_ylabel("Throughput (msg/s)", fontsize=12)
    ax.legend(title="Runtime / Protocol", fontsize=9, ncol=2)
    ax.grid(which="both", linestyle="--", alpha=0.4)
    plt.tight_layout()
    out_path = out_dir / "chart7_crossover.png"
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (
        grouped[["RuntimeLabel", "ProtoLabel", "PacketLossPct", "Throughput"]]
        .rename(columns={
            "RuntimeLabel": "Runtime",
            "ProtoLabel": "Protocol",
            "Throughput": "Throughput_msg_s",
        })
        .sort_values(["Runtime", "Protocol", "PacketLossPct"])
    )
    write_chart_csv(csv_df, out_dir, "chart7_crossover")


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

    # Stable x-axis order: protocol-major (PROTO_ORDER), runtime-minor
    # (RUNTIME_ORDER = Bun, Deno, Node) — so each protocol group reads Bun→Deno→Node.
    present_groups = set(subset["GroupLabel"])
    x_order = [
        f"{rt}\n{proto}"
        for proto in PROTO_ORDER
        for rt in RUNTIME_ORDER
        if f"{rt}\n{proto}" in present_groups
    ]

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

    csv_df = (
        subset[["RuntimeLabel", "ProtocolVariant", "Profile", "Throughput"]]
        .rename(columns={"RuntimeLabel": "Runtime", "Throughput": "Throughput_msg_s"})
        .sort_values(["Runtime", "ProtocolVariant", "Profile"])
    )
    write_chart_csv(csv_df, out_dir, "chart2_packet_loss_resilience")


# ---------------------------------------------------------------------------
# Chart 3 — Latency CDF
# ---------------------------------------------------------------------------

# Each entry: (runtime, variant, display_label, color, linestyle, linewidth, alpha)
# Grouping rules:
#   WebSocket lines  — dashed (--),  alpha=0.6, lw=1.8   (background reference)
#   WebTransport FC  — solid  (-),   alpha=1.0, lw=2.4   (primary comparison)
#   WT vmeansdev     — dash-dot (-.), alpha=1.0, lw=2.4   (distinct Bun WT variant)
CDF_RUNS = [
    # Ordered Bun, Deno, Node within each protocol class (WS then WebTransport).
    # runtime                 variant                         label                              color      ls     lw    alpha
    ("bun",  "ws",                            "Bun WS (baseline)",               "#F472B6", "--",  1.8,  0.6),
    ("deno", "ws",                            "Deno WS (baseline)",              "#1A1A1A", "--",  1.8,  0.6),
    ("node", "ws",                            "Node WS (baseline)",              "#339933", "--",  1.8,  0.6),
    ("bun",  "webtransport-vmeansdev",        "Bun WebTransport (vmeansdev)",     "#F472B6", "-",   2.4,  1.0),
    ("deno", "webtransport",                  "Deno WebTransport (native)",       "#1A1A1A", "-",   2.4,  1.0),
    ("node", "webtransport-fails-components", "Node WebTransport (fails-components)",           "#339933", "-",   2.4,  1.0),
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
    cdf_records: list[dict] = []

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

        # Companion CSV: downsample the plotted curve to <=300 evenly-spaced
        # points so the data file matches the picture without being huge.
        if len(x) > 0:
            idx = np.unique(np.linspace(0, len(x) - 1, min(len(x), 300)).astype(int))
            for xi, yi in zip(x[idx], y[idx]):
                cdf_records.append({
                    "Series": label,
                    "RTT_ms": round(float(xi), 4),
                    "CumulativeProbability": round(float(yi), 5),
                })

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

    if cdf_records:
        write_chart_csv(cdf_records, out_dir, "chart3_latency_cdf")


# ---------------------------------------------------------------------------
# Chart 4 — Server CPU Over Time
# ---------------------------------------------------------------------------

# Each entry: (runtime, variant, label, color, linestyle, linewidth, alpha)
# Mirrors CDF chart styling: WebSocket = dashed/low-opacity, WT FC = solid, WT vmeansdev = dash-dot
CPU_RUNS = [
    # Ordered Bun, Deno, Node within each protocol class (WS then WebTransport).
    ("bun",  "ws",                            "Bun WS (baseline)",               "#F472B6", "--", 1.5, 0.6),
    ("deno", "ws",                            "Deno WS (baseline)",              "#1A1A1A", "--", 1.5, 0.6),
    ("node", "ws",                            "Node WS (baseline)",              "#339933", "--", 1.5, 0.6),
    ("bun",  "webtransport-vmeansdev",        "Bun WebTransport (vmeansdev)",     "#F472B6", "-",  2.0, 1.0),
    ("deno", "webtransport",                  "Deno WebTransport (native)",       "#1A1A1A", "-",  2.0, 1.0),
    ("node", "webtransport-fails-components", "Node WebTransport (fails-components)",           "#339933", "-",  2.0, 1.0),
]


def chart_cpu_over_time(out_dir: Path) -> None:
    run_map = build_run_dir_map("ideal")
    if not run_map:
        print("  [warn] no ideal run dirs found — skipping chart 4")
        return

    fig, ax = plt.subplots(figsize=(11, 6))
    plotted = False
    cpu_records: list[dict] = []

    for runtime, variant, label, color, ls, lw, alpha in CPU_RUNS:
        run_dir = run_map.get((runtime, variant))
        if run_dir is None:
            print(f"  [warn] chart 4: no run dir for ({runtime}, {variant}) — skipping line")
            continue
        pidstat_path = run_dir / "server_pidstat.log"
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

        for sec, cpu in zip(elapsed, cpu_vals):
            cpu_records.append({"Series": label, "ElapsedSec": sec, "ServerCPUPct": cpu})

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

    if cpu_records:
        write_chart_csv(cpu_records, out_dir, "chart4_cpu_over_time")


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
    chart_connect_time(df, out_dir)
    chart_cpu_efficiency(df, out_dir)
    chart_crossover(df, out_dir)

    print(f"\nDone. Charts in {out_dir}/")


if __name__ == "__main__":
    main()
