# Wave tracker: Gleam-first HTTP Gun

## Current state

- Tracker path: docs/implementation/gleam-first/wave-tracker.md
- Updated: 2026-10-01; Warden feedback waves29–31 qualified locally.
- Target: docs/DESIGN.md and the owner's restart prompt; plan revision 11 (Warden feedback).
- Approved first milestone: standard binary Request -> real local Gun HTTP -> buffered Response with trailers, using Gleam ownership. Final acceptance includes all six waves; the first milestone is not completion.
- Approval: the original prompt explicitly supplied and authorized the complete six-slice program, directed continuation without another broad approval cycle, and selected Gun/OTP/Gleam. Follow-up explicitly requested progressive implementation. This records that existing authorization, not inferred approval from silence.
- Last closed wave: 31. Active: none.
- Open material decisions: Warden must reconcile its two remaining transport tables and qualify a released dependency before adoption. No parser patch or invented failure precision is proposed here.
- Temporary production substitutes: none. Loopback H1/H2 servers are test infrastructure, never production paths.
- Gate: full Darwin ARM64 gates pass on OTP29/28/27, each with128 tests on stdlib0.71.0 and1.0.5, three consumers, seven intended type rejections,1196 LLM split points, batch scaling, nghttpd H2, recording/replay and eleven load scenarios. Current isolated LLM Wire passes223 tests with explicit loopback setup. Warden security probes9/9 pass, but unchanged transport tests remain17/19. Exact receipts: docs/VALIDATION.md and docs/evidence/wave31/receipt.json. Linux receipts are historical; no current Linux run is claimed.
- Commit: the owner authorized local integration of waves29–31 after qualification; all111 frozen executable/dependency inputs reverified, with the normal fast pre-commit gate enabled. No push/publication or sibling edit is included.
- Next action: Warden adoption/release remains separate, with its two failing transport tables explicitly recorded. Optional client features remain deferred.
- Recovery: archives and hashes in docs/PROGRESS.md. No old production runtime was retained. All six retained waves pass the completed gates.

## Technology and boundary decision register

| Role                | Adopt / contract / first wave                                         | Alternatives and reason                                                                  | Evidence / revisit                                                                                               |
| ------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Compiler/runtime    | locked Gleam 1.18.1 and OTP 29, wave 1                                | retain reproducible Nix rather than ambient runtime                                      | `gleam --version`, `system_info`; OTP27/28 compatibility checked in wave6 before claims                          |
| HTTP values         | gleam_http 4.4.0, wave1                                               | custom request types rejected: duplicate facts                                           | inspected Request/Response APIs; external consumer wave6                                                         |
| Orchestration       | gleam_otp 1.3.0, gleam_erlang 1.3.0, wave1                            | handwritten Erlang servers rejected by owner                                             | inspected typed actors, selectors, monitors, supervision; process.call panics, so use typed monitored calls      |
| Wire                | Gun 2.6.0, Cowlib 2.20.0, wave1                                       | HTTPc violates selected transport; old Erlang orchestration rejected                     | released Hex versions verified; untouched source; real socket proof wave1 and TLS/H2 wave3                       |
| Fixture codec       | gleam_json 3.1.0, wave4                                               | raw Erlang terms rejected as portable fixture contract                                   | selected dependency API to inspect at wave4; bounded versioned binary encoding                                   |
| Persistence         | file_streams 1.7.0 and simplifile 2.7.0, wave7; Gleam writer retained | replaces wave5 primitives after broader ecosystem review; stdlib1-only releases deferred | bounded raw reads/exclusive writes; atomic link/rename; small bridges only for missing primitives; FILESYSTEM.md |
| Test infrastructure | gleeunit 1.9.0 and reviewed loopback servers, wave1/3                 | provider endpoints excluded                                                              | exact inherited file hashes in provenance.json; test servers use Cowlib, not a production parser                 |

Sources: https://hex.pm/packages/gun, https://hex.pm/packages/cowlib, cached selected Gleam package source, https://gleam.run/news/. References guide scenarios only; no upstream parity claimed.

## Complete wave map

All waves use docs/DESIGN.md's corresponding numbered acceptance and Ownership and transitions contracts. Fast gate is `./dev/env sh dev/gate fast`; full is `./dev/env sh dev/gate full`. The gate is grown as its surfaces exist; absent later checks remain pending, never passing. No production substitute or removal obligation is approved. File/hash snapshots precede retained donor material.

| Wave | Visible result and purpose                                     | Core transition / real shell                                                                                                 | First adopted / deferred libraries                                            | Observable scenarios and exit                                                                                                                                                            | Risks / revisit evidence                                                            |
| ---- | -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| 1    | Ordinary binary HTTP, prove independent runtime path           | validate config/request; Opening -> head -> bytes -> end; real Gun socket                                                    | compiler, HTTP, OTP/Erlang, Gun/Cowlib, gleeunit; JSON deferred to4           | binary201, arbitrary methods/non2xx, empty response, duplicate head/trailer, invalid config; fast formatting/check/build/tests/FFI warnings                                              | Gun events/flow semantics may revise body internals, never widen FFI policy         |
| 2    | Scoped and owned streaming on same bounded collection path     | single consumer, shared cursor, timeout != deadline; monitor/credit/cancel                                                   | existing libraries; no new infrastructure                                     | early/exception close, copied handle, competing read, owner death, overflow, stalled read, deadline; fast                                                                                | actual H1/H2 delivery may need finite queue accounting; no eager draining           |
| 3    | Managed concurrent requests and batches, verified TLS/H2       | reuse before create, finite admission, origin scan, H1/H2 leases, per-request deadline; supported Gun settings notifications | OTP supervision API, existing Gun TLS/H2; JSON remains deferred               | shared H2 socket, sibling survival, queue expiry, owner loss, origin fairness, bounded worker count, shutdown/restart; fast and targeted full checks                                     | capacity/GOAWAY races exposed by public Gun API return truthful failures; no replay |
| 4    | Strict offline scripts and disk replay                         | sequence match before advance; validate fixture version/bytes; same body owner                                               | JSON first real codec contract; filesystem read bridge                        | repeated identical requests, mismatch then correct request, missing/corrupt/version/exhausted, concurrent session ordering; fast                                                         | malformed fixture ambiguity must reject, never fall back                            |
| 5    | Real live recording and deterministic finish                   | reserve -> capture acknowledged records -> complete/fail/cancel -> publish; busy/finalized/failed                            | file write/publish bridge; Gleam writer actor                                 | actual roundtrip, early cancellation no drain, HTTP vs capture failure, budget/backpressure, destination refusal/replace, interrupted recording no fixture; fast/full persistence checks | IO stalls must not block HTTP lifetime controls; no claimed fsync durability        |
| 6    | Independently consumable package and accurate practical limits | public-only apps compose; validate scaling and source boundaries                                                             | isolated LLM snapshot as dev-only reference; no production sibling dependency | external app, opacity/body rejection, LLM provider encoding/reduction above HTTP, 1/10/100/1000 and large/mixed streams, runtime matrix; full                                            | report environment-limited cases honestly; no universal memory certification        |

## Explicit deferrals

Streamed uploads, redirects, decompression, proxies/mTLS, cookie/cache adapters, SSE, explicit body/query redaction and crash-durable publication are follow-on scope. The latter two are client features, not dependency limitations. Parser hardening, HPACK/Huffman, dependency allocation certification, provider semantics, credentialed/public-provider tests, publication and sibling changes are excluded. There is no deferral of required managed client behavior.

## Wave history

Entries below are append-only.

### Wave 1 — real binary HTTP

- Status: accepted for its scoped milestone, 2026-09-29.
- Hypothesis: standard HTTP bytes can traverse a real Gun socket with Gleam-owned lifecycle and a narrow bridge.
- Design anchors: DESIGN.md delivery1 and ownership. Opening -> final head -> bytes/trailers -> completion is exercised through public send.
- Delivered: binary 201, arbitrary standard methods, empty204, informational103 followed by final429, duplicate headers and final trailers, invalid startup configuration.
- Real boundaries: local TCP, released Gun/Cowlib, typed Gleam OTP actor/selector/monitor. No production substitute.
- Validation: `nix develop path:. --command sh -c 'gleam format src test dev && sh dev/gate fast'` passed: format, check, build warnings-as-errors, 4 tests, erlc -Werror on handwritten production and test Erlang.
- Findings: selected Gleam check does not accept --warnings-as-errors; build does. Corrected gate rather than claiming the failed command passed. Removed an OTP29 deprecated-catch warning.
- Rejected: old Erlang orchestration and a parallel buffered networking path. send collects the owned body.
- Design changes: none. Distance: streaming lifecycle, managed pooling/batches/H2, cassettes/recording and consumer/load acceptance remain.
- Remaining waves: unchanged2–6. Next action: copied-handle/timeout/close red-green loop.
- Commit: none; local edits retained under existing authorization.

