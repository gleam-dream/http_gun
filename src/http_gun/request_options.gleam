//// Execution controls; these never change the HTTP request or cassette key.

import gleam/option.{type Option, None, Some}
import http_gun/cancellation
import http_gun/deadline

/// What buffered collection does when a response body exceeds its limit.
pub type Overflow {
  /// Close the body and fail with `LimitExceeded(CollectedBodyBytes, ..)`.
  /// The failure carries no response status or headers.
  Fail
  /// Close the body and return the status, headers and the first `limit`
  /// body bytes, with `Buffered.truncated` set and no trailers. Use this when
  /// the status decides the outcome, e.g. a delivery a peer may have accepted.
  Truncate
}

/// A per-request collection policy for `send_with_options`. The limit is in
/// body bytes, must be non-negative, and replaces the client's `collect_bytes`
/// for this call only.
pub type Collect {
  Collect(limit: Int, overflow: Overflow)
}

pub type Options {
  Options(
    deadline: Option(deadline.Deadline),
    cancellation: Option(cancellation.Token),
    /// `None` collects up to the client's `collect_bytes` and fails on overflow.
    collect: Option(Collect),
  )
}

/// Use the client's request deadline and collection limit with no external
/// cancellation token.
pub fn default() -> Options {
  Options(None, None, None)
}

@internal
pub fn cancelled(options: Options) -> Bool {
  case options.cancellation {
    None -> False
    Some(token) -> cancellation.is_cancelled(token)
  }
}
