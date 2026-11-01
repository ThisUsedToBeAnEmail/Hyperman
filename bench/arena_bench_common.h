/* arena_bench_common.h - the scaffold arena_bench.c and arena_bench_sa.c share.
 *
 * Fork K workers, release them together, time each one's loop, and gather the
 * numbers back through one shared page. Perl-free, like the headers under
 * test: the accept-path check and the bus are called from C with no Perl frame,
 * and a Perl benchmark would measure the XS door on top of a 20ns question.
 *
 * Every case reports the POOLED cost: the sum of the workers' elapsed time over
 * the sum of their operations, which is "nanoseconds of one worker's time per
 * operation". For the balanced cases it is the plain mean; for the queue-group
 * claim, where a shared cursor hands the work out unevenly, it is the only
 * number that does not depend on who won more races.
 */

#ifndef ARENA_BENCH_COMMON_H
#define ARENA_BENCH_COMMON_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/time.h>

#if !defined(MAP_ANONYMOUS) && defined(MAP_ANON)
#  define MAP_ANONYMOUS MAP_ANON
#endif

#define AB_MAX_K    64
#define AB_PAYLOAD  64            /* the bus record every bus case publishes */
#define AB_TOPIC    "t"
#define AB_TLEN     1u

/* The table shapes, the server's defaults on both sides. */
#define AB_DENY_CAP   1024
#define AB_RATE_CAP   4096
#define AB_RING_SLOTS 2048
#define AB_RING_SLOT  2048

#define AB_DENY_LIVE  100         /* entries loaded for the hit and miss cases */
#define AB_DENY_TTL_S 3600        /* a ban lapses, as Punk's deny_add(ip, ttl) */
#define AB_HIT_IP     "10.0.0.50"
#define AB_MISS_IP    "203.0.113.7"

#define AB_RL_LIMIT   (1L << 30)
#define AB_RL_WINDOW  3600L
#define AB_RL_KEYS    4096
#define AB_RL_KLEN    9           /* "rl\0k\0" + four digits, NULs included */

/* Wakeup latency: the poke arrives or it does not. Five seconds of silence is
 * a broken wakeup, not a slow one; the sleeper stops and says so. */
#define AB_WAKE_TIMEOUT_MS 5000

typedef struct {
    double   elapsed_us;
    uint64_t ops;
    uint64_t extra;         /* what the case counts: hits, fresh counters   */
    uint64_t extra2;        /* refusals, fail-opens, timeouts              */
    double   lat_mean_us;   /* wake only                                    */
    double   lat_median_us; /* wake only                                    */
} ab_result;

typedef struct {
    volatile uint32_t ready;     /* workers that finished their setup      */
    volatile uint32_t go;        /* the parent's starting gun               */
    volatile uint64_t acked;     /* wake: records the sleepers have taken   */
    volatile uint64_t total;     /* claim: claims across the whole pool     */
    ab_result w[AB_MAX_K];
} ab_shared;

static ab_shared *ab_sh;

static uint64_t ab_now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000u + (uint64_t)tv.tv_usec;
}

static void ab_shared_init(void) {
    void *m = mmap(NULL, sizeof(ab_shared), PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); exit(2); }
    memset(m, 0, sizeof(ab_shared));
    ab_sh = (ab_shared *)m;
}

/* A worker announces its setup is done, then waits for every sibling's. */
static void ab_wait_go(void) {
    __atomic_fetch_add(&ab_sh->ready, 1u, __ATOMIC_ACQ_REL);
    while (!__atomic_load_n(&ab_sh->go, __ATOMIC_ACQUIRE)) ;
}

static void ab_done(int widx, uint64_t t0, uint64_t t1, uint64_t ops,
                    uint64_t extra, uint64_t extra2) {
    ab_result *w = &ab_sh->w[widx];
    w->elapsed_us = (double)(t1 - t0);
    w->ops    = ops;
    w->extra  = extra;
    w->extra2 = extra2;
}

static int ab_cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

/* The wake case's per-sleeper summary. */
static void ab_done_lat(int widx, uint64_t *samples, uint64_t n,
                        uint64_t timeouts) {
    ab_result *w = &ab_sh->w[widx];
    uint64_t i, sum = 0;
    for (i = 0; i < n; i++) sum += samples[i];
    qsort(samples, (size_t)n, sizeof(uint64_t), ab_cmp_u64);
    w->ops           = n;
    w->extra2        = timeouts;
    w->lat_mean_us   = n ? (double)sum / (double)n : 0.0;
    w->lat_median_us = n ? (double)samples[n / 2] : 0.0;
}

