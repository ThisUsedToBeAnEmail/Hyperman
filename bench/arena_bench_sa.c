/* arena_bench_sa.c - the same cases as arena_bench.c, against Shared::Arena's
 * core headers directly, so the candidate is measured BEFORE the port exists.
 *
 * The shapes are the ones plan_hyperman_shared_arena/04 and 05 intend:
 *   - the denylist is a Map keyed by the IP string, empty value, per-key TTL;
 *   - the fixed-window counter is a Map keyed by the 64-bit FNV of the opaque
 *     key (as hm_ratelimit.h keys its table today), eight-byte counter, so a
 *     hit is fnv + sa_hash_incr. map_incr_ttl does not exist yet (phase 02),
 *     so the deadline is not set here; it costs one clock read on CREATE only;
 *   - the bus is a Ring of the server's geometry (2048 x 2048), one queue
 *     group, wakers = K + 1 as hm_run_server sizes them.
 *
 *   cc -O3 -DSA_HAVE_ATFORK -I../../Shared-Arena/include \
 *      -o arena_bench_sa arena_bench_sa.c -lpthread
 *
 * -DSA_HAVE_ATFORK matters: without it sa_getpid is a syscall on every
 * publish, which is not what the dist builds with on any platform that has
 * pthread_atfork.
 */

#include "arena_bench_common.h"

#include "sa/sa_compat.h"
#include "sa/sa_atomic.h"
#include "sa/sa_format.h"
#include "sa/sa_map.h"
#include "sa/sa_arena.h"
#include "sa/sa_peer.h"
#include "sa/sa_ring.h"
#include "sa/sa_hash.h"
#include "sa/sa_hll.h"

#if !SA_HAVE_ATOMICS
#error "no atomics: nothing to measure"
#endif

#define REGION_BYTES (8u << 20)
#define REGION_REGS  16

/* sa_hash_capacity charges a slot sizeof(sa_hash_slot) - 1 = 39 bytes of
 * header (the struct pads to 40), so a slot carries slot_size - 39 bytes of
 * key + value. A deny slot must hold an IPv6 string (46 with the NUL) and no
 * value: 88 gives 49. A rate slot holds the 8-byte key and the 8-byte
 * counter: 56 gives 17, and the counter lands 8-aligned (bytes begin at
 * offset 32, so key + 8 sits at 40 of a 56-byte stride), which is what makes
 * sa_hash_incr take its one-instruction path. */
#define DENY_SLOT 88
#define RATE_SLOT 56

static sa_region *R;
static sa_hash   *DENY, *RATE;
static sa_ring   *RING;
static sa_group_h *G;
static sa_hll    *HLL;

static const char *deny_ip;
static int         rl_nkeys;

/* ---- deny_check: a fetch with a zero-length buffer (exists) --------------- */

static void w_deny(int widx, int k, uint64_t n) {
    uint64_t i, hits = 0, busy = 0, t0, t1;
    uint32_t iplen = (uint32_t)strlen(deny_ip), vl;
    char out[1];
    (void)k;
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) {
        int rc = sa_hash_fetch(DENY, deny_ip, iplen, out, 0, &vl);
        if (rc == SA_H_HIT) hits++;
        else if (rc == SA_H_BUSY) busy++;
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, hits, busy);
}

/* The clock alone: sa_now_ms, which the map reads on a hit that carries a
 * deadline and on the create of a counter with one. A reference row. */
static void w_clock(int widx, int k, uint64_t n) {
    uint64_t i, sink = 0, t0, t1;
    (void)k;
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) sink += sa_now_ms();
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, sink & 1u, 0);
}

