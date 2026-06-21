#!/usr/bin/env bash
#
# harness_run_test.sh — Network-namespace benchmark harness (the core engine).
#
# This is the ONE script that performs the low-level mechanics: ip netns + veth
# pair, tc netem (loss/delay), taskset CPU pinning, server/client launch, perf
# profiling. The sweep_*.sh drivers call this once per matrix combination.
#
# Creates ns_server and ns_client, connects them with a direct veth pair on a
# /30 subnet (no bridge, no loopback shortcut), applies symmetric tc netem on
# both veth egress qdiscs, launches the server in ns_server and the client in
# ns_client, and tears everything down on exit.
#
# Must be run as root (ip netns / tc require CAP_NET_ADMIN).

set -euo pipefail

# --- Topology constants -------------------------------------------------------
NS_SERVER="ns_server"
NS_CLIENT="ns_client"
VETH_SERVER="veth_s"
VETH_CLIENT="veth_c"
SERVER_IP="10.0.0.1"
CLIENT_IP="10.0.0.2"
SUBNET_PREFIX="30"
SERVER_PORT="${SERVER_PORT:-8080}"

# --- Defaults -----------------------------------------------------------------
DURATION=30
LOSS="0%"
DELAY="0ms"
SERVER_CMD=""
CLIENT_CMD=""
SERVER_CORES=""
CLIENT_CORES=""
PROFILE=0
LABEL=""
# Self-describing run dimensions (passed by the sweep_* drivers; empty for
# standalone runs, in which case the client applies its own placeholders).
BENCH_PROFILE=""
RUNTIME=""
VARIANT=""
SWEEP_STAMP=""
PIDSTAT_INTERVAL=1
RESULTS_DIR="${RESULTS_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"}"

usage() {
    cat >&2 <<EOF
Usage: $0 --server "<cmd>" --client "<cmd>" [options]

Required:
  --server CMD       Command to launch the echo server (runs in ns_server).
  --client CMD       Command to launch the load generator (runs in ns_client).

Options:
  --duration SECS      Test duration in seconds (default: ${DURATION}).
  --loss PCT           tc netem packet loss, e.g. "1%" (default: ${LOSS}).
  --delay MS           tc netem one-way delay, e.g. "20ms" (default: ${DELAY}).
  --port PORT          Server port (default: ${SERVER_PORT}).
  --server-cores LIST  taskset -c list for the server process, e.g. "0" (default: unpinned).
  --client-cores LIST  taskset -c list for the client process, e.g. "1,2" (default: unpinned).
  --profile            Wrap the server in 'perf record -F 99 -g' and, after the run,
                       render \$RUN_DIR/flamegraph.svg from the captured perf.data.
  --label TEXT         Descriptive label used as the flamegraph title (with --profile),
                       e.g. "Node WebTransport (fails-components)". Falls back to a
                       generic title if omitted.
  --bench-profile NAME Self-describing profile tag (ideal|high_latency|packet_loss|
                       crossover|profiling|smoke). Embedded in metrics.csv + metadata.json.
  --runtime NAME       Runtime under test (node|deno|bun). Embedded as a data dimension.
  --variant NAME       Full protocol variant (e.g. webtransport-fails-components).
  --sweep-stamp STAMP  Shared UTC stamp from the calling sweep, used as the run-dir name
                       PREFIX so all dirs from one command group together. Falls back to
                       this run's own start stamp when omitted (standalone runs).
  -h, --help           Show this message.

Environment exported to children:
  SERVER_IP, CLIENT_IP, SERVER_PORT, and (for the client) the self-describing
  RUN_PROFILE, RUN_RUNTIME, RUN_VARIANT, RUN_LOSS_PCT, RUN_DELAY_MS.
EOF
    exit "${1:-0}"
}

# --- Arg parsing --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)        SERVER_CMD="$2";    shift 2 ;;
        --client)        CLIENT_CMD="$2";    shift 2 ;;
        --duration)      DURATION="$2";      shift 2 ;;
        --loss)          LOSS="$2";          shift 2 ;;
        --delay)         DELAY="$2";         shift 2 ;;
        --port)          SERVER_PORT="$2";   shift 2 ;;
        --server-cores)  SERVER_CORES="$2";  shift 2 ;;
        --client-cores)  CLIENT_CORES="$2";  shift 2 ;;
        --profile)       PROFILE=1;          shift 1 ;;
        --label)         LABEL="$2";         shift 2 ;;
        --bench-profile) BENCH_PROFILE="$2"; shift 2 ;;
        --runtime)       RUNTIME="$2";       shift 2 ;;
        --variant)       VARIANT="$2";       shift 2 ;;
        --sweep-stamp)   SWEEP_STAMP="$2";   shift 2 ;;
        -h|--help)       usage 0 ;;
        *)               echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$SERVER_CMD" || -z "$CLIENT_CMD" ]] && usage 1