### Wave 2 — owned streaming and shared bounded collection

- Status: accepted for covered H1 lifecycle, 2026-09-29. H2-specific demand remains wave3.
- Hypothesis: one Gleam owner can provide shared consumption and finite collection without an eager forwarding loop.
- Design anchors: DESIGN.md delivery2 and body transitions.
- Delivered: copied-handle cursor, local timeout preserving stream, one owner, conflicting-read refusal, scoped early and exceptional close, owner-death cleanup, terminal overall deadline, bounded collection.
- Red: copied handle's second close returned ClientClosed. Green: close is idempotent; dead read handles return Closed with conservative evidence.
- Validation: exact fast gate from wave1 rerun; format/check/build, 11 public tests, FFI warnings all pass.
- Refactoring: cancel completed read/deadline timers; empty DATA does not accumulate zero-byte queue entries. No second networking path.
- Real boundary: controlled loopback sockets and process monitors. No production substitutes. No material design revision.
- Distance: waves3–6 remain. Next: real negotiated H2 sibling cancellation and supported flow/capacity behavior; bounded batches.

### Wave 3 — managed admission, batches and real H2

- Status: accepted for current scoped contracts, 2026-09-29; practical load/runtime-matrix qualification stays in wave6.
- Design anchors: DESIGN.md delivery3 and pool/batch transitions.
- Delivered: reuse-first H1/H2, TLS ALPN and custom CA, same-socket H2 sibling cancellation/reset, flow/window resumption, peer capacity zero, GOAWAY draining then explicit fresh request, ordered batch results, queue limit, other-origin progress, queued deadline with NotSubmitted, standard supervision child.
- Red: a connecting request counted as a waiter, so another origin was refused while one origin filled its queue. Green: typed connection reservation is distinct from queued work; the controlled fairness regression passes.
- Validation: fast gate rerun on actual tree, 22 public tests pass; formatting/check/build/FFI warnings pass. TLS rejection intentionally emits local unknown-CA notices.
- Core/shell: Gleam admission, reservations, owner monitoring and bounded batch scheduling call unchanged Gun. Body controls remain in Gleam. No temporary runtime or new dependency.
- Findings: selected Gun supports settings-change notifications and enforces peer concurrency. Flow credit counts messages; H2 can deliver frames already within the window, so replenishment accounts for credit debt. GOAWAY is observed through supported connection shutdown; a racing request may fail and is never replayed.
- Design changes: none. Remaining: scripts/disk replay, live recording, public consumers and load/matrix qualification. Next: strict sequence mismatch without consuming the expected exchange.

### Wave 4 — strict scripts and disk playback

- Status: accepted, 2026-09-29.
- Delivered: ordered repeated exchanges, mismatch without consumption, binary JSON v1 codec with explicit lengths/base64, real disk load, strict missing/corrupt/incompatible/exhausted errors, meaningful-header matching and credential-header exclusion, offline protocol identity.
- Real boundaries: selected gleam_json codec and bounded filesystem read. Scripts use the same Gleam body owner, collection, deadline and cleanup implementation as live requests; no synthetic networking runtime.
- Red: rejection before final headers retained an unreachable body owner and blocked the next request. Green: an explicit Rejected phase releases and stops; two failures with a single active slot both return their own failure.
- Validation: full fast gate on actual tree, 26 public tests pass (format/check/build/FFI warnings included). Disk tests use temporary fixtures; no public endpoints.
- Technology: gleam_json3.1.0 adopted at its first codec contract. Minimal bounded file-read primitive because selected gleam_erlang has no filesystem API; no Erlang session logic.
- Scope change/substitution: none. Remaining: actual recording/persistence, public-only and isolated LLM consumers, practical load/matrix and documentation. Next: record a real binary exchange, atomically finish, then replay it with the local server gone.

### Wave 5 — live recording and persistence failures

- Status: accepted for implemented recording contract, 2026-09-29.
- Delivered: actual live binary/status/header/trailer capture, acknowledged incremental writes, ordered concurrent reservations, complete/failed/local-close outcomes, early close without drain, pre-header cancellation without an invented response, Busy/finalized/failed finish, atomic no-replace/explicit replacement, independent capture failure and explicit abort.
- Boundary: Gleam recorder coordinates a single linked IO worker. Only bounded read/write, unique private-directory creation, rename/link publication and removal are Erlang primitives. Body control and deadlines continue while writes are stalled.
- Validation: fast gate rerun on actual tree: 36 public tests pass, format/check/build/FFI warnings pass. Actual EISDIR write fault preserves HTTP bytes but fails capture; an OS FIFO stalls persistence while finish remains responsive and completed HTTP survives its capture deadline; destination refusal is stable; interrupted capture publishes no fixture.
- Core transitions: Active -> Sealing -> Sealed or Broken; requests reserve in client admission order, append observations, then close. Finish refuses while HTTP or writer work is outstanding. Repeated results are deterministic while the recording owner lives.
- Red/green: live roundtrip initially failed for missing recording API; it now persists then replays with the original local response socket closed.
- Redaction: authorization/proxy-authorization/cookie/set-cookie metadata excluded by default. Bodies and URL queries remain exact and may contain secrets; no per-chunk secret replacement or claim of comprehensive redaction.
- No temporary production substitute, material adoption change or dependency patch. Remaining: independent consumer/type rejection, isolated LLM integration, practical load, runtime qualification, final docs/CI and conformance review. Next: run the separate public-only consumer and load scenarios.

### Wave 6 — independent consumers and practical qualification

- Status: accepted and program complete, 2026-09-29 local time. All six required milestones are retained; no production substitute remains.
- Delivered: separate public-only consumer using one function for live/record/playback buffered, scoped and batch calls; opaque Client/Body/Recording and String-body rejection compilations; isolated hash-verified LLM consumer; reproducible example locks; package independence checks; README, limits/provenance/evidence and CI.
- Core/shell: all managed behavior remains in Gleam. Production Erlang is 102 physical lines / 4,782 bytes, sixteen external bindings for Gun/runtime/filesystem operations. No handwritten orchestration server.
- Red/green findings: normalized host-only request targets and rejected invalid method/query/partial-byte bodies before submission; rejected non-byte fixture bodies; required H2 rejects H1 fallback; idle connections yield slots to other origins. A queued-reservation visibility bug initially caused connection churn and was fixed by protecting queued origins throughout admission.
- Scaling finding: the first 1,000-caller run exposed excessive rescanning in admission and failed. Direct new-request admission plus a bounded queue pass removed that work; final 1/10/100/1000 H1 and H2 runs all complete. H2 uses one connection. Both 32 MiB streams and a 1,000-request batch alongside a slow H2 stream complete. No dependency patch or parser-hardening diversion.
- Refactoring: split the pool handler into focused admission/release/process-loss functions; retain pure configuration and codec decisions. Common API-key metadata is excluded; private recording directories use mode0700. Recorded partial failures preserve observed bytes and their terminal error.
- Exact final validation: `./dev/env sh dev/gate fast` passes 47 tests, format/check/build, own FFI warnings and boundaries. `sh dev/matrix` passes full gates on Gleam1.18.1 with OTP29/ERTS17.1, OTP28/ERTS16.4.0.6 and OTP27/ERTS15.2.7.13 on Darwin arm64. Each includes two external consumers, four expected compiler rejections and eleven load scenarios. Logs, source receipt and measurements: docs/evidence; analysis and inherited warnings: docs/VALIDATION.md.
- References: reviewed previous test infrastructure and isolated consumer attribution retained; no upstream suite parity claimed. Archives rehashed; sibling HEAD/status unchanged. No pushes, publication, credentials or upstream messages.
- Remaining distance to required client: none identified by accepted scenarios and final review. Explicit follow-ons remain uploads, redirects/decompression, proxies/mTLS, cookies/cache and optional SSE. Inherited parsing behavior, GOAWAY races, query/body secrets, temporary interrupted files and absent fsync durability are documented limitations, not claimed guarantees.
- Commit: none requested; working changes retained locally with the previous implementation recoverable in .archive.

### Wave 7 — filesystem reuse and client-owned improvements

