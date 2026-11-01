#!/bin/sh
# HTTP/1.1 vs HTTP/2 vs HTTP/3 on Hyperman, over TLS, from one client.
#
# FAIRNESS, and it matters more than the numbers:
#
#   * TLS ON ALL THREE. HTTP/3 has no cleartext mode, so measuring it against
#     plaintext h1 or h2c would fold the whole cost of the record layer into
#     "the cost of HTTP/3". Every row below is behind the same certificate.
#
#   * ONE SERVER, ONE LISTENER, ONE PORT. bench/proto-server.pl turns on
#     http2 and http3 on a single TLS listener, so the worker count, the
#     build, the page cache and the machine's mood are identical across the
#     three rows and the only difference on the wire is the protocol. Three
#     servers measured one after another would fold whatever drifted between
#     them into the comparison.
#
#   * ONE CLIENT, and this is the constraint that shapes the whole script.
#     h2load is the usual tool here and it CANNOT be used: the build on this
#     machine has no QUIC linked at all, and its --h3 is shorthand for an
#     ALPN string over TCP - it would quietly measure h1 three times. curl
#     with an HTTP3 feature is the only thing here that speaks all three, so
#     curl drives all three. A different client per protocol would measure
#     the clients.
#
#   * --http3-only, never --http3, so a QUIC failure cannot be silently
#     scored as a fast TCP request.
#
# WHAT THIS IS NOT: an absolute throughput figure. curl is a transfer tool,
# not a load generator; it is here because it is the only fair one. Compare
# the rows to each other, not to a number from wrk or h2load. For absolute
# HTTP/1.1 and HTTP/2 throughput use bench/wrk-tls.sh and the h2load figures
# in BENCHMARKS.md.
#
# Usage: bench/proto-bench.sh [requests] [concurrency]
set -e

N=${1:-20000}
C=${2:-50}
PORT=${PORT:-19700}
WORKERS=${WORKERS:-1}
RUNS=${RUNS:-3}

# A curl with HTTP/3 in its FEATURE list - not one that merely accepts the
# flag. That distinction is the whole reason this script exists in the shape
# it does.
CURL=""
for c in /opt/homebrew/opt/curl/bin/curl /usr/local/opt/curl/bin/curl \
         $(command -v curl 2>/dev/null); do
    [ -x "$c" ] || continue
    if "$c" --version 2>/dev/null | grep -q '^Features:.*HTTP3'; then
        CURL="$c"; break
    fi
done
if [ -z "$CURL" ]; then
    echo "no HTTP/3-capable curl found." >&2
    echo "  macOS:  brew install curl   (keg-only; its bottle links ngtcp2+nghttp3)" >&2
    echo "  check:  curl --version | grep -o HTTP3" >&2
    exit 1
fi

DIR=$(mktemp -d "${TMPDIR:-/tmp}/hm-proto-bench.XXXXXX")
trap 'kill $SRV 2>/dev/null; rm -rf "$DIR"' EXIT INT TERM

openssl req -x509 -newkey rsa:2048 -keyout "$DIR/k.pem" -out "$DIR/c.pem" \
        -days 1 -nodes -subj "/CN=localhost" >/dev/null 2>&1

CERT="$DIR/c.pem" KEY="$DIR/k.pem" PORT="$PORT" WORKERS="$WORKERS" \
    perl -Mblib bench/proto-server.pl >/dev/null 2>&1 &
SRV=$!

# Wait for the QUIC half specifically. The TCP listener comes up first, so
# polling it would start the run before h3 could answer and charge HTTP/3 for
# the startup.
i=0
while [ $i -lt 100 ]; do
    if "$CURL" -s -k --http3-only --max-time 2 -o /dev/null \
               "https://127.0.0.1:$PORT/" 2>/dev/null; then break; fi
    i=$((i + 1)); sleep 0.1
done
if [ $i -ge 100 ]; then echo "server did not come up on HTTP/3" >&2; exit 1; fi

urls() {   # $1 = path, $2 = count
    i=0
    while [ $i -lt "$2" ]; do
        printf 'url = "https://127.0.0.1:%s%s"\noutput = "/dev/null"\n' "$PORT" "$1"
        i=$((i + 1))
    done
}

run_one() {   # $1 = proto flag, $2 = config file -> req/s on stdout
    S=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    "$CURL" -s -k "$1" --parallel --parallel-max "$C" -K "$2" >/dev/null 2>&1
    E=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    perl -e 'my ($n,$s,$e)=@ARGV; printf "%.0f", $e-$s > 0 ? $n/($e-$s) : 0' \
         "$N" "$S" "$E"
}

# The median of RUNS, not the best: a best-of hides variance, and on a
# loopback benchmark variance is most of what there is to know.
median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

bench_path() {   # $1 = path, $2 = label
    CFG="$DIR/urls$$.txt"
    urls "$1" "$N" > "$CFG"
    printf '\n%s  (%s requests, concurrency %s, %s worker(s), median of %s)\n' \
           "$2" "$N" "$C" "$WORKERS" "$RUNS"
    printf '  %-12s %12s  %s\n' protocol req/s relative
    BASE=""
    for p in --http1.1 --http2 --http3-only; do
        # One untimed pass first: it pays the handshakes and warms the page
        # cache, so what is measured afterwards is steady state rather than
        # connection setup.
        "$CURL" -s -k "$p" --parallel --parallel-max "$C" -K "$CFG" \
                >/dev/null 2>&1 || true
        r=1
        set --
        while [ $r -le "$RUNS" ]; do
            set -- "$@" "$(run_one "$p" "$CFG")"
            r=$((r + 1))
        done
        M=$(median "$@")
        [ -z "$BASE" ] && BASE=$M
        printf '  %-12s %12s  %s\n' \
            "$(echo "$p" | sed 's/^--//; s/-only$//')" "$M" \
            "$(perl -e 'printf "%.2fx", $ARGV[1] ? $ARGV[0]/$ARGV[1] : 0' "$M" "$BASE")"
    done
    rm -f "$CFG"
}

echo "Hyperman HTTP/1.1 vs HTTP/2 vs HTTP/3, all over TLS"
echo "client: $CURL"
echo "server: one TLS listener on 127.0.0.1:$PORT with http2 and http3 on"

# 13 bytes: the canonical micro-benchmark body, so this row is about
# per-request overhead - framing, headers, and a round trip.
bench_path "/"    "13-byte body - per-request overhead"

# 64KB: large enough to cross a QUIC flow-control window and to need more
# than one TCP segment, so this row is about the write path instead.
bench_path "/big" "64KB body - write path"

cat <<'NOTE'

Reading these:

  HTTP/1.1 opens a connection per concurrent request; HTTP/2 and HTTP/3
  multiplex onto one. That is not an artefact of the harness, it is the
  difference between the protocols, and it is most of the gap on the small
  body.

  HTTP/3 doing all of its crypto and packetisation in userspace, one sendto
  per packet, is why it does not beat HTTP/2 here. There is no GSO on macOS
  and none is used on Linux yet, so this is a floor and not a ceiling.

  QUIC's real wins - no head-of-line blocking under loss, and a cheaper
  reconnect - are invisible on a loopback with no loss and no RTT. Do not
  read these rows as "HTTP/3 is slower"; read them as "HTTP/3 costs this
  much more CPU when the network is perfect".
NOTE