[[ $EUID -eq 0 ]] || { echo "Must be run as root." >&2; exit 1; }

mkdir -p "$RESULTS_DIR"

# --- Self-describing dimensions (numeric loss/delay derived from tc args) -----
LOSS_PCT="${LOSS%\%}"      # "1%"  -> "1"
DELAY_MS="${DELAY%ms}"     # "20ms" -> "20"
# Dir-name + metadata fallbacks so standalone runs never break.
TAG_PROFILE="${BENCH_PROFILE:-standalone}"
TAG_RUNTIME="${RUNTIME:-unknown}"
TAG_VARIANT="${VARIANT:-unknown}"
# Best-effort extraction of protocol + concurrency from the client command,
# purely for the metadata.json record (the harness is otherwise protocol-blind).
RUN_PROTOCOL=""
RUN_CONCURRENCY=""
[[ "$CLIENT_CMD" =~ --protocol[[:space:]]+([a-z-]+) ]] && RUN_PROTOCOL="${BASH_REMATCH[1]}"
[[ "$CLIENT_CMD" =~ --clients[[:space:]]+([0-9]+) ]]   && RUN_CONCURRENCY="${BASH_REMATCH[1]}"

# Descriptive, self-identifying run-dir name. The timestamp is a PREFIX so dirs
# from one sweep command (which all share --sweep-stamp) group together and sort
# adjacently. Standalone runs fall back to this run's own UTC start stamp.
# "__" field separator (variants use single "-"); __r<n> on collision.
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREFIX_STAMP="${SWEEP_STAMP:-$RUN_STAMP}"
RUN_TAG="${PREFIX_STAMP}__${TAG_PROFILE}__${TAG_RUNTIME}__${TAG_VARIANT}__loss${LOSS_PCT}pct__delay${DELAY_MS}ms"
RUN_DIR="$RESULTS_DIR/$RUN_TAG"
_n=0
while [[ -e "$RUN_DIR" ]]; do
    _n=$(( _n + 1 ))
    RUN_DIR="$RESULTS_DIR/${RUN_TAG}__r${_n}"
done
RUN_TAG="$(basename "$RUN_DIR")"
mkdir -p "$RUN_DIR"

SERVER_PID=""
CLIENT_PID=""
PIDSTAT_PID=""
CLIENT_PIDSTAT_PID=""
CLIENT_RC=""

