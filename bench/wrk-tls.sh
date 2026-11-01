#!/bin/sh
# What TLS costs Hyperman: the same app, over http and over https, driven by
# wrk.
#
# FAIRNESS, and it matters more than the numbers:
#
#   * ONE server process serves both. run() takes a plain listener and a TLS
#     listener in the same pool, so the worker count, the build, the page
#     cache and the machine's mood are identical across the two rows and the
#     only difference on the wire is the transport. Two separate servers
#     measured one after the other would fold whatever drifted between them
#     into "the cost of TLS".
#
#   * Three profiles, because they answer different questions:
#       keep-alive  - wrk's default. Connections are established once and
#                     reused, so this is the steady-state record layer:
#                     encrypt, MAC, and the extra copy. It is what a busy
#                     server actually pays.
#       close       - Connection: close, so every request is a fresh TCP
#                     connection. NOT a fresh handshake: wrk keeps a client
#                     session cache per thread, so past the first few
#                     connections it is resuming. Measured server CPU per
#                     connection here matches s_time -reuse almost exactly
#                     and is well under one RSA-2048 signature, which is
#                     how you can tell.
#       s_time      - the actual handshake, -new (full) against -reuse
#                     (resumed through a ticket). This is the only section
#                     that sees the asymmetric crypto, and the only one
#                     that moves with the key type.
#
#   * A warmup run is discarded (lazy loads, cold caches, unforked workers)
#     and the best of two is taken.
#
#   * Self-signed cert, minted per run into a temp dir and thrown away. wrk
#     does not verify the peer, so no trust store is involved.
#
# Co-resident: the load client shares these cores with the server, and with
# TLS it also shares the crypto units. The numbers are RELATIVE - good for
# comparing transports on this box, not headline figures. Those need a
# separate load machine.
#
# Usage: sh bench/wrk-tls.sh [WORKERS] [DURATION] [CONNECTIONS]
#   KEYTYPE=ec256   use a P-256 key instead of RSA-2048 (default rsa2048)
#   THREADS=n       wrk client threads (default 4)

set -e
cd "$(dirname "$0")/.."

WORKERS=${1:-1}
DUR=${2:-6}
CONN=${3:-100}
THREADS=${THREADS:-4}
KEYTYPE=${KEYTYPE:-rsa2048}
APP=bench/app.psgi
PERL=$(command -v perl)

command -v wrk     >/dev/null || { echo "wrk is not installed";     exit 1; }
command -v openssl >/dev/null || { echo "openssl is not installed"; exit 1; }
[ -d blib/arch ]              || { echo "run make first";           exit 1; }
"$PERL" -Iblib/lib -Iblib/arch -MHyperman \
        -e 'exit(Hyperman->has_tls ? 0 : 1)' \
    || { echo "this Hyperman was built without OpenSSL"; exit 1; }

# Ports from the kernel, not from $$: this script has to be able to run
# beside a test suite doing the same thing.
PORTS=$($PERL -It/lib -MHMTest -e 'print join " ", HMTest::free_ports(2)')
PLAIN=$(echo "$PORTS" | cut -d' ' -f1)
TLS=$(echo   "$PORTS" | cut -d' ' -f2)
[ -n "$TLS" ] || { echo "could not get two free loopback ports"; exit 1; }

DIR=$(mktemp -d)
CERT=$DIR/cert.pem
KEY=$DIR/key.pem
SRV=

cleanup() {
    [ -n "$SRV" ] && { pkill -P "$SRV" 2>/dev/null || true
                       kill "$SRV"     2>/dev/null || true; }
    rm -rf "$DIR"
}
trap cleanup EXIT INT TERM

case "$KEYTYPE" in
    ec256)
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -nodes -keyout "$KEY" -out "$CERT" -days 1 \
            -subj "/CN=localhost" >/dev/null 2>&1
        ;;
    *)
        KEYTYPE=rsa2048
        openssl req -x509 -newkey rsa:2048 \
            -nodes -keyout "$KEY" -out "$CERT" -days 1 \
            -subj "/CN=localhost" >/dev/null 2>&1
        ;;
esac
[ -s "$CERT" ] && [ -s "$KEY" ] || { echo "could not mint a self-signed cert"; exit 1; }

"$PERL" -Iblib/lib -Iblib/arch -MHyperman -e '
    my ($app_file, $plain, $tls, $workers, $cert, $key) = @ARGV;
    my $app = do "./$app_file";
    die "could not load $app_file: $@" unless ref $app eq "CODE";
    Hyperman->run(
        app     => $app,
        workers => $workers,
        listen  => [
            { host => "127.0.0.1", port => $plain },
            { host => "127.0.0.1", port => $tls,
              tls_cert => $cert, tls_key => $key },
        ],
    );
