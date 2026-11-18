# Changelog

## Unreleased

### Added

- `testing.verify(client) -> Result(testing.Verdict, testing.VerifyError)`
  reports what a playback client refused and left: each mismatched request
  beside the exchange it was compared against (`testing.Mismatch` with
  `position`, `expected` and `actual`), each request after the last exchange,
  all in `match_key` form and oldest first (the first 64 of each kind, with
  the rest counted in `dropped`),
  and the exchanges not yet used. A test can fail on a stale or half-used
  script even when the code under test handled the playback failure. A live
  or recording client gives `NotPlayback`, a stopped one `ClientStopped`.
- `redaction.keeping_request_headers(redaction, names)` stores and compares
  only the named request headers and `content-type`. Credential and other
  removed headers stay removed even when named; response headers, trailers
  and failure headers are unaffected. See ADR 0018.
- `redaction.with_request_body(redaction, rewrite)` rewrites request bodies
  only, in recordings and on both sides of playback matching, so normalising
  volatile request values never edits a recorded answer.
- `testing.repeating(script)` starts playback again at the first exchange
  after the last, so a non-empty script is never exhausted. With a matcher
  that accepts any request, one exchange answers every request, for example
  with a built provider failure.
- `redaction.request_fields_only(redaction)` replaces credential fields in
  request bodies and the query only, and stores response bodies as received
  (apart from `with_body`), so a JSON answer or error body with a listed key,
  such as `{"error":{"code":429}}`, replays exactly. The default is
  unchanged; a consumer that opts in owns keeping secrets such as OAuth token
  answers out of its cassettes.
- `cassette.redact(script, redaction)` applies a redaction to stored
  exchanges as a recording would store them, including the headers held
  inside a scripted failure, to find what a grown policy
  would still change in old cassettes and to clean them with `encode`
  without recording again.
- `config.with_cipher_suites` with `config.CipherSuites`: `OtpDefaults`
  (the default) or `OtpDefaultsAndTls12Cbc`, which also offers the TLS 1.2
  ECDHE AES-CBC suites with HMAC-SHA-256/384 after OTP's defaults. OTP left
  CBC suites out of its defaults, and some servers (for example the São Paulo
  NFS-e web service) accept only them. Verification, trust and destination
  policy are unchanged. See ADR 0017.

### Changed

- Cassettes are written in schema 3 (`"http_gun": 3`), and schema 2 files
  still load. Schema 3 lays a cassette out over many lines, each header
  pair, chunk and body line on a line of its own, and stores a UTF-8 body or
  chunk that contains a newline as `{"lines": [...]}`, the strings between
  its newlines, rebuilt exactly by joining them. Every body reads back byte
  for byte. Recorded files and `cassette.encode` output share this layout.
  See ADR 0019.
- The recording budget is charged on every byte the file holds, its envelope
  and separators included, so a recording within budget B loads with
  `max_bytes` B. A budget below the 42-byte envelope is refused with
  `CaptureLimit`.

### Upgrading cassettes

- Convert each schema 2 file with `cassette.parse(text, max_bytes)` then
  `cassette.encode`: read the file, convert the text, parse the result to
  check it, then write it back. No credentials, no network. `encode` applies
  no redaction, so no recorded answer changes. To clean a file recorded
  before field redaction existed, apply `cassette.redact` on purpose.
- Schema 3 stores a request's scheme, host, port, path and query as
  separate fields, so every request a client accepts reads back exactly:
  a query with brackets, braces, a pipe or quotes, a non-ASCII path, an IPv6
  host, or a `?` or `#` in a path. A schema 2 file stored one URL, which
  could not carry those targets. Such a file either never loaded (`parse`
  returns `Corrupt`, and HTTP Gun cannot recover it: record it again) or
  loaded as a different request, which converts as that request. A schema 2
  file that loads but holds a target a client could not send, such as port 0
  or an empty host, converts to text `parse` refuses: check before writing.
- Who breaks: `cassette.encode` applies no redaction any more. Since 0.1.0 it
  promised never to write credential headers, and since 0.1.1 it replaced
  credential fields; a hand-built script now keeps, when encoded, the
  credentials its responses hold (a `set-cookie` or other credential response
  or trailer header, failure headers, credential fields in response bodies).
  `testing.exchange` still redacts the request. Apply
  `cassette.redact(script, redaction.default())` first, as recording already
  does. `cassette.encode` of a hand-built script whose target a client
  could not send (an empty host, port 0, a path without a leading `/`) writes
  a file `parse` refuses as `Corrupt`; schema 2 loaded such files. An older
  HTTP Gun reading a schema 3 file fails with
  `UnsupportedVersion(3)`; code comparing `cassette.encode` output with a
  stored string sees the new layout; a `load` limit set close to a file's
  schema 2 size can fail with `TooLarge` (a streamed answer grows by about a
  quarter); `cassette.record` with a budget below 42 bytes now fails at once
  with `CaptureLimit` instead of at the first request; and a recording that
  fit its budget under schema 2 can now exceed it, since the same exchanges
  store more bytes and every stored byte is charged. Convert in one commit,
  after moving to this version, so no re-record mixes a format change with a
  content change.

