# HTTP Gun

An HTTP client for Gleam on Erlang/OTP, on released Gun. Requests are
`gleam/http/request.Request(BitArray)`; responses keep status codes, duplicate
headers, arbitrary bytes and trailers. Non-2xx statuses are data. There are no
automatic retries, redirects or decompression.

## Send a request

```gleam
import gleam/http/request
import http_gun
import http_gun/config

pub fn main() {
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(req) = request.to("https://example.com/data")
  let result = http_gun.send(client, request.set_body(req, <<>>))
  http_gun.stop(client)
  result
}
```

`send` collects the response into `Buffered`, with its `Response(BitArray)`,
trailers and negotiated protocol. A body over the limit fails with
`LimitExceeded(ResponseBodyBytes, ..)`, and `error.status(failure)` still tells
you the status.

## Defaults

Every wait, read and queue is bounded. Every timeout, deadline and wait takes
a `gleam/time/duration.Duration`; HTTP Gun keeps whole milliseconds and rounds
a sub-millisecond remainder away from zero. An unbounded request or idle
timeout is requested explicitly with `config.Infinity`; a bounded one is
`config.After(duration)`.

| Setting | Default | Change with |
| --- | --- | --- |
| connect, including DNS and TLS | `duration.seconds(5)` | `config.with_connect_timeout` |
| waiting for a pooled connection | `duration.seconds(5)` | `config.with_pool_timeout` |
| request, admission to last byte | `config.After(duration.seconds(30))` | `config.with_request_timeout`, per call `http_gun.with_timeout` or `with_deadline` |
| idle read, no bytes while reading | `config.After(duration.seconds(30))` | `config.with_idle_timeout`, per call `http_gun.with_idle_timeout` |
| idle pooled connection | `duration.seconds(60)` | `config.with_connection_idle_timeout` |
| draining on `stop` | `duration.seconds(5)` | `config.with_shutdown_timeout` |
| destinations | public addresses only | `config.allow_loopback`, `config.with_destination` |
| plaintext `http://` | allowed | `destination.with_plaintext` |
| destination on every view | not required | `config.require_view_destination` |
| protocol / TLS | HTTP/1.1, system CAs, peer and host name verified | `config.with_protocol`, `config.with_trust` |
| connections | 16, 4 per origin, 100 HTTP/2 streams each | `with_max_connections`, `with_max_connections_per_origin`, `with_max_streams_per_connection` |
| open bodies / queued requests | 128 / 128 | `with_max_open_bodies`, `with_max_queued_requests` |
| request body | 1 MiB | `with_max_request_body_bytes` |
| headers | 16 KiB, 100 | `with_max_header_bytes`, `with_max_header_count` |
| buffered response bytes | 128 KiB | `with_max_buffered_bytes` |
| collected response body (`send`) | 8 MiB | `with_max_response_body_bytes`, per call `http_gun.with_body_limit` |
| `batch` | 1–1,024 workers, 10,000 requests, 64 MiB retained | `with_max_batch_bytes` |
| scripts and cassettes | 16 MiB | `cassette.load`/`parse` take a byte limit; `cassette.with_max_bytes` |
| cassette redaction | credential headers | `config.with_redaction` |
| observations | `sinal.emit`, following the application's routes | `config.with_observations`, `config.without_observations` |
| client label in events | none | `config.with_label` |

Each phase is also capped by the time left in the request. Lifting the request
timeout never lifts the connect, pool or idle timeouts. [BOUNDS.md](BOUNDS.md)
states where each limit is enforced and what it does not bound.

## Configure

A `Config` is opaque: start from `config.default()` and set only what you
need, so a new option never breaks your code.

```gleam
let settings =
  config.default()
  |> config.with_protocol(config.PreferHttp2)
  |> config.with_request_timeout(config.After(duration.seconds(10)))
  |> config.with_max_response_body_bytes(1_048_576)
```

`http_gun.start` validates it and returns `InvalidConfig(ConfigError)` for an
out-of-range value; `config.validate` checks it without starting anything.

## Client views

Per-call settings live on the handle. Each view returns a new handle over the
same pool, and `send`, `open`, `with_response` and `batch` all honour it.

```gleam
let stream =
  client
  |> http_gun.with_timeout(config.Infinity)  // a long-lived SSE stream
  |> http_gun.with_idle_timeout(config.After(duration.seconds(60)))
  |> http_gun.with_correlation(order)
```

| View | Effect |
| --- | --- |
| `with_timeout(client, timeout)` | replaces the request timeout, shorter or longer |
| `with_deadline(client, deadline)` | an absolute budget shared across calls; replaces the request timeout |
| `with_idle_timeout(client, timeout)` | replaces the idle timeout, for example for a model's first token |
| `with_cancellation(client, token)` | cancels unfinished requests when the token is cancelled |
| `with_body_limit(client, bytes, Fail \| Truncate)` | the collection limit; `Fail` keeps the status and headers on the failure, `Truncate` keeps them and a prefix |
| `with_destination(client, policy)` | narrows the destinations; never widens them |
| `with_correlation(client, correlation)` | tags lifecycle events with a `sinal/correlation.Correlation` |