' "$APP" "$PLAIN" "$TLS" "$WORKERS" "$CERT" "$KEY" >/dev/null 2>&1 &
SRV=$!

i=0
while [ $i -lt 100 ]; do
    nc -z 127.0.0.1 "$PLAIN" 2>/dev/null && nc -z 127.0.0.1 "$TLS" 2>/dev/null && break
    i=$((i + 1))
    sleep 0.1
done
[ $i -lt 100 ] || { echo "server never bound :$PLAIN and :$TLS"; exit 1; }

# measure LABEL URL [extra wrk args...] -> "req/s  p50  p99" on stdout
measure() {
    label=$1; url=$2; shift 2
    wrk -t"$THREADS" -c"$CONN" -d3s --latency "$@" "$url" >/dev/null 2>&1 || true
    best=0; bp50=-; bp99=-; note=
    for _ in 1 2; do
        out=$(wrk -t"$THREADS" -c"$CONN" -d"${DUR}s" --latency "$@" "$url" 2>/dev/null)
        rps=$(printf '%s\n' "$out" | awk '/Requests\/sec/ { print $2 }')
        p50=$(printf '%s\n' "$out" | awk '/^ +50%/ { print $2 }')
        p99=$(printf '%s\n' "$out" | awk '/^ +99%/ { print $2 }')
        [ -z "$rps" ] && rps=0
        if awk -v a="$best" -v b="$rps" 'BEGIN { exit !(b > a) }'; then
            best=$rps; bp50=$p50; bp99=$p99
        fi
        e=$(printf '%s\n' "$out" | awk '/Socket errors/ { print; exit }')
        [ -n "$e" ] && note="$e"
    done
    printf '%-22s %12s req/s   p50 %-9s p99 %-9s %s\n' \
        "$label" "$best" "${bp50:--}" "${bp99:--}" "$note"
    RESULT=$best
}

cat <<EOF
Hyperman: plaintext vs TLS - $WORKERS worker(s), wrk -t$THREADS -c$CONN -d${DUR}s
app: $APP (plaintext Hello, World!), cert: self-signed $KEYTYPE
$(openssl version), co-resident client

-- keep-alive (steady-state record layer) ------------------------------------
EOF

measure "http  keep-alive"  "http://127.0.0.1:$PLAIN/";  KA_PLAIN=$RESULT
measure "https keep-alive"  "https://127.0.0.1:$TLS/";   KA_TLS=$RESULT

echo
cat <<'EOF'
-- Connection: close (fresh TCP connection per request) ---------------------
   Read the https number here in absolute terms, not as a ratio. The
   plaintext row is bound by TCP connection churn on loopback (ephemeral
   port reuse, listen backlog, TIME_WAIT) rather than by the server, and
   it swings by 3x between runs on the same box. Any "socket errors:
   connect" below is that pressure, not a server fault.
EOF

measure "http  close"  "http://127.0.0.1:$PLAIN/"  -H 'Connection: close'; CL_PLAIN=$RESULT
measure "https close"  "https://127.0.0.1:$TLS/"   -H 'Connection: close'; CL_TLS=$RESULT

echo
cat <<'EOF'
-- handshakes (openssl s_time) -----------------------------------------------
   wrk cannot measure this. It keeps a client session cache per thread, so
   after the first few connections a Connection: close run is mostly
   RESUMING, not handshaking - which is why the rows above are far cheaper
   than an RSA-2048 signature would allow. s_time asks for each explicitly.
   Single-threaded client, so read these two against each other, not as a
   throughput ceiling.
EOF

hs() { # -new | -reuse
    openssl s_time -connect "127.0.0.1:$TLS" "$1" -time "$DUR" -www / 2>/dev/null \
        | awk '/connections in .* real seconds/ { printf "%.0f", $1 / '"$DUR"'; exit }'
}
openssl s_time -connect "127.0.0.1:$TLS" -new -time 2 -www / >/dev/null 2>&1 || true
printf '%-22s %12s conn/s   (full handshake)\n'    "s_time new"   "$(hs -new)"
printf '%-22s %12s conn/s   (resumed via ticket)\n' "s_time reuse" "$(hs -reuse)"

echo
awk -v a="$KA_PLAIN" -v b="$KA_TLS" -v c="$CL_PLAIN" -v d="$CL_TLS" -v kt="$KEYTYPE" 'BEGIN {
    printf "TLS retains %.1f%% of plaintext throughput on kept-alive connections\n",
           (a > 0 ? 100 * b / a : 0);
    printf "https reconnect (mostly resumed) %.0f req/s, plaintext reconnect %.0f req/s\n",
           d, c;
}'
