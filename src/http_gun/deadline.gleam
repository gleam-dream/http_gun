//// A monotonic time budget shared by several calls on one VM.
////
//// Create one with `after` before a unit of work and give each request the
//// remaining budget with `http_gun.with_deadline`:
////
//// ```gleam
//// let budget = deadline.after(duration.seconds(60))
//// let client = client |> http_gun.with_deadline(budget)
//// let first = http_gun.send(client, first_request)
//// let second = http_gun.send(client, second_request) // shares the 60 s
//// ```
////
//// A `Deadline` is VM-local: do not persist it or send it to another node.

import gleam/int
import gleam/time/duration.{type Duration}
import http_gun/internal/bridge
import http_gun/internal/settings

pub opaque type Deadline {
  Deadline(at: Int)
}

/// A budget that ends `budget` from now, in whole milliseconds. Zero or a
/// negative budget is already expired.
pub fn after(budget: Duration) -> Deadline {
  Deadline(bridge.now() + int.max(0, settings.milliseconds(budget)))
}

/// The time left, in whole milliseconds and clamped to zero. Reading does
/// not renew it.
pub fn remaining(deadline: Deadline) -> Duration {
  duration.milliseconds(int.max(0, deadline.at - bridge.now()))
}
