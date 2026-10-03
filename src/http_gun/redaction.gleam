//// Decides which request and response data cassettes never store.
////
//// `default()` removes the credential headers `authorization`,
//// `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`, `api-key` and
//// `x-goog-api-key`. Add your own secrets, then pass the redaction to
//// `config.with_redaction`:
////
//// ```gleam
//// let redaction =
////   redaction.default()
////   |> redaction.with_headers(["x-signature"])
////   |> redaction.with_query_parameters(["token"])
////   |> redaction.with_body(fn(bytes) { scrub_card_numbers(bytes) })
//// config.default() |> config.with_redaction(redaction)
//// ```
////
//// A recording client stores requests and responses with the redaction
//// applied: listed headers are removed, listed query parameters keep their
//// name with the value `REDACTED`, and the body function rewrites request
//// bodies and whole response bodies. A playback client applies the same
//// redaction to the scripted request and to each incoming request before
//// comparing them, so a recorded cassette matches the live code that made it.
//// The live request on the network is never changed.
////
//// Failures and telemetry events never contain a URL, header, query or body,
//// so no redaction can leak into them, and a waiting request's headers are
//// held in a closure that crash reports print as a function reference.

import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

/// What to remove from stored exchanges. Credential headers are always
/// removed; the functions below only add to the list.
pub opaque type Redaction {
  Redaction(
    headers: List(String),
    query: List(String),
    body: Option(fn(BitArray) -> BitArray),
  )
}

const credential_headers = [
  "authorization",
  "proxy-authorization",
  "cookie",
  "set-cookie",
  "x-api-key",
  "api-key",
  "x-goog-api-key",
]

/// Remove the credential headers. Query parameters and bodies are kept.
pub fn default() -> Redaction {
  Redaction(headers: credential_headers, query: [], body: None)
}

/// Also remove these headers, compared without case, from stored requests
/// and responses, including trailers.
pub fn with_headers(redaction: Redaction, names: List(String)) -> Redaction {
  let names = list.map(names, string.lowercase)
  Redaction(
    ..redaction,
    headers: list.unique(list.append(redaction.headers, names)),
  )
}

/// Replace the value of these query parameters with `REDACTED`, compared by
/// exact, percent-decoded name. The parameter order and every other byte of
/// the query stay as sent.
pub fn with_query_parameters(
  redaction: Redaction,
  names: List(String),
) -> Redaction {
  Redaction(
    ..redaction,
    query: list.unique(list.append(redaction.query, names)),
  )
}

/// Rewrite stored bodies with `redact`: each request body, and each response
/// body as a whole. A recording buffers a response body until it ends, within
/// the recording's byte budget, and stores the rewritten body as one chunk,
/// so a secret split across chunks is still seen whole. Playback applies
/// `redact` to the scripted and the incoming request bodies before
/// comparing. Calling it again replaces the function.
pub fn with_body(
  redaction: Redaction,
  redact: fn(BitArray) -> BitArray,
) -> Redaction {
  Redaction(..redaction, body: Some(redact))
}

/// Remove the redacted headers from a header list.
pub fn headers(
  redaction: Redaction,
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) {
    !list.contains(redaction.headers, string.lowercase(header.0))
  })
}

/// Apply the redaction to a request: remove headers, replace query values and
/// rewrite the body.
pub fn request(
  redaction: Redaction,
  req: Request(BitArray),
) -> Request(BitArray) {
  request.Request(
    ..req,
    headers: headers(redaction, req.headers),
    query: option.map(req.query, query(redaction, _)),
    body: body(redaction, req.body),
  )
}

/// Apply the body function, if any.
pub fn body(redaction: Redaction, bytes: BitArray) -> BitArray {
  case redaction.body {
    Some(redact) -> redact(bytes)
    None -> bytes
  }
}

/// Whether this redaction rewrites bodies.
pub fn rewrites_bodies(redaction: Redaction) -> Bool {
  option.is_some(redaction.body)
}

fn query(redaction: Redaction, query: String) -> String {
  case redaction.query {
    [] -> query
    names ->
      string.split(query, "&")
      |> list.map(fn(pair) {
        let name = case string.split_once(pair, "=") {
          Ok(#(name, _)) -> name
          Error(Nil) -> pair
        }
        let decoded = case uri.percent_decode(string.replace(name, "+", " ")) {
          Ok(decoded) -> decoded
          Error(Nil) -> name
        }
        case list.contains(names, decoded) {
          True -> name <> "=REDACTED"
          False -> pair
        }
      })
      |> string.join("&")
  }
}
