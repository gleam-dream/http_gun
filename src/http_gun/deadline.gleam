//// A monotonic time budget shared by several calls on one VM.
////
//// Create one with `after` before a unit of work and give each request the
//// remaining budget with `http_gun.with_deadline`:
////
//// ```gleam
//// let budget = deadline.after(60_000)
//// let client = client |> http_gun.with_deadline(budget)
//// let first = http_gun.send(client, first_request)
//// let second = http_gun.send(client, second_request) // shares the 60 s
//// ```
////
//// A `Deadline` is VM-local: do not persist it or send it to another node.

import gleam/int
import http_gun/internal/bridge

pub opaque type Deadline {
  Deadline(at: Int)
}

/// A budget that ends `milliseconds` from now. Zero or a negative value is
/// already expired.
pub fn after(milliseconds: Int) -> Deadline {
  Deadline(bridge.now() + int.max(0, milliseconds))
}

/// Remaining whole milliseconds, clamped to zero. Reading does not renew it.
pub fn remaining_ms(deadline: Deadline) -> Int {
  int.max(0, deadline.at - bridge.now())
}
