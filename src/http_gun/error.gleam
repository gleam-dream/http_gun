import gleam/int

/// Submission evidence is conservative; neither alternative proves execution.
pub type Evidence {
  NotSubmitted
  MayHaveBeenSent
}

/// Category and units of an application admission limit.
pub type LimitKind {
  RequestBodyBytes
  RequestHeaderBytes
  RequestHeaderCount
  ResponseHeaderBytes
  ResponseHeaderCount
  ResponseChunkBytes
  ResponseQueueBytes
  CollectedBodyBytes
  FixtureBytes
}

/// Stable categories from supported transport errors. UnknownTransport retains
/// uncertainty; no dependency term or server-controlled diagnostic is exposed.
pub type TransportCause {
  NameResolutionFailed
  ConnectionRefused
  CertificateRejected
  TlsFailed
  ConnectionReset
  PeerClosed
  PeerDraining
  ProtocolError
  TransportTimeout
  UnexpectedProtocol
  UnknownTransport
}

pub type FileOperation {
  OpenFile
  ReadFile
  WriteFile
  CloseFile
  CreateDirectory
  SetPermissions
  PublishFixture
}

pub type FileCause {
  FileMissing
  AlreadyExists
  PermissionDenied
  NoSpace
  ReadOnlyFilesystem
  NotDirectory
  IsDirectory
  CrossFilesystem
  UnknownIoFailure
}

pub type Reason {
  InvalidConfig(String)
  InvalidRequest(String)
  ClientClosed
  AdmissionFull
  ConnectionFailed(TransportCause)
  RequestFailed(TransportCause)
  DeadlineExceeded
  ReadTimeout
  ReadConflict
  WrongOwner
  Closed
  Cancelled
  LimitExceeded(kind: LimitKind, limit: Int, observed: Int)
  FixtureMissing
  FixtureIo(FileOperation, FileCause)
  FixtureCorrupt
  FixtureVersion(Int)
  FixtureExhausted
  FixtureMismatch(position: Int)
  CaptureFailed(String)
}

pub type Failure {
  Failure(reason: Reason, evidence: Evidence)
}

/// A bounded vocabulary for logs/UI. Never includes free-form failure details,
/// paths, URLs, headers, bodies or queries. Pattern-match Failure for decisions.
pub fn describe(failure: Failure) -> String {
  let message = case failure.reason {
    InvalidConfig(_) -> "Invalid client configuration"
    InvalidRequest(_) -> "Invalid HTTP request"
    ClientClosed -> "HTTP client closed"
    AdmissionFull -> "HTTP admission limit reached"
    ConnectionFailed(cause) ->
      "Connection failed: " <> transport_description(cause)
    RequestFailed(cause) -> "Request failed: " <> transport_description(cause)
    DeadlineExceeded -> "Request deadline exceeded"
    ReadTimeout -> "Read wait timed out"
    ReadConflict -> "Another read is pending"
    WrongOwner -> "Only the opening process may read this body"
    Closed -> "Response body closed"
    Cancelled -> "Request cancelled locally"
    LimitExceeded(kind, limit, observed) -> {
      limit_description(kind)
      <> " limit "
      <> int.to_string(limit)
      <> "; observed "
      <> int.to_string(observed)
    }
    FixtureMissing -> "Fixture missing"
    FixtureIo(operation, cause) -> file_description(operation, cause)
    FixtureCorrupt -> "Fixture corrupt"
    FixtureVersion(_) -> "Fixture version unsupported"
    FixtureExhausted -> "Fixture exhausted"
    FixtureMismatch(position) ->
      "Fixture mismatch at exchange " <> int.to_string(position)
    CaptureFailed(_) -> "Recording unavailable"
  }
  message
  <> case failure.evidence {
    NotSubmitted -> "; not submitted"
    MayHaveBeenSent -> "; request may have been sent"
  }
}

fn limit_description(kind: LimitKind) -> String {
  case kind {
    RequestBodyBytes -> "Request body bytes"
    RequestHeaderBytes -> "Request header bytes"
    RequestHeaderCount -> "Request header count"
    ResponseHeaderBytes -> "Response header bytes"
    ResponseHeaderCount -> "Response header count"
    ResponseChunkBytes -> "Response chunk bytes"
    ResponseQueueBytes -> "Retained response bytes"
    CollectedBodyBytes -> "Collected body bytes"
    FixtureBytes -> "Fixture bytes"
  }
}

fn transport_description(cause: TransportCause) -> String {
  case cause {
    NameResolutionFailed -> "name resolution failed"
    ConnectionRefused -> "connection refused"
    CertificateRejected -> "certificate rejected"
    TlsFailed -> "TLS failed"
    ConnectionReset -> "connection reset"
    PeerClosed -> "peer closed"
    PeerDraining -> "peer draining"
    ProtocolError -> "protocol error"
    TransportTimeout -> "transport timeout"
    UnexpectedProtocol -> "unexpected negotiated protocol"
    UnknownTransport -> "cause unavailable"
  }
}

@internal
pub fn file_description(operation: FileOperation, cause: FileCause) -> String {
  let operation = case operation {
    OpenFile -> "Opening file"
    ReadFile -> "Reading file"
    WriteFile -> "Writing file"
    CloseFile -> "Closing file"
    CreateDirectory -> "Creating directory"
    SetPermissions -> "Setting permissions"
    PublishFixture -> "Publishing fixture"
  }
  operation
  <> " failed: "
  <> case cause {
    FileMissing -> "file missing"
    AlreadyExists -> "already exists"
    PermissionDenied -> "permission denied"
    NoSpace -> "no space available"
    ReadOnlyFilesystem -> "read-only filesystem"
    NotDirectory -> "not a directory"
    IsDirectory -> "is a directory"
    CrossFilesystem -> "cross-filesystem operation"
    UnknownIoFailure -> "cause unavailable"
  }
}
