# Local acceptance evidence

## Warden feedback: waves29–31

The corrected working tree passes **128 tests on both stdlib0.71.0 and1.0.5**
in each full Darwin ARM64 gate: Gleam1.18.1, OTP29/ERTS17.1,
OTP28/ERTS16.4.0.6 and OTP27/ERTS15.2.7.13. The public dependency bound now
admits1.x while the normal lock retains0.71. All111 frozen executable/dependency
inputs match the final source. Public API documentation builds.
[Receipt](evidence/wave31/receipt.json), [input hashes](evidence/wave31/inputs.json),
[commands and retained failures](evidence/wave31/README.md),
[runtime logs](evidence/wave31/runtimes/).

New public tests prove in-memory DER CA trust with wrong-name/untrusted controls;
empty/non-byte configuration rejection and invalid-only DER refusal; fresh
connections after acknowledged idle TLS close; request/response close-token
retirement; the original deadline during readiness inspection; and preservation
of Gun's structured header-limit error. H1 readiness runs in bounded Gleam jobs,
reserves admission capacity and is not cached across dispatch passes. It is an
observation before submission, not an atomic remote-liveness guarantee. No
submitted request is replayed. Gun/Cowlib remain unmodified.

Every full gate also passes three public consumers, seven intended type
rejections with positive control,1196 archived LLM split points, async ownership
and startup-failure checks, real TLS/H2 and sibling cancellation, seven nghttpd
scenarios,256 actual recorded/replayed exchanges totaling8MiB, batch trials
through10000 and eleven load scenarios including32MiB streams and slow readers.

| OTP | nghttpd1000 elapsed ms | p95 ms | Peak sampled VM bytes | Largest mailbox | Connections |
| --- | ---: | ---: | ---: | ---: | ---: |
|29|81.321|74.456|71239164|275|1|
|28|87.398|78.268|71205153|148|1|
|27|89.137|80.798|70110881|167|1|

These are individual local samples with nghttpd1.70.0, peer stream limit8,
client active128/waiting1024, a60-second budget and256-byte replies. The sampler
can miss peaks and excludes the C server. Complete H1/H2 counts1/10/100/1000,
mixed consumers, sockets, processes and latency measurements are retained.
No new comparative benchmark, Linux/hosted CI or sustained soak is claimed.

Warden's retained experiment was rerun in temporary copies, using direct
`config.Anchors` and the new `HeaderLimitReached` mapping. Its transport tests
were unchanged: **17 pass,2 fail**. All9 security probes pass, including G3 at
100/1000/3000ms after close, Connection:close retirement, mailbox0→0 and bounded
shutdown. The fast suite including probes is124 pass/2 fail;13 intended public
type rejections plus positive control and8 consumer tests pass. Its live IPv6
port443 subcase could not bind and was skipped; the non-default-port exchange
and HTTP Gun's authority formatting test pass.
[Exact adapter and receipt](evidence/wave31/warden-final/receipt.json).

The remaining transport tables require distinctions Gun does not expose for
four malformed/truncated cases, and strict rejection of the accepted discarded
reason-phrase/mixed-LF case. Header-limit precision is corrected; the other
four cases remain failures with coarse causes. No assertion was waived or
changed. Warden's release/migration acceptance is **not complete**.

Current LLM Wire1c0ad614 separately passes223 tests, its public boundary and five
local TLS/H2 scenarios through1000 callers. As in wave28, only eight test/example
files in disposable copies opt into loopback; production source is unchanged.
All selected originals match after both isolated consumer checks.
[LLM receipt and setup patch](evidence/wave31/downstream-final/receipt.json).

The first complete run found an eligible-origin ordering regression on1.0.5;
active reservations fixed it before the final matrix. The final matrix passed
OTP29/28, then Hex rate limiting interrupted OTP27 dependency resolution. A
concurrent LLM attempt hit the same limit after check passed. Sequential retries
of those two incomplete gates pass without further runtime changes. Initial
failures are retained. Nothing was committed, published or changed in sibling
checkouts during this follow-up.

## Historical destination policy and DNS pinning: waves25–28

The final source passes **120 tests** in the fast gate and full gates on Darwin
ARM64, Gleam1.18.1, OTP29/ERTS17.1, OTP28/ERTS16.4.0.6 and
OTP27/ERTS15.2.7.13. Commands: `./dev/env sh dev/gate fast`,
`./dev/env sh dev/gate full`, and
`sh docs/evidence/wave28/remaining-matrix.sh` for the other two pinned shells.
All106 executable/dependency inputs remain identical to the qualified hashes.
[Receipt](evidence/wave28/receipt.json), [inputs](evidence/wave28/inputs.json),
[runtime logs and measurements](evidence/wave28/runtimes/).

