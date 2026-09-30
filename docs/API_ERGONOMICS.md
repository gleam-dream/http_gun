# Public API ergonomics

The four accepted improvements are implemented on the existing client, body and recording actors. Ordinary `send`, `open`, `with_response`, `batch` and immediate `finish` remain available. The separate [ordinary consumer](../examples/ordinary/src/http_gun_consumer.gleam) compiles these controls through live, recording and playback clients. The [LLM example](../examples/llm/src/http_gun_llm_consumer.gleam) uses fallible scoped consumption.

## Recording completion

```gleam
let outcome = recording.finish_wait(recorded.recording, 5000)
```

This seals new recording reservations and waits for already accepted requests and writes. It never reads or drains response bodies. Consume or close those bodies normally. Success returns the published path. `WaitTimeout` ends this wait only: finalization continues, and a later call observes its stable outcome. One completion waiter is admitted; an overlapping waiter gets `Busy`. A dead or timed-out waiter releases that slot. `recording.finish` keeps its immediate Busy behavior. `recording.abort` explicitly abandons capture; stop the client separately.

A recording failure stays separate from an HTTP outcome. Atomic publication provides visibility of a complete fixture, not power-loss durability. Abort cannot roll back a publication syscall that already committed.

## Fallible scoped streaming

```gleam
// AppError has an Http(error.Failure) constructor.
use response <- http_gun.try_with_response(client, req, Http)
body.next(response.body, 1000)
|> result.map_error(Http)
```

The opening failure is mapped with `Http`; the callback maps its own read/application errors. The result is a single `Result(value, AppError)`. Scope exit closes the body for success, error and exception. Returning after one chunk is early termination. The original `with_response` remains useful for callbacks returning arbitrary values.

## Per-request deadline and cancellation

```gleam
let assert Ok(budget) = deadline.after(5000)
// Prepare the request here: preparation consumes the same monotonic budget.
let options = request_options.Options(
  ..request_options.default(),
  deadline: Some(budget),
)
let outcome = http_gun.send_with_options(client, req, options)
```

`Deadline` is opaque and VM-local; `remaining_ms` reports remaining time without renewing it. Zero is expired; a negative duration is invalid. The effective deadline is the earlier of this deadline and the client's request ceiling. It covers admission, connection, headers and unfinished body consumption. Existing calls use the client ceiling.

```gleam
let outcome = cancellation.with_token(fn(token) {
  let options = request_options.Options(Some(budget), Some(token))
  // Share token with a controlling process to cancel before headers or during reads.
  http_gun.send_with_options(client, req, options)
})
```

`with_token` returns an outer Result for token startup and preserves the callback's value. When the callback returns a Result, flatten or map that outer error as appropriate. Copies share latched state. `cancellation.cancel(token)` returns Nil after latching; associated owners release resources asynchronously. Repeated cancellation is harmless. Scope exit, exceptions and creator death cancel unfinished associated requests; a token kept beyond its scope stays cancelled. A token can deliberately group several requests. Completed HTTP is preserved. No token transfers body-consumption ownership or proves remote cancellation.

Use `open_with_options`, `with_response_with_options` or `try_with_response_with_options` for streaming. Execution controls never change cassette matching. `batch` retains its small policy and client defaults; custom grouped control can be composed by applications using the same client.

The three waits differ: `body.next` timeout preserves HTTP, a request deadline terminates unfinished HTTP, and `finish_wait` timeout preserves recording finalization.

## Typed diagnostics and fixture format

`Failure(reason, evidence)` keeps conservative `NotSubmitted`/`MayHaveBeenSent` evidence. Limit errors are `LimitExceeded(kind, limit, observed)`, with typed byte/count categories and a required observed Int. This is the amount seen at enforcement, not an upstream allocation bound or necessarily the full body/file size. Bounded file reads report the limit plus one observed byte. Negative fixture budgets are configuration errors checked before opening a file or decoding JSON.

`ConnectionFailed(cause)` and `RequestFailed(cause)` classify known DNS, refusal, TLS/certificate, reset/close, draining, timeout and protocol causes. Unsupported dependency reasons become `UnknownTransport`; raw Erlang terms are not exposed. Filesystem errors retain operation and cause: `FixtureIo(operation, cause)` for loading and `recording.IoFailure(operation, cause)` for capture. `error.describe(failure)` uses fixed vocabulary and numbers; it omits free-form details and request/response content. It does not sanitize a separately logged Failure value.

This package is unreleased and has no external consumers. Owned tests and examples use the current error types; no downstream migration is pending. For example, a `case` branch can match `ConnectionFailed(ConnectionRefused)` to inspect the cause, or `ConnectionFailed(_)` to handle all connection causes. No retry is inferred from the category.

Cassettes have one current schema marked `"http_gun": 1`. The marker detects incompatible data; it is separate from a package release/version. Old experimental layouts are not migrated: regenerate those fixtures. Missing required values, unknown tags and unsupported format markers fail explicitly, with no legacy or network fallback. Pre-release API/schema changes are allowed without compatibility scaffolding or a package version bump.

## Implementation boundary

Gleam owns finish waiting, scopes, deadlines, cancellation, pool/body cleanup, typed file errors and the strict fixture codec. One small Erlang classifier converts supported Gun/OTP failure terms to bounded transport categories. Production handwritten FFI totals 92 physical lines / 4,669 bytes across two files and 13 declarations: Gun bindings/message conversion, transport cause conversion, monotonic time, exception-safe cleanup, unique temporary names and directory removal. Dependencies remain pinned and unmodified. No handwritten server, parser, second transport path or provider semantics were added.

Exact validation is recorded in [VALIDATION.md](VALIDATION.md) and the append-only [wave tracker](implementation/gleam-first/wave-tracker.md).
