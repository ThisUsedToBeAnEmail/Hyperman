#!/bin/sh
# Hyperman vs Starman on an identical plaintext PSGI app, driven by wrk.
#
# wrk rather than a Perl load client on purpose: a Perl client competes
# with the server for the same runtime, and a benchmark whose client is
# the thing under test measures the client. bench/bench.pl is the
# dependency-free version of this; this one is for numbers that leave
# the building.
#
# FAIRNESS, and it matters more than the numbers:
#
#   * Same app.psgi for every server. Same worker count. Keep-alive on
#     everywhere (both servers default to it).
#   * Starman is run TWICE. Its max_requests defaults to 1000, so a
#     worker recycles after a thousand requests - over a run this size
#     that measures fork(), not serving. `starman` is the honest
#     out-of-the-box figure and `starman-tuned` raises it, which is what
#     anyone benchmarking would do. Hyperman's equivalent
#     (max_requests_per_worker) is off by default, so the tuned row is
#     the like-for-like one.
#   * Starman gets --preload-app, which helps it.
#   * Hyperman is measured through plackup as well as natively, so the
#     comparison is not flattered by skipping a layer Starman cannot.
#   * A warmup run is discarded, then the best of two is taken.
#
# Co-resident: the load client shares these cores with the server. The
# numbers are RELATIVE - good for comparing servers on this box, not
# headline figures. Those need a separate load machine.
#
# Usage: sh bench/wrk-bench.sh [WORKERS] [DURATION] [CONNECTIONS]

set -e
cd "$(dirname "$0")/.."

WORKERS=${1:-1}
DUR=${2:-6}
CONN=${3:-100}
THREADS=4
PORT=${PORT:-28080}
APP=bench/app.psgi
PERL=$(command -v perl)

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }

wait_for_port() {
    i=0
    while [ $i -lt 100 ]; do
        if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then return 0; fi
        i=$((i + 1))
        sleep 0.1
    done
    return 1
}

# One server, started detached, measured, killed, port drained.
run_one() {
    name=$1
    shift
    "$@" >/dev/null 2>&1 &
    pid=$!
    if ! wait_for_port; then
        printf '%-18s SKIPPED (never bound :%s)\n' "$name" "$PORT"
        kill $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
        sleep 1
        return
    fi

    # Warmup, discarded: first requests pay for lazy loading, cold caches
    # and - for a prefork server - workers that have not forked yet.
    wrk -t$THREADS -c$CONN -d3s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true

    best=0
    for _ in 1 2; do
        out=$(wrk -t$THREADS -c$CONN -d${DUR}s "http://127.0.0.1:$PORT/" 2>/dev/null)
        rps=$(printf '%s\n' "$out" | awk '/Requests\/sec/ { print $2 }')
        err=$(printf '%s\n' "$out" | awk '/Socket errors/ { print; exit }')
        [ -z "$rps" ] && rps=0
        # awk for the float compare: sh has no floating point.
        best=$(awk -v a="$best" -v b="$rps" 'BEGIN { print (b > a ? b : a) }')
        [ -n "$err" ] && printf '%-18s note: %s\n' "$name" "$err"
    done

    printf '%-18s %12s req/s\n' "$name" "$best"

    # Kill the group: both servers are supervisors with children.
    kill $pid 2>/dev/null || true
    pkill -P $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    sleep 1
}

cat <<EOF
Hyperman vs Starman - $WORKERS worker(s), wrk -t$THREADS -c$CONN -d${DUR}s
app: $APP (plaintext Hello, World!), keep-alive, co-resident client
EOF

run_one starman \
    starman --workers "$WORKERS" --port "$PORT" --preload-app "$APP"

run_one starman-tuned \
    starman --workers "$WORKERS" --port "$PORT" --preload-app \
            --max-requests 1000000 "$APP"

run_one hyperman-plackup \
    plackup -E deployment -s Hyperman --workers "$WORKERS" \
            --port "$PORT" "$APP"

run_one hyperman-native \
    "$PERL" -Iblib/lib -Iblib/arch -MHyperman -e '
        my $app = do "./$ARGV[0]";
        Hyperman->run(app => $app, host => "127.0.0.1",
                      port => $ARGV[1], workers => $ARGV[2]);
    ' "$APP" "$PORT" "$WORKERS"