New checks cover default refusal before any connection; explicit loopback opt-in;
private/mixed/empty/failed DNS answers; exact case-insensitive host allowlists;
50 address-classification cases; one injected lookup and checked-connection reuse;
original-hostname and IP-SAN TLS with trusted wrong-name negative controls;
blocked/throwing resolvers, cancellation/deadline/caller/client death and progress
at another origin; strict offline modes and recorded destination refusals;
IPv6 authority, complete admitted heads and malformed framing/header values.

Four non-reading-server cases use16MiB buffered uploads, fresh/reused TCP and
TLS connections and a300ms request budget. All return DeadlineExceeded and
complete client cleanup within1500ms test tolerance; caller mailbox size is
unchanged. A separate synchronized test checks long-lived callers after body
cancellation/deadline, server closure and client shutdown. A100ms connection
budget probe also passes; it is additional coverage, not a reproduced defect.
The public API is not a real-time scheduler or proof of remote cancellation.

The full gates retain three external consumer packages, positive compilation
control/seven intended type rejections,1196 archived LLM split points,11 async
lifecycle groups and startup-failure control, H1/TLS/H2 and sibling-preserving
cancellation, batch scaling through10000, seven nghttpd1.70.0 scenarios,
256 record/replay exchanges totaling8MiB, and eleven load scenarios including
1/10/100/1000 requests,32MiB streams and mixed slow/fast consumers. Public API
documentation also builds. No new Linux/hosted-CI, Dream comparison or sustained
soak execution is claimed for this change.

| OTP | nghttpd1000 elapsed ms | p95 ms | Peak sampled VM bytes | Largest mailbox | Connections |
| --- | ---: | ---: | ---: | ---: | ---: |
|29|114.471|102.378|69530244|39|1|
|28|82.494|74.184|68856592|149|1|
|27|87.016|79.239|71873942|184|1|

These independent-server runs use one H2 connection, peer stream limit8,
client active128/waiting1024, a60-second budget and256-byte replies. They are
individual local samples; sampling may miss peaks and excludes the C server.
They are not an overhead comparison or universal allocation guarantee.

Current LLM Wire1c0ad614 passes unmodified check/build; its existing test setup
produces175 passes/48 failures because it previously used the default for local
servers. An experiment changes only eight test/example configuration files in
**disposable copies**, enabling loopback explicitly. All223 tests, its public
boundary controls and five local TLS/H2 scenarios through1000 callers pass.
Production LLM Wire source is unchanged; both original checkouts are unchanged
during each check. [Original receipt](evidence/wave28/downstream-original/receipt.json),
[adapted receipt and exact setup patch](evidence/wave28/downstream-adapted/receipt.json).
This is an adoption requirement, not a claim that the untouched downstream suite
passes. Warden230c6bb4 is read-only reference evidence: no Warden migration,
release or execution of its own adapter gate is claimed.

The owner accepted a measured parser exception: Gun/Cowlib accepts control bytes
in status reason phrases and discards that text before exposing a response.
HTTP Gun cannot validate it through the supported API. Delivered header values
are now checked. [Raw local dependency probe](evidence/wave27/parser-probe.log).
A disposable SNI=disable mutation fails the IP-literal negative control by
accepting the trusted wrong-host certificate; the real implementation omits SNI
and passes. [Mutation result](evidence/wave28/ip-sni-mutation.json).

Retained reds are default loopback connection, ignored injected private DNS,
and accepted header control bytes. An initial IP test certificate was rejected
as a self-signed peer and replaced with a proper separate test CA; no TLS
verification bypass was added. Initial gate corrections were an asynchronous
recording test that needed finish_wait and a local example configuration alias.
Their logs are retained with the final passing runs. Dependencies remain
unmodified. Current FFI counts and boundaries are below; earlier sections are
historical receipts.

## Historical Sinal lifecycle integration: waves22–24

