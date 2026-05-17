#!/usr/bin/env bash
#
# smoke_test.sh — End-to-end pipeline validation across the full runtime x
# protocol matrix (3 runtimes x 3 protocols = 9 combinations).
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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_TEST="$SCRIPT_DIR/run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_DIR="$REPO_ROOT/results"
METRICS_CSV="$RESULTS_DIR/metrics.csv"

# --- Matrix parameters --------------------------------------------------------
# The matrix is asymmetric — not every runtime has the same WebTransport variants.
# Deno webtransport-fails-components is excluded: the package uses internal Node.js
# socket APIs (getSendQueueCount) that Deno's compat layer does not implement.
#   node:  ws sse short-polling long-polling webtransport-fails-components          (5)
#   bun:   ws sse short-polling long-polling webtransport-vmeansdev wt-fc           (6)
#   deno:  ws sse short-polling long-polling webtransport                           (5)
# Total: 16 combinations.
RUNTIMES=(node deno bun)
PROTOCOLS_NODE=(ws sse short-polling long-polling webtransport-fails-components)
PROTOCOLS_BUN=(ws sse short-polling long-polling webtransport-vmeansdev webtransport-fails-components)
PROTOCOLS_DENO=(ws sse short-polling long-polling webtransport)
DURATION=2
CLIENTS=2
MIN_RTT_SAMPLES=10
BASE_PORT=8080  # bump per combination to dodge TIME_WAIT on rapid reruns

# --- Pretty output ------------------------------------------------------------
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

fail() { red "FAIL: $*" >&2; exit 1; }
ok()   { green "OK:   $*"; }

# --- Pre-flight: privileges + dependencies ------------------------------------
[[ $EUID -eq 0 ]] || fail "must be run as root (ip netns / tc require CAP_NET_ADMIN)"

[[ -x "$RUN_TEST" ]]      || fail "run_test.sh not found or not executable: $RUN_TEST"
[[ -f "$CLIENT_SCRIPT" ]] || fail "load_generator.ts not found: $CLIENT_SCRIPT"

for bin in node deno bun pidstat; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        case "$bin" in
            deno)    fail "deno not on PATH. Install: curl -fsSL https://deno.land/install.sh | sh" ;;
            bun)     fail "bun not on PATH. Install: curl -fsSL https://bun.sh/install | bash" ;;
            node)    fail "node not on PATH. Install Node.js >= 20." ;;
            pidstat) fail "pidstat not on PATH. Install: apt-get install sysstat" ;;
        esac
    fi
done

# Each (runtime, protocol) needs the corresponding server source file present.
proto_to_base() {
    case "$1" in
        ws)                            echo "websocket" ;;
        sse)                           echo "sse" ;;
        short-polling)                 echo "short-polling" ;;
        long-polling)                  echo "long-polling" ;;
        webtransport)                  echo "webtransport" ;;
        webtransport-fails-components) echo "webtransport-fails-components" ;;
        webtransport-vmeansdev)        echo "webtransport-vmeansdev" ;;
    esac
}
check_sources() {
    local runtime="$1" ext="$2"
    shift 2
    for proto in "$@"; do
        local base path
        base=$(proto_to_base "$proto")
        path="$REPO_ROOT/servers/$runtime/$base.$ext"
        [[ -f "$path" ]] || fail "server source missing: $path"
    done
}
check_sources node js "${PROTOCOLS_NODE[@]}"
check_sources bun  ts "${PROTOCOLS_BUN[@]}"
check_sources deno ts "${PROTOCOLS_DENO[@]}"

# Check required npm packages are installed.
if [[ ! -d "$REPO_ROOT/servers/node/node_modules/ws" ]]; then
    fail "ws not installed. Run: (cd $REPO_ROOT/servers/node && npm install)"
fi
if [[ ! -d "$REPO_ROOT/servers/node/node_modules/@fails-components/webtransport" ]]; then
    fail "@fails-components/webtransport not installed in node. Run: (cd $REPO_ROOT/servers/node && npm install)"
fi
if [[ ! -d "$REPO_ROOT/servers/bun/node_modules/@webtransport-bun" ]]; then
    fail "@webtransport-bun/webtransport not installed. Run: (cd $REPO_ROOT/servers/bun && bun install)"
fi
if [[ ! -d "$REPO_ROOT/servers/bun/node_modules/@fails-components/webtransport" ]]; then
    fail "@fails-components/webtransport not installed in bun. Run: (cd $REPO_ROOT/servers/bun && bun add @fails-components/webtransport @fails-components/webtransport-transport-http3-quiche && bun pm trust @fails-components/webtransport-transport-http3-quiche)"
fi

ok "pre-flight checks passed (node, deno, bun, pidstat, all server sources)"

# --- Resolve the per-combination launch command -------------------------------
server_cmd_for() {
    local runtime="$1" proto="$2"
    local base
    local base
    base=$(proto_to_base "$proto")
    case "$runtime" in
        node) echo "node $REPO_ROOT/servers/node/$base.js" ;;
        deno)
            if [[ "$proto" == "webtransport" ]]; then
                echo "deno run --allow-net --allow-env --allow-read --unstable-net $REPO_ROOT/servers/deno/$base.ts"
            elif [[ "$proto" == "webtransport-fails-components" ]]; then
                echo "deno run --allow-net --allow-env --allow-read --allow-ffi $REPO_ROOT/servers/deno/$base.ts"
            else
                echo "deno run --allow-net --allow-env --allow-read $REPO_ROOT/servers/deno/$base.ts"
            fi
            ;;
        bun) echo "bun $REPO_ROOT/servers/bun/$base.ts" ;;
    esac
}

# --- Run a single (runtime, protocol) combination + assert --------------------
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
            --port "$port"; then
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
yellow "[smoke] matrix: 16 combinations (node×5, bun×6, deno×5)"
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