# --- netem ground-truth capture -----------------------------------------------
# tc netem keeps per-qdisc counters of how many packets it actually sent vs.
# dropped. Capturing `tc -s qdisc show` before teardown lets us confirm the
# *observed* loss matches the *configured* loss — the requested rate is all the
# kernel records (per-packet drop timing is not exposed, so netem's default
# independent/Bernoulli model can be confirmed in aggregate rate only). Globals
# below feed write_metadata; default 0 when capture never ran (early failure).
NETEM_SERVER_SENT=0;  NETEM_SERVER_DROPPED=0
NETEM_CLIENT_SENT=0;  NETEM_CLIENT_DROPPED=0
# Observed loss% as a printf-ready string (kept as text so write_metadata can
# emit it verbatim without re-running awk).
observed_loss_pct() {  # $1=sent $2=dropped
    awk -v s="$1" -v d="$2" \
        'BEGIN { t = s + d; if (t > 0) printf "%.2f", (d / t) * 100; else printf "0" }'
}
capture_netem_stats() {
    [[ -z "${RUN_DIR:-}" || ! -d "$RUN_DIR" ]] && return 0
    local ns dev out line
    for spec in "$NS_SERVER:$VETH_SERVER:netem_server.txt:SERVER" \
                "$NS_CLIENT:$VETH_CLIENT:netem_client.txt:CLIENT"; do
        IFS=: read -r ns dev out side <<<"$spec"
        ip netns exec "$ns" tc -s qdisc show dev "$dev" \
            > "$RUN_DIR/$out" 2>/dev/null || true
        # Parse: " Sent <bytes> bytes <pkt> pkt (dropped <N>, overlimits ..."
        line=$(awk '
            /Sent/ {
                sent = 0; dropped = 0
                for (i = 1; i <= NF; i++) {
                    if ($i == "pkt")              sent    = $(i-1) + 0
                    if ($i ~ /^\(dropped$/)       dropped = $(i+1) + 0
                }
                printf "%d %d", sent, dropped; exit
            }' "$RUN_DIR/$out" 2>/dev/null)
        local sent="${line%% *}" dropped="${line##* }"
        [[ -z "$sent"    || ! "$sent"    =~ ^[0-9]+$ ]] && sent=0
        [[ -z "$dropped" || ! "$dropped" =~ ^[0-9]+$ ]] && dropped=0
        eval "NETEM_${side}_SENT=$sent; NETEM_${side}_DROPPED=$dropped"
    done
    local s_loss c_loss
    s_loss=$(observed_loss_pct "$NETEM_SERVER_SENT" "$NETEM_SERVER_DROPPED")
    c_loss=$(observed_loss_pct "$NETEM_CLIENT_SENT" "$NETEM_CLIENT_DROPPED")
    echo "[netem] observed loss: server=${s_loss}% (${NETEM_SERVER_DROPPED}/$((NETEM_SERVER_SENT + NETEM_SERVER_DROPPED))) client=${c_loss}% (${NETEM_CLIENT_DROPPED}/$((NETEM_CLIENT_SENT + NETEM_CLIENT_DROPPED))) | configured=${LOSS} delay=${DELAY}" >&2
}

# --- metadata.json writer -----------------------------------------------------
# Self-describing dimension+path index for each run (replaces the old
# annotations.csv + chronological-zip linkage). Written by the cleanup trap so
# it always exists — even when a run fails before producing a metrics row.
# Plain printf JSON (no jq dependency); none of the embedded values contain
# double quotes, so no escaping is required.
write_metadata() {
    local profiled_json="false" perf_json="null" flame_json="null"
    [[ "$PROFILE" -eq 1 ]] && profiled_json="true"
    [[ -f "$RUN_DIR/perf.data"      ]] && perf_json="\"perf.data\""
    [[ -f "$RUN_DIR/flamegraph.svg" ]] && flame_json="\"flamegraph.svg\""
    local rc_json="null"
    [[ -n "$CLIENT_RC" ]] && rc_json="$CLIENT_RC"
    printf '%s\n' "{
  \"schema_version\": 1,
  \"run_tag\": \"${RUN_TAG}\",
  \"timestamp_start\": \"${RUN_STAMP}\",
  \"sweep_stamp\": \"${SWEEP_STAMP}\",
  \"profile\": \"${TAG_PROFILE}\",
  \"runtime\": \"${TAG_RUNTIME}\",
  \"protocol\": \"${RUN_PROTOCOL}\",
  \"protocol_variant\": \"${TAG_VARIANT}\",
  \"packet_loss_pct\": ${LOSS_PCT:-0},
  \"delay_ms\": ${DELAY_MS:-0},
  \"netem\": {
    \"configured_loss\": \"${LOSS}\",
    \"configured_delay\": \"${DELAY}\",
    \"server_sent_pkt\": ${NETEM_SERVER_SENT:-0},
    \"server_dropped_pkt\": ${NETEM_SERVER_DROPPED:-0},
    \"server_observed_loss_pct\": $(observed_loss_pct "${NETEM_SERVER_SENT:-0}" "${NETEM_SERVER_DROPPED:-0}"),
    \"client_sent_pkt\": ${NETEM_CLIENT_SENT:-0},
    \"client_dropped_pkt\": ${NETEM_CLIENT_DROPPED:-0},
    \"client_observed_loss_pct\": $(observed_loss_pct "${NETEM_CLIENT_SENT:-0}" "${NETEM_CLIENT_DROPPED:-0}")
  },
  \"duration_sec\": ${DURATION},
  \"concurrency\": ${RUN_CONCURRENCY:-0},
  \"server_port\": ${SERVER_PORT},
  \"server_cmd\": \"${SERVER_CMD}\",
  \"server_cores\": \"${SERVER_CORES}\",
  \"client_cores\": \"${CLIENT_CORES}\",
  \"profiled\": ${profiled_json},
  \"client_rc\": ${rc_json},
  \"files\": {
    \"server_log\": \"server.log\",
    \"client_log\": \"client.log\",
    \"server_pidstat\": \"server_pidstat.log\",
    \"client_pidstat\": \"client_pidstat.log\",
    \"rtts\": \"rtts.csv\",
    \"netem_server\": \"netem_server.txt\",
    \"netem_client\": \"netem_client.txt\",
    \"perf_data\": ${perf_json},
    \"flamegraph\": ${flame_json}
  }
}" > "$RUN_DIR/metadata.json"
}