- Status: active; explicitly authorized by the owner's follow-up to retain Gun, reuse suitable filesystem libraries and correct responsibility wording. No further approval is required for this scoped change.
- Design anchors: DESIGN.md ownership/recording/FFI contracts; existing atomic publication, bounded reads, exclusive spool creation and independent capture errors remain unchanged.
- Delivery: replace ordinary handwritten file operations with released libraries; preserve bounded raw reads, exclusive writes, close/error handling, permissions and atomic link/rename publication. Align Gun's supported header count with the configured application count. Clarify inherited behavior versus optional client features.
- Research: simplifile 2.7.0 supports link/rename/permissions/file removal, but its create_file is check-then-write and delete recursively removes directories. Use neither for exclusive creation or empty-only removal. file_streams 1.7.0 supplies Raw/Read/Write/Append/Exclusive and bounded byte reads, compatible with stdlib0.71; file_streams2.0 and fio1.2.1 require stdlib1, so defer that unrelated migration. Exact package hashes and source review will be retained.
- Sequence: existing cassette regression baseline; refactor filesystem boundary while green; red/green configured header-count regression on real H1 and H2; documentation and final full gate/runtime checks.
- Gate: ./dev/env sh dev/gate fast; ./dev/env sh dev/gate full; sh dev/matrix for the changed dependency seam. Public-only consumers and recording fault tests must remain green.
- Scope: no dependency patches, protocol/parser changes, redaction implementation or durability implementation. Body/query transformation and durable publication are optional HTTP Gun features, not upstream defects. Gun remains the transport.

### Wave 7 — acceptance

- Status: accepted, 2026-09-29 America/Sao_Paulo. No open material decision or production substitute.
- Baseline: existing tests plus exact bounded-file regression passed 48 before and after filesystem substitution. H1 and H2 public tests then separately failed with RequestFailed for valid configured counts above Gun's default; both turned green after using its supported max_headers option, with one H2 allowance for :status.
- Delivered: file_streams 1.7.0 bounded raw binary IO/exclusive creation and simplifile 2.7.0 permissions/link/rename/removal, exact dependency and consumer locks, normal close-error propagation. Remaining filesystem bridge: unique candidate path and empty-directory removal. Review inventory and package hashes are in docs/filesystem-review.json; installed adopted sources match their releases.
- Conformance: existing binary fixtures, ordering, strict replay, writer backpressure, capture failure independence, atomic replacement policy and lifecycle behavior are preserved. No public API or fixture version changed. Handwritten production FFI is 72 lines/3,650 bytes in 12 bindings, down from 102 lines/4,782 bytes. No dependency patch, protocol parser or Erlang orchestration added.
- Validation: direct fast gate passed 50 tests plus format/check/build/FFI warnings/boundaries. sh dev/matrix passed full isolated OTP29/28/27 gates, each with 50 tests, two consumer packages, four expected type rejections and 11 load scenarios. Source hashes, red/green logs, exact full receipts and measurements are in docs/evidence/wave7; docs/VALIDATION.md explains the evidence.
- Documentation: README, BOUNDS, DESIGN, local instructions and filesystem decision now distinguish inherited allocations and GOAWAY races from optional client-owned body/query redaction and durable publication. Neither optional feature is implemented or represented as an upstream defect. No source rendering gate is configured for these Markdown documents; local links and changed source were checked.
- Acceptance: approved behavior, dependency boundary, preserved interface, public regression scenarios, repository rules and executable gates all pass. Original six-wave history remains above unchanged. No tracker issue or design pending entry requires closure. Changes remain local and uncommitted; siblings/oversight were not modified.

### Wave 8 — requested Dream comparison

- Status: active; explicitly authorized by the owner's request to benchmark and test against lostbean/dream branch codex/http-client-combined.
- Target: exact commit bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5, downloaded into ignored build/dream-comparison. Archive/source hashes recorded before use; upstream production source remains unmodified. Existing sibling checkouts stay read-only.
- Scope: run the upstream HTTP client suite, compare public contracts on controlled local servers, benchmark common H1 buffered/pull-streaming workloads with disclosed connection/session settings and fresh processes. The settings were found to have different semantics; a four-worker case matches application admission. Report H2 as a separate capability, not an H1/H2 speed contest. No transport switch or dependency patch.
- Method: pinned Gleam/OTP toolchain, common dependency lock for comparative harness where compatible, equal request counts/payloads/time budgets, warmup and repeated trials, actual connection observations, latency and sampled VM/mailbox memory. Include slow consumption and early termination. Document APIs that cannot express a contract rather than silently adapting away differences.
- Acceptance: retained reproduction command, exact revisions/configuration/results, upstream failures distinguished from comparative findings, all HTTP Gun fast checks still passing. No performance or parity claim beyond measured cases.

### Wave 8 — acceptance

- Status: accepted for the requested comparison, 2026-09-29. No production behavior or dependency change.
- Delivered: hash-pinned isolated Dream archive, separate public-import consumer, executable behavior checks, repeated warmed H1 workloads, exact environment/source receipts, raw measurements, summaries and docs/DREAM_COMPARISON.md. Reproduction: ./dev/env python3 dev/comparison/run.py all.
- Validation: HTTP Gun fast gate passes 50 tests, formatting/check/build/FFI warnings/boundaries. Dream's original check/test fail on stale local lock versions; reconciling only those two entries gives 213 passing tests. Original format failures are disclosed and source is untouched. Comparison build passes with warnings as errors; its new Erlang helper passes erlc -Werror. Fifteen HTTP Gun and sixteen Dream public contract cases check the recorded outcomes. All 54 timed runs return correct byte counts with no request failures on Gleam1.18.1/OTP29/ERTS17.1, Darwin arm64.
- Findings: binary buffered responses, stream status/ownership and ordered cassette replay differ. Dream explicit callback cancellation works; its basic pull yielder lacks the observed scoped/owner-exit closure. A small-first-chunk pilot failed before cleanup and is retained without assigning a root cause. Final cleanup cases use a 16 KiB first chunk and observe closure for two seconds.
- Performance: median 1,000-request/four-worker elapsed time is 35.42ms Gun versus 59.46ms Dream; 32MiB pull streams are 201.20/205.13ms. A 1,000-caller burst is 705.99/66.97ms, with Dream's range 43.86–1084.23ms. HTTP Gun's client admission/scheduling warrants profiling; no cause or fix is claimed. Dream max_sessions is a persistent-session limit, not the same open-connection cap, and actual connection counts are reported.
- Boundaries: three local trials per case, whole-VM sampled resources, H1 only for timing; no statistical/SLA, hostile-input memory or H2 speed claim. Earlier full OTP27/28/29 qualification remains separate evidence, unchanged production hashes were verified. Handwritten production FFI stays 72 lines/3,650 bytes in 12 bindings. No source donor, upstream patch, sibling modification, push or publication.

### Wave 9 — remove quadratic burst admission work

- Status: active, authorized by the owner's “Fix it” on 2026-09-30 after the burst diagnosis. This is an in-place correction within DESIGN.md's bounded origin-aware pool contract, not a public behavior or dependency change.
- Delivery: cache normalized destinations, keep FIFO waiting work by origin with indexed expiry/owner removal and cached counts, stop reconsidering a blocked origin, and preserve one globally ordered playback queue. Pool actor owns every queue/index/count transition. Connection leases, body ownership, capture reservation order and supported Gun behavior remain unchanged.
- Sequence: fail an observable public burst-work scaling regression; implement the queue and scheduling correction; add focused contention/expiry/owner-death/ordered-playback checks as needed; refactor while green; run full gates and repeated comparison workloads.
- Acceptance: doubling a warmed same-origin workload does not quadruple work; 1,000 callers complete with finite connections/queues and substantially reduced median time; other origins, deadlines, H1/H2 capacity, owner cleanup, replay order and recording remain correct. No temporary benchmark special case survives.
- Gates: ./dev/env sh dev/gate fast; ./dev/env sh dev/gate full; sh dev/matrix; pinned comparison's public contracts and repeated burst/bounded/stream workloads. Record exact evidence under docs/evidence/wave9, preserving original comparison/diagnosis results.
- Libraries: existing gleam_stdlib Dict supports typed indexes; no queue API exists in the selected stdlib/erlang package sources. Use a small internal queue with explicit indexed links, no added dependency or FFI. Previous source/tests preserved in .archive/before-pool-fix-20260930.tar.gz before editing.

### Wave 9 — acceptance

