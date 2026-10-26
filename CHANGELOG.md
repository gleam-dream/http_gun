# Changelog

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
