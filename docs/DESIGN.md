# Gleam-first client contract

Accepted authority: the owner's HTTP Gun restart prompt, 2026-09-29. This is a fresh implementation. Oversight's public API guidance applies; obsolete parser-hardening plans do not.

## Consumer checks

```gleam
let assert Ok(client) = http_gun.start(config.default())
let result = http_gun.send(client, request)
let result = http_gun.with_response(client, request, fn(response) {
  body.next(response.body, 1000) // returning early cancels locally
})
let results = http_gun.batch(client, requests, 10) // input order
let _ = http_gun.stop(client)
```

Live uses start; scripts use testing.start; disk playback uses cassette.playback; recording uses cassette.record. Every constructor returns the same Client, with recording additionally returning a finish capability. Mode selection belongs at application startup. No automatic fallback.

## Ownership and transitions

Gleam pool actor: bounded admission, FIFO waiting work by normalized origin, connection states Connecting/Ready, H1 exclusive leases, H2 stream capacity and reuse-first policy. An admission pass stops at a blocked origin's head and continues with other origins. Origins that make progress yield their place for the next pass. Playback retains one globally ordered session queue. Gun owns connections and protocol state. Requests spend their overall budget starting before admission. Expiry before submission reports NotSubmitted; after Gun request invocation reports MayHaveBeenSent. Neither proves server execution. No retry.

The pool owns queue membership, caller/id indexes, FIFO links, waiting counts and body-owner membership together. Removing an expired or dead caller immediately unlinks its entry; no cancelled-entry history remains behind a blocked head. Cached origins are established during request validation. A connection reservation is distinct from waiting work and remains bounded by connection admission. Scheduling work depends on waiting origins and available capacity, rather than repeatedly traversing every request behind a blocked origin.

Callbacks crossing process boundaries capture only the values required by that operation. Pool cleanup callbacks carry message destinations; batch workers carry one input and the operation; capture acknowledgements carry their destination. They must not carry unrelated pending work, completed results or body queues across the process boundary.

Gleam body actor: Opening -> Reading -> Complete/Failed/LocallyCancelled. One consumer is the opening process. Copies share the actor state. Another process receives ReadConflict if a read is pending, otherwise WrongOwner. A read-wait timeout clears only that waiting read, retaining credit and admitted bytes. Overall deadline is terminal. Scope exit, owner death, close and shutdown converge on idempotent release. Close means local cancellation, never remote rollback. Completed bytes/trailers survive until read or owner closure, subject to finite retained-owner admission.

Demand uses one outstanding Gun flow credit. No forwarding process eagerly drains the response. H2 flow credit is not a byte limit: supported receive windows plus post-delivery chunk/queue limits bound HTTP Gun's admitted storage, not dependency parser allocation. Headers and trailers are checked after parsing. Pass the configured header count to Gun’s supported max_headers setting, allowing for the H2 status pseudo-header. Keep byte admission distinct from wire/parser limits. GOAWAY/submission races return truthful failures and do not justify dependency changes.

Gleam batch scheduler: at most requested bounded workers, input-indexed results, independent failures, same pool and send implementation.

Gleam playback mode in the client actor: ordered session position, match before advance, finite fixture and diagnostic data; concurrent requests take admission order. Strict missing/corrupt/version/exhaustion errors. No network in replay.

Gleam recorder: ordered reservations, incremental acknowledged writer records, finite capture budget, independent capture failure, Active/Closing/Sealing/Sealed/Broken states; immediate finish while busy refuses, bounded finish waiting seals reservations, repeated finish is deterministic. Publish only a finalized complete session, atomically, with explicit replacement. Interrupted temporary data is never a completed fixture. Strip credential headers; queries and bodies can contain secrets. Bodies and queries remain exact. Body/query redaction and crash-durable publication are optional client-owned features, not dependency defects; neither is implemented in this scope. Atomic visibility is required, power-loss durability is not.

FFI: straightforward Gun open/request/update_flow/cancel/close, typed event decoding, monotonic milliseconds, exception-safe scope cleanup and genuinely missing filesystem primitives. Use file_streams 1.7.0 for bounded raw reads/exclusive writes and simplifile 2.7.0 for path operations. Gleam owns file policy and error mapping; retain small bridges for unique candidate names, empty-directory removal and exception cleanup. No domain policy or handwritten server loops.

## Delivery slices and observable acceptance

1. Binary ordinary request over local Gun; standard HTTP types and validated configuration.
2. Shared owner, timeout versus deadline, finite buffered collection, early and exceptional cleanup.
3. Reuse, origin fairness, finite batch and admission, TLS, real H2 multiplexing/cancellation, supervision.
4. Strict scripts and versioned binary disk replay, ordered repeated exchanges and non-consuming mismatch.
5. Actual live recording, failure/cancellation observations, backpressure, deterministic publication failures.
6. Public-only consumer, isolated LLM consumer, type rejection, scaling at 1/10/100/1000 and large/mixed streams, documentation and CI.

Follow-on: streamed uploads, redirect policy, decompression, proxies/mTLS, cookie/cache adapters and SSE parsing. Provider semantics stay outside this package.

## Accepted API ergonomics (2026-09-30)

The owner's “apply them” authorizes these four changes. Existing default HTTP calls and immediate recording finish remain available. No new dependency or transport path is introduced.

E1 Recording completion: `recording.finish_wait(recording, wait_ms)` closes new reservations, waits for existing consumers and writes without reading HTTP itself, and publishes once all observations are terminal. Its timeout ends only that wait; closing/finalization continues. Subsequent finish calls observe the stable result. One active waiter is allowed; contention returns Busy. Timed-out/dead waiters are removed. Abort/owner death interrupt capture; HTTP outcomes stay independent.