All three full gates pass on Darwin ARM64 with Gleam 1.18.1 and OTP29/ERTS17.1, OTP28/ERTS16.4.0.6 and OTP27/ERTS15.2.7.13. Each includes 98 tests, format/check/build, handwritten FFI warnings as errors, three public consumers, a positive compiler control and seven intended type rejections, 1196 archived LLM stream split points, 11 async lifecycle groups and startup-failure control, batch scaling through 10000, seven independent nghttpd scenarios, 256 record/replay exchanges totaling 8 MiB and eleven controlled load scenarios. All 97 frozen executable/dependency inputs stayed unchanged. [Receipt and commands](evidence/wave24/receipt.json), [inputs](evidence/wave24/inputs.json), [runtime logs/measurements](evidence/wave24/runtimes/).

Sinal's own 93 tests and three synchronized startup/restart probes pass on each runtime. A capacity1 blocked observation handler does not prevent a 1000-request, 16-worker batch from completing: one coalesced drop notice remains queued and at least3999 observations are rejected. An isolated synchronous-delivery mutation fails that same public test for the intended timeout. [Wave23 red/green evidence and final Sinal source hashes](evidence/wave23/README.md). No permanent runtime test hooks exist.

Current LLM Wire at `1c0ad614` passes 223 tests, its public consumer/boundary controls and five local TLS/H2 scenarios on OTP29. At1000 simultaneous callers it reports no failures and one connection; cancellation preserves a healthy 2 MiB sibling. All selected originals remain unchanged during validation. [Downstream receipt](evidence/wave24/current-downstream/receipt.json).

`sh dev/matrix` first passed OTP29, then hit Hex's API rate limit on OTP28. A parallel downstream attempt also hit that limit during its public boundary check, after all223 tests passed. Both failed attempts are retained under [rate-limit-attempt](evidence/wave24/rate-limit-attempt/). The remaining two full gates and downstream check subsequently passed sequentially with no production change. The [resume command](evidence/wave24/resume-matrix.sh) is retained. Generated dependency/archived-donor deprecation warnings remain; owned handwritten FFI passes `-Werror`.

Representative independent-server runs use nghttpd1.70.0, one H2 connection, peer stream limit8, client active128/waiting1024, a60-second request budget and256-byte replies. Observation is disabled for these existing load scenarios; the enabled-observation bound is tested separately above. These single local runs are not an overhead comparison or universal memory guarantee. Sampling can miss peaks and excludes the C server. The complete1/10/100/1000,32 MiB and mixed slow/fast measurements are retained beside each runtime log.

| OTP |1000 callers elapsed ms|p95 ms|Peak sampled VM bytes|Largest sampled mailbox|Connections|
|---|---:|---:|---:|---:|---:|
|29|95.509|82.375|70027911|57|1|
|28|82.794|72.342|67360009|140|1|
|27|97.341|78.104|73398335|91|1|

HTTP Gun production FFI is unchanged: 92 lines/4669 bytes/13 bindings. Sinal is the only authorized sibling changed; Gun/Cowlib remain unmodified. No Linux/hosted CI, new Dream comparison, sustained soak or comparative enabled-telemetry overhead benchmark is claimed for this follow-up. Observation remains best effort, with no remote-receipt, durable-delivery or exporter-queue guarantee. The exact API and one-source dependency arrangement are in [OBSERVATIONS.md](OBSERVATIONS.md).

## Historical adoption follow-up: waves18–21

The final local matrix passes on Darwin ARM64 with Gleam1.18.1 and OTP29/ERTS17.1, OTP28/ERTS16.4.0.6 and OTP27/ERTS15.2.7.13. Command: `sh dev/matrix`. Each isolated full gate passes91 tests, formatting/check/build, FFI warnings/boundaries, three public consumers, positive compilation control/six intended symbol-specific rejections,1196 archived LLM split points,11 async lifecycle groups plus token-startup fault injection, batch trials through10000, seven independent nghttpd scenarios,256 record/replay exchanges (8MiB), and eleven controlled load scenarios. All90 frozen executable/dependency inputs remained unchanged. [Final receipt](evidence/wave21/receipt.json), [input hashes](evidence/wave21/inputs.json), [raw runtime logs and measurements](evidence/wave21/runtimes/).

The opt-in current downstream check separately passes223 LLM Wire tests, its public boundary/consumer and five independent local H2 scenarios on OTP29. Its receipt precedes the final example-only startup correction; [source recheck](evidence/wave21/downstream-source-recheck.json) proves every production HTTP Gun/dependency input still matches. All selected sibling source bytes also match. Sinal's Git metadata advanced afterward from77fcbef to098a2d5 without changing these selected bytes; it was not modified by this task. [Exact downstream commands, revisions and hashes](evidence/wave21/current-downstream/receipt.json).