cleanup() {
    local ec=$?
    set +e
    echo "[cleanup] tearing down..." >&2

    [[ -n "$CLIENT_PID"         ]] && kill -TERM "$CLIENT_PID"         2>/dev/null
    [[ -n "$SERVER_PID"         ]] && kill -TERM "$SERVER_PID"         2>/dev/null
    [[ -n "$PIDSTAT_PID"        ]] && kill -TERM "$PIDSTAT_PID"        2>/dev/null
    [[ -n "$CLIENT_PIDSTAT_PID" ]] && kill -TERM "$CLIENT_PIDSTAT_PID" 2>/dev/null
    # wait blocks until perf (the server's parent when profiling) has caught
    # SIGTERM and flushed perf.data, so the flamegraph pipeline below sees a
    # complete capture.
    wait 2>/dev/null

    # --- netem ground-truth capture (before namespaces are torn down) --------
    # Runs while ns_server/ns_client still exist and the load has stopped, so
    # the qdisc counters reflect the whole run. Populates the NETEM_* globals
    # that write_metadata emits below.
    capture_netem_stats

    # --- Flamegraph generation (profiling runs only) -------------------------
    if [[ "${PROFILE:-0}" -eq 1 && -f "${PERF_DATA:-}" ]]; then
        echo "[cleanup] perf.data found; rendering flamegraph..." >&2
        # Descriptive title from --label (falls back to generic); subtitle carries
        # the network conditions so the SVG is self-documenting.
        local fg_title_args=()
        if [[ -n "${LABEL:-}" ]]; then
            # ASCII-only title text. A non-ASCII dash gets double-UTF-8-encoded
            # somewhere in the bash -> perl -> SVG path and renders as mojibake.
            fg_title_args=(--title "$LABEL - Server CPU" \
                           --subtitle "perf -F99 -g | loss=${LOSS} delay=${DELAY} | ${RUN_TAG}")
        fi
        if perf script -i "$PERF_DATA" \
                | stackcollapse-perf.pl \
                | flamegraph.pl "${fg_title_args[@]}" > "$RUN_DIR/flamegraph.svg" 2>"$RUN_DIR/flamegraph.err"; then
            echo "[cleanup] wrote $RUN_DIR/flamegraph.svg" >&2
            rm -f "$RUN_DIR/flamegraph.err"
        else
            echo "[cleanup] WARN: flamegraph pipeline failed; see $RUN_DIR/flamegraph.err" >&2
            rm -f "$RUN_DIR/flamegraph.svg"
        fi
    fi

    # Write the self-describing run record last, so perf.data/flamegraph.svg
    # presence and CLIENT_RC are final. Always runs (even on early failure).
    [[ -d "${RUN_DIR:-}" ]] && write_metadata

    ip netns del "$NS_SERVER" 2>/dev/null
    ip netns del "$NS_CLIENT" 2>/dev/null
    # Deleting the netns destroys veth endpoints inside it; the peer goes too.
    ip link del "$VETH_SERVER" 2>/dev/null
    ip link del "$VETH_CLIENT" 2>/dev/null

    exit "$ec"
}
trap cleanup EXIT INT TERM

# --- Topology setup -----------------------------------------------------------
echo "[setup] creating namespaces and veth pair..." >&2

# Defensive pre-cleanup in case a previous run died mid-flight.
ip netns del "$NS_SERVER" 2>/dev/null || true
ip netns del "$NS_CLIENT" 2>/dev/null || true
ip link  del "$VETH_SERVER" 2>/dev/null || true
ip link  del "$VETH_CLIENT" 2>/dev/null || true

ip netns add "$NS_SERVER"
ip netns add "$NS_CLIENT"

ip link add "$VETH_SERVER" type veth peer name "$VETH_CLIENT"
ip link set "$VETH_SERVER" netns "$NS_SERVER"
ip link set "$VETH_CLIENT" netns "$NS_CLIENT"

ip -n "$NS_SERVER" addr add "${SERVER_IP}/${SUBNET_PREFIX}" dev "$VETH_SERVER"
ip -n "$NS_CLIENT" addr add "${CLIENT_IP}/${SUBNET_PREFIX}" dev "$VETH_CLIENT"

