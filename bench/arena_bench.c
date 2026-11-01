/* arena_bench.c - Hyperman's own arena code, timed from C with no Perl frame.
 *
 * Since phase 04 of the Shared::Arena port the denylist and the rate counters
 * are hm_sa_abuse.h on two maps in a Shared::Arena, driven through the ABI
 * table; this harness resolves that table from the sibling's sa_abi_impl.h
 * with no interpreter, so what it times is the accept path the server runs,
 * indirect call and all; since phase 05 the bus is hm_sa_bus.h on a ring in
 * the same arena, measured the same way. Forks K workers, times one case per
 * run. The sibling arena_bench_sa.c runs the same
 * cases against Shared::Arena's core headers directly; bench/arena-bench.sh
 * builds and drives both.
 *
 *   cc -O3 -DSA_HAVE_ATFORK -I../include/hyperman -I../../Shared-Arena/include \
 *      -o arena_bench arena_bench.c -lpthread -lm
 */

#include "arena_bench_common.h"

/* Shared::Arena's core and its ABI table, perl-free, in the order Arena.xs
 * includes them (less the three that need an interpreter). Both sides of the
 * server's arena code - the maps and the ring - are then driven through the
 * same table the server resolves, indirect call and all. */
#include "sa/sa_compat.h"
#include "sa/sa_atomic.h"
#include "sa/sa_format.h"
#include "sa/sa_map.h"
#include "sa/sa_arena.h"
#include "sa/sa_peer.h"
#include "sa/sa_ring.h"
#include "sa/sa_hash.h"
#include "sa/sa_bloom.h"
#include "sa/sa_hist.h"
#include "sa/sa_cache.h"
#include "sa/sa_rate.h"
#include "sa/sa_cms.h"
#include "sa/sa_cuckoo.h"
#include "sa/sa_lease.h"
#include "sa/sa_scoreboard.h"
#include "sa/sa_hll.h"
#include "sa_abi.h"
#include "sa/sa_abi_impl.h"

/* What hm_sa.h defines in the server; here the table is the sibling's own. */
static const sa_abi *HM_SA = NULL;
static sa_region    *hm_sa_region = NULL;

#include "hm_atomic.h"
#include "hm_sa_abuse.h"
#include "hm_sa_bus.h"
#include "hm_sa_board.h"

#if !HM_HAVE_ATOMICS || !SA_HAVE_ATOMICS
#error "no atomics: nothing to measure"
#endif

static const char *deny_ip;      /* the IP the deny cases check */
static sa_group_h *claim_gh;     /* the group the claim case shares */
static int         rl_nkeys;     /* how many of the 4096 keys a rl_keys run walks */

/* ---- deny_check ----------------------------------------------------------- */

static void w_deny(int widx, int k, uint64_t n) {
    uint64_t i, hits = 0, t0, t1;
    (void)k;
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) hits += (uint64_t)hm_sa_deny_check(deny_ip);
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, hits, 0);
}

/* The clock alone: what deny_check and ratelimit_hit pay for time(NULL)
 * before they touch the arena. A reference row, not an arena operation. */
static void w_clock(int widx, int k, uint64_t n) {
    uint64_t i, sink = 0, t0, t1;
    (void)k;
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) sink += (uint64_t)time(NULL);
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, sink & 1u, 0);
}

/* The opt-in distinct-client count: what run(distinct_clients => 1) adds to
 * every accept. 100 rotating peers, so the sketch sees new and repeated
 * addresses as an accept loop would. */
static void w_hll(int widx, int k, uint64_t n) {
    char ips[100][32];
    uint64_t i, t0, t1;
    int j = widx % 100;
    (void)k;
    for (i = 0; i < 100; i++) ab_deny_ip((int)i, ips[i], sizeof ips[i]);
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) {
        hm_sa_hll_add(ips[j]);
        if (++j == 100) j = 0;
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, (uint64_t)hm_sa_hll_count(), 0);
}

