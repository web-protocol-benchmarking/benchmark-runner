#!/usr/bin/env bash
# run_all_sweeps.sh — Run the full thesis sweep set unattended.
#
# Runs the three data-producing sweeps — benchmark (ideal/high_latency/
# packet_loss), crossover, and profiling — and REPEATS each one $REPEATS times
# (default 10) so tools/generate_charts.py can average across runs for tighter,
# less noise-prone estimates.
#
# Must run as root: the harness uses `ip netns` + `tc` (CAP_NET_ADMIN). The
# user-local deno/bun installs are forced onto PATH below so they resolve even
# from a bare root shell.
#
#   sudo -E ./run_all_sweeps.sh           # from the bench user's shell
#   ./run_all_sweeps.sh                   # from a root shell
#
# Env knobs:
#   REPEATS=10        how many times to repeat each sweep
#   ARCHIVE_OLD=1    move pre-existing results aside first (see below); 0 to keep
#
# ARCHIVE_OLD (on by default) moves results/{ideal,high_latency,packet_loss,
# crossover,profiling} into results/_archive_<ts>/ before the run. This matters
# after a runtime upgrade: generate_charts.py now AVERAGES every run in those
# dirs, so leaving stale runs from a different runtime version would silently
# contaminate the averages. Nothing is deleted — set ARCHIVE_OLD=0 to append to
# the existing data instead.

set -uo pipefail

REPEATS="${REPEATS:-10}"
ARCHIVE_OLD="${ARCHIVE_OLD:-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Ensure node (26, in /usr/local/bin) shadows apt's node, and that the
# user-local deno/bun installs are reachable regardless of how we were invoked.
for d in /usr/local/bin "$HOME/.bun/bin" "$HOME/.deno/bin" \
         /home/bench/.bun/bin /home/bench/.deno/bin; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
done
export PATH

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root (ip netns / tc require CAP_NET_ADMIN). Try: sudo -E $0" >&2
    exit 1
fi

echo "[run-all] runtimes: node=$(command -v node) ($(node --version 2>/dev/null)), deno=$(deno --version 2>/dev/null | head -1), bun=$(bun --version 2>/dev/null)"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p logs

SWEEPS=(sweep_benchmark sweep_crossover sweep_profiling)
PROFILE_DIRS=(ideal high_latency packet_loss crossover profiling)

# --- Archive pre-existing results so averages aren't contaminated -------------
if [[ "$ARCHIVE_OLD" == "1" ]]; then
    archive="results/_archive_${ts}"
    moved=0
    for d in "${PROFILE_DIRS[@]}"; do
        if [[ -d "results/$d" ]]; then
            mkdir -p "$archive"
            mv "results/$d" "$archive/"
            moved=1
        fi
    done
    if [[ "$moved" == "1" ]]; then
        echo "[run-all] archived previous results to $archive/ (set ARCHIVE_OLD=0 to keep & append)"
    else
        echo "[run-all] no previous results to archive"
    fi
fi

# --- Run every sweep $REPEATS times (repeat-major: rep1 all, rep2 all, ...) ----
# Repeat-major interleaving spreads each config's repeats across the whole run,
# so a transient system blip can't bias all repeats of a single config.
fails=0
start_epoch="$(date +%s)"
for rep in $(seq 1 "$REPEATS"); do
    for s in "${SWEEPS[@]}"; do
        log="logs/${ts}_rep${rep}_${s}.log"
        echo "===== $(date -u +%H:%M:%S) START rep ${rep}/${REPEATS} ${s} -> ${log} ====="
        bash "orchestration/${s}.sh" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
        if [[ "$rc" -ne 0 ]]; then
            echo "[run-all] WARNING: ${s} (rep ${rep}) exited ${rc} — continuing"
            fails=$((fails + 1))
        fi
        echo "===== $(date -u +%H:%M:%S) END   rep ${rep}/${REPEATS} ${s} (exit ${rc}) ====="
    done
done

mins=$(( ($(date +%s) - start_epoch) / 60 ))
echo
echo "[run-all] DONE in ${mins} min — ${REPEATS} repeats each of: ${SWEEPS[*]}"
echo "[run-all] ${fails} sweep invocation(s) reported a non-zero exit (see logs)."
echo "[run-all] logs: logs/${ts}_*.log"
echo "[run-all] next — regenerate charts (now averaged across all runs):"
echo "          .venv/bin/python tools/generate_charts.py"
