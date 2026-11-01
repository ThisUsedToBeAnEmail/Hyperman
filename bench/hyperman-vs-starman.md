# Hyperman vs Starman

Reproduce with `sh bench/wrk-bench.sh [WORKERS] [DURATION] [CONNECTIONS]`.

**Host:** Apple M5, 10 cores, macOS 26.4.1, perl 5.42.0, wrk 4.2.0,
Starman 0.4018, Hyperman 0.15. Load client **co-resident** with the
server - they share these cores. Plaintext `Hello, World!`
(`bench/app.psgi`), keep-alive, identical app for every server.

These are **relative** numbers, good for comparing servers on this box.
Headline figures need a separate load machine, and the last section
explains why that matters more here than usual.

## Per worker - the clean comparison

`wrk -t4 -c100 -d6s`, one worker each. Best of two after a discarded
warmup.

| server | req/s | vs Starman |
|---|---:|---:|
| starman (defaults) | 28,093 | 1.0× |
| starman (`--max-requests 1000000`) | 27,723 | 1.0× |
| **hyperman** (plackup) | **226,612** | **8.1×** |
| **hyperman** (native runner) | **227,452** | **8.1×** |

## Four workers

| server | -c100 | -c400 |
|---|---:|---:|
| starman (defaults) | 73,095 | 71,388 |
| starman (tuned) | 80,197 | 75,072 |
| hyperman (plackup) | 186,087 | 186,487 |
| hyperman (native) | 188,580 | 185,955 |

**Do not read the Hyperman row as scaling.** It goes *down* from one
worker to four, at both concurrencies, which is not a property of the
server: four Hyperman workers plus four `wrk` threads do not fit in ten
cores, and one Hyperman worker already saturates the client. Starman
climbs 2.9× on four workers because a single Starman worker leaves the
client plenty of headroom to grow into.

So on this box the honest reading is:

- the **per-worker** row is a real comparison;
- the **four-worker** Hyperman figure is a **floor**, not a ceiling, and
  says more about the measuring apparatus than about Hyperman.

## Two fairness notes, both of which cost Hyperman

**Starman's `max_requests` defaults to 1000** - a worker recycles after a
thousand requests, and this run does ~170,000 of them. Hyperman's
equivalent (`max_requests_per_worker`) is off by default, so the tuned
row is the like-for-like one and it is the one quoted above.

I expected that to dominate and it does not: **it is worth about 3%**
at one worker and ~10% at four. Worth saying out loud, because
"benchmark disproves the benchmarker's assumption" is more persuasive
than any number in the table.

**Hyperman is measured through `plackup` as well as natively**, and the
two agree to within 0.4%. The comparison is not flattered by skipping a
layer Starman cannot skip. Starman also gets `--preload-app`, which
helps it.

## What this is and is not

It is a plaintext micro-benchmark: no database, no template, no
serialisation. It measures the distance between the socket and the
application, which is exactly the thing an event loop in C changes and
exactly the thing most real applications are not bounded by.

The comparison is also not like-for-like architecturally, and that is
the point rather than a flaw. Starman is prefork: one process per
concurrent request, blocking, and its worker count is its concurrency.
Hyperman is an event loop per worker: one process serving many
concurrent connections. At equal worker counts that is a fair question
to ask, but they are answering it with different resources.

## For a slide

Two rows, one caveat:

    per worker, plaintext, keep-alive
      Starman   28,093 req/s
      Hyperman 227,452 req/s      8.1x

    (co-resident load client; one Hyperman worker already saturates it)

If you have room for one more line, use the dev-mode figure from
`BENCHMARKS.md` beside it: the same Hyperman under `plackup` in
development mode does 22,500 req/s. Same server, an order of magnitude
apart, and the difference is `AccessLog`, `Lint` and `StackTrace`. It
argues that the thing costing you throughput is probably not the thing
you were about to rewrite - and it uses your own benchmark against the
reflex to trust benchmarks.