ip -n "$NS_SERVER" link set "$VETH_SERVER" up
ip -n "$NS_CLIENT" link set "$VETH_CLIENT" up
ip -n "$NS_SERVER" link set lo up
ip -n "$NS_CLIENT" link set lo up

# --- tc netem (symmetric egress on both endpoints) ----------------------------
echo "[setup] applying netem: loss=${LOSS} delay=${DELAY} (both directions)" >&2
ip netns exec "$NS_SERVER" tc qdisc add dev "$VETH_SERVER" root netem \
    delay "$DELAY" loss "$LOSS"
ip netns exec "$NS_CLIENT" tc qdisc add dev "$VETH_CLIENT" root netem \
    delay "$DELAY" loss "$LOSS"

# --- Connectivity smoke test --------------------------------------------------
# Send several pings and require only ONE to return. A single -c1 probe is too
# fragile under the netem impairment we deliberately inject: at 50ms delay +
# 2-10% loss a lone packet is routinely dropped, aborting an otherwise-healthy
# run before launch. -c5 with a per-packet -W2 tolerates loss while still
# catching a genuinely broken topology (all 5 dropped => exit).
if ! ip netns exec "$NS_CLIENT" ping -c5 -W2 "$SERVER_IP" >/dev/null; then
    echo "[setup] sanity ping failed (0/5 replies); aborting." >&2
    exit 1
fi

# --- Launch server ------------------------------------------------------------
export SERVER_IP CLIENT_IP SERVER_PORT
SERVER_LOG="$RUN_DIR/server.log"
CLIENT_LOG="$RUN_DIR/client.log"
PIDSTAT_LOG="$RUN_DIR/server_pidstat.log"

# When profiling, wrap the server in perf record. perf must sit *inside* the
# netns exec / taskset so it profiles the actual server subtree (and inherits
# the same core pinning); -g captures call graphs, -F 99 keeps overhead low.
# On SIGTERM (sent by the cleanup trap) perf flushes perf.data and exits.
PERF_DATA="$RUN_DIR/perf.data"
PERF_PREFIX=()
if [[ "$PROFILE" -eq 1 ]]; then
    PERF_PREFIX=(perf record -F 99 -g -o "$PERF_DATA" --)
fi

echo "[run] cpu pinning: server=${SERVER_CORES:-any} client=${CLIENT_CORES:-any}" >&2
[[ "$PROFILE" -eq 1 ]] && echo "[run] profiling enabled: perf record -F 99 -g -> $PERF_DATA" >&2
echo "[run] launching server in $NS_SERVER -> $SERVER_LOG" >&2
if [[ -n "$SERVER_CORES" ]]; then
    taskset -c "$SERVER_CORES" ip netns exec "$NS_SERVER" env \
        SERVER_IP="$SERVER_IP" SERVER_PORT="$SERVER_PORT" \
        "${PERF_PREFIX[@]}" bash -c "$SERVER_CMD" >"$SERVER_LOG" 2>&1 &
else
    ip netns exec "$NS_SERVER" env \
        SERVER_IP="$SERVER_IP" SERVER_PORT="$SERVER_PORT" \
        "${PERF_PREFIX[@]}" bash -c "$SERVER_CMD" >"$SERVER_LOG" 2>&1 &
fi
SERVER_PID=$!

# Give the server a moment to bind.
sleep 1
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[run] server failed to start; see $SERVER_LOG" >&2
    exit 1
fi

# --- pidstat (host-side, by PID; sees the in-namespace process normally) ------
echo "[run] starting pidstat (interval=${PIDSTAT_INTERVAL}s) -> $PIDSTAT_LOG" >&2
pidstat -h -r -u -p "$SERVER_PID" "$PIDSTAT_INTERVAL" >"$PIDSTAT_LOG" 2>&1 &
PIDSTAT_PID=$!

# --- Launch client ------------------------------------------------------------
echo "[run] launching client in $NS_CLIENT for ${DURATION}s -> $CLIENT_LOG" >&2
if [[ -n "$CLIENT_CORES" ]]; then
    taskset -c "$CLIENT_CORES" ip netns exec "$NS_CLIENT" env \
        SERVER_IP="$SERVER_IP" CLIENT_IP="$CLIENT_IP" SERVER_PORT="$SERVER_PORT" \
        DURATION="$DURATION" RESULTS_DIR="$RUN_DIR" \
        RUN_PROFILE="$BENCH_PROFILE" RUN_RUNTIME="$RUNTIME" RUN_VARIANT="$VARIANT" \
        RUN_LOSS_PCT="$LOSS_PCT" RUN_DELAY_MS="$DELAY_MS" \
        bash -c "$CLIENT_CMD" >"$CLIENT_LOG" 2>&1 &
