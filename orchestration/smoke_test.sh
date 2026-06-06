#!/usr/bin/env bash
#
# smoke_test.sh — End-to-end pipeline validation across the full runtime x
# protocol matrix (15 runtime+protocol combinations).
#
# Each combination drives a 2-second / 2-client echo run through run_test.sh
# with no network impairment, then asserts that the resulting metrics.csv
# row and per-run rtts.csv are well-formed and impairment-free. Any single
# failure aborts the matrix with a non-zero exit so we never advance to
# sweep automation on a broken pipeline.
#
# Run as root.

set -euo pipefail

# --- Paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_DIR="$REPO_ROOT/results"
METRICS_CSV="$RESULTS_DIR/metrics.csv"

# --- Matrix parameters --------------------------------------------------------
# The matrix is asymmetric — not every runtime has the same WebTransport variants.
# Deno webtransport-fails-components is excluded: the package uses internal Node.js
# socket APIs (getSendQueueCount) that Deno's compat layer does not implement.
#   node:  ws sse short-polling long-polling webtransport-fails-components          (5)
#   bun:   ws sse short-polling long-polling webtransport-vmeansdev                 (5)
#   deno:  ws sse short-polling long-polling webtransport                           (5)
# Total: 15 combinations.
DURATION=2
CLIENTS=2
MIN_RTT_SAMPLES=10
SERVER_CORES="0"      # pin server to core 0
CLIENT_CORES="1,2"    # pin client to cores 1-2 (2 cores for 2 concurrent clients)

# --- Pre-flight ---------------------------------------------------------------
run_preflight

# --- Resolve the per-combination launch command -------------------------------
run_one() {
    local runtime="$1" proto="$2" port="$3"
    local tag="$runtime $proto"

    yellow "[smoke] === ${tag} (port=${port}) ==="

    # Record metrics.csv baseline so we can detect exactly one fresh row.
    local baseline_lines=0
    if [[ -f "$METRICS_CSV" ]]; then
        baseline_lines=$(wc -l < "$METRICS_CSV")
    fi

    local server_cmd
    server_cmd=$(server_cmd_for "$runtime" "$proto")

    # All webtransport variants use --protocol webtransport on the client
    # (same WebTransport API; server backend differs). --unstable-net is
    # required on the client whenever it uses new WebTransport(...).
    local client_proto="$proto"
    local wt_flag=""
    [[ "$proto" == webtransport* ]] && client_proto="webtransport" && wt_flag="--unstable-net"
    local client_cmd="deno run --allow-net --allow-read --allow-write --allow-env $wt_flag \
        $CLIENT_SCRIPT \
        --target \$SERVER_IP:\$SERVER_PORT \
        --protocol $client_proto \
        --duration \$DURATION \
        --clients $CLIENTS"

    if ! SERVER_PORT="$port" "$RUN_TEST" \
            --server "$server_cmd" \
            --client "$client_cmd" \
            --duration "$DURATION" \
            --loss "0%" \
            --delay "0ms" \
            --port "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES"; then
        fail "${tag}: run_test.sh exited non-zero"
    fi

    # Locate newest per-run directory under results/.
    local run_dir
    run_dir=$(find "$RESULTS_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-)
    [[ -n "$run_dir" && -d "$run_dir" ]] \
        || fail "${tag}: could not locate per-run directory under $RESULTS_DIR"

    # ---- Assertion: metrics.csv has the expected header + one new row -------
    [[ -f "$METRICS_CSV" ]] || fail "${tag}: metrics.csv was not created"

    local header expected_header current_lines new_rows
    header=$(head -n1 "$METRICS_CSV")
    expected_header="Timestamp,Protocol,Concurrency,DurationSec,Throughput,p50_ms,p95_ms,p99_ms,Errors,Overflows"
    [[ "$header" == "$expected_header" ]] \
        || fail "${tag}: metrics.csv header mismatch. got: $header"

    current_lines=$(wc -l < "$METRICS_CSV")
    new_rows=$(( current_lines - baseline_lines ))
    if (( baseline_lines == 0 )); then
        (( new_rows == 2 )) \
            || fail "${tag}: expected 2 new lines (header + row) in fresh metrics.csv, got $new_rows"
    else
        (( new_rows == 1 )) \
            || fail "${tag}: expected exactly 1 new row in metrics.csv, got $new_rows"
    fi

    local last_row protocol_col expected_proto
    last_row=$(tail -n1 "$METRICS_CSV")
    protocol_col=$(echo "$last_row" | cut -d',' -f2)
    # Variant names (webtransport-*) all write "webtransport" to metrics.csv.
    expected_proto="$proto"
    [[ "$proto" == webtransport* ]] && expected_proto="webtransport"
    [[ "$protocol_col" == "$expected_proto" ]] \
        || fail "${tag}: metrics.csv row protocol=$protocol_col, expected $expected_proto"

    # ---- Assertion: rtts.csv exists with header + > MIN samples -------------
    local raw_rtts raw_header raw_samples
    raw_rtts="$run_dir/rtts.csv"
    [[ -f "$raw_rtts" ]] || fail "${tag}: rtts.csv not found at $raw_rtts"

    raw_header=$(head -n1 "$raw_rtts")
    [[ "$raw_header" == "client_id,rtt_ms" ]] \
        || fail "${tag}: rtts.csv header mismatch. got: $raw_header"

    raw_samples=$(( $(wc -l < "$raw_rtts") - 1 ))
    (( raw_samples > MIN_RTT_SAMPLES )) \
        || fail "${tag}: rtts.csv has only $raw_samples samples (expected > $MIN_RTT_SAMPLES)"

    # ---- Assertion: errors == 0 and overflows == 0 --------------------------
    local errors overflows throughput
    errors=$(echo "$last_row" | cut -d',' -f9)
    overflows=$(echo "$last_row" | cut -d',' -f10)
    throughput=$(echo "$last_row" | cut -d',' -f5)
    [[ "$errors"    == "0" ]] || fail "${tag}: errors=$errors in clean-network run (expected 0)"
    [[ "$overflows" == "0" ]] || fail "${tag}: overflows=$overflows (per-client buffer cap exceeded)"
    awk -v t="$throughput" 'BEGIN { exit !(t > 0) }' \
        || fail "${tag}: throughput=$throughput (expected > 0)"

    # ---- Assertion: server.log + pidstat.log are non-empty ------------------
    [[ -s "$run_dir/server.log"  ]] || fail "${tag}: server.log is empty"
    [[ -s "$run_dir/pidstat.log" ]] || fail "${tag}: pidstat.log is empty"

    ok "PASS: ${tag}  (samples=${raw_samples}, throughput=${throughput} msg/s)"
}

# --- Drive the full matrix ----------------------------------------------------
yellow "[smoke] matrix: 15 combinations (node×5, bun×5, deno×5)"
yellow "[smoke] per-run: ${DURATION}s, ${CLIENTS} clients, loss=0%, delay=0ms"
echo ""

port_offset=0
for runtime in "${RUNTIMES[@]}"; do
    case "$runtime" in
        node) protos=("${PROTOCOLS_NODE[@]}") ;;
        bun)  protos=("${PROTOCOLS_BUN[@]}") ;;
        deno) protos=("${PROTOCOLS_DENO[@]}") ;;
    esac
    for proto in "${protos[@]}"; do
        port=$(( BASE_PORT + port_offset ))
        run_one "$runtime" "$proto" "$port"
        port_offset=$(( port_offset + 1 ))
        echo ""
    done
done

green "===================="
green "MATRIX PASSED (all combinations)"
green "===================="
echo "metrics: $METRICS_CSV"