E2 Scoped errors: `try_with_response(client, request, on_http_error, consume)` maps opening errors into the caller's error type and flattens a fallible callback. The callback maps its own read/application errors. Existing arbitrary-value `with_response` and exception-safe cleanup remain unchanged.

E3 Request controls: opaque monotonic Deadline plus scoped opaque cancellation Token are independent optional request values. The effective request deadline is the earlier of the client ceiling and supplied deadline, measured before request preparation when created then. Cancellation is latched, copies share it, and scope/creator death cancels associated unfinished requests. Pending and active cancellation converge on the existing pool/body owners, including pre-header work. Cancelled/expired work known to precede submission returns NotSubmitted; racing submissions remain conservative. Controls never enter cassette matching. Completed HTTP is not retrospectively failed. Token subscriptions are bounded and removed after release; no eager reader or worker per request is introduced. Existing calls use default options; send/open/scoped variants accept explicit options.

E4 Useful errors: limit kinds are typed and include observed sizes where known. Transport and filesystem reasons retain supported, bounded categories with explicit unknown cases. `error.describe` excludes free-form config/request/fixture details, headers, URLs, bodies and queries. Rich errors retain submission evidence and capture errors remain separate. Fixtures have one current schema identified by a format marker; old experimental layouts are rejected, never migrated or retried through another decoder. Public functions document ownership, timeouts, failures and cleanup.

E4 representation: observed sizes are required Int values measured at enforcement, with typed byte/count categories. Invalid byte budgets are configuration errors before IO. The package is unreleased: keep one current fixture schema under marker1 and no legacy decoder, compatibility-only error variants or release migration burden. Unknown transport/IO causes remain valid runtime uncertainty. Publication is the filesystem atomic commit point; abort cannot roll back an already committed publication.

Pre-release cleanup (2026-09-30): the owner explicitly accepts breaking changes and confirms no external consumers or released versions. Earlier experimental fixtures may be regenerated. Retain the format marker to detect incompatible data, without introducing a package release or parallel codec. Tests and examples evolve with the API; update them in the same wave.


## Accepted adoption improvements (2026-09-30)

A1 Current adoption: LLM Wire at1c0ad614 is a migrated downstream consumer of HTTP Gun at ebf2b479. Revalidate explicitly against selected working copies in an isolated closure, recording revisions and source hashes and checking originals unchanged. Normal package gates remain independent of sibling checkouts. Archived examples do not prove current downstream compatibility.

A2 Asynchronous composition: a maintained application example owns a shared supervised client and a bounded number of jobs. Each job's worker opens and reads its own body under a cancellation scope spanning its whole lifetime. A monitor-only guardian terminates that worker on application-owner death. Synchronous sink processing precedes further demand; there is no chunk-forwarding mailbox. Application shutdown has a finite grace and may terminate its own blocked worker. One job completing never stops the shared client. This is application recipe code, not a second library body server or task runtime.

A3 Policy inspection: `request_ceiling_ms(client)` returns the positive immutable startup ceiling carried by that exact capability, in every mode and after stop. It performs no actor call and makes no liveness claim. A restart delivers a new capability; inspecting an old one returns its old policy. Default30000ms and min(client ceiling, supplied monotonic deadline) enforcement remain unchanged. Read waits, connection timeouts and recording finalization waits remain separate.

A4 Fallible cancellation scope: `cancellation.try_with_token(on_start_error, run)` maps only token-startup Failure into the caller's error type and returns the fallible callback's Result directly. Success, callback failure and exceptions have identical lifetime/cleanup to with_token. Group cancellation and typed request evidence are unchanged. Exceptions propagate after cleanup; no error or retry inference is introduced.

## Accepted Sinal observation boundary (2026-10-01)

The owner selected Sinal for lifecycle observation delivery. HTTP Gun supplies typed HTTP milestones, opaque request correlation and monotonic VM-local timestamps. An application-owned, supervised Sinal forwarder owns bounded asynchronous delivery and drop reporting. HTTP Gun does not add an observation collector, mailbox, retained timeline, ETS store or forwarding actor. The earlier fixed-slot experiment remains historical evidence, not the implementation target.

Observation is opt-in. HTTP Gun uses an explicitly supplied forwarder and direct forwarding; neither synchronous `sinal.emit` nor `emit_routed`'s synchronous no-route fallback may run user handlers inside HTTP owners. Full, unavailable or failed observation delivery must not alter HTTP outcomes, cancellation, deadlines or recording. Events contain no URLs, queries, headers, bodies, credentials or raw dependency terms, and there are no default per-chunk events. Applications own any retained history and downstream export queues.

The pool remains authoritative for admission; the request/body owner remains authoritative for local Gun-call return, accepted final response headers and HTTP termination. Observations are best effort and unsuitable for correctness or retry decisions. Gun-call return establishes only return from a local asynchronous API, not transport processing, bytes written or remote receipt. Script/playback observations must identify their simulated execution and never claim network submission. Recording persistence remains separate.

Implemented through `config.observations`, `telemetry.event()` and a pure correlated Client view. Request options, HTTP failures and cassette schema are unchanged. The generic Sinal correction gives each actor incarnation its own direct destination, admission slots and drop-notice flag. No HTTP-specific server is added to Sinal. Dependency source and gate isolation are described in [OBSERVATIONS.md](OBSERVATIONS.md); exact qualification is in the current wave tracker.
