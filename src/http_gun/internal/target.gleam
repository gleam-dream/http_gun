//// The rule a request must meet before it is sent: whole-byte body, a known
//// method, a host and port, a path with a leading slash, a host, path and
//// query without space, CR, LF, TAB or NUL (compared by code point), and
//// lowercase token header names with values free of CR, LF and NUL. Admission applies `check` to live requests; the codec
//// applies `check_target`, the host, port, path and query part, to a stored
//// schema 3 request, so a cassette's targets are ones a client could send.

import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun/error.{type RequestProblem}
import http_gun/internal/bridge

/// The host, port and whether TLS is used, as a connection is keyed.
pub fn origin(req: Request(a)) -> #(String, Int, Bool) {
  let tls = req.scheme == http.Https
  #(
    bridge.unbracket(string.lowercase(req.host)),
    case req.port {
      Some(port) -> port
      None ->
        case tls {
          True -> 443
          False -> 80
        }
    },
    tls,
  )
}

/// The first problem that stops `req` from being sent, if any.
pub fn check(req: Request(BitArray)) -> Result(Nil, RequestProblem) {
  let method_ok =
    http.parse_method(http.method_to_string(req.method)) |> result.is_ok
  use <- guard(bit_array.bit_size(req.body) % 8 == 0, error.BodyNotBytes)
  use <- guard(method_ok, error.InvalidMethod)
  use Nil <- result.try(check_target(req))
  use <- guard(
    list.all(req.headers, fn(h) {
      h.0 == string.lowercase(h.0)
      && http.parse_method(h.0) |> result.is_ok
      && !string.contains(h.1, "\r")
      && !string.contains(h.1, "\n")
      && !string.contains(h.1, "\u{0}")
    }),
    error.InvalidHeader,
  )
  Ok(Nil)
}

/// The host, port, path and query part of `check`.
pub fn check_target(req: Request(a)) -> Result(Nil, RequestProblem) {
  let #(host, port, _) = origin(req)
  use <- guard(
    host != "" && port > 0 && port <= 65_535 && safe(host),
    error.InvalidOrigin,
  )
  use <- guard(
    safe(option.unwrap(req.query, ""))
      && safe(req.path)
      && string.starts_with(req.path, "/"),
    error.InvalidTarget,
  )
  Ok(Nil)
}

fn guard(
  holds: Bool,
  problem: RequestProblem,
  next: fn() -> Result(Nil, RequestProblem),
) -> Result(Nil, RequestProblem) {
  case holds {
    True -> next()
    False -> Error(problem)
  }
}

// Compared by code point, not by grapheme, so a combining mark after a
// space cannot hide it.
fn safe(value: String) -> Bool {
  !list.any(string.to_utf_codepoints(value), fn(point) {
    list.contains(
      [0x20, 0x0D, 0x0A, 0x09, 0x00],
      string.utf_codepoint_to_int(point),
    )
  })
}
