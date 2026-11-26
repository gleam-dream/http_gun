# Migrating from HTTP Gun 0.3 to 0.4

HTTP Gun 0.4.0 is a breaking release. Change the dependency to `http_gun >= 0.4.0 and < 0.5.0` in `gleam.toml`, and `sinal` to `>= 0.2.0 and < 0.3.0` if the application depends on Sinal directly. Then work through the sections below in order. The first one affects most applications.

| Change                                                                                          | Who must act                                                                                                            |
| ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| [Every call has a deadline its caller enforces](#every-call-has-a-deadline-its-caller-enforces) | Code that calls `config.with_request_timeout`, or passes `config.Infinity` or `config.After` to `http_gun.with_timeout` |
| [Sinal 0.2 binds handlers to their process](#sinal-02-binds-handlers-to-their-process)          | Applications that attach HTTP Gun lifecycle handlers                                                                    |
| [A refusal on a closing connection is not sent](#a-refusal-on-a-closing-connection-is-not-sent) | Retry code that matches `PeerDraining` or `MaybeSent`                                                                   |
| [Gun's closing timer is off](#guns-closing-timer-is-off)                                        | Code that relied on a response being cut 15 seconds after `connection: close`                                           |
| [A verify call can end with `NotAnswered`](#a-verify-call-can-end-with-notanswered) | Code that matches `testing.VerifyError` exhaustively |
| [Header names and values are always text](#header-names-and-values-are-always-text)             | Code that reads raw bytes from response header or trailer values                                                        |
| [Other behaviour changes](#other-behaviour-changes)                                             | Code that depends on 0.3 read, batch, GOAWAY or queue behaviour                       |

## Every call has a deadline its caller enforces

**What changed.** Every request now has a finite deadline, fixed when the call is made. The deadline is the view's `with_deadline`, the view's `with_timeout` measured from the call, the earlier of the two when both are set, or 30 seconds from the call when neither is. The calling process enforces it: it waits for the pool and then for the body owner until the deadline plus 500 ms, and then returns `DeadlineExceeded` with `MaybeSent`. Body reads, body closes and pool queries such as `http_gun.stats` are bounded the same way. A reply that arrives after the caller stopped waiting never reaches its mailbox.

The request timeout is no longer part of the client configuration:

- `config.with_request_timeout` is removed.
- The `config.RequestTimeout` setting, which `config.validate` could name in a `ConfigError`, is removed.
- `http_gun.with_timeout` takes a `gleam/time/duration.Duration` instead of a `config.Timeout`. `config.Infinity` can no longer lift the request bound.
- A timeout of zero or less fails the call at once with `DeadlineExceeded` and `NotSent`.

The connect, pool and idle timeouts are unchanged, and `config.with_idle_timeout` still accepts `config.Infinity`.

**Why.** In 0.3 the pool and the body owner enforced the deadline, and the caller waited for them without a bound. A pool that was alive but stuck, for example behind a synchronous telemetry handler, held every caller past every timeout. A handle from `http_gun.named(name)` carries no configuration, so only the call can carry a deadline its caller knows.

**What to do.** Move the request timeout from the configuration to the client handle. Apply it once to the handle the application shares, or per call on a view:

```gleam
// 0.3
let settings =
  config.default()
  |> config.with_request_timeout(config.After(duration.seconds(10)))
let assert Ok(client) = http_gun.start(settings)

// 0.4
let assert Ok(client) = http_gun.start(config.default())
let client = http_gun.with_timeout(client, duration.seconds(10))
```

For a supervised client, apply the view to the handle from `named`, because views are not stored in the pool:

```gleam
let client = http_gun.named(name) |> http_gun.with_timeout(duration.seconds(10))
```

Replace `config.After(d)` with `d` in every `http_gun.with_timeout` call. Code that relied on the 30-second default needs no change.

A long-lived stream such as server-sent events chooses a long timeout and opens a new request when the response ends, as SSE clients already do after a disconnect:

```gleam
// 0.3
let stream = client |> http_gun.with_timeout(config.Infinity)

// 0.4
let stream = client |> http_gun.with_timeout(duration.hours(1))
```

A caller that retries on `DeadlineExceeded` must treat the new `MaybeSent` answer as it treats any other `MaybeSent` failure: send a non-idempotent request again only when the application can prove the server did not act on it. `error.is_retryable(failure, idempotent:)` already makes that distinction.

## Sinal 0.2 binds handlers to their process

**What changed.** HTTP Gun 0.4 depends on Sinal 0.2. In Sinal 0.2, a handler attached with `sinal.observe` or `sinal.attach` belongs to the process that attached it and is removed when that process exits. HTTP Gun's own events are unchanged.

**What to do.** Attach handlers for HTTP Gun lifecycle events (`telemetry.event()`) from a long-lived process, such as one the application supervises, never from a request or a setup function that returns. If the application depends on Sinal directly, move its range to `sinal >= 0.2.0 and < 0.3.0`. The [Sinal migration guide](https://github.com/gleam-dream/sinal/blob/main/docs/MIGRATION.md) lists the rest of Sinal's changes.

## A refusal on a closing connection is not sent

**What changed.** After an HTTP/2 peer sends GOAWAY, Gun refuses new requests on that connection without writing them. HTTP Gun now reports that refusal as `RequestFailed(PeerDraining)` with `NotSent`; in 0.3 it was `MaybeSent`. `PeerDraining` is a network failure, so `error.is_retryable(failure, idempotent: False)` is now true for it. The pool also stops admitting requests to a connection whose peer is going away, so at most the first request after a GOAWAY is refused on each connection.

**Why.** Gun answers a request made in its closing state before any byte reaches the socket. ADR 0023 records the evidence.

**What to do.** Retry code that already follows `error.is_retryable` needs no change; it now sends such a POST again. Code that matched `#(RequestFailed(PeerDraining), MaybeSent)` must match `NotSent` instead.

## Gun's closing timer is off

**What changed.** HTTP Gun sets Gun's `closing_timeout` to `infinity` for HTTP/1.1 and HTTP/2. In 0.3 a streamed response that announced `connection: close`, or that was in flight when an HTTP/2 peer sent GOAWAY, was cut 15 seconds after Gun entered its closing state and failed with `RequestFailed(PeerClosed)` and `MaybeSent`. In 0.4 only the call's deadline, the idle timeout, cancellation, `body.close`, the end of the response or a transport failure ends such a response.

**What to do.** Nothing, unless the application relied on the 15-second cut. Such an application sets the bound it wants with `http_gun.with_timeout` or `config.with_idle_timeout`.

## A verify call can end with `NotAnswered`

**What changed.** `testing.verify` is bounded by the view's deadline. When the client does not answer in time it returns `Error(testing.NotAnswered)`, a new `VerifyError` variant. The client may still be running, and a later `verify` may answer. `ClientStopped` now means only that the client has stopped; in 0.3 a call to a client that did not answer waited without a bound.

**What to do.** Add the variant to every `case` over `VerifyError`, or the code no longer compiles:

```gleam
case testing.verify(client) {
  Ok(verdict) -> verdict
  Error(testing.NotPlayback) -> panic as "not a playback client"
  Error(testing.ClientStopped) -> panic as "client stopped"
  Error(testing.NotAnswered) -> panic as "client did not answer in time"
}
```

## Header names and values are always text

**What changed.** Response, informational and trailer header names and values are `String`s, and a Gleam `String` must be UTF-8. In 0.3 HTTP Gun passed on the bytes the peer sent, so a value such as an ISO-8859-1 filename reached the caller as a `String` that was not text, and `string.lowercase` on it raised. In 0.4 a name or value that is valid UTF-8 is kept as sent, and any other is read as ISO-8859-1, which maps every byte to one code point. A header name with such a byte still fails the token check, and the request ends with `RequestFailed(ProtocolError)`.

**What to do.** Nothing for code that treats header values as text. Code that needs the original bytes of a converted value encodes the string back to ISO-8859-1. Header byte limits now count the converted text, so a converted value counts up to twice its size on the wire.

## Other behaviour changes

- `body.next_within` ends within its wait plus half a second even when the body owner cannot answer, and returns `None`. A chunk the owner sent to a read that had already given up is delivered to the next read, so no chunk is skipped.
- A read from the process that owns the body replaces a read it gave up on, instead of failing with `ReadConflict`. A read from another process still fails with `ReadConflict` while a read is pending.
- When `http_gun.batch` cannot read its byte limit from the client before the view's deadline, it runs no request and every position fails with `DeadlineExceeded` and `NotSent`.
- A body owner that exits before it sends the response head no longer leaves the caller waiting. The call fails with `RequestFailed(UnknownTransport)` and `MaybeSent`.
- With a per-origin connection limit of 1, a request that finds the only connection going away waits in the queue for a new connection, and fails with the pool timeout and `NotSent` if none becomes free. In 0.3 it failed at once with `PeerDraining` and `MaybeSent`.
- A burst of requests to an origin with no connection now prepares up to the per-origin limit of connections at once, within the total limit, instead of one at a time. `stats.queued_requests` counts only requests that hold no preparation, so it falls sooner during such a burst. A preparation that fails still fails every request waiting in its lane. A preparation's connect timeout is its own; a request near its deadline at the head of the lane no longer shortens or discards a connection that a later request could use. An HTTP/2 connection waiting for the peer's first SETTINGS counts as a preparation, so a single request no longer opens a second connection meanwhile.
