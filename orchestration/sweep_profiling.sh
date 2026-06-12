#!/usr/bin/env bash
#
# sweep_profiling.sh — Targeted CPU profiling sweep for flamegraph generation.
# Driver: calls the core harness (harness_run_test.sh) with --profile.
#
# Unlike sweep_benchmark.sh (the full 45-run matrix), this profiles only the
# WebSocket baseline vs the WebTransport implementation for each runtime, under
# the IDEAL network profile ONLY (no loss/delay). perf adds observer overhead
# and produces large perf.data files, so we deliberately keep the set small.
#
# Each run is launched through harness_run_test.sh with --profile, which wraps the
# server in 'perf record -F 99 -g' and renders a flamegraph.svg per run.
#
# Output is routed to results/profiling/ (one per-run dir per combination),
# separate from the benchmark results so the chart pipeline never touches it.
#
# Run as root (ip netns / tc / perf all require elevated privileges).

set -euo pipefail

# --- Paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_BASE="$REPO_ROOT/results"
PROFILING_DIR="$RESULTS_BASE/profiling"

# --- Profiling parameters -----------------------------------------------------
# 15s is plenty of wall-clock to collect a representative flamegraph without
# bloating perf.data. Same concurrency / core pinning as the full sweep so the
# captured profile reflects the same load shape.
DURATION=30
CLIENTS=50
SERVER_CORES="0"
CLIENT_CORES="1,2"

# Ideal network only — netem impairment would add idle wait to the profile and
# obscure the FFI/crypto CPU cost we are trying to visualise.
LOSS="0%"
DELAY="0ms"

# One UTC stamp for the whole sweep — passed to every run as its dir-name prefix
# so all dirs from this invocation group together.
SWEEP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# --- Targeted combinations: WS baseline vs WT impl, per runtime ---------------
# Parallel arrays: PROFILE_RUNTIMES[i] runs PROFILE_PROTOS[i].
PROFILE_RUNTIMES=(node node                          deno deno          bun  bun)
PROFILE_PROTOS=(  ws   webtransport-fails-components  ws   webtransport  ws   webtransport-vmeansdev)

# --- Pre-flight ---------------------------------------------------------------
run_preflight

if ! command -v perf >/dev/null 2>&1; then
    fail "perf not on PATH. Install: apt-get install linux-tools-common linux-tools-\$(uname -r)"
fi
for tool in stackcollapse-perf.pl flamegraph.pl; do
    command -v "$tool" >/dev/null 2>&1 \
        || yellow "[profile] WARN: $tool not on PATH — perf.data will be captured but flamegraph.svg will not render."
done

mkdir -p "$PROFILING_DIR"

# --- Run a single profiled combination ----------------------------------------
FAILURES=0

# Human-readable label for the flamegraph title (matches chart legend wording).
profile_label() {
    local runtime="$1" proto="$2"
    local rt_name
    case "$runtime" in
        node) rt_name="Node" ;;
        deno) rt_name="Deno" ;;
        bun)  rt_name="Bun" ;;
        *)    rt_name="$runtime" ;;
    esac
    case "$proto" in
        ws)                            echo "$rt_name WebSocket" ;;
        webtransport)                  echo "$rt_name WebTransport (native)" ;;
        webtransport-fails-components) echo "$rt_name WebTransport (fails-components)" ;;
        webtransport-vmeansdev)        echo "$rt_name WebTransport (vmeansdev)" ;;
        *)                             echo "$rt_name $proto" ;;
    esac
}

run_one_profile() {
    local runtime="$1" proto="$2" port="$3"

    local server_cmd label
    server_cmd=$(server_cmd_for "$runtime" "$proto")
    label=$(profile_label "$runtime" "$proto")

    # All webtransport variants drive the client with --protocol webtransport.
    local client_proto="$proto"
    local wt_flag=""
    [[ "$proto" == webtransport* ]] && client_proto="webtransport" && wt_flag="--unstable-net"

    local client_cmd="deno run --allow-net --allow-read --allow-write --allow-env --unsafely-ignore-certificate-errors $wt_flag \
        $CLIENT_SCRIPT \
        --target \$SERVER_IP:\$SERVER_PORT \
        --protocol $client_proto \
        --duration $DURATION \
        --clients $CLIENTS"

    yellow "[profile] ideal | $runtime $proto (port=$port, ${DURATION}s, perf -F 99 -g)"

    if ! RESULTS_DIR="$PROFILING_DIR" SERVER_PORT="$port" "$RUN_TEST" \
            --server  "$server_cmd" \
            --client  "$client_cmd" \
            --duration "$DURATION" \
            --loss    "$LOSS" \
            --delay   "$DELAY" \
            --port    "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES" \
            --profile \
            --label "$label" \
            --bench-profile profiling \
            --runtime "$runtime" \
            --variant "$proto" \
            --sweep-stamp "$SWEEP_STAMP"; then
        red "  WARN: ideal | $runtime $proto — harness_run_test.sh exited non-zero" >&2
        FAILURES=$(( FAILURES + 1 ))
        return
    fi

    ok "  DONE: ideal | $runtime $proto"
}

# --- Drive the targeted set ---------------------------------------------------
# Base port distinct from smoke (8080+) and benchmark (8200+) to dodge TIME_WAIT.
PROFILING_BASE_PORT=8300

yellow "[profile] Targeted profiling: ${#PROFILE_RUNTIMES[@]} combinations, ideal network only"
yellow "[profile] duration=${DURATION}s clients=${CLIENTS} server_cores=${SERVER_CORES} client_cores=${CLIENT_CORES}"
yellow "[profile] output -> $PROFILING_DIR"
echo ""

port_offset=0
for i in "${!PROFILE_RUNTIMES[@]}"; do
    runtime="${PROFILE_RUNTIMES[$i]}"
    proto="${PROFILE_PROTOS[$i]}"
    port=$(( PROFILING_BASE_PORT + port_offset ))
    run_one_profile "$runtime" "$proto" "$port"
    port_offset=$(( port_offset + 1 ))
    echo ""
done

# --- Summary ------------------------------------------------------------------
green "===================="
green "PROFILING COMPLETE"
green "===================="
echo "Runs:     $(( port_offset ))"
echo "Failures: $FAILURES"
echo "Flamegraphs (one per run dir):"
echo "  $PROFILING_DIR/*/flamegraph.svg"

if (( FAILURES > 0 )); then
    red "$FAILURES run(s) failed — check logs in $PROFILING_DIR/" >&2
    exit 1
fi
