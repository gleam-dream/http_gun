//// Reads and closes a streamed response body.
////
//// `http_gun.open` and `http_gun.with_response` give a `Response(Body)`. Read
//// it chunk by chunk with `next`, or gather it with `collect`:
////
//// ```gleam
//// use response <- http_gun.with_response(client, req, fn(failure) { failure })
//// count(response.body, 0)
////
//// fn count(stream: body.Body, total: Int) -> Result(Int, error.Failure) {
////   case body.next(stream) {
////     Ok(body.Chunk(bytes)) -> count(stream, total + bit_array.byte_size(bytes))
////     Ok(body.End(..)) -> Ok(total)
////     Error(failure) -> Error(failure)
////   }
//// }
//// ```
////
//// `next` waits until bytes arrive, the body ends or it fails; the client's
//// request and idle timeouts bound that wait. `next_within` waits at most a
//// given time and returns `None` when it passes, leaving the stream intact.
//// `close` ends the stream early and is idempotent.
////
//// The process that opened the response owns it: a read from another process
//// fails with `WrongOwner`, and a read while another is pending fails with
//// `ReadConflict`. Copies of a `Body` share one cursor.

import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import http_gun/config
import http_gun/error.{type Failure}
import http_gun/internal/bridge
import http_gun/internal/owner
import http_gun/internal/settings

/// A streamed response body owned by the process that opened it.
pub type Body =
  owner.Body

pub type Event {
  Chunk(BitArray)
  /// The body ended; trailers follow the last chunk.
  End(trailers: List(#(String, String)))
}

pub type Collected {
  Collected(bytes: BitArray, trailers: List(#(String, String)))
}

/// Wait for the next chunk or the end of the body. The request timeout, the
/// idle timeout and cancellation bound the wait; with both timeouts set to
/// `Infinity` it waits as long as the stream stays open.
pub fn next(body: Body) -> Result(Event, Failure) {
  case owner.read(body, None) {
    Ok(Some(event)) -> Ok(event_of(event))
    Ok(None) -> next(body)
    Error(failure) -> Error(failure)
  }
}

/// Wait at most `wait` for the next chunk or the end of the body. `None`
/// means nothing arrived in time; the stream stays intact and a later read
/// continues it. A zero or negative wait polls once.
pub fn next_within(
  body: Body,
  wait: Duration,
) -> Result(Option(Event), Failure) {
  owner.read(body, Some(bridge.now() + settings.milliseconds(wait)))
  |> result.map(option.map(_, event_of))
}

/// End the stream and cancel the request locally if it is unfinished.
/// Closing is idempotent, and any holder of a copy may close it. Local
/// cancellation does not establish what the server did.
pub fn close(body: Body) -> Nil {
  owner.close(body)
}

/// The protocol the response used; `Offline` for scripted and cassette
/// responses.
pub fn protocol(body: Body) -> config.Negotiated {
  case owner.protocol(body) {
    settings.H1 -> config.H1
    settings.H2 -> config.H2
    settings.Offline -> config.Offline
  }
}

/// Collect the rest of the body, at most `limit` bytes. A larger body is
/// closed and fails with `LimitExceeded(ResponseBodyBytes, ..)`, carrying the
/// response status. Close the body afterwards if you opened it with
/// `http_gun.open`; scoped responses close themselves.
pub fn collect(body: Body, limit: Int) -> Result(Collected, Failure) {
  owner.collect(body, limit, False, fn(_) { Ok(Nil) })
  |> result.map(fn(collected) { Collected(collected.0, collected.1) })
}

fn event_of(event: owner.Event) -> Event {
  case event {
    owner.Chunk(bytes) -> Chunk(bytes)
    owner.End(trailers) -> End(trailers)
  }
}