else
    ip netns exec "$NS_CLIENT" env \
        SERVER_IP="$SERVER_IP" CLIENT_IP="$CLIENT_IP" SERVER_PORT="$SERVER_PORT" \
        DURATION="$DURATION" RESULTS_DIR="$RUN_DIR" \
        RUN_PROFILE="$BENCH_PROFILE" RUN_RUNTIME="$RUNTIME" RUN_VARIANT="$VARIANT" \
        RUN_LOSS_PCT="$LOSS_PCT" RUN_DELAY_MS="$DELAY_MS" \
        bash -c "$CLIENT_CMD" >"$CLIENT_LOG" 2>&1 &
fi
CLIENT_PID=$!

# --- client pidstat (bottleneck verification) ---------------------------------
CLIENT_PIDSTAT_LOG="$RUN_DIR/client_pidstat.log"
echo "[run] starting client pidstat (interval=${PIDSTAT_INTERVAL}s) -> $CLIENT_PIDSTAT_LOG" >&2
pidstat -h -r -u -p "$CLIENT_PID" "$PIDSTAT_INTERVAL" >"$CLIENT_PIDSTAT_LOG" 2>&1 &
CLIENT_PIDSTAT_PID=$!

# Wait for the client to finish (it owns the test duration).
wait "$CLIENT_PID"
CLIENT_RC=$?

# Stop client pidstat so the log is flushed before we parse it.
# Ignore the wait exit code — pidstat exits non-zero when killed by SIGTERM,
# and set -e would otherwise abort the script before the saturation check.
kill -TERM "$CLIENT_PIDSTAT_PID" 2>/dev/null
wait "$CLIENT_PIDSTAT_PID" 2>/dev/null || true
CLIENT_PIDSTAT_PID=""

# --- CPU saturation check -----------------------------------------------------
# Threshold: 90% of the cores allocated to the client. With CLIENT_CORES="1,2"
# that is 2 cores × 90 = 180% (pidstat reports per-process %CPU uncapped).
if [[ -f "$CLIENT_PIDSTAT_LOG" ]]; then
    CORE_COUNT=1
    if [[ -n "$CLIENT_CORES" ]]; then
        CORE_COUNT=$(echo "$CLIENT_CORES" | tr ',' '\n' | wc -l)
    fi
    THRESHOLD=$(awk -v c="$CORE_COUNT" 'BEGIN { printf "%d", c * 90 }')

    AVG_CPU=$(awk '
        /^#/      { next }
        /^[0-9]/  { if ($8+0 > 0) { sum += $8; n++ } }
        END       { if (n > 0) printf "%.1f", sum/n; else print "0" }
    ' "$CLIENT_PIDSTAT_LOG")

    PEAK_CPU=$(awk '
        /^#/      { next }
        /^[0-9]/  { if ($8+0 > max) max = $8 }
        END       { printf "%.1f", max+0 }
    ' "$CLIENT_PIDSTAT_LOG")

    if awk -v avg="$AVG_CPU" -v peak="$PEAK_CPU" -v thr="$THRESHOLD" \
            'BEGIN { exit !(avg >= thr || peak >= thr) }'; then
        echo "" >&2
        echo "╔══════════════════════════════════════════════════════════════════╗" >&2
        echo "║  !! WARNING: CLIENT CPU SATURATION DETECTED                   !!" >&2
        echo "║  avg=${AVG_CPU}%  peak=${PEAK_CPU}%  threshold=${THRESHOLD}% (${CORE_COUNT} core(s) x 90%)" >&2
        echo "║  The load generator may be the bottleneck.                      ║" >&2
        echo "║  Benchmark data for this run may be INVALID.                    ║" >&2
        echo "╚══════════════════════════════════════════════════════════════════╝" >&2
        echo "" >&2
    else
        echo "[run] client cpu ok: avg=${AVG_CPU}% peak=${PEAK_CPU}% (threshold=${THRESHOLD}%)" >&2
    fi
fi

echo "[run] client exited rc=$CLIENT_RC; results in $RUN_DIR" >&2
exit "$CLIENT_RC"
