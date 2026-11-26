<a id="adr-0026"></a>

# 0026: Verify tells a silent client from a stopped one

Date: 2026-11-26
Status: Accepted

## Decision

- `testing.VerifyError` gains `NotAnswered`: the client did not answer before
  the deadline of the view given to `testing.verify`. `ClientStopped` means
  only that the client has stopped.
- This supersedes, for `VerifyError` in 0.4.0 only, ADR 0018's rule that the
  verdict types gain no variants. The rule stands for later releases.

## Rationale and alternatives

- ADR 0021 bounds every pool query by the view's deadline. A playback client
  that is alive but slow therefore failed the query with `DeadlineExceeded`,
  which `verify` reported as `ClientStopped`, a claim the client contradicts
  when it answers the next call.
- A separate function would leave `verify` reporting a stopped client that is
  running. 0.4.0 already breaks the public interface, so the variant costs a
  consumer one more case in a release it must adapt to anyway.

## Evidence

- `test/http_gun_caller_deadline_test.gleam`
  (`verify_on_a_blocked_pool_is_not_a_stopped_client_test`) suspends a
  client's pool and calls `verify` through a 100 ms view. Before the change it
  returned `Error(ClientStopped)`.