- Status: accepted, 2026-09-30. Governing anchors: DESIGN.md ownership/admission and delivery3/6. The owner's “Fix it” authorizes this intent-preserving performance correction; no material adoption, public contract revision or unresolved design decision.
- Delivered: cached normalized origins; per-origin FIFO heads with indexed caller/expiry removal and cached waiting counts; progressing-origin rotation; indexed body ownership; one ordered playback queue. Body cleanup callbacks carry only their destination identifiers, avoiding copies of the whole pool state. Only pool.gleam and new pending.gleam change production code. No special-case benchmark path, second runtime or temporary production substitute remains.
- Red/green: the original pool failed the public 500/1,000-caller VM-work scaling regression. A controlled two-ready-origin scenario failed with rotation omitted. Seven added public scenarios cover these checks, head/middle/tail caller loss and restored FIFO/capacity, a fast origin alongside 500 blocked callers, queued deadlines, cross-origin replay ordering and same-connection H2 queue resumption after cancellation. Existing lifecycle, batch, recording and persistence-fault scenarios remain green. Test-development failures caused by using normal exit to kill an unlinked caller and by not making both fairness-test connections eligible were corrected in the test setup and retained in evidence; they are not reported as production defects.
- Validation: final direct fast gate passes 57 tests plus format/check/build/FFI warnings/boundaries. Final sh dev/matrix passes full OTP29/28/27, each with 57 tests, both consumers, four expected type rejections and 11 load scenarios. Frozen executable inputs match the final tree. The separate comparison checks all 15 HTTP Gun and 16 Dream contract observations. HTTP Gun completes 27/27 repeated workloads with exact bytes and zero failures; Dream completes 26/27, with one burst reporting 48 connection timeouts. The overall comparison exit is 1 and that failure is explicitly retained. No upstream fix or native-suite rerun is claimed.
- Performance: final 1,000-caller/four-connection median 45.333ms (45.247–60.599) versus original705.991ms; 15.6× faster. Separate narrow profiles reduce admission checks993,648→2,997 and origin calculations1,987,296→1,002. Four-worker median35.813ms and32MiB201.873ms remain similar to original35.420/201.200. Mixed fast-request p95 drops691.767→45.283ms while the slow stream still determines total elapsed. Burst sampled whole-VM memory is66.49MiB versus64.08; no memory reduction claim. The queue-only intermediate174.907ms and callback-capture finding are preserved separately.
- Boundaries: only three repeated local H1 trials; connection policies differ; one-run H2 load data is separate. Scheduling still scans waiting origins and configured connections, and external calls may queue before admission. No SLA, universal constant-work guarantee or dependency allocation certification. Linux CI not executed locally. Existing optional redaction/durability and other follow-ons remain unchanged.
- Acceptance rubric: requested behavior, governing ownership rules, unchanged interface, public behavioral scenarios, covered criteria, approved scope, named general conditions, design documentation, standing rules and focused quality review all pass. No issue or pending design entry needs closure. Production FFI remains72 physical lines/3,650bytes/12bindings; dependencies/manifests unchanged. Source snapshot and receipt hashes are retained; original wave8 results remain intact.
- Evidence: docs/BURST_FIX.md and docs/evidence/wave9. Remaining required implementation distance: none identified by these accepted scenarios. No further authorized wave remains. Changes stay local and uncommitted; no sibling/oversight edits, push, publication, upstream contact or provider credentials.

### Authorized adoption-validation follow-up — plan revision 5

The owner's request to focus on the remaining review items and external reference validation authorizes these intent-preserving waves. The public contract, Gun transport and dependency boundary remain unchanged. No further approval is needed for these scoped tests and fixes. No temporary production substitute is introduced.

| Wave | Outcome / contract                                                                                                                                       | Real boundary and technology                                                                                                   | Observable exit / gate                                                                                                                    |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| 10   | Bounded batches avoid copying scheduler history into workers; asynchronous callbacks carry only needed values                                            | Existing Gleam actors, same public batch and pool; no dependency or FFI additions                                              | Reproduce reviewed 500/2000/5000 scaling defect, fix narrow captures, retain regression; fast gate and repeated public batch measurements |
| 11   | Isolated public-import LLM consumer handles incremental bytes and early termination; reference-derived lifecycle scenarios strengthen streaming evidence | Existing public LLM Wire reducers in retained isolated snapshot; framing stays in example, local controlled HTTP servers       | Progress before EOF, split events/UTF-8, local cancellation, live/record/replay, bounded framing; fast and independent consumer gates     |
| 12   | Independent server compatibility and practical qualification                                                                                             | nghttp2's nghttpd as dev-only server pinned by existing Nix lock, verified TLS/ALPN; controlled servers retain fault injection | Binary H2 responses, multiplexing, sibling cancellation, repeated workloads; full gate and OTP27/28/29 matrix, exact receipts             |

Design anchors: DESIGN.md ownership, batch scheduling, incremental recording and delivery slices 2/3/5/6. References are scenario donors only: Finch timeout/cancellation, Gun flow/trailers/reuse, Mint fragmentation, ReqCassette binary/ordered matching; exact revisions and hashes are in evidence/adoption-review/reference-sources.json. Do not copy dependency parser tests. Independent nghttpd tests client interoperability, not protocol certification. Linux evidence will be reported only if executed; sibling LLM runtime migration remains outside this checkout's authority. Body/query redaction and crash durability remain optional features.

### Wave 10 — acceptance

- Status: accepted for the measured batch defect, 2026-09-30; wave11 now active.
- Red: retained public benchmark fails its generous tenfold-growth guard (500 inputs36.771ms,5000 inputs2377.275ms median across three fresh VMs). VM reduction counts alone missed the copying cost.
- Green: extracting the operation and destination before spawning avoids worker copies of pending inputs/results. Body capture acknowledgements and recorder dispatch use the same narrow-capture rule; final publication carries only publication inputs. No public API, dependency or FFI changes.
- Validation: fast gate passes57 tests, format/check/build, FFI warnings and boundaries. Three fresh-VM public batch trials pass including10000 inputs; medians500=19.812ms,1000=36.374ms,2000=67.674ms,5000=166.490ms,10000=327.580ms. Full gate now retains this regression. Exact red/green output and raw trials are in docs/evidence/wave10.
- Evidence boundary: elapsed-time guard allows scheduling noise; no absolute latency or universal complexity claim. Existing lifecycle and persistence failures remain green. Broader consumer/server qualification remains waves11–12. No temporary runtime or dependency patch.

### Wave 11 — acceptance

- Status: accepted, 2026-09-30; wave12 now active. Public HTTP Gun API unchanged; no new production FFI.
- Red/green: original buffered LLM consumer failed to return within the synchronized test window after provider completion without HTTP EOF. Scoped incremental consumption now returns and closes that live stream. A progress callback can stop early; partial-disconnect failures retain observed-byte and semantic-progress evidence. SSE framing remains in the example, retained from the reviewed LLM Wire source with exact hashes and Apache license, never imported from sibling internals.
- Consumer evidence: all1196 byte split points of OpenAI/Anthropic/Google text fixtures, including UTF-8/CRLF; live progress before EOF; local cancellation; live recording followed by offline playback of the same consumer; bounded body/line errors; status/Retry-After; compression refusal; idle expiry and partial disconnect. The sibling session runtime and tool/continuation orchestration are not migrated or claimed as tested through this example.
- Reference coverage:25 H1 responses with25 flow-controlled chunks and duplicate trailers on one reused socket; normal owner exit; batch owner death and restored admission; active H2 sibling finishing during GOAWAY;65 ordered binary cassette responses with all256 byte values and non-consuming mismatches. Exact sources recorded in adoption-review and wave11 donor receipts; scenarios re-expressed, no external protocol suite copied.
- Findings: initial draining test submitted fresh work before Gun's connection-down observation and received truthful ConnectionFailed/MayHaveBeenSent. The corrected test synchronizes on that supported observation; no automatic replay or stronger atomic guarantee was introduced. This test-setup correction is retained in draining-race.log.
- Validation: fast gate passes62 tests, format/check/build/FFI warnings/boundaries; both separately built consumers and four negative type fixtures pass. Exact final.log and streaming.log are retained in docs/evidence/wave11. No temporary runtime, dependency patch or sibling mutation. Remaining distance: independent server/full runtime qualification and measured sustained load.

### Wave 12 — acceptance

- Status: accepted, 2026-09-30. No pending required implementation or temporary production substitute in this authorized follow-up. Remaining sibling migration and optional features are distinguished from HTTP capabilities.
- Adopted: released nghttpd1.70.0 as test-only infrastructure pinned by existing flake.lock, alongside controlled Cowlib servers for synchronized faults. Official server options verified locally. Nix/Hex toolchain and production Gun/Cowlib versions remain unchanged.
- Delivered: independent verified TLS/H2, binary PUT/download, HEAD/404/trailers,1/10/100/1000 callers, stalled-large-stream plus bounded batch, two cancellations and a32MiB surviving sibling. Full server-event observation verifies one connection and two resets; diagnostics retain a bounded prefix. Added256 concurrent recorded/replayed binary exchanges (8MiB), public batch regression through10000 inputs, and repeatable evidence export.
- Sustained check:60 seconds,317900 requests, one connection, no failures; final bodies/waiters zero. Whole-VM sampled peak64066243 bytes, largest mailbox12. This is practical evidence, not an SLA or whole-stack memory/leak certification.
- Validation: six full local gates pass on ARM64 Darwin/Linux × OTP29/28/27. Every run passes62 tests, formatting/check/build, FFI warnings/boundaries, two public consumers, four type rejections,1196 LLM split points, batch regression, independent server scenarios, recording/replay pressure and all eleven original load cases. Final Darwin wrapper exits0 with frozen executable inputs. Linux snapshot differs only in later README prose and the post-gate copy helper; no client, consumer or executable gate changes. Exact hashes/outcomes and raw logs are in wave12 evidence.
- Tooling findings retained: macOS metadata sidecars broke initial Linux compilation; export now omits them. Editing the first host matrix wrapper while it ran caused a trailing-command exit127 after all checks passed; frozen final rerun succeeds. These are our tooling corrections, not dependency failures.
- Conformance/acceptance: approved outcomes, owning-process guarantees, pure typed decisions, narrow FFI, scoped source reuse/licensing, observable tests, independent public imports, documentation and workspace rules all verified. No library patch, generic framework, untranslated Erlang orchestration, provider credential, sibling write, publication or push. FFI remains72 lines/3650 bytes/12 bindings. Changes are retained locally.
- Remaining boundary: full LLM Wire session migration must preserve tools/continuations, remaining budgets and complete retry evidence; the example is text-oriented. GitHub-hosted x86_64 CI was not run. Body/query redaction, crash durability and previously listed follow-on HTTP features remain optional. No extra protocol certification or upstream repair is required by these findings.

