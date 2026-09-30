# Local acceptance evidence

Run `./dev/env sh dev/gate fast` for the fast gate and `./dev/env sh dev/gate full` for the complete local gate. `sh dev/matrix` creates independent build directories and runs the full gate on the three pinned OTP shells. No sibling checkout is written and no provider credentials or public application endpoints are used. Fresh Nix/Hex dependency installation can need network access.

## Covered contracts

The fast gate runs formatting, Gleam check, build with warnings as errors, 62 observable tests, `erlc -Werror` over handwritten production/test FFI, and dependency/public-import/Dynamic boundary checks.

| Area | Executed observations |
| --- | --- |
| Ordinary HTTP | Real binary 201; arbitrary methods; non-2xx final status; informational head; empty 204; duplicate headers and trailers; host-only URL; invalid method/query; partial-byte rejection; configured H1/H2 header counts above Gun’s default |
| Lifecycle | Scoped normal/exception cleanup; shared copied cursor; wrong-owner/conflicting read; local wait versus overall deadline; normal/abnormal owner death; batch owner loss; shutdown; bounded collection |
| Pool | H1 reuse; eligible other-origin progress past a 500-caller backlog; FIFO after head/middle/tail caller death; waiting cap; queued deadlines with NotSubmitted and restored capacity; eligible-origin rotation under shared body capacity; idle eviction; standard supervisor child; warmed 500/1,000-caller work scaling |
| TLS/H2 | Verified H1 TLS; unknown-CA and hostname rejection; ALPN H2 and required-H2 fallback refusal; same-connection multiplexing; local cancellation/reset preserving siblings and resuming queued streams; demand/window resumption; zero peer capacity; GOAWAY with an active sibling completing, then an explicit fresh request |
| Batch | Binary requests, input-associated ordered results, independent failures, bounded workers, public batch scaling through 10,000 inputs, 1,000-request mixed-stream load |
| Playback | Binary versioned codec; 65 generated exchanges containing all 256 byte values; ordered distinct repeated replies; queued cross-origin session order; mismatch without consumption; missing/corrupt/incompatible/exhausted fixtures; no network fallback; meaningful headers and credential exclusions; exact disk-read limits |
| Recording | Actual live roundtrip; prefix plus cancellation/failure; pre-header failure; concurrent recording/replay; writer backpressure; finite budget; Busy/finalized/refused states; explicit replacement; real EISDIR/FIFO persistence faults; interrupted capture never publishes; owner-only temporary permissions |

The full gate additionally builds a separate package using public imports only. One consumer performs buffered, scoped and batch calls unchanged across live, record and playback clients. Four negative compilations must fail: constructing Client, Body or Recording, and passing a String body to `send`. The compiler does not prohibit all internal-module imports; public-import use is checked separately, and no stronger opacity claim is made.

The isolated LLM consumer verifies retained source hashes, compiles against its own dependency lock, and uses public LLM Wire interfaces over scoped HTTP Gun streams. It checks live progress before EOF, early cancellation, all 1196 provider-fixture split points, finite parsing/body limits, status/compression handling, partial-disconnect evidence, idle expiry and actual recording/playback. Provider semantics and its retained bounded framer remain outside HTTP Gun. This text-oriented example does not migrate or validate the entire LLM Wire session runtime.

The full gate also runs three fresh-VM public batch trials through 10,000 inputs; independent nghttpd 1.70.0 TLS/H2 interoperability with server-observed single-connection multiplexing/cancellation; and 256 concurrent recording/byte-exact replay exchanges totaling 8 MiB of request plus response bytes. See [the adoption follow-up](ADOPTION_VALIDATION.md) for setup and boundaries. A separate 60-second nghttpd steady run is retained outside the fast/full gate.

## Load method

`gleam run -m http_gun_benchmark` runs eleven loopback scenarios. Concurrent request counts are 1, 10, 100 and 1,000 for both H1 and verified TLS/H2. Each run uses a fresh client, 60-second deadline, 128 active handles, 1,024 waiting requests, four H1 connections or one H2 connection with 100 admitted streams. The load generator creates exactly the named number of finite callers; this deliberately measures admission pressure as well as transport work. Successful response headers identify actual server connections.

The 32 MiB H1 stream is counted incrementally, once at full speed and once with a 1 ms consumer pause after each received chunk. Its delivered-chunk/queue limits are 512 KiB/1 MiB. The mixed H2 scenario keeps a slow response open, completes 1,000 fast requests through `batch(..., 64)`, then reads and cancels the slow stream; it asserts one connection.

