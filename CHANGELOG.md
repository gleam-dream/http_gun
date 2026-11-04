# Changelog

## Unreleased

### Security

- `redaction.default()` now also keeps credentials outside headers out of
  cassettes. It replaces the value of credential query parameters (`key`,
  `api_key`, `apikey`, `access_token`, `token`, `client_secret`, `code`,
  `refresh_token`, `id_token`, `signature`, `sig`, `x-amz-security-token`,
  `x-goog-api-key` and the AWS spellings `Signature`, `X-Amz-Signature`,
  `X-Amz-Credential`, `X-Amz-Security-Token`) with `REDACTED`, and replaces
  credential fields in `application/x-www-form-urlencoded` and JSON request
  and response bodies (`client_secret`, `access_token`, `refresh_token`,
  `id_token`, `api_key`, `password`, `secret`, `token`, `authorization`, plus
  the query names in form bodies). Previously a recorded OAuth token exchange
  stored the client secret, authorization code and tokens verbatim.
- The default removed headers add `x-auth-token`, `x-access-token`,
  `x-amz-security-token` and `x-csrf-token`.
- Recorded cassettes and their staged files are created with mode `0600`
  instead of inheriting the process umask.

### Changed

- Playback applies the same default redaction to both sides, so a recorded
  request still matches its live request; a redacted value now matches any
  live value of that parameter or field. A recording buffers form and JSON
  response bodies whole (within its byte budget) and stores them as one
  chunk, and `cassette.encode` stores those response bodies the same way.
- Bodies with other content types, non-UTF-8 form bodies, JSON bodies that do
  not scan and bodies above 16 MiB are stored as before; use
  `redaction.with_body` for them.

### Added

- `redaction.with_body_fields` adds field names to replace in form and JSON
  bodies.
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
