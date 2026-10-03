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
changed item.

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
- Named timeouts with these defaults: connect including DNS and TLS 5 s
  (`with_connect_timeout`), pool checkout 5 s (`with_pool_timeout`), request
  30 s (`with_request_timeout`), idle read 30 s (`with_idle_timeout`), idle
  pooled connection 60 s (`with_connection_idle_timeout`) and shutdown drain
  5 s (`with_shutdown_timeout`). `config.Infinity` lifts a bound explicitly.
- `body.next(body)` waits for data within those timeouts;
  `body.next_within(body, ms)` returns `Ok(None)` when its local wait passes.
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
- `stop` drains: it refuses new work, fails queued requests, lets open bodies
  finish within the shutdown timeout, then cancels them.
- [docs/GUN_AUDIT.md](docs/GUN_AUDIT.md), the audit of the Gun and Cowlib terms
  the FFI relies on.
- Module docs on every public module, a README defaults table, and README
  examples compiled as tests (`test/http_gun_readme_test.gleam`).

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
  `PlaybackMismatch`, `PlaybackExhausted`, `RecordingClosed`.
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