### Fixed

- A request whose method was spelled as another known method, such as
  `http.Other("GET")`, was recorded as `Get` and then never matched its own
  live form on replay. Matching now compares methods in one spelling, so
  `Other("GET")` and `Get` are the same method; requests sent are unchanged.

- A request whose host, path or query held a space followed by a combining
  mark passed admission, because the check matched whole characters as
  displayed rather than code points; the space then reached the request
  line. It is now refused as `InvalidRequest(InvalidTarget)` (or
  `InvalidOrigin` for the host), like any other space.

## 0.1.1 - 2026-11-04

### Security

- `redaction.default()` now also keeps credentials outside headers out of
  cassettes. One list of credential names (`key`, `api_key`, `apikey`,
  `access_token`, `token`, `client_secret`, `code`, `refresh_token`,
  `id_token`, `signature`, `sig`, `x-amz-security-token`, `x-goog-api-key`,
  `x-amz-signature`, `x-amz-credential`, `password`, `secret`,
  `authorization`) selects query parameters, pairs of
  `application/x-www-form-urlencoded` bodies (split at `&` and `;`) and keys
  of JSON request and response bodies whose value becomes `REDACTED`. Names
  compare without case and ignoring `-` and `_`, so `CLIENT_SECRET`,
  `accessToken` and `API-KEY` are covered. JSON key escapes are not decoded;
  the value of any key containing a backslash escape (such as
  `"\u0070assword"`) is replaced, whatever the key spells. Previously a recorded OAuth token
  exchange stored the client secret, authorization code and tokens
  verbatim.
- A form or JSON body that cannot be scanned (non-UTF-8 form data, or JSON
  cut off inside a string or before a value, as an aborted response is) or
  that is above 16 MiB is stored as `REDACTED-UNPARSABLE` instead of
  verbatim.
- The default removed headers add `x-auth-token`, `x-access-token`,
  `x-amz-security-token` and `x-csrf-token`.
- Recorded cassettes and their staged files are created with mode `0600`
  instead of inheriting the process umask.

### Changed

- Playback applies the same default redaction to both sides, so a recorded
  request still matches its live request; a redacted value now matches any
  live value of that parameter or field.
- A recording now buffers every form and JSON response body whole and stores
  it as one chunk; `cassette.encode` stores those response bodies the same
  way. The held bytes count against `max_bytes`, so a recording of large
  form or JSON responses can fail with `CaptureLimit` sooner than before.
- `with_query_parameters` names are compared without case and ignoring `-`
  and `_`, and share one list with body fields, so they also apply to form
  and JSON bodies.
- Bodies with other content types are stored as before; use
  `redaction.with_body` for them.

### Added

- `redaction.with_body_fields` adds names to replace in form and JSON bodies
  (and, sharing the list, in the query).
- `redaction.body_for` and `redaction.rewrites_body_for` apply and report the
  content-type-aware body redaction. `redaction.body` and
  `redaction.rewrites_bodies` keep their meaning (the body function only).

## 0.1.0

- Pooled HTTP/1.1 and HTTP/2 clients with verified TLS and optional client certificates.
- Collected, streamed and batched responses with caller-selected budgets and cancellation.
- Typed failure evidence, Sinal observations, scripted responses and cassette recording/playback.

### New variants

The initial public error variants are listed below. These types may gain variants
in minor releases. Match the variants you handle explicitly and keep a catch-all
for the rest, or classify failures with `error.kind`.

- `error.Reason`: `InvalidRequest`, `ClientClosed`, `AdmissionFull`, `PoolTimeout`,
  `DestinationRejected`, `ViewDestinationRequired`, `ResolutionFailed`,
  `ConnectTimeout`, `ConnectionFailed`, `RequestFailed`, `DeadlineExceeded`,
  `IdleTimeout`, `ReadConflict`, `WrongOwner`, `Closed`, `Cancelled`,
  `LimitExceeded`, `PlaybackMismatch`, `PlaybackExhausted`, `RecordingClosed`.
- `error.TransportCause`: `NameResolutionFailed`, `ConnectionRefused`,
  `CertificateRejected`, `TlsFailed`, `ConnectionReset`, `PeerClosed`,
  `PeerDraining`, `ProtocolError`, `HeaderLimitReached`, `TransportTimeout`,
  `UnexpectedProtocol`, `UnknownTransport`.
- `error.LimitKind`: `RequestBodyBytes`, `RequestHeaderBytes`,
  `RequestHeaderCount`, `ResponseHeaderBytes`, `ResponseHeaderCount`,
  `BufferedBytes`, `ResponseBodyBytes`, `BatchBytes`.
- `error.RequestProblem`: `BodyNotBytes`, `InvalidMethod`, `InvalidOrigin`,
  `InvalidTarget`, `InvalidHeader`, `InvalidBodyLimit`, `InvalidBatch`.
