# Benchmarks

Measurements of HTTP Gun and the pinned Dream client over local HTTP/1.1
servers. They are observations about one workload on one machine. They state no
ranking, latency promise or allocation guarantee. The references behind the
comparison and how outcomes are classified are in [ORACLE.md](ORACLE.md).

## Scope

- Nine workloads: single and concurrent small GETs at several connection settings, a 32 MiB stream, a slow 32 MiB reader and a slow stream with 1,000 small requests to the same origin.
- Both clients run the same workload driver through `comparison_adapter`. A client's own connection model is reported and never normalized away.
- Memory, mailbox, process and port samples cover the whole VM, so they include the local servers, the callers and the sampler. They bound nothing inside Gun or Cowlib.

## Method

- Each case uses three fresh BEAM VMs, warms the transport and alternates client order. Elapsed time excludes compilation and VM startup.
- Requests are GETs with empty bodies. Small responses are status 200 and three bytes. Request and connect settings are 60 and 5 seconds.
- HTTP Gun uses a four-connection cap except where the setting is 100, and admits 1,024 open bodies and 1,024 queued requests. Dream's persistent-session setting has different connection semantics, so the four-worker case gives both clients the same application concurrency.
- The slow reader waits 2 ms per accumulated 64 KiB.
- Source hashes for HTTP Gun and the harness are recorded in `docs/evidence/comparison/inputs.json`. They do not include a separate HTTP Gun commit id.

## Run

```sh
./dev/env python3 dev/comparison/run.py all --trials 3 --output build/comparison-recheck
```

- `contracts`, `bench --trials 3` and `upstream` run single parts. `summary` recomputes statistics from saved measurements.
- A rerun writes new evidence for the current source. It never reproduces the retained hashes.
- The weekly extended workflow runs the pinned comparison. [ADR 0014](adr/0014-qualify-behavior-through-isolated-gates-and-public-consumers.md) states its retention.

## Retained results

Retained run of 2026-09-30, accompanying the scheduling correction in [ADR 0003](adr/0003-origin-lanes-and-minimal-process-captures.md). It predates the current checkout and has not been rerun for it.

- **Environment:** Gleam 1.18.1, OTP 29 (ERTS 17.1), macOS 26.5.2 ARM64, Apple M2 Max, 12 logical CPUs and schedulers, 32 GiB RAM.
- **Dream pin:** `bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5`, source receipt `docs/evidence/dream-comparison/source.json`.

Median elapsed milliseconds with minimum and maximum across successful trials:

| Workload                              | HTTP Gun                        | Dream                                       |
| ------------------------------------- | ------------------------------- | ------------------------------------------- |
| 1 caller, setting 4                   | 0.481 [0.437–0.496]             | 1.750 [1.619–1.878]                         |
| 10 callers, setting 4                 | 1.698 [1.663–1.987]             | 2.670 [2.504–2.879]                         |
| 100 callers, setting 4                | 4.891 [4.627–4.960]             | 102.506 [46.662–121.579]                    |
| 1,000 callers, setting 4              | 45.333 [45.247–60.599]          | 51.236 [35.840–66.631], 2 successful trials |
| 1,000 requests, four workers          | 35.813 [35.810–37.279]          | 61.600 [58.925–63.479]                      |
| 1,000 callers, setting 100            | 48.860 [44.798–54.675]          | 44.457 [40.405–68.492]                      |
| 32 MiB stream                         | 201.873 [194.308–205.758]       | 207.527 [199.254–208.163]                   |
| 32 MiB slow reader                    | 1,539.712 [1,537.749–1,547.623] | 1,546.585 [1,540.455–1,548.644]             |
| Slow stream plus 1,000 small requests | 1,543.994 [1,540.637–1,545.679] | 1,555.800 [1,545.494–2,062.938]             |

- The mixed case's elapsed time includes the slow stream. The median trial p95 of its small requests alone is 45.283 ms for HTTP Gun and 30.585 ms for Dream. Stream-only percentile fields in the raw output are unmeasured.
- One Dream burst trial failed and is excluded from the aggregate: 48 connection-timeout failures, 393 distinct connections and 5,013.866 ms elapsed. The successful Dream burst trials used 6 and 30 distinct connections and HTTP Gun used 4 in each. The observations do not identify the cause.
- Raw data stays beside the receipts as non-markdown files: `docs/evidence/comparison/benchmark.jsonl`, `summary.json`, `inputs.json` and `failed-trial-observation.json`.

## Limits

- Three local trials on one machine establish scheduling behavior for these workloads only.
- Comparing wall time without matching concurrency misattributes pool semantics, so read the four-worker row, not the setting-4 rows, for equal application concurrency.
- The batch scaling guard `5000 requests < 15 × 500-request median + 50 ms` is a regression guard from the same correction and adds no absolute latency promise.

## Related

- Design verification: [Validation profiles and gates](design/design.typ#validation-profiles-and-gates) and [Comparison and benchmark method](design/design.typ#comparison-and-benchmark-method).
- Records: [ADR 0013](adr/0013-report-comparison-measurements-as-scoped-workload-evidence.md) and [ADR 0014](adr/0014-qualify-behavior-through-isolated-gates-and-public-consumers.md).
- Runnable harness: [examples/comparison](../examples/comparison/README.md).
