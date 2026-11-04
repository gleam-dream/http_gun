//// Decides which request and response data cassettes never store.
////
//// `default()` removes the credential headers `authorization`,
//// `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`, `api-key`,
//// `x-goog-api-key`, `x-auth-token`, `x-access-token`,
//// `x-amz-security-token` and `x-csrf-token`. It replaces the value of the
//// credential query parameters `key`, `api_key`, `apikey`, `access_token`,
//// `token`, `client_secret`, `code`, `refresh_token`, `id_token`,
//// `signature`, `sig`, `x-amz-security-token`, `x-goog-api-key`, and the
//// AWS spellings `Signature`, `X-Amz-Signature`, `X-Amz-Credential` and
//// `X-Amz-Security-Token`, with `REDACTED`. It also rewrites credential
//// fields in request and response bodies:
////
//// - an `application/x-www-form-urlencoded` body keeps every pair, with the
////   value of each query parameter name above, and of each body field name
////   below, replaced by `REDACTED`;
//// - an `application/json` or `+json` body keeps every byte except the
////   value of an object key, at any depth, named `client_secret`,
////   `access_token`, `refresh_token`, `id_token`, `api_key`, `password`,
////   `secret`, `token` or `authorization`, which becomes `"REDACTED"`.
////
//// Names are compared exactly; a JSON key is compared as written, without
//// decoding escapes. A body with another content type, a form body that is
//// not UTF-8, a JSON body that does not scan (an unterminated string or
//// unbalanced brackets) and a body above 16 MiB are kept as they are; use
//// `with_body` for those. Add your own secrets, then pass the redaction to
//// `config.with_redaction`:
////
//// ```gleam
//// let redaction =
////   redaction.default()
////   |> redaction.with_headers(["x-signature"])
////   |> redaction.with_query_parameters(["session"])
////   |> redaction.with_body_fields(["card_number"])
////   |> redaction.with_body(fn(bytes) { scrub_card_numbers(bytes) })
//// config.default() |> config.with_redaction(redaction)
//// ```
////
//// A recording client stores requests and responses with the redaction
//// applied: listed headers are removed, listed query parameters keep their
//// name with the value `REDACTED`, credential body fields are replaced, and
//// the body function rewrites request bodies and whole response bodies. A
//// playback client applies the same redaction to the scripted request and to
//// each incoming request before comparing them, so a recorded cassette
//// matches the live code that made it. A redacted value therefore matches
//// any live value. The live request on the network is never changed.
////
//// Failures and telemetry events never contain a URL, query or body, nor a
//// request header. A `send` or `batch` failure after the response head
//// arrived keeps the response headers (`error.headers`) with the listed
//// headers removed. A waiting request's headers are held in a closure that
//// crash reports print as a function reference.

