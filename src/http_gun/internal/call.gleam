import gleam/erlang/process
import http_gun/error.{type Failure, ClientClosed, Failure, NotSubmitted}

// Unlike process.call, process death is an ordinary typed result.
pub fn run(
  subject: process.Subject(message),
  make: fn(process.Subject(Result(value, Failure))) -> message,
) -> Result(value, Failure) {
  with_failure(subject, make, Failure(ClientClosed, NotSubmitted))
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