/* The distinct-client sketch, as hm_sa_board.h adds a peer at accept. */
static void w_hll(int widx, int k, uint64_t n) {
    char ips[100][32];
    uint64_t i, t0, t1;
    int j = widx % 100;
    (void)k;
    for (i = 0; i < 100; i++) ab_deny_ip((int)i, ips[i], sizeof ips[i]);
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) {
        sa_hll_add(HLL, ips[j], strlen(ips[j]));
        if (++j == 100) j = 0;
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, (uint64_t)sa_hll_count(HLL), 0);
}

/* ---- ratelimit_hit: fnv, then incr on the eight-byte key ------------------- */

/* `extra` counts increments that CREATED the counter (the result was 1); rl_one
 * expects 1 across the pool, rl_4096 exactly 4096. `extra2` counts refusals:
 * SA_H_FULL is both "table full" and "stripe contended past the bound". */
static void w_rl_one(int widx, int k, uint64_t n) {
    uint64_t i, fresh = 0, refused = 0, now = 0, t0, t1;
    (void)k;
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) {
        uint64_t h = sa_at_fnv(AB_RL_ONE, AB_RL_ONE_LEN);
        int rc = sa_hash_incr(RATE, (const char *)&h, 8, 1, &now);
        if (rc != SA_H_OK) refused++;
        else if (now == 1) fresh++;
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, fresh, refused);
}

static void w_rl_keys(int widx, int k, uint64_t n) {
    uint64_t i, fresh = 0, refused = 0, now = 0, t0, t1;
    int j = (widx * 997) % rl_nkeys;
    (void)k;
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++) {
        uint64_t h = sa_at_fnv(ab_rl_keys[j], AB_RL_KLEN);
        int rc = sa_hash_incr(RATE, (const char *)&h, 8, 1, &now);
        if (rc != SA_H_OK) refused++;
        else if (now == 1) fresh++;
        if (++j == rl_nkeys) j = 0;
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, fresh, refused);
}

/* ---- the ring ------------------------------------------------------------- */

static void cb_count(void *ud, uint64_t seq, const char *topic, uint32_t tlen,
                     const char *data, uint32_t dlen, uint32_t flags) {
    (void)seq; (void)topic; (void)tlen; (void)data; (void)dlen; (void)flags;
    (*(uint64_t *)ud)++;
}

static void w_pub(int widx, int k, uint64_t n) {
    char payload[AB_PAYLOAD];
    uint64_t i, bad = 0, t0, t1;
    (void)k;
    memset(payload, 'x', sizeof payload);
    (void)sa_wake_take(R, widx);
    ab_wait_go();
    t0 = ab_now_us();
    for (i = 0; i < n; i++)
        if (sa_ring_publish(RING, AB_TOPIC, AB_TLEN, payload, AB_PAYLOAD, NULL)
            != SA_PUB_OK)
            bad++;
    t1 = ab_now_us();
    ab_done(widx, t0, t1, n, 0, bad);
}

static void w_drain(int widx, int k, uint64_t n) {
    sa_cursor *c;
    uint64_t got = 0, oldest, t0, t1, stuck = 0;
    (void)k;
    (void)sa_wake_take(R, widx);
    c = sa_cursor_new(RING, 1);
    if (!c) _exit(1);
    oldest = c->seq;                     /* the ring is exactly full: 1 */
    ab_wait_go();
    t0 = ab_now_us();
    while (got < n) {
        c->seq = oldest;
        if (sa_cursor_drain(c, 0, cb_count, &got) <= 0) { stuck++; break; }
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, got, c->lapped, stuck);
}

