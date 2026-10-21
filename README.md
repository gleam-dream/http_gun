# HTTP Gun

HTTP Gun sends HTTP requests and reads byte responses in Gleam on Erlang/OTP.
It provides connection pooling, streamed bodies, bounded collection, offline
playback and live recording through one client type.

## Use the current checkout

HTTP Gun is unreleased. Gleam fetches Sinal from its Git repository on `main`, and `manifest.toml` locks the commit; no
sibling Sinal checkout is needed. To use a local HTTP Gun checkout from
an adjacent application, add:

```toml
[dependencies]
http_gun = { path = "../http_gun" }
```

The package requires Gleam 1.18 or newer and targets Erlang. Gun and Cowlib use
qualified patch ranges that the design's foreign-boundary section governs.

## Send a request

This runnable consumer starts a local fixture with `server()` and permits its
loopback address through `local_config()`. The full source supplies these helpers.

<!-- prettier-ignore-start -->

<!-- snips: examples/ordinary/src/http_gun_consumer.gleam#send-request -->
```gleam
let req = local_request(server())
// The common path: start a client, send, read the collected response, stop.
let assert Ok(client) = http_gun.start(local_config())
let assert Ok(reply) = http_gun.send(client, req)
let assert 200 = reply.response.status
let assert <<"abc":utf8>> = reply.response.body
http_gun.stop(client)
```

<!-- prettier-ignore-end -->

`send` returns `Result(Buffered, error.Failure)`. On success, `buffered.response`
contains the status, ordered headers and `BitArray` body; trailers and negotiated
protocol are separate fields. Non-2xx statuses remain response data. The caller
chooses retry, redirect and decoding behavior.

`start` links the client to its caller. Applications that share a client run it
under supervision:

<!-- prettier-ignore-start -->

<!-- snips: examples/ordinary/src/http_gun_consumer.gleam#supervision -->
```gleam
fn supervised(req: request.Request(BitArray)) -> Nil {
  let name = process.new_name("http_client")
  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(http_gun.supervised(local_config(), name))
    |> static_supervisor.start
  let client = http_gun.named(name)
  consume(client, req)
}

```

<!-- prettier-ignore-end -->

## Configure a client

A `Config` is opaque: start from `config.default()` and set only what you need.
Every timeout takes a `gleam/time/duration.Duration`; `config.Infinity` lifts the
request or idle timeout explicitly.

<!-- prettier-ignore-start -->

<!-- snips: examples/ordinary/src/usage_configure.gleam#configure -->
```gleam
let settings =
  config.default()
  |> config.with_protocol(config.PreferHttp2)
  |> config.with_connect_timeout(duration.seconds(3))
  |> config.with_request_timeout(config.After(duration.seconds(10)))
  |> config.with_max_response_body_bytes(1_048_576)
```

<!-- prettier-ignore-end -->

Clients admit public destinations over HTTP/1.1 with verified system TLS trust.
Local tests and services enable loopback access with `config.allow_loopback` or
`config.with_destination(destination.loopback_only())`. Capacities, timeouts
and every other default are listed in the design.

Per-call settings are client views over the same pool. `with_timeout`,
`with_deadline`, `with_idle_timeout`, `with_cancellation`, `with_body_limit`,
`with_destination` and `with_correlation` each return a new handle.

<!-- prettier-ignore-start -->

<!-- snips: examples/ordinary/src/usage_views.gleam#client-view -->
```gleam
let order = correlation.unique()
let stream =
  client
  |> http_gun.with_timeout(config.Infinity)
  |> http_gun.with_idle_timeout(config.After(duration.seconds(60)))
  |> http_gun.with_correlation(order)
```

<!-- prettier-ignore-end -->

A TLS client identity comes from `client_identity.from_pem(chain, key)` and is
selected with `config.with_client_identity`. Each client owns one immutable
identity; rotation starts a new client.

## Stream a body

<!-- prettier-ignore-start -->

<!-- snips: examples/ordinary/src/usage_views.gleam#stream-body -->
```gleam
let assert Ok(3) = {
  use response <- http_gun.with_response(stream, req, fn(failure) { failure })
  count(response.body, 0)
}
```

<!-- prettier-ignore-end -->

The helper reads until the stream ends:

<!-- prettier-ignore-start -->

<!-- snips: examples/ordinary/src/usage_views.gleam#count-body -->
```gleam
fn count(stream: body.Body, total: Int) -> Result(Int, error.Failure) {
  case body.next(stream) {
    Ok(body.Chunk(bytes)) -> count(stream, total + bit_array.byte_size(bytes))
    Ok(body.End(..)) -> Ok(total)
    Error(failure) -> Error(failure)
  }
}

```

<!-- prettier-ignore-end -->

