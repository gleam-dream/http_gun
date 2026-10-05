# Burst admission correction — 2026-09-30

The 1,000-caller H1 burst now completes in a median **45.333 ms**, compared with **705.991 ms** in the original comparison: **15.6× faster**, with the same four-connection cap and correct responses. Three final trials took 45.247–60.599 ms. All 27 HTTP Gun comparison runs succeeded. This fixes avoidable work in our Gleam implementation; Gun, Cowlib, public APIs, package manifests and production FFI are unchanged.

## What changed

The [diagnosis](BURST_DIAGNOSIS.md) identified repeated full-queue scans. The pool now caches each normalized origin and maintains a FIFO per live origin, checking its head until it cannot progress. Other origins remain eligible. Origins that make progress yield their place for the next admission pass. Playback uses one session FIFO, preserving explicit cross-origin arrival order.

A small typed [pending queue](../src/http_gun/internal/pending.gleam) uses the existing stdlib dictionary for request/owner indexes and FIFO links. Expiry and caller death unlink the entry immediately; waiting counts are maintained with the queue. Body owners are indexed too. The [pool actor](../src/http_gun/internal/pool.gleam) owns these transitions. No cancelled-entry history or extra server is introduced.

The first general queue correction reduced the burst median to 174.907 ms. Review then found another cost: a cleanup callback passed into each body actor captured the entire pool state, carrying its waiting requests across a process boundary. Both live and playback callbacks now capture only their destination identifiers. Generated Erlang shows the difference: [before](evidence/wave9/callback-before.txt), [after](evidence/wave9/callback-after.txt). The [intermediate measurements](evidence/wave9/comparison-before-capture-fix/summary.json) remain separate from the final results.

No scheduling shortcut depends on the benchmark's hostname, request count or response size. Connection reuse, H1 leases, H2 stream capacity, deadlines, recording reservations and cleanup retain their existing contracts.

## Work removed

Separate OTP `tprof` call-count runs confirm the change. Counts include two warmup requests; profiled elapsed times are excluded from performance comparisons.

| Callers | Admission checks before → after | Origin calculations before → after | Actual launches |
| ------: | ------------------------------: | ---------------------------------: | --------------: |
|     100 |                     9,611 → 296 |                       19,222 → 102 |             102 |
|     500 |                 247,267 → 1,497 |                      494,534 → 502 |             502 |
|   1,000 |                 993,648 → 2,997 |                  1,987,296 → 1,002 |           1,002 |

The new 500-to-1,000 increase is approximately twofold instead of fourfold. Sources: [original profiles](evidence/burst-diagnosis/), final [100](evidence/wave9/call-count-buffered-100.log), [500](evidence/wave9/call-count-buffered-500.log), [1,000](evidence/wave9/call-count-buffered-1000.log). Four workers processing 1,000 requests required [1,020 checks](evidence/wave9/call-count-bounded-1000.log).

## Repeated local comparison

Same pinned Dream revision and public harness as the [original report](DREAM_COMPARISON.md): `bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5`. Gleam 1.18.1, OTP29/ERTS17.1, Apple M2 Max, 12 logical CPUs, 32 GiB RAM, Darwin arm64. Three fresh-VM trials per case, alternating client order, after transport warmup. No other gate or profiling job ran concurrently. Request/connect budgets are 60/5 seconds; HTTP Gun admits at most 1,024 active bodies and 1,024 waiters. The ordinary burst uses a hard four-connection cap; the setting-100 case is separate. Stream chunk/queue limits are 512 KiB/1 MiB.

Times below are medians in milliseconds. Dream's `max_sessions` controls persistent sessions and is not HTTP Gun's hard open-connection cap; observed connections remain part of the result. This is a practical H1 comparison, not an equivalent-socket-budget or universal performance claim.

| Workload                            | HTTP Gun before | HTTP Gun after |                       Dream rerun |
| ----------------------------------- | --------------: | -------------: | --------------------------------: |
| 1 caller, setting 4                 |           0.536 |          0.481 |                             1.750 |
| 10 callers, setting 4               |           1.698 |          1.698 |                             2.670 |
| 100 callers, setting 4              |          10.457 |          4.891 |                           102.506 |
| 1,000 callers, setting 4            |         705.991 |         45.333 | 35.840 / 66.631; one failed trial |
| 1,000 requests, four workers        |          35.420 |         35.813 |                            61.600 |
| 1,000 callers, setting 100          |       1,129.773 |         48.860 |                            44.457 |
| 32 MiB stream                       |         201.200 |        201.873 |                           207.527 |
| 32 MiB slow consumer                |       1,552.462 |      1,539.712 |                         1,546.585 |
| Slow stream plus 1,000 fast callers |       1,542.846 |      1,543.994 |                         1,555.800 |

All **27/27 HTTP Gun runs** returned exact byte totals and zero failures. Dream completed **26/27 runs** without failures. Its second setting-4 burst observed 393 distinct connections and 48 connection-timeout failures, completing in 5,013.866 ms. The two successful trials observed 6 and 30 connections. The comparison command therefore exited **1**; the failed trial is retained, not replaced by a rerun or included as a successful timing. This observation alone does not locate a Dream, httpc, server or operating-system defect. No upstream fix was attempted.