Representative independent-server qualification uses one H2 connection, peer limit8, client active128/waiting1024,60-second deadlines and256-byte responses. These are individual local observations, not a comparative benchmark or allocation guarantee. The VM sampler can miss transient peaks; it excludes the independent C server. Other1/10/100,32MiB and mixed slow/fast results are retained alongside the logs.

| OTP |1000 callers elapsed ms|p95 ms|Peak sampled VM bytes|Largest sampled mailbox|Connections|
|---|---:|---:|---:|---:|---:|
|29|80.730|74.123|70147564|227|1|
|28|80.644|71.606|71613137|158|1|
|27|86.421|78.653|67822303|152|1|

Red/green evidence includes missing public functions, an intentionally incompatible downstream export, and the async example's stray completion message on token-startup failure. The controlled fault is injected only into a temporary copy at the OTP startup boundary; it checks exact Failure mapping, callback suppression and64 failed starts without mailbox retention. Normal production code contains no injection hook. See [startup red](evidence/wave21/startup-red.log) and [green](evidence/wave21/startup-green.log).

The bounded observation experiment is documented separately in [ADOPTION_IMPROVEMENTS.md](ADOPTION_IMPROVEMENTS.md); its synthetic storage results do not constitute integrated HTTP telemetry. No production observation API was added. Linux, hosted CI, a new Dream comparison and another sustained soak were not rerun here. Their earlier receipts remain historical. FFI is unchanged at92 lines/4669 bytes/13 declarations, covering only Gun/runtime bindings, event/error conversion, exception-safe cleanup and missing filesystem primitives.

Current downstream check: [dev/check_downstream.py](../dev/check_downstream.py) runs explicitly selected LLM Wire/HTTP Gun sources in temporary copies, independent of the ordinary package gate. Wave18 passes223 downstream tests, public-boundary positive control/six intended rejections and five local H2 scenarios on Darwin ARM64/OTP29. Exact working-source hashes and commands: [receipt](evidence/wave18/current-downstream/receipt.json). Historical sections retain their original source/runtime scope. See [usage](DOWNSTREAM.md).

Run `./dev/env sh dev/gate fast` for the fast gate and `./dev/env sh dev/gate full` for the complete local gate. `sh dev/matrix` creates independent build directories and runs the full gate on the three pinned OTP shells. No sibling checkout is written and no provider credentials or public application endpoints are used. Fresh Nix/Hex dependency installation can need network access.

## Covered contracts

The fast gate runs formatting, Gleam check, build with warnings as errors, 128 observable tests, `erlc -Werror` over handwritten production/test FFI, and dependency/public-import/Dynamic boundary checks. The full gate repeats that suite on stdlib1.0.5 after resolving an independent public consumer against the actual package bounds.

| Area | Executed observations |
| --- | --- |
| Ordinary HTTP | Real binary 201; arbitrary methods; non-2xx final status; informational head; empty 204; duplicate headers and trailers; host-only URL; invalid method/query; partial-byte rejection; configured H1/H2 header counts above Gun’s default |
| Lifecycle | Scoped normal/exception cleanup; shared copied cursor; wrong-owner/conflicting read; local wait versus overall deadline; normal/abnormal owner death; batch owner loss; shutdown; bounded collection |
| Pool | H1 reuse; eligible other-origin progress past a 500-caller backlog; FIFO after head/middle/tail caller death; waiting cap; queued deadlines with NotSubmitted and restored capacity; eligible-origin rotation under shared body capacity; idle eviction; standard supervisor child; warmed 500/1,000-caller work scaling |
| TLS/H2 | Verified H1 TLS; unknown-CA and hostname rejection; ALPN H2 and required-H2 fallback refusal; same-connection multiplexing; local cancellation/reset preserving siblings and resuming queued streams; demand/window resumption; zero peer capacity; GOAWAY with an active sibling completing, then an explicit fresh request |
| Batch | Binary requests, input-associated ordered results, independent failures, bounded workers, public batch scaling through 10,000 inputs, 1,000-request mixed-stream load |
| Playback | Binary versioned codec; 65 generated exchanges containing all 256 byte values; ordered distinct repeated replies; queued cross-origin session order; mismatch without consumption; missing/corrupt/incompatible/exhausted fixtures; no network fallback; meaningful headers and credential exclusions; exact disk-read limits |
| Request controls | Expired monotonic deadline, client ceiling, queued/pre-header/body cancellation, shared connecting reservation cleanup, scope/creator death, completed-HTTP preservation, H2 sibling survival, controls in live/record/playback |
| Diagnostics | Typed limit kind and observed size; real refusal/certificate/file failures; safe formatter; exhaustive typed error codec roundtrip; single strict schema; obsolete layout/missing size/unknown marker rejection; negative budget refusal before IO |
| Recording | Bounded finish wait, sealing, timeout without draining, waiter contention/death, abort; actual live roundtrip; prefix plus cancellation/failure; pre-header failure; concurrent recording/replay; writer backpressure; finite budget; Busy/finalized/refused states; explicit replacement; real EISDIR/FIFO persistence faults; interrupted capture never publishes; owner-only temporary permissions |