A test-only sampler checks all local BEAM processes approximately every 10 ms. Memory, process, port and mailbox peaks include the client, local server, caller load generator, dependencies and sampler. Fast scenarios may finish between samples. Latency covers `send`, including admission/connection time. Percentiles use the sorted finite sample (floor rank); zero percentile fields on whole-stream/mixed measurements mean “not measured”, not zero latency. Connections are server-observed identities for concurrent runs; port counts include listeners and non-HTTP runtime ports.

These are one-run practical measurements on a local machine, not a throughput SLA, statistical benchmark or adversarial memory certification. The finite admitted queues do not prevent arbitrary external processes from first placing calls in actor mailboxes. See [BOUNDS.md](../BOUNDS.md).

## Adoption follow-up receipt

The final full gates pass on **Darwin ARM64 and Linux ARM64**, each on OTP 29/ERTS 17.1, OTP 28/ERTS 16.4.0.6 and OTP 27/ERTS 15.2.7.13, using Gleam 1.18.1. Each of the six runs passes 62 tests, format/check/build, handwritten FFI warnings and boundaries; two external consumers; four type rejections; all 1196 LLM fixture split points and live streaming scenarios; three public batch trials through 10,000 inputs; seven independent nghttpd scenarios; the 256-exchange recording/replay workload; and the eleven original controlled-server load scenarios.

[Final receipt](evidence/wave12/receipt.json), [final executable hashes](evidence/wave12/final-inputs.json), [environment](evidence/wave12/environment.json), [Darwin wrapper](evidence/wave12/darwin-matrix.log), [Linux wrapper](evidence/wave12/linux-container.log), [Darwin raw gates](evidence/wave12/darwin/) and [Linux raw gates](evidence/wave12/linux/) retain exact outcomes. The code, consumer, gate and dependency inputs match across platforms. Two post-snapshot changes are identified explicitly: example README prose and repeatable post-gate artifact export. Final Darwin executable hashes are unchanged throughout its successful rerun. No production Hex dependency or FFI change occurred.

The independent-server1000-caller measurements below use one connection, peer concurrency 8, client active 128/waiting 1024, 60-second deadlines and 256-byte responses. Latencies include scheduling from caller arrival. These are individual qualification runs, not comparable platform benchmarks: Linux is a four-CPU/four-GiB Docker container with four Erlang schedulers; Darwin uses the host's 12 logical CPUs. The sampler includes all BEAM processes but excludes the independent C server. Verbose server logging is enabled. Fast samples can miss short-lived peaks.

| Platform / OTP | Elapsed ms | Request p95 ms | Peak VM bytes | Largest sampled mailbox |
| --- | ---: | ---: | ---: | ---: |
| Darwin 29 | 82.914 | 76.089 | 65703538 | 138 |
| Darwin 28 | 82.422 | 75.013 | 70238209 | 109 |
| Darwin 27 | 87.378 | 80.194 | 71648375 | 205 |
| Linux 29 | 255.245 | 247.184 | 61413105 | 63 |
| Linux 28 | 268.167 | 259.932 | 62062729 | 132 |
| Linux 27 | 267.553 | 263.117 | 67183743 | 10 |

Each server receipt observes one request connection and two stream resets. The mixed-scenario percentile field is labeled `local_cancel_to_empty_snapshot`; it is a single cancellation measurement, not a request latency distribution. Unmeasured new percentile fields are null. The earlier pilot/soak files use zero for unmeasured percentiles; those zeros are not measured zero latency.

The separate 60-second run completed 317,900 requests without failure and ended with zero body handles/waiters. Its exact setup and the 256-exchange/8MiB recording workload are described in [ADOPTION_VALIDATION.md](ADOPTION_VALIDATION.md). The Linux source exporter initially included macOS resource-fork sidecars; omitting that metadata fixed the compiler failure. An overlapping edit to the first Darwin matrix wrapper caused exit 127 after its gates passed; the final frozen rerun exits 0. Both failed attempts remain in the evidence, and neither is presented as a client or dependency defect.

Reproduce Linux with `sh dev/linux-gate` using an available Docker engine. It uses a pinned official ARM64 Nix image, read-only source archive and isolated build directory. The hosted GitHub x86_64 CI job was not executed in this workspace; no x86_64 execution claim is made. All tests use local servers and temporary fixtures, without provider credentials. The LLM Wire sibling remains read-only and unchanged; its full session-runtime migration remains separate work.

## Burst-fix receipt

