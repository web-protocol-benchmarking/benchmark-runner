#!/usr/bin/env bash
#
# run_crossover.sh — Packet-loss crossover sweep at fixed latency.
#
# Holds one-way delay flat at 50ms and sweeps packet loss across
# 0/1/2/5/10%, running the full 15-combo matrix at each loss level. The goal
# is to find the crossover point: WebSocket (kernel TCP) throughput should
# collapse as loss rises (head-of-line blocking + retransmits), while
# WebTransport (QUIC) degrades far more gracefully and eventually overtakes it.
#
# Output is routed to results/crossover/ with a metrics.csv and an
# annotations.csv sidecar. Unlike the main benchmark, the annotation carries a
# 4th PacketLoss column so the chart generator can use loss as the X-axis.
#
# Does NOT abort on individual run failures — increments a counter and
# continues so one flaky run doesn't waste the sweep.
#
# Run as root.

set -euo pipefail

# --- Paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_BASE="$REPO_ROOT/results"
CROSSOVER_DIR="$RESULTS_BASE/crossover"

# --- Benchmark parameters -----------------------------------------------------
DURATION=10
CLIENTS=50
SERVER_CORES="0"
CLIENT_CORES="1,2"

# --- Sweep axes ---------------------------------------------------------------
# Latency held flat; packet loss is the swept variable.
DELAY="50ms"
LOSS_LEVELS=("0%" "1%" "2%" "5%" "10%")

# --- Crossover protocol set (WS vs WebTransport ONLY) -------------------------
# The crossover thesis compares kernel-TCP WebSocket against QUIC WebTransport.
# The SSE / polling protocols are not part of that comparison and tripled the
# sweep runtime, so they are excluded here (chart 7 filters to WS+WT anyway).
# Each runtime keeps its own WebTransport variant.
PROTOS_CROSSOVER_NODE=(ws webtransport-fails-components)
PROTOS_CROSSOVER_BUN=(ws webtransport-vmeansdev)
PROTOS_CROSSOVER_DENO=(ws webtransport)

# --- Pre-flight ---------------------------------------------------------------
run_preflight

mkdir -p "$CROSSOVER_DIR"

METRICS_CSV="$CROSSOVER_DIR/metrics.csv"
ANNOTATIONS_CSV="$CROSSOVER_DIR/annotations.csv"
if [[ ! -f "$ANNOTATIONS_CSV" ]]; then
    printf 'Timestamp,Runtime,ProtocolVariant,PacketLoss\n' > "$ANNOTATIONS_CSV"
fi

# --- Run a single combination at a given loss level ---------------------------
FAILURES=0

run_one_crossover() {
    local loss="$1" runtime="$2" proto="$3" port="$4"

    local server_cmd
    server_cmd=$(server_cmd_for "$runtime" "$proto")

    local client_proto="$proto"
    local wt_flag=""
    [[ "$proto" == webtransport* ]] && client_proto="webtransport" && wt_flag="--unstable-net"

    local client_cmd="deno run --allow-net --allow-read --allow-write --allow-env $wt_flag \
        $CLIENT_SCRIPT \
        --target \$SERVER_IP:\$SERVER_PORT \
        --protocol $client_proto \
        --duration $DURATION \
        --clients $CLIENTS"

    yellow "[crossover] loss=$loss delay=$DELAY | $runtime $proto (port=$port)"

    if ! RESULTS_DIR="$CROSSOVER_DIR" SERVER_PORT="$port" "$RUN_TEST" \
            --server  "$server_cmd" \
            --client  "$client_cmd" \
            --duration "$DURATION" \
            --loss    "$loss" \
            --delay   "$DELAY" \
            --port    "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES"; then
        red "  WARN: loss=$loss | $runtime $proto — run_test.sh exited non-zero (skipping annotation)" >&2
        FAILURES=$(( FAILURES + 1 ))
        return
    fi

    # Annotate the freshly-appended metrics row with runtime, protocol, and the
    # numeric loss level (strip the % so the chart axis is numeric).
    local ts loss_num
    ts=$(tail -n1 "$METRICS_CSV" | cut -d',' -f1)
    loss_num="${loss%\%}"
    printf '%s,%s,%s,%s\n' "$ts" "$runtime" "$proto" "$loss_num" >> "$ANNOTATIONS_CSV"

    ok "  DONE: loss=$loss | $runtime $proto"
}

# --- Full sweep ---------------------------------------------------------------
# Base port distinct from smoke (8080+), benchmark (8200+), profiling (8300+).
CROSSOVER_BASE_PORT=8400

combos_per_level=$(( ${#PROTOS_CROSSOVER_NODE[@]} + ${#PROTOS_CROSSOVER_BUN[@]} + ${#PROTOS_CROSSOVER_DENO[@]} ))
total_runs=$(( ${#LOSS_LEVELS[@]} * combos_per_level ))
yellow "[crossover] Sweep: ${#LOSS_LEVELS[@]} loss levels x $combos_per_level combos (WS+WT) = $total_runs runs (delay flat at $DELAY)"
yellow "[crossover] duration=${DURATION}s clients=${CLIENTS} server_cores=${SERVER_CORES} client_cores=${CLIENT_CORES}"
yellow "[crossover] output -> $CROSSOVER_DIR"
echo ""

port_offset=0
for loss in "${LOSS_LEVELS[@]}"; do
    yellow "=== Loss level: $loss (delay=$DELAY) ==="

    for runtime in "${RUNTIMES[@]}"; do
        case "$runtime" in
            node) protos=("${PROTOS_CROSSOVER_NODE[@]}") ;;
            bun)  protos=("${PROTOS_CROSSOVER_BUN[@]}") ;;
            deno) protos=("${PROTOS_CROSSOVER_DENO[@]}") ;;
        esac
        for proto in "${protos[@]}"; do
            port=$(( CROSSOVER_BASE_PORT + port_offset ))
            run_one_crossover "$loss" "$runtime" "$proto" "$port"
            port_offset=$(( port_offset + 1 ))
            echo ""
        done
    done

    green "=== Loss level $loss COMPLETE ==="
    echo ""
done

# --- Summary ------------------------------------------------------------------
green "===================="
green "CROSSOVER SWEEP COMPLETE"
green "===================="
echo "Runs:     $(( port_offset ))"
echo "Failures: $FAILURES"
echo "Results:  $METRICS_CSV"

if (( FAILURES > 0 )); then
    red "$FAILURES run(s) failed — check logs in $CROSSOVER_DIR/" >&2
    exit 1
fi