### Authorized API ergonomics — plan revision 6

Approval: owner accepted the four concrete proposals with “apply them” on 2026-09-30. Design anchors E1–E4 in DESIGN.md. Baseline 1f53017 is clean and recoverable in Git. No additional approval cycle, dependencies, upstream patches, sibling edits or provider traffic. Existing Gleam actors/selectors/monitors/timers and filesystem libraries are retained; no temporary runtime. Design documentation stays in this package's existing Markdown format.

| Wave | Observable delivery and transition                                                                            | Public red/green checks and exit                                                                                                      |
| ---- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| 13   | E1 bounded finish: Active -> Closing -> Publishing -> Finalized/Failed; finite removable waiter               | Timeout seals without draining, cancellation then publication/replay, concurrent/dead waiter, abort; fast gate and ordinary consumer  |
| 14   | E2 fallible scoped callback with caller errors and identical cleanup                                          | Opening/read/application error mapping, success/early/exception cleanup; fast and public consumers                                    |
| 15   | E3 monotonic deadline and scoped latched cancellation through existing admission/body ownership               | Expired/queued/pre-header/reading requests, scope and creator death, H2 healthy sibling, no replay/history growth; fast and consumers |
| 16   | E4 typed limits, bounded transport/file diagnostics, codec compatibility, public docs and final qualification | Real TLS/refusal/IO errors, every error roundtrip, strict v1/v2 decode, safe descriptions; full gate and OTP29/28/27 matrix           |

Decisions: client deadline remains the ceiling; finish timeout does not abort; cancellation applies to every request deliberately attached to one token; only one recorder completion waiter, rejected extra waits return Busy. Scope exit releases token state. Unexpected raw dependency reasons map to Unknown; no arbitrary term inspection in public errors. These are scoped implementation decisions consistent with the approved proposal. No protocol hardening, full sibling LLM migration, optional redaction or crash durability in this wave.

Initial plan state: wave13 active; waves14–16 pending. Acceptance requires unchanged ordinary workflows plus all four improvements, retained exact failing/passing evidence and no unresolved gate failures. No completion claimed yet.

### Wave 13 — acceptance

E1 delivered: finish_wait seals new reservations, holds one monitored/timed waiter, continues finalization after wait timeout and never reads HTTP bodies. Dead/timed-out waiters are removed; abort remains capture-only. Real cancellation-prefix replay passes; ordinary consumer no longer polls. Fast gate passes64 tests and two consumers/four rejections pass. Exact logs in evidence/wave13 include missing-API red, unused-result gate correction and a contention-test registration race corrected without sleeps. Production FFI/dependencies unchanged. E2–E4 remain pending; wave14 active.

### Wave 14 — acceptance

E2 delivered: try_with_response preserves caller errors, maps opening failures, flattens the result and reuses exception-safe with_response. Public tests cover application/read/open errors, success, early exit and exception cleanup. LLM public consumer uses the helper without trailing flatten. Fast67 tests and both consumers/four rejection fixtures pass (wave14/final-green.log); missing API and a test-only private-return-type correction retained. No FFI/dependency change. Wave15 now active; request controls and E4 remain unbuilt.

### Wave 15 — acceptance

E3 delivered: opaque monotonic deadline with remaining_ms; request options for send/open/arbitrary and fallible scopes; scoped latched token through a small Gleam actor. Pending cancellation monitors have a bounded live-entry index; body owners observe token termination and remove monitors on release. No per-request worker, body forwarding, callback history or new FFI. Cancel while connecting removes unused reservations; queued peers preserve useful connections. Red/green tests cover expired admission, pre-header and queued cancellation, stalled TLS reservation cleanup. Scope/creator death, client ceiling, body deadlines and H2 sibling/reuse pass. Fast76 tests; both external consumers and six type rejections pass in wave15 logs. Options are exercised through live/record/playback. Implementation keeps existing default APIs and same pool. Wave16 active; typed diagnostics, fixture revision and final qualification remain required.

### Wave 16 — acceptance

- Status: accepted,2026-09-30. All four approved API improvements E1–E4 are implemented; no required item remains in this follow-up. Default client calls remain; richer error constructors require the documented pattern-match migration. New fixture output is version2; valid version1 is explicitly decoded without corrupt-fixture fallback.
- Delivered: typed byte/count limits with optional observed size; supported transport categories including real refusal/certificate rejection; operation/cause filesystem failures; safe descriptions excluding free-form data; compiled public documentation and examples. Legacy ambiguous sizes/categories use None/OtherLimit rather than invented precision. Cancellation roundtrips preserve observed prefixes and typed outcomes; completed HTTP survives later cancellation.
- Red/green: missing typed constructors and safe formatter tests fail before implementation. A final controlled public test exposed retention of a connecting socket after both the reserving caller and its queued peer cancelled. Pool cleanup now closes unused connecting sockets after every relevant pending removal while preserving useful shared connections. Retained red/green logs show84 passed/1 failed then85 passed. No dependency patch or separate networking path.
- Validation: direct fast85 tests, both separate consumers/six compiler rejection fixtures,1196 LLM split points and generated docs pass. Six isolated full gates pass on ARM64 Darwin/Linux × OTP29/28/27 against the same frozen executable inputs. Each repeats85 tests, format/check/build/FFI warnings/boundaries, two consumers, six rejections, batch trials through10000, seven nghttpd scenarios with one connection/two stream resets,256 recorded/replayed exchanges/8MiB and eleven original load scenarios. See evidence/wave16/receipt.json and per-runtime logs/measurements. Earlier failed test/tooling attempts remain in the wave evidence.
- Boundaries: no new Dream rerun or60-second soak claimed; those are historical receipts. Host/container timing runs overlap and are qualification observations, not comparative performance claims. Remote x86_64 CI was not run. The isolated LLM example is text-oriented; sibling session-runtime migration is separate. Body/query redaction and crash durability remain optional client features.
- Review: actor-owned lifetimes and finite admitted subscriptions/waiters, conservative submission evidence, public-only examples, explicit fixture compatibility and unmodified dependency boundaries preserved. Handwritten FFI now92 physical lines/4669 bytes/13 declarations, adding only bounded transport-reason conversion. Gun/runtime bindings and the8-line filesystem primitive bridge remain narrow. No generic framework, raw public transport terms, production substitute, donor copy or sibling write. Changes are local and uncommitted; no push or publication.

### Authorized pre-release cleanup — wave 17 / plan revision 7

The owner confirms no released package/external consumer and explicitly permits breaking cleanup. E4 now has one strict fixture schema (marker1), mandatory observed limit sizes and no legacy decoder/OtherLimit. Invalid negative fixture budgets fail before IO; genuine unknown transport/IO causes remain. No package version bump or dependency/FFI change. Public red/green: old experimental failure layout is corrupt, current typed failures roundtrip, unknown versions/tags fail, negative budgets are configuration errors. Keep recording/live/playback consumers on this schema. Gates: ./dev/env sh dev/gate fast; ./dev/env sh dev/gate full; runtime matrix if needed for final qualification. Status: active; prior wave16 evidence remains historical.

### Wave 17 — acceptance

