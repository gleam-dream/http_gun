# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- An HTTP client on Gun: `http_gun.start` and `child` start a client with its
  own connection pool; `send` collects a response, `open`, `with_response`
  and `try_with_response` stream an owned `body.Body`, and `batch` runs
  requests with bounded concurrency.
- HTTP/1.1 and HTTP/2 (`Http1`, `PreferHttp2`, `RequireHttp2`), verified TLS
  with system, file or in-memory trust anchors, and a pure `config.Config`
  with byte, header, connection and stream limits.
- A destination policy (`http_gun/destination`) that admits public addresses
  by default, checks every resolved address before connecting, and always
  refuses reserved and cloud metadata addresses.
- Per-request deadlines (`http_gun/deadline`), scoped cancellation
  (`http_gun/cancellation`) and a per-request collection policy that can keep
  the status on overflow (`request_options.Collect`).
- Typed failures (`http_gun/error`) with submission evidence (`NotSubmitted`,
  `MayHaveBeenSent`) and a bounded `describe`.
- Offline scripts (`http_gun/testing`), cassette playback and recording
  (`http_gun/cassette`, `http_gun/recording`). Cassettes omit credential
  headers (`authorization`, `proxy-authorization`, `cookie`, `set-cookie`,
  `x-api-key`, `api-key`, `x-goog-api-key`).
- Lifecycle observations through a Sinal forwarder (`http_gun/telemetry`).
- Every public module now has a rendered `////` module doc. Seven modules
  (`body`, `cassette`, `config`, `destination`, `error`, `fixture`,
  `testing`) had none, and `recording` described its internals.
- Regression tests that `string.inspect` of failures, observation metadata,
  encoded and parsed cassettes, and recorded cassette files contains no
  `authorization`, `proxy-authorization`, `cookie` or `set-cookie` value.
