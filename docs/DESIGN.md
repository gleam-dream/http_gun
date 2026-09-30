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

Gleam recorder: ordered reservations, incremental acknowledged writer records, finite capture budget, independent capture failure, Active/Finalized/Failed session state; finish while busy refuses, repeated finish is deterministic. Publish only a finalized complete session, atomically, with explicit replacement. Interrupted temporary data is never a completed fixture. Strip credential headers; queries and bodies can contain secrets. Bodies and queries remain exact. Body/query redaction and crash-durable publication are optional client-owned features, not dependency defects; neither is implemented in this scope. Atomic visibility is required, power-loss durability is not.

FFI: straightforward Gun open/request/update_flow/cancel/close, typed event decoding, monotonic milliseconds, exception-safe scope cleanup and genuinely missing filesystem primitives. Use file_streams 1.7.0 for bounded raw reads/exclusive writes and simplifile 2.7.0 for path operations. Gleam owns file policy and error mapping; retain small bridges for unique candidate names, empty-directory removal and exception cleanup. No domain policy or handwritten server loops.

## Delivery slices and observable acceptance

1. Binary ordinary request over local Gun; standard HTTP types and validated configuration.
2. Shared owner, timeout versus deadline, finite buffered collection, early and exceptional cleanup.
3. Reuse, origin fairness, finite batch and admission, TLS, real H2 multiplexing/cancellation, supervision.
4. Strict scripts and versioned binary disk replay, ordered repeated exchanges and non-consuming mismatch.
5. Actual live recording, failure/cancellation observations, backpressure, deterministic publication failures.
6. Public-only consumer, isolated LLM consumer, type rejection, scaling at 1/10/100/1000 and large/mixed streams, documentation and CI.

Follow-on: streamed uploads, redirect policy, decompression, proxies/mTLS, cookie/cache adapters and SSE parsing. Provider semantics stay outside this package.
