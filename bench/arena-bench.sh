#!/bin/sh
# The arena microbenchmarks: Hyperman's arena code (the port, through the
# table) against Shared::Arena's core headers direct, from C, forked K = 1, 2, 4, 8, the
# median of RUNS runs per cell. See plan_hyperman_shared_arena/01.
#
# Builds both harnesses with the compiler and optimisation the dist itself
# uses (perl's $Config{cc} and $Config{optimize}), so a number here is a number
# the .so would see.
#
# Usage: sh bench/arena-bench.sh [RUNS] [CASE...]
#   RUNS   runs per cell, default 5
#   CASE   any of the harness cases; default all
# Env:
#   SA_INCLUDE   Shared::Arena's include dir (default ../Shared-Arena/include)
#   KS           the worker counts (default "1 2 4 8")
#   BUILD        where the binaries go (default a temp dir)
#   HM_ONLY=1    build and run only the Hyperman side
#   SA_ONLY=1    build and run only the Shared::Arena side
#   SA_DEFINE    extra -D flags for the Shared::Arena side, the ones its own
#                Makefile.PL probes would set on this box (on Linux:
#                -DSA_HAVE_COARSE_CLOCK); -DSA_HAVE_ATFORK is always passed

set -e
cd "$(dirname "$0")/.."

RUNS=${1:-5}
[ $# -gt 0 ] && shift
CASES=${*:-"clock deny_empty deny_hit deny_miss hll rl_one rl_1024 rl_4096 pub drain claim wake"}
KS=${KS:-"1 2 4 8"}
SA_INCLUDE=${SA_INCLUDE:-../Shared-Arena/include}
BUILD=${BUILD:-$(mktemp -d)}

CC=$(perl -MConfig -e 'print $Config{cc}')
OPT=$(perl -MConfig -e 'print $Config{optimize}')
CFLAGS="$OPT -fno-strict-aliasing -Wall -Wextra -Wno-unused-function"

build() {
    [ -z "$SA_ONLY" ] && $CC $CFLAGS -DSA_HAVE_ATFORK $SA_DEFINE -Iinclude/hyperman \
        -I"$SA_INCLUDE" -Ibench \
        -o "$BUILD/arena_bench" bench/arena_bench.c -lpthread -lm
    [ -z "$HM_ONLY" ] && $CC $CFLAGS -DSA_HAVE_ATFORK $SA_DEFINE -I"$SA_INCLUDE" \
        -Ibench -o "$BUILD/arena_bench_sa" bench/arena_bench_sa.c -lpthread
    return 0
}

# median of the numbers on stdin
median() {
    sort -n | awk '{ a[NR] = $1 } END {
        if (NR == 0) { print "n/a"; exit }
        if (NR % 2) print a[(NR + 1) / 2];
        else printf "%.2f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }'
}

# one cell: median ns/op (or median latency for wake) plus the extras of the
# median run's siblings, reported once per cell from the last run
cell() {
    bin=$1; case=$2; k=$3
    vals=""
    last=""
    i=0
    while [ $i -lt "$RUNS" ]; do
        out=$("$bin" "$case" "$k") || { echo "FAIL"; return; }
        last=$out
        if [ "$case" = wake ]; then
            v=$(printf '%s\n' "$out" | sed -n 's/.*lat_median_us=\([0-9.]*\).*/\1/p')
        else
            v=$(printf '%s\n' "$out" | sed -n 's/.*ns_per_op=\([0-9.]*\).*/\1/p')
        fi
        vals="$vals$v
"
        i=$((i + 1))
    done
    m=$(printf '%s' "$vals" | median)
    ex=$(printf '%s\n' "$last" | sed -n 's/.*ops=[0-9]* //p')
    printf '%s|%s' "$m" "$ex"
}

table() {
    bin=$1; label=$2
    echo
    echo "### $label"
    echo
    printf '| case |'
    for k in $KS; do printf ' K=%s |' "$k"; done
    printf ' K=%s / K=%s | notes (last run) |\n' "$(echo $KS | awk '{print $NF}')" "$(echo $KS | awk '{print $1}')"
    printf '%s' '|---|'
    for k in $KS; do printf '%s' '---|'; done
    printf '%s\n' '---|---|'
    for c in $CASES; do
        printf '| %s |' "$c"
        first=""; lastv=""; note=""
        for k in $KS; do
            r=$(cell "$bin" "$c" "$k")
            v=${r%%|*}
            note=${r#*|}
            [ -z "$first" ] && first=$v
            lastv=$v
            if [ "$c" = wake ]; then printf ' %s us |' "$v"; else printf ' %s |' "$v"; fi
        done
        ratio=$(awk -v a="$first" -v b="$lastv" 'BEGIN { if (a > 0) printf "%.2f", b / a; else print "n/a" }')
        printf ' %s | %s |\n' "$ratio" "$note"
    done
}

build

echo "Arena microbenchmarks: $(uname -s) $(uname -m), $(date '+%Y-%m-%d'), $RUNS runs per cell, median"
echo "cc: $CC $OPT; cases: ns per op per process (wake: publish-to-woken, median us)"

[ -z "$SA_ONLY" ] && table "$BUILD/arena_bench"    "Hyperman (the port: hm_sa_abuse.h + hm_sa_bus.h + hm_sa_board.h, through the table)"
[ -z "$HM_ONLY" ] && table "$BUILD/arena_bench_sa" "Shared::Arena (sa_hash.h + sa_ring.h + sa_hll.h, direct)"

exit 0
