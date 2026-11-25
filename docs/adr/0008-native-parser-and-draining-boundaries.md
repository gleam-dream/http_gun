# Native parser and draining boundaries retain conservative evidence

<a id="adr-0008"></a>

## Decision

- Keep post-parse delivered-header byte/count/control checks separate from native wire allocation and parsing.
- Accept the documented reason-phrase boundary: Gun discards reason text before its public head event, so HTTP Gun cannot reject controls or mixed terminators interpreted inside that text.
- Keep GOAWAY/submission races and unsupported precise parser causes conservative. H1 readiness uses supported info in a bounded worker before reuse; it is a point-in-time observation.

## Rationale and alternatives

- Dependency patches or a custom parser would change the restart's ownership contract. Stack-trace matching would create false precision and an unstable dependency on crash internals.
- Readiness inspected synchronously inside the pool can stall unrelated origins during Gun's TLS-alert wait. A bounded preparation job preserves pool progress and can discard an unused connection before submission.
- No supported call atomically establishes H2 eligibility and request acceptance. Returning MaybeSent after invocation states the uncertainty without inventing retry permission.
- Close-delimited TLS EOF can be indistinguishable from truncation without declared framing. Consumers must validate completeness at the payload/framing boundary they own.

## Evidence

- docs/DESIGN and BOUNDS record owner acceptance of reason-phrase limits on 2026-10-01. `369da4f` records Hellhound feedback corrections; exact approval transcript is not tracked.
- `http_gun_ffi.erl:reusable/1,cause/1,decode/1`, `internal/preparation.gleam`, `pool.gleam:checked`, `owner.gleam:check_headers`, wire/reuse/H2 tests.
- The parser and send-deadline receipts and the Hellhound-feedback qualification receipts are retained in repository history at commit `1549541` and earlier. Accepting this boundary does not turn an independently stricter downstream framing expectation into a passing claim.

## Amendment of 2026-11-25: a refusal on a closing connection is NotSent

- Gun's refusal of a request on a connection in its closing state is
  `RequestFailed(PeerDraining)` with NotSent instead of MaybeSent. The owner
  ruled this change; the rest of this record stands, including MaybeSent for
  every other failure after the Gun request call.
- Evidence: in Gun 2.6.0, `gun:closing/3` answers the `request` and `headers`
  casts with `{gun_error, self(), StreamRef, closing}` and keeps its state when
  `retry` is 0, which HTTP Gun always sets. The clause runs in place of the
  protocol module's request function, so no byte of that request reaches the
  socket. Gun enters the closing state after it has processed a peer GOAWAY on
  HTTP/2 or begun a graceful close, and no other Gun path reports the reason
  `closing`, which `http_gun_ffi:cause/1` maps to PeerDraining.
- A request that Gun accepted before it processed the GOAWAY is written and
  fails with another reason, which stays MaybeSent.
- `test/http_gun_h2_test.gleam` (`draining_connection_admits_no_stream_after_a_refusal_test`)
  observes the refusal from a server that sends GOAWAY while an earlier stream
  stays open, and checks NotSent and that `error.is_retryable` allows a
  non-idempotent retry.