`http_gun.correlation(client)` reads a view's correlation. A library that
receives a caller's view reads the caller's correlation there and copies it
into its own telemetry, so the caller sets it once.

## Stream a body

```gleam
use response <- http_gun.with_response(client, req, fn(failure) { failure })
count(response.body, 0)

fn count(stream: body.Body, total: Int) -> Result(Int, error.Failure) {
  case body.next(stream) {
    Ok(body.Chunk(bytes)) -> count(stream, total + bit_array.byte_size(bytes))
    Ok(body.End(..)) -> Ok(total)
    Error(failure) -> Error(failure)
  }
}
```

`with_response` closes the body when the callback returns or raises, and maps
an opening failure into the callback's error type. `body.next` waits until
bytes arrive, bounded by the request and idle timeouts. `body.next_within`
waits at most a given `Duration` and returns `Ok(None)`, leaving the stream
intact.
`open` returns the response for you to close.

The opening process owns the body: a read from another process fails with
`WrongOwner`, a concurrent read with `ReadConflict`. Copies share one cursor.
Closing cancels the request locally and says nothing about what the server did.

`batch(client, requests, concurrency)` runs at most `concurrency` requests at
once and returns results in input order; a failure occupies only its position.

## Handle failures

A `Failure` is opaque. Branch on its closed `Kind`, and ask whether a retry is
safe:

```gleam
case http_gun.send(client, req) {
  Ok(buffered) -> Ok(buffered.response)
  Error(failure) ->
    case error.kind(failure) {
      error.Refused -> Error(BadDestination)
      error.TooLarge -> Error(TooBig(error.status(failure)))
      _ ->
        case error.is_retryable(failure, idempotent: False) {
          True -> Error(TryLater)
          False -> Error(Failed(error.describe(failure)))
        }
    }
}
```

Every failure carries submission evidence: `NotSent` or `MaybeSent`. A
`NotSent` failure of kind `Unavailable`, `Network` or `TimedOut` is safe to
retry; a `MaybeSent` one only for an idempotent request. `error.Reason` gives
the detail and may gain variants, so match it with a `_` arm. `error.name`
is a stable identifier such as `"connection_failed.connection_refused"`, and
`error.to_json` with `error.decoder` stores and restores a failure. A failure
never holds a URL, query or body, nor a request header.

A `send` or `batch` failure after the response head arrived keeps its status
and headers, so a 429 whose body exceeded `with_body_limit(_, _, Fail)` still
says when to retry. The client's redaction (`config.with_redaction`) removes
its listed headers first, the credential headers by default:

```gleam
case error.status(failure), list.key_find(error.headers(failure), "retry-after") {
  Some(429), Ok(seconds) -> snooze(seconds)
  _, _ -> give_up(failure)
}
```

## Destinations

The default admits public addresses only. The three local setups are one line
each:

```gleam
config.default() |> config.allow_loopback                       // public and loopback
config.default() |> config.with_destination(destination.loopback_only())
config.default()
|> config.with_destination(
  destination.loopback_only() |> destination.only_hosts(["127.0.0.1:8080"]),
)
```

`only_hosts` entries are `"host"` (every port) or `"host:port"`. Reserved and
cloud metadata addresses are always refused. A host name is resolved once per
connection; every A and AAAA address must pass the policy, and Gun connects to
the checked address with the original TLS identity. `destination.check` applies
a policy without resolving names; `config.with_resolver` replaces DNS in tests.

`destination.with_plaintext` decides whether `http://` is admitted, against the
same resolved addresses: `AllowPlaintext` (the default), `PlaintextToLoopbackOnly`
(every resolved address must be loopback, so `http://localhost` passes) or
`RequireTls`. A refused request fails with
`DestinationRejected(PlaintextRefused(class))`, kind `Refused`, and `NotSent`.
`https://` is never affected.

### One client for several tenants

A view can only narrow the client's policy, so a client shared by tenants with
different destinations must admit their union, for example public hosts and
loopback. Any call that holds the client without the tenant's view reaches
that union. `config.require_view_destination` closes the gap: a request whose
view has not chosen a destination fails with `ViewDestinationRequired` and
`NotSent` before anything is resolved or sent. A view chooses one when a
`with_destination` policy sets `only_hosts` or refuses an address class the
client admits. A policy that only tightens `with_plaintext` chooses none, so
a library that tightens the scheme on a tenant's view keeps the requirement.
The client's policy then only bounds what a view may narrow to.

```gleam
let assert Ok(client) =
  config.default()
  |> config.allow_loopback                 // the union: public and loopback
  |> config.require_view_destination       // a call without a view fails closed
  |> http_gun.start

fn for_tenant(client: http_gun.Client, tier: Tier) -> http_gun.Client {
  case tier {
    Public -> client |> http_gun.with_destination(destination.default())
    Internal(hosts) ->
      client
      |> http_gun.with_destination(
        destination.loopback_only() |> destination.only_hosts(hosts),
      )
  }
}

for_tenant(client, tier) |> http_gun.send(req)  // narrowed to the tier
http_gun.send(client, req)                      // Error: ViewDestinationRequired
```

