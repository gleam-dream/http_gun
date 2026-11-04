//// Decides which request and response data cassettes never store.
////
//// `default()` removes the credential headers `authorization`,
//// `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`, `api-key`,
//// `x-goog-api-key`, `x-auth-token`, `x-access-token`,
//// `x-amz-security-token` and `x-csrf-token`. One list of credential names,
//// `key`, `api_key`, `apikey`, `access_token`, `token`, `client_secret`,
//// `code`, `refresh_token`, `id_token`, `signature`, `sig`,
//// `x-amz-security-token`, `x-goog-api-key`, `x-amz-signature`,
//// `x-amz-credential`, `password`, `secret` and `authorization`, selects
//// what else is replaced by `REDACTED`:
////
//// - the value of a query parameter with a listed name;
//// - in an `application/x-www-form-urlencoded` request or response body, the
////   value of a pair with a listed name, with pairs split at `&` and `;`;
//// - in an `application/json` or `+json` body, the value of an object key
////   with a listed name at any depth, which becomes `"REDACTED"`. Every other
////   byte of the body is kept.
////
//// Names are compared without case and ignoring `-` and `_`, so `api_key`
//// also selects `API-KEY`, `apiKey` and `ApiKey`. A JSON key is compared as
//// written, without decoding escapes. A form or JSON body that cannot be
//// scanned (a form body that is not UTF-8, JSON with an unterminated string
//// or a missing value, as a truncated or aborted body has) or that is above
//// 16 MiB is replaced as a whole by `REDACTED-UNPARSABLE`. Bodies with
//// another content type are kept; use `with_body` for those. Add your own
//// secrets, then pass the redaction to `config.with_redaction`:
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
    names: List(String),
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
  "x-amz-signature",
  "x-amz-credential",
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

/// Replaces a whole form or JSON body that cannot be scanned.
const unparsable = "REDACTED-UNPARSABLE"

/// Remove the credential headers, and replace credential query parameters
/// and credential fields in form and JSON bodies, as the module
/// documentation lists.
pub fn default() -> Redaction {
  Redaction(
    headers: credential_headers,
    names: add_names([], list.append(credential_parameters, credential_fields)),
    body: None,
  )
}

/// Names compare without case and without `-` or `_`, so `api-key`,
/// `api_key`, `apiKey` and `APIKEY` are one name.
fn normalise(name: String) -> String {
  name
  |> string.lowercase
  |> string.replace("-", "")
  |> string.replace("_", "")
}

fn add_names(names: List(String), added: List(String)) -> List(String) {
  list.unique(list.append(names, list.map(added, normalise)))
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
/// percent-decoded name without case and ignoring `-` and `_`. The parameter
/// order and every other byte of the query stay as sent. Query parameters
/// and body fields share one list, so the names also apply to form and JSON
/// bodies.
pub fn with_query_parameters(
  redaction: Redaction,
  names: List(String),
) -> Redaction {
  Redaction(..redaction, names: add_names(redaction.names, names))
}

/// Also replace the value of these fields in form and JSON bodies, compared
/// as `with_query_parameters` compares names. Query parameters and body
/// fields share one list, so the names also apply to the query.
pub fn with_body_fields(
  redaction: Redaction,
  names: List(String),
) -> Redaction {
  Redaction(..redaction, names: add_names(redaction.names, names))
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
  pairs(query, redaction.names, ["&"])
}

/// Replace the value of each pair, split at `separators`, whose
/// percent-decoded, normalised name is in `names`, keeping every other byte.
fn pairs(
  text: String,
  names: List(String),
  separators: List(String),
) -> String {
  case separators {
    [separator, ..rest] ->
      string.split(text, separator)
      |> list.map(pairs(_, names, rest))
      |> string.join(separator)
    [] -> {
      let name = case string.split_once(text, "=") {
        Ok(#(name, _)) -> name
        Error(Nil) -> text
      }
      let decoded = case uri.percent_decode(string.replace(name, "+", " ")) {
        Ok(decoded) -> decoded
        Error(Nil) -> name
      }
      case list.contains(names, normalise(decoded)) {
        True -> name <> "=" <> marker
        False -> text
      }
    }
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

// A form or JSON body that cannot be scanned fails closed: it may be a
// truncated body whose secret value is cut short, so it is replaced whole.
fn fields(
  redaction: Redaction,
  kind: ContentKind,
  bytes: BitArray,
) -> BitArray {
  case kind, bit_array.byte_size(bytes) > max_scanned_bytes {
    Opaque, _ -> bytes
    _, True -> bit_array.from_string(unparsable)
    Form, False ->
      case bit_array.to_string(bytes) {
        Ok(text) ->
          bit_array.from_string(pairs(text, redaction.names, ["&", ";"]))
        Error(Nil) -> bit_array.from_string(unparsable)
      }
    Json, False ->
      case json_from(bytes, redaction.names, []) {
        Ok(parts) -> bit_array.concat(list.reverse(parts))
        Error(Nil) -> bit_array.from_string(unparsable)
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
    Ok(name) -> list.contains(names, normalise(name))
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
