//// Describes why an HTTP request, a body read or a scripted exchange failed.
////
//// A `Failure` is opaque. Branch on its closed `Kind` with `kind`, and ask
//// `is_retryable` whether sending the request again is safe:
////
//// ```gleam
//// case http_gun.send(client, req) {
////   Ok(buffered) -> handle(buffered.response)
////   Error(failure) ->
////     case error.is_retryable(failure, idempotent: False) {
////       True -> retry_later()
////       False -> give_up(error.describe(failure))
////     }
//// }
//// ```
////
//// Every failure carries submission `Evidence`: `NotSent` when the request
//// never reached the network, `MaybeSent` when the server may have received
//// it. Neither proves the server acted. `status` returns the response status
//// when final headers had arrived before the failure, for example when a body
//// exceeded its limit, and `headers` returns that response's headers, so a
//// caller can still read `retry-after` from a 429 whose body was too large.
////
//// `Reason` gives detail and may gain variants in a minor release; match it
//// with a `_` arm, and branch on `Kind` instead where you can. `name` is a
//// stable identifier for logs and stored records, and `to_json` with
//// `decoder` round-trips a failure. A failure never holds a URL, header,
//// query or body from the request; the response headers it may hold have
//// the client's redaction applied (`config.with_redaction`).

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import http_gun/destination

/// Whether the request may have reached the server. A failure never reports
/// a completed exchange: a completed exchange is a response.
pub type Evidence {
  /// The request was refused or failed before any byte reached the network.
  /// Sending it again cannot duplicate an effect.
  NotSent
  /// The request may have reached the server, which may have acted on it.
  MaybeSent
}

/// The closed classification of a failure. It never gains variants, so an
/// exhaustive match on it keeps compiling across minor releases.
pub type Kind {
  /// The request or a per-call setting is malformed. Fix the caller.
  InvalidInput
  /// The destination policy refused the host or a resolved address, or the
  /// client requires a view destination and the view set none.
  Refused
  /// The client is stopped, restarting or full, it timed out waiting for a
  /// connection from its pool, or its recording closed.
  Unavailable
  /// Name resolution, connecting, TLS or the exchange itself failed.
  Network
  /// A connect, request or idle timeout expired.
  TimedOut
  /// A size limit was exceeded.
  TooLarge
  /// The caller cancelled the request or closed its body.
  CancelledLocally
  /// The body was read concurrently or from a process that does not own it.
  Misuse
  /// A scripted or cassette client found no matching exchange.
  Playback
}

/// What was wrong with a request or a per-call setting.
/// May gain variants in a minor release.
pub type RequestProblem {
  /// The body is a bit array whose size is not a whole number of bytes.
  BodyNotBytes
  /// The method is not an HTTP token.
  InvalidMethod
  /// The host is empty or malformed, or the port is outside 1..65535.
  InvalidOrigin
  /// The path or query contains whitespace or control characters, or the
  /// path does not start with `/`.
  InvalidTarget
  /// A header name is not a lowercase token, or a value contains CR, LF or
  /// NUL.
  InvalidHeader
  /// A body limit set with `http_gun.with_body_limit` is negative.
  InvalidBodyLimit
  /// A batch needs 1 to 1,024 workers and at most 10,000 requests.
  InvalidBatch
}

/// The category and unit of a size limit. May gain variants in a minor
/// release.
pub type LimitKind {
  RequestBodyBytes
  RequestHeaderBytes
  RequestHeaderCount
  ResponseHeaderBytes
  ResponseHeaderCount
  /// Response bytes buffered between the network and the reader
  /// (`config.with_max_buffered_bytes`).
  BufferedBytes
  /// Body bytes collected by `send` or `batch`
  /// (`config.with_max_response_body_bytes`, `http_gun.with_body_limit`).
  ResponseBodyBytes
  /// Body bytes retained by one `batch` call (`config.with_max_batch_bytes`).
  BatchBytes
}

/// A stable category of transport error. `UnknownTransport` keeps the
/// uncertainty; no dependency term or server-supplied text is exposed. May
/// gain variants in a minor release.
pub type TransportCause {
  NameResolutionFailed
  ConnectionRefused
  CertificateRejected
  TlsFailed
  ConnectionReset
  PeerClosed
  PeerDraining
  ProtocolError
  /// Gun refused a response header or trailer list over its count limit
  /// before delivering it. Gun does not report the measured value.
  HeaderLimitReached
  TransportTimeout
  UnexpectedProtocol
  UnknownTransport
}