import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// What to remove from stored exchanges. The `default()` credentials are
/// always removed; the functions below only add to the lists.
pub opaque type Redaction {
  Redaction(
    headers: List(String),
    query: List(String),
    fields: List(String),
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
  "x-auth-token",
  "x-access-token",
  "x-amz-security-token",
  "x-csrf-token",
]

const credential_parameters = [
  "key",
  "api_key",
  "apikey",
  "access_token",
  "token",
  "client_secret",
  "code",
  "refresh_token",
  "id_token",
  "signature",
  "sig",
  "x-amz-security-token",
  "x-goog-api-key",
  "Signature",
  "X-Amz-Signature",
  "X-Amz-Credential",
  "X-Amz-Security-Token",
]

const credential_fields = [
  "client_secret",
  "access_token",
  "refresh_token",
  "id_token",
  "api_key",
  "password",
  "secret",
  "token",
  "authorization",
]

/// Bodies above this size are not scanned for credential fields. No
/// recording or script can hold one.
const max_scanned_bytes = 16_777_216

const marker = "REDACTED"

/// Remove the credential headers, and replace credential query parameters
/// and credential fields in form and JSON bodies, as the module
/// documentation lists.
pub fn default() -> Redaction {
  Redaction(
    headers: credential_headers,
    query: credential_parameters,
    fields: credential_fields,
    body: None,
  )
}

/// Also remove these headers, compared without case, from stored requests
/// and responses, including trailers, and from the response headers a
/// failure keeps.
pub fn with_headers(redaction: Redaction, names: List(String)) -> Redaction {
  let names = list.map(names, string.lowercase)
  Redaction(
    ..redaction,
    headers: list.unique(list.append(redaction.headers, names)),
  )
}

/// Replace the value of these query parameters with `REDACTED`, compared by
/// exact, percent-decoded name. The parameter order and every other byte of
/// the query stay as sent. The same names are replaced in form bodies.
pub fn with_query_parameters(
  redaction: Redaction,
  names: List(String),
) -> Redaction {
  Redaction(
    ..redaction,
    query: list.unique(list.append(redaction.query, names)),
  )
}

/// Also replace the value of these fields, compared exactly, in form and
/// JSON bodies.
pub fn with_body_fields(
  redaction: Redaction,
  names: List(String),
) -> Redaction {
  Redaction(
    ..redaction,
    fields: list.unique(list.append(redaction.fields, names)),
  )
}

/// Rewrite stored bodies with `redact`, after the credential fields are
/// replaced: each request body, and each response
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
/// rewrite the body for its `content-type`, as `body_for` does.
pub fn request(
  redaction: Redaction,
  req: Request(BitArray),
) -> Request(BitArray) {
  request.Request(
    ..req,
    headers: headers(redaction, req.headers),
    query: option.map(req.query, query(redaction, _)),
    body: body_for(redaction, req.headers, req.body),
  )
}

/// Rewrite a request or response body with the `content-type` in `headers`:
/// replace the credential fields of a form or JSON body, then apply the body
/// function, if any.
pub fn body_for(
  redaction: Redaction,
  headers: List(#(String, String)),
  bytes: BitArray,
) -> BitArray {
  body(redaction, fields(redaction, content_kind(headers), bytes))
}

/// Whether `body_for` can change a body with these headers: a body function
/// is set, or the content type is form or JSON.
pub fn rewrites_body_for(
  redaction: Redaction,
  headers: List(#(String, String)),
) -> Bool {
  rewrites_bodies(redaction) || content_kind(headers) != Opaque
}

/// Apply the body function, if any. Credential fields are not replaced; use
/// `body_for`.
pub fn body(redaction: Redaction, bytes: BitArray) -> BitArray {
  case redaction.body {
    Some(redact) -> redact(bytes)
    None -> bytes
  }
}

/// Whether this redaction has a body function. Credential fields are replaced
/// whatever this returns; see `rewrites_body_for`.
pub fn rewrites_bodies(redaction: Redaction) -> Bool {
  option.is_some(redaction.body)
}

fn query(redaction: Redaction, query: String) -> String {
  pairs(query, redaction.query)
}

/// Replace the value of each `&`-separated pair whose percent-decoded name
/// is in `names`, keeping every other byte.
fn pairs(text: String, names: List(String)) -> String {
  case names {
    [] -> text
    names ->
      string.split(text, "&")
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
          True -> name <> "=" <> marker
          False -> pair
        }
      })
      |> string.join("&")
  }
}

type ContentKind {
  Form
  Json
  Opaque
}

