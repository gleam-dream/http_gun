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

- docs/DESIGN and BOUNDS record owner acceptance of reason-phrase limits on 2026-10-01. `369da4f` records Warden feedback corrections; exact approval transcript is not tracked.
- `http_gun_ffi.erl:reusable/1,cause/1,decode/1`, `internal/preparation.gleam`, `pool.gleam:checked`, `owner.gleam:check_headers`, wire/reuse/H2 tests.
- Parser and send-deadline receipts remain in `docs/history/evidence/wave27` and Warden-feedback qualification receipts. Accepting this boundary does not turn an independently stricter downstream framing expectation into a passing claim.