The full gate additionally builds a separate package using public imports only. One consumer performs buffered, scoped and batch calls unchanged across live, record and playback clients. Six negative compilations must fail: constructing Client, Body, Recording, Deadline or Token, and passing a String body to `send`. The compiler does not prohibit all internal-module imports; public-import use is checked separately, and no stronger opacity claim is made.

The isolated LLM consumer verifies retained source hashes, compiles against its own dependency lock, and uses public LLM Wire interfaces over scoped HTTP Gun streams. It checks live progress before EOF, early cancellation, all 1196 provider-fixture split points, finite parsing/body limits, status/compression handling, partial-disconnect evidence, idle expiry and actual recording/playback. Provider semantics and its retained bounded framer remain outside HTTP Gun. This text-oriented example does not migrate or validate the entire LLM Wire session runtime.

The full gate also runs three fresh-VM public batch trials through 10,000 inputs; independent nghttpd 1.70.0 TLS/H2 interoperability with server-observed single-connection multiplexing/cancellation; and 256 concurrent recording/byte-exact replay exchanges totaling 8 MiB of request plus response bytes. See [the adoption follow-up](ADOPTION_VALIDATION.md) for setup and boundaries. A separate 60-second nghttpd steady run is retained outside the fast/full gate.

## Load method

`gleam run -m http_gun_benchmark` runs eleven loopback scenarios. Concurrent request counts are 1, 10, 100 and 1,000 for both H1 and verified TLS/H2. Each run uses a fresh client, 60-second deadline, 128 active handles, 1,024 waiting requests, four H1 connections or one H2 connection with 100 admitted streams. The load generator creates exactly the named number of finite callers; this deliberately measures admission pressure as well as transport work. Successful response headers identify actual server connections.

The 32 MiB H1 stream is counted incrementally, once at full speed and once with a 1 ms consumer pause after each received chunk. Its delivered-chunk/queue limits are 512 KiB/1 MiB. The mixed H2 scenario keeps a slow response open, completes 1,000 fast requests through `batch(..., 64)`, then reads and cancels the slow stream; it asserts one connection.

A test-only sampler checks all local BEAM processes approximately every 10 ms. Memory, process, port and mailbox peaks include the client, local server, caller load generator, dependencies and sampler. Fast scenarios may finish between samples. Latency covers `send`, including admission/connection time. Percentiles use the sorted finite sample (floor rank); zero percentile fields on whole-stream/mixed measurements mean “not measured”, not zero latency. Connections are server-observed identities for concurrent runs; port counts include listeners and non-HTTP runtime ports.

These are one-run practical measurements on a local machine, not a throughput SLA, statistical benchmark or adversarial memory certification. The finite admitted queues do not prevent arbitrary external processes from first placing calls in actor mailboxes. See [BOUNDS.md](../BOUNDS.md).

## Current pre-release cleanup receipt

The current tree passes86 tests and all six full gates on ARM64 Darwin/Linux × OTP29/28/27: [receipt](evidence/wave17/receipt.json), [frozen inputs](evidence/wave17/final-inputs.json), [fast/docs gate](evidence/wave17/final-fast-docs.log). Each full gate passes both independent examples, six type rejections,1196 LLM split points, three batch trials through10000 inputs, seven nghttpd scenarios (one connection, two resets),256 recorded/replayed exchanges totaling8MiB and eleven controlled load scenarios. Runtime versions and configuration match the preceding receipt; current per-runtime logs and measurements are under wave17/darwin and wave17/linux. Host/container qualification overlaps, so timing is not an isolated comparative benchmark.

This cleanup rejects obsolete fixture error layouts and removes their decoder/OtherLimit, requires observed limit sizes, and refuses negative fixture budgets before IO. Exact failing/passing logs are retained. An unused-import warning and a fixed-count test polling race were corrected; bounded finish_wait replaces the polling helper. Package version, dependencies and production FFI are unchanged. All current executable input hashes match; historical85-test compatibility evidence below describes the prior tree only.