static void w_claim(int widx, int k, uint64_t n) {
    sa_group *g = G->g;
    uint64_t end, oldest, mine = 0, target = n * (uint64_t)k, t0, t1;
    (void)sa_wake_take(R, widx);
    end    = sa_at_load64_acq(&RING->hdr->seq);
    oldest = end - RING->nslots;
    ab_wait_go();
    t0 = ab_now_us();
    while (__atomic_load_n(&ab_sh->total, __ATOMIC_ACQUIRE) < target) {
        uint64_t seq, batch = 0;
        const char *tp, *dp;
        uint32_t tl, dl, fl;
        while (sa_group_claim(RING, g, G->scratch, &seq, &tp, &tl, &dp, &dl, &fl)
               == SA_READ_OK)
            batch++;
        mine += batch;
        if (batch)
            __atomic_fetch_add(&ab_sh->total, batch, __ATOMIC_ACQ_REL);
        if (sa_at_load64_acq(&g->cursor) >= end)
            (void)sa_at_cas64(&g->cursor, end, oldest);
    }
    t1 = ab_now_us();
    ab_done(widx, t0, t1, mine, sa_at_load64_acq(&g->lapped), 0);
}

typedef struct { uint64_t *samples; uint64_t n, cap; } wake_ud;

static void cb_wake(void *ud, uint64_t seq, const char *topic, uint32_t tlen,
                    const char *data, uint32_t dlen, uint32_t flags) {
    wake_ud *w = (wake_ud *)ud;
    uint64_t ts;
    (void)seq; (void)topic; (void)tlen; (void)flags;
    if (dlen < 8 || w->n >= w->cap) return;
    memcpy(&ts, data, 8);
    w->samples[w->n++] = ab_now_us() - ts;
}

static void w_wake(int widx, int k, uint64_t n) {
    sa_cursor *c;
    uint64_t timeouts = 0;
    wake_ud ud;
    int rfd;
    (void)k;
    if (sa_wake_take(R, widx) < 0) {
        fprintf(stderr, "worker %d: no waker\n", widx);
        _exit(1);
    }
    rfd = sa_wake_fd(R);
    if (rfd < 0) _exit(1);
    c = sa_cursor_new(RING, 0);
    if (!c) _exit(1);
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
        sa_wake_drained(R);
        got = sa_cursor_drain(c, 0, cb_wake, &ud);
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
            if (ab_now_us() > deadline) return;
        ts = ab_now_us();
        memcpy(payload, &ts, 8);
        (void)sa_ring_publish(RING, AB_TOPIC, AB_TLEN, payload, AB_PAYLOAD, NULL);
    }
}

/* ---- setup ---------------------------------------------------------------- */

static void die_err(const char *what, int err) {
    fprintf(stderr, "%s: SA_E %d\n", what, err);
    exit(2);
}

static void setup(int k) {
    sa_reg *e;
    int err = 0;

    R = sa_region_open(NULL, 0, REGION_BYTES, REGION_REGS, 1, &err);
    if (!R) die_err("region", err);

    e = sa_carve(R, "deny", 4, sa_hash_bytes(AB_DENY_CAP, DENY_SLOT), SA_T_MAP, &err);
    if (!e) die_err("carve deny", err);
    DENY = sa_hash_bind(R, e, AB_DENY_CAP, DENY_SLOT, 0, &err);
    if (!DENY) die_err("bind deny", err);

    e = sa_carve(R, "rate", 4, sa_hash_bytes(AB_RATE_CAP, RATE_SLOT), SA_T_MAP, &err);
    if (!e) die_err("carve rate", err);
    RATE = sa_hash_bind(R, e, AB_RATE_CAP, RATE_SLOT, 0, &err);
    if (!RATE) die_err("bind rate", err);

    e = sa_carve(R, "bus", 3, sa_ring_bytes(AB_RING_SLOTS, AB_RING_SLOT), SA_T_RING, &err);
    if (!e) die_err("carve bus", err);
    RING = sa_ring_bind(R, e, AB_RING_SLOTS, AB_RING_SLOT, &err);
    if (!RING) die_err("bind bus", err);

    if (!sa_wake_init(R, (uint32_t)k + 1)) { fprintf(stderr, "wake_init\n"); exit(2); }

    /* AB_SA_WAKERS_TIGHT=1: poke walks only the K + 1 slots that were given
     * pipes, as hm_bus_poke walks nwakers, instead of all SA_WAKERS_MAX (64).
     * Not what the dist does today; it is the experiment that tells phase 02
     * what the 64-slot walk costs a publish. */
    if (getenv("AB_SA_WAKERS_TIGHT")) R->wakers_max = (uint32_t)k + 1;
}

