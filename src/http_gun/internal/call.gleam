import gleam/erlang/atom
import gleam/erlang/process
import http_gun/error.{type Failure}

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

/// Like `with_failure`, but tells apart a process that was never reached
/// (`not_running`: not registered, or already dead when monitored) from one
/// that exited after the message may have arrived (`lost`).
pub fn with_failures(
  subject: process.Subject(message),
  make: fn(process.Subject(Result(value, failure))) -> message,
  not_running not_running: failure,
  lost lost: failure,
) -> Result(value, failure) {
  case process.subject_owner(subject) {
    Error(Nil) -> Error(not_running)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(subject, make(reply))
      let noproc = process.Abnormal(atom.to_dynamic(atom.create("noproc")))
      let response =
        process.new_selector()
        |> process.select(reply)
        |> process.select_specific_monitor(monitor, fn(down) {
          case down {
            process.ProcessDown(reason:, ..) if reason == noproc ->
              Error(not_running)
            _ -> Error(lost)
          }
        })
        |> process.selector_receive_forever
      process.demonitor_process(monitor)
      response
    }
  }
}
