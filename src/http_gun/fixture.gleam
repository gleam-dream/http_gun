//// Defines the HTTP exchanges that scripts and cassettes replay.
////
//// An `Exchange` pairs an expected `Request(BitArray)` with a `Reply`: a
//// response with its body chunks and `Ending`, or a `Failure`. Pass a list of
//// exchanges to `testing.start` or `cassette.new`. `matches` and `sanitise`
//// define how playback compares requests: credential headers are ignored, while
//// the method, URL, other headers and body bytes must match exactly.

import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import http_gun/error.{type Failure}

pub type Ending {
  Complete(trailers: List(#(String, String)))
  Failed(Failure)
  Cancelled
}

pub type Reply {
  Respond(response: response.Response(List(BitArray)), ending: Ending)
  Reject(Failure)
}

pub type Exchange {
  Exchange(request: request.Request(BitArray), reply: Reply)
}

/// Credential metadata is excluded on both sides of matching. Other headers,
/// the complete query, method, target and exact bytes remain significant.
pub fn matches(
  expected: request.Request(BitArray),
  actual: request.Request(BitArray),
) -> Bool {
  sanitise(expected) == sanitise(actual)
}

/// Remove the documented credential headers and normalize the request match key.
/// Bodies, queries and unlisted custom headers remain exact and may contain secrets.
pub fn sanitise(req: request.Request(BitArray)) -> request.Request(BitArray) {
  request.Request(
    ..req,
    host: string.lowercase(req.host),
    path: case req.path {
      "" -> "/"
      _ -> req.path
    },
    headers: safe_headers(req.headers)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
  )
}

/// Exclude the documented credential-header names, case-insensitively.
/// This is a finite list, not a general secret detector.
pub fn safe_headers(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  headers
  |> list.map(fn(h) { #(string.lowercase(h.0), h.1) })
  |> list.filter(fn(h) {
    !list.contains(
      [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "x-goog-api-key",
      ],
      h.0,
    )
  })
}

/// Estimate retained request/response observation bytes for admission.
/// This does not measure VM memory, JSON overhead or upstream parser allocations.
@internal
pub fn size(exchange: Exchange) -> Int {
  let request_size =
    bit_array.byte_size(exchange.request.body)
    + string.byte_size(string.inspect(request.set_body(exchange.request, Nil)))
  case exchange.reply {
    Reject(_) -> request_size + 256
    Respond(response, ending) ->
      request_size
      + string.byte_size(string.inspect(ending))
      + string.byte_size(string.inspect(response.headers))
      + list.fold(response.body, 0, fn(total, bytes) {
        total + bit_array.byte_size(bytes) + 32
      })
  }
}

/// Validate fixture methods, statuses, byte alignment and terminal observations.
@internal
pub fn validate(exchanges: List(Exchange)) -> Result(Nil, Nil) {
  case
    list.all(exchanges, fn(exchange) {
      bit_array.bit_size(exchange.request.body) % 8 == 0
      && case exchange.reply {
        Reject(_) -> True
        Respond(response, _) ->
          response.status >= 200
          && response.status <= 599
          && list.all(response.body, fn(bytes) {
            bit_array.bit_size(bytes) % 8 == 0
          })
      }
    })
  {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}
