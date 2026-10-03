//// Scripted exchanges as the pool and body owners replay them, and the one
//// definition of how a playback request matches an expected one.

import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import http_gun/error.{type Failure}
import http_gun/redaction.{type Redaction}

pub type Ending {
  Finished(trailers: List(#(String, String)))
  Aborted(Failure)
  Abandoned
}

pub type Reply {
  Respond(
    status: Int,
    headers: List(#(String, String)),
    chunks: List(BitArray),
    ending: Ending,
  )
  Reject(Failure)
}

pub type Exchange {
  Exchange(request: Request(BitArray), reply: Reply)
}

/// How a playback client compares requests.
pub type Matching {
  Matching(
    ignored: List(String),
    matcher: Option(fn(Request(BitArray), Request(BitArray)) -> Bool),
  )
}

pub const exact = Matching([], None)

/// The comparable form of a request: the redaction applied, the host
/// lowercased, an empty path as `/`, header names lowercased, ignored
/// headers removed and headers sorted by name, keeping the order of
/// repeated names.
pub fn key(
  policy: Redaction,
  ignored: List(String),
  req: Request(BitArray),
) -> Request(BitArray) {
  let req = redaction.request(policy, req)
  request.Request(
    ..req,
    host: string.lowercase(req.host),
    path: case req.path {
      "" -> "/"
      path -> path
    },
    headers: req.headers
      |> list.map(fn(header) { #(string.lowercase(header.0), header.1) })
      |> list.filter(fn(header) { !list.contains(ignored, header.0) })
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
  )
}

pub fn matches(
  matching: Matching,
  policy: Redaction,
  expected: Request(BitArray),
  actual: Request(BitArray),
) -> Bool {
  let expected = key(policy, matching.ignored, expected)
  let actual = key(policy, matching.ignored, actual)
  case matching.matcher {
    None -> expected == actual
    Some(compare) -> compare(expected, actual)
  }
}

/// Estimated retained bytes of one exchange, for the 16 MiB script budget.
/// This does not measure VM memory.
pub fn size(exchange: Exchange) -> Int {
  let req = exchange.request
  let request_size =
    bit_array.byte_size(req.body)
    + string.byte_size(req.host)
    + string.byte_size(req.path)
    + string.byte_size(option.unwrap(req.query, ""))
    + headers_size(req.headers)
    + 64
  case exchange.reply {
    Reject(_) -> request_size + 256
    Respond(_, headers, chunks, ending) ->
      request_size
      + headers_size(headers)
      + case ending {
        Finished(trailers) -> headers_size(trailers)
        Aborted(_) | Abandoned -> 64
      }
      + list.fold(chunks, 0, fn(total, bytes) {
        total + bit_array.byte_size(bytes) + 32
      })
  }
}

fn headers_size(headers: List(#(String, String))) -> Int {
  list.fold(headers, 0, fn(total, header) {
    total + string.byte_size(header.0) + string.byte_size(header.1) + 16
  })
}

/// The position of the first exchange with a partial-byte body or a status
/// outside 200..599.
pub fn invalid(exchanges: List(Exchange)) -> Option(Int) {
  exchanges
  |> list.index_map(fn(exchange, index) { #(index, exchange) })
  |> list.find(fn(pair) {
    let exchange = pair.1
    bit_array.bit_size(exchange.request.body) % 8 != 0
    || case exchange.reply {
      Reject(_) -> False
      Respond(status, _, chunks, _) ->
        status < 200
        || status > 599
        || list.any(chunks, fn(bytes) { bit_array.bit_size(bytes) % 8 != 0 })
    }
  })
  |> option.from_result
  |> option.map(fn(pair) { pair.0 })
}

pub const max_bytes = 16_777_216

/// Ordered exchanges and how to match them.
pub type Script {
  Script(exchanges: List(Exchange), matching: Matching)
}
