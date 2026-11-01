# Hyperman vs Feersum

Reproduce with `sh bench/feersum-bench.sh [WORKERS] [DURATION] [CONNECTIONS]`.

**Host:** Apple M5, 10 cores, macOS 26.4.1, perl 5.42.0, wrk 4.2.0,
Feersum 1.505, Hyperman 0.51. Load client **co-resident** with the
server. Plaintext `Hello, World!` (`bench/app.psgi`), keep-alive,
identical app for every PSGI row.

Feersum is the harder comparison and the more interesting one. Starman
is prefork Perl answering the same question with a different
architecture, so an 8x gap says mostly that an event loop in C beats a
process per request. Feersum is the *same* architecture as Hyperman: one
XS event loop per process, many connections per loop, libev underneath
instead of a hand-written kqueue loop. What is left when you hold the
model fixed is the implementation.

## Per worker - the clean comparison

`wrk -t4 -c100 -d6s`, one worker each. Best of two within a run after a
discarded warmup; best of three runs shown.

| server | interface | req/s | vs Feersum PSGI |
|---|---|---:|---:|
| feersum (`--keepalive=1`) | PSGI | 183,566 | 1.00x |
| feersum (native app) | not PSGI | 235,304 | 1.28x |
| **hyperman** (plackup) | PSGI | **235,647** | **1.28x** |
| **hyperman** (native runner) | PSGI | **237,048** | **1.29x** |

The shape of that table is the result:

**Hyperman serving PSGI matches Feersum serving its own non-PSGI native
interface.** Feersum's PSGI path runs at 78% of its own native path -
building a `$env` hash and unpacking a PSGI response arrayref costs it
22% - while Hyperman's PSGI number lands on top of Feersum's PSGI-free
number. Against
the row that is actually like-for-like - both servers, both under
`plackup`, both speaking PSGI - Hyperman is **1.28x**.

## Run-to-run spread, because it is large

| row | run 1 | run 2 | run 3 |
|---|---:|---:|---:|
| feersum-keepalive | 172,102 | 183,566 | 173,922 |
| feersum-native | 183,707 | 235,304 | 229,284 |
| hyperman-plackup | 188,934 | 235,647 | 228,020 |
| hyperman-native | 192,685 | 234,692 | 237,048 |

Run 1 is low on **every** row, by roughly the same fraction. That is the
box, not the servers: a cold machine and a co-resident client. Runs 2
and 3 agree to within about 5% and the *ratios* hold across all three
even where the absolutes do not, which is the reason to quote a ratio
here and not a headline number.

## Four workers - the client saturates, and that is all this says

`wrk -t4 -c400 -d6s`, four workers each:

| server | req/s |
|---|---:|
| feersum-keepalive | 193,280 |
| feersum-native | 186,505 |
| hyperman-plackup | 185,509 |
| hyperman-native | 186,440 |

Every row converges on ~185-193k, and both servers land *below* their
own one-worker figures. Four server workers plus four `wrk` threads do
not fit in ten cores, and one worker of either server already saturates
the client. This table separates nothing and should not be read as
Feersum edging ahead; it is four measurements of the same load
generator. Worker scaling needs a separate load machine.

Verified that the row is really four processes: `--pre-fork=4` gives a
parent plus four children, all serving.

## Feersum's keepalive defaults to OFF, and it is worth saying carefully

Out of the box Feersum answers every request with `Connection: close`.
`bench/feersum-bench.sh` therefore runs it twice, the way the Starman
script runs Starman twice, and the defaults row comes out like this:

| run | req/s |
|---|---:|
| 1 | 14,698 |
| 2 | 4,423 |
| 3 | 23,852 |

**That is not a Feersum measurement and the script says so on stdout.**
A five-fold spread across three identical runs is the tell. With
keepalive off every request is a fresh TCP connection, each parking an
ephemeral port in `TIME_WAIT` for 2*MSL. This box has ~16k ephemeral
ports and a 15s MSL, so a run doing >20k req/s exhausts the range inside
the first second and then measures how fast the kernel releases ports.

Two practical consequences, both of which cost real time to find:

- The number is a property of `net.inet.ip.portrange` and
  `net.inet.tcp.msl`. Quoting it as "Feersum does 14k req/s" would be a
  lie, and an easy one to tell by accident.
- It poisons the *next* row. With the range exhausted, nothing can get
  an outbound port for the next half minute - not `wrk`, not `curl`, not
  the `nc -z` that asks whether the next server has bound. The first
  version of this script ran the defaults row first and reported the
  keep-alive row as `SKIPPED (never bound)`, which looked like a Feersum
  failure and was entirely an artefact of the measuring apparatus. The
  script now runs that row **last** and drains `TIME_WAIT` before
  continuing.

The finding worth keeping is the default itself, not the number: anyone
benchmarking Feersum out of the box against a keep-alive server is
reporting TCP connection setup as Feersum's speed.

## Fairness notes

- Same `bench/app.psgi` for every PSGI row, same worker count.
- Neither server recycles workers by default (Feersum's
  `max_connection_reqs` and Hyperman's `max_requests_per_worker` are
  both off), so unlike the Starman comparison no tuned row is needed on
  either side.
- Hyperman is measured through `plackup` as well as natively. The two
  best-of figures agree to within 0.6% (up to 4% inside a single run, in
  both directions), so the comparison is not flattered by skipping a
  layer Feersum also has to pay.
- Feersum gets a native-interface row it can win on. It is labelled
  `(not PSGI)` because PSGI middleware cannot run on it.
- Every server is proved to serve `Hello, World!` before it is timed. A
  row that measures a 404, or a server still holding the port from the
  row before, is worse than a missing row.

## What this is and is not

A plaintext micro-benchmark: no database, no template, no serialisation.
It measures the distance between the socket and the application, which
is what an event loop in C changes and what most real applications are
not bounded by.

Against Starman the honest summary was 8x and the caveat was that the
architectures differ. Against Feersum the architectures agree, the gap
narrows to 1.28x, and the interesting number is not the gap at all - it
is that Hyperman's PSGI path costs about what Feersum's non-PSGI path
costs.
