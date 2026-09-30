# Wave tracker: Gleam-first HTTP Gun

## Current state

- Tracker path: docs/implementation/gleam-first/wave-tracker.md
- Updated: 2026-09-30; original program and scoped follow-ups complete.
- Target: docs/DESIGN.md and the owner's restart prompt; plan revision 4 (filesystem, comparison and performance follow-ups authorized).
- Approved first milestone: standard binary Request -> real local Gun HTTP -> buffered Response with trailers, using Gleam ownership. Final acceptance includes all six waves; the first milestone is not completion.
- Approval: the original prompt explicitly supplied and authorized the complete six-slice program, directed continuation without another broad approval cycle, and selected Gun/OTP/Gleam. Follow-up explicitly requested progressive implementation. This records that existing authorization, not inferred approval from silence.
- Last closed wave: 9 accepted. Active: none.
- Open material decisions: none. Reversible implementation details follow the contract.
- Temporary production substitutes: none. Loopback H1/H2 servers are test infrastructure, never production paths.
- Gate: fast passes 57 tests, formatting, check/build, FFI warnings and boundaries. Full isolated matrix passes OTP29/28/27 with 57 tests, ordinary and LLM consumers, four rejection fixtures and eleven load scenarios each. Final comparison: all 31 contract observations checked, HTTP Gun 27/27 workloads successful, Dream 26/27 with one disclosed failed burst. Exact receipts in docs/VALIDATION.md and docs/BURST_FIX.md.
- Next action: none required for the authorized performance correction. Optional features remain deferred; further performance work should start from a concrete workload and this evidence.
- Recovery: archives and hashes in docs/PROGRESS.md. No old production runtime was retained. All six retained waves pass the completed gates.

## Technology and boundary decision register

| Role | Adopt / contract / first wave | Alternatives and reason | Evidence / revisit |
| --- | --- | --- | --- |
| Compiler/runtime | locked Gleam 1.18.1 and OTP 29, wave 1 | retain reproducible Nix rather than ambient runtime | `gleam --version`, `system_info`; OTP27/28 compatibility checked in wave6 before claims |
| HTTP values | gleam_http 4.4.0, wave1 | custom request types rejected: duplicate facts | inspected Request/Response APIs; external consumer wave6 |
| Orchestration | gleam_otp 1.3.0, gleam_erlang 1.3.0, wave1 | handwritten Erlang servers rejected by owner | inspected typed actors, selectors, monitors, supervision; process.call panics, so use typed monitored calls |
| Wire | Gun 2.6.0, Cowlib 2.20.0, wave1 | HTTPc violates selected transport; old Erlang orchestration rejected | released Hex versions verified; untouched source; real socket proof wave1 and TLS/H2 wave3 |
| Fixture codec | gleam_json 3.1.0, wave4 | raw Erlang terms rejected as portable fixture contract | selected dependency API to inspect at wave4; bounded versioned binary encoding |
| Persistence | file_streams 1.7.0 and simplifile 2.7.0, wave7; Gleam writer retained | replaces wave5 primitives after broader ecosystem review; stdlib1-only releases deferred | bounded raw reads/exclusive writes; atomic link/rename; small bridges only for missing primitives; FILESYSTEM.md |
| Test infrastructure | gleeunit 1.9.0 and reviewed loopback servers, wave1/3 | provider endpoints excluded | exact inherited file hashes in provenance.json; test servers use Cowlib, not a production parser |

Sources: https://hex.pm/packages/gun, https://hex.pm/packages/cowlib, cached selected Gleam package source, https://gleam.run/news/. References guide scenarios only; no upstream parity claimed.

## Complete wave map

All waves use docs/DESIGN.md's corresponding numbered acceptance and Ownership and transitions contracts. Fast gate is `./dev/env sh dev/gate fast`; full is `./dev/env sh dev/gate full`. The gate is grown as its surfaces exist; absent later checks remain pending, never passing. No production substitute or removal obligation is approved. File/hash snapshots precede retained donor material.

| Wave | Visible result and purpose | Core transition / real shell | First adopted / deferred libraries | Observable scenarios and exit | Risks / revisit evidence |
| --- | --- | --- | --- | --- | --- |
| 1 | Ordinary binary HTTP, prove independent runtime path | validate config/request; Opening -> head -> bytes -> end; real Gun socket | compiler, HTTP, OTP/Erlang, Gun/Cowlib, gleeunit; JSON deferred to4 | binary201, arbitrary methods/non2xx, empty response, duplicate head/trailer, invalid config; fast formatting/check/build/tests/FFI warnings | Gun events/flow semantics may revise body internals, never widen FFI policy |
| 2 | Scoped and owned streaming on same bounded collection path | single consumer, shared cursor, timeout != deadline; monitor/credit/cancel | existing libraries; no new infrastructure | early/exception close, copied handle, competing read, owner death, overflow, stalled read, deadline; fast | actual H1/H2 delivery may need finite queue accounting; no eager draining |
| 3 | Managed concurrent requests and batches, verified TLS/H2 | reuse before create, finite admission, origin scan, H1/H2 leases, per-request deadline; supported Gun settings notifications | OTP supervision API, existing Gun TLS/H2; JSON remains deferred | shared H2 socket, sibling survival, queue expiry, owner loss, origin fairness, bounded worker count, shutdown/restart; fast and targeted full checks | capacity/GOAWAY races exposed by public Gun API return truthful failures; no replay |
| 4 | Strict offline scripts and disk replay | sequence match before advance; validate fixture version/bytes; same body owner | JSON first real codec contract; filesystem read bridge | repeated identical requests, mismatch then correct request, missing/corrupt/version/exhausted, concurrent session ordering; fast | malformed fixture ambiguity must reject, never fall back |
| 5 | Real live recording and deterministic finish | reserve -> capture acknowledged records -> complete/fail/cancel -> publish; busy/finalized/failed | file write/publish bridge; Gleam writer actor | actual roundtrip, early cancellation no drain, HTTP vs capture failure, budget/backpressure, destination refusal/replace, interrupted recording no fixture; fast/full persistence checks | IO stalls must not block HTTP lifetime controls; no claimed fsync durability |
| 6 | Independently consumable package and accurate practical limits | public-only apps compose; validate scaling and source boundaries | isolated LLM snapshot as dev-only reference; no production sibling dependency | external app, opacity/body rejection, LLM provider encoding/reduction above HTTP, 1/10/100/1000 and large/mixed streams, runtime matrix; full | report environment-limited cases honestly; no universal memory certification |

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