A view that admits more than the client, such as `allow_private` on this
client, still gets only what both admit. The requirement also holds for
recording and playback clients built from the same configuration, so a test
catches a call that skips the view.

## Lifecycle and supervision

`start` links the client to the caller. Under a supervisor, name it:

```gleam
let name = process.new_name("http_client")
let assert Ok(_) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(http_gun.supervised(config.default(), name))
  |> static_supervisor.start
let client = http_gun.named(name)  // keeps working across restarts
```

During a restart, calls fail with `ClientClosed` and `NotSent`. `stop`
refuses new requests, fails queued ones, lets open responses finish within the
shutdown timeout, then cancels them and closes the connections.

## Test without a network

`http_gun/testing` starts an offline client from a script:

```gleam
let script =
  testing.script([
    testing.exchange(
      req,
      testing.Respond(
        response.new(200) |> response.set_body([<<"{\"ok\":true}">>]),
        testing.Finished([]),
      ),
    ),
  ])
let assert Ok(client) = testing.playback(script, config.default())
```

Requests match the next exchange exactly; `testing.ignoring_headers` and
`testing.matching` relax it. A mismatch fails with `PlaybackMismatch(position)`
and keeps the exchange; a request after the last fails with
`PlaybackExhausted`. Playback never opens a connection and skips the
destination policy.

`http_gun/cassette` records live exchanges to a readable JSON file and loads it
back as a script:

```gleam
let assert Ok(cassette.Recorded(client:, recording:)) =
  cassette.record(settings, "test/orders.json", cassette.options())
// ... make requests ...
let assert Ok(_) = cassette.finish(recording, duration.seconds(5))

let assert Ok(script) = cassette.load("test/orders.json", 1_048_576)
let assert Ok(client) = testing.playback(script, settings)
```

## Redaction

Cassettes never store the credential headers `authorization`,
`proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`, `api-key` and
`x-goog-api-key`. Add your own:

```gleam
let redaction =
  redaction.default()
  |> redaction.with_headers(["x-signature"])
  |> redaction.with_query_parameters(["token"])
  |> redaction.with_body(scrub)
let settings = config.default() |> config.with_redaction(redaction)
```

Recording stores the redacted form, and playback applies the same redaction to
both sides before matching, so a redacted cassette still matches the code that
recorded it. A body function sees each request body and each whole response
body, so a secret split across chunks is still found. Failures and telemetry
never contain URLs, headers, queries or bodies, and a waiting request is held
in a closure that crash reports print as a function reference.

## Observations

Each request emits `[http_gun, lifecycle]` events (`http_gun/telemetry`) with
`sinal.emit`: admission, the Gun call, response headers and termination, with
a `request_id` and the view's `correlation`. Route the prefix to a forwarder at
startup so handlers never run in the pool:

```gleam
forwarder.route(["http_gun"], app_forwarder)
```

`config.with_observations(config, forwarder)` sends one client's events to a
forwarder directly. Events are best effort and never submission evidence.

A node-wide handler sees every client's events, including those of clients
that libraries own. `config.with_label(config, "billing")` puts the label in
each event's `client` field, so a handler can filter:

```gleam
sinal.observe(telemetry.event(), fn(timing, metadata) {
  case metadata.client {
    Some("billing") -> record(timing, metadata)
    _ -> Nil
  }
})
```

A library that starts its own private client labels it with the library's
name (`"warden"`, `"llm_wire"`). It may instead call
`config.without_observations(config)`, after which the client emits nothing;
prefer the label, which leaves the choice to the application.

## Dependencies

`gun >= 2.6.0 and < 2.7.0` and `cowlib >= 2.20.0 and < 2.21.0`: patch ranges,
because the FFI relies on terms the Gun and Cowlib manuals do not document. CI
runs the full gate on the minimum and the newest patch of both. The
[dependency audit](docs/GUN_AUDIT.md) lists each term and what fails if it
changes.

## Validation

```sh
./dev/env sh dev/gate fast  # format, check, build, tests, FFI warnings, boundaries
./dev/env sh dev/gate full  # also consumer packages, nghttpd, batch, recording and load checks
sh dev/matrix              # isolated full gates on each runtime
```

The gates use loopback HTTP/1.1, TLS and HTTP/2 servers and temporary
fixtures, with no provider credentials. The
[ordinary consumer](examples/ordinary/src/http_gun_consumer.gleam) and the
[asynchronous feed recipe](examples/async/README.md) compile and run as
separate packages against the public API.

Streamed uploads, redirects, decompression, proxies, mTLS, cookies and SSE
parsing are out of scope for this release. See the [design](docs/DESIGN.md),
the [CHANGELOG](CHANGELOG.md), the [wave 3 migration guide](docs/migration-wave-3.md)
and the construction [history](docs/history/README.md).
