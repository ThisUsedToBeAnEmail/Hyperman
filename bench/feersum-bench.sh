#!/bin/sh
# Hyperman vs Feersum on an identical plaintext PSGI app, driven by wrk.
#
# Feersum is the interesting comparison, and a harder one than Starman.
# Starman is prefork Perl: a different architecture answering the same
# question. Feersum is the same architecture as Hyperman - one XS event
# loop per process, many connections per loop - so this measures the
# implementation rather than the model.
#
# FAIRNESS, and it matters more than the numbers:
#
#   * Same bench/app.psgi for every PSGI row. Same worker count.
#   * Feersum is run TWICE, because ITS KEEPALIVE DEFAULTS TO OFF.
#     Out of the box it answers every request with `Connection: close`,
#     so a keep-alive benchmark against the defaults measures TCP
#     connection setup and reports it as Feersum's speed. `feersum` is
#     the honest out-of-the-box figure; `feersum-keepalive` passes
#     --keepalive=1 and is THE LIKE-FOR-LIKE ROW, because Hyperman keeps
#     connections alive by default. Quote that one.
#   * Feersum also gets a native-interface row (bench/app.feersum), which
#     skips PSGI entirely: no $env hash, no response arrayref. It is not
#     like-for-like and is labelled `(not PSGI)`. It is here to bound how
#     much of any gap is PSGI rather than the server.
#   * Neither server recycles workers by default (Feersum's
#     max_connection_reqs and Hyperman's max_requests_per_worker are both
#     off), so no tuned row is needed on either side.
#   * Hyperman is measured through plackup as well as natively, so the
#     comparison is not flattered by skipping a layer.
#   * Every server is proved to serve the right body before it is timed,
#     a warmup run is discarded, then the best of two is taken.
#
# At one worker Feersum runs in-process, matching Hyperman's
# `workers => 1` (also in-process, no supervisor). Above one, Feersum
# gets --pre-fork=N against Hyperman's N workers.
#
# Co-resident: the load client shares these cores with the server. The
# numbers are RELATIVE - good for comparing servers on this box, not
# headline figures. Those need a separate load machine, and one Hyperman
# worker already saturates a 4-thread wrk on ten cores.
#
# Usage: sh bench/feersum-bench.sh [WORKERS] [DURATION] [CONNECTIONS]

set -e
cd "$(dirname "$0")/.."

WORKERS=${1:-1}
DUR=${2:-6}
CONN=${3:-100}
THREADS=4
PORT=${PORT:-28081}
APP=bench/app.psgi
NATIVE_APP=bench/app.feersum
PERL=$(command -v perl)

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }
"$PERL" -MFeersum -e1 2>/dev/null || { echo "Feersum is not installed"; exit 1; }
[ -d blib/arch ] || { echo "run make first: blib/arch is missing"; exit 1; }

# Feersum's pre-fork parent calls setsid() and re-forks any child that
# dies, so killing children first just breeds new ones and killing the
# parent alone orphans the pool into another session. SIGQUIT is the one
# signal its runner turns into a group shutdown, so ask for that first.
port_free() {
    ! nc -z 127.0.0.1 "$PORT" 2>/dev/null
}

wait_for_port() {
    i=0
    while [ $i -lt 100 ]; do
        nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
        i=$((i + 1))
        sleep 0.1
    done
    return 1
}

wait_for_free() {
    i=0
    while [ $i -lt 150 ]; do
        port_free && return 0
        i=$((i + 1))
        sleep 0.1
    done
    return 1
}

# A close-per-request row opens hundreds of thousands of connections and
# every one of them parks an ephemeral port in TIME_WAIT for 2*MSL. The
# range is ~16k ports wide, so it saturates, and then NOTHING can get an
# outbound port for the next half minute - not wrk, not curl, not the
# `nc -z` that asks whether the next server has bound. Skipping this wait
# does not produce a slow benchmark, it produces a benchmark where the
# row after the churn is silently reported as SKIPPED.
settle() {
    i=0
    while [ $i -lt 90 ]; do
        tw=$(netstat -an -p tcp 2>/dev/null | grep "\.$PORT " | grep -c TIME_WAIT || true)
        [ "${tw:-0}" -lt 1000 ] && return 0
        i=$((i + 1))
        sleep 1
    done
    return 0
}

stop_one() {
    pid=$1
    kill -QUIT "$pid" 2>/dev/null || true
    if ! wait_for_free; then
        kill -TERM "$pid" 2>/dev/null || true
        pkill -P "$pid" 2>/dev/null || true
        if ! wait_for_free; then
            kill -KILL "$pid" 2>/dev/null || true
            pkill -9 -P "$pid" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
    settle
    wait_for_free
}