- Status: accepted,2026-09-30. The owner's explicit pre-release direction supersedes E4's earlier compatibility decision; no external migration, new package release or further approval is needed. Existing functional capabilities and genuine unknown runtime causes remain.
- Delivered: one strict fixture schema marked1; version-independent nested decoders; no legacy mapper or OtherLimit; required observed Int in LimitExceeded. Negative file/parse budgets return InvalidConfig before IO/decode. Public docs and local instructions distinguish error pattern syntax, current owned examples and future consumers.
- Red/green: obsolete failure layout accepted then rejected; negative budget classified as LimitExceeded then InvalidConfig; null observed size accepted then rejected. Typed error roundtrips and strict missing/unknown-marker/tag cases pass. An initial unused import warning was removed. A test-only fixed-count Busy polling loop exhausted before disk completion; the evidenced helper was removed and tests use bounded finish_wait. Both correction logs are retained rather than reported as dependency defects.
- Validation: fast86 tests, format/check/build, own FFI warnings/boundaries, and generated API docs pass. Six full gates on ARM64 Darwin/Linux × OTP29/28/27 pass against frozen current inputs; each includes86 tests, two isolated public consumers, six type rejections,1196 LLM split points, three batch trials through10000 inputs, seven independent nghttpd scenarios,256 recording/replay exchanges totaling8MiB and eleven controlled load scenarios. Exact receipt and logs: evidence/wave17.
- Scope/quality: no production substitute, generic framework, dependency/parser patch or wider architecture change. Current typed data matches the design; old experimental artifacts need regeneration rather than compatibility branches. Package/toolchain/FFI unchanged (92 lines/4669 bytes/13 bindings). No sibling/oversight mutation, push, publication, credentials or commit. No pending work in this cleanup. Historical wave16 receipts remain accurate for their captured tree. Remote x86_64 CI, another Dream comparison/soak, optional redaction/durability and full sibling LLM migration are not claimed.

### Local integration after wave 17

The owner requested committing the accepted API improvements and pre-release cleanup. They form one coherent local commit with source, examples, documentation and red/green/full-gate evidence. Before staging, all78 frozen executable/fixture inputs and all six current runtime receipt hashes were reverified; no source change invalidates the86-test qualification. Historical entries above retain their original status. No push, publication, sibling or oversight change is included.

### Authorized adoption ergonomics — plan revision 8

The owner's “Proceed” accepts the completed API/adoption proposal reviewed against HTTP Gun ebf2b479 and migrated LLM Wire 1c0ad614. This is implementation authorization for the small additions, documentation and independent validation below; observation remains an isolated experiment, not an approved public API. Prior receipts remain historical. No commit, sibling mutation, new dependency or production FFI is needed. Design anchors A1–A4 below refine existing ownership rules.

| Wave | Retained outcome                                                     | Observable exit                                                                                                                                                               |
| ---- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 18   | Accurate adoption status and explicit isolated downstream gate       | Current LLM Wire tests/public boundary/local H2 run against selected HTTP Gun; recorded revisions/hashes; originals unchanged; incompatible API fails                         |
| 19   | Maintained generic asynchronous feed recipe using public imports     | Synchronized admission/connect/header/body cancellation, ownership, exceptions/death/shutdown, modes and healthy H2 sibling; normal gate has no sibling dependency            |
| 20   | Immutable request-ceiling inspection and fallible cancellation scope | Public red/green tests; stopped/restarted client policy, all modes, success/callback error/exception/group cancellation; finite deadlines unchanged                           |
| 21   | Bounded lifecycle-observation experiment and qualification           | Compare bounded pull ring and per-request slots in temporary code; expose no new production API; publish ordering/loss/ingress findings; full local gate and runtime evidence |

Current state: wave18 active,19–21 pending. The existing approved proposal is retained by SHA256 in wave18/proposal-source.json. No unbuilt item above is called a limitation or complete. The migration establishes a real current consumer; the archived text example remains historical scenario evidence. Application framing, sink blocking/idle policies and retry decisions stay outside HTTP Gun. Observation cannot establish remote receipt and must not affect correctness or persistence outcomes.

### Wave 18 — acceptance

Accepted: opt-in current downstream driver, source closure isolation, revision/hash/runtime receipts, and current adoption wording. Missing-command red is retained; initial rejection of an in-checkout CLAUDE.md symlink was corrected to dereference only within its source root. Current LLM Wire passes223 tests, check/build, actual public consumer/six negative controls and five local H2 scenarios on Darwin ARM64/OTP29. Sources were unchanged. Removing the public with_response_with_options export only in a disposable HTTP Gun copy produces the expected downstream Unknown module value error. See evidence/wave18. No production dependency/FFI or sibling change. Wave19 active.

### Wave 19 — acceptance

Accepted: the reviewed temporary generic feed recipe is retained as examples/async with provenance hashes, a two-job offline demo, and11 synchronized lifecycle groups. The independent package builds with warnings as errors and all groups pass on OTP29 (evidence/wave19/green.log). It covers cancellation during admission/TLS/header/body, shared cursor/conflicts, early/error/exception/death/shutdown, supervision restart, one-connection H2 sibling survival, live/scripts/strict playback/actual prefix recording and separate capture failure. Missing executable red is retained. Token startup failures now propagate through the application's startup channel rather than being reduced to WorkerStopped. No new library task abstraction, FFI, dependency or sibling change. Wave20 active.

### Wave 20 — acceptance

Accepted: request_ceiling_ms reads only the capability's immutable startup scalar; try_with_token delegates to the existing exception-safe scope, maps startup Failure and flattens the callback Result. Defaults, deadline enforcement, actors and FFI are unchanged. The public missing-function red becomes88 passing tests, then91 with grouped/error/exception cleanup coverage. The async package checks policy across all four modes and stopped/restarted capabilities, and uses the helper in download and grouped REST workflows. Fast, all three consumers, positive compiler control/six symbol-specific rejections and API docs pass (evidence/wave20/qualification.log). Controlled token actor-startup failure injection was not attempted: mapping is a direct Result.map_error on the existing constructor; no unsafe resource-exhaustion or production test seam was added. This execution boundary is disclosed rather than claiming that fault was observed. Wave21 now active: experiment and final complete-tree qualification.

Wave21 review correction: controlled token-startup failure is now exercised through a temporary-copy OTP boundary substitution, without a production seam. It exposed an example-only stray completion message when startup failed before a Job could be returned. The public test fails its mailbox assertion, then passes after the worker separates startup failure from callback completion. Sixty-four failures retain no messages, exact Failure mapping is checked and the callback cannot run. The ordinary with_token form is intentional for this two-channel application protocol; download/grouped REST use try_with_token. Logs: wave21/startup-red.log and startup-green.log. The initial three runtime gates and downstream rerun passed before this example/gate correction; final matrix is being repeated against fresh frozen inputs. Production source remains unchanged from those earlier runs.

### Wave 21 — acceptance

Accepted,2026-09-30. The approved follow-up is complete: two small API additions, maintained generic asynchronous recipe, isolated current downstream gate, accurate adoption wording and an observation experiment. No production observation API was authorized or added. There is no temporary runtime or required implementation left in these waves.

Final qualification: three full Darwin ARM64 gates on OTP29/28/27 pass91 tests, all three public consumers, six precise type rejections,1196 archived splits,11 async lifecycle groups and controlled startup-error check, batch scaling, seven nghttpd scenarios,256 record/replay exchanges/8MiB and all eleven load scenarios. Ninety executable/dependency inputs stayed frozen. Current LLM Wire passes223 tests, its public boundary and local H2 scenarios; final production source matches its receipt. Sinal Git metadata advanced after that run but its complete selected source/manifest set stayed identical. No sibling was modified. Receipt: evidence/wave21/receipt.json.

Experiment: a64-event ring accumulates60000 incoming messages with10000 synthetic requests and a paused receiver. A64-slot bounded CAS store retains64 rows/24512 ETS bytes with no observation mailbox;64 synchronized writers produce one commit/63 losses. Stale generations, duplicate terminal, reordered arrival, simulated network marks and dead/throwing observers are checked. This is storage evidence only; real milestone integration, timing overhead, loss/cursor semantics and library/bridge selection remain future design. No callback/telemetry framework, ETS production dependency or Gun hook was introduced.

Review: typed public values and actor-owned HTTP lifecycle remain unchanged; the accessor is pure policy and the scope helper uses existing cleanup. The example's startup-result leak was reproduced and fixed with a retained boundary-fault regression. FFI remains92 lines/4669 bytes/13 declarations; dependencies/fixture schema unchanged. Linux/hosted CI, new Dream comparison and sustained soak were not rerun. Optional redaction/durability remain outside scope. No commit, push, publication, credentials, upstream contact or sibling/oversight write occurred.

### Authorized Sinal adoption — plan revision 9

The owner's “Agree, proceed to sinal and simplify our system” selects Sinal for observation delivery. The target is the small instrumentation boundary in DESIGN.md, with no HTTP Gun observation actor, retained timeline or custom ingress implementation. HTTP outcomes and persistence remain independent of best-effort observations. Prior public HTTP behavior stays accepted. No commit, push, publication or provider traffic is authorized.

| Wave | Retained outcome                                            | Observable exit                                                                                                                                                                                                                 |
| ---- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 22   | Verified Sinal ingress and a reviewed dependency correction | Synchronized startup and delayed-sender tests reproduce the original failures and pass the corrected source; Sinal tests/build/FFI warnings pass on selected runtimes; correction applied only within authorized checkout scope |
| 23   | Sinal dependency and typed HTTP lifecycle instrumentation   | Normal gate independent of sibling checkouts; direct forwarding/default disabled; bounded payloads and correlation; live/recorded and simulated events truthful; blocked/dead/throwing observers cannot change HTTP outcomes    |
| 24   | Adoption qualification and simplified docs/examples         | Public consumer, current isolated LLM Wire, all modes, cancellation/H2 siblings and fast/full gates; exact receipts and accurate remaining limits                                                                               |