The final wave9 source passed the direct fast gate and all three isolated full gates on 2026-09-30. Each full gate passed **57 tests**, both separate consumer packages, four expected type rejections and all eleven load scenarios. The source and executable gate inputs were unchanged throughout these runs: [frozen inputs](evidence/wave9/inputs-before-gate.json), [receipt](evidence/wave9/receipt.json), [fast log](evidence/wave9/fast.log).

| Runtime | Result | Receipt |
| --- | --- | --- |
| OTP 29 / ERTS 17.1 | full PASS | [log](evidence/wave9/default-full.log), [measurements](evidence/wave9/default-load.jsonl) |
| OTP 28 / ERTS 16.4.0.6 | full PASS | [log](evidence/wave9/otp28-full.log), [measurements](evidence/wave9/otp28-load.jsonl) |
| OTP 27 / ERTS 15.2.7.13 | full PASS | [log](evidence/wave9/otp27-full.log), [measurements](evidence/wave9/otp27-load.jsonl) |

Seven new public scenarios cover burst work, queue removal/capacity, blocked-origin progress, queued deadlines, origin fairness, playback order and H2 resumption. The work-scaling test failed on the old pool; the controlled fairness test failed without origin rotation. Final gates include all prior recording, persistence, lifecycle and transport scenarios. Only the Gleam pool and its new typed queue change production code; dependencies and the 72-line FFI remain unchanged.

The separate comparison checked all 15 HTTP Gun and 16 Dream public observations. HTTP Gun passed 27/27 repeated timed runs, with its 1,000-caller median falling from 705.991 to 45.333 ms at the same four-connection cap. Dream passed 26/27 runs; one burst reported 48 connection timeouts, making the overall comparison exit 1. This is retained as a comparison failure, not a passing whole-comparison gate or an HTTP Gun failure. The [fix report](BURST_FIX.md) gives configuration, ranges, resource samples, profiles and exact reproduction. Dream's native suite was not rerun; its historical 213-test result remains separate. Linux CI was not run locally.

## Filesystem follow-up receipt

The authorized follow-up passed on 2026-09-29 America/Sao_Paulo, with the same pinned Gleam/runtime matrix. The direct fast gate passed 50 tests. Each full matrix run passed 50 tests, two separate consumer packages, four expected type rejections and 11 load scenarios. Executable inputs were checked unchanged during the matrix. Exact timestamp and source hashes: [receipt](evidence/wave7/receipt.json), [inputs](evidence/wave7/inputs-sha256.json).

| Runtime | Result | Receipt |
| --- | --- | --- |
| OTP 29 / ERTS 17.1 | full PASS | [log](evidence/wave7/otp29-full.log), [measurements](evidence/wave7/otp29-load.jsonl) |
| OTP 28 / ERTS 16.4.0.6 | full PASS | [log](evidence/wave7/otp28-full.log), [measurements](evidence/wave7/otp28-load.jsonl) |
| OTP 27 / ERTS 15.2.7.13 | full PASS | [log](evidence/wave7/otp27-full.log), [measurements](evidence/wave7/otp27-load.jsonl) |

The filesystem refactor preserved the 48-test baseline, including actual write/stall faults, destination replacement/refusal and exact file-read bounds. Separate H1 and negotiated-H2 tests failed before correcting the supported header-count setting, then passed: [H1 red](evidence/wave7/h1-red.log), [H2 red](evidence/wave7/h2-red.log), [final fast gate](evidence/wave7/fast.log). All three runtimes retained same-connection H2 multiplexing and healthy sibling cancellation.

The wave7 OTP 29 run completed 1,000 H1 requests on 4 connections in 712.78 ms and 1,000 H2 requests on 1 connection in 588.82 ms. Both 32 MiB stream cases and the mixed slow-stream/1,000-request batch passed. These are fresh observations under the methodology above, not a performance improvement claim; full memory/mailbox/latency samples are in the linked JSONL files. Linux CI has not been run locally.

## Original six-wave runtime receipt

The original six-wave full matrix passed on 2026-09-29 America/Sao_Paulo (receipt completed 2026-09-30T00:08:41Z), on Darwin 25.5.0 arm64. Each runtime used Gleam 1.18.1 and passed the then-current gate: 47 tests, two external consumers, four expected compiler rejections and eleven load scenarios.

| Runtime | ERTS | Result | Receipt |
| --- | --- | --- | --- |
| OTP 29 | 17.1 | full PASS | [log](evidence/otp29-full.log), [measurements](evidence/otp29-load.jsonl) |
| OTP 28 | 16.4.0.6 | full PASS | [log](evidence/otp28-full.log), [measurements](evidence/otp28-load.jsonl) |
| OTP 27 | 15.2.7.13 | full PASS | [log](evidence/otp27-full.log), [measurements](evidence/otp27-load.jsonl) |

