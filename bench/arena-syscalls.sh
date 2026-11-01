#!/bin/sh
# Syscalls per connection on the accept path, before and after the arena
# port. The one measurement wrk cannot make: today's deny_check makes one
# time(2)-class call per accept that a map with no expiring entry does not,
# and the count must go down or stay, never up.
#
# Starts the plaintext Hello World server with ONE worker, traces that
# worker with dtruss (macOS) or strace (Linux) while wrk -c100 holds it busy
# for DURATION seconds, and prints the per-syscall totals. Both tracers need
# root: run it as `sudo sh bench/arena-syscalls.sh`.
#
# Read the accept-path calls (accept, setsockopt, fcntl, close, plus any
# time/gettimeofday/clock_gettime that is a real syscall on that kernel)
# against the number of connections wrk opened; the request-path calls
# (read, writev, kevent/epoll_wait) scale with requests, not connections.
#
# Usage: sudo sh bench/arena-syscalls.sh [DURATION] [CONNECTIONS]

set -e
cd "$(dirname "$0")/.."

DUR=${1:-10}
CONN=${2:-100}
PORT=${PORT:-8201}

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "the tracer needs root: sudo sh $0"; exit 1; }

case "$(uname -s)" in
    Darwin) TRACER=dtruss ;;
    Linux)  TRACER=strace ;;
    *)      echo "no tracer for $(uname -s)"; exit 1 ;;
esac
command -v $TRACER >/dev/null || { echo "$TRACER is not installed"; exit 1; }

PORT=$PORT perl -Mblib -e '
    use Hyperman; my $b = "Hello, World!";
    Hyperman->run(app => sub { [200, ["Content-Type", "text/plain"], [$b]] },
                  host => "127.0.0.1", port => $ENV{PORT}, workers => 1);' \
    >/dev/null 2>&1 &
sup=$!
i=0
while [ $i -lt 100 ]; do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    i=$((i + 1)); sleep 0.1
done
sleep 0.5
worker=$(pgrep -P $sup | head -1)
[ -n "$worker" ] || worker=$sup     # workers => 1 may serve from the parent

echo "tracing pid $worker ($TRACER) for ${DUR}s under wrk -t2 -c$CONN"
# wrk with a fixed connection count opens CONN connections once and keeps
# them: the accept path runs CONN times per run. -c1 style churn would need
# a client that reconnects; the ratio below is per run, so compare runs.
if [ $TRACER = dtruss ]; then
    dtruss -c -p "$worker" > "trace.$worker.txt" 2>&1 &
else
    strace -c -f -p "$worker" -o "trace.$worker.txt" &
fi
tracer=$!
sleep 1
wrk -t2 -c"$CONN" -d"${DUR}s" "http://127.0.0.1:$PORT/" | grep -E 'Requests/sec|requests in'
kill -INT $tracer 2>/dev/null || true
wait $tracer 2>/dev/null || true
kill $sup 2>/dev/null || true
pkill -P $sup 2>/dev/null || true
wait $sup 2>/dev/null || true

echo "--- syscall totals (trace.$worker.txt), $CONN connections accepted this run"
cat "trace.$worker.txt"
