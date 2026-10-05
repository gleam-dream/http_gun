# Why the 1,000-caller burst is slow

Historical diagnosis. The owner subsequently authorized the [implemented correction](BURST_FIX.md), accepted on 2026-09-30 with a 45.333 ms burst median and full runtime gates. The original experiments and evidence below are retained unchanged.

The dominant cause is repeated work in HTTP Gun's Gleam pool. A large pending queue is rescanned after each response releases its connection and again after its body process exits. Each pass repeats origin normalization and connection eligibility checks for requests that still cannot run. The observed admission work grows approximately quadratically with burst size.

This is an HTTP Gun implementation problem. The evidence does not call for changes to Gun, Cowlib, Gleam, OTP or the foreign interface. The original Dream comparison's roughly 10.5× median difference (706/67 ms) is specific to that workload and its different connection policies; this diagnosis establishes our own avoidable work without relying on identical Dream settings.

## Evidence

Repeated on 2026-09-29 with the original comparison package, Gleam 1.18.1 / OTP29 / ERTS17.1, Darwin arm64. The workload and configuration remain as described in [the comparison report](DREAM_COMPARISON.md): three-byte responses, 1,000 same-origin H1 requests, four maximum connections, 60-second request budget. All unprofiled runs and both temporary probes returned the correct 3,000 bytes with zero failures.

The reproduction loop ranked three hypotheses before intervention: (1) repeated pending-queue scans dominate; (2) per-request actor/monitor overhead dominates; (3) connection policy accounts for most of the gap. The latter two remain background costs but do not explain the reduction obtained with the same number of callers, connections and body actors.

| Unprofiled case                                     | Median ms |        Range ms | Connections |
| --------------------------------------------------- | --------: | --------------: | ----------: |
| Original, 1,000 callers                             |   695.506 | 683.761–708.923 |           4 |
| Original, four workers processing 1,000 requests    |    38.566 |   35.730–39.075 |           4 |
| Diagnostic: omit repeated host lowercasing          |   374.577 | 366.880–381.764 |           4 |
| Diagnostic: stop checking an already blocked origin |    56.335 |   54.859–56.368 |           4 |

Each row has three fresh-VM trials. The two diagnostic rows are independent changes to the original isolated source, not cumulative optimizations. The first preserves behavior for this already-lowercase `localhost` workload only. The second exploits the workload's single queued origin: derive the protected-origin set from the first queued request and stop dispatch when that origin is blocked, retaining the remaining FIFO. It preserves the caller count, connection cap and body lifecycle, but does **not** implement general multi-origin scheduling. Neither is a production fix. Both were applied only in the ignored benchmark copy, then restored in a `finally` block and rebuilt with warnings as errors.

The single-origin experiment removes about 92% of the measured burst elapsed time while keeping the transport and process-per-request workflow. It is strong evidence that repeated scheduling work is the dominant cause here. It does not predict an exact production optimization result after preserving all origins, modes, deadlines and cancellation rules.

## Call counts and code path

OTP's [tprof](https://www.erlang.org/doc/apps/tools/tprof.html) counted functions in `http_gun@internal@pool` after explicitly loading that module. Counts include the two warmup requests. Profiled wall-clock times are excluded from the timing table because tracing changes execution cost and scheduling.

| Workload                     | Admission checks | Origin calculations | Actual launches |
| ---------------------------- | ---------------: | ------------------: | --------------: |
| 100 callers                  |            9,611 |              19,222 |             102 |
| 500 callers                  |          247,267 |             494,534 |             502 |
| 1,000 callers                |          993,648 |           1,987,296 |           1,002 |
| Four workers, 1,000 requests |            1,025 |               2,050 |           1,002 |

Doubling the burst from 500 to 1,000 produces about four times as many admission checks. The worker case launches exactly as many requests but avoids the large pending queue.

The causal path in [pool.gleam](../src/http_gun/internal/pool.gleam) is:

1. `open_request` puts blocked requests in one list. It also recomputes protected origins, appends the list and recounts waiters on each arrival.
2. `release_body` calls `dispatch`. `dispatch` computes the protected origins and folds over **every** pending request, even after all available connections have been taken.
3. `admit_live` normalizes the origin and searches/filter-checks connections for each entry. Most checks cannot admit anything.
4. `process_lost`, including normal body-process cleanup, calls `dispatch` again. The 1,000-caller profile recorded 2,011 dispatch calls, compared with 1,002 launches.

Narrow pool timing supports this path: admission, origin computation, connection scans and room checks dominate the profiled pool work; `launch` accounted for 0.29% of that profile. That percentage applies to the **instrumented pool profile**, not to uninstrumented whole-VM CPU time. The independent scheduling probe is the stronger performance evidence.

An initial whole-VM function trace perturbed execution enough to exceed the controlled server's five-second idle budget: 362 requests failed in that instrumented run. Its `profile-buffered.log` is retained but is **not** a valid successful benchmark or the source of the count table. A first narrow attempt returned no samples because the target module had not yet been loaded; the successful narrow runs explicitly load it and verify nonempty profiles and zero failures.

## Proposed correction

Remove the repeated work while preserving the accepted capabilities: store normalized origin with pending work, keep queues/counts by origin, and reconsider an origin when its connection/stream capacity or owner admission changes. Preserve reuse-first behavior, progress for other origins, deadlines, H1/H2 lease differences, recording order and cleanup. This is a systemic implementation correction within the existing design (`in-place-fix`, proposed now), not a behavior-rule change or new orchestration framework.

Caching only hostname normalization is a smaller local improvement, but the independent probe still took 375 ms; it leaves the queue-scan cause intact. More connections are not a demonstrated cure: the original comparison's setting-100 case was slower for HTTP Gun. Bounded `batch` admission is already available to applications, but it does not excuse slow handling of independently arriving callers.

A subsequent implementation should lock the real public failure pattern with a large same-origin backlog alongside a fast second origin, then verify deadlines, owner death, cancellation and H2 capacity changes. Re-run both burst and bounded benchmarks and the existing gates. No new regression test, production fix or accepted-design change was made during this diagnosis.

Raw evidence is in [burst-diagnosis](evidence/burst-diagnosis/): baseline/probe JSONL, successful call-count/time profiles, the qualified full-trace attempt, input hashes, restoration build log and [summary](evidence/burst-diagnosis/summary.json). All production hashes match the pre-diagnosis receipt; the isolated pool source was restored byte-for-byte. No temporary instrumentation remains in source.