/// Why a request failed, in detail. May gain variants in a minor release:
/// match it with a `_` arm, or branch on `kind`.
pub type Reason {
  InvalidRequest(RequestProblem)
  /// The client is stopped, or restarting under its supervisor.
  ClientClosed
  /// The client's queue of waiting requests is full.
  AdmissionFull
  /// No connection became available within the pool timeout.
  PoolTimeout
  DestinationRejected(destination.Rejection)
  /// The client was configured with `config.require_view_destination`, and
  /// the request's view chose no destination with `http_gun.with_destination`:
  /// no policy set a host list or refused an address class the client admits.
  ViewDestinationRequired
  ResolutionFailed
  /// Resolving and connecting did not finish within the connect timeout.
  ConnectTimeout
  ConnectionFailed(TransportCause)
  RequestFailed(TransportCause)
  /// The request timeout or the per-call deadline expired.
  DeadlineExceeded
  /// No bytes arrived within the idle timeout while a read was waiting.
  IdleTimeout
  ReadConflict
  WrongOwner
  /// The body was closed, or its owner or client stopped.
  Closed
  Cancelled
  LimitExceeded(kind: LimitKind, limit: Int, observed: Int)
  /// The request did not match the scripted exchange at this position,
  /// counted from 0. The exchange stays in place.
  PlaybackMismatch(position: Int)
  /// Every scripted exchange has been used.
  PlaybackExhausted
  /// The recording behind a recording client is finishing or finished.
  RecordingClosed
}