/* ---- ratelimit_hit -------------------------------------------------------- */

/* `extra` counts calls that saw a FRESH counter (remaining == limit - 1): the
 * first hit on a key, and every eviction or fail-open after it. rl_one expects
 * exactly 1 across the pool, rl_4096 exactly 4096; anything above is a reset
 * the table imposed. `extra2` counts refusals, which this arena has none of. */
static void w_rl_one(int widx, int k, uint64_t n) {
    uint64_t i, fresh = 0, t0, t1;
    long rem = 0, reset = 0;
    (void)k;
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) {
        (void)hm_sa_ratelimit_hit(AB_RL_ONE, AB_RL_ONE_LEN, AB_RL_LIMIT,
                                  AB_RL_WINDOW, &rem, &reset);
        if (rem == AB_RL_LIMIT - 1) fresh++;
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, fresh, 0);
}

static void w_rl_keys(int widx, int k, uint64_t n) {
    uint64_t i, fresh = 0, t0, t1;
    long rem = 0, reset = 0;
    int j = (widx * 997) % rl_nkeys;
    (void)k;
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) {
        (void)hm_sa_ratelimit_hit(ab_rl_keys[j], AB_RL_KLEN, AB_RL_LIMIT,
                                  AB_RL_WINDOW, &rem, &reset);
        if (rem == AB_RL_LIMIT - 1) fresh++;
        if (++j == rl_nkeys) j = 0;
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, fresh, 0);
}

/* ---- the bus -------------------------------------------------------------- */

static void cb_count(void *ud, uint64_t seq, const char *topic, uint32_t tlen,
                     const char *payload, uint32_t plen) {
    (void)seq; (void)topic; (void)tlen; (void)payload; (void)plen;
    (*(uint64_t *)ud)++;
}

/* K publishers, each with its own waker taken as a worker takes it. Nobody
 * drains, so after the first poke every pending flag stays set: this is the
 * steady state of a busy ring, one write(2) per waker per drain cycle, and
 * what is left is the publish itself. */
static void w_pub(int widx, int k, uint64_t n) {
    char payload[AB_PAYLOAD];
    uint64_t i, bad = 0, t0, t1;
    (void)k;
    memset(payload, 'x', sizeof payload);
    (void)hm_sa_bus_waker_take(widx);
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++)
        if (hm_sa_bus_publish(AB_TOPIC, AB_TLEN, payload, AB_PAYLOAD) != HM_BUS_OK)
            bad++;
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, 0, bad);
}

/* K fanout readers over a ring the parent filled exactly once. Each reader
 * drains the whole ring with its own cursor, puts the cursor back at the
 * oldest slot, and goes again: the seqlock read path with K readers and no
 * writer, which is where a shared write on a read path shows as the K=8/K=1
 * ratio. */
static void w_drain(int widx, int k, uint64_t n) {
    uint64_t got = 0, oldest, t0, t1, stuck = 0;
    sa_cursor *c;
    (void)k;
    (void)hm_sa_bus_waker_take(widx);
    c = hm_sa_bus_cursor(&hm_sa_recv_cur);      /* from the start: oldest */
    if (!c) _exit(1);
    oldest = c->seq;
    ab_wait_go();
    t0 = ab_now_us();
    while (got < n) {
        c->seq = oldest;
        if (hm_sa_bus_drain(&hm_sa_recv_cur, cb_count, &got) <= 0) { stuck++; break; }
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, got, hm_sa_bus_gaps_of(c), stuck);
}

/* K members of one queue group over the same filled ring. Whoever finds the
 * shared cursor at the end puts it back to the oldest slot with one CAS, so
 * the pool claims the ring over and over until it has claimed N x K records
 * between them. */
