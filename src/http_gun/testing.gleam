//// Starts offline clients that answer from a script of exchanges, to test
//// code that takes an `http_gun.Client`.
////
//// ```gleam
//// let assert Ok(req) = request.to("https://api.example.com/orders/7")
//// let script =
////   testing.script([
////     testing.exchange(
////       request.set_body(req, <<>>),
////       testing.Respond(
////         response.new(200) |> response.set_body([<<"{\"id\":7}">>]),
////         testing.Finished([]),
////       ),
////     ),
////   ])
//// let assert Ok(client) = testing.playback(script, config.default())
//// let assert Ok(buffered) = http_gun.send(client, request.set_body(req, <<>>))
//// ```
////
//// A playback client never opens a connection and ignores the destination
//// policy. Each request must match the next exchange: a mismatch fails with
//// `PlaybackMismatch(position)` and leaves the exchange in place, and a
//// request after the last fails with `PlaybackExhausted`. Concurrent
//// requests are matched in admission order.
////
//// Matching is exact by default: method, URL, headers and body bytes, after
//// the configuration's redaction (`config.with_redaction`) is applied to
//// both sides. `ignoring_headers` skips headers such as a timestamp or a
//// signature, and `matching` replaces the comparison.
////
//// `exchange` drops the credential headers of `redaction.default()` from
//// the request it stores, so a script never holds a caller's credentials.

import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import http_gun
import http_gun/config
import http_gun/error.{type Failure}
import http_gun/internal/pool
import http_gun/internal/script as internal
import http_gun/redaction.{type Redaction}

/// A request and the reply that answers it.
pub type Exchange =
  internal.Exchange

/// Ordered exchanges and the way requests are matched against them.
pub type Script =
  internal.Script

/// How a scripted exchange answers.
pub type Reply {
  /// Respond with a status, headers and body chunks, then end.
  Respond(response: Response(List(BitArray)), ending: Ending)
  /// Fail before any response, for example with a connection failure.
  Reject(Failure)
}

/// How a scripted response body ends.
pub type Ending {
  /// The body completed, with these trailers.
  Finished(trailers: List(#(String, String)))
  /// The body failed after its chunks.
  Aborted(Failure)
  /// The client closed the body before it completed, as a recorded early
  /// stop replays.
  Abandoned
}

/// Pair an expected request with its reply.
pub fn exchange(request: Request(BitArray), reply: Reply) -> Exchange {
  internal.Exchange(
    redaction.request(redaction.default(), request),
    case reply {
      Reject(failure) -> internal.Reject(failure)
      Respond(response, ending) ->
        internal.Respond(
          response.status,
          response.headers,
          response.body,
          case ending {
            Finished(trailers) -> internal.Finished(trailers)
            Aborted(failure) -> internal.Aborted(failure)
            Abandoned -> internal.Abandoned
          },
        )
    },
  )
}

/// The expected request of an exchange, as stored.
pub fn request(exchange: Exchange) -> Request(BitArray) {
  exchange.request
}

/// The reply of an exchange.
pub fn reply(exchange: Exchange) -> Reply {
  case exchange.reply {
    internal.Reject(failure) -> Reject(failure)
    internal.Respond(status, headers, chunks, ending) ->
      Respond(response.Response(status, headers, chunks), case ending {
        internal.Finished(trailers) -> Finished(trailers)
        internal.Aborted(failure) -> Aborted(failure)
        internal.Abandoned -> Abandoned
      })
  }
}

/// A script of exchanges, matched in order and exactly.
pub fn script(exchanges: List(Exchange)) -> Script {
  internal.Script(exchanges, internal.exact)
}

/// The exchanges of a script, in order.
pub fn exchanges(script: Script) -> List(Exchange) {
  script.exchanges
}

/// Leave these headers, compared without case, out of matching on both
/// sides, for values that change on every run such as a date or a
/// signature.
pub fn ignoring_headers(script: Script, names: List(String)) -> Script {
  let matching = script.matching
  internal.Script(
    ..script,
    matching: internal.Matching(
      ..matching,
      ignored: list.append(matching.ignored, list.map(names, string.lowercase)),
    ),
  )
}

/// Replace the exact comparison. `compare` receives the expected and the
/// actual request as `match_key` forms them: redacted, normalised, without
/// ignored headers.
pub fn matching(
  script: Script,
  compare: fn(Request(BitArray), Request(BitArray)) -> Bool,
) -> Script {
  internal.Script(
    ..script,
    matching: internal.Matching(..script.matching, matcher: Some(compare)),
  )
}

/// Start an offline client that answers from `script`. The script is checked
/// first: statuses must be 200..599, bodies whole bytes, and the whole
/// script within 16 MiB.
///
/// Each call starts a client with its own cursor at the first exchange.
/// The immutable `Script` can be reused to start independent clients. Views
/// made from one client share its cursor; changing correlation does not create
/// another replay or affect matching. Stop each started client separately.
pub fn playback(
  script: Script,
  settings: config.Config,
) -> Result(http_gun.Client, http_gun.StartError) {
  use settings <- result.try(
    config.validate(settings) |> result.map_error(http_gun.InvalidConfig),
  )
  use Nil <- result.try(case internal.invalid(script.exchanges) {
    Some(position) -> Error(http_gun.InvalidScript(position))
    option.None -> Ok(Nil)
  })
  let size =
    list.fold(script.exchanges, 0, fn(total, exchange) {
      total + internal.size(exchange)
    })
  use Nil <- result.try(case size <= internal.max_bytes {
    True -> Ok(Nil)
    False -> Error(http_gun.ScriptTooLarge(internal.max_bytes, size))
  })
  pool.start(settings, pool.Playback(script.exchanges, 0, script.matching))
  |> result.map(fn(started) { started.data })
  |> result.replace_error(http_gun.StartFailed)
}

/// The form of a request that playback compares: `redaction` applied, the
/// host lowercased, an empty path as `/`, header names lowercased and headers
/// sorted by name.
pub fn match_key(
  redaction: Redaction,
  request: Request(BitArray),
) -> Request(BitArray) {
  internal.key(redaction, [], request)
}