The fast callers' median trial p95 in the mixed case fell from **691.767 to 45.283 ms**. Total mixed elapsed time still includes the deliberately slow stream. Four-worker and large-stream measurements remain similar to their previous values.

Resource observations below are medians of each trial's sampled peak, including local server, callers, dependencies and sampler. Sampling occurs approximately every 10 ms and can miss short peaks. Connections are distinct server-observed identities, not sampled peaks.

| HTTP Gun workload              | Connections before / after | VM MiB before / after | Total mailbox before / after | Largest mailbox before / after | p95 ms before / after |
| ------------------------------ | -------------------------: | --------------------: | ---------------------------: | -----------------------------: | --------------------: |
| 1,000-caller burst, cap 4      |                      4 / 4 |         64.08 / 66.49 |                    646 / 154 |                      645 / 140 |      700.813 / 39.107 |
| Four workers, 1,000 requests   |                      4 / 4 |         52.19 / 52.12 |                        4 / 4 |                          1 / 2 |         0.214 / 0.202 |
| 32 MiB stream                  |                      1 / 1 |         51.78 / 51.88 |                        2 / 2 |                          1 / 1 |          not measured |
| Slow stream plus 1,000 callers |                      4 / 4 |         64.32 / 64.56 |                      674 / 5 |                        674 / 3 |      691.767 / 45.283 |

The burst's sampled memory did not decrease; this is principally a work/latency correction. Exact ranges and every scenario's sockets, memory, mailboxes, processes and latency are in the [raw runs](evidence/wave9/comparison/benchmark.jsonl) and [summary](evidence/wave9/comparison/summary.json). [Input hashes and environment](evidence/wave9/comparison/inputs.json) identify the final source. Original and intermediate measurements remain untouched.

## Correctness and acceptance

Seven public regression scenarios were added: burst work scaling; FIFO and capacity after head/middle/tail caller removal; another origin progressing past 500 blocked callers; queued deadlines restoring capacity; eligible origins taking turns under a shared body limit; cross-origin playback ordering; and queued H2 streams resuming on the same connection after cancellation.

The old implementation failed the work-scaling check ([red](evidence/wave9/scaling-red.log)). A controlled two-origin test failed without rotation ([red](evidence/wave9/fairness-red-controlled.log)); both are green in the final gates. The scaling test compares VM reductions for 500 versus 1,000 warmed callers, avoiding a tight elapsed-time threshold. Existing recording, shutdown, TLS, H2 multiplexing/sibling cancellation and persistence-fault tests remain included.

| Final check                 | Outcome                                                                                                                 |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Fast gate                   | 57 tests; formatting, check/build, handwritten FFI warnings and boundaries pass ([log](evidence/wave9/fast.log))        |
| Full OTP29 / ERTS17.1       | 57 tests, two consumers, four expected type rejections, 11 load scenarios pass ([log](evidence/wave9/default-full.log)) |
| Full OTP28 / ERTS16.4.0.6   | Same complete gate passes ([log](evidence/wave9/otp28-full.log))                                                        |
| Full OTP27 / ERTS15.2.7.13  | Same complete gate passes ([log](evidence/wave9/otp27-full.log))                                                        |
| Comparison public contracts | All 15 HTTP Gun and 16 Dream observations match their recorded contracts                                                |
| Comparison benchmark        | HTTP Gun 27/27; Dream 26/27; overall command exits 1 as described above                                                 |
| Final narrow profiles       | All four workloads complete with correct bytes and zero failures                                                        |

The full gates separately exercised real H2. OTP29 completed 1,000 H1 requests in 44.741 ms on four connections and 1,000 H2 requests in 56.167 ms on one connection. The slow H2 stream plus 1,000-request bounded batch took 120.316 ms on one connection. These are single-run gate measurements, not repeated H2 benchmark claims. Full receipts: [OTP29](evidence/wave9/default-load.jsonl), [OTP28](evidence/wave9/otp28-load.jsonl), [OTP27](evidence/wave9/otp27-load.jsonl).

The executed source matches the [frozen gate inputs](evidence/wave9/inputs-before-gate.json). Only `pool.gleam` and the new `pending.gleam` change production code. Handwritten production FFI remains **72 physical lines / 3,650 bytes / 12 bindings**: supported Gun calls/message conversion, monotonic time, exception cleanup, unique filesystem names and empty-directory removal. No dependency, wire parser or Erlang orchestration changed.

## Reproduction and remaining boundaries

```sh
./dev/env sh dev/gate fast
./dev/env sh dev/gate full
sh dev/matrix
./dev/env python3 dev/comparison/run.py contracts --output build/burst-recheck
./dev/env python3 dev/comparison/run.py bench --trials 3 --output build/burst-recheck
```

Use a new comparison output directory to preserve prior receipts. The original Dream native-suite qualification remains the earlier 213-test result with its two disclosed local lock corrections; that native suite was not rerun for this pool-only change.

Scheduling still examines waiting origins and the configured connection set. Origin ordering operations scan the finite origin list; this is not a constant-work guarantee for arbitrarily many distinct origins. An application can still flood the client mailbox before requests reach admission. Three local trials and sampled resources are not an SLA or a memory certification. Linux CI was not executed locally. Existing [dependency boundaries and optional features](../BOUNDS.md) remain unchanged.