/// A failed operation: its reason, submission evidence and, when final
/// headers had arrived, the response status and headers.
pub opaque type Failure {
  Failure(
    reason: Reason,
    evidence: Evidence,
    status: Option(Int),
    headers: List(#(String, String)),
  )
}

/// Build a failure, for scripted replies and test doubles.
pub fn new(reason: Reason, evidence: Evidence) -> Failure {
  Failure(reason:, evidence:, status: None, headers: [])
}

/// Record the response status that had arrived before the failure.
pub fn with_status(failure: Failure, status: Int) -> Failure {
  Failure(..failure, status: Some(status))
}

/// Record the response headers that had arrived before the failure,
/// replacing any recorded before. The caller applies its own redaction.
pub fn with_headers(
  failure: Failure,
  headers: List(#(String, String)),
) -> Failure {
  Failure(..failure, headers:)
}

pub fn reason(failure: Failure) -> Reason {
  failure.reason
}

pub fn evidence(failure: Failure) -> Evidence {
  failure.evidence
}

/// The response status, when final headers had arrived before the failure.
/// A body over its limit fails with the status of the response it belonged to.
pub fn status(failure: Failure) -> Option(Int) {
  failure.status
}

/// The response headers, in arrival order with duplicates kept, when final
/// headers had arrived before a `send` or `batch` failure; otherwise `[]`.
/// The client's redaction (`config.with_redaction`) has removed its
/// listed headers, the credential headers by default. A streaming caller
/// already holds the headers in its `Response`.
///
/// ```gleam
/// // A 429 whose body exceeded `with_body_limit(_, _, Fail)`.
/// list.key_find(error.headers(failure), "retry-after")
/// ```
pub fn headers(failure: Failure) -> List(#(String, String)) {
  failure.headers
}

/// The closed classification of the failure.
pub fn kind(failure: Failure) -> Kind {
  case failure.reason {
    InvalidRequest(_) -> InvalidInput
    DestinationRejected(_) | ViewDestinationRequired -> Refused
    ClientClosed | AdmissionFull | PoolTimeout | RecordingClosed -> Unavailable
    ResolutionFailed | ConnectionFailed(_) | RequestFailed(_) -> Network
    ConnectTimeout | DeadlineExceeded | IdleTimeout -> TimedOut
    LimitExceeded(..) -> TooLarge
    Cancelled | Closed -> CancelledLocally
    ReadConflict | WrongOwner -> Misuse
    PlaybackMismatch(_) | PlaybackExhausted -> Playback
  }
}

/// Whether sending the same request again is safe and may succeed.
///
/// A `NotSent` failure of kind `Unavailable`, `Network` or `TimedOut` is
/// retryable. A `MaybeSent` failure of those kinds is retryable only for an
/// idempotent request, because the server may already have acted on it. No
/// other kind is retryable. HTTP Gun itself never retries.
pub fn is_retryable(failure: Failure, idempotent idempotent: Bool) -> Bool {
  case kind(failure), failure.evidence {
    Unavailable, NotSent | Network, NotSent | TimedOut, NotSent -> True
    Unavailable, MaybeSent | Network, MaybeSent | TimedOut, MaybeSent ->
      idempotent
    _, _ -> False
  }
}

/// A stable identifier for logs, metrics and stored records, such as
/// `"connection_failed.connection_refused"` or
/// `"limit_exceeded.response_body_bytes"`. `decoder` reads it back.
pub fn name(failure: Failure) -> String {
  case failure.reason {
    InvalidRequest(problem) -> "invalid_request." <> problem_tag(problem)
    ClientClosed -> "client_closed"
    AdmissionFull -> "admission_full"
    PoolTimeout -> "pool_timeout"
    DestinationRejected(rejection) ->
      "destination_rejected." <> rejection_tag(rejection)
    ViewDestinationRequired -> "view_destination_required"
    ResolutionFailed -> "resolution_failed"
    ConnectTimeout -> "connect_timeout"
    ConnectionFailed(cause) -> "connection_failed." <> cause_tag(cause)
    RequestFailed(cause) -> "request_failed." <> cause_tag(cause)
    DeadlineExceeded -> "deadline_exceeded"
    IdleTimeout -> "idle_timeout"
    ReadConflict -> "read_conflict"
    WrongOwner -> "wrong_owner"
    Closed -> "closed"
    Cancelled -> "cancelled"
    LimitExceeded(kind:, ..) -> "limit_exceeded." <> limit_tag(kind)
    PlaybackMismatch(_) -> "playback_mismatch"
    PlaybackExhausted -> "playback_exhausted"
    RecordingClosed -> "recording_closed"
  }
}

/// A one-line description for logs and user interfaces. It never contains a
/// URL, header, query or body.
pub fn describe(failure: Failure) -> String {
  let message = case failure.reason {
    InvalidRequest(problem) ->
      "Invalid HTTP request: " <> describe_problem(problem)
    ClientClosed -> "HTTP client closed"
    AdmissionFull -> "HTTP admission queue full"
    PoolTimeout -> "No connection available within the pool timeout"
    DestinationRejected(rejection) ->
      "Network destination rejected: " <> describe_rejection(rejection)
    ViewDestinationRequired ->
      "The client requires a destination set on the request's view"
    ResolutionFailed -> "Destination resolution failed"
    ConnectTimeout -> "Connect timeout exceeded"
    ConnectionFailed(cause) ->
      "Connection failed: " <> transport_description(cause)
    RequestFailed(cause) -> "Request failed: " <> transport_description(cause)
    DeadlineExceeded -> "Request deadline exceeded"
    IdleTimeout -> "No bytes received within the idle timeout"
    ReadConflict -> "Another read is pending"
    WrongOwner -> "Only the opening process may read this body"
    Closed -> "Response body closed"
    Cancelled -> "Request cancelled locally"
    LimitExceeded(kind, limit, observed) ->
      limit_description(kind)
      <> " limit "
      <> int.to_string(limit)
      <> "; observed "
      <> int.to_string(observed)
    PlaybackMismatch(position) ->
      "Request does not match scripted exchange " <> int.to_string(position)
    PlaybackExhausted -> "No scripted exchange left"
    RecordingClosed -> "Recording closed"
  }
  message
  <> case failure.status {
    Some(status) -> "; status " <> int.to_string(status)
    None -> ""
  }
  <> case failure.evidence {
    NotSent -> "; not sent"
    MaybeSent -> "; request may have been sent"
  }
}

/// Encode a failure as JSON, for stored records such as a durable step
/// error. `decoder` reads it back to an equal failure. Response headers, when
/// present, are stored as `[name, value]` pairs, after the client's
/// redaction.
///
/// ```json
/// {"name": "limit_exceeded.response_body_bytes", "evidence": "maybe_sent",
///  "status": 429, "headers": [["retry-after", "30"]],
///  "limit": 8388608, "observed": 8388609}
/// ```
pub fn to_json(failure: Failure) -> json.Json {
  let detail = case failure.reason {
    LimitExceeded(_, limit, observed) -> [
      #("limit", json.int(limit)),
      #("observed", json.int(observed)),
    ]
    PlaybackMismatch(position) -> [#("position", json.int(position))]
    _ -> []
  }
  let status = case failure.status {
    Some(status) -> [#("status", json.int(status))]
    None -> []
  }
  let headers = case failure.headers {
    [] -> []
    headers -> [
      #(
        "headers",
        json.array(headers, fn(header) {
          json.preprocessed_array([json.string(header.0), json.string(header.1)])
        }),
      ),
    ]
  }
  json.object([
    #("name", json.string(name(failure))),
    #("evidence", json.string(evidence_tag(failure.evidence))),
    ..list.flatten([status, headers, detail])
  ])
}

/// Decode the JSON that `to_json` writes. An unknown name fails to decode.
pub fn decoder() -> decode.Decoder(Failure) {
  use name <- decode.field("name", decode.string)
  use evidence <- decode.field("evidence", decode.string)
  use status <- decode.optional_field(
    "status",
    None,
    decode.int |> decode.map(Some),
  )
  use headers <- decode.optional_field(
    "headers",
    [],
    decode.list(
      decode.list(decode.string)
      |> decode.then(fn(pair) {
        case pair {
          [name, value] -> decode.success(#(name, value))
          _ -> decode.failure(#("", ""), "[name, value]")
        }
      }),
    ),
  )
  use limit <- decode.optional_field("limit", -1, decode.int)
  use observed <- decode.optional_field("observed", -1, decode.int)
  use position <- decode.optional_field("position", -1, decode.int)
  let evidence = case evidence {
    "not_sent" -> Ok(NotSent)
    "maybe_sent" -> Ok(MaybeSent)
    _ -> Error(Nil)
  }
  let reason = parse_name(name, limit, observed, position)
  case reason, evidence {
    Ok(reason), Ok(evidence) ->
      decode.success(Failure(reason:, evidence:, status:, headers:))
    _, _ -> decode.failure(new(ClientClosed, NotSent), "http_gun failure")
  }
}

fn parse_name(
  name: String,
  limit: Int,
  observed: Int,
  position: Int,
) -> Result(Reason, Nil) {
  let #(head, tail) = case string.split_once(name, ".") {
    Ok(#(head, tail)) -> #(head, tail)
    Error(Nil) -> #(name, "")
  }
  case head, tail {
    "invalid_request", tag -> result.map(parse_problem(tag), InvalidRequest)
    "client_closed", "" -> Ok(ClientClosed)
    "admission_full", "" -> Ok(AdmissionFull)
    "pool_timeout", "" -> Ok(PoolTimeout)
    "destination_rejected", tag ->
      result.map(parse_rejection(tag), DestinationRejected)
    "view_destination_required", "" -> Ok(ViewDestinationRequired)
    "resolution_failed", "" -> Ok(ResolutionFailed)
    "connect_timeout", "" -> Ok(ConnectTimeout)
    "connection_failed", tag -> result.map(parse_cause(tag), ConnectionFailed)
    "request_failed", tag -> result.map(parse_cause(tag), RequestFailed)
    "deadline_exceeded", "" -> Ok(DeadlineExceeded)
    "idle_timeout", "" -> Ok(IdleTimeout)
    "read_conflict", "" -> Ok(ReadConflict)
    "wrong_owner", "" -> Ok(WrongOwner)
    "closed", "" -> Ok(Closed)
    "cancelled", "" -> Ok(Cancelled)
    "limit_exceeded", tag if limit >= 0 && observed >= 0 ->
      result.map(parse_limit(tag), fn(kind) {
        LimitExceeded(kind, limit, observed)
      })
    "playback_mismatch", "" if position >= 0 -> Ok(PlaybackMismatch(position))
    "playback_exhausted", "" -> Ok(PlaybackExhausted)
    "recording_closed", "" -> Ok(RecordingClosed)
    _, _ -> Error(Nil)
  }
}

fn evidence_tag(evidence: Evidence) -> String {
  case evidence {
    NotSent -> "not_sent"
    MaybeSent -> "maybe_sent"
  }
}

const problems = [
  BodyNotBytes,
  InvalidMethod,
  InvalidOrigin,
  InvalidTarget,
  InvalidHeader,
  InvalidBodyLimit,
  InvalidBatch,
]

fn problem_tag(problem: RequestProblem) -> String {
  case problem {
    BodyNotBytes -> "body_not_bytes"
    InvalidMethod -> "invalid_method"
    InvalidOrigin -> "invalid_origin"
    InvalidTarget -> "invalid_target"
    InvalidHeader -> "invalid_header"
    InvalidBodyLimit -> "invalid_body_limit"
    InvalidBatch -> "invalid_batch"
  }
}

fn parse_problem(tag: String) -> Result(RequestProblem, Nil) {
  list.find(problems, fn(problem) { problem_tag(problem) == tag })
}

fn describe_problem(problem: RequestProblem) -> String {
  case problem {
    BodyNotBytes -> "body is not whole bytes"
    InvalidMethod -> "invalid method"
    InvalidOrigin -> "invalid host or port"
    InvalidTarget -> "invalid path or query"
    InvalidHeader -> "invalid header"
    InvalidBodyLimit -> "body limit is negative"
    InvalidBatch -> "batch needs 1..1024 workers and at most 10000 requests"
  }
}

fn rejection_tag(rejection: destination.Rejection) -> String {
  case rejection {
    destination.HostNotAllowed -> "host_not_allowed"
    destination.AddressRefused(class) -> class_tag(class)
    destination.PlaintextRefused(class) -> "plaintext_" <> class_tag(class)
  }
}

fn class_tag(class: destination.Class) -> String {
  case class {
    destination.Public -> "public"
    destination.Loopback -> "loopback"
    destination.Private -> "private"
    destination.Reserved -> "reserved"
  }
}

fn parse_rejection(tag: String) -> Result(destination.Rejection, Nil) {
  case tag {
    "host_not_allowed" -> Ok(destination.HostNotAllowed)
    "public" -> Ok(destination.AddressRefused(destination.Public))
    "loopback" -> Ok(destination.AddressRefused(destination.Loopback))
    "private" -> Ok(destination.AddressRefused(destination.Private))
    "reserved" -> Ok(destination.AddressRefused(destination.Reserved))
    "plaintext_public" -> Ok(destination.PlaintextRefused(destination.Public))
    "plaintext_loopback" ->
      Ok(destination.PlaintextRefused(destination.Loopback))
    "plaintext_private" -> Ok(destination.PlaintextRefused(destination.Private))
    "plaintext_reserved" ->
      Ok(destination.PlaintextRefused(destination.Reserved))
    _ -> Error(Nil)
  }
}

fn describe_rejection(rejection: destination.Rejection) -> String {
  case rejection {
    destination.HostNotAllowed -> "host or port not allowed"
    destination.AddressRefused(_) ->
      rejection_tag(rejection) <> " address refused"
    destination.PlaintextRefused(class) ->
      "plaintext HTTP to a " <> class_tag(class) <> " address refused"
  }
}

const limits = [
  RequestBodyBytes,
  RequestHeaderBytes,
  RequestHeaderCount,
  ResponseHeaderBytes,
  ResponseHeaderCount,
  BufferedBytes,
  ResponseBodyBytes,
  BatchBytes,
]

fn limit_tag(kind: LimitKind) -> String {
  case kind {
    RequestBodyBytes -> "request_body_bytes"
    RequestHeaderBytes -> "request_header_bytes"
    RequestHeaderCount -> "request_header_count"
    ResponseHeaderBytes -> "response_header_bytes"
    ResponseHeaderCount -> "response_header_count"
    BufferedBytes -> "buffered_bytes"
    ResponseBodyBytes -> "response_body_bytes"
    BatchBytes -> "batch_bytes"
  }
}

fn parse_limit(tag: String) -> Result(LimitKind, Nil) {
  list.find(limits, fn(kind) { limit_tag(kind) == tag })
}

fn limit_description(kind: LimitKind) -> String {
  case kind {
    RequestBodyBytes -> "Request body bytes"
    RequestHeaderBytes -> "Request header bytes"
    RequestHeaderCount -> "Request header count"
    ResponseHeaderBytes -> "Response header bytes"
    ResponseHeaderCount -> "Response header count"
    BufferedBytes -> "Buffered response bytes"
    ResponseBodyBytes -> "Response body bytes"
    BatchBytes -> "Batch body bytes"
  }
}

const causes = [
  NameResolutionFailed,
  ConnectionRefused,
  CertificateRejected,
  TlsFailed,
  ConnectionReset,
  PeerClosed,
  PeerDraining,
  ProtocolError,
  HeaderLimitReached,
  TransportTimeout,
  UnexpectedProtocol,
  UnknownTransport,
]

fn cause_tag(cause: TransportCause) -> String {
  case cause {
    NameResolutionFailed -> "name_resolution_failed"
    ConnectionRefused -> "connection_refused"
    CertificateRejected -> "certificate_rejected"
    TlsFailed -> "tls_failed"
    ConnectionReset -> "connection_reset"
    PeerClosed -> "peer_closed"
    PeerDraining -> "peer_draining"
    ProtocolError -> "protocol_error"
    HeaderLimitReached -> "header_limit_reached"
    TransportTimeout -> "transport_timeout"
    UnexpectedProtocol -> "unexpected_protocol"
    UnknownTransport -> "unknown_transport"
  }
}

fn parse_cause(tag: String) -> Result(TransportCause, Nil) {
  list.find(causes, fn(cause) { cause_tag(cause) == tag })
}

fn transport_description(cause: TransportCause) -> String {
  string.replace(cause_tag(cause), "_", " ")
}
