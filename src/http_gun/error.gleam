/// Submission evidence is conservative; neither alternative proves execution.
pub type Evidence {
  NotSubmitted
  MayHaveBeenSent
}

pub type Reason {
  InvalidConfig(String)
  InvalidRequest(String)
  ClientClosed
  AdmissionFull
  ConnectionFailed
  RequestFailed
  DeadlineExceeded
  ReadTimeout
  ReadConflict
  WrongOwner
  Closed
  LimitExceeded(kind: String, limit: Int)
  FixtureMissing
  FixtureCorrupt
  FixtureVersion(Int)
  FixtureExhausted
  FixtureMismatch(position: Int)
  CaptureFailed(String)
}

pub type Failure {
  Failure(reason: Reason, evidence: Evidence)
}
