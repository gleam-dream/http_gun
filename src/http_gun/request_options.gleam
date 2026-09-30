//// Execution controls; these never change the HTTP request or cassette key.

import gleam/option.{type Option, None, Some}
import http_gun/cancellation
import http_gun/deadline

pub type Options {
  Options(
    deadline: Option(deadline.Deadline),
    cancellation: Option(cancellation.Token),
  )
}

/// Use the client's request deadline with no external cancellation token.
pub fn default() -> Options {
  Options(None, None)
}

@internal
pub fn cancelled(options: Options) -> Bool {
  case options.cancellation {
    None -> False
    Some(token) -> cancellation.is_cancelled(token)
  }
}
