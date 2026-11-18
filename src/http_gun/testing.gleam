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
//// Matching compares method, URL, headers and body bytes after the
//// configuration's redaction (`config.with_redaction`) is applied to both
//// sides, so a redacted query parameter or body field matches any value.
//// Everything else is compared exactly. `ignoring_headers` skips headers
//// such as a timestamp or a signature, and `matching` replaces the
//// comparison.
////
//// `exchange` applies `redaction.default()` to the request it stores: it
//// drops the credential headers and replaces credential query parameters
//// and form or JSON body fields, so a script never holds a caller's
//// credentials.

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
  pool.start(settings, pool.playback(script.exchanges, script.matching))
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

/// A request that did not match the exchange at `position`. Both the
/// exchange's request and the actual one are as `match_key` forms them, with
/// the script's ignored headers removed, so they differ exactly where
/// matching saw a difference (unless `matching` replaced the comparison).
pub type Mismatch {
  Mismatch(
    position: Int,
    expected: Request(BitArray),
    actual: Request(BitArray),
  )
}

/// What a playback client met that did not match its script. A client whose
/// requests all matched and whose exchanges were all used reports
/// `Verdict([], [], [], 0)`.
pub type Verdict {
  Verdict(
    /// Requests that did not match the next exchange, oldest first: the
    /// first 64.
    mismatched: List(Mismatch),
    /// Requests that arrived after the last exchange, oldest first, in the
    /// same form: the first 64.
    exhausted: List(Request(BitArray)),
    /// Exchanges not used yet, in order.
    unused: List(Exchange),
    /// Refusals of either kind beyond the first 64 of each, which the
    /// client counted but did not keep.
    dropped: Int,
  )
}

/// Why `verify` has no verdict.
pub type VerifyError {
  /// The client was started by `http_gun.start` or `cassette.record`.
  NotPlayback
  /// The client has stopped; ask before `http_gun.stop`.
  ClientStopped
}

/// Report what this playback client met so far that did not match its
/// script. The caller's code sees `PlaybackMismatch` and `PlaybackExhausted`
/// as before; `verify` lets a test fail on them even when that code handled
/// the failure, and on exchanges it never used. Views of one client share
/// one report. The client keeps the first 64 refused requests of each kind
/// until it stops and counts the rest in `dropped`.
pub fn verify(client: http_gun.Client) -> Result(Verdict, VerifyError) {
  case pool.verify(client) {
    Error(_) -> Error(ClientStopped)
    Ok(option.None) -> Error(NotPlayback)
    Ok(Some(report)) ->
      Ok(Verdict(
        mismatched: list.map(report.mismatched, fn(miss) {
          Mismatch(miss.position, miss.expected, miss.actual)
        }),
        exhausted: report.exhausted,
        unused: report.unused,
        dropped: report.dropped,
      ))
  }
}
