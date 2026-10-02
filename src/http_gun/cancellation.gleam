//// Cancels in-flight requests from another part of the program.
////
//// `with_token` and `try_with_token` run a callback with a `Token`. Pass the
//// token in `request_options.Options` to `http_gun`'s `_with_options`
//// functions. `cancel` stops every associated request that has not finished,
//// before headers or during body consumption, and the token stays cancelled.
//// Scope exit, an exception and the creator's death also cancel. Cancellation
//// is local: it says nothing about whether the server processed the request.

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

/// Run a fallible callback within a cancellation scope without nested Results.
/// Only token startup failures pass through on_start_error; callback errors keep
/// their own type and value. Return, error and exception cancel associated work
/// exactly as with_token does. Exceptions propagate after scope cleanup.
pub fn try_with_token(
  on_start_error: fn(error.Failure) -> app_error,
  run: fn(Token) -> Result(value, app_error),
) -> Result(value, app_error) {
  with_token(run)
  |> result.map_error(on_start_error)
  |> result.flatten
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
