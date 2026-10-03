# Dream comparison — 2026-09-29

Historical baseline: the measurements below precede the [2026-09-30 burst fix](BURST_FIX.md). The corrected HTTP Gun median is 45.333 ms for 1,000 callers, versus 705.991 ms here. That follow-up includes fresh results for both clients and preserves a failed Dream trial; these original tables remain unchanged.

HTTP Gun completed all compared workloads. It was faster with four application workers and at 1/10/100 callers; both clients had similar 32 MiB pull-stream times. At 1,000 simultaneous callers, HTTP Gun was substantially slower than Dream's median result. Dream's burst results also varied widely. These measurements identify an HTTP Gun profiling opportunity; they do not establish a universal winner or a dependency defect.

Subsequent [burst diagnosis](BURST_DIAGNOSIS.md) identified repeated pending-queue scans in HTTP Gun's pool. An isolated single-origin scheduling probe reduced its burst median from 696 ms to 56 ms with the same four connections and 1,000 callers. That probe was removed before the later general correction. The measurements below describe the original implementation.

## Revision and test outcomes

The requested [Dream branch](https://github.com/lostbean/dream/tree/codex/http-client-combined) was pinned to [bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5](https://github.com/lostbean/dream/tree/bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5/modules/http_client), HTTP client 5.1.3. Its archive SHA256 is `d518ec13f566dd8d60482eef0076fa562625fed4f1f2ffcbb38c4cbc1d8735fd`. [Source receipts](evidence/dream-comparison/source.json) record file hashes before use. The isolated archive retains its MIT license. No Dream production or test source was patched, and no sibling checkout was modified.

| Check | Outcome |
| --- | --- |
| Dream, original lock, `gleam check` / `gleam test` | Both stopped before tests: stale local dependency versions |
| Dream, `gleam format --check` on Gleam 1.18.1 | Failed for `client.gleam`, `recorder.gleam`, `recording.gleam`; source left unchanged |
| Dream, two local lock entries reconciled | Check passed; **213 tests passed, zero failures** |
| HTTP Gun fast gate | **50 tests passed**, formatting/check/build/FFI warnings and package boundaries passed |
| Separate public API comparison package | Build with warnings as errors passed; **15 HTTP Gun and 16 Dream contract cases** checked |
| Repeated workloads | **54 runs**, zero request failures, all byte totals correct |

The two lock corrections were `dream` 2.3.1 → 2.4.1 and `dream_mock_server` 1.0.0 → 1.1.1, matching the archive's local manifests. Released dependency versions stayed unchanged for the successful native suite. An earlier broad dependency refresh failed because released `glisten` called the removed `gleam/list.range` API with stdlib 0.71; that experiment and the original failures remain in the evidence. Neither is reported as a passing raw-branch gate. Dream's Makefile was not used because its cleanup can kill unrelated owners of port 9876.

The comparative package uses a shared lock for both clients: stdlib 0.71.0, gleam_http 4.4.0, gleam_erlang/otp 1.3.0, gleam_json 3.1.0, gleam_yielder 1.1.0 and simplifile 2.7.0, plus the exact transitive dependencies in its [manifest](../examples/comparison/manifest.toml). This differs from Dream's native suite lock (including stdlib 0.67.1 and gleam_http 4.3.0). HTTP Gun production source and its dependency manifests are unchanged from [wave7](evidence/wave7/inputs-sha256.json).

## Public behavior

The harness exercises public imports against controlled loopback servers. It asserts each client's observed contract; passing does not mean the contracts are equivalent. Exact output: [HTTP Gun](evidence/dream-comparison/gun-contracts.jsonl), [Dream](evidence/dream-comparison/dream-contracts.jsonl).

| Scenario | HTTP Gun | Dream at the pinned revision |
| --- | --- | --- |
| Buffered 201 / empty 204 | Response with bytes / empty bytes | Response with string / empty string |
| Buffered 429 | Ordinary response data | `ResponseError` retaining status, headers and body |
| Buffered bytes `00 ff 80` | Preserved exactly | `RequestError`: conversion to string failed |
| Duplicate headers and trailers | Both duplicate values retained; trailers separate | Both duplicate values retained; trailers merged into buffered headers |
| Pull response 201 / 429 | Body delivered normally; status available on response | String errors `HTTP 201: abc` / `HTTP 429: abc` through `stream_yielder` |
| Pull empty 204 / binary 200 | Completed / all three bytes delivered | Completed / all three bytes delivered |
| TLS with a trusted local CA | Verified request succeeded | Verified request succeeded |
| Stop after the first pull chunk | Scope exit closed the socket within two seconds | `yielder.take(1)` did not close it within two seconds |
| Worker exits holding an unfinished pull stream | Owner monitor closed the socket within two seconds | No closure observed within two seconds |
| Explicit Dream callback cancellation | Scoped/owned cancellation covered by HTTP Gun's suite | `cancel_stream_handle` closed the socket within two seconds |
| Real record → server gone → replay | Replayed bytes, then `FixtureExhausted` | Replayed bytes; the single matching fixture remained reusable |
| Record identical requests returning `abc`, then `xyz` | Replayed both in order, then exhausted | Playback reported two ambiguous matches on each attempt |

Dream also exposes `stream_yielder_detailed` and `on_http_response_error`, preserving complete error responses. Its README documents that successful stream status is unavailable from `httpc`'s stream-start event, and distinguishes pull-based yielders from push-based callbacks. The tests above use its basic pull API; they do not imply that no richer error API exists. [Pinned Dream README](https://github.com/lostbean/dream/blob/bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5/modules/http_client/README.md).

The final cleanup cases send a 16 KiB first chunk, then withhold EOF. An earlier three-byte first-chunk probe once stalled before the first successful Dream read and ended with `socket_closed_remotely`; its [partial output](evidence/dream-comparison/dream-small-chunk-probe.jsonl) and [failure](evidence/dream-comparison/dream-small-chunk-probe.stderr) are retained. That pilot is not a diagnosed dependency bug or part of the successful final contract count. The two-second cleanup observation is a bounded check, not a claim that an abandoned request lives forever.

All timed cases use H1. Real H2 ALPN, same-connection multiplexing, sibling cancellation and capacity changes remain HTTP Gun checks in the passing fast gate and prior runtime matrix. Dream's selected `httpc` transport provides no comparable H2 client surface, so no H2 speed comparison is claimed. Persistence failures, strict mismatch behavior and interrupted recording are covered by the libraries' own suites, not by an exhaustive comparative fault matrix.

## Benchmark configuration

Apple M2 Max, 12 logical CPUs/schedulers, 32 GiB RAM, Darwin 25.5.0 arm64; pinned Nix shell, Gleam 1.18.1, OTP 29 / ERTS 17.1. [Input and environment receipt](evidence/dream-comparison/inputs.json). This comparison was not repeated on OTP 27/28 or Linux. HTTP Gun's earlier three-runtime full gate remains separate evidence.

Each measurement starts a fresh BEAM VM, warms the selected transport, and excludes compilation/startup from elapsed time. Buffered cases also warm one connection to the measured origin. Large/mixed cases warm the transport on a different connection; their measured time includes opening the workload connection. Three repetitions alternate client order. Both applications are present in the same dependency graph, but only the selected client handles each workload. No other test gate ran concurrently with timed trials.

Requests are GETs with empty bodies. Small responses are status 200 and exactly three ASCII bytes. Both clients use 60-second request settings, five-second connection settings, disabled redirects and the same CA policy. These settings do not imply identical deadline semantics. HTTP Gun uses H1, global/per-origin connection limits of 4 (or 100 in the sensitivity case), active/waiting limits of 1,024 each, 512 KiB admitted chunks, a 1 MiB body queue and its default 8 MiB collection limit. Large streams are consumed incrementally, outside the collector.

Dream uses a dedicated public `HttpProfile` with `max_sessions` 4 (or 100). **This is not the same limit as HTTP Gun's open-connection cap.** OTP defines `max_sessions` as persistent connections per host; separate `max_connections_open` controls open handlers and defaults to infinity. Dream's public profile constructor sets `max_sessions` and disables pipelining; it does not expose the latter bound. The observed extra connections are therefore not described as a cap violation. [OTP httpc options](https://www.erlang.org/doc/apps/inets/httpc.html#set_options/2). The selected runtime's [inets 9.8 defaults](evidence/dream-comparison/runtime-httpc-options.log) confirm that open handlers default to infinity.

The burst cases spawn one caller per input without an application concurrency gate. The bounded case runs exactly four caller workers, each sending its next request after completion; this compares both public request APIs with the same application admission rule. It does not compare a nonexistent Dream batch API with HTTP Gun's batch scheduler. The mixed case starts one 32 MiB slow stream and waits for its first chunk, then starts 1,000 small requests to the same origin. Slow consumption waits two milliseconds per accumulated 64 KiB, independent of transport chunk boundaries.

## Timings and connections

Elapsed milliseconds, **median [minimum–maximum] of three trials**. Connections are distinct server-side connection identities used by the workload, shown as the observed range; they are not a measurement of peak simultaneous sockets. The sensitivity row changes only the public connection/session setting to 100.

| Workload | HTTP Gun ms | Dream ms | Connections, Gun / Dream |
| --- | ---: | ---: | ---: |
| 1 caller | 0.54 [0.50–0.59] | 1.61 [1.59–2.05] | 1 / 1 |
| 10 callers | 1.70 [1.47–1.82] | 3.08 [2.77–3.17] | 3 / 4–5 |
| 100 callers | 10.46 [10.39–10.59] | 77.57 [65.03–83.68] | 4 / 24–26 |
| 1,000 callers | 705.99 [698.74–715.08] | 66.97 [43.86–1,084.23] | 4 / 11–431 |
| 1,000 requests, four workers | 35.42 [33.63–40.50] | 59.46 [58.10–63.50] | 4 / 1 |
| 1,000 callers, setting 100 | 1,129.77 [1,126.10–1,145.54] | 74.06 [37.04–199.95] | 44 / 8–33 |
| 32 MiB pull stream | 201.20 [196.73–204.65] | 205.13 [199.00–209.44] | 1 / 1 |
| 32 MiB slow reader | 1,552.46 [1,546.77–1,758.37] | 1,551.39 [1,550.97–1,566.94] | 1 / 1 |
| Slow stream + 1,000 callers | 1,542.85 [1,542.70–1,547.32] | 1,557.75 [1,548.89–1,558.65] | 4 / 10–220 |

The mixed elapsed time mostly measures the slow stream. Median per-trial p95 latency for its **small requests** was 691.77 ms for HTTP Gun and 31.76 ms for Dream. HTTP Gun's 1,000-caller behavior deserves profiling of its own admission and scheduling path. Raising the cap to 100 made its measured burst time worse, so merely increasing connection count is not a demonstrated fix. The four-worker result shows that caller admission policy materially changes performance. No CPU/reduction profile was collected, so the cause is not established.

## Sampled resources and request latency

Memory is the median of each trial's sampled **whole-VM** peak, including server processes, both installed applications, callers and the sampler. Mailbox/process/port columns are the largest sampled value across the three trials. The sampler checks approximately every ten milliseconds; it can miss short peaks, especially in the shortest cases. These are practical observations, not allocation bounds or retained-client-memory measurements. Erlang ports include both ends of sockets and runtime ports.

| Workload / client | p95 request ms, median | VM peak MiB, median | Max one mailbox | Max all mailboxes | Max processes | Max ports |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 callers / Gun | 700.81 | 64.08 | 678 | 679 | 1,091 | 11 |
| 1,000 callers / Dream | 37.86 | 65.39 | 996 | 998 | 894 | 223 |
| Four workers / Gun | 0.21 | 52.19 | 3 | 4 | 100 | 11 |
| Four workers / Dream | 0.33 | 51.53 | 3 | 3 | 94 | 5 |
| 32 MiB / Gun | — | 51.78 | 1 | 2 | 90 | 5 |
| 32 MiB / Dream | — | 51.40 | 1 | 2 | 90 | 4 |
| Slow reader / Gun | — | 51.81 | 1 | 1 | 90 | 4 |
| Slow reader / Dream | — | 51.17 | 1 | 1 | 90 | 4 |
| Mixed / Gun | 691.77 | 64.32 | 689 | 689 | 1,095 | 11 |
| Mixed / Dream | 31.76 | 63.45 | 1,009 | 1,009 | 953 | 105 |

Per-request timing begins in each worker before its public request call and includes client queuing; it excludes time before that worker runs. Bounded-case request percentiles exclude time an input waits for its worker's earlier jobs; total elapsed time includes all jobs. Mixed percentiles cover only small requests. Stream-only percentile fields are zero in raw output, meaning unmeasured, not zero latency. Raw [54 measurements](evidence/dream-comparison/benchmark.jsonl) and [all metric summaries](evidence/dream-comparison/summary.json) include p50/p95/p99 and ranges. Three local trials are too few for an SLA or statistical significance claim.

## Reproduction and scope

From the HTTP Gun root:

```sh
./dev/env python3 dev/comparison/run.py all
```

The [runner](../dev/comparison/run.py) downloads the exact hash-verified archive into ignored `build/dream-comparison`, builds the [separate consumer package](../examples/comparison/README.md), runs the native suite with the disclosed lock correction, runs contract checks and repeats the workloads. Initial downloads require network access; all HTTP test requests use local servers and temporary fixtures, without provider credentials. It overwrites the comparison evidence directory's named output files. Port 9876 must be free for Dream's suite; the runner refuses to take it from another process.

Use `contracts`, `bench --trials 3`, or `upstream` for individual phases; `summary` only recomputes summaries from saved measurements. Run `./dev/env sh dev/gate fast` separately for HTTP Gun's gate. The comparison is optional and does not add Dream to production dependencies or normal gates.

Gun remains the transport for HTTP Gun's H2, generic-byte and owned-stream contract. This work changed comparison tooling and documentation only. Production handwritten FFI remains **72 physical lines / 3,650 bytes, 12 bindings**: Gun calls/event adaptation, TLS/runtime primitives, scope/exception cleanup, unique temporary-path candidates and empty-directory removal. Comparison-only server/measurement helpers are test infrastructure. No library, protocol parser or runtime patch was introduced.
