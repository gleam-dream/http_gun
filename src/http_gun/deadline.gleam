//// Monotonic budgets shared across preparation and HTTP calls on this VM.

import gleam/int
import http_gun/error
import http_gun/internal/bridge

pub opaque type Deadline {
  Deadline(at: Int)
}

/// Create a budget now. Zero is already expired; negative values are invalid.
/// This value is VM-local and must not be persisted or sent to another node.
pub fn after(milliseconds: Int) -> Result(Deadline, error.Failure) {
  case milliseconds < 0 {
    True ->
      Error(error.Failure(
        error.InvalidConfig("deadline must not be negative"),
        error.NotSubmitted,
      ))
    False -> Ok(Deadline(bridge.now() + milliseconds))
  }
}

/// Remaining whole milliseconds, clamped to zero. Reading does not renew it.
pub fn remaining_ms(deadline: Deadline) -> Int {
  int.max(0, deadline.at - bridge.now())
}

@internal
pub fn timestamp(deadline: Deadline) -> Int {
  deadline.at
}
