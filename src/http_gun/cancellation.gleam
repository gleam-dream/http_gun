//// Cancels in-flight requests from another part of the program.
////
//// `with_token` runs a callback with a `Token`; attach it to a client view
//// with `http_gun.with_cancellation`. `cancel` stops every request made
//// through such a view that has not finished, before its headers or while
//// its body is read, and the token stays cancelled. Returning from the
//// callback, an exception and the creator's exit also cancel.
////
//// ```gleam
//// use token <- cancellation.with_token
//// let client = client |> http_gun.with_cancellation(token)
//// spawn_watchdog(fn() { cancellation.cancel(token) })
//// http_gun.send(client, req)
//// ```
////
//// Cancellation is local: it says nothing about whether the server processed
//// the request, and the failure's evidence says whether it may have been
//// sent.

import http_gun/internal/bridge
import http_gun/internal/token

/// A cancellation capability. Copies share one state.
pub type Token =
  token.Token

/// Run `run` with a new token, and cancel the token when `run` returns or
/// raises.
pub fn with_token(run: fn(Token) -> value) -> value {
  let token = token.new()
  bridge.scoped(fn() { run(token) }, fn() { token.cancel(token) })
}

/// Cancel. Idempotent, and returns at once: requests release their
/// resources asynchronously. A request started afterwards through a view
/// with this token fails with `Cancelled` and `NotSent`.
pub fn cancel(token: Token) -> Nil {
  token.cancel(token)
}

/// Whether the token has been cancelled.
pub fn is_cancelled(token: Token) -> Bool {
  token.is_cancelled(token)
}
