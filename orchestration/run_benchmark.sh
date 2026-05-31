#!/usr/bin/env bash
#
# run_benchmark.sh — Full thesis sweep: 3 network profiles x 16 runtime+protocol
# combos = 48 timed runs.
#
# Per-profile output is routed to results/<profile>/ with a metrics.csv and an
# annotations.csv sidecar (Timestamp,Runtime,ProtocolVariant) that the chart
# generator joins on to add Runtime and Profile dimensions.
#
# Does NOT abort on individual run failures — increments a failure counter and
# continues so a single flaky run doesn't waste the rest of the sweep.
#
# Run as root.

set -euo pipefail

# --- Paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_BASE="$REPO_ROOT/results"

# --- Benchmark parameters -----------------------------------------------------
DURATION=30
CLIENTS=50
SERVER_CORES="0"
CLIENT_CORES="1,2"

# --- Network profiles (parallel arrays) ---------------------------------------
#   ideal        — clean network, baseline throughput
#   high_latency — 50ms one-way delay, tests head-of-line blocking
#   packet_loss  — 1% loss + 20ms delay, tests retransmission resilience
PROFILE_NAMES=(ideal      high_latency  packet_loss)
PROFILE_LOSS=( "0%"       "0%"          "1%"       )
PROFILE_DELAY=("0ms"      "50ms"        "20ms"     )

# --- Pre-flight ---------------------------------------------------------------
run_preflight

# --- Run a single combination under a given profile ---------------------------
FAILURES=0

run_one_benchmark() {
    local profile="$1" loss="$2" delay="$3" runtime="$4" proto="$5" port="$6"
    local profile_dir="$RESULTS_BASE/$profile"
    local metrics_csv="$profile_dir/metrics.csv"
    local annotations_csv="$profile_dir/annotations.csv"

    mkdir -p "$profile_dir"

    if [[ ! -f "$annotations_csv" ]]; then
        printf 'Timestamp,Runtime,ProtocolVariant\n' > "$annotations_csv"
    fi

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

    yellow "[bench] $profile | $runtime $proto (port=$port, loss=$loss, delay=$delay)"

    if ! RESULTS_DIR="$profile_dir" SERVER_PORT="$port" "$RUN_TEST" \
            --server  "$server_cmd" \
            --client  "$client_cmd" \
            --duration "$DURATION" \
            --loss    "$loss" \
            --delay   "$delay" \
            --port    "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES"; then
        red "  WARN: $profile | $runtime $proto — run_test.sh exited non-zero (skipping annotation)" >&2
        FAILURES=$(( FAILURES + 1 ))
        return
    fi

    # Capture the timestamp of the freshly-appended metrics row and annotate.
    local ts
    ts=$(tail -n1 "$metrics_csv" | cut -d',' -f1)
    printf '%s,%s,%s\n' "$ts" "$runtime" "$proto" >> "$annotations_csv"

    ok "  DONE: $profile | $runtime $proto"
}

# --- Full sweep ---------------------------------------------------------------
# Use ports starting at 8200 to avoid TIME_WAIT collision with smoke (8080–8095).
BENCHMARK_BASE_PORT=8200

yellow "[bench] Starting full sweep: ${#PROFILE_NAMES[@]} profiles x 16 combos = 48 runs"
yellow "[bench] duration=${DURATION}s  clients=${CLIENTS}  server_cores=${SERVER_CORES}  client_cores=${CLIENT_CORES}"
echo ""

port_offset=0
for pi in "${!PROFILE_NAMES[@]}"; do
    profile="${PROFILE_NAMES[$pi]}"
    loss="${PROFILE_LOSS[$pi]}"
    delay="${PROFILE_DELAY[$pi]}"

    yellow "=== Profile: $profile (loss=$loss, delay=$delay) ==="

    for runtime in "${RUNTIMES[@]}"; do
        case "$runtime" in
            node) protos=("${PROTOCOLS_NODE[@]}") ;;
            bun)  protos=("${PROTOCOLS_BUN[@]}") ;;
            deno) protos=("${PROTOCOLS_DENO[@]}") ;;
        esac
        for proto in "${protos[@]}"; do
            port=$(( BENCHMARK_BASE_PORT + port_offset ))
            run_one_benchmark "$profile" "$loss" "$delay" "$runtime" "$proto" "$port"
            port_offset=$(( port_offset + 1 ))
            echo ""
        done
    done

    green "=== Profile $profile COMPLETE ==="
    echo ""
done

# --- Summary ------------------------------------------------------------------
green "===================="
green "SWEEP COMPLETE"
green "===================="
echo "Runs:     $(( port_offset ))"
echo "Failures: $FAILURES"
echo "Results:"
for name in "${PROFILE_NAMES[@]}"; do
    echo "  $RESULTS_BASE/$name/metrics.csv"
done

if (( FAILURES > 0 )); then
    red "$FAILURES run(s) failed — check logs in $RESULTS_BASE/" >&2
    exit 1
fi
