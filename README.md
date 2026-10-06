# HTTP Gun

HTTP Gun sends HTTP requests and reads byte responses in Gleam on Erlang/OTP.
It provides connection pooling, streamed bodies, bounded collection, offline
playback and live recording through one client type.

## Use the current checkout

HTTP Gun is unreleased. Keep the `http_gun` and `sinal` checkouts beside each
other because this checkout depends on `../sinal`. In an application beside
those directories, add:

```toml
[dependencies]
http_gun = { path = "../http_gun" }
```

The current package requires Gleam 1.18 or newer and targets Erlang. Gun and
Cowlib use qualified patch ranges; see the
[dependency procedure](docs/DEPENDENCY-UPGRADES.md) before widening them.

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

`send` returns `Result(Buffered, error.Failure)`. On success, `buffered.response`
contains the status, ordered headers and `BitArray` body; trailers and negotiated
protocol are separate fields. Non-2xx statuses remain response data. The caller
chooses retry, redirect and decoding behavior.

The example stops the client after either request result. `start` links the
client to its caller; applications that share a client can instead use
[OTP supervision](docs/USAGE.md#lifecycle-and-supervision).

## Defaults and ownership

Clients admit public destinations and use HTTP/1.1 with verified system TLS
trust. Local tests and services must explicitly enable loopback access with
`config.allow_loopback`.

The default request and idle read timeouts are 30 seconds. Connect and pool
wait timeouts are 5 seconds. `send` collects at most 8 MiB per response. Client
views can replace per-call timeouts, add cancellation and narrow destination
policy over the same pool; [all defaults and setters](docs/USAGE.md#defaults)
are listed in the usage guide.

For a streamed response, the process that opens the body owns its reads. Copies
share one cursor. Use `with_response` to close the body on callback return or
exception, or close an explicit `open` body even after reaching EOF.
[Streaming and typed failures](docs/USAGE.md#stream-a-body) show these calls.

## Further use

The [usage guide](docs/USAGE.md) retains configuration, client views, streaming,
batching, destination rules, failure handling, record/playback, redaction and
observations. The [ordinary consumer](examples/ordinary/src/http_gun_consumer.gleam)
demonstrates these through public imports in a separate package. The
[asynchronous feed recipe](examples/async/README.md) adds application-owned jobs,
sinks and cancellation.

[Historical local benchmarks](examples/comparison/README.md#retained-measurements)
include elapsed times, workloads, environment receipts and reproduction commands.

Streamed uploads, redirect following, decompression, proxies, mTLS, cookie/cache
adapters and generic SSE parsing remain pending capabilities in the
[design](docs/design/design.typ); this checkout does not expose those APIs.

## Development

```sh
./dev/env sh dev/gate fast
./dev/env sh dev/gate full
sh dev/matrix
```

Fast checks formatting, compilation, tests and native boundaries. Full adds
separate consumers, real HTTP/2, batch, recording and load checks. The matrix
runs isolated gates on each selected runtime. These use local servers and
temporary fixtures; [TESTING.md](docs/TESTING.md) gives the exact procedures.

The [design source](docs/design/design.typ),
[rendered design](docs/design/design-layer.pdf),
[vocabulary](docs/design/CONTEXT.typ), [coverage](docs/COVERAGE.md) and
[decision records](docs/adr/0001-gleam-owns-exchange-state.md) describe the package
contracts. [CHANGELOG.md](CHANGELOG.md) records changes.
