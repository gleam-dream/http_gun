# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

`error.Reason`, `error.TransportCause`, `error.LimitKind` and
`error.RequestProblem` may gain variants in a minor release. Each release lists
new variants here under **New variants**.

## Unreleased

The first release. Wave 3 redesigned the API before publication; see
[the wave 3 migration guide](docs/migration-wave-3.md) for every removed and
changed item. Wave 4 moved every timeout to `Duration`, added the
plaintext rule and the view correlation accessor, and made only a narrowing
view policy satisfy `require_view_destination`; see [the wave 4 migration guide](docs/migration-wave-4.md).

### Fixed

- `cassette.abort` left the `<path>.http-gun-*` staging directory and its
  files behind, as did every other failed recording: a capture failure such as
  the byte budget or a write error, a failed `finish` (for example
  `DestinationExists`), the death of the process that started the recording,
  and a crash of the recorder. Each now removes the staging directory;
  `abort` has removed it when it returns. It stays only if the VM is killed
  mid-recording or a writer is stuck in a blocking file operation, and then
  only until that operation returns.

### Added

- An HTTP client on Gun: `http_gun.start`, or `supervised(config, name)` with
  `named(name)` under a supervisor; `send` collects a response, `open` and
  `with_response` stream an owned `body.Body`, and `batch` runs requests with
  bounded concurrency. One entry point per operation.
- Client views for per-call settings: `with_timeout`, `with_deadline`,
  `with_idle_timeout`, `with_cancellation`, `with_body_limit` (`Fail` or
  `Truncate`), `with_destination` (narrows only) and `with_correlation`. A
  view's timeout or deadline replaces the client's request timeout, shorter
  or longer.
- Opaque `config.Config` built from `default()` with `with_*` setters, and a
  typed `ConfigError` from `validate` and `start` (`StartError.InvalidConfig`).
- Named timeouts, each a `gleam/time/duration.Duration`, with these
  defaults: connect including DNS and TLS 5 s (`with_connect_timeout`), pool
  checkout 5 s (`with_pool_timeout`), request 30 s (`with_request_timeout`),
  idle read 30 s (`with_idle_timeout`), idle pooled connection 60 s
  (`with_connection_idle_timeout`) and shutdown drain 5 s
  (`with_shutdown_timeout`). The request and idle timeouts take
  `config.After(duration)` or the explicit `config.Infinity`.
- `body.next(body)` waits for data within those timeouts;
  `body.next_within(body, wait)` returns `Ok(None)` when its local wait
  passes.
- `destination.with_plaintext(policy, AllowPlaintext | PlaintextToLoopbackOnly
  | RequireTls)` decides whether `http://` is admitted, against every
  resolved address and the addresses of a reused pooled connection. A refused
  request fails with `DestinationRejected(PlaintextRefused(class))`, kind
  `Refused`, and `NotSent`. The default, `AllowPlaintext`, keeps plaintext
  callers working; `destination.check_plaintext` checks one address.
- HTTP/1.1 and HTTP/2 (`Http1`, `PreferHttp2`, `RequireHttp2`), verified TLS
  with system, file or in-memory trust anchors, and byte, header, connection,
  stream and queue limits, each with a `with_max_*` setter.
- `batch` retains at most `with_max_batch_bytes` (64 MiB) of bodies; later
  requests fail with `LimitExceeded(BatchBytes, ..)` and `NotSent`.
- A destination policy (`http_gun/destination`) that admits public addresses
  by default, checks every resolved address before connecting, and always
  refuses reserved and cloud metadata addresses. `loopback_only`,
  `allow_loopback`, `allow_private`, `only_hosts` with `host:port` entries,
  `check`, `check_address`, `validate` and `parse_address`.
- An opaque `error.Failure` with `reason`, `evidence` (`NotSent`,
  `MaybeSent`), `status`, a closed `Kind`, `is_retryable(idempotent:)`,
  `name`, `describe`, `to_json` and `decoder`. A collected body over its limit
  keeps the response status.
- Offline scripts (`http_gun/testing`) with `ignoring_headers` and `matching`,
  and readable schema 2 cassettes (`http_gun/cassette`) with incremental
  recording and atomic publication. `dev/convert_cassette.py` converts schema
  1 files.
- Redaction (`http_gun/redaction`, `config.with_redaction`): credential
  headers by default, configured headers, named query parameters and a
  whole-body function, applied identically when recording and when matching
  playback.
- Lifecycle observations (`http_gun/telemetry`) emitted with `sinal.emit`, so
  the application's `forwarder.route` decides where handlers run;
  `config.with_observations` sends to a forwarder directly. Events carry the
  caller's `sinal/correlation.Correlation` and a per-request `RequestId`.
- `config.with_label(config, label)` names a client in its events
  (`telemetry.Metadata.client`, native key `client`), so a node-wide handler
  can tell clients apart. A library that owns a private client labels it with
  its name, such as `"warden"` or `"llm_wire"`.
- `config.without_observations(config)` makes a client emit nothing. A
  library may silence its private client this way; labelling is preferred,
  because it leaves the choice to the application. The default is unchanged:
  every client emits through `sinal.emit`.
- `config.require_view_destination(config)`: the client refuses, with
  `ViewDestinationRequired` and `NotSent`, every request whose view has not
  chosen a destination with `http_gun.with_destination`. A multi-tenant client
  must admit the union of its tenants' destinations; with this setting a call
  that skips the tenant's view fails closed instead of reaching that union.
  Only a view policy that narrows the client's destinations counts: one that
  sets `destination.only_hosts` or refuses an address class the client
  admits, as `destination.narrows(policy, within: client)` reports. A policy
  that only tightens `destination.with_plaintext` counts as none, so a library that tightens the scheme on a caller's view never lifts
  the requirement. The client's policy only bounds what views may narrow to;
  a view still never widens it. The check holds for live, recording and
  playback clients.
