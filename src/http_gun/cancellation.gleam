//// Scoped, latched local cancellation. This capability never owns body reads.

import gleam/erlang/process
import gleam/otp/actor
import gleam/result
import http_gun/error
import http_gun/internal/bridge

pub opaque type Token {
  Token(subject: process.Subject(Message), pid: process.Pid)
}

type Message {
  Cancel
  OwnerLost(process.Down)
}

/// Run with a new cancellation capability. Copies share cancellation state.
/// Scope exit, exceptions and creator death cancel unfinished associated work.
/// Startup failure is returned; the callback retains its own return type.
pub fn with_token(run: fn(Token) -> value) -> Result(value, error.Failure) {
  let owner = process.self()
  use started <- result.try(
    actor.new_with_initialiser(1000, fn(subject) {
      let _ = process.monitor(owner)
      Ok(
        actor.initialised(Nil)
        |> actor.selecting(
          process.new_selector()
          |> process.select(subject)
          |> process.select_monitors(OwnerLost),
        )
        |> actor.returning(Token(subject, process.self())),
      )
    })
    |> actor.on_message(fn(_, _) { actor.stop() })
    |> actor.start
    |> result.map_error(fn(_) {
      error.Failure(error.ClientClosed, error.NotSubmitted)
    }),
  )
  let token = started.data
  Ok(bridge.scoped(fn() { run(token) }, fn() { cancel(token) }))
}

/// Latch cancellation and notify existing owners. Idempotent, including after
/// scope exit. Owners release resources asynchronously; remote execution is unknown.
pub fn cancel(token: Token) -> Nil {
  let monitor = process.monitor(token.pid)
  process.send(token.subject, Cancel)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
}

@internal
pub fn is_cancelled(token: Token) -> Bool {
  !process.is_alive(token.pid)
}

@internal
pub fn monitor(token: Token) -> process.Monitor {
  process.monitor(token.pid)
}
