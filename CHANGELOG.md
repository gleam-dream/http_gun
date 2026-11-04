# Changelog

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
