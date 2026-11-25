import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import http_gun/error.{type Failure}
import http_gun/internal/bridge

/// How long a caller waits past its deadline for the answer of the process
/// that enforces that deadline, before ending the wait itself.
pub const grace = 500

/// A subject for one exchange whose replies the runtime drops once
/// `retire` has run, including replies already sent but not yet received.
@external(erlang, "http_gun_ffi", "reply_alias")
pub fn reply() -> process.Subject(message)

@external(erlang, "http_gun_ffi", "retire_alias")
pub fn retire(reply: process.Subject(message)) -> Nil

/// Wait for a message from `selector` until the monotonic time `until`, in
/// milliseconds. `Error(Nil)` when the time passes first.
pub fn receive_until(
  selector: process.Selector(message),
  until: Int,
) -> Result(message, Nil) {
  let left = until - bridge.now()
  case left <= 0 {
    True -> process.selector_receive(selector, 0)
    False ->
      // A receive timeout is at most 2^32 - 1 ms; wait in steps below it.
      case process.selector_receive(selector, int.min(left, longest_step)) {
        Ok(message) -> Ok(message)
        Error(Nil) if left > longest_step -> receive_until(selector, until)
        Error(Nil) -> Error(Nil)
      }
  }
}

const longest_step = 86_400_000

/// Why a call ended without its reply.
pub type Unanswered {
  /// The process was not registered, or was already dead when monitored.
  NotRunning
  /// The process exited after the request may have arrived.
  Lost
  /// The process is alive but did not answer before `until` plus `grace`.
  Expired
}

/// Send one request built around a reply subject and wait for the reply
/// until `until` plus `grace`. However the wait ends, no later reply reaches
/// the caller's mailbox.
pub fn ask(
  subject: process.Subject(message),
  make: fn(process.Subject(reply)) -> message,
  until: Int,
) -> Result(reply, Unanswered) {
  case process.subject_owner(subject) {
    Error(Nil) -> Error(NotRunning)
    Ok(pid) -> {
      let reply = reply()
      let monitor = process.monitor(pid)
      process.send(subject, make(reply))
      let noproc = process.Abnormal(atom.to_dynamic(atom.create("noproc")))
      let response =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(down) {
          case down {
            process.ProcessDown(reason:, ..) if reason == noproc ->
              Error(NotRunning)
            _ -> Error(Lost)
          }
        })
        |> receive_until(until + grace)
      process.demonitor_process(monitor)
      retire(reply)
      case response {
        Ok(answer) -> answer
        Error(Nil) -> Error(Expired)
      }
    }
  }
}

// Unlike process.call, process death is an ordinary typed result.
pub fn run(
  subject: process.Subject(message),
  make: fn(process.Subject(Result(value, Failure))) -> message,
) -> Result(value, Failure) {
  with_failure(subject, make, error.new(error.ClientClosed, error.NotSent))
}

pub fn with_failure(
  subject: process.Subject(message),
  make: fn(process.Subject(Result(value, failure))) -> message,
  unavailable: failure,
) -> Result(value, failure) {
  case process.subject_owner(subject) {
    Error(Nil) -> Error(unavailable)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(subject, make(reply))
      let response =
        process.new_selector()
        |> process.select(reply)
        |> process.select_specific_monitor(monitor, fn(_) { Error(unavailable) })
        |> process.selector_receive_forever
      process.demonitor_process(monitor)
      response
    }
  }
}
