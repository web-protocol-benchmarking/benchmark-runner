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
RUNTIMES=(node deno bun)
PROTOCOLS=(ws sse short-polling long-polling)
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
# Server files are named for the wire protocol: short-polling.{js,ts} and
# long-polling.{js,ts} live alongside websocket.{js,ts} and sse.{js,ts}.
for runtime in "${RUNTIMES[@]}"; do
    for proto in "${PROTOCOLS[@]}"; do
        case "$runtime" in
            node) ext="js" ;;
            *)    ext="ts" ;;
        esac
        case "$proto" in
            ws)             base="websocket" ;;
            sse)            base="sse" ;;
            short-polling)  base="short-polling" ;;
            long-polling)   base="long-polling" ;;
        esac
        path="$REPO_ROOT/servers/$runtime/$base.$ext"
        [[ -f "$path" ]] || fail "server source missing: $path"
    done
done

# Node needs ws installed; Deno and Bun have no external deps.
if [[ ! -d "$REPO_ROOT/servers/node/node_modules/ws" ]]; then
    fail "ws package not installed. Run: (cd $REPO_ROOT/servers/node && npm install)"
fi

ok "pre-flight checks passed (node, deno, bun, pidstat, all server sources)"

# --- Resolve the per-combination launch command -------------------------------
server_cmd_for() {
    local runtime="$1" proto="$2"
    local base
    case "$proto" in
        ws)             base="websocket" ;;
        sse)            base="sse" ;;
        short-polling)  base="short-polling" ;;
        long-polling)   base="long-polling" ;;
    esac
    case "$runtime" in
        node) echo "node $REPO_ROOT/servers/node/$base.js" ;;
        deno) echo "deno run --allow-net --allow-env --allow-read $REPO_ROOT/servers/deno/$base.ts" ;;
        bun)  echo "bun $REPO_ROOT/servers/bun/$base.ts" ;;
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

    local client_cmd="deno run --allow-net --allow-read --allow-write --allow-env \
        $CLIENT_SCRIPT \
        --target \$SERVER_IP:\$SERVER_PORT \
        --protocol $proto \
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

    local last_row protocol_col
    last_row=$(tail -n1 "$METRICS_CSV")
    protocol_col=$(echo "$last_row" | cut -d',' -f2)
    [[ "$protocol_col" == "$proto" ]] \
        || fail "${tag}: metrics.csv row protocol=$protocol_col, expected $proto"

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
yellow "[smoke] matrix: ${#RUNTIMES[@]} runtimes x ${#PROTOCOLS[@]} protocols = $((${#RUNTIMES[@]} * ${#PROTOCOLS[@]})) runs"
yellow "[smoke] per-run: ${DURATION}s, ${CLIENTS} clients, loss=0%, delay=0ms"
echo ""

port_offset=0
for runtime in "${RUNTIMES[@]}"; do
    for proto in "${PROTOCOLS[@]}"; do
        port=$(( BASE_PORT + port_offset ))
        run_one "$runtime" "$proto" "$port"
        port_offset=$(( port_offset + 1 ))
        echo ""
    done
done

green "===================="
green "MATRIX PASSED ($((${#RUNTIMES[@]} * ${#PROTOCOLS[@]}))/$((${#RUNTIMES[@]} * ${#PROTOCOLS[@]})) combinations)"
green "===================="
echo "metrics: $METRICS_CSV"