static void w_claim(int widx, int k, uint64_t n) {
    sa_group *g = claim_gh->g;
    uint64_t end, oldest, mine = 0, target = n * (uint64_t)k, t0, t1;
    (void)hm_sa_bus_waker_take(widx);
    end    = hm_sa_bus_seq();
    oldest = end - hm_sa_ring->nslots;
    ab_wait_go();
    t0 = ab_now_us();
    while (__atomic_load_n(&ab_sh->total, __ATOMIC_ACQUIRE) < target) {
        long c = hm_sa_bus_claim(claim_gh, cb_count, &mine);
        if (c > 0) __atomic_fetch_add(&ab_sh->total, (uint64_t)c, __ATOMIC_ACQ_REL);
        if (sa_at_load64_acq(&g->cursor) >= end)
            (void)sa_at_cas64(&g->cursor, end, oldest);
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, mine, hm_sa_bus_group_gaps(claim_gh), 0);
}

/* Publish-to-woken. The parent publishes one record carrying the clock, every
 * sleeper wakes from poll(2) on its waker, drains, and measures; the parent
 * waits for every sleeper's ack before the next record, so no poke can
 * coalesce with the one being measured. */
typedef struct { uint64_t *samples; uint64_t n, cap; } wake_ud;

static void cb_wake(void *ud, uint64_t seq, const char *topic, uint32_t tlen,
                    const char *payload, uint32_t plen) {
    wake_ud *w = (wake_ud *)ud;
    uint64_t ts;
    (void)seq; (void)topic; (void)tlen;
    if (plen < 8 || w->n >= w->cap) return;
    memcpy(&ts, payload, 8);
    w->samples[w->n++] = ab_now_us() - ts;
}

static void w_wake(int widx, int k, uint64_t n) {
    uint64_t timeouts = 0;
    wake_ud ud;
    int rfd;
    (void)k;
    rfd = hm_sa_bus_waker_take(widx);
    if (rfd < 0) { fprintf(stderr, "worker %d: no waker\n", widx); _exit(1); }
    hm_sa_bus_reset_cursor(&hm_sa_recv_cur);      /* from now on */
    ud.cap = n + 16;
    ud.n = 0;
    ud.samples = (uint64_t *)calloc((size_t)ud.cap, sizeof(uint64_t));
    if (!ud.samples) _exit(1);
    ab_wait_go();
    while (ud.n < n) {
        struct pollfd p;
        long got;
        p.fd = rfd; p.events = POLLIN; p.revents = 0;
        if (poll(&p, 1, AB_WAKE_TIMEOUT_MS) <= 0) { timeouts++; break; }
        hm_sa_bus_waker_drained();
        got = hm_sa_bus_drain(&hm_sa_recv_cur, cb_wake, &ud);
        if (got > 0)
            __atomic_fetch_add(&ab_sh->acked, (uint64_t)got, __ATOMIC_ACQ_REL);
    }
    ab_done_lat(widx, ud.samples, ud.n, timeouts);
}

static void p_wake(int k, uint64_t n) {
    char payload[AB_PAYLOAD];
    uint64_t r, deadline;
    memset(payload, 'x', sizeof payload);
    for (r = 0; r < n; r++) {
        uint64_t ts, want = r * (uint64_t)k;
        deadline = ab_now_us() + 10000000u;
        while (__atomic_load_n(&ab_sh->acked, __ATOMIC_ACQUIRE) < want)
            if (ab_now_us() > deadline) return;      /* a sleeper gave up */
        ts = ab_now_us();
        memcpy(payload, &ts, 8);
        (void)hm_sa_bus_publish(AB_TOPIC, AB_TLEN, payload, AB_PAYLOAD);
    }
}

/* ---- setup ---------------------------------------------------------------- */

static void fill_deny(void) {
    char ip[32];
    int i;
    for (i = 0; i < AB_DENY_LIVE; i++) {
        ab_deny_ip(i, ip, sizeof ip);
        hm_sa_deny_add(ip, AB_DENY_TTL_S);
    }
}