## API ergonomics receipt (before pre-release cleanup)

Waves13–16 passed the then-current85-test fast gate and all six full gates on ARM64 Darwin/Linux with OTP29/28/27. [Receipt](evidence/wave16/receipt.json) records outcomes, runtime versions and artifact hashes; [frozen inputs](evidence/wave16/final-inputs.json) identify the captured wave16 source, before cleanup. [Direct fast/consumer/docs log](evidence/wave16/final-fast-consumers-docs.log) includes generated public documentation. All runtimes pass both consumers, six expected type rejections,1196 provider split points, three batch trials through10000 requests, seven independent-server scenarios,256 byte-exact recorded/replayed exchanges/8MiB and eleven load scenarios.

| Runtime | Darwin ARM64 | Linux ARM64 |
| --- | --- | --- |
| OTP29 / ERTS17.1 | [full PASS](evidence/wave16/darwin/default.log) | [full PASS](evidence/wave16/linux/default.log) |
| OTP28 / ERTS16.4.0.6 | [full PASS](evidence/wave16/darwin/otp28.log) | [full PASS](evidence/wave16/linux/otp28.log) |
| OTP27 / ERTS15.2.7.13 | [full PASS](evidence/wave16/darwin/otp27.log) | [full PASS](evidence/wave16/linux/otp27.log) |

The host uses the pinned Gleam1.18.1/Nix runtime. Linux runs the pinned official Nix ARM64 image with4 CPUs,4GiB and `+S4:4`, using a read-only source archive and private build copies. Host and container qualification overlap, so elapsed figures are local observations, not an isolated before/after comparison. Full per-runtime batch, load, recording and nghttpd metrics are adjacent to each log; they include sockets, sampled VM memory/mailboxes and latency. No new Dream comparison or60-second soak is claimed.

The final shared-connection reservation regression fails with84 passing/1 failing test before the pool cleanup and passes85 afterward: [red](evidence/wave16/shared-reservation-red.log), [green](evidence/wave16/shared-reservation-green.log). Other retained waves cover missing APIs, callback errors, token/deadline cleanup, real certificate/refusal/file errors, strict fixture migration and safe descriptions. TLS rejection notices and historical dependency deprecation warnings are expected; this package's own warning gates pass.

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
| `src/http_gun_ffi.erl` | 113 | 5,469 | Native IP parsing/lookup and tuple conversion; Gun application/open/request/flow/cancel/close and advisory info calls, TLS trust/identity and finite send options, event/cause conversion, clock and exception-safe cleanup |
| `src/http_gun_file_ffi.erl` | 8 | 431 | Unique temporary-directory candidate name and empty-directory removal |
| Total | 121 | 5,900 | Sixteen external bindings; no pool, body, batch or cassette server |

These are the wave31 counts. Wave28 had113 lines/5585 bytes/15 bindings. This follow-up adds one small exception-safe `gun:info/1` binding, one cacerts option variant and one structured error mapping. All preparation workers and admission decisions remain in Gleam. file_streams and simplifile supply ordinary filesystem IO; their released code is a dependency, not counted as handwritten HTTP Gun FFI. Counts include blank/comment lines. Test-only loopback servers and instrumentation are excluded from production FFI. Gleam owns admission policy, states, deadlines, demand, monitoring, batch scheduling, matching, JSON codec, recorder coordination and finalization ordering. Internal typed bridge declarations live in Gleam; raw Dynamic is confined to event/JSON boundaries.

## Optional features and inherited behavior

No required client workflow is deferred after this acceptance. The documented follow-on features are streamed uploads, redirect/decompression policy, proxies/mTLS, cookies/cache and optional SSE. Dependency parsing/TLS/HPACK allocations remain outside our application storage guarantee; that is not evidence of an upstream defect. GOAWAY can race with submission; HTTP Gun owns cleanup and truthful failures without replay. Body/query redaction and crash-durable publication are optional HTTP Gun features, currently unimplemented, that require no Gun/Cowlib changes. Bodies/queries may contain secrets and interrupted recordings may leave private temporary files. Atomic publication provides complete-fixture visibility, not power-loss durability. Performance figures are sampled local observations. ARM64 Linux container gates are local evidence; remote GitHub-hosted x86_64 CI is not claimed as executed.
