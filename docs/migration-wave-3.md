# Wave 3 migration

Wave 3 is HTTP Gun's release API redesign (HTTPGUN-R1 to R10 in oversight
`docs/release-api/http_gun.md`). It breaks every dependent. The changes, in
one line each:

- every value a caller builds is opaque with `with_*` setters: `config.Config`,
  `destination.Policy`, `redaction.Redaction`, `cassette.RecordOptions`;
- per-call settings are client views; the `_with_options` twins and
  `http_gun/request_options` are gone;
- timeouts are named: connect including DNS, pool, request, idle, idle
  connection and shutdown; a view's timeout may be longer than the client's;
- `error.Failure` is opaque with a closed `Kind`, `is_retryable`, `status`,
  `name`, `to_json` and `decoder`;
- `supervised(config, name)` and `named(name)` replace `child`;
- `http_gun/fixture` merged into `http_gun/testing`, `http_gun/recording` into
  `http_gun/cassette`, and cassettes move to schema 2;
- redaction is configurable; observations default to `sinal.emit`, and a
  client can carry a label or emit nothing.

Four changes are easy to miss, because most still compile:

- `config.allow_loopback` alone also leaves public hosts allowed. The old
  `allow_loopback` plus nested `Policy(.., allow_public: False)` update is
  `config.with_destination(destination.loopback_only())`. See
  [destination](#http_gundestination).
- A stopped client reports `ClientClosed` as `NotSent`; it was `MaybeSent`.
  A client that exits while handling the call still reports `MaybeSent`. See
  [error](#http_gunerror).
- `stop` returns `Nil`. `let _ = http_gun.stop(c)` still compiles and can
  become `http_gun.stop(c)`; `let assert Ok(Nil) = http_gun.stop(c)` does not
  compile. See [http_gun](#http_gun).
- `cassette.parse` reads a body or chunk from `text` (UTF-8) or `base64`; the
  `bytes` count is gone, so a test that drops each required key lists `text`
  instead of `bytes` and `base64`. See
  [cassette files](#cassette-files-schema-1-to-2).

Contents: [http_gun](#http_gun) · [config](#http_gunconfig) ·
[destination](#http_gundestination) · [error](#http_gunerror) ·
[body](#http_gunbody) · [deadline](#http_gundeadline) ·
[cancellation](#http_guncancellation) ·
[request_options](#http_gunrequest_options-removed) ·
[testing and fixture](#http_guntesting-absorbs-http_gunfixture) ·
[cassette and recording](#http_guncassette-absorbs-http_gunrecording) ·
[cassette files](#cassette-files-schema-1-to-2) · [redaction](#http_gunredaction-new) ·
[telemetry](#http_guntelemetry) · [index of dependents](#index-of-symbols-each-dependent-uses)

## `http_gun`

| Before                                                         | After                                                                                                                                                 |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `start(config) -> Result(Client, Failure)`                     | `start(config) -> Result(Client, StartError)`                                                                                                         |
| `child(config) -> ChildSpecification(Client)`                  | `supervised(config, name) -> ChildSpecification(Client)` and `named(name) -> Client`                                                                  |
| `stop(client) -> Result(Nil, Failure)`                         | `stop(client) -> Nil`; drains open bodies for the shutdown timeout                                                                                    |
| `send_with_options(client, req, options)`                      | `send(client \|> views.., req)`                                                                                                                       |
| `open_with_options(client, req, options)`                      | `open(client \|> views.., req)`                                                                                                                       |
| `with_response(client, req, run)`                              | `with_response(client, req, on_failure, run)`; `run` returns `Result`                                                                                 |
| `try_with_response(client, req, on_error, consume)`            | `with_response(client, req, on_error, consume)`                                                                                                       |
| `with_response_with_options`, `try_with_response_with_options` | `with_response` on a view                                                                                                                             |
| `snapshot(client)`                                             | `stats(client)`                                                                                                                                       |
| `Stats(connections, bodies, waiting)`                          | `Stats(connections, open_bodies, queued_requests)`                                                                                                    |
| `request_ceiling_ms(client)`                                   | removed                                                                                                                                               |
| `request_options.Overflow` (`Fail`, `Truncate`)                | `http_gun.Overflow` (`Fail`, `Truncate`)                                                                                                              |
| —                                                              | views `with_timeout`, `with_deadline`, `with_idle_timeout`, `with_cancellation`, `with_body_limit`, `with_destination` (`with_correlation` unchanged) |
| —                                                              | `StartError`, `describe_start_error`, `Message`                                                                                                       |

`StartError` is `InvalidConfig(config.ConfigError)`, `InvalidScript(position)`,
`ScriptTooLarge(limit, observed)` or `StartFailed`.

```gleam
// Before
let assert Ok(client) = http_gun.start(settings)
let _ = http_gun.stop(client)

// After
let assert Ok(client) = http_gun.start(settings)
http_gun.stop(client)
```

A supervised client registers under a name, and the handle survives restarts.
This replaces warden's `persistent_term` shim:

```gleam
// Before
let child =
  http_gun.child(settings)
  |> supervision.map_data(fn(client) { persistent_term_put(key, client) client })

// After
let name = process.new_name("warden_http")
let child = http_gun.supervised(settings, name)
// anywhere, at any time:
let client = http_gun.named(name)
```

Per-call options become views:

```gleam
// Before
let options =
  request_options.Options(
    ..request_options.default(),
    deadline: Some(budget),
    cancellation: Some(token),
    collect: Some(request_options.Collect(1024, request_options.Truncate)),
  )
http_gun.send_with_options(client, req, options)

// After
client
|> http_gun.with_deadline(budget)
|> http_gun.with_cancellation(token)
|> http_gun.with_body_limit(1024, http_gun.Truncate)
|> http_gun.send(req)
```

The deadline rule changed: a view's deadline or timeout **replaces** the
client's request timeout, so a 600 s LLM budget is no longer cut to the
client's 30 s. With both `with_timeout` and `with_deadline`, the earlier wins.

```gleam
// Before: the stream needed a dedicated client with a long ceiling.
let assert Ok(streams) =
  http_gun.start(config.Config(..settings, deadline_ms: 3_600_000))

// After: one client; this view lifts only the overall bound.
let stream = client |> http_gun.with_timeout(config.Infinity)
```

Scoped streaming takes an error mapper:

```gleam
// Before
http_gun.try_with_response(client, req, fn(f) { HttpError(f) }, fn(response) {
  read(response.body)
})
http_gun.with_response(client, req, fn(response) { count(response.body) })

// After
http_gun.with_response(client, req, HttpError, fn(response) {
  read(response.body)
})
http_gun.with_response(client, req, fn(f) { f }, fn(response) {
  Ok(count(response.body))
})
```

`batch` keeps its signature. Retained bodies are now bounded by
`config.with_max_batch_bytes` (64 MiB); requests not yet sent when the bound is
reached fail with `LimitExceeded(BatchBytes, ..)` and `NotSent`.

## `http_gun/config`

`Config` is opaque. Record construction, record update and field access stop
compiling; use the setters. `Limits` is gone.

| Before                                      | After                                                                             |
| ------------------------------------------- | --------------------------------------------------------------------------------- |
| `Config(..c, deadline_ms: n)`               | `config.with_request_timeout(c, config.Milliseconds(n))`                          |
| `Config(..c, connect_ms: n)`                | `config.with_connect_timeout(c, n)` (now includes DNS)                            |
| —                                           | `with_pool_timeout(c, ms)`, default 5 s                                           |
| —                                           | `with_idle_timeout(c, Timeout)`, default 30 s                                     |
| —                                           | `with_connection_idle_timeout(c, ms)`, default 60 s                               |
| —                                           | `with_shutdown_timeout(c, ms)`, default 5 s                                       |
| `Config(..c, protocol: p)`                  | `config.with_protocol(c, p)`                                                      |
| `Config(..c, trust: t)`                     | `config.with_trust(c, t)`                                                         |
| `Config(..c, observations: Some(f))`        | `config.with_observations(c, f)`                                                  |
| `Config(..c, observations: None)`           | default; events now go through `sinal.emit` (see [telemetry](#http_guntelemetry)) |
| `Config(..c, destination: p)`               | `config.with_destination(c, p)`                                                   |
| `destination.Policy(.., resolver: Some(r))` | `config.with_resolver(c, r)`                                                      |
| `Limits.connections`                        | `with_max_connections`                                                            |
| `Limits.per_origin`                         | `with_max_connections_per_origin`                                                 |
| `Limits.streams_per_connection`             | `with_max_streams_per_connection`                                                 |
| `Limits.active`                             | `with_max_open_bodies`                                                            |
| `Limits.waiting`                            | `with_max_queued_requests`                                                        |
| `Limits.request_bytes`                      | `with_max_request_body_bytes`                                                     |
| `Limits.head_bytes`                         | `with_max_header_bytes`                                                           |
| `Limits.header_count`                       | `with_max_header_count`                                                           |
| `Limits.chunk_bytes`, `Limits.queue_bytes`  | `with_max_buffered_bytes` (one limit; it also bounds one chunk)                   |
| `Limits.collect_bytes`                      | `with_max_response_body_bytes`                                                    |
| —                                           | `with_max_batch_bytes`, default 64 MiB                                            |
| —                                           | `with_redaction(c, redaction)`                                                    |
| `validate(c) -> Result(Config, String)`     | `validate(c) -> Result(Config, ConfigError)`, `describe_error`                    |
| `config.Config.connect_ms` (read)           | no getter; keep the value in your own code                                        |
| —                                           | `Timeout { Milliseconds(Int) Infinity }`, `Resolver`, `Setting`, `ConfigError`    |

`Protocol`, `Trust` and `Negotiated` keep their constructors.

```gleam
// Before
let defaults = config.default()
let settings =
  config.Config(
    ..defaults,
    deadline_ms: 60_000,
    connect_ms: 2000,
    limits: config.Limits(..defaults.limits, collect_bytes: 1_048_576, active: 8),
    observations: Some(forwarder),
  )

// After
let settings =
  config.default()
  |> config.with_request_timeout(config.Milliseconds(60_000))
  |> config.with_connect_timeout(2000)
  |> config.with_max_response_body_bytes(1_048_576)
  |> config.with_max_open_bodies(8)
  |> config.with_observations(forwarder)
```

`ConfigError` is `OutOfRange(setting: Setting, value: Int)`,
`EmptyTrustAnchors`, `InvalidTrustAnchor` or `InvalidAllowedHost(entry)`.

## `http_gun/destination`

`Policy` is opaque, and the resolver moved to `config.with_resolver`.

| Before                                                                              | After                                                                                                                  |
| ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `Policy(allow_public:, allow_loopback:, allow_private:, allowed_hosts:, resolver:)` | `default()`, `loopback_only()`, `allow_loopback(p)`, `allow_private(p)`, `only_hosts(p, hosts)`                        |
| `allowed_hosts: Some(["host"])` (host only)                                         | `only_hosts(p, ["host", "host:port", "[::1]:8080"])`                                                                   |
| `Resolver`                                                                          | `config.Resolver`; its `Int` is the time left in the connect timeout                                                   |
| `valid`, `permits`, `permits_host` (`@internal`)                                    | `validate(p) -> Result(Policy, String)`, `check(p, host, port) -> Result(Nil, Rejection)`, `check_address(p, address)` |
| `bridge.parse_address` (internal; webhooks used an FFI)                             | `parse_address(text) -> Result(Address, Nil)`                                                                          |
| —                                                                                   | `Rejection { HostNotAllowed AddressRefused(Class) }`                                                                   |

`Address`, `Class` and `classify` are unchanged.

`allow_loopback` adds loopback to the policy it is given and keeps every other
destination, so `config.default() |> config.allow_loopback` still admits
public hosts. To keep a test or local client off the public internet, which
the old `allow_public: False, allow_loopback: True` update did, use
`destination.loopback_only()`:

```gleam
// Before: loopback only
config.Config(
  ..defaults,
  destination: destination.Policy(
    ..defaults.destination,
    allow_public: False,
    allow_loopback: True,
  ),
)

// After: equivalent
config.default() |> config.with_destination(destination.loopback_only())

// Not equivalent: public hosts stay allowed
config.default() |> config.allow_loopback
```

```gleam
// Before: loopback only, pinned to hosts (checkout, research_agent, support_desk)
let defaults = config.default()
let settings =
  config.Config(
    ..defaults,
    destination: destination.Policy(
      ..defaults.destination,
      allow_public: False,
      allow_loopback: True,
      allowed_hosts: Some(["127.0.0.1"]),
    ),
  )

// After: one line, and the port is pinned too
let settings =
  config.default()
  |> config.with_destination(
    destination.loopback_only() |> destination.only_hosts(["127.0.0.1:8080"]),
  )
```

```gleam
// Before: warden built every field
destination.Policy(
  allow_public: True, allow_loopback: False, allow_private: False,
  allowed_hosts: Some(hosts), resolver: Some(resolver),
)

// After
config.default()
|> config.with_destination(destination.default() |> destination.only_hosts(hosts))
|> config.with_resolver(resolver)
```

A view can narrow the policy per call; it never widens it:

```gleam
let tenant = client |> http_gun.with_destination(destination.default() |> destination.only_hosts(tenant_hosts))
```

Because a view only narrows, a client shared by tenants with different
destinations must admit their union, and a call that skips the tenant's view
reaches that union. Add `config.require_view_destination`; see
[Follow-up fixes](#follow-up-fixes).

## `http_gun/error`

`Failure` is opaque. Use the accessors instead of fields and patterns.

| Before                                                                          | After                                                                                                                                                    |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Failure(reason, evidence)` (construct)                                         | `error.new(reason, evidence)`, plus `error.with_status(f, status)`                                                                                       |
| `failure.reason`, `failure.evidence`                                            | `error.reason(failure)`, `error.evidence(failure)`                                                                                                       |
| `Failure(evidence: MayHaveBeenSent, ..)` (pattern)                              | `error.evidence(failure) == error.MaybeSent`                                                                                                             |
| `NotSubmitted`, `MayHaveBeenSent`                                               | `NotSent`, `MaybeSent`                                                                                                                                   |
| —                                                                               | `status(f) -> Option(Int)`, `kind(f) -> Kind`, `is_retryable(f, idempotent:)`, `name(f)`, `to_json(f)`, `decoder()`                                      |
| `InvalidConfig(String)`                                                         | removed; `http_gun.InvalidConfig(config.ConfigError)` at start                                                                                           |
| `InvalidRequest(String)`                                                        | `InvalidRequest(RequestProblem)`: `BodyNotBytes`, `InvalidMethod`, `InvalidOrigin`, `InvalidTarget`, `InvalidHeader`, `InvalidBodyLimit`, `InvalidBatch` |
| `DestinationRejected`                                                           | `DestinationRejected(destination.Rejection)`                                                                                                             |
| `ReadTimeout`                                                                   | removed; `body.next_within` returns `Ok(None)`                                                                                                           |
| —                                                                               | `PoolTimeout`, `ConnectTimeout`, `IdleTimeout`                                                                                                           |
| `FixtureMissing`, `FixtureIo(op, cause)`, `FixtureCorrupt`, `FixtureVersion(v)` | `cassette.CassetteError`: `Missing`, `Io(op, cause)`, `Corrupt`, `UnsupportedVersion(v)`, `TooLarge(limit, observed)`                                    |
| `FixtureExhausted`                                                              | `PlaybackExhausted`                                                                                                                                      |
| `FixtureMismatch(position)`                                                     | `PlaybackMismatch(position)`                                                                                                                             |
| `CaptureFailed(String)`                                                         | `RecordingClosed`                                                                                                                                        |
| `LimitKind.CollectedBodyBytes`                                                  | `ResponseBodyBytes`                                                                                                                                      |
| `LimitKind.ResponseQueueBytes`                                                  | `BufferedBytes`                                                                                                                                          |
| `LimitKind.ResponseChunkBytes`                                                  | removed; `BufferedBytes` bounds a chunk                                                                                                                  |
| `LimitKind.FixtureBytes`                                                        | removed; `http_gun.ScriptTooLarge` or `cassette.TooLarge`                                                                                                |
| —                                                                               | `LimitKind.BatchBytes`                                                                                                                                   |
| `FileOperation`, `FileCause`                                                    | `cassette.FileOperation`, `cassette.FileCause` (`PublishFixture` is `PublishFile`)                                                                       |
| `file_description`                                                              | `cassette.describe_error`                                                                                                                                |

A request on a stopped client fails with `ClientClosed` and `NotSent`; it was
`MaybeSent`. Nothing reaches the network once the client has stopped. A client
that exits while it handles the call still reports `MaybeSent`. A test that
pins `error.new(error.ClientClosed, error.MaybeSent)` for a stopped client
needs `NotSent`.

Unchanged reasons: `ClientClosed`, `AdmissionFull`, `ResolutionFailed`,
`ConnectionFailed(cause)`, `RequestFailed(cause)`, `DeadlineExceeded`,
`ReadConflict`, `WrongOwner`, `Closed`, `Cancelled`,
`LimitExceeded(kind, limit, observed)`, and every `TransportCause`.

`Kind` is closed: `InvalidInput`, `Refused`, `Unavailable`, `Network`,
`TimedOut`, `TooLarge`, `CancelledLocally`, `Misuse`, `Playback`. `Reason`,
`TransportCause`, `LimitKind` and `RequestProblem` may gain variants in minor
releases: match them with a `_` arm.

An exhaustive `Reason` match (warden's `from_gun`, webhooks' `classify_failure`)
becomes a `Kind` match plus the detail arms you need:

```gleam
// Before: 22 arms, broken by every new reason
case failure.reason {
  error.InvalidConfig(_) -> Misconfigured
  error.ClientClosed | error.AdmissionFull -> Unavailable
  error.ConnectionFailed(_) | error.RequestFailed(_) -> Transport
  error.DeadlineExceeded | error.ReadTimeout -> Timeout
  // ... 15 more
}

// After
case error.kind(failure) {
  error.TimedOut -> Timeout
  error.Network -> Transport
  error.Unavailable -> Unavailable
  error.Refused -> Forbidden
  error.TooLarge -> TooLarge(error.status(failure))
  error.InvalidInput | error.Misuse -> Bug(error.describe(failure))
  error.CancelledLocally -> Cancelled
  error.Playback -> Bug(error.describe(failure))
}
```

The retry rule three apps wrote is built in:

```gleam
// Before
case failure.evidence, failure.reason {
  error.NotSubmitted, _ -> True
  error.MayHaveBeenSent, _ -> idempotent
}

// After
error.is_retryable(failure, idempotent: idempotent)
```

A hand-written failure codec (checkout `codecs.gleam`, 129 lines) and a naming
table (webhooks `failure_name`, 52 lines) become:

```gleam
let stored = error.to_json(failure) |> json.to_string
let assert Ok(restored) = json.parse(stored, error.decoder())
error.name(failure) // "connection_failed.connection_refused"
```

An oversized collected body now keeps the status (WHK-3):

```gleam
// Before: no status; Truncate was the only way to read it
let assert Error(error.Failure(error.LimitExceeded(error.CollectedBodyBytes, _, _), _)) =
  http_gun.send(client, req)

// After
let assert Error(failure) = http_gun.send(client, req)
let assert error.LimitExceeded(error.ResponseBodyBytes, _, _) = error.reason(failure)
error.status(failure) // Some(200)
```

## `http_gun/body`

| Before                                                                                       | After                                                                                       |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `next(body, wait_ms) -> Result(Event, Failure)`                                              | `next(body) -> Result(Event, Failure)`, bounded by the request and idle timeouts            |
| `next(body, wait_ms)` returning `ReadTimeout`                                                | `next_within(body, wait_ms) -> Result(Option(Event), Failure)`; `Ok(None)` keeps the stream |
| `close(body) -> Result(Nil, Failure)`                                                        | `close(body) -> Nil`                                                                        |
| `collect(body, limit)` failure `LimitExceeded(CollectedBodyBytes, ..)`                       | `LimitExceeded(ResponseBodyBytes, ..)` with `error.status`                                  |
| `collect_prefix`, `start`, `check_headers`, `authority`, `Input`, `HeaderKind` (`@internal`) | internal                                                                                    |

`Event`, `Collected` and `protocol` are unchanged.

```gleam
// Before
case body.next(stream, 5000) {
  Ok(body.Chunk(bytes)) -> ..
  Ok(body.End(_)) -> ..
  Error(error.Failure(error.ReadTimeout, _)) -> keep_waiting()
  Error(failure) -> ..
}

// After: let the idle timeout bound the wait ..
case body.next(stream) {
  Ok(body.Chunk(bytes)) -> ..
  Ok(body.End(_)) -> ..
  Error(failure) -> ..
}
// .. or poll with a local wait
case body.next_within(stream, 5000) {
  Ok(Some(body.Chunk(bytes))) -> ..
  Ok(Some(body.End(_))) -> ..
  Ok(None) -> keep_waiting()
  Error(failure) -> ..
}
```

## `http_gun/deadline`

| Before                                   | After                                                |
| ---------------------------------------- | ---------------------------------------------------- |
| `after(ms) -> Result(Deadline, Failure)` | `after(ms) -> Deadline`; zero or negative is expired |
| `timestamp(deadline)` (`@internal`)      | removed                                              |

```gleam
// Before
let assert Ok(budget) = deadline.after(60_000)
// After
let budget = deadline.after(60_000)
```

## `http_gun/cancellation`

| Before                                      | After                                            |
| ------------------------------------------- | ------------------------------------------------ |
| `with_token(run) -> Result(value, Failure)` | `with_token(run) -> value`; cannot fail          |
| `try_with_token(on_start_error, run)`       | `with_token(run)`                                |
| `cancel(token)` waits for the token process | returns at once (an asynchronous latch)          |
| `is_cancelled`, `monitor` (`@internal`)     | `is_cancelled(token)` public; `monitor` internal |

```gleam
// Before
use token <- cancellation.try_with_token(fn(_) { StartFailed })
// After
use token <- cancellation.with_token
```

## `http_gun/request_options` (removed)

| Before                                                     | After                                                                          |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `Options(deadline:, cancellation:, collect:)`, `default()` | views on the client                                                            |
| `Options(deadline: Some(d))`                               | `http_gun.with_deadline(client, d)`                                            |
| `Options(cancellation: Some(t))`                           | `http_gun.with_cancellation(client, t)`                                        |
| `Collect(limit, Fail)` / `Collect(limit, Truncate)`        | `http_gun.with_body_limit(client, limit, http_gun.Fail)` / `http_gun.Truncate` |
| `Overflow`, `Fail`, `Truncate`                             | `http_gun.Overflow`, `http_gun.Fail`, `http_gun.Truncate`                      |
| `cancelled` (`@internal`)                                  | `cancellation.is_cancelled`                                                    |

## `http_gun/testing` (absorbs `http_gun/fixture`)

| Before                                                         | After                                                                                             |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `fixture.Exchange(request, reply)`                             | `testing.exchange(request, reply)`; it drops credential headers from the stored request           |
| `exchange.request`, `exchange.reply`                           | `testing.request(exchange)`, `testing.reply(exchange)` (the field `exchange.request` still reads) |
| `fixture.Respond(response, ending)`, `fixture.Reject(failure)` | `testing.Respond(response, ending)`, `testing.Reject(failure)`                                    |
| `fixture.Complete(trailers)`                                   | `testing.Finished(trailers)`                                                                      |
| `fixture.Failed(failure)`                                      | `testing.Aborted(failure)`                                                                        |
| `fixture.Cancelled`                                            | `testing.Abandoned`                                                                               |
| `fixture.Reply`, `fixture.Ending`                              | `testing.Reply`, `testing.Ending`                                                                 |
| `testing.start(config, exchanges) -> Result(Client, Failure)`  | `testing.playback(testing.script(exchanges), config) -> Result(Client, http_gun.StartError)`      |
| `fixture.matches(a, b)`                                        | `testing.match_key(r, a) == testing.match_key(r, b)`                                              |
| `fixture.sanitise(req)`                                        | `testing.match_key(redaction.default(), req)`                                                     |
| `fixture.safe_headers(headers)`                                | `redaction.headers(redaction.default(), headers)`                                                 |
| `fixture.size`, `fixture.validate` (`@internal`)               | internal; `testing.playback` validates                                                            |
| —                                                              | `testing.script`, `exchanges`, `ignoring_headers`, `matching`                                     |

```gleam
// Before
let exchanges = [
  fixture.Exchange(req, fixture.Respond(response.new(200) |> response.set_body([<<"ok">>]), fixture.Complete([]))),
]
let assert Ok(client) = testing.start(config.default(), exchanges)

// After
let script =
  testing.script([
    testing.exchange(
      req,
      testing.Respond(response.new(200) |> response.set_body([<<"ok">>]), testing.Finished([])),
    ),
  ])
let assert Ok(client) = testing.playback(script, config.default())
```

Relax matching for values that change per run (WHK-7):

```gleam
let script =
  testing.script(exchanges)
  |> testing.ignoring_headers(["x-signature", "date"])
```

llm_wire's `session.gleam` builds exchanges from its own request and reply:

```gleam
// Before
fixture.Exchange(fixture.sanitise(request), reply)
// After
testing.exchange(request, reply) // credential headers are dropped on the way in
```

## `http_gun/cassette` (absorbs `http_gun/recording`)

| Before                                                                                          | After                                                                                                                                        |
| ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `cassette.new(exchanges) -> Result(Cassette, Failure)`                                          | `testing.script(exchanges) -> Script`; validated by `testing.playback`                                                                       |
| `Cassette`                                                                                      | `testing.Script`                                                                                                                             |
| `cassette.playback(cassette, config)`                                                           | `testing.playback(script, config)`                                                                                                           |
| `cassette.load(path, max) -> Result(Cassette, Failure)`                                         | `cassette.load(path, max) -> Result(testing.Script, CassetteError)`                                                                          |
| `cassette.parse(text, max)`                                                                     | same, `Result(testing.Script, CassetteError)`                                                                                                |
| `cassette.encode(cassette)`                                                                     | `cassette.encode(script)`                                                                                                                    |
| `cassette.record(config, path, recording.Options(max, RefuseExisting))`                         | `cassette.record(config, path, cassette.options() \|> cassette.with_max_bytes(max))`                                                         |
| `recording.Options(max, ReplaceExisting)`                                                       | `cassette.options() \|> cassette.with_max_bytes(max) \|> cassette.replace_existing`                                                          |
| `recording.default()`                                                                           | `cassette.options()`                                                                                                                         |
| `Recorded(client, recording)`                                                                   | unchanged; `recording: cassette.Recording`                                                                                                   |
| `StartRecordingError { ClientFailure(Failure) CaptureFailure(CaptureError) }`                   | `cassette.RecordError`                                                                                                                       |
| `recording.CaptureError { CaptureLimit IoFailure DestinationExists SessionClosed Interrupted }` | `cassette.RecordError { ClientFailed(http_gun.StartError) CaptureLimit IoFailure(op, cause) DestinationExists RecordingClosed Interrupted }` |
| `recording.finish(r)`, `cassette.finish(r)`                                                     | `cassette.finish(r, 0)`                                                                                                                      |
| `recording.finish_wait(r, ms)`                                                                  | `cassette.finish(r, ms)`                                                                                                                     |
| `recording.FinishError { Busy WaitTimeout CaptureFailed(CaptureError) }`                        | `cassette.FinishError { Busy WaitTimeout CaptureFailed(RecordError) }`                                                                       |
| `recording.abort(r)`                                                                            | `cassette.abort(r) -> Result(Nil, RecordError)`                                                                                              |
| `recording.Replacement`, `RefuseExisting`, `ReplaceExisting`                                    | `cassette.replace_existing`                                                                                                                  |
| —                                                                                               | `describe_error`, `describe_record_error`, `describe_finish_error`                                                                           |

```gleam
// Before
let assert Ok(cassette.Recorded(client:, recording:)) =
  cassette.record(settings, path, recording.Options(1_048_576, recording.RefuseExisting))
let assert Ok(_) = recording.finish_wait(recording, 5000)
let assert Ok(tape) = cassette.load(path, 1_048_576)
let assert Ok(replay) = cassette.playback(tape, settings)

// After
let assert Ok(cassette.Recorded(client:, recording:)) =
  cassette.record(settings, path, cassette.options() |> cassette.with_max_bytes(1_048_576))
let assert Ok(_) = cassette.finish(recording, 5000)
let assert Ok(script) = cassette.load(path, 1_048_576)
let assert Ok(replay) = testing.playback(script, settings)
```

```gleam
// Before
let assert Error(error.Failure(error.FixtureMissing, _)) = cassette.load(path, 1024)
// After
let assert Error(cassette.Missing) = cassette.load(path, 1024)
```

## Cassette files: schema 1 to 2

A schema 1 file (`"http_gun": 1`) fails to load with
`UnsupportedVersion(1)`. Convert each one once:

```sh
python3 dev/convert_cassette.py test/fixtures/old.json            # in place
python3 dev/convert_cassette.py old.json new.json                  # to a new file
```

It keeps every exchange, header and byte. Bodies and chunks that are valid
UTF-8 become `{"text": ..}`; others stay `{"base64": ..}` without the byte
count. `cassette.parse` reads `text` or `base64` and ignores `bytes`, so a
test that removes each required key to check rejection names `text` where it
named `bytes` and `base64`. Endings become `finished`, `aborted` and `abandoned`, and failures take
the `error.to_json` shape. The two schema 1 cassettes in the dependents are
`llm_wire/test/fixtures/http-gun-text.json` and
`fabric/test/fixtures/llm/hello.json`; both convert cleanly.

## `http_gun/redaction` (new)

`config.with_redaction(config, redaction)` decides what cassettes store and
how playback matches:

```gleam
let redaction =
  redaction.default()                       // the credential headers, as before
  |> redaction.with_headers(["x-signature"])
  |> redaction.with_query_parameters(["token"]) // stored as token=REDACTED
  |> redaction.with_body(scrub)                 // request bodies, whole response bodies
```

Recording applies it before writing; playback applies it to the scripted and
the incoming request before comparing. `redaction.headers`, `request` and
`body` apply it to your own values.

## `http_gun/telemetry`

| Before                                                                        | After                                                                                                       |
| ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| no events unless `observations: Some(forwarder)`                              | events always go through `sinal.emit`; route `["http_gun"]` to a forwarder to keep handlers out of the pool |
| `observations: Some(forwarder)`                                               | `config.with_observations(config, forwarder)` sends that client's events to the forwarder directly          |
| `prepare`, `begin`, `emit`, `termination`, `Emitter`, `Context` (`@internal`) | internal                                                                                                    |
| —                                                                             | `new_request_id()`, `request_id_to_string(id)`                                                              |
| —                                                                             | `config.with_label(config, label)`: the client's label, in `Metadata.client` and the native `client` key    |
| —                                                                             | `config.without_observations(config)`: the client emits nothing                                             |

`event()`, `Milestone`, `Outcome`, `Mode` and `Timing` are unchanged.
`Metadata` gains `client: Option(String)`, `None` for an unlabelled client,
whose native key is then omitted. A handler that reads `Metadata` by label or
with `Metadata(correlation:, ..)` keeps compiling; code that builds a
`Metadata`, or matches it without `..`, adds `client:`.

```gleam
// Before
let settings = config.Config(..config.default(), observations: Some(forwarder))

// After: route once, for every HTTP Gun client in the node
forwarder.route(["http_gun"], forwarder)
let settings = config.default()
```

An application that attaches a handler without routing now receives HTTP Gun
events synchronously in the pool and body processes.

A node-wide handler also sees the events of clients that libraries own, such
as warden's and llm_wire's. A library that owns a private client labels it
with its name, so the application can tell it apart:

```gleam
// In the library
let settings = config.default() |> config.with_label("warden")

// In the application: skip the library's HTTP
sinal.observe(telemetry.event(), fn(timing, metadata) {
  case metadata.client {
    Some("warden") -> Nil
    _ -> record(timing, metadata)
  }
})
```

A library may instead call `config.without_observations`, which leaves the
application nothing to watch. Prefer the label: it keeps the choice with the
application.

## Index of symbols each dependent uses

Grep of `src`, `test`, `integrations`, `consumers` and `examples` of every
sibling and of `oversight/apps`, at http_gun 056536b. relay, saga and grind do
not use http_gun. No dependent imports an http_gun module unqualified.
"Breaks" lists what stops compiling.

### fabric (light)

| File                                                        | Uses                                                                                                                           | Breaks                                                                  |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `src/fabric/llm.gleam`, `src/fabric/graph/llm.gleam`        | `http_gun.Client`                                                                                                              | nothing                                                                 |
| `test/fabric/graph_llm_test.gleam`                          | `testing.start`, `config.default`, `stop`                                                                                      | `testing.start`                                                         |
| `test/fabric/llm_recovery_test.gleam`                       | `cassette.load`, `cassette.playback`, `stop`                                                                                   | `cassette.playback`; fixture `test/fixtures/llm/hello.json` is schema 1 |
| `test/fabric/support/fake_provider.gleam`                   | `config.Config(..default(), destination:)`, `destination.Policy(..default(), allow_public:, allow_loopback:)`, `start`, `stop` | both record updates: use `destination.loopback_only()`                  |
| `consumers/decision/{src,test}`                             | `start`, `testing.start`, `stop`                                                                                               | `testing.start`                                                         |
| `consumers/writing/src/fabric_writing/{cli,provider}.gleam` | `start`, `stop`, `Client`                                                                                                      | nothing                                                                 |
| `consumers/writing/test/fabric_writing_test.gleam`          | `testing.start`, `fixture.Exchange` (type), `stop`                                                                             | `testing.start`, `fixture.Exchange` → `testing.Exchange`                |

fabric_typesafe calls raw `gun` from Erlang and does not use http_gun.

### llm_wire (heavy)

| File                                                                                    | Uses                                                                                                                                                                                                                                                                                                                                                                                                | Breaks                                                                        |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `src/llm_wire/internal/http_client.gleam`                                               | `with_response_with_options`, `request_options.Options(deadline, cancellation)`, `deadline.after`/`remaining_ms`, `cancellation.with_token`/`cancel`, `body.next(_, ms)`, `Chunk`, `End`, `Failure(..)` construct and patterns incl. `Failure(ReadTimeout, _)`, `DeadlineExceeded`, `NotSubmitted`, `MayHaveBeenSent`, `Cancelled`, `.reason`, `.evidence` (exhaustive `Evidence` match at 301-304) | all of it: views, `body.next`/`next_within`, opaque `Failure`, evidence names |
| `src/llm_wire/internal/owner.gleam`                                                     | `deadline.Deadline`, `remaining_ms`                                                                                                                                                                                                                                                                                                                                                                 | nothing                                                                       |
| `src/llm_wire/internal/runtime.gleam`                                                   | `Client`                                                                                                                                                                                                                                                                                                                                                                                            | nothing                                                                       |
| `src/llm_wire/session.gleam`                                                            | `fixture.Exchange`, `fixture.Reply`, `fixture.sanitise` (376-387)                                                                                                                                                                                                                                                                                                                                   | → `testing.exchange`, `testing.Reply`, `testing.match_key`                    |
| `src/llm_wire/testing.gleam`                                                            | `fixture.Exchange`, `Reply`, `Complete`, `Failed`, `Respond`, `error.Failure(RequestFailed(PeerClosed), MayHaveBeenSent)`                                                                                                                                                                                                                                                                           | → `testing.*`, `Finished`, `Aborted`, `error.new(.., MaybeSent)`              |
| `src/llm_wire/types.gleam:594`                                                          | `WireError.HttpFailure(reason: http_error.Reason)` (public re-export)                                                                                                                                                                                                                                                                                                                               | compiles; consider carrying `error.Failure` or its `Kind`                     |
| `examples/consumer`                                                                     | `Config(..default(), deadline_ms:)`, `child` + `map_data`, `start`, `stop`, `cassette.record`, `recording.Options` (positional), `RefuseExisting`, `finish_wait`, `Recorded` fields, `cassette.load`/`playback`/`new`/`parse`/`encode`, `testing.start`                                                                                                                                             | most of it                                                                    |
| `test/http_test_helpers.gleam`                                                          | `Config` updates (`destination`, `deadline_ms`), `Policy(..).allow_loopback`, `testing.start`, `fixture.Exchange`                                                                                                                                                                                                                                                                                   | yes                                                                           |
| `test/llm_wire_cassette_test.gleam`                                                     | `cassette.new`/`encode`/`parse`/`load`/`playback`; `FixtureExhausted`, `FixtureMismatch`, `FixtureCorrupt`, `FixtureVersion`, `FixtureMissing`, `LimitExceeded(FixtureBytes)`, `ClientClosed`, `RequestFailed(PeerClosed)`; `fixture.Respond`/`Exchange`/`Complete`/`Reject`/`matches`; `Exchange.request`/`.reply`                                                                                 | yes; `test/fixtures/http-gun-text.json` is schema 1                           |
| `test/llm_wire_http_gun_test.gleam`                                                     | `start` ×12, `Config` updates (`deadline_ms`, `limits`), `Limits(..).request_bytes`, `ClientClosed`, `LimitExceeded(RequestBodyBytes)`, `snapshot`, `Stats.bodies`/`.waiting`                                                                                                                                                                                                                       | yes                                                                           |
| `test/llm_wire_integration_test.gleam`                                                  | `LimitExceeded(ResponseHeaderBytes)`, `Config(..).trust` with `CustomCa`                                                                                                                                                                                                                                                                                                                            | config updates                                                                |
| `test/llm_wire_local_gate.gleam`                                                        | `snapshot`, `Stats.connections`, `Config` update (`protocol`, `trust`, `deadline_ms`, `limits`), `RequireHttp2`, `CustomCa`, `Limits` update (`connections`, `per_origin`, `active`, `waiting`)                                                                                                                                                                                                     | yes                                                                           |
| `test/llm_wire_long_line_test.gleam`, `test/llm_wire_provider_fragmentation_test.gleam` | `fixture.Respond`, `Complete`, `Exchange`, `.request`                                                                                                                                                                                                                                                                                                                                               | → `testing.*`                                                                 |
| `test/llm_wire_owner_test.gleam`                                                        | `RequestFailed(ConnectionReset)`                                                                                                                                                                                                                                                                                                                                                                    | patterns on `Failure`                                                         |
| `test/llm_wire_pool_test.gleam`                                                         | `Config`/`Limits` updates, `snapshot`, `Stats.*`, `AdmissionFull`                                                                                                                                                                                                                                                                                                                                   | yes                                                                           |
| `test/llm_wire_recording_test.gleam`                                                    | `cassette.record` ×7, `recording.Options` (positional), `RefuseExisting`, `ReplaceExisting`, `recording.default`, `finish_wait` ×8, `CaptureFailed`, `CaptureLimit`, `DestinationExists`, `IoFailure`, `WaitTimeout`, `error.PublishFixture`, `cassette.load`/`playback`, `Recorded` fields                                                                                                         | yes                                                                           |
| `test/llm_wire_test_client.gleam`                                                       | `Client`                                                                                                                                                                                                                                                                                                                                                                                            | nothing                                                                       |
| `test/llm_wire_testing_test.gleam`                                                      | `RequestFailed(PeerClosed)`, `FixtureExhausted`                                                                                                                                                                                                                                                                                                                                                     | yes                                                                           |
| `test/llm_wire_transport_failure_test.gleam`                                            | `Failure(DeadlineExceeded, MayHaveBeenSent)`, `InvalidConfig`, `NotSubmitted`, `ConnectionFailed(ConnectionRefused)`                                                                                                                                                                                                                                                                                | yes                                                                           |

Sites: `stop` 41, `start` 24, `Client` 21, `cassette.parse` 11, `fixture.Exchange`
13, `error.NotSubmitted` 12, `error.Failure` 16, `recording.finish_wait` 9,
`cassette.load` 9, `cassette.playback` 8, `cassette.record` 8, `config.Config`
record updates 10, `Limits` updates 3, `snapshot` 5.

### warden (medium; one file)

`src/warden/internal/transport.gleam`:

- `http_gun.child` with `supervision.map_data` and `persistent_term`
  put/get/erase plus an unchecked `coerce` (159-183, 532-550): replace with
  `http_gun.supervised(settings, name)` and `http_gun.named(name)`, and delete
  the shim.
- `with_response_with_options` with `request_options.Options(deadline:)` and
  `deadline.after`: → `client |> http_gun.with_deadline(deadline.after(ms))`
  and `with_response(client, req, on_failure, run)`.
- `body.collect` and `Collected.bytes`: unchanged.
- `config.Config(..defaults, trust, deadline_ms, connect_ms, limits,
destination)`, `SystemTrust`, `Anchors`, `Limits(..).request_bytes,
head_bytes, header_count, collect_bytes`: setters.
- `destination.Policy` built with all five labels including `resolver` (280):
  `destination.default() |> destination.only_hosts(..)` and
  `config.with_resolver`.
- Exhaustive match on all 22 `Reason`s (405-452), 12 `TransportCause`s and 9
  `LimitKind`s, plus `Evidence`: a `Kind` match with detail arms ending in `_`.
- `destination.classify`, `Class`, `Address`, `Ipv4`, `Ipv6`: unchanged.

### Apps

| App            | Uses                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Breaks                                                                                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| checkout       | `start`, `stop`, `send`, `with_correlation`, `Buffered.response`; `gateway.gleam`: `Config` update (`deadline_ms`, `observations`, `destination`), `Policy` update (`allow_public`, `allow_loopback`, `allowed_hosts`), `deadline.after`, `request_options.Options(deadline:)`, `send_with_options`; `codecs.gleam` 236-373: a hand-written `Failure` codec over every `Reason`, `TransportCause` and `LimitKind`; `domain.gleam`: `Failure(evidence: MayHaveBeenSent, ..)` pattern, `describe`; `web.gleam`: `Failure(DeadlineExceeded, _)` pattern; `telemetry.gleam`: `event`, `Metadata` fields; tests: `Failure(DeadlineExceeded, MayHaveBeenSent)`                                                                                                                                                                                                                                                                                                                                                                      | gateway (one line with `loopback_only() \|> only_hosts([..])` and `with_deadline`), the codec (→ `error.to_json`/`decoder`), every `Failure` pattern                                                           |
| extractor      | `clients.gleam`: `Config` updates (`deadline_ms`, `connect_ms`, `limits`, `observations`, `destination`), `allow_loopback`, `Limits` update (`connections`, `per_origin`, `collect_bytes`), `Policy` updates (`allowed_hosts`, `resolver`), `Ipv4`; `document.gleam`: `try_with_response`, `body.collect`, `LimitExceeded(CollectedBodyBytes, ..)` pattern, `describe`; `outcome.gleam`: `Reason` patterns `DestinationRejected`, `InvalidRequest`, `InvalidConfig`, `LimitExceeded`; `telemetry.gleam`: exhaustive `Milestone` match; tests: `Failure(reason:, evidence:)` patterns                                                                                                                                                                                                                                                                                                                                                                                                                                          | config, `try_with_response`, `CollectedBodyBytes`, `InvalidConfig`, `DestinationRejected` arity, `Failure` patterns                                                                                            |
| research_agent | `app.gleam`: `Config` update (`deadline_ms`, `observations`, `destination`), `allow_loopback`, `Policy(..).allowed_hosts`; `remote.gleam`: `Reason` type, `describe`, `Failure(..)` construct, `NotSubmitted`, `MayHaveBeenSent`, `.reason`, `.evidence`, `send`, `with_correlation`; `telemetry.gleam`: `ResponseHeaders`, `HttpTerminated`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | config (both clients: `with_destination(loopback_only() \|> only_hosts([..]))`; the 120 s client can become a `with_timeout` view), `Failure` use                                                              |
| sso_portal     | `app.gleam`: `Config` updates (`deadline_ms`, `connect_ms`, `observations`, `destination`), `allow_loopback`, `Policy(..).allow_public`; `browser.gleam`: `Config(..).trust`, `deadline_ms`, `Anchors`, `.reason`; `billing.gleam`, `web.gleam`: `send`, `with_correlation`, `.reason`; `telemetry.gleam`: exhaustive `Milestone` match                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | config (`loopback_only()`), `.reason`                                                                                                                                                                          |
| support_desk   | `app.gleam`: `Config` updates (`observations`, `deadline_ms`, `destination`), `Policy(..default(), allow_public:, allow_loopback:)`; `shop.gleam`: `describe` ×5, `Failure(evidence: NotSubmitted, ..)` and `MayHaveBeenSent` patterns, `Buffered(response:, ..)`, `send`; `desk.gleam`: `with_correlation`; `telemetry.gleam`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | config (`loopback_only()`), evidence patterns                                                                                                                                                                  |
| tool_hub       | `tool_hub.gleam`: `Config` update (`deadline_ms`, `observations`), `allow_loopback`, `start`, `stop`; `assistant.gleam`: `with_correlation`; `telemetry.gleam`: `Metadata(correlation:, mode:, milestone:, ..)` pattern; test: `Buffered(response:, ..)`, `send`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | config                                                                                                                                                                                                         |
| webhooks       | `webhooks.gleam`: `Address`, `Ipv4` resolver, `allow_loopback`, `send`, `.reason`; `attempt.gleam`: two exhaustive matches over all 22 `Reason`s (228-251, 260-282), `TransportCause`, `LimitKind`; `delivery.gleam`: `request_options.Options(collect: Some(Collect(_, Truncate)))`, `send_with_options`, `Buffered.truncated`, `with_correlation`; `egress.gleam`: `Resolver`, `Config` updates (`deadline_ms`, `connect_ms`, `observations`, `destination`), `Config.connect_ms` read, full `Policy` construction (58), `Policy(..).allow_public`/`allowed_hosts`; `subscription.gleam`: `Class`, `classify`, `Address`, `Ipv4`, `Ipv6`, and `webhooks_ffi.erl` `parse_ip` (→ `destination.parse_address`); `telemetry.gleam`: exhaustive `Milestone` match, `Metadata.mode`; tests: `fixture.*`, `cassette.new`/`parse`/`encode`/`playback`, `request_options.Collect`, `Fail`, `Truncate`, `LimitExceeded(CollectedBodyBytes)`, `FixtureExhausted`, `FixtureMismatch`, `Failure(..)` constructions, `Class` constructors | the most: `attempt.gleam` (→ `error.kind`/`name`; the status is now in `error.status` instead of `Truncate`), `egress.gleam` (per-tenant clients can become `with_destination` views), `delivery.gleam`, tests |

App call sites: `http_gun.Client` 46, `stop` 14, `start` 15, `send` 10,
`with_correlation` 8, `Buffered.response` 14, `config.Config` record updates
16, `destination.Policy` updates 8 and full constructions 2, `error.describe`
11, `Failure.reason` 9, `Failure.evidence` 4, `error.Failure` patterns 8,
`telemetry.event` 7.

## Follow-up fixes

Two fixes after the webhooks re-run on wave 3 (oversight
`apps/webhooks/FEEDBACK.md`, "Re-run after wave 3"). Neither breaks code that
already compiles against wave 3, apart from an exhaustive `Reason` match,
which needs the new variant or a `_` arm.

### A multi-tenant client fails closed without a view destination

Before, the one client of a multi-tenant app had to admit the union of every
tier, so a call that skipped the app's narrowing helper let a public tenant
reach loopback:

```gleam
// Safe: narrowed to the tenant's tier.
egress.client_for(deps.egress, tier) |> http_gun.send(req)
// Compiled, and let a public tenant's URL reach 127.0.0.1.
deps.egress.client |> http_gun.send(req)
```

After, require a destination on every view. The union policy stays on the
client and bounds what the views may narrow to:

```gleam
config.default()
|> config.allow_loopback              // public and loopback: the union
|> config.require_view_destination    // a view must narrow it
```

`deps.egress.client |> http_gun.send(req)` now fails with
`error.ViewDestinationRequired`, `NotSent` and kind `Refused`, before the host
is resolved, so `error.is_retryable` is `False`. A view that admits more than
the client still gets only what both admit. Playback and recording clients
started from the same configuration refuse the same call, so the cassette
tests catch a missed view.

| Before                                                                        | After                                                                                       |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| a client with the union policy, safe only if every call goes through the view | `config.require_view_destination(config)`; a bare call fails with `ViewDestinationRequired` |
| —                                                                             | `error.ViewDestinationRequired` (`Refused`, `"view_destination_required"`)                  |

### `Fail` keeps the response headers

Before, `with_body_limit(max, Fail)` kept the status of an oversized response
but dropped its headers, so a 429 lost its `retry-after`, and the only way to
keep it was `Truncate` with a second branch on `Buffered.truncated`. After,
every `send` or `batch` failure that has a status also has the response's
headers, after the client's redaction:

```gleam
// After
case error.status(failure), list.key_find(error.headers(failure), "retry-after") {
  Some(429), Ok(seconds) -> snooze(seconds)
  _, _ -> classify(failure)
}
```

| Before                                                                          | After                                                                           |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `Truncate` + `Buffered.truncated` + `response.get_header` to keep `retry-after` | `Fail` + `error.headers(failure)`                                               |
| `error.new(..) \|> error.with_status(s)` in a test double                       | add `\|> error.with_headers(headers)` when the double needs headers             |
| `to_json` without headers                                                       | an optional `"headers": [[name, value], ..]`; records without it decode to `[]` |

A test that compares a whole `send` failure with `should.equal` and a status
now needs the response's headers too, or compare `error.reason` and
`error.status`. Streaming failures from `body.next` keep only the status; the
caller already holds the headers in its `Response`.