# One server, started detached, proved, measured, stopped, port drained.
run_one() {
    name=$1
    note=$2
    shift 2

    # A leftover from the previous row would be measured as this one.
    if ! port_free; then
        echo "ABORT: :$PORT still bound before starting $name"
        exit 1
    fi

    # Keep the server's own output: a SKIPPED row with no reason is a
    # benchmark that lies quietly.
    log=${TMPDIR:-/tmp}/feersum-bench.$name.log
    "$@" >"$log" 2>&1 &
    pid=$!
    if ! wait_for_port; then
        printf '%-20s SKIPPED (never bound :%s)\n' "$name" "$PORT"
        sed -n '1,5p' "$log" | sed 's/^/                     | /'
        stop_one "$pid" || true
        return
    fi

    # Prove it serves the benchmark app before timing it. A row that
    # measures a 404, or a server still holding the port from the row
    # before, is worse than a missing row.
    body=$(curl -sS --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || true)
    if [ "$body" != "Hello, World!" ]; then
        printf '%-20s SKIPPED (served "%s", not the app)\n' "$name" "$body"
        sed -n '1,5p' "$log" | sed 's/^/                     | /'
        stop_one "$pid" || true
        return
    fi

    # Warmup, discarded: first requests pay for lazy loading, cold caches
    # and - when pre-forked - workers that have not forked yet.
    wrk -t$THREADS -c$CONN -d3s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true

    # wrk exits non-zero when it collects socket errors, and the
    # keepalive-off row collects plenty - a new connection per request
    # runs the ephemeral port range down. Under `set -e` an unguarded
    # assignment from it kills the whole benchmark half way through the
    # first server, so swallow the status and keep the errors as a note
    # against the row instead.
    best=0
    errs=
    for _ in 1 2; do
        out=$(wrk -t$THREADS -c$CONN -d${DUR}s "http://127.0.0.1:$PORT/" 2>/dev/null) || out=
        rps=$(printf '%s\n' "$out" | awk '/Requests\/sec/ { print $2 }')
        err=$(printf '%s\n' "$out" | awk '/Socket errors/ { sub(/^ *Socket errors: */, ""); print; exit }')
        [ -z "$rps" ] && rps=0
        # awk for the float compare: sh has no floating point.
        best=$(awk -v a="$best" -v b="$rps" 'BEGIN { print (b > a ? b : a) }')
        [ -n "$err" ] && errs="$err"
    done

    printf '%-20s %12s req/s  %s\n' "$name" "$best" "$note"
    [ -n "$errs" ] && printf '%-20s %12s   socket errors: %s\n' "" "" "$errs"

    stop_one "$pid" || { echo "ABORT: :$PORT would not drain after $name"; exit 1; }
}

if [ "$WORKERS" -gt 1 ]; then
    FEERSUM_FORK="--pre-fork=$WORKERS"
    FEERSUM_PREFORK=$WORKERS
else
    FEERSUM_FORK=""
    FEERSUM_PREFORK=0
fi

cat <<EOF
Hyperman vs Feersum - $WORKERS worker(s), wrk -t$THREADS -c$CONN -d${DUR}s
app: $APP (plaintext Hello, World!), keep-alive, co-resident client
EOF

run_one feersum-keepalive "like-for-like" \
    plackup -E deployment -s Feersum --port "$PORT" --keepalive=1 \
            $FEERSUM_FORK "$APP"

run_one feersum-native "(not PSGI)" \
    "$PERL" -MFeersum::Runner -e '
        my $app = do "./$ARGV[0]";
        die $@ || "could not load $ARGV[0]" unless $app;
        Feersum::Runner->new(
            listen   => [ "127.0.0.1:$ARGV[1]" ],
            pre_fork => $ARGV[2],
            keepalive => 1,
            quiet    => 1,
        )->run($app);
    ' "$NATIVE_APP" "$PORT" "$FEERSUM_PREFORK"

run_one hyperman-plackup "" \
    plackup -E deployment -s Hyperman --workers "$WORKERS" \
            --port "$PORT" "$APP"

run_one hyperman-native "" \
    "$PERL" -Iblib/lib -Iblib/arch -MHyperman -e '
        my $app = do "./$ARGV[0]";
        Hyperman->run(app => $app, host => "127.0.0.1",
                      port => $ARGV[1], workers => $ARGV[2]);
    ' "$APP" "$PORT" "$WORKERS"

# Last, and on its own, because it is the row that burns the ephemeral
# port range down and makes the next half minute unmeasurable.
run_one feersum "keepalive OFF (its default), see below" \
    plackup -E deployment -s Feersum --port "$PORT" $FEERSUM_FORK "$APP"

cat <<'EOF'

The `feersum` row is NOT a throughput figure and should not be quoted as
one. With keepalive off every request is a fresh TCP connection, so the
run exhausts this box's ~16k ephemeral ports within the first second and
spends the rest of its time waiting for TIME_WAIT to release them. What
it measures is the port range and 2*MSL, not the server - which is why it
comes with socket errors and why it moves by 25% between runs.

The finding it exists to record is the default itself: out of the box
Feersum answers `Connection: close`, and a keep-alive benchmark run
against its defaults reports connection setup as Feersum's speed.
`feersum-keepalive` is the row to compare against Hyperman.
EOF