fn content_kind(headers: List(#(String, String))) -> ContentKind {
  let found =
    list.find(headers, fn(header) {
      string.lowercase(header.0) == "content-type"
    })
  case found {
    Error(Nil) -> Opaque
    Ok(#(_, value)) -> {
      let media = case string.split_once(value, ";") {
        Ok(#(media, _)) -> media
        Error(Nil) -> value
      }
      case string.lowercase(string.trim(media)) {
        "application/x-www-form-urlencoded" -> Form
        "application/json" -> Json
        media ->
          case string.ends_with(media, "+json") {
            True -> Json
            False -> Opaque
          }
      }
    }
  }
}

fn fields(
  redaction: Redaction,
  kind: ContentKind,
  bytes: BitArray,
) -> BitArray {
  case kind, bit_array.byte_size(bytes) > max_scanned_bytes {
    Opaque, _ | _, True -> bytes
    Form, False ->
      case bit_array.to_string(bytes) {
        Ok(text) ->
          bit_array.from_string(pairs(
            text,
            list.unique(list.append(redaction.query, redaction.fields)),
          ))
        Error(Nil) -> bytes
      }
    Json, False ->
      case redaction.fields {
        [] -> bytes
        names ->
          case json_from(bytes, names, []) {
            Ok(parts) -> bit_array.concat(list.reverse(parts))
            Error(Nil) -> bytes
          }
      }
  }
}

// A byte scanner, not a JSON parser: it finds each string followed by `:`
// (an object key) and replaces the value after a named key, keeping every
// other byte, so redacting twice changes nothing more. `parts` is reversed.
fn json_from(
  rest: BitArray,
  names: List(String),
  parts: List(BitArray),
) -> Result(List(BitArray), Nil) {
  let #(plain, rest) = until_quote(rest, rest, 0)
  let parts = [plain, ..parts]
  case rest {
    <<"\"":utf8, after:bytes>> -> {
      use #(raw, after) <- result.try(string_end(after, after, 0))
      let parts = [<<"\"":utf8, raw:bits, "\"":utf8>>, ..parts]
      let #(space, following) = spaces(after, after, 0)
      case following, named(raw, names) {
        <<":":utf8, value:bytes>>, True -> {
          let #(gap, value) = spaces(value, value, 0)
          use rest <- result.try(skip_value(value))
          json_from(rest, names, [
            <<"\"":utf8, marker:utf8, "\"":utf8>>,
            gap,
            <<":":utf8>>,
            space,
            ..parts
          ])
        }
        _, _ -> json_from(after, names, parts)
      }
    }
    _ -> Ok(parts)
  }
}

fn named(raw: BitArray, names: List(String)) -> Bool {
  case bit_array.to_string(raw) {
    Ok(name) -> list.contains(names, name)
    Error(Nil) -> False
  }
}

fn take(bytes: BitArray, count: Int) -> BitArray {
  case bytes {
    <<head:bytes-size(count), _:bytes>> -> head
    _ -> bytes
  }
}

fn until_quote(
  start: BitArray,
  rest: BitArray,
  count: Int,
) -> #(BitArray, BitArray) {
  case rest {
    <<"\"":utf8, _:bytes>> | <<>> -> #(take(start, count), rest)
    <<_, more:bytes>> -> until_quote(start, more, count + 1)
    _ -> #(start, <<>>)
  }
}

// The bytes of a string after its opening quote, and the rest after its
// closing quote.
fn string_end(
  start: BitArray,
  rest: BitArray,
  count: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  case rest {
    <<"\\":utf8, _, more:bytes>> -> string_end(start, more, count + 2)
    <<"\"":utf8, more:bytes>> -> Ok(#(take(start, count), more))
    <<_, more:bytes>> -> string_end(start, more, count + 1)
    _ -> Error(Nil)
  }
}

fn spaces(
  start: BitArray,
  rest: BitArray,
  count: Int,
) -> #(BitArray, BitArray) {
  case rest {
    <<byte, more:bytes>>
      if byte == 32 || byte == 9 || byte == 10 || byte == 13
    -> spaces(start, more, count + 1)
    _ -> #(take(start, count), rest)
  }
}

// The rest after one value: a string, a bracketed value or a scalar.
fn skip_value(value: BitArray) -> Result(BitArray, Nil) {
  case value {
    <<"\"":utf8, more:bytes>> ->
      string_end(more, more, 0) |> result.map(fn(found) { found.1 })
    <<"{":utf8, more:bytes>> | <<"[":utf8, more:bytes>> -> nested(more, 1)
    _ -> scalar(value, 0)
  }
}

fn nested(rest: BitArray, depth: Int) -> Result(BitArray, Nil) {
  case rest {
    <<"\"":utf8, more:bytes>> -> {
      use #(_, after) <- result.try(string_end(more, more, 0))
      nested(after, depth)
    }
    <<"{":utf8, more:bytes>> | <<"[":utf8, more:bytes>> ->
      nested(more, depth + 1)
    <<"}":utf8, more:bytes>> | <<"]":utf8, more:bytes>> ->
      case depth {
        1 -> Ok(more)
        _ -> nested(more, depth - 1)
      }
    <<_, more:bytes>> -> nested(more, depth)
    _ -> Error(Nil)
  }
}

fn scalar(rest: BitArray, count: Int) -> Result(BitArray, Nil) {
  case rest, count {
    <<byte, _:bytes>>, _
      if byte == 44
      || byte == 125
      || byte == 93
      || byte == 32
      || byte == 9
      || byte == 10
      || byte == 13
    -> stop(rest, count)
    <<_, more:bytes>>, _ -> scalar(more, count + 1)
    _, _ -> stop(rest, count)
  }
}

fn stop(rest: BitArray, count: Int) -> Result(BitArray, Nil) {
  case count {
    0 -> Error(Nil)
    _ -> Ok(rest)
  }
}