The final fast gate also passed directly in the owned checkout. The unknown-CA and hostname-mismatch TLS notices are expected negative-test output. OTP 29 emits deprecated-catch warnings in the released gleam_stdlib and isolated historical LLM dependencies; HTTP Gun's own Gleam build and handwritten Erlang warning gates pass. Dependencies were not modified to hide warnings. CI is configured to repeat the full gate on Linux; remote CI has not been executed or claimed.

## Representative measurements

Original six-wave OTP 29 run; time and latency below are milliseconds, memory is sampled whole-VM MiB. See the methodology above before interpreting these numbers.

| Scenario | Requests | Elapsed ms | p50 / p95 / p99 ms | Connections | VM MiB | Mailbox total / one |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| h1-concurrent | 1 | 43.30 | 43.23 / 43.23 / 43.23 | 1 | 51.18 | 1 / 1 |
| h2-concurrent | 1 | 50.39 | 50.34 / 50.34 / 50.34 | 1 | 55.24 | 1 / 1 |
| h1-concurrent | 10 | 1.98 | 1.59 / 1.80 / 1.80 | 3 | 55.38 | 1 / 1 |
| h2-concurrent | 10 | 3.77 | 3.57 / 3.65 / 3.65 | 1 | 55.55 | 0 / 0 |
| h1-concurrent | 100 | 10.35 | 7.39 / 9.96 / 10.07 | 4 | 56.72 | 47 / 47 |
| h2-concurrent | 100 | 9.08 | 7.50 / 8.73 / 8.80 | 1 | 57.16 | 43 / 43 |
| h1-concurrent | 1000 | 702.24 | 522.27 / 696.35 / 698.97 | 4 | 68.63 | 642 / 642 |
| h2-concurrent | 1000 | 662.02 | 448.16 / 655.49 / 658.75 | 1 | 70.49 | 633 / 633 |
| large-stream | 1 | 201.22 | — | 1 | 59.31 | 2 / 1 |
| large-slow-reader | 1 | 7341.65 | — | 1 | 59.10 | 2 / 1 |
| h2-slow-stream-plus-batch | 1000 | 134.05 | — | 1 | 72.93 | 123 / 123 |

All requested exchanges/bytes completed without retries. Both large-stream rows represent 32 MiB. H2 cancellation preserved the slow stream's healthy fast siblings on the same connection. The mixed scenario used batch concurrency 64; the 1,000 independent-call scenarios deliberately included 1,000 caller processes, while HTTP Gun admission remained finite. Exact process/port peaks and all runtime results are in the JSONL receipts.

## Handwritten production FFI

| File | Physical lines | Bytes | Responsibilities |
| --- | ---: | ---: | --- |
| `src/http_gun_ffi.erl` | 64 | 3,219 | Gun application/open/request/flow/cancel/close calls, supported TLS/protocol/header-count options, Gun event decoding, clock, scope cleanup and exception-only cleanup |
| `src/http_gun_file_ffi.erl` | 8 | 431 | Unique temporary-directory candidate name and empty-directory removal |
| Total | 72 | 3,650 | Twelve external bindings; no pool, body, batch or cassette server |

These are the current wave7 counts, reduced from 102 lines / 4,782 bytes in wave6. file_streams and simplifile now supply ordinary filesystem IO; their released code is a dependency, not counted as handwritten HTTP Gun FFI. Counts include blank/comment lines. Test-only loopback servers and instrumentation are excluded from production FFI. Gleam owns admission policy, states, deadlines, demand, monitoring, batch scheduling, matching, JSON codec, recorder coordination and finalization ordering. Internal typed bridge declarations live in Gleam; raw Dynamic is confined to event/JSON boundaries.

## Optional features and inherited behavior

No required client workflow is deferred after this acceptance. The documented follow-on features are streamed uploads, redirect/decompression policy, proxies/mTLS, cookies/cache and optional SSE. Dependency parsing/TLS/HPACK allocations remain outside our application storage guarantee; that is not evidence of an upstream defect. GOAWAY can race with submission; HTTP Gun owns cleanup and truthful failures without replay. Body/query redaction and crash-durable publication are optional HTTP Gun features, currently unimplemented, that require no Gun/Cowlib changes. Bodies/queries may contain secrets and interrupted recordings may leave private temporary files. Atomic publication provides complete-fixture visibility, not power-loss durability. Performance figures are sampled local observations; Linux CI and other operating systems are not claimed as locally executed.
