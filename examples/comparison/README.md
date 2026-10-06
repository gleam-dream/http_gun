# Local HTTP comparison

This separate Gleam package compares the public HTTP Gun and Dream APIs using
local HTTP/1.1 servers. `comparison_adapter` retains status, error and body
differences while giving the workload driver one call shape.

`comparison_contract` exercises binary responses, status handling, duplicate
headers, trailers, local TLS, early closure, owner exit, explicit Dream callback
cancellation and disk record/playback. These are behavioral observations, separate
from the timing measurements below.

## Retained measurements

The retained run accompanies the
[2026-09-30 scheduling correction](../../docs/adr/0003-origin-lanes-and-minimal-process-captures.md).
Its [input receipt](../../docs/history/evidence/wave9/comparison/inputs.json)
records exact HTTP Gun and harness source hashes: Gleam 1.18.1, OTP 29 / ERTS
17.1, macOS 26.5.2 ARM64, Apple M2 Max, 12 logical CPUs/schedulers and 32 GiB RAM.
It does not record a separate HTTP Gun commit id. Dream is pinned to
`bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5` with archive and module hashes in the
[source receipt](../../docs/history/evidence/dream-comparison/source.json).
These measurements predate the current checkout and have not been rerun for
this documentation change.

Each case uses three fresh BEAM VMs, warms the transport and alternates client
order. Elapsed time excludes compilation and VM startup. Requests are GETs with
empty bodies; small responses are status 200 and three bytes. Request/connect
settings are 60/5 seconds. HTTP Gun has a four-connection cap except where the
setting is 100, and admits 1,024 open bodies and 1,024 queued requests. Dream's
persistent-session setting has different connection semantics; the four-worker
case gives both clients the same application concurrency.

The table gives median elapsed milliseconds with minimum–maximum across
successful trials. Values come from the
[raw measurements](../../docs/history/evidence/wave9/comparison/benchmark.jsonl)
and [summary](../../docs/history/evidence/wave9/comparison/summary.json).

| Workload                              |   HTTP Gun ms: median [min–max] |                  Dream ms: median [min–max] |
| ------------------------------------- | ------------------------------: | ------------------------------------------: |
| 1 caller, setting 4                   |             0.481 [0.437–0.496] |                         1.750 [1.619–1.878] |
| 10 callers, setting 4                 |             1.698 [1.663–1.987] |                         2.670 [2.504–2.879] |
| 100 callers, setting 4                |             4.891 [4.627–4.960] |                    102.506 [46.662–121.579] |
| 1,000 callers, setting 4              |          45.333 [45.247–60.599] | 51.236 [35.840–66.631], 2 successful trials |
| 1,000 requests, four workers          |          35.813 [35.810–37.279] |                      61.600 [58.925–63.479] |
| 1,000 callers, setting 100            |          48.860 [44.798–54.675] |                      44.457 [40.405–68.492] |
| 32 MiB stream                         |       201.873 [194.308–205.758] |                   207.527 [199.254–208.163] |
| 32 MiB slow reader                    | 1,539.712 [1,537.749–1,547.623] |             1,546.585 [1,540.455–1,548.644] |
| Slow stream plus 1,000 small requests | 1,543.994 [1,540.637–1,545.679] |             1,555.800 [1,545.494–2,062.938] |

The slow reader waits 2 ms per accumulated 64 KiB. The mixed case begins the
32 MiB slow stream before starting 1,000 small requests to the same origin.
Its elapsed time includes the slow stream; median trial p95 for just its small
requests is 45.283 ms for HTTP Gun and 30.585 ms for Dream. Stream-only percentile
fields in raw output are unmeasured.

One Dream burst measurement is omitted from the timing aggregate
because it failed: the
[failed-trial observation](../../docs/history/evidence/wave9/comparison/failed-trial-observation.json)
records 48 connection-timeout failures, 393 distinct connections and 5,013.866 ms
elapsed. The successful Dream burst trials used 6 and 30 distinct connections;
HTTP Gun used 4 in each trial. The comparison command exited 1 for that failed
case. These observations do not identify the cause of the failure.

Resource measurements in the raw receipts sample whole-VM memory, mailboxes,
processes and ports approximately every 10 ms, including local servers, callers
and the sampler. They can miss short peaks. Connections are distinct server-side
identities, not peak simultaneous sockets. Three local H1 trials establish
neither a general performance ranking nor latency or allocation guarantees.

## Run the harness

Run from the HTTP Gun root. For a fresh comparison workspace, materialize the
bundled Sinal snapshot before the wrapper builds its copied HTTP Gun package:

```sh
./dev/env python3 dev/sinal_source.py build/dream-comparison/sinal
./dev/env python3 dev/comparison/run.py all --trials 3 --output build/comparison-recheck
```

The Sinal extraction command requires a new destination. Reuse an existing
matching snapshot when rerunning the comparison. Use a new output directory to
preserve receipts. `contracts`, `bench --trials 3` and `upstream` run individual
parts; `summary` recomputes statistics from saved measurements.

The wrapper copies this consumer into `build/dream-comparison/runner` alongside
isolated client packages, reviewed local servers, certificates and the sampler.
It downloads the pinned Dream archive when absent and checks its recorded hashes.
Dream's source and MIT notice stay in its isolated checkout. No Dream source is
copied into this package. `comparison_ffi.erl` contains only argument conversion
and finite local test servers.

The two clients share the comparison lock. Reproduction runs the current HTTP
Gun source, so it creates new evidence rather than reproducing the retained
source hashes automatically. See [TESTING.md](../../docs/TESTING.md) for package
qualification and keep those checks separate from benchmark timing.
