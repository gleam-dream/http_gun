//// The process behind a cancellation token: it lives until cancelled or until
//// its creator exits, and owners monitor it.

import gleam/erlang/process

pub opaque type Token {
  Token(pid: process.Pid)
}

pub fn new() -> Token {
  let owner = process.self()
  Token(
    process.spawn_unlinked(fn() {
      let monitor = process.monitor(owner)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive_forever
      Nil
    }),
  )
}

/// Asynchronous latch. `is_cancelled` called afterwards from the cancelling
/// process sees it at once, because signals between two processes are ordered.
pub fn cancel(token: Token) -> Nil {
  process.kill(token.pid)
}

pub fn is_cancelled(token: Token) -> Bool {
  !process.is_alive(token.pid)
}

pub fn monitor(token: Token) -> process.Monitor {
  process.monitor(token.pid)
}