typedef void (*ab_worker_fn)(int widx, int k, uint64_t n);
typedef void (*ab_parent_fn)(int k, uint64_t n);

/* Fork K workers, wait for all of them to be set up, release them together,
 * run the parent's own part (the wake case's publisher) and reap. */
static int ab_run(int k, uint64_t n, ab_worker_fn worker, ab_parent_fn parent) {
    pid_t pids[AB_MAX_K];
    int i, status, bad = 0;

    for (i = 0; i < k; i++) {
        pid_t p = fork();
        if (p < 0) { perror("fork"); exit(2); }
        if (p == 0) { worker(i, k, n); _exit(0); }
        pids[i] = p;
    }
    while (__atomic_load_n(&ab_sh->ready, __ATOMIC_ACQUIRE) < (uint32_t)k)
        usleep(100);
    __atomic_store_n(&ab_sh->go, 1u, __ATOMIC_RELEASE);
    if (parent) parent(k, n);
    for (i = 0; i < k; i++) {
        if (waitpid(pids[i], &status, 0) != pids[i]
            || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
            bad = 1;
    }
    return bad ? -1 : 0;
}

/* One line per run, in a shape the driver script can read with awk. */
static void ab_report(const char *name, int k, int is_wake) {
    double el = 0.0, lm = 0.0, lmed = 0.0;
    uint64_t ops = 0, extra = 0, extra2 = 0;
    int i;
    for (i = 0; i < k; i++) {
        el     += ab_sh->w[i].elapsed_us;
        ops    += ab_sh->w[i].ops;
        extra  += ab_sh->w[i].extra;
        extra2 += ab_sh->w[i].extra2;
        lm     += ab_sh->w[i].lat_mean_us;
        lmed   += ab_sh->w[i].lat_median_us;
    }
    if (is_wake)
        printf("%s K=%d lat_median_us=%.1f lat_mean_us=%.1f ops=%llu "
               "timeouts=%llu\n",
               name, k, lmed / (double)k, lm / (double)k,
               (unsigned long long)ops, (unsigned long long)extra2);
    else
        printf("%s K=%d ns_per_op=%.2f ops=%llu extra=%llu extra2=%llu\n",
               name, k, ops ? el * 1000.0 / (double)ops : 0.0,
               (unsigned long long)ops, (unsigned long long)extra,
               (unsigned long long)extra2);
}

/* The rate-limit keys: "rl\0k\0NNNN", nine bytes with the NULs Punk's
 * "rl\0tag\0id" shape carries. The same 4096 keys for every worker, walked
 * from a different starting point so the workers do not march in lockstep. */
static char ab_rl_keys[AB_RL_KEYS][AB_RL_KLEN + 1];

static void ab_rl_keys_init(void) {
    int i;
    for (i = 0; i < AB_RL_KEYS; i++) {
        char *k = ab_rl_keys[i];
        memcpy(k, "rl\0k\0", 5);
        snprintf(k + 5, 5, "%04d", i);
    }
}

/* The single contended key: an IP under the default tag. */
#define AB_RL_ONE      "rl\0ip\0203.0.113.7"
#define AB_RL_ONE_LEN  (sizeof(AB_RL_ONE) - 1)

/* The 100 denylist entries: 10.0.0.0 .. 10.0.0.99. AB_HIT_IP is one of them. */
static void ab_deny_ip(int i, char *out, size_t outsz) {
    snprintf(out, outsz, "10.0.%d.%d", i / 256, i % 256);
}

static uint64_t ab_default_n(const char *name) {
    if (!strcmp(name, "clock"))    return 5000000u;
    if (!strncmp(name, "deny", 4)) return 5000000u;
    if (!strcmp(name, "hll"))      return 5000000u;
    if (!strncmp(name, "rl", 2))   return 2000000u;
    if (!strcmp(name, "pub"))      return 1000000u;
    if (!strcmp(name, "drain"))    return 4000000u;
    if (!strcmp(name, "claim"))    return 2000000u;
    if (!strcmp(name, "wake"))     return 2000u;
    return 1000000u;
}

static void ab_usage(const char *argv0) {
    fprintf(stderr,
        "usage: %s CASE K [N]\n"
        "  CASE  clock | deny_empty | deny_hit | deny_miss | hll | rl_one | rl_1024 | rl_4096\n"
        "        | pub | drain | claim | wake\n"
        "  K     forked workers, 1..%d\n"
        "  N     operations per worker (a default per case)\n", argv0, AB_MAX_K);
    exit(2);
}

#endif /* ARENA_BENCH_COMMON_H */