Wave22 is active. Sinal098a2d5 is unpublished on Hex (package API returned404). Its startup reset permits two events at capacity1; a producer paused before send can also enqueue an old reservation into a replacement process. Both are reproduced with synchronized temporary-copy hooks, never production test seams. The prepared correction publishes fresh admission counters together with a direct subject for each incarnation using a one-row actor-owned ETS table. The public Sinal API is unchanged. Diagnostic counters are explicitly best effort and do not enforce capacity. No Gun/Cowlib patch or HTTP Gun workaround is involved.

The earlier instruction keeps siblings read-only. A specific clarification is pending before applying the tested correction to `/code/gleam-dream/sinal`; no sibling has been modified. The patch, regression runner and source hashes are retained in evidence/wave22. Production integration and end-to-end HTTP validation remain unfinished, not passing limitations. Packaging the unpublished source reproducibly remains part of wave23; a mutable sibling-only dependency is not an acceptable normal gate.

Wave22 preparation result: both original regressions fail for their intended assertions, the candidate passes both, and93 Sinal tests plus format/check/build/FFI warnings pass on Darwin ARM64/Gleam1.18.1 with OTP29/ERTS17.1, OTP28/16.4.0.6 and OTP27/15.2.7.13. `git apply --check` passes for the retained patch. The original Sinal source hashes/status are unchanged. See evidence/wave22/receipt.json. Application and HTTP integration are still pending; no acceptance of wave22 or later waves is claimed.

### Wave 22 — acceptance and related regression

The owner explicitly authorized fixing Sinal, superseding the earlier read-only restriction for this package alone. The tested generic correction is applied to `/code/gleam-dream/sinal`; its public API is unchanged. Review found a related delayed diagnostic-notification race: a paused sender could move a ReportDrops message into a replacement actor. Its synchronized red shows mailbox0→1; a direct incarnation destination plus one coalescing flag makes it0→0. All three probes now live in Sinal's own dev runner/CI and inject hooks only in disposable copies. HTTP Gun adds no queue/collector/ETS store or production FFI. The original wave22 preparation receipt remains historical; final-source qualification follows in wave23.

### Wave 23 — implementation

Implemented `config.observations`, typed `telemetry.event()` and a pure `with_correlation` Client view, preserving request options/failure constructors/cassette matching. The canonical local Sinal dependency is shared with LLM Wire; independent gates materialize its verified source archive at the same relative path. No second Sinal implementation resolves in a build. Scripts/replay report Offline and no Gun call; live recording separates HTTP termination from capture failure. Public tests cover1000 requests with a capacity1 blocked handler, unavailable/dead/throwing observers, queued deadline without submission, pre-header Gun return, strict matching, recording failure and H2 cancellation with a healthy sibling. The fast gate passes98 tests. A synchronous-delivery mutation fails the blocked-observer test while the real bounded path passes. Wave24 final qualification is in progress.

### Waves 23–24 — acceptance

Accepted, 2026-10-01. HTTP Gun uses one canonical Sinal implementation through a typed, opt-in observation surface. The dependency's generic startup, delayed-event and delayed-drop-notice corrections pass 93 tests and all three synchronized probes on Darwin ARM64/OTP29/28/27. Independent package gates use a hash-verified source archive; current downstream uses the same selected Sinal checkout. No collector/history/observation actor or production HTTP Gun FFI was added. The exact privacy, ownership, source-time ordering, best-effort loss and mode contracts are in OBSERVATIONS.md.

Final full HTTP gates on all three runtimes pass 98 tests, three consumers, seven precise type rejections with positive control, real H1/TLS/H2 and sibling-preserving cancellation, strict scripts/replay, live recording/persistence failures, async lifecycle/startup faults and practical batch/stream/load checks. Current LLM Wire passes 223 tests, its actual public boundary and five local H2 scenarios through1000 callers; selected originals are unchanged during the isolated check. The 97 frozen executable/dependency inputs remain identical. Initial Hex rate-limit attempts are retained, followed by passing sequential reruns without a production workaround. Evidence: wave23 and wave24/receipt.json.

The blocked-observer test requires a capacity1 forwarder to leave HTTP's1000-request bounded batch working, with one queued drop notice. A synchronous-delivery mutation fails the same test. All milestone integration tests remain in the ordinary suite. Sinal retains generic deterministic regressions in its own CI, using temporary-copy hooks only. HTTP Gun handwritten FFI remains92 lines/4669 bytes/13 bindings. Its selected Sinal forwarder bridge is114 lines/4135 bytes, covering atomics/routes and two narrow ETS operations; an obsolete named-send exception helper was removed. No required work remains in these waves. Linux/hosted CI, new Dream comparison/soak, enabled-telemetry overhead comparison and optional redaction/durability were not performed. No commit, push, publication, provider traffic or sibling/oversight edits beyond authorized Sinal occurred.

### Local integration after wave 24

The owner requested committing the accepted work. Sinal's generic correction is committed separately as8acec45. Its formatting hook only removed an extra README blank line; all qualified runtime source and tests remain unchanged. The HTTP Gun commit retains the accepted adoption additions, maintained async consumer, Sinal instrumentation, standalone dependency snapshot, documentation and complete validation evidence. The snapshot now identifies the clean Sinal commit. Integration recheck hashes distinguish that packaging/documentation update from the unchanged tested runtime. The normal HTTP Gun fast pre-commit gate remains enabled. No push, publication or other sibling changes are included.

### Destination policy — authorized plan revision 10

The owner's 2026-10-01 destination-policy prompt authorizes this complete scoped program. HTTP Gun starts at 2b3656e8. Warden is read-only behavioral evidence at 230c6bb4; transport SHA256 0fd3b160ecb50575a7185b4927b7010c684a218a3ba4e8fc46471d3d1de568cc and transport-test SHA256 f079d5ee5edc04b403d281c973a203080d3328cd7291a86d0e848d5c1c0f4c36. No donor source has been copied.

| Wave | Outcome                                                               | Acceptance                                                                                                                                                      |
| ---- | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 25   | Pure, validated destination policy and classification; secure default | Observable default refusal before a socket opens; address table and explicit loopback permission; existing local consumers opt in                               |
| 26   | Bounded resolution, pinned connections and original TLS identity      | One resolution per new connection, reject every mixed answer, typed pre-submission failures, cancellation/deadline/death cleanup; hostname and IP-SAN TLS tests |
| 27   | Send deadline, mailbox and parser-boundary qualification              | Controlled blocked sender and late replies; IPv6 authority; whole admitted head; raw malformed-response tests against released dependencies                     |
| 28   | Documentation and complete adoption qualification                     | Fast/full gates, current isolated downstream check, exact evidence, truthful dependencies and unresolved requirements                                           |

Decisions: retain Gun 2.6.0/Cowlib 2.20.0; policy, classification, resolution coordination and connection admission in Gleam; only native address parsing/lookup and Gun option conversion cross FFI. Resolution occupies finite connection admission capacity and cannot block the pool. Configuration is immutable for a client; checked connections are reused only within that client/origin, and replacement connections resolve again. Offline modes never resolve. Default policy becomes public-only; local tests explicitly permit loopback. No retries, dependency parser changes, Warden migration, release or commit is included. Strict parsing is an acceptance question to measure, not assume or silently waive.

Wave25 active. No new validation is claimed yet.

### Wave 25 — acceptance

The focused default-policy red returned MayHaveBeenSent after connecting to loopback; green refuses before a socket opens. The injected-private-answer red returned a real200 response; green returns DestinationRejected/NotSubmitted. After explicit opt-in updates to owned loopback tests,105 tests pass, including50 address classification cases, mixed/empty/failed DNS answers, exact case-insensitive allowlists, validation purity, literal bypass and checked-answer reuse. New typed reasons round-trip through the existing strict fixture codec. Logs: evidence/wave25. No source was copied from Warden and no sibling was changed. Wave26 is active: asynchronous resolution is implemented and lifetime/TLS qualification is underway.

The owner accepted the experimentally confirmed reason-phrase exception on2026-10-01: keep Gun/Cowlib unmodified and document it. The local Gun probe rejects bare LF and signed lengths/chunk sizes but accepts control bytes in header values and status reason text. HTTP Gun will reject delivered invalid header values; Gun does not expose status reason text to the client. Evidence: wave27/parser-probe.log. This is a precise exception to the requested parser acceptance, not a claim of strict wire parsing.

### Wave 26 — acceptance