The process that opens the body owns its reads, and copies share one cursor.
`with_response` closes the body when the callback returns or raises; an explicit
`open` body is closed by the caller even after EOF. `batch(client, requests,
concurrency)` runs at most `concurrency` requests at once and returns results in
input order.

## Handle failures

A `Failure` is opaque. Branch on its closed `Kind` and ask whether a retry is
safe. This consumer uses `unused_port()` to provoke a failure before sending:

<!-- prettier-ignore-start -->

<!-- snips: examples/ordinary/src/http_gun_consumer.gleam#retry-evidence -->
```gleam
let assert Error(unreachable) =
  http_gun.send(client, local_request(unused_port()))
let assert error.Network = error.kind(unreachable)
let assert error.NotSent = error.evidence(unreachable)
let assert True = error.is_retryable(unreachable, idempotent: False)
```

<!-- prettier-ignore-end -->

Every failure carries submission evidence, `NotSent` or `MaybeSent`. A
`MaybeSent` failure is retryable only for an idempotent request.
`error.status` and `error.headers` keep the response head after a collection
failure, with credential headers redacted.

## Test without a network

`http_gun/testing` starts an offline client from a script, and `http_gun/cassette`
records live exchanges to a JSON file that loads back as a script. This excerpt
uses the request, temporary path and redaction settings prepared by the runnable
example:

<!-- prettier-ignore-start -->

<!-- snips: examples/ordinary/src/usage_offline.gleam#record-and-load -->
```gleam
let assert Ok(cassette.Recorded(client:, recording:)) =
  cassette.record(settings, path, cassette.options())
let assert Ok(_) = http_gun.send(client, req)
let assert Ok(_) = cassette.finish(recording, duration.seconds(5))
http_gun.stop(client)

let assert Ok(script) = cassette.load(path, 1_048_576)
let encoded = cassette.encode(script)
remove_fixture(path)
let assert False = string.contains(encoded, "secret")
let assert True = string.contains(encoded, "token=REDACTED&page=2")
let assert Ok(replay) = testing.playback(script, settings)
let assert Ok(buffered) = http_gun.send(replay, req)
let assert <<"abc":utf8>> = buffered.response.body
http_gun.stop(replay)
```

<!-- prettier-ignore-end -->

Playback never opens a connection. A mismatch fails with `PlaybackMismatch` and
keeps the exchange. Cassettes omit credential headers; `config.with_redaction`
adds headers, query parameters and body rewriting.

## Observe requests

Each request emits `[http_gun, lifecycle]` events through `sinal.emit`.
`config.with_label` puts a label in each event so a node-wide handler can filter,
and `config.with_observations` sends one client's events to a forwarder.

## Examples

Each topic above has a compiled example in a separate package that imports only
public modules. The gate builds and runs them, so they stay current with the
library. The snippets in this README come from those executable consumers.

| Topic                                               | Example                                                                  |
| --------------------------------------------------- | ------------------------------------------------------------------------ |
| Defaults, configuration and validation              | [`usage_configure`](examples/ordinary/src/usage_configure.gleam)         |
| Client views, streamed bodies, limits and batches   | [`usage_views`](examples/ordinary/src/usage_views.gleam)                 |
| Destination policies, plaintext rules and tenants   | [`usage_destinations`](examples/ordinary/src/usage_destinations.gleam)   |
| Scripted playback, failures with a head, redaction  | [`usage_offline`](examples/ordinary/src/usage_offline.gleam)             |
| Supervision, failure handling, observations, replay | [`http_gun_consumer`](examples/ordinary/src/http_gun_consumer.gleam)     |
| Cancellation by application and operation           | [`cancellation_checks`](examples/ordinary/src/cancellation_checks.gleam) |
| TLS client identities and rotation                  | [mutual TLS consumer](examples/mtls/README.md)                           |
| Application-owned jobs, sinks and shutdown          | [asynchronous feed recipe](examples/async/README.md)                     |

## More

- [Ordinary consumer](examples/ordinary/README.md) runs all the usage examples above through public imports.
- [Oracle references](docs/ORACLE.md) pin what HTTP Gun is compared with, and [benchmarks](docs/BENCHMARKS.md) hold the method and retained measurements.
- [Asynchronous feed recipe](examples/async/README.md) adds application-owned jobs, sinks and cancellation.
- [Mutual TLS consumer](examples/mtls/README.md) demonstrates client identities, independent server trust and rotation.
- [Comparison harness](examples/comparison/README.md) compares HTTP Gun with Dream on local servers.
- [Design](docs/design/design.typ), [vocabulary](docs/design/CONTEXT.typ), [coverage](docs/COVERAGE.md) and [decision records](docs/adr) describe the package contracts. [AGENTS.md](AGENTS.md) lists the gate commands.

Streamed uploads, redirect following, decompression, proxies, cookie and cache
adapters and generic SSE parsing are pending capabilities in the design; this
checkout does not expose those APIs.