static void fill_deny(void) {
    char ip[32];
    int i;
    for (i = 0; i < AB_DENY_LIVE; i++) {
        ab_deny_ip(i, ip, sizeof ip);
        if (sa_hash_store_ttl(DENY, ip, (uint32_t)strlen(ip), "", 0,
                              (uint64_t)AB_DENY_TTL_S * 1000u) != SA_H_OK) {
            fprintf(stderr, "fill deny: refused\n");
            exit(2);
        }
    }
}

static void fill_ring(void) {
    char payload[AB_PAYLOAD];
    uint64_t i;
    memset(payload, 'x', sizeof payload);
    for (i = 0; i < RING->nslots; i++)
        if (sa_ring_publish(RING, AB_TOPIC, AB_TLEN, payload, AB_PAYLOAD, NULL)
            != SA_PUB_OK) {
            fprintf(stderr, "fill: publish refused\n");
            exit(2);
        }
}

int main(int argc, char **argv) {
    const char *name;
    int k, err = 0;
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
    setup(k);

    if (!strcmp(name, "clock"))          { worker = w_clock; }
    else if (!strcmp(name, "deny_empty")) { deny_ip = AB_MISS_IP; worker = w_deny; }
    else if (!strcmp(name, "deny_hit"))  { fill_deny(); deny_ip = AB_HIT_IP;  worker = w_deny; }
    else if (!strcmp(name, "deny_miss")) { fill_deny(); deny_ip = AB_MISS_IP; worker = w_deny; }
    else if (!strcmp(name, "rl_one"))    { worker = w_rl_one; }
    else if (!strcmp(name, "rl_1024"))   { rl_nkeys = 1024; worker = w_rl_keys; }
    else if (!strcmp(name, "rl_4096"))   { rl_nkeys = AB_RL_KEYS; worker = w_rl_keys; }
    else if (!strcmp(name, "hll")) {
        sa_reg *e = sa_carve(R, "clients", 7, sa_hll_bytes(14), SA_T_HLL, &err);
        if (!e) die_err("carve hll", err);
        HLL = sa_hll_bind(R, e, 14, &err);
        if (!HLL) die_err("bind hll", err);
        worker = w_hll;
    }
    else if (!strcmp(name, "pub"))       { worker = w_pub; }
    else if (!strcmp(name, "drain"))     { fill_ring(); worker = w_drain; }
    else if (!strcmp(name, "claim")) {
        G = sa_group_new(RING, "g", 1, AB_TOPIC, AB_TLEN, 1, &err);
        if (!G) die_err("group", err);
        fill_ring();
        worker = w_claim;
    }
    else if (!strcmp(name, "wake"))      { worker = w_wake; parent = p_wake; is_wake = 1; }
    else ab_usage(argv[0]);

    if (ab_run(k, n, worker, parent) != 0) {
        fprintf(stderr, "%s: a worker failed\n", name);
        return 1;
    }
    /* A table that refused everything measured nothing: a mis-sized slot
     * made every increment SA_H_TOOBIG at 0.7ns and looked like a win. */
    if (!strncmp(name, "rl", 2)) {
        uint64_t ops = 0, refused = 0;
        int i;
        for (i = 0; i < k; i++) { ops += ab_sh->w[i].ops; refused += ab_sh->w[i].extra2; }
        if (ops && refused * 2 > ops) {
            fprintf(stderr, "%s: %llu of %llu increments refused; the table is "
                    "mis-sized or the stripe never came free\n", name,
                    (unsigned long long)refused, (unsigned long long)ops);
            return 1;
        }
    }
    ab_report(name, k, is_wake);
    return 0;
}