Accepted: bounded Gleam resolution jobs occupy connection slots, validate complete A/AAAA answers, and supply only checked IP tuples to Gun. Original hostname TLS and IP-literal SAN verification pass with proper trusted-chain controls. Resolution cancellation, deadline, caller death, explicit stop, abnormal client death, throwing callbacks and cross-origin progress pass synchronized public probes. No resolver runs on the pool actor; no callback receives request bodies. Existing H1/H2 pool behavior remains green. Evidence is retained under docs/evidence/wave26; the initial self-signed-leaf fixture failure is disclosed and corrected without weakening verification.

### Wave 27 — acceptance

Accepted: complete delivered headers reject control values and enforce the final header's admitted byte contribution. Raw bare-LF/signed-length/signed-chunk cases fail through released Gun/Cowlib; the owner-approved reason-phrase exception is documented and measured. HTTP authority preserves original names and brackets IPv6, including default443. Four16MiB non-reading TCP/TLS cases (fresh/reused) terminate at the300ms request budget with bounded cleanup and unchanged caller mailbox; synchronized body cancellation/deadline callers also retain no messages after server/client cleanup. The fast gate passes120 tests. Additional100ms-connect probe passes, with no reproduced defect or production change; qualified test settings were restored. Logs: docs/evidence/wave27. The recording refusal test uses the existing bounded finish_wait because HTTP and writer acknowledgements are separate.

### Wave 28 — acceptance

Accepted,2026-10-01. All three full Darwin ARM64 gates pass on Gleam1.18.1/OTP29,28,27:120 tests, formatting/check/build, FFI warnings and package boundaries, three public consumers, seven intended compile rejections, async lifecycle/startup controls, independent nghttpd H2 and sibling cancellation, actual record/replay/persistence failures, batch scaling and eleven load scenarios. All106 frozen executable/dependency inputs match. Public API docs build. A temporary SNI=disable mutation is caught by the trusted wrong-certificate IP test. Initial gate failures/corrections are retained, never relabeled as passing.

Unmodified migrated LLM Wire1c0ad614 passes check/build but needs explicit loopback permission in its local setup (175 passes/48 failures). An isolated adaptation of eight test/example startup files passes223 tests, public boundary and five local H2 scenarios through1000 callers, with production code and all original checkouts unchanged. The normal downstream gate does not silently adapt sources. Warden is unchanged read-only evidence; migration/release and its future adapter gate remain separate work, not claims of this acceptance.

Current FFI is113 lines/5585 bytes/15 bindings. New native responsibilities are IP parse/tuple conversion and one-family DNS lookup; supported Gun TLS/send options are adapted in the existing bridge. All policy, resolution coordination, lifetime and pool changes are Gleam. No dependency patch, second transport runtime, commit, push, publication, provider credentials or sibling/oversight write occurred. Accepted boundaries: unexposed reason phrases, close-delimited TLS ambiguity, connection-lifetime DNS trust, inherited allocations and scheduling races; optional redaction/durability remain separate. Linux/hosted CI, new Dream comparison and sustained soak were not executed. No required implementation remains under the owner's accepted reason-phrase exception. Receipt: docs/evidence/wave28/receipt.json.

### Warden feedback — plan revision 11

The owner's G1–G4 feedback continues the authorized generic adoption work from b517725. Keep siblings read-only; no dependency patches, retries, publication or automatic replay. Design anchors: DESIGN.md configuration/transport ownership, pool reuse and truthful errors; BOUNDS.md post-parse limits and closing races.

- Wave29: resolve an independent stdlib1.0.5 consumer without changing its requirements; retain0.71 qualification; add `Trust.Anchors(List(BitArray))` mapping only to OTP cacerts, with verified local TLS, no filesystem conversion, and empty/malformed-input failure checks.
- Wave30: reproduce request/response close retirement and already-closed idle TLS reuse; prevent avoidable admission through supported Gun behavior, preserving live siblings, finite work and the original deadline. A readiness observation is not an atomic remote liveness guarantee; no submitted request may replay.
- Wave31: classify only facts established by released dependency events, retain ambiguous failures honestly, qualify complete gates/isolated downstream probes and document remaining Warden differences. No promise to invent five distinct error classes from indistinguishable dependency signals.

Each wave starts with an observable failing case and finishes with focused green evidence, followed by the complete final gate. Existing dependency/library roles remain unchanged. The production Warden switch/release and mTLS stay outside this task.

### Waves29–30 — focused acceptance

The independent stdlib1.0.5 consumer first failed dependency resolution, then
resolved and passed the original120 tests after widening only the bound. The
normal lock retains0.71. Direct `Anchors` first failed to compile, then passed
verified local TLS plus wrong-name/untrusted/invalid-only negative controls.
No anchor-file conversion exists in production.

A controlled acknowledged peer close reproduced G3 as
`ConnectionFailed(PeerClosed), MayHaveBeenSent`100ms later. The bounded supported
Gun readiness check makes the same request succeed on connection2, sequence1,
without replay. Repeated request/response close-token cases and a10ms deadline
during readiness pass. Mixed-case close-token retirement required its own
correction. A complete gate on stdlib1.0.5 exposed check-order contention; checks
now reserve active capacity, and readiness is not retained across admission
passes. The128-test suite passes after that correction. Wave31 is qualifying
the final complete tree; initial failures remain in the evidence.

G4's header-limit row now retains `HeaderLimitReached`; four malformed/truncated
rows retain coarse failures because released Gun events do not prove finer
categories. Warden's nine retained security probes pass, including both G3
cases, with in-memory trust in its isolated adapter. Its unchanged transport
suite remains17/19 and its fast suite124/126 because two tables still demand
unavailable precision and strict rejection of the accepted reason-phrase case.
No original checkout changed during that experiment. This is not a Warden
release/adoption acceptance. Final matrix/downstream qualification is pending.

### Wave31 — final qualification

Complete locally,2026-10-01. Three full Darwin ARM64 gates pass on
Gleam1.18.1/OTP29,28,27, each with128 tests on both stdlib0.71.0 and1.0.5.
The independent consumer resolves the actual public bounds. Public consumers,
seven intended type rejections with positive control, async ownership controls,
verified TLS/H2 and sibling cancellation, nghttpd, recording/replay and bounded
batch/load checks pass. All111 frozen executable inputs match. Public docs build.

The final isolated Warden adapter uses direct anchors and retains the new
header-limit cause. All9 security probes pass, including the formerly failing
idle-close and request-close cases. Its unchanged transport tests remain17/19;
the fast suite is124/126, boundary controls pass, and its independent consumer
passes8 tests. The two failing tables and skipped live IPv6:443 subcase are
explicit in the receipt; strict reason-phrase rejection and unavailable error
precision are not falsely marked passing. Warden adoption/release is separate.

Current LLM Wire passes223 tests, its public boundary and five local H2 scenarios
through1000 callers, with only eight isolated loopback test/example settings
adapted and production source unchanged. All selected original checkouts match
after both consumer checks. A Hex rate limit interrupted the initial OTP27 and
LLM attempts; their sequential retries pass without runtime changes. Earlier
mixed-case close-token and admission-order failures are retained with fixes.

FFI is121 lines/5900 bytes/16 bindings. The only new binding wraps supported
Gun info; anchor conversion and structured error mapping extend existing
bindings. Gleam owns all preparation, admission and lifetime changes. No
dependency patch, commit, publication, provider traffic or sibling write.
No current Linux/hosted CI, comparative benchmark or sustained soak was run.
Evidence: docs/evidence/wave31/receipt.json and README.md in that directory.

### Wave 3 follow-up — tenant views and failure headers

Complete locally, 2026-10-02, from the webhooks re-run after wave 3.
`config.require_view_destination` refuses (`ViewDestinationRequired`,
`NotSent`) any request whose view set no destination, in live, recording and
playback modes; views still only narrow. `send` and `batch` failures after the
head keep the redacted response headers (`error.headers`), stored by
`to_json`. A first draft captured the pool state in the reply callback and
failed `burst_work_scales_with_requests_test`; the callback now captures only
the redaction. `./dev/env sh dev/gate full` passes with 200 tests, all 11 load
scenarios and nghttpd; LLM Wire and Warden build against the change.

### Wave 4 follow-up — view correlation and narrowing destinations

Complete locally, 2026-10-03, from LLM Wire's wave 4 redesign.
`http_gun.correlation(client)` returns the view's correlation, so a library
copies the caller's correlation instead of asking for it twice.
`config.require_view_destination` is now satisfied only by a view policy that
sets `only_hosts` or refuses an address class the client admits; a policy
that only tightens the plaintext rule counts as none.
`scheme_tightening_does_not_satisfy_required_destination_test` covers both
directions; `required_view_destination_never_widens_the_client_policy_test`
now narrows with a host list; `narrows_results_test` covers
`destination.narrows`, which states the rule publicly because public modules
carry no `@internal` functions. `./dev/env sh dev/gate full` passes with 206
tests, all 11 load scenarios and nghttpd; Warden builds against the change.
