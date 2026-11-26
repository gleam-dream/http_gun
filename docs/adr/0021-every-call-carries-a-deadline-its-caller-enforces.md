<a id="adr-0021"></a>

# 0021: Every call carries a deadline its caller enforces

Date: 2026-11-25
Status: Accepted

## Decision

- Every request has a finite deadline, fixed when the call is made: the view's
  deadline, the view's timeout from the call, the earlier of the two when both
  are set, or 30 seconds from the call when neither is. `config.Infinity` no
  longer applies to the request timeout, and the client configuration holds no
  request timeout: `config.with_request_timeout` and the `RequestTimeout`
  setting are removed, and `http_gun.with_timeout` takes a `Duration`. A
  timeout of zero or less fails the call before admission with
  `DeadlineExceeded` and `NotSent`.
- The calling process enforces the deadline itself. It waits for the pool and
  then the body owner until the deadline plus a fixed grace of 500 ms. When the
  grace ends without an answer, the call returns `DeadlineExceeded` with
  `MaybeSent`, because the process that holds the reply may have submitted the
  request. Body reads and closes are bounded the same way, measured from the
  later of the deadline and the moment of the call.
- Replies travel to a process alias created for the one call. The caller
  deactivates the alias when it stops waiting, however the wait ends, and
  removes any reply already delivered. The runtime drops every later reply, so
  no message from an abandoned call stays in the caller's mailbox.
- This supersedes ADR 0002's statement that a view's timeout or deadline
  replaces the startup request timeout, and its rationale for keeping an
  unbounded request timeout for streams. The connect, pool and idle timeouts
  stay independent, as ADR 0002 records.

## Rationale and alternatives

- The pool and the body owner enforced the deadline, and the caller waited for
  them without a bound. A pool that is alive but stuck (a synchronous
  telemetry handler, a slow recorder reservation, a first trust-store load)
  held every caller past every timeout, and no timeout setting recovered it.
- A caller cannot enforce a deadline it does not know. A handle from
  `http_gun.named(name)` carries no configuration, so a request timeout held
  in the configuration is visible only to the pool. Moving the timeout to the
  call makes the deadline known where it is enforced, and removing `Infinity`
  makes an unbounded wait impossible to express.
- A long-lived stream now states a long timeout and opens a new request when it
  ends. A stream that must outlive the timeout reconnects, as SSE clients do
  after any disconnect.
- A plain reply subject leaves a late reply in the caller's mailbox for the
  life of the process. A monitor-based alias is the mechanism `gen_server:call`
  uses for the same guarantee; the native boundary gains two runtime calls.
- The grace lets the pool's or owner's typed answer win in ordinary operation,
  so the caller's own expiry only appears when the answering process is stuck.

## Evidence

- `test/http_gun_caller_deadline_test.gleam` suspends the pool and, separately,
  a body owner, and checks that the call ends with `DeadlineExceeded` and
  `MaybeSent` and that no late reply reaches the caller's mailbox. With a
  plain reply subject instead of the alias, both mailbox checks fail.
