#!/bin/sh
# The whole-request sanity check beside the arena microbenchmarks: the
# plaintext Hello World server from BENCHMARKS.md "Reproduce", wrk -t4 -c400,
# WORKERS = 1 and 4, RUNS runs each, every number printed and the median
# marked. Co-resident, so under 10% is noise (BENCHMARKS.md, and
# bench/wrk-bench.sh's header).
#
# Usage: sh bench/arena-wrk-baseline.sh [RUNS] [DURATION]

set -e
cd "$(dirname "$0")/.."

RUNS=${1:-5}
DUR=${2:-8}
PORT=${PORT:-8200}
WORKERS_LIST=${WORKERS_LIST:-"1 4"}

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }

wait_for_port() {
    i=0
    while [ $i -lt 100 ]; do
        nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
        i=$((i + 1)); sleep 0.1
    done
    return 1
}

echo "wrk baseline: $(uname -s) $(uname -m), $(date '+%Y-%m-%d'), wrk -t4 -c400 -d${DUR}s, $RUNS runs"
for W in $WORKERS_LIST; do
    WORKERS=$W PORT=$PORT perl -Mblib -e '
        use Hyperman; my $b = "Hello, World!";
        Hyperman->run(app => sub { [200, ["Content-Type", "text/plain"], [$b]] },
                      host => "127.0.0.1", port => $ENV{PORT},
                      workers => $ENV{WORKERS});' >/dev/null 2>&1 &
    pid=$!
    wait_for_port || { echo "WORKERS=$W: never bound :$PORT"; kill $pid 2>/dev/null; exit 1; }
    wrk -t4 -c400 -d3s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true   # warmup
    vals=""
    i=0
    while [ $i -lt "$RUNS" ]; do
        rps=$(wrk -t4 -c400 -d${DUR}s "http://127.0.0.1:$PORT/" 2>/dev/null \
              | awk '/Requests\/sec/ { print $2 }')
        vals="$vals $rps"
        i=$((i + 1))
    done
    med=$(printf '%s\n' $vals | sort -n | awk '{ a[NR] = $1 } END {
        if (NR % 2) print a[(NR + 1) / 2]; else printf "%.2f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }')
    printf 'WORKERS=%s  runs:%s  median: %s req/s\n' "$W" "$vals" "$med"
    kill $pid 2>/dev/null || true
    pkill -P $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    sleep 1
done