static void fill_ring(void) {
    char payload[AB_PAYLOAD];
    uint32_t i;
    memset(payload, 'x', sizeof payload);
    for (i = 0; i < hm_sa_ring->nslots; i++)
        if (hm_sa_bus_publish(AB_TOPIC, AB_TLEN, payload, AB_PAYLOAD) != HM_BUS_OK) {
            fprintf(stderr, "fill: publish refused\n");
            exit(2);
        }
}

int main(int argc, char **argv) {
    const char *name;
    int k;
    uint64_t n;
    ab_worker_fn worker = NULL;
    ab_parent_fn parent = NULL;
    int is_wake = 0;

    if (argc < 3) ab_usage(argv[0]);
    name = argv[1];
    k = atoi(argv[2]);
    if (k < 1 || k > AB_MAX_K) ab_usage(argv[0]);
    n = argc > 3 ? strtoull(argv[3], NULL, 10) : ab_default_n(name);

    ab_shared_init();
    ab_rl_keys_init();

    /* As hm_run_server: the Shared::Arena and its two maps, then the bus,
     * all before the fork; wakers = workers + 1. */
    {
        const char *which = NULL;
        int err = 0;
        HM_SA = &SA_ABI;
        hm_sa_region = sa_region_open(NULL, 0, 8u << 20, 16, 1, &err);
        if (!hm_sa_region) { fprintf(stderr, "region: SA_E %d\n", err); return 2; }
        if (hm_sa_abuse_open(0, 0, &which, &err) < 0) {
            fprintf(stderr, "map %s: SA_E %d\n", which, err);
            return 2;
        }
    }
    {
        int err = 0;
        if (hm_sa_bus_open(0, 0, &err) < 0) { fprintf(stderr, "ring: SA_E %d\n", err); return 2; }
        (void)hm_sa_bus_wake_init((uint32_t)k + 1);
    }
    if (!hm_sa_abuse_live() || !hm_sa_bus_live()) {
        fprintf(stderr, "no arena\n");
        return 2;
    }

    if (!strcmp(name, "clock"))          { worker = w_clock; }
    else if (!strcmp(name, "deny_empty")) { deny_ip = AB_MISS_IP; worker = w_deny; }
    else if (!strcmp(name, "deny_hit"))  { fill_deny(); deny_ip = AB_HIT_IP;  worker = w_deny; }
    else if (!strcmp(name, "deny_miss")) { fill_deny(); deny_ip = AB_MISS_IP; worker = w_deny; }
    else if (!strcmp(name, "rl_one"))    { worker = w_rl_one; }
    else if (!strcmp(name, "rl_1024"))   { rl_nkeys = 1024; worker = w_rl_keys; }
    else if (!strcmp(name, "rl_4096"))   { rl_nkeys = AB_RL_KEYS; worker = w_rl_keys; }
    else if (!strcmp(name, "hll")) {
        int err = 0;
        if (hm_sa_hll_open(&err) < 0) { fprintf(stderr, "hll: SA_E %d\n", err); return 2; }
        worker = w_hll;
    }
    else if (!strcmp(name, "pub"))       { worker = w_pub; }
    else if (!strcmp(name, "drain"))     { fill_ring(); worker = w_drain; }
    else if (!strcmp(name, "claim")) {
        /* The group BEFORE the fill: a new group starts at the current
         * sequence, and the fill is what it has to claim. */
        claim_gh = hm_sa_bus_group(AB_TOPIC, AB_TLEN, "g", 1);
        if (!claim_gh) { fprintf(stderr, "no group\n"); return 2; }
        fill_ring();
        worker = w_claim;
    }
    else if (!strcmp(name, "wake"))      { worker = w_wake; parent = p_wake; is_wake = 1; }
    else ab_usage(argv[0]);

    if (ab_run(k, n, worker, parent) != 0) {
        fprintf(stderr, "%s: a worker failed\n", name);
        return 1;
    }
    ab_report(name, k, is_wake);
    return 0;
}