- `http_gun.correlation(client) -> Option(Correlation)` reads the
  correlation a view carries. A library that receives a caller's view reads
  the caller's correlation from it and copies it into its own telemetry,
  instead of asking the caller to set it twice.
- `error.headers(failure)` and `error.with_headers(failure, headers)`: a
  `send` or `batch` failure after the response head arrived keeps the
  response headers, after the client's redaction, beside `error.status`. A
  429 whose body exceeds `with_body_limit(_, _, Fail)` keeps its
  `retry-after`. `error.to_json` stores them as `"headers": [[name, value]]`
  and `error.decoder` reads them back.
- `stop` drains: it refuses new work, fails queued requests, lets open bodies
  finish within the shutdown timeout, then cancels them.
- [docs/GUN_AUDIT.md](docs/GUN_AUDIT.md), the audit of the Gun and Cowlib terms
  the FFI relies on.
- Module docs on every public module, a README defaults table, and README
  examples compiled as tests (`test/http_gun_readme_test.gleam`).

### Changed (wave 4, breaking)

- Every timeout, deadline and wait takes a `Duration` (new dependency
  `gleam_time >= 1.11.0 and < 2.0.0`); no public signature takes `Int`
  milliseconds. `config.Timeout` is `After(Duration) | Infinity` instead of
  `Milliseconds(Int) | Infinity`; `with_connect_timeout`, `with_pool_timeout`,
  `with_connection_idle_timeout` and `with_shutdown_timeout` take a
  `Duration`; `config.Resolver` receives the time left as a `Duration`;
  `deadline.after(Duration)` and `deadline.remaining(deadline) -> Duration`
  replace `after(Int)` and `remaining_ms`; `body.next_within` and
  `cassette.finish` take a `Duration` wait. A timeout out of range is
  `ConfigError.TimeoutOutOfRange(setting, Duration)`; `OutOfRange` keeps
  capacities. Defaults and the internal whole-millisecond precision are
  unchanged; a sub-millisecond remainder rounds away from zero.

### Changed (wave 3, breaking)

- Every value a caller builds is opaque: `config.Config`, `config.Limits`
  (removed into setters), `destination.Policy`, `cassette.RecordOptions`.
- `http_gun.start` returns `StartError`; `stop` returns `Nil`; `child` became
  `supervised(config, name)`; `snapshot` became `stats` with fields
  `connections`, `open_bodies`, `queued_requests`.
- The `_with_options` twins and `try_with_response` were folded into the views
  and `with_response(client, req, on_failure, run)`.
- `deadline.after` is total; `cancellation.with_token` cannot fail and
  `cancel` returns at once.
- `http_gun/fixture` merged into `http_gun/testing` (`Complete`, `Failed`,
  `Cancelled` became `Finished`, `Aborted`, `Abandoned`), and
  `http_gun/recording` into `http_gun/cassette` (`finish(recording, wait_ms)`
  replaces `finish` and `finish_wait`).
- Error vocabulary: `NotSubmitted` and `MayHaveBeenSent` became `NotSent` and
  `MaybeSent`; `InvalidRequest` takes a `RequestProblem`;
  `DestinationRejected` takes a `destination.Rejection`;
  `FixtureExhausted` and `FixtureMismatch` became `PlaybackExhausted` and
  `PlaybackMismatch`; `CaptureFailed(String)` became `RecordingClosed`;
  `CollectedBodyBytes` and `ResponseQueueBytes` became `ResponseBodyBytes`
  and `BufferedBytes`.
- Cassettes use schema 2; schema 1 files fail with `UnsupportedVersion(1)`.
- Observations are on by default through `sinal.emit` instead of off.
- A request on a stopped client fails with `ClientClosed` and `NotSent`
  instead of `MaybeSent`.
- `gun >= 2.6.0 and < 2.7.0` and `cowlib >= 2.20.0 and < 2.21.0` replace the
  exact pins. CI runs the minimum and the newest patch.
- A waiting request's headers and body are held in a closure, so a pool crash
  report prints no credential; `testing.exchange` drops credential headers
  from the in-memory script.
- Construction records moved to `docs/history/`.

### New variants

- `Reason`: `PoolTimeout`, `ConnectTimeout`, `IdleTimeout`,
  `PlaybackMismatch`, `PlaybackExhausted`, `RecordingClosed`,
  `ViewDestinationRequired` (kind `Refused`, name
  `"view_destination_required"`).
- `LimitKind`: `BufferedBytes`, `ResponseBodyBytes`, `BatchBytes`.
- `RequestProblem` (new): `BodyNotBytes`, `InvalidMethod`, `InvalidOrigin`,
  `InvalidTarget`, `InvalidHeader`, `InvalidBodyLimit`, `InvalidBatch`.

### Removed

- `http_gun/request_options`, `http_gun/fixture`, `http_gun/recording`.
- `http_gun.request_ceiling_ms`, `open_with_options`, `send_with_options`,
  `with_response_with_options`, `try_with_response`,
  `try_with_response_with_options`, `child`, `snapshot`.
- `error.InvalidConfig`, `ReadTimeout`, `FixtureMissing`, `FixtureIo`,
  `FixtureCorrupt`, `FixtureVersion`, `CaptureFailed`, `ResponseChunkBytes`,
  `FixtureBytes`, `file_description`; `cancellation.try_with_token`;
  `deadline.timestamp`; every `@internal` function in a public module.
- The archived LLM Wire consumer from the gate: LLM Wire is a live dependent
  and migrates itself.
- `telemetry.new_id()`, replaced earlier by `sinal/correlation`.
