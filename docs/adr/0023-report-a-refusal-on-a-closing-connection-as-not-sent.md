<a id="adr-0023"></a>

# 0023: Report a refusal on a closing connection as not sent

Date: 2026-11-25
Status: Accepted

## Decision

- Gun's refusal of a request on a connection in its closing state is
  `RequestFailed(PeerDraining)` with NotSent instead of MaybeSent.
- Every other failure after the Gun request call stays MaybeSent.
- This supersedes ADR 0008's rule that every failure after the Gun request
  call is MaybeSent, for this one refusal only. The rest of ADR 0008 stands.

## Rationale and alternatives

- In Gun 2.6.0, `gun:closing/3` answers the `request` and `headers` casts with
  `{gun_error, self(), StreamRef, closing}` and keeps its state when `retry` is
  0, which HTTP Gun always sets. The clause runs in place of the protocol
  module's request function, so no byte of that request reaches the socket.
- Gun enters the closing state after it has processed a peer GOAWAY on HTTP/2
  or begun a graceful close, and no other Gun path reports the reason
  `closing`, which `http_gun_ffi:cause/1` maps to PeerDraining. The evidence is
  therefore exact for this reason, not an inference from a race.
- A request that Gun accepted before it processed the GOAWAY is written and
  fails with another reason, which stays MaybeSent.
- Keeping MaybeSent would deny a safe retry of a non-idempotent request that
  provably never left the client, which is the case a caller most needs to
  retry after a peer goes away.

## Evidence

- Owner ruling on 2026-11-25.
- `test/http_gun_h2_test.gleam`
  (`draining_connection_admits_no_stream_after_a_refusal_test`) observes the
  refusal from a server that sends GOAWAY while an earlier stream stays open,
  and checks NotSent and that `error.is_retryable` allows a non-idempotent
  retry.
