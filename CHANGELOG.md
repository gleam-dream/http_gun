# Changelog

## Unreleased

> [!WARNING]
> This release breaks the request timeout API and changes when calls end.
> Read the [migration guide](https://github.com/gleam-dream/http_gun/blob/main/docs/MIGRATION.md)
> before upgrading from 0.3.

### Changed

- Every call has a finite deadline that the calling process enforces: the
  view's deadline, its timeout, the earlier of the two, or 30 seconds from the
  call. The caller waits until the deadline plus 500 ms and then returns
  `DeadlineExceeded` with `MaybeSent`; body reads, body closes and pool
  queries are bounded the same way, and a late reply never reaches the
  caller's mailbox. A timeout of zero or less fails at once with `NotSent`.
  See ADR 0021.
- `http_gun.with_timeout` takes a `Duration` instead of a `config.Timeout`;
  `config.Infinity` no longer lifts the request bound.
- Gun's own closing timer is off (`closing_timeout => infinity`), so a
  streamed response after `connection: close` or an HTTP/2 GOAWAY is no
  longer cut at 15 seconds. A body owner that loses its client closes its
  connection. See ADR 0024.
- A request Gun refuses on a closing connection fails with
  `RequestFailed(PeerDraining)` and `NotSent` instead of `MaybeSent`, so
  `error.is_retryable` allows it for any method. See ADR 0023.
- The pool admits no new stream to a connection whose peer is going away and
  closes it when its last stream ends.
- Response, informational and trailer header names and values that are not
  UTF-8 are read as ISO-8859-1, so every header string is text.
- A cold origin prepares up to its per-origin limit of connections at once.
  See ADR 0022.
- HTTP Gun depends on `sinal >= 0.2.0 and < 0.3.0`, which removes a handler
  when the process that attached it exits.
- `testing.VerifyError` gains `NotAnswered` for a client that does not
  answer before the view's deadline; `ClientStopped` means only a stopped
  client. See ADR 0026.
- `body.next_within` ends within its wait plus the grace even when the body
  owner cannot answer, and a chunk sent to a read the reader gave up is
  delivered to the next read. A read from the owning process replaces a read
  it gave up instead of failing with `ReadConflict`. See ADR 0025.

### Removed

- `config.with_request_timeout` and the `config.RequestTimeout` setting. Set
  the timeout on the client handle with `http_gun.with_timeout`.

### Fixed

- `http_gun.batch` no longer runs without its byte limit when the client does
  not report the limit in time; every position then fails with
  `DeadlineExceeded` and `NotSent`.
- An HTTP/2 connection waiting for the peer's first SETTINGS counts as a
  preparation, so the pool does not open more connections for the same
  waiters meanwhile.
- A connection prepared for one request is bounded by its own connect budget,
  not by the deadline of the request at the head of the lane.
- A body owner that exits before the response head no longer leaves its
  caller waiting; the call fails with `RequestFailed(UnknownTransport)` and
  `MaybeSent`.

## 0.3.0 - 2026-11-23

### Added

- `client_identity.from_signer(certificates, signer)` builds a client identity
  whose private key never enters HTTP Gun: `client_identity.RsaSigner(sign)`
  receives a `client_identity.RsaRequest` (the message to sign, its `Hash`
  and its `RsaScheme`, PKCS#1 v1.5 or PSS with salt length and MGF1 hash) and
  returns the signature or `Error(Nil)`. `Signer` may gain variants for other
  key kinds. The signer runs in the connection's ssl process once per full
  handshake that requests a client certificate; see the function's
  documentation for timing, timeouts and renegotiation. `from_pem` is
  unchanged. See ADR 0020.

### New variants

These types may gain variants in minor releases. Match the variants you handle
explicitly and keep a catch-all for the rest, or classify failures with
`error.kind`.

- `error.TransportCause`: `ClientSigningFailed`. A signer identity's signer
  refused or failed during the opening TLS handshake, so the client ended it.
  The request fails with `ConnectionFailed(ClientSigningFailed)` and
  `NotSent`; its name is `connection_failed.client_signing_failed`. Its kind
  is `error.Refused`, so `error.is_retryable` is false: HTTP Gun cannot tell
  a signer that declined from one that was unreachable, and the application
  that owns the signer decides whether to try again. A server refusal stays
  `CertificateRejected` or `TlsFailed`.

## 0.2.0 - 2026-11-18

> [!WARNING]
> This release does not read the cassettes HTTP Gun 0.1.0 and 0.1.1 wrote
> (schema 2): loading one fails with `UnsupportedVersion(2)`. Convert every
> cassette on commit `0974868` before moving to this release, as
> [Upgrading cassettes](#upgrading-cassettes) describes. `cassette.encode`
> also no longer removes credentials; see [Security](#security).

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

### Security

- `cassette.encode` no longer removes credentials: it lays a script out as
  given. Since 0.1.0 it promised never to write credential headers, and since
  0.1.1 it replaced credential fields. Code that encodes hand-built or parsed
  scripts must apply `cassette.redact(script, redaction.default())` first;
  recordings are redacted as they are captured, as before.

### Changed

- Cassettes are written and read in schema 3 (`"http_gun": 3`); schema 2
  files are no longer read, and `cassette.describe_error` of
  `UnsupportedVersion(2)` says how to convert one. Schema 3 lays a cassette out over many lines, each header
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

- This release reads schema 3 only. Commit
  `0974868199378dd774e5979bff8f503cf645fd4c` is the last that reads schema
  2, and it writes the same schema 3 as this release. Convert on it, then
  move on:
  1. Depend on that commit:
     `http_gun = { git = "https://github.com/gleam-dream/http_gun", ref = "0974868199378dd774e5979bff8f503cf645fd4c" }`.
  2. For each cassette, read the file, apply `cassette.parse(text, max_bytes)`
     then `cassette.encode`, parse the result to check it, and write it back.
     No credentials, no network. `encode` applies no redaction, so no
     recorded answer changes. To clean a file recorded before field
     redaction existed, apply `cassette.redact` on purpose.
  3. Commit the converted files, then depend on this release.
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
  credential fields; a hand-built or parsed script now keeps, when encoded,
  every credential it holds: a `set-cookie` or other credential response or
  trailer header, failure headers, credential fields in bodies, and, for a
  parsed or hand-edited script, request credentials too (`testing.exchange`
  still redacts the request it builds). Apply
  `cassette.redact(script, redaction.default())` first, as recording already
  does. `cassette.encode` of a hand-built script whose target a client
  could not send (an empty host, port 0, a path without a leading `/`) writes
  a file `parse` refuses as `Corrupt`; schema 2 loaded such files. An older
  HTTP Gun reading a schema 3 file fails with
  `UnsupportedVersion(3)`, and this release reading a schema 2 file fails
  with `UnsupportedVersion(2)`; code comparing `cassette.encode` output with a
  stored string sees the new layout; a `load` limit set close to a file's
  schema 2 size can fail with `TooLarge` (a streamed answer grows by about a
  quarter); `cassette.record` with a budget below 42 bytes now fails at once
  with `CaptureLimit` instead of at the first request; and a recording that
  fit its budget under schema 2 can now exceed it, since the same exchanges
  store more bytes and every stored byte is charged. Convert in one commit
  of your own, so no re-record mixes a format change with a content change.

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
